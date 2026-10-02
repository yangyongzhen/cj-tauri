package cjTauri.tests

import cjTauri.*
import std.collection.*
import std.sync.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * IPC 链路单元测试：解析 → 能力校验 → 分发 → 结果/错误回写 → 事件投递。
 * 这些用例不碰宿主层（不创建窗口），纯逻辑，可在无 GUI 的环境跑。
 */

/** 固定返回 "ok" 的处理器 */
class OkHandler <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        return JsonString("ok")
    }
}

/** 抛 CommandException 的处理器（预期内的失败） */
class BoomHandler <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        throw CommandException("boom")
    }
}

/** 抛普通异常的处理器（预期外的失败） */
class CrashHandler <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        throw Exception("crash")
    }
}

/** 取 JSON 顶层字符串字段（缺失返回空串） */
func strField(json: String, key: String): String {
    let o = JsonValue.fromStr(json).asObject()
    if (let Some(x) <- o.get(key)) {
        return x.asString().getValue()
    }
    return ""
}

/** 取 JSON 顶层布尔字段（缺失返回 false） */
func boolField(json: String, key: String): Bool {
    let o = JsonValue.fromStr(json).asObject()
    if (let Some(x) <- o.get(key)) {
        return x.asBool().getValue()
    }
    return false
}

/*
 * 命令执行自「异步分发」改造起跑在 worker 线程上（见 IpcHub.handleInvoke），于是用例里出现两侧并发：
 * worker 线程往 sink 里写，用例线程读。两边都过同一把锁——既避免读写竞态，也借锁的释放/获取建立可见性
 * （没有同步点的话，写完的那侧不保证被读到）。
 */
let TEST_SINK_LOCK = Mutex()

/** 往用例 sink 追加一条（加锁；hub 的 jsSink 与断言前的等待都走它建立的顺序） */
func addToTestSink(sink: ArrayList<String>, s: String): Unit {
    synchronized(TEST_SINK_LOCK) {
        sink.add(s)
    }
}

/**
 * 等 sink 至少收到 n 条消息（最多等 timeoutMs 毫秒后放弃，让断言自己报失败而不是挂死）。
 * 「已放行且已注册」的调用是异步的，断言前必须先等；「未授权 / 未注册」是同步拒绝，不必等。
 */
func waitSink(sink: ArrayList<String>, n: Int64, timeoutMs!: Int64 = 10000): Unit {
    var waited: Int64 = 0
    while (waited < timeoutMs) {
        synchronized(TEST_SINK_LOCK) {
            if (sink.size >= n) {
                return
            }
        }
        sleep(Duration.millisecond * 5)
        waited += 5
    }
}

/** 组装一个「只放行指定命令/事件」的 hub，sink 收集输出 */
func hubWith(commands: Array<String>, events: Array<String>, sink: ArrayList<String>): IpcHub {
    let hub = IpcHub()
    let cap = Capability("test")
    cap.allowWindow("main")
    for (c in commands) {
        cap.allowCommand(c)
    }
    for (e in events) {
        cap.allowEvent(e)
    }
    let reg = CapabilityRegistry()
    reg.add(cap)
    hub.setCapabilities(reg)
    hub.jsSink = { s => addToTestSink(sink, s) }
    return hub
}

@Test
func testInvokeRequestParseOk(): Unit {
    let req = InvokeRequest.parse("{\"type\":\"invoke\",\"id\":7,\"cmd\":\"greet\",\"args\":{\"who\":\"cj\"}}")
    @Expect(req.isSome(), true)
    let r = req.getOrThrow()
    @Expect(r.id, 7)
    @Expect(r.cmd, "greet")
    @Expect(r.args.get("who").getOrThrow().asString().getValue(), "cj")
}

@Test
func testInvokeRequestParseToleratesMissingArgs(): Unit {
    let req = InvokeRequest.parse("{\"type\":\"invoke\",\"id\":1,\"cmd\":\"system:ping\"}")
    @Expect(req.isSome(), true)
    @Expect(req.getOrThrow().args.size(), 0)
}

