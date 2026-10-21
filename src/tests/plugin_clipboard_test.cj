package cjTauri.tests

import cjTauri.*
import cjTauri.plugins.clipboard.*
import std.collection.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * clipboard 插件单元测试：命令面 / shim / 命名权限集闸门 / 参数校验 / 未装配宿主的可读错误
 * + 「宿主已装配」时的读写转交（用 FakeHost 替身记痕）。
 *
 * 真剪贴板读写落在 C 桥（GTK / Win32 的剪贴板调用必须在宿主 UI 线程），归实机验证
 * （examples/plugin-clipboard）；这里只锁「不碰剪贴板就能判定的入口逻辑」。
 */

/** 造 { text } 参数 */
func clipTextArgs(text: String): JsonObject {
    var o = JsonObject()
    o.put("text", JsonString(text))
    return o
}

/** 取一条「已装配宿主」的命令处理器：剪贴板命令要先经 attachHost 才有宿主可用 */
func clipCmdWithHost(short: String, host: FakeHost): CommandHandler {
    let _ = short
    let c = ClipboardCommands()
    c.attachHost(host)
    return c
}

/** 直接调命令，把 CommandException 的原文取出来（没抛就返回空串）*/
func clipErrOf(handler: CommandHandler, cmd: String, args: JsonObject): String {
    try {
        handler.handle(cmd, args, IpcContext("main", IpcHub()))
        return ""
    } catch (e: CommandException) {
        return e.message
    }
}

@Test
func testClipboardPluginSurface(): Unit {
    let p = ClipboardPlugin()
    @Expect(p.name(), "clipboard")
    let names = pluginCommandNames(p)
    @Expect(names.size, 2)
    var hasRead = false
    var hasWrite = false
    for (n in names) {
        if (n == "clipboard:read") {
            hasRead = true
        }
        if (n == "clipboard:write") {
            hasWrite = true
        }
    }
    @Expect(hasRead, true)
    @Expect(hasWrite, true)
}

@Test
func testClipboardPluginShimTargetsItsOwnNamespace(): Unit {
    let js = ClipboardPlugin().jsShim()
    @Expect(js.contains("t.clipboard"), true)
    @Expect(js.contains("'clipboard:write'"), true)
    @Expect(js.contains("'clipboard:read'"), true)
}

@Test
func testClipboardPluginDeclaresPermissionSets(): Unit {
    let sets = pluginPermissionSets(ClipboardPlugin())
    @Expect(sets.size, 2)
    // readonly 只放行读：剪贴板里可能有用户敏感内容，「只写不读」是合理的最小授权面
    let ro = sets.get("clipboard:readonly").getOrThrow()
    @Expect(ro.size, 1)
    @Expect(ro[0], "clipboard:read")
    @Expect(sets.get("clipboard:default").getOrThrow().size, 2)
}

@Test
func testClipboardPermissionSetGatesCommands(): Unit {
    let out = ArrayList<String>()
    let reg = CapabilityRegistry()
    reg.addFromJson(JsonValue.fromStr("{\"identifier\":\"c\",\"permissions\":[\"clipboard:readonly\"]}"))
    let hub = hubWithRegistry(reg, out)
    registerPluginCommands(hub, ClipboardPlugin())
    registerPluginPermissionSets(reg, ClipboardPlugin())

    // 集内命令放行：这条会走到「宿主未装配」的业务错误，而不是「未授权」
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":41,\"cmd\":\"clipboard:read\"}")
    waitSink(out, 1)
    @Expect(out.size, 1)
    @Expect(strField(out[0], "error").contains("command not allowed"), false)

    // 集外命令仍拒：readonly 不夹带写能力
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":42,\"cmd\":\"clipboard:write\",\"args\":{\"text\":\"x\"}}")
    @Expect(out.size, 2)
    @Expect(strField(out[1], "error"), "command not allowed: clipboard:write")
}

@Test
func testClipboardWriteRequiresTextArgument(): Unit {
    let cmd = ClipboardPlugin().commands().get("write").getOrThrow()
    let ctx = IpcContext("main", IpcHub())
    var threw = false
    try {
        cmd.handle("clipboard:write", JsonObject(), ctx)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("missing argument \"text\""), true)
    }
    @Expect(threw, true)
}

