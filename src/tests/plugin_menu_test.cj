package cjTauri.tests

import cjTauri.*
import std.collection.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * menu 插件的声明面与参数校验。
 *
 * 「改状态真的落到宿主上」要构造 TauriApp（构造即建宿主对象），端到端由 examples/menu 实机覆盖；
 * 这里钉住的是**插件声明**（命名空间全名 / 事件 / 命名权限集 / shim 只动自己的命名空间）与
 * 参数校验的可读报错——这两块是插件作者与前端直接对着看的东西，写错了最难自查。
 */

/** 未 attach 的处理器：参数校验应比「未装配到应用」先报，故这里断言的是前者的报错 */
func menuCmdError(handler: MenuCommands, cmd: String, argsJson: String): String {
    let args = JsonValue.fromStr(argsJson).asObject()
    try {
        handler.handle(cmd, args, IpcContext("main", IpcHub()))
        return ""
    } catch (e: CommandException) {
        return e.message
    }
}

@Test
func testMenuPluginDeclaresNamespacedCommandsAndEvents(): Unit {
    let p = MenuPlugin()
    @Expect(p.name(), "menu")
    let cmds = pluginCommandNames(p)
    @Expect(cmds.size, 2)
    // HashMap 迭代顺序不定，所以按「含哪些」断言，不按位置
    @Expect(cmds.contains("menu:setChecked"), true)
    @Expect(cmds.contains("menu:setEnabled"), true)
    // 事件只声明；真正投递在 TauriApp 的 shell 分发里（页面 listen("menu:click", …)）
    let evts = pluginEventNames(p)
    @Expect(evts.size, 1)
    @Expect(evts[0], "menu:click")
}

@Test
func testMenuPluginPermissionSetExpandsToFullNames(): Unit {
    // 集里写的是短名，框架展开成全名——清单里引用 "menu:state" 就等于放行这两条
    let sets = pluginPermissionSets(MenuPlugin())
    let members = sets.get("menu:state").getOrThrow()
    @Expect(members.size, 2)
    @Expect(members.contains("menu:setChecked"), true)
    @Expect(members.contains("menu:setEnabled"), true)
}

@Test
func testMenuPluginShimOnlyTouchesItsOwnNamespace(): Unit {
    let shim = MenuPlugin().jsShim()
    @Expect(shim.contains("t.menu = {"), true)
    @Expect(shim.contains("invoke('menu:setEnabled'"), true)
    @Expect(shim.contains("invoke('menu:setChecked'"), true)
    // 只挂命名空间：不覆盖 invoke / listen / emit（那是桥的地盘，插件不得改写）
    @Expect(shim.contains("t.invoke"), false)
    @Expect(shim.contains("t.listen"), false)
    @Expect(shim.contains("t.emit"), false)
}

@Test
func testMenuCommandsReportMissingArguments(): Unit {
    let h = MenuCommands()
    @Expect(menuCmdError(h, "menu:setEnabled", "{}").contains("missing argument \"id\""), true)
    @Expect(menuCmdError(h, "menu:setEnabled", "{\"id\":\"view.sidebar\"}")
        .contains("missing argument \"enabled\""), true)
    @Expect(menuCmdError(h, "menu:setChecked", "{\"id\":\"view.sidebar\"}")
        .contains("missing argument \"checked\""), true)
}

@Test
func testMenuCommandsReportWrongArgumentTypes(): Unit {
    let h = MenuCommands()
    @Expect(menuCmdError(h, "menu:setEnabled", "{\"id\":7,\"enabled\":true}")
        .contains("must be a string"), true)
    @Expect(menuCmdError(h, "menu:setEnabled", "{\"id\":\"x\",\"enabled\":\"yes\"}")
        .contains("must be a boolean"), true)
}

@Test
func testMenuCommandsReportUnattachedPlugin(): Unit {
    // 参数齐全但 handler 没被 setup() 注入 app：报的必须是「未装配」，
    // 而不是「窗口不存在」这种让人往别处查的错
    let h = MenuCommands()
    @Expect(menuCmdError(h, "menu:setEnabled", "{\"id\":\"view.sidebar\",\"enabled\":false}")
        .contains("未装配到应用"), true)
}

@Test
func testMenuCommandsRejectUnknownCommandName(): Unit {
    let h = MenuCommands()
    @Expect(menuCmdError(h, "menu:ghost", "{}").contains("unknown menu command"), true)
}
