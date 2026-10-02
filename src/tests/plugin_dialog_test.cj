package cjTauri.tests

import cjTauri.*
import std.collection.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * dialog 插件单元测试：命令面、命名权限集、参数校验、未装配宿主时的可读错误。
 * 只碰纯逻辑——原生对话框要真窗口，归实机验证（examples/plugin-dialog）。
 */

/** 造一个只带 message 的对象 */
func messageArgs(text: String): JsonObject {
    var o = JsonObject()
    o.put("message", JsonString(text))
    return o
}

@Test
func testDialogPluginSurface(): Unit {
    let p = DialogPlugin()
    @Expect(p.name(), "dialog")
    let names = pluginCommandNames(p)
    @Expect(names.size, 3)
    var hasOpen = false
    var hasSave = false
    var hasMessage = false
    for (n in names) {
        if (n == "dialog:open") {
            hasOpen = true
        }
        if (n == "dialog:save") {
            hasSave = true
        }
        if (n == "dialog:message") {
            hasMessage = true
        }
    }
    @Expect(hasOpen, true)
    @Expect(hasSave, true)
    @Expect(hasMessage, true)
}

@Test
func testDialogPluginShimTargetsItsOwnNamespace(): Unit {
    let js = DialogPlugin().jsShim()
    @Expect(js.contains("t.dialog"), true)
    @Expect(js.contains("'dialog:open'"), true)
    @Expect(js.contains("'dialog:save'"), true)
    @Expect(js.contains("'dialog:message'"), true)
}

@Test
func testDialogPluginDeclaresPermissionSets(): Unit {
    let sets = pluginPermissionSets(DialogPlugin())
    @Expect(sets.size, 2)
    let files = sets.get("dialog:files").getOrThrow()
    @Expect(files.size, 2)
    var filesHasMessage = false
    for (m in files) {
        if (m == "dialog:message") {
            filesHasMessage = true
        }
    }
    // 只想挑文件的应用不该顺带拿到「弹任意提示框」
    @Expect(filesHasMessage, false)
    @Expect(sets.get("dialog:default").getOrThrow().size, 3)
}

@Test
func testDialogPermissionSetGatesCommands(): Unit {
    let out = ArrayList<String>()
    let reg = CapabilityRegistry()
    reg.addFromJson(JsonValue.fromStr("{\"identifier\":\"d\",\"permissions\":[\"dialog:files\"]}"))
    let hub = hubWithRegistry(reg, out)
    registerPluginCommands(hub, DialogPlugin())
    registerPluginPermissionSets(reg, DialogPlugin())

    // 集内命令放行：这条会真的去弹对话框，测试环境没有宿主 → 报的是业务错误，不是「未授权」
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":21,\"cmd\":\"dialog:open\"}")
    @Expect(out.size, 1)
    let firstError = strField(out[0], "error")
    @Expect(firstError.contains("command not allowed"), false)

    // 集外命令仍拒：放行的是那一组，不是整个插件
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":22,\"cmd\":\"dialog:message\"}")
    @Expect(out.size, 2)
    @Expect(strField(out[1], "error"), "command not allowed: dialog:message")
}

@Test
func testDialogMessageRequiresTextArgument(): Unit {
    let cmds = DialogPlugin().commands()
    let ctx = IpcContext("main", IpcHub())
    var threw = false
    try {
        cmds.get("message").getOrThrow().handle("dialog:message", JsonObject(), ctx)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("missing argument \"message\""), true)
    }
    @Expect(threw, true)
}

@Test
func testDialogWithoutHostIsReadableError(): Unit {
    // 没经 .plugin() 装配（没有宿主）时调用：给的是可读错误，而不是空指针崩掉
    let cmds = DialogPlugin().commands()
    let ctx = IpcContext("main", IpcHub())
    var openThrew = false
    try {
        cmds.get("open").getOrThrow().handle("dialog:open", JsonObject(), ctx)
    } catch (e: CommandException) {
        openThrew = true
        @Expect(e.message.contains("宿主未装配"), true)
    }
    @Expect(openThrew, true)

    var msgThrew = false
    try {
        cmds.get("message").getOrThrow().handle("dialog:message", messageArgs("hi"), ctx)
    } catch (e: CommandException) {
        msgThrew = true
    }
    @Expect(msgThrew, true)
}

@Test
func testDialogRejectsUnknownCommand(): Unit {
    let cmds = DialogPlugin().commands()
    let ctx = IpcContext("main", IpcHub())
    var threw = false
    try {
        cmds.get("open").getOrThrow().handle("dialog:nope", JsonObject(), ctx)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("unknown dialog command"), true)
    }
    @Expect(threw, true)
}
