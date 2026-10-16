package cjTauri.tests

import cjTauri.*
import cjTauri.plugins.ws.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * ws 插件的策略层用例（帧 IO 归实机：真连接需要对端，单测不起网络）。
 * urlHostOf 的 ws/wss 用例也放这里（核心共享层函数，随 ws 插件落地一起验）。
 */

@Test
func testUrlHostOfAcceptsWsSchemes(): Unit {
    // cjh web 的默认端点形状：ws://127.0.0.1:8765/ws
    @Expect(urlHostOf("ws://127.0.0.1:8765/ws"), "127.0.0.1")
    @Expect(urlHostOf("wss://Example.COM/ws"), "example.com")
}

@Test
func testWsPluginDeclarations(): Unit {
    let p = WsPlugin()
    @Expect(p.name(), "ws")
    @Expect(p.scopeAware(), true)
    // 权限集 default = connect + send + close：集声明 != 放行，清单引用才生效
    @Expect(p.permissions().contains("default"), true)
    let cmds = p.commands()
    @Expect(cmds.contains("connect"), true)
    @Expect(cmds.contains("send"), true)
    @Expect(cmds.contains("close"), true)
    // 推两个事件（frame / state），无前端 shim
    @Expect(p.events().size == 2, true)
    @Expect(p.jsShim().size == 0, true)
}

@Test
func testWsStateConstants(): Unit {
    @Expect(CJ_WS_STATE_CONNECTED, "connected")
    @Expect(CJ_WS_STATE_CLOSED, "closed")
}