@Test
func testInvokeRequestParseRejectsMalformed(): Unit {
    // 非 JSON
    @Expect(InvokeRequest.parse("not json").isNone(), true)
    // 顶层不是对象
    @Expect(InvokeRequest.parse("[1,2,3]").isNone(), true)
    // type 不是 invoke：emit 报文由 EmitRequest.parse 接走，这边照样是 None
    @Expect(InvokeRequest.parse("{\"type\":\"emit\",\"id\":1,\"event\":\"x\"}").isNone(), true)
    // 缺 cmd
    @Expect(InvokeRequest.parse("{\"type\":\"invoke\",\"id\":1}").isNone(), true)
    // 缺 id
    @Expect(InvokeRequest.parse("{\"type\":\"invoke\",\"cmd\":\"greet\"}").isNone(), true)
    // 缺 type
    @Expect(InvokeRequest.parse("{\"id\":1,\"cmd\":\"greet\"}").isNone(), true)
}

@Test
func testHubResolvesAllowedCommand(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith(["greet"], [], out)
    hub.register("greet", OkHandler())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":3,\"cmd\":\"greet\"}")
    waitSink(out, 1)
    @Expect(out.size, 1)
    @Expect(strField(out[0], "type"), "resolve")
    @Expect(strField(out[0], "data"), "ok")
}

@Test
func testHubRejectsCommandNotAllowed(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith(["system:ping"], [], out)
    hub.register("greet", OkHandler())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":4,\"cmd\":\"greet\"}")
    // 未授权在**调用线程上同步拒绝**：不必等 worker，调用返回即可见
    @Expect(out.size, 1)
    @Expect(strField(out[0], "error"), "command not allowed: greet")
}

@Test
func testHubRejectsUnregisteredCommand(): Unit {
    let out = ArrayList<String>()
    // 放行了但没注册：与「未放行」是两条不同的报错，容易混淆
    let hub = hubWith(["ghost"], [], out)
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":5,\"cmd\":\"ghost\"}")
    // 未注册同样是同步拒绝
    @Expect(out.size, 1)
    @Expect(strField(out[0], "error"), "command not registered: ghost")
}

@Test
func testHubReportsCommandException(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith(["boom"], [], out)
    hub.register("boom", BoomHandler())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":6,\"cmd\":\"boom\"}")
    waitSink(out, 1)
    @Expect(out.size, 1)
    @Expect(strField(out[0], "error"), "boom")
}

@Test
func testHubReportsUnexpectedException(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith(["crash"], [], out)
    hub.register("crash", CrashHandler())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":8,\"cmd\":\"crash\"}")
    waitSink(out, 1)
    @Expect(out.size, 1)
    // 预期外的异常统一加前缀，前端据此区分「业务拒绝」与「崩了」
    @Expect(strField(out[0], "error").startsWith("command failed:"), true)
}

@Test
func testHubIgnoresMessageWithoutId(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith(["greet"], ["tick"], out)
    hub.register("greet", OkHandler())
    // 结构坏掉且**读不出 id**：对应不到任何 promise，只能 stderr（这是设计，不是遗留问题）
    hub.handleRawMessage("garbage")
    hub.handleRawMessage("{\"type\":\"emit\",\"event\":\"tick\"}")
    hub.handleRawMessage("{\"type\":\"invoke\"}")
    @Expect(out.size, 0)
}

@Test
func testEmitRequiresDeclaredEvent(): Unit {
    let denied = ArrayList<String>()
    let hubDenied = hubWith(["greet"], [], denied)
    hubDenied.emitToWindow("tick", JsonObject(), "main")
    @Expect(denied.size, 0)

    let allowed = ArrayList<String>()
    let hubAllowed = hubWith(["greet"], ["tick"], allowed)
    hubAllowed.emitToWindow("tick", JsonObject(), "main")
    @Expect(allowed.size, 1)
    @Expect(strField(allowed[0], "type"), "event")
    @Expect(strField(allowed[0], "event"), "tick")
}

@Test
func testIpcMessageResolveKeepsPayload(): Unit {
    var payload = JsonObject()
    payload.put("n", JsonInt(1))
    let msg = IpcMessage.resolve(9, payload)
    @Expect(strField(msg, "type"), "resolve")
    let o = JsonValue.fromStr(msg).asObject()
    @Expect(o.get("data").getOrThrow().asObject().get("n").getOrThrow().asInt().getValue(), 1)
}

