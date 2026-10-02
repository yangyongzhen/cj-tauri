package cjTauri.tests

import cjTauri.*
import std.collection.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * shell 插件单元测试：命令面、命名权限集（allow-open 不含 exec）、参数校验、可读错误、输出捕获与解码。
 * 真正「交给系统默认程序打开」要桌面环境，归实机验证（examples/plugin-shell）；这里只跑不起窗口的部分。
 * 唯一会真的起子进程的是 testShellExecCapturesOutputAndExitCode：只跑 `sh`，且仅在 Linux 上执行。
 */

@Test
func testShellPluginSurface(): Unit {
    let p = ShellPlugin()
    @Expect(p.name(), "shell")
    let names = pluginCommandNames(p)
    @Expect(names.size, 2)
    var hasOpen = false
    var hasExec = false
    for (n in names) {
        if (n == "shell:open") {
            hasOpen = true
        }
        if (n == "shell:exec") {
            hasExec = true
        }
    }
    @Expect(hasOpen, true)
    @Expect(hasExec, true)
}

@Test
func testShellPluginShimTargetsItsOwnNamespace(): Unit {
    let js = ShellPlugin().jsShim()
    @Expect(js.contains("t.shell"), true)
    @Expect(js.contains("'shell:open'"), true)
    @Expect(js.contains("'shell:exec'"), true)
}

@Test
func testShellPluginDeclaresPermissionSets(): Unit {
    let sets = pluginPermissionSets(ShellPlugin())
    @Expect(sets.size, 2)
    let openOnly = sets.get("shell:allow-open").getOrThrow()
    @Expect(openOnly.size, 1)
    @Expect(openOnly[0], "shell:open")
    let all = sets.get("shell:default").getOrThrow()
    @Expect(all.size, 2)
    var allHasExec = false
    for (m in all) {
        if (m == "shell:exec") {
            allHasExec = true
        }
    }
    @Expect(allHasExec, true)
    // 只想「打开链接 / 文件」的应用不该顺带拿到执行能力
    var openOnlyHasExec = false
    for (m in openOnly) {
        if (m == "shell:exec") {
            openOnlyHasExec = true
        }
    }
    @Expect(openOnlyHasExec, false)
}

@Test
func testShellPermissionSetGatesCommands(): Unit {
    let out = ArrayList<String>()
    let reg = CapabilityRegistry()
    reg.addFromJson(JsonValue.fromStr("{\"identifier\":\"s\",\"permissions\":[\"shell:allow-open\"]}"))
    let hub = hubWithRegistry(reg, out)
    registerPluginCommands(hub, ShellPlugin())
    registerPluginPermissionSets(reg, ShellPlugin())

    // 集内命令放行：故意不传 target，报的应是业务错误（参数校验），而不是「未授权」
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":31,\"cmd\":\"shell:open\"}")
    waitSink(out, 1)
    @Expect(out.size, 1)
    let firstError = strField(out[0], "error")
    @Expect(firstError.contains("command not allowed"), false)
    @Expect(firstError.contains("missing argument \"target\""), true)

    // 集外命令仍拒：allow-open 放行的是「打开」，不是整个插件
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":32,\"cmd\":\"shell:exec\"}")
    @Expect(out.size, 2)
    @Expect(strField(out[1], "error"), "command not allowed: shell:exec")
}

@Test
func testShellExecRequiresProgram(): Unit {
    let cmds = ShellPlugin().commands()
    let ctx = IpcContext("main", IpcHub())
    var threw = false
    try {
        cmds.get("exec").getOrThrow().handle("shell:exec", JsonObject(), ctx)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("missing argument \"program\""), true)
    }
    @Expect(threw, true)
}

@Test
func testShellOpenRejectsEmptyTarget(): Unit {
    let cmds = ShellPlugin().commands()
    let ctx = IpcContext("main", IpcHub())
    let args = JsonValue.fromStr("{\"target\":\"\"}").asObject()
    var threw = false
    try {
        cmds.get("open").getOrThrow().handle("shell:open", args, ctx)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("must not be empty"), true)
    }
    @Expect(threw, true)
}

@Test
func testShellExecRejectsNonStringArgs(): Unit {
    let cmds = ShellPlugin().commands()
    let ctx = IpcContext("main", IpcHub())
    // args 里混进数字：宁可报错也不要悄悄丢掉——否则页面以为传了参数，实际没传
    let args = JsonValue.fromStr("{\"program\":\"echo\",\"args\":[1]}").asObject()
    var threw = false
    try {
        cmds.get("exec").getOrThrow().handle("shell:exec", args, ctx)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("must contain only strings"), true)
    }
    @Expect(threw, true)
}

@Test
func testShellExecMissingProgramIsReadableError(): Unit {
    // 程序不存在时给的是可读的 CommandException（含系统原文），而不是让异常穿透到 IPC 层
    let cmds = ShellPlugin().commands()
    let ctx = IpcContext("main", IpcHub())
    let args = JsonValue.fromStr("{\"program\":\"cj-tauri-no-such-program-xyz\"}").asObject()
    var threw = false
    try {
        cmds.get("exec").getOrThrow().handle("shell:exec", args, ctx)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("shell:exec failed"), true)
    }
    @Expect(threw, true)
}

@Test
func testShellExecCapturesOutputAndExitCode(): Unit {
    // 真起一个子进程取回 stdout / stderr / 退出码。用 sh 保证两件事同时可测：分流与退出码。
    // 只在 Linux 跑：Windows 上 sh 不保证存在（`echo` 是 cmd 内建、不是可执行文件），
    // 这台机器的实测环境是 Linux，不在没验证过的平台上假装通过。
    if (currentPlatform() != "linux") {
        return
    }
    let cmds = ShellPlugin().commands()
    let ctx = IpcContext("main", IpcHub())
    let args = JsonValue.fromStr(
        "{\"program\":\"sh\",\"args\":[\"-c\",\"echo out; echo err 1>&2; exit 3\"]}").asObject()
    let r = cmds.get("exec").getOrThrow().handle("shell:exec", args, ctx).asObject()
    @Expect(r.get("code").getOrThrow().asInt().getValue(), 3)
    @Expect(r.get("stdout").getOrThrow().asString().getValue().contains("out"), true)
    @Expect(r.get("stderr").getOrThrow().asString().getValue().contains("err"), true)
}

@Test
func testDecodeCapturedFallsBackForNonUtf8(): Unit {
    // 子进程往 stdout 写二进制是常事：解码失败要退化成摘要，不能让整条命令崩掉
    let bad = Array<Byte>(3, repeat: 255)
    let text = decodeCaptured(bad)
    @Expect(text.contains("不是合法 UTF-8"), true)
}

@Test
func testDecodeCapturedTruncatesLongOutput(): Unit {
    // 超过上限的输出截断并标注，避免一条命令把几十 MB 灌进 IPC 消息
    let big = Array<Byte>(SHELL_MAX_CAPTURE_BYTES + 10, repeat: 65)
    let text = decodeCaptured(big)
    @Expect(text.contains("已截断"), true)
    // 没超上限时不该出现标注
    let small = Array<Byte>(4, repeat: 65)
    @Expect(decodeCaptured(small).contains("已截断"), false)
}
