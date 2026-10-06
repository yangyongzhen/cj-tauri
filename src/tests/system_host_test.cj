package cjTauri.tests

import cjTauri.*
import std.collection.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 内置命令 system:host 的用例。
 *
 * 覆盖的是「能力位 → 具名布尔 JSON」这一段：能力位从调用窗口的宿主来，经 hub 注入的取值通道
 * （生产环境里由 TauriApp 接到 hostCapabilities()）变成 HostCapabilities。用例不建窗口，
 * 替身就是那条注入通道——顺带钉住「system:host 走的是通道，不是 hub 自己去摸窗口注册表」。
 *
 * 断言一律**解析 JSON 再取字段**（不靠子串）：序列化格式（空白、键序）不是契约，字段值是。
 */

/** 造一个「通道给 bits」的 hub + 会话上下文（window = main） */
func hostCtxWith(bits: Int32, asked: ArrayList<String>): IpcContext {
    let hub = IpcHub()
    hub.hostCapabilitiesSink = { label =>
        asked.add(label)
        bits
    }
    return IpcContext(DEFAULT_WINDOW_LABEL, hub)
}

@Test
func testSystemHostReportsNamedBooleansForInjectedBits(): Unit {
    let asked = ArrayList<String>()
    // 有菜单 + 有托盘、没有拖入：三位各自独立翻名，不能整体按 true/false 一刀切
    let ctx = hostCtxWith(CJ_CAP_MENU | CJ_CAP_TRAY, asked)
    let data = SystemCommands().handle("system:host", JsonObject(), ctx).asObject()
    @Expect(data.get("menu").getOrThrow().asBool().getValue(), true)
    @Expect(data.get("tray").getOrThrow().asBool().getValue(), true)
    @Expect(data.get("dragDrop").getOrThrow().asBool().getValue(), false)
    // platform 由仓颉侧条件编译给（windows / linux），不该是空串
    @Expect(data.get("platform").getOrThrow().asString().getValue().size > 0, true)
    // 取的是**发起命令那个窗口**的能力位
    @Expect(asked[0], DEFAULT_WINDOW_LABEL)
}

@Test
func testSystemHostReportsAllFalseWhenPlatformHasNothing(): Unit {
    let asked = ArrayList<String>()
    let ctx = hostCtxWith(0, asked)
    let data = SystemCommands().handle("system:host", JsonObject(), ctx).asObject()
    @Expect(data.get("menu").getOrThrow().asBool().getValue(), false)
    @Expect(data.get("tray").getOrThrow().asBool().getValue(), false)
    @Expect(data.get("dragDrop").getOrThrow().asBool().getValue(), false)
}

@Test
func testSystemHostResolvesThroughHubWhenDeclared(): Unit {
    // 三处联动的第三处：清单里声明了 system:host，前端才调得到（走完整 IPC 链路 + 异步分发）
    let out = ArrayList<String>()
    let hub = hubWith(["system:host"], [], out)
    hub.hostCapabilitiesSink = { _ => CJ_CAP_MENU }
    hub.register("system:host", SystemCommands())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":21,\"cmd\":\"system:host\"}")
    waitSink(out, 1)
    let reply = JsonValue.fromStr(out[0]).asObject()
    @Expect(reply.get("ok").getOrThrow().asBool().getValue(), true)
    let data = reply.get("data").getOrThrow().asObject()
    @Expect(data.get("menu").getOrThrow().asBool().getValue(), true)
}

@Test
func testSystemHostIsDeniedWithoutCapability(): Unit {
    // 三处联动缺了清单那一处：能力清单没声明 system:host → 调用线程上同步拒绝
    let out = ArrayList<String>()
    let hub = hubWith([], [], out)
    hub.hostCapabilitiesSink = { _ => CJ_CAP_MENU }
    hub.register("system:host", SystemCommands())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":23,\"cmd\":\"system:host\"}")
    waitSink(out, 1)
    @Expect(out[0].contains("command not allowed"), true)
}
