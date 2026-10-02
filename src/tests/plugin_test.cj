package cjTauri.tests

import cjTauri.*
import std.collection.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 插件体系单元测试：命名空间前缀、接口默认实现、JS 汇总与 HTML 注入位置、fs 插件的读写。
 * 纯逻辑为主（不创建窗口），可在无 GUI 环境跑；文件用例只碰 /tmp 下的固定路径。
 */

/** 只实现必写成员的最小插件：用来验证接口默认实现（events / jsShim / setup）够用 */
class MiniPlugin <: Plugin {
    public init() {}

    public func name(): String {
        return "mini"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        m.add("ping", PluginEchoHandler())
        return m
    }
}

/** 带事件与前端 shim 的插件 */
class DemoPlugin <: Plugin {
    public init() {}

    public func name(): String {
        return "demo"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        m.add("do", PluginEchoHandler())
        return m
    }

    public func events(): ArrayList<String> {
        let e = ArrayList<String>()
        e.add("changed")
        return e
    }

    public func jsShim(): String {
        return "window.__CJ_TAURI__.demo = {};\n"
    }
}

/** 回显命令全名，便于断言「前端调到的到底是哪个名字」 */
class PluginEchoHandler <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        return JsonString("pong:${cmd}")
    }
}

/** 声明命名权限集的插件：验证「短名补前缀」「集声明 ≠ 放行」 */
class ScopedPlugin <: Plugin {
    public init() {}

    public func name(): String {
        return "scoped"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        m.add("read", PluginEchoHandler())
        m.add("write", PluginEchoHandler())
        return m
    }

    public func events(): ArrayList<String> {
        let e = ArrayList<String>()
        e.add("changed")
        return e
    }

    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let watch = ArrayList<String>()
        watch.add("read")                 // 短名：应补成 scoped:read
        watch.add("scoped:changed")       // 全名：原样保留
        m.add("watch", watch)
        return m
    }
}

/** 用给定能力注册中心装配的 hub（命名权限集用例用；不碰宿主层） */
func hubWithRegistry(reg: CapabilityRegistry, sink: ArrayList<String>): IpcHub {
    let hub = IpcHub()
    hub.setCapabilities(reg)
    hub.jsSink = { s => sink.add(s) }
    return hub
}

/** 造一个只有 path 的对象 */
func pathArgs(path: String): JsonObject {
    var o = JsonObject()
    o.put("path", JsonString(path))
    return o
}

@Test
func testPluginNameValidation(): Unit {
    @Expect(isValidPluginName("fs"), true)
    @Expect(isValidPluginName("dialog2"), true)
    @Expect(isValidPluginName(""), false)
    @Expect(isValidPluginName("a:b"), false)
    @Expect(isValidPluginName("a：b"), false)   // 全角冒号同样不行
}

@Test
func testPluginCommandNamesArePrefixed(): Unit {
    let names = pluginCommandNames(MiniPlugin())
    @Expect(names.size, 1)
    @Expect(names[0], "mini:ping")
}

@Test
func testPluginEventNamesArePrefixed(): Unit {
    @Expect(pluginEventNames(MiniPlugin()).size, 0)   // 默认实现：没有事件
    let names = pluginEventNames(DemoPlugin())
    @Expect(names.size, 1)
    @Expect(names[0], "demo:changed")
}

@Test
func testRegisterPluginCommandsUsesNamespace(): Unit {
    let out = ArrayList<String>()
    let hub = hubWith(["mini:ping"], [], out)
    registerPluginCommands(hub, MiniPlugin())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":1,\"cmd\":\"mini:ping\"}")
    @Expect(out.size, 1)
    @Expect(strField(out[0], "type"), "resolve")
    @Expect(strField(out[0], "data"), "pong:mini:ping")
}

@Test
func testPluginDoesNotAutoGrantCapability(): Unit {
    let out = ArrayList<String>()
    // 插件把命令注册进来了，但能力清单没放行：默认最小权限仍生效（插件不自动放行）
    let hub = hubWith([], [], out)
    registerPluginCommands(hub, MiniPlugin())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":2,\"cmd\":\"mini:ping\"}")
    @Expect(out.size, 1)
    @Expect(strField(out[0], "error"), "command not allowed: mini:ping")
}

