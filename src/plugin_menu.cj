package cjTauri

import std.collection.*
import stdx.encoding.json.*

/**
 * 官方插件 menu：运行期改菜单项状态 + 前端命名空间（RFC-002 §5.6 / §5.9）
 *
 * 命令（短名 → 全名）：
 *   setEnabled → menu:setEnabled   `{ id, enabled }`
 *   setChecked → menu:setChecked   `{ id, checked }`
 * 事件：`click` → `menu:click`——本插件只**声明**它（给缺权限提示用），真正投递在
 *   `TauriApp` 的 shell 分发里，页面侧写 `listen("menu:click", …)` 即可。
 * 权限：**不自动放行**，应用在 capabilities 里二选一（两种写法等价）：
 *   "commands": ["menu:setEnabled", "menu:setChecked"]   // 明文逐条（旧写法）
 *   "permissions": ["menu:state"]                        // 命名权限集（v1.1）
 * 前端：window.__CJ_TAURI__.menu.setChecked({ id: "view.sidebar", checked: true })
 *
 * 为什么命令要经 `TauriApp`、而不是直接用宿主：菜单项按 id 定位到**调用方那个窗口**
 * （`ipc.window`），而「另一维状态」存在应用层留存的菜单模型里——平台侧一次调用会同时写
 * enabled 与 checked（见 `WebViewHost.setMenuItemState`），拿不到另一维就会把用户刚点出来的
 * 勾选抹掉。所以处理器必须握有 app，装配时由 `setup()` 注入。
 */
public class MenuPlugin <: Plugin {
    // 两个命令共用一个处理器实例：app 引用只要注入一次（commands() 早于 setup() 跑，见 attach）
    private let handler: MenuCommands = MenuCommands()

    public init() {}

    public func name(): String {
        return "menu"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        m.add("setEnabled", this.handler)
        m.add("setChecked", this.handler)
        return m
    }

    /** 事件只声明（`<插件名>:<短名>` = `menu:click`），投递在框架的 shell 分发里 */
    public func events(): ArrayList<String> {
        let e = ArrayList<String>()
        e.add("click")
        return e
    }

    /**
     * 命名权限集（v1.1）：`menu:state` = 两个改状态的命令
     *
     * 与 fs 的 readonly 同理——**集声明不等于放行**，清单不引用它一条也不会生效。
     */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let st = ArrayList<String>()
        st.add("setEnabled")
        st.add("setChecked")
        m.add("state", st)
        return m
    }

    public func setup(app: TauriApp): Unit {
        this.handler.attach(app)
    }

    /**
     * 前端 shim：往桥对象上挂一个 menu 命名空间。
     * 只动 __CJ_TAURI__ 的一个命名空间，不碰 invoke / listen / emit，也不注册全局变量。
     */
    public func jsShim(): String {
        return "(function () { var t = window.__CJ_TAURI__ || (window.__CJ_TAURI__ = {});" +
            " t.menu = {" +
            " setEnabled: function (args) { return window.__CJ_TAURI__.invoke('menu:setEnabled', args); }," +
            " setChecked: function (args) { return window.__CJ_TAURI__.invoke('menu:setChecked', args); }" +
            " }; })();\n"
    }
}

/**
 * menu 插件的命令处理器（两个命令共用一份，按全名分派，与内置 SystemCommands / FsCommands 同形）
 */
class MenuCommands <: CommandHandler {
    private var app: Option<TauriApp> = None

    public init() {}

    /**
     * 由 MenuPlugin.setup 注入
     *
     * 不能靠构造函数传：`commands()`（装配时先跑，负责建处理器）拿不到 app，
     * 而 `setup(app)` 后跑——所以只能事后注入。
     */
    func attach(app: TauriApp): Unit {
        this.app = Some(app)
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "menu:setEnabled" => this.setEnabled(args, ipc)
            case "menu:setChecked" => this.setChecked(args, ipc)
            case _ => throw CommandException("unknown menu command: ${cmd}")
        }
    }

    /** 只改启用状态；勾选态由应用层模型补齐（见 MenuPlugin 的类注释） */
    private func setEnabled(args: JsonObject, ipc: IpcContext): JsonValue {
        let id = this.requireString(args, "id")
        let enabled = this.requireBool(args, "enabled")
        this.requireApp().setMenuItemEnabledTo(ipc.window, id, enabled)
        return JsonBool(true)
    }

    /** 只改勾选状态；启用态由应用层模型补齐 */
    private func setChecked(args: JsonObject, ipc: IpcContext): JsonValue {
        let id = this.requireString(args, "id")
        let checked = this.requireBool(args, "checked")
        this.requireApp().setMenuItemCheckedTo(ipc.window, id, checked)
        return JsonBool(true)
    }

    private func requireApp(): TauriApp {
        match (this.app) {
            case Some(a) => return a
            case None => throw CommandException("menu: 插件未装配到应用（请 TauriApp().plugin(MenuPlugin())）")
        }
    }

    /** 取必需的字符串参数；缺失 / 类型不对时抛业务错误，前端拿到可读原文 */
    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => throw CommandException("menu: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("menu: missing argument \"${key}\"")
        }
    }

    private func requireBool(args: JsonObject, key: String): Bool {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsBool => return v.asBool().getValue()
                case _ => throw CommandException("menu: argument \"${key}\" must be a boolean")
            }
            case None => throw CommandException("menu: missing argument \"${key}\"")
        }
    }
}
