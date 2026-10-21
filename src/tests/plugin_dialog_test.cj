package cjTauri.tests

import cjTauri.*
import cjTauri.plugins.dialog.*
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

/** 造一个只带 title 的对象 */
func titleArgs(t: String): JsonObject {
    var o = JsonObject()
    o.put("title", JsonString(t))
    return o
}

@Test
func testDialogPluginSurface(): Unit {
    let p = DialogPlugin()
    @Expect(p.name(), "dialog")
    let names = pluginCommandNames(p)
    @Expect(names.size, 4)
    var hasOpen = false
    var hasSave = false
    var hasPick = false
    var hasMessage = false
    for (n in names) {
        if (n == "dialog:open") {
            hasOpen = true
        }
        if (n == "dialog:save") {
            hasSave = true
        }
        if (n == "dialog:pickFolder") {
            hasPick = true
        }
        if (n == "dialog:message") {
            hasMessage = true
        }
    }
    @Expect(hasOpen, true)
    @Expect(hasSave, true)
    @Expect(hasPick, true)
    @Expect(hasMessage, true)
}

@Test
func testDialogPluginShimTargetsItsOwnNamespace(): Unit {
    let js = DialogPlugin().jsShim()
    @Expect(js.contains("t.dialog"), true)
    @Expect(js.contains("'dialog:open'"), true)
    @Expect(js.contains("'dialog:save'"), true)
    @Expect(js.contains("'dialog:pickFolder'"), true)
    @Expect(js.contains("'dialog:message'"), true)
}

@Test
func testDialogPluginDeclaresPermissionSets(): Unit {
    let sets = pluginPermissionSets(DialogPlugin())
    @Expect(sets.size, 2)
    let files = sets.get("dialog:files").getOrThrow()
    @Expect(files.size, 3)
    var filesHasMessage = false
    for (m in files) {
        if (m == "dialog:message") {
            filesHasMessage = true
        }
    }
    // 只想挑文件（或目录）的应用不该顺带拿到「弹任意提示框」
    @Expect(filesHasMessage, false)
    @Expect(sets.get("dialog:default").getOrThrow().size, 4)
}

@Test
func testDialogPickFolderGoesToFolderDialog(): Unit {
    // 选目录走的是独立的宿主方法（不是文件框那条）：桩把标题记下来，用例断言转交的确实是 title
    let host = FakeHost("main")
    let cmds = DialogCommands()
    cmds.attachHost(host)
    let ctx = IpcContext("main", IpcHub())

    cmds.handle("dialog:pickFolder", titleArgs("选工作区"), ctx)
    @Expect(host.folderDialogTitle, "选工作区")

    // 不给标题时兜底，别把空标题交给平台（空串会让平台用自己的默认文案）
    cmds.handle("dialog:pickFolder", JsonObject(), ctx)
    @Expect(host.folderDialogTitle, "选择文件夹")

    // 用户取消（桩恒回空串）时命令的返回也是空串——上游按「没选」处理
    let r = cmds.handle("dialog:pickFolder", JsonObject(), ctx)
    @Expect(r.toString(), "\"\"")
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
    waitSink(out, 1)
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

/**
 * 桩侧「label → 宿主」解析器（模拟 `app.hostOf`）
 *
 * 用独立函数而不是内联 lambda：多分支要能 return，写成独立函数最稳。
 */
func routeProbeHost(label: String, mainHost: FakeHost, secondHost: FakeHost): Option<WebViewHost> {
    if (label == "second") {
        return Some(secondHost)
    }
    if (label == "main") {
        return Some(mainHost)
    }
    return None
}

@Test
func testDialogRoutesToTheWindowThatAsked(): Unit {
    // 多窗口的核心契约：报文里的 window 决定交给哪个宿主。
    // 只用单槽（装配时那一个宿主）时，第二扇窗的框会排进 main 的队列——
    // 2026-10-20 鸿蒙真机实测的串台就是这么来的（docs/鸿蒙ArkWeb接入踩坑.md §10.12）。
    let mainHost = FakeHost("main")
    let secondHost = FakeHost("second")
    let cmds = DialogCommands()
    cmds.attachHost(mainHost)
    cmds.attachHostResolver({ label => routeProbeHost(label, mainHost, secondHost) })
    let hub = IpcHub()

    cmds.handle("dialog:message", messageArgs("second 的框"), IpcContext("second", hub))
    @Expect(secondHost.messageDialogArgs.contains("second 的框"), true)
    @Expect(secondHost.messageDialogArgs.contains("|second 的框"), true)
    // 关键断言：另一扇窗**一点都没被碰到**
    @Expect(mainHost.messageDialogArgs, "")

    cmds.handle("dialog:message", messageArgs("main 的框"), IpcContext("main", hub))
    @Expect(mainHost.messageDialogArgs.contains("main 的框"), true)
    // 反向也成立：second 那一份不被覆盖（各持一份状态，不是共用一个槽）
    @Expect(secondHost.messageDialogArgs.contains("second 的框"), true)
}

@Test
func testDialogReportsUnknownWindowInsteadOfFallingBack(): Unit {
    // 解析器在场而窗口没登记时如实报错：悄悄回落到单槽正是串台的来源
    let mainHost = FakeHost("main")
    let secondHost = FakeHost("second")
    let cmds = DialogCommands()
    cmds.attachHost(mainHost)
    cmds.attachHostResolver({ label => routeProbeHost(label, mainHost, secondHost) })
    var threw = false
    try {
        cmds.handle("dialog:message", messageArgs("谁的框"), IpcContext("ghost", IpcHub()))
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("ghost"), true)
    }
    @Expect(threw, true)
    // 报错之后两个宿主都没被写过：宁可不弹，也不弹到别人窗口里
    @Expect(mainHost.messageDialogArgs, "")
    @Expect(secondHost.messageDialogArgs, "")
}
