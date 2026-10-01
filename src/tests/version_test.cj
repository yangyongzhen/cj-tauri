package cjTauri.tests

import cjTauri.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 版本与内置命令的一致性测试。
 * 版本号的权威目标是 CHANGELOG.md，四处常量由 scripts/check-version.sh 巡检；
 * 这里只锁「代码里的单一来源不漂移」。
 */

@Test
func testVersionConstantNotEmpty(): Unit {
    @Expect(CJ_TAURI_VERSION.size > 0, true)
}

@Test
func testSystemVersionReportsConstant(): Unit {
    let commands = SystemCommands()
    let v = commands.handle("system:version", JsonObject(), IpcContext("main", IpcHub()))
    let o = v.asObject()
    // 命令报告的版本必须就是常量本身（防止有人改了其中一处）
    @Expect(o.get("version").getOrThrow().asString().getValue(), CJ_TAURI_VERSION)
    @Expect(o.get("name").getOrThrow().asString().getValue(), "cj-tauri")
    @Expect(o.get("platform").getOrThrow().asString().getValue(), currentPlatform())
    @Expect(currentPlatform().size > 0, true)
}

@Test
func testSystemPingEchoAndUnknown(): Unit {
    let commands = SystemCommands()
    let ctx = IpcContext("main", IpcHub())
    @Expect(commands.handle("system:ping", JsonObject(), ctx).asString().getValue(), "pong")

    var args = JsonObject()
    args.put("who", JsonString("cj"))
    let echoed = commands.handle("system:echo", args, ctx).asObject()
    @Expect(echoed.get("who").getOrThrow().asString().getValue(), "cj")

    // 未定义的 system:* 走 CommandException，前端拿到的是这句原文
    var thrown = ""
    try {
        commands.handle("system:nope", JsonObject(), ctx)
    } catch (e: CommandException) {
        thrown = e.message
    }
    @Expect(thrown, "unknown system command: system:nope")
}

@Test
func testWindowConfigDefaultsMatchBridgeHardcoding(): Unit {
    // 默认值必须与桥里此前的硬编码一致（标题 cj-tauri / 900x640），否则不调 window() 的应用会变样
    let def = WindowConfig()
    @Expect(def.title, "cj-tauri")
    @Expect(def.width, 900)
    @Expect(def.height, 640)
    @Expect(def.devTools, true)

    let custom = WindowConfig("我的应用", 1200, 800)
    @Expect(custom.title, "我的应用")
    @Expect(custom.width, 1200)
    @Expect(custom.height, 800)
}