@Test
func testAssemblePluginJs(): Unit {
    let none = ArrayList<Plugin>()
    @Expect(assemblePluginJs(none), "")   // 没有任何 shim 就不插脚本块

    let plugins = ArrayList<Plugin>()
    plugins.add(MiniPlugin())             // 默认 shim 为空，应被跳过
    plugins.add(DemoPlugin())
    let js = assemblePluginJs(plugins)
    @Expect(js.startsWith("<script>"), true)
    @Expect(js.contains("__CJ_TAURI__.demo"), true)
    @Expect(js.endsWith("</script>\n"), true)
}

@Test
func testInjectPluginJsBeforeHeadEnd(): Unit {
    let html = "<html><head><title>t</title></head><body>hi</body></html>"
    let out = injectPluginJs(html, "<script>1</script>\n")
    let at = out.indexOf("<script>1</script>").getOrThrow()
    let headEnd = out.indexOf("</head>").getOrThrow()
    @Expect(at < headEnd, true)                       // 必须早于 </head>，才早于页面脚本
    @Expect(out.contains("<body>hi</body>"), true)    // 原内容不丢
}

@Test
func testInjectPluginJsFallsBackToFront(): Unit {
    let out = injectPluginJs("<div>hi</div>", "<script>1</script>\n")
    @Expect(out.startsWith("<script>1</script>"), true)   // 没有 </head> 时插到最前
}

@Test
func testInjectPluginJsNoopWithoutShim(): Unit {
    let html = "<html><head></head></html>"
    @Expect(injectPluginJs(html, ""), html)
}

@Test
func testDescribePluginsListsCommandsAndEvents(): Unit {
    let plugins = ArrayList<Plugin>()
    plugins.add(DemoPlugin())
    let text = describePlugins(plugins)
    @Expect(text.contains("demo"), true)
    @Expect(text.contains("demo:do"), true)
    @Expect(text.contains("events: demo:changed"), true)
}

@Test
func testFsPluginSurface(): Unit {
    let p = FsPlugin()
    @Expect(p.name(), "fs")
    let names = pluginCommandNames(p)
    @Expect(names.size, 3)
    var hasRead = false
    var hasWrite = false
    var hasExists = false
    for (n in names) {
        if (n == "fs:readText") {
            hasRead = true
        }
        if (n == "fs:writeText") {
            hasWrite = true
        }
        if (n == "fs:exists") {
            hasExists = true
        }
    }
    @Expect(hasRead, true)
    @Expect(hasWrite, true)
    @Expect(hasExists, true)
}

@Test
func testFsPluginShimTargetsItsOwnNamespace(): Unit {
    let js = FsPlugin().jsShim()
    @Expect(js.contains("t.fs"), true)
    @Expect(js.contains("'fs:readText'"), true)
    @Expect(js.contains("'fs:writeText'"), true)
    @Expect(js.contains("'fs:exists'"), true)
}

@Test
func testFsPluginDeclaresPermissionSets(): Unit {
    let sets = pluginPermissionSets(FsPlugin())
    @Expect(sets.size, 2)
    let ro = sets.get("fs:readonly").getOrThrow()
    @Expect(ro.size, 2)
    var roHasWrite = false
    for (m in ro) {
        if (m == "fs:writeText") {
            roHasWrite = true
        }
    }
    @Expect(roHasWrite, false)                 // 只读集不含写：最小权限不打折
    @Expect(sets.get("fs:default").getOrThrow().size, 3)
}

@Test
func testPluginPermissionSetsAreNamespacedAndExpanded(): Unit {
    let sets = pluginPermissionSets(ScopedPlugin())
    @Expect(sets.size, 1)
    @Expect(sets.contains("scoped:watch"), true)
    let members = sets.get("scoped:watch").getOrThrow()
    @Expect(members.size, 2)
    var hasShort = false
    var hasFull = false
    for (m in members) {
        if (m == "scoped:read") {
            hasShort = true
        }
        if (m == "scoped:changed") {
            hasFull = true
        }
    }
    @Expect(hasShort, true)     // 短名补了插件名前缀
    @Expect(hasFull, true)      // 全名原样
}

@Test
func testPluginPermissionSetsDefaultEmpty(): Unit {
    // 接口默认实现：没写 permissions() 的插件没有集（MiniPlugin 只写了必写成员）
    @Expect(pluginPermissionSets(MiniPlugin()).size, 0)
}