@Test
func testClipboardWriteRejectsNonString(): Unit {
    var args = JsonObject()
    args.put("text", JsonInt(7))
    let cmd = ClipboardPlugin().commands().get("write").getOrThrow()
    let ctx = IpcContext("main", IpcHub())
    var threw = false
    try {
        cmd.handle("clipboard:write", args, ctx)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("must be a string"), true)
    }
    @Expect(threw, true)
}

@Test
func testClipboardWithoutHostIsReadableError(): Unit {
    // 没经 .plugin() 装配（没有宿主）时调用：给的是可读错误，而不是空指针崩掉
    @Expect(clipErrOf(ClipboardPlugin().commands().get("read").getOrThrow(), "clipboard:read", JsonObject())
        .contains("宿主未装配"), true)
    @Expect(clipErrOf(ClipboardPlugin().commands().get("write").getOrThrow(), "clipboard:write",
        clipTextArgs("hi")).contains("宿主未装配"), true)
}

@Test
func testClipboardRejectsUnknownCommand(): Unit {
    @Expect(clipErrOf(ClipboardPlugin().commands().get("read").getOrThrow(), "clipboard:nope", JsonObject())
        .contains("unknown clipboard command"), true)
}

@Test
func testClipboardWriteHandsTextToHost(): Unit {
    let host = FakeHost("main")
    let cmd = clipCmdWithHost("write", host)
    let r = cmd.handle("clipboard:write", clipTextArgs("hello 剪贴板"), IpcContext("main", IpcHub()))
    // 成功回 JsonNull（写命令没有返回值，与 Tauri 的 writeText 对齐）
    match (r.kind()) {
        case JsonKind.JsNull => ()
        case _ =>
            @Expect(false, true) // 成功路径不该回别的类型
    }
    @Expect(host.clipboardWritten, "hello 剪贴板")
}

@Test
func testClipboardReadReturnsHostValue(): Unit {
    let host = FakeHost("main")
    let cmd = clipCmdWithHost("read", host)

    // 空 / 非文本 / 平台失败都归 None，转成 JsonNull——这是合法结果，不是错误
    let empty = cmd.handle("clipboard:read", JsonObject(), IpcContext("main", IpcHub()))
    match (empty.kind()) {
        case JsonKind.JsNull => ()
        case _ => @Expect(false, true)
    }

    // 有内容：原样转成 JsonString 回给前端
    host.clipboardReadValue = Some("pasted 文本")
    let got = cmd.handle("clipboard:read", JsonObject(), IpcContext("main", IpcHub()))
    @Expect(got.asString().getValue(), "pasted 文本")
}

/** 桩侧「label → 宿主」解析器见 plugin_dialog_test.cj 的 routeProbeHost（同包可见） */
@Test
func testClipboardRoutesToTheWindowThatAsked(): Unit {
    // 与 dialog 同一条契约：报文里的 window 决定交给哪个宿主。
    // 只装单槽时第二扇窗的读写会落到默认窗那个宿主上（多窗口下的串台来源）。
    let mainHost = FakeHost("main")
    let secondHost = FakeHost("second")
    let cmds = ClipboardCommands()
    cmds.attachHost(mainHost)
    cmds.attachHostResolver({ label => routeProbeHost(label, mainHost, secondHost) })

    cmds.handle("clipboard:write", clipTextArgs("second 的剪贴板"), IpcContext("second", IpcHub()))
    @Expect(secondHost.clipboardWritten, "second 的剪贴板")
    // 关键断言：另一扇窗的宿主一点都没被碰到
    @Expect(mainHost.clipboardWritten, "")

    // 读同样按窗口解析
    secondHost.clipboardReadValue = Some("from second")
    let got = cmds.handle("clipboard:read", JsonObject(), IpcContext("second", IpcHub()))
    @Expect(got.asString().getValue(), "from second")
    @Expect(mainHost.clipboardReadValue.isNone(), true)
}

@Test
func testClipboardReportsUnknownWindowInsteadOfFallingBack(): Unit {
    let mainHost = FakeHost("main")
    let secondHost = FakeHost("second")
    let cmds = ClipboardCommands()
    cmds.attachHost(mainHost)
    cmds.attachHostResolver({ label => routeProbeHost(label, mainHost, secondHost) })

    var threw = false
    try {
        cmds.handle("clipboard:write", clipTextArgs("x"), IpcContext("ghost", IpcHub()))
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("ghost"), true)
    }
    @Expect(threw, true)
    // 报错之后两个宿主都没被写过：不回落单槽，宁可不写
    @Expect(mainHost.clipboardWritten, "")
    @Expect(secondHost.clipboardWritten, "")
}