/*
 * 以下是「异步分发」的行为契约（命令执行跑在 worker 线程上，见 IpcHub.handleInvoke）：
 * 调用线程只做校验并立刻返回，慢命令不再把宿主 UI 线程钉住。
 */

/** 睡 300ms 再回答：模拟 `shell:exec` 这类慢命令 */
class SlowHandler <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        sleep(Duration.millisecond * 300)
        return JsonString("slow-ok")
    }
}

@Test
func testDispatchReturnsBeforeSlowCommandFinishes(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith(["slow"], [], out)
    hub.register("slow", SlowHandler())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":41,\"cmd\":\"slow\"}")
    // 关键：handler 还在睡，调用就已经返回了 —— 这就是「UI 线程不被命令阻塞」的单元级证据
    // （handler 睡 300ms，这两行断言在微秒级完成，不存在轮到 worker 跑完的可能）
    @Expect(out.size, 0)
    waitSink(out, 1)
    @Expect(strField(out[0], "type"), "resolve")
    @Expect(strField(out[0], "data"), "slow-ok")
}

@Test
func testRejectsStaySynchronous(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith(["allowed"], [], out)
    // 未授权：调用线程上同步回写，调用一返回就可见，不需要等
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":42,\"cmd\":\"nope\"}")
    @Expect(out.size, 1)
    @Expect(strField(out[0], "error"), "command not allowed: nope")
    // 未注册：同样同步（放行了但没注册，两条报错别混）
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":43,\"cmd\":\"allowed\"}")
    @Expect(out.size, 2)
    @Expect(strField(out[1], "error"), "command not registered: allowed")
}

@Test
func testConcurrentInvokesEachResolveExactlyOnce(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith(["slow"], [], out)
    hub.register("slow", SlowHandler())
    // 同一命令连发 6 次：**不保证执行顺序**（各自独立跑，谁先完谁先回），但每条 id 必须有且只有一条响应
    for (i in 50..56) {
        hub.handleRawMessage("{\"type\":\"invoke\",\"id\":${i},\"cmd\":\"slow\"}")
    }
    waitSink(out, 6, timeoutMs: 20000)
    @Expect(out.size, 6)
    let ids = ArrayList<Int64>()
    for (m in out) {
        @Expect(strField(m, "type"), "resolve")
        ids.add(JsonValue.fromStr(m).asObject().get("id").getOrThrow().asInt().getValue())
    }
    for (i in 50..56) {
        var hits = 0
        for (id in ids) {
            if (id == i) {
                hits += 1
            }
        }
        // 既不丢（0）也不重复（2）：并发下每条 invoke 恰好被回投一次
        @Expect(hits, 1)
    }
}

/*
 * 前端 emit（P1-4 缺口）：只投后端监听器、不回投页面；未授权与非法报文的失败都要回给前端。
 * 与 Tauri v2 的差异是有意选的（见 EmitRequest 注释 / docs/IPC-通信机制.md §7）。
 */

/** 抛异常的监听器：验证「一个听众崩了不牵连别的听众与发送方」 */
func boomListener(p: JsonValue): Unit {
    throw Exception("listener boom")
}

@Test
func testEmitRequestParseOk(): Unit {
    let req = EmitRequest.parse("{\"type\":\"emit\",\"id\":9,\"event\":\"tick\",\"payload\":{\"n\":1}}")
    @Expect(req.isSome(), true)
    let r = req.getOrThrow()
    @Expect(r.id, 9)
    @Expect(r.event, "tick")
    @Expect(r.payload.asObject().get("n").getOrThrow().asInt().getValue(), 1)
}

@Test
func testEmitRequestParseDefaultsPayloadAndRejectsMalformed(): Unit {
    // 前端 emit('tick') 不带第二个参数：payload 缺省成空对象
    let bare = EmitRequest.parse("{\"type\":\"emit\",\"id\":1,\"event\":\"tick\"}")
    @Expect(bare.isSome(), true)
    @Expect(bare.getOrThrow().payload.asObject().size(), 0)
    // 缺 id / 缺 event / 类型不对，都不是合法 emit 报文
    @Expect(EmitRequest.parse("{\"type\":\"emit\",\"event\":\"tick\"}").isNone(), true)
    @Expect(EmitRequest.parse("{\"type\":\"emit\",\"id\":1}").isNone(), true)
    @Expect(EmitRequest.parse("{\"type\":\"invoke\",\"id\":1,\"cmd\":\"greet\"}").isNone(), true)
    @Expect(EmitRequest.parse("not json").isNone(), true)
}