@Test
func testPluginPermissionSetDoesNotAutoGrant(): Unit {
    let out = ArrayList<String>()
    // 插件声明了 scoped:watch，但清单没引用它 → 命令仍被拒（集声明不等于放行）
    let hub = hubWith([], [], out)
    registerPluginCommands(hub, ScopedPlugin())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":11,\"cmd\":\"scoped:read\"}")
    @Expect(out.size, 1)
    @Expect(strField(out[0], "error"), "command not allowed: scoped:read")
}

@Test
func testPluginPermissionSetAuthorizesWhenReferenced(): Unit {
    let out = ArrayList<String>()
    let reg = CapabilityRegistry()
    reg.addFromJson(JsonValue.fromStr("{\"identifier\":\"d\",\"permissions\":[\"scoped:watch\"]}"))
    let hub = hubWithRegistry(reg, out)
    registerPluginCommands(hub, ScopedPlugin())
    registerPluginPermissionSets(reg, ScopedPlugin())
    // 集内命令放行
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":12,\"cmd\":\"scoped:read\"}")
    @Expect(out.size, 1)
    @Expect(strField(out[0], "type"), "resolve")
    @Expect(strField(out[0], "data"), "pong:scoped:read")
    // 集外命令仍拒：放行的是那一组，不是整个插件
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":13,\"cmd\":\"scoped:write\"}")
    @Expect(out.size, 2)
    @Expect(strField(out[1], "error"), "command not allowed: scoped:write")
}

@Test
func testDescribePermissionSets(): Unit {
    let none = ArrayList<Plugin>()
    @Expect(describePermissionSets(none), "")
    let plugins = ArrayList<Plugin>()
    plugins.add(ScopedPlugin())
    let text = describePermissionSets(plugins)
    @Expect(text.contains("scoped:watch"), true)
    @Expect(text.contains("scoped:read"), true)
}

@Test
func testFsWriteThenReadRoundTrip(): Unit {
    let cmds = FsPlugin().commands()
    let ctx = IpcContext("main", IpcHub())
    let path = "/tmp/cj-tauri-plugin-roundtrip.txt"

    var wArgs = pathArgs(path)
    wArgs.put("contents", JsonString("插件写入的内容 CJ"))
    let wrote = cmds.get("writeText").getOrThrow().handle("fs:writeText", wArgs, ctx)
    @Expect(wrote.asBool().getValue(), true)

    let read = cmds.get("readText").getOrThrow().handle("fs:readText", pathArgs(path), ctx)
    @Expect(read.asString().getValue(), "插件写入的内容 CJ")

    // 覆盖写：再写一次短内容，读回来应是新的（不是追加、也不是旧内容）
    var w2 = pathArgs(path)
    w2.put("contents", JsonString("覆盖"))
    cmds.get("writeText").getOrThrow().handle("fs:writeText", w2, ctx)
    let read2 = cmds.get("readText").getOrThrow().handle("fs:readText", pathArgs(path), ctx)
    @Expect(read2.asString().getValue(), "覆盖")

    let exists = cmds.get("exists").getOrThrow().handle("fs:exists", pathArgs(path), ctx)
    @Expect(exists.asBool().getValue(), true)
}

@Test
func testFsRejectsMissingArgument(): Unit {
    let cmds = FsPlugin().commands()
    let ctx = IpcContext("main", IpcHub())
    var threw = false
    try {
        cmds.get("readText").getOrThrow().handle("fs:readText", JsonObject(), ctx)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("missing argument"), true)
    }
    @Expect(threw, true)
}

@Test
func testFsReadMissingFileBecomesBusinessError(): Unit {
    let cmds = FsPlugin().commands()
    let ctx = IpcContext("main", IpcHub())
    var threw = false
    try {
        cmds.get("readText").getOrThrow().handle("fs:readText", pathArgs("/tmp/cj-tauri-plugin-no-such-file.txt"), ctx)
    } catch (e: CommandException) {
        // 抛 CommandException 而不是裸异常：前端拿到的是可读原文，不是 "command failed: ..."
        threw = true
        @Expect(e.message.startsWith("fs:readText failed:"), true)
    }
    @Expect(threw, true)

    let exists = cmds.get("exists").getOrThrow().handle("fs:exists", pathArgs("/tmp/cj-tauri-plugin-no-such-file.txt"), ctx)
    @Expect(exists.asBool().getValue(), false)
}
