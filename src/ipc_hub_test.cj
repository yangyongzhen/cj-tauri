package cjTauri

import std.collection.*
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
    hub.jsSink = { s => sink.add(s) }
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
    // type 不是 invoke：桥的 emit 占位实现就落在这一支
    @Expect(InvokeRequest.parse("{\"type\":\"emit\",\"event\":\"x\"}").isNone(), true)
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
    @Expect(out.size, 1)
    @Expect(strField(out[0], "error"), "command not allowed: greet")
}

@Test
func testHubRejectsUnregisteredCommand(): Unit {
    let out = ArrayList<String>()
    // 放行了但没注册：与「未放行」是两条不同的报错，容易混淆
    let hub = hubWith(["ghost"], [], out)
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":5,\"cmd\":\"ghost\"}")
    @Expect(out.size, 1)
    @Expect(strField(out[0], "error"), "command not registered: ghost")
}

@Test
func testHubReportsCommandException(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith(["boom"], [], out)
    hub.register("boom", BoomHandler())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":6,\"cmd\":\"boom\"}")
    @Expect(out.size, 1)
    @Expect(strField(out[0], "error"), "boom")
}

@Test
func testHubReportsUnexpectedException(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith(["crash"], [], out)
    hub.register("crash", CrashHandler())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":8,\"cmd\":\"crash\"}")
    @Expect(out.size, 1)
    // 预期外的异常统一加前缀，前端据此区分「业务拒绝」与「崩了」
    @Expect(strField(out[0], "error").startsWith("command failed:"), true)
}

@Test
func testHubIgnoresMalformedMessage(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith(["greet"], [], out)
    hub.register("greet", OkHandler())
    // emit 的消息类型不是 invoke：不投递、不回写（前端 emit 目前是占位实现）
    hub.handleRawMessage("{\"type\":\"emit\",\"event\":\"tick\",\"payload\":{}}")
    hub.handleRawMessage("garbage")
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