@Test
func testFrontendEmitReachesBackendListener(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith([], ["tick"], out)
    let seen = ArrayList<Int64>()
    hub.listenEvent("tick", { p =>
        synchronized(TEST_SINK_LOCK) {
            seen.add(p.asObject().get("n").getOrThrow().asInt().getValue())
        }
    })
    hub.handleRawMessage("{\"type\":\"emit\",\"id\":21,\"event\":\"tick\",\"payload\":{\"n\":7}}")
    waitSink(out, 1)
    @Expect(seen.size, 1)
    @Expect(seen[0], 7)
    @Expect(out.size, 1)
    @Expect(strField(out[0], "type"), "resolve")
    @Expect(boolField(out[0], "ok"), true)
}

@Test
func testAllListenersOfEventAreCalled(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith([], ["tick"], out)
    let hits = ArrayList<String>()
    hub.listenEvent("tick", { _ => synchronized(TEST_SINK_LOCK) { hits.add("a") } })
    hub.listenEvent("tick", { _ => synchronized(TEST_SINK_LOCK) { hits.add("b") } })
    hub.handleRawMessage("{\"type\":\"emit\",\"id\":23,\"event\":\"tick\",\"payload\":{}}")
    waitSink(out, 1)
    @Expect(hits.size, 2)
}

@Test
func testFailingListenerDoesNotBreakOthers(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith([], ["tick"], out)
    hub.listenEvent("tick", boomListener)
    let ok = ArrayList<Bool>()
    hub.listenEvent("tick", { _ => synchronized(TEST_SINK_LOCK) { ok.add(true) } })
    hub.handleRawMessage("{\"type\":\"emit\",\"id\":24,\"event\":\"tick\",\"payload\":{}}")
    waitSink(out, 1)
    // 事件是广播语义：一个听众抛错不该牵连其它听众，也不该让发送方收到失败
    @Expect(ok.size, 1)
    @Expect(boolField(out[0], "ok"), true)
}

@Test
func testFrontendEmitDeniedEventIsRejected(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith([], ["tick"], out)
    // 未授权的事件：与命令一样在调用线程上同步拒绝，不必等 worker
    hub.handleRawMessage("{\"type\":\"emit\",\"id\":22,\"event\":\"nope\",\"payload\":{}}")
    @Expect(out.size, 1)
    @Expect(boolField(out[0], "ok"), false)
    @Expect(strField(out[0], "error"), "event not allowed: nope")
}

@Test
func testFrontendEmitWithoutListenerStillResolves(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith([], ["tick"], out)
    // 授权了但没人听：不是错误（Tauri 同样不报），发送方照常拿到 resolve
    hub.handleRawMessage("{\"type\":\"emit\",\"id\":25,\"event\":\"tick\",\"payload\":{}}")
    waitSink(out, 1)
    @Expect(out.size, 1)
    @Expect(boolField(out[0], "ok"), true)
}

@Test
func testMalformedMessageWithIdIsRejected(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith([], ["tick"], out)
    // 未知报文类型但 id 可读：回一条 reject，前端那条 promise 不再永久 pending
    hub.handleRawMessage("{\"type\":\"wat\",\"id\":31}")
    @Expect(out.size, 1)
    @Expect(boolField(out[0], "ok"), false)
    @Expect(strField(out[0], "error"), "invalid IPC message")
}

@Test
func testEventCarriesWindowLabelOrNothingWhenBroadcast(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith([], ["tick"], out)
    hub.emitToWindow("tick", JsonObject(), "main")
    @Expect(strField(out[0], "window"), "main")
    hub.emitAll("tick", JsonObject())
    // 广播不带 window 字段：页面里由桥放行（多窗口过滤靠它）
    @Expect(JsonValue.fromStr(out[1]).asObject().get("window").isNone(), true)
}
