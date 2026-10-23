package cjTauri.plugins.sqlite

/**
 * ohos 侧 sqlite 桩（RFC §4.6.4 P-1）：FFI 直连系统 sqlite3 在鸿蒙 hap 里没有链接对象，
 * 桌面实现整体门禁（plugin_sqlite.cj / sqlite_ffi.cj 的 `@When[env != "ohos"]`），
 * 本文件提供同名的桩类占住装配位——业务 build() 三端共用、import 全部所用插件，
 * 不能靠编译期排除子包（与「业务零平台分支」冲突，RFC §4.6.4 有完整论证）。
 *
 * 桩语义：命令表 / 权限集 / 前端 shim 与桌面版完全一致（页面 API 面不变），
 * 但每条命令运行期抛「端不支持」——P-2 的如实失败，与 describe().supportedHosts
 * （webkitgtk）严格一致。真实现批次 4 走 NDK FFI 接通（§4.6.5 四通道决策）后，
 * 删掉本文件、在桌面声明上补 ohos 实现段。
 */

@When[env == "ohos"]
import std.collection.*

@When[env == "ohos"]
import stdx.encoding.json.*

@When[env == "ohos"]
import cjTauri.*

@When[env == "ohos"]
public class SqlitePlugin <: Plugin {
    public init() {}

    /** 自描述与桌面版一致（P-2：桩行为与 supportedHosts 严格对齐） */
    public func describe(): PluginManifest {
        let hosts = ArrayList<String>()
        hosts.add("webkitgtk")
        return PluginManifest(hosts, ArrayList<String>())
    }

    public func name(): String {
        return "sqlite"
    }

    /** 与桌面版一致：path 参数吃 scope 校验（桩不碰路径，语义保持一致免得两端行为分叉） */
    public func scopeAware(): Bool {
        return true
    }

    /** 命令表与桌面版同形（常量共用 plugin_sqlite.cj 的门禁外 let），每条指向桩处理器 */
    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        for (short in SQLITE_PLUGIN_COMMANDS) {
            m.add(short, SqliteOhosStubHandler())
        }
        return m
    }

    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let ro = ArrayList<String>()
        for (short in SQLITE_READONLY_COMMANDS) {
            ro.add(short)
        }
        m.add("readonly", ro)
        let all = ArrayList<String>()
        for (short in SQLITE_PLUGIN_COMMANDS) {
            all.add(short)
        }
        m.add("default", all)
        return m
    }

    /** 前端 shim 与桌面版逐字一致：页面 __CJ_TAURI__.sqlite 命名空间照常存在，调用得到可读错误 */
    public func jsShim(): String {
        return "(function () { var t = window.__CJ_TAURI__ || (window.__CJ_TAURI__ = {});" +
            " t.sqlite = {" +
            " info: function (args) { return window.__CJ_TAURI__.invoke('sqlite:info', args); }," +
            " tables: function (args) { return window.__CJ_TAURI__.invoke('sqlite:tables', args); }," +
            " schema: function (args) { return window.__CJ_TAURI__.invoke('sqlite:schema', args); }," +
            " page: function (args) { return window.__CJ_TAURI__.invoke('sqlite:page', args); }," +
            " query: function (args) { return window.__CJ_TAURI__.invoke('sqlite:query', args); }," +
            " exec: function (args) { return window.__CJ_TAURI__.invoke('sqlite:exec', args); }," +
            " env: function (args) { return window.__CJ_TAURI__.invoke('sqlite:env', args); }" +
            " }; })();\n"
    }
}

/** 桩处理器：不分命令、一律如实报错（可照做：换端或等批次 4） */
@When[env == "ohos"]
class SqliteOhosStubHandler <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        throw CommandException("sqlite: ${cmd} 在 ohos 端暂不支持（P-1 桩，批次 4 走 NDK FFI 接通，见 RFC §4.6.4）")
    }
}
