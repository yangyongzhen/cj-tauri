package cjTauri.tests

import cjTauri.*
import cjTauri.plugins.notification.*
import std.collection.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * notification 插件单元测试：命令面 / shim / 命名权限集闸门 / 参数校验 / 未装配宿主的可读错误
 * + 「宿主已装配」时的转交（FakeHost 记痕）。
 *
 * 真通知落在 C 桥（Linux 走 freedesktop Notifications，Windows 桩阶段未实现），
 * 归实机验证；这里只锁入口逻辑。body 可省是契约的一部分，单独覆盖。
 */

/** 取一条「已装配宿主」的命令处理器 */
func notifCmdWithHost(host: FakeHost): CommandHandler {
    let c = NotificationCommands()
    c.attachHost(host)
    return c
}

func notifErrOf(handler: CommandHandler, cmd: String, args: JsonObject): String {
    try {
        handler.handle(cmd, args, IpcContext("main", IpcHub()))
        return ""
    } catch (e: CommandException) {
        return e.message
    }
}

/** 造 { title, body } */
func notifArgs(title: String, body: JsonValue): JsonObject {
    var o = JsonObject()
    o.put("title", JsonString(title))
    o.put("body", body)
    return o
}

@Test
func testNotificationPluginSurface(): Unit {
    let p = NotificationPlugin()
    @Expect(p.name(), "notification")
    let names = pluginCommandNames(p)
    @Expect(names.size, 1)
    @Expect(names[0], "notification:notify")
}

@Test
func testNotificationPluginShimTargetsItsOwnNamespace(): Unit {
    let js = NotificationPlugin().jsShim()
    @Expect(js.contains("t.notification"), true)
    @Expect(js.contains("'notification:notify'"), true)
}

@Test
func testNotificationPluginDeclaresPermissionSets(): Unit {
    let sets = pluginPermissionSets(NotificationPlugin())
    @Expect(sets.size, 1)
    let d = sets.get("notification:default").getOrThrow()
    @Expect(d.size, 1)
    @Expect(d[0], "notification:notify")
}

@Test
func testNotificationPermissionSetGatesCommand(): Unit {
    let out = ArrayList<String>()
    let reg = CapabilityRegistry()
    reg.addFromJson(JsonValue.fromStr("{\"identifier\":\"n\",\"permissions\":[\"notification:default\"]}"))
    let hub = hubWithRegistry(reg, out)
    registerPluginCommands(hub, NotificationPlugin())
    registerPluginPermissionSets(reg, NotificationPlugin())

    // 集内命令放行：走到「宿主未装配」的业务错误，而不是「未授权」
    hub.handleRawMessage(
        "{\"type\":\"invoke\",\"id\":51,\"cmd\":\"notification:notify\",\"args\":{\"title\":\"t\"}}")
    waitSink(out, 1)
    @Expect(out.size, 1)
    @Expect(strField(out[0], "error").contains("command not allowed"), false)
}

@Test
func testNotificationWithoutPermissionIsDenied(): Unit {
    let out = ArrayList<String>()
    let reg = CapabilityRegistry()
    reg.addFromJson(JsonValue.fromStr("{\"identifier\":\"empty\",\"permissions\":[]}"))
    let hub = hubWithRegistry(reg, out)
    registerPluginCommands(hub, NotificationPlugin())
    registerPluginPermissionSets(reg, NotificationPlugin())

    hub.handleRawMessage(
        "{\"type\":\"invoke\",\"id\":52,\"cmd\":\"notification:notify\",\"args\":{\"title\":\"t\"}}")
    waitSink(out, 1)
    @Expect(strField(out[0], "error"), "command not allowed: notification:notify")
}

@Test
func testNotificationRequiresTitle(): Unit {
    let cmd = NotificationPlugin().commands().get("notify").getOrThrow()
    let ctx = IpcContext("main", IpcHub())
    var threw = false
    try {
        cmd.handle("notification:notify", JsonObject(), ctx)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("missing argument \"title\""), true)
    }
    @Expect(threw, true)
}

@Test
func testNotificationRejectsNonStringTitle(): Unit {
    var args = JsonObject()
    args.put("title", JsonBool(true))
    let cmd = NotificationPlugin().commands().get("notify").getOrThrow()
    var threw = false
    try {
        cmd.handle("notification:notify", args, IpcContext("main", IpcHub()))
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("must be a string"), true)
    }
    @Expect(threw, true)
}

@Test
func testNotificationWithoutHostIsReadableError(): Unit {
    @Expect(notifErrOf(NotificationPlugin().commands().get("notify").getOrThrow(), "notification:notify",
        notifArgs("hi", JsonString("body"))).contains("宿主未装配"), true)
}

@Test
func testNotificationRejectsUnknownCommand(): Unit {
    @Expect(notifErrOf(NotificationPlugin().commands().get("notify").getOrThrow(), "notification:nope",
        JsonObject()).contains("unknown notification command"), true)
}

@Test
func testNotificationBodyIsOptional(): Unit {
    let host = FakeHost("main")
    let cmd = notifCmdWithHost(host)

    // 只给 title：body 按空串
    var onlyTitle = JsonObject()
    onlyTitle.put("title", JsonString("标题"))
    let r1 = cmd.handle("notification:notify", onlyTitle, IpcContext("main", IpcHub()))
    match (r1.kind()) {
        case JsonKind.JsNull => ()
        case _ => @Expect(false, true)
    }
    @Expect(host.notifiedArgs, "标题|")

    // body 显式 null：同样按空串（前端 o.body 传 undefined 时序列化可能落成 null）
    cmd.handle("notification:notify", notifArgs("标题2", JsonNull()), IpcContext("main", IpcHub()))
    @Expect(host.notifiedArgs, "标题2|")

    // body 有值：原样转交
    cmd.handle("notification:notify", notifArgs("标题3", JsonString("正文")), IpcContext("main", IpcHub()))
    @Expect(host.notifiedArgs, "标题3|正文")
}
