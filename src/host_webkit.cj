package cjTauri

import std.collection.*

/**
 * C 桥 FFI 声明（native/libcjtbridge.so）
 * 所有 GTK/WebKit 调用在 C 桥的原生 pthread 内执行（见 native/bridge_linux.c 头注释）。
 */
@When[os == "Linux"]
@C
foreign func cj_bridge_init(m: CFunc<(CString) -> Unit>, d: CFunc<() -> Unit>): Unit

@When[os == "Linux"]
@C
foreign func cj_bridge_start(html: CString): Unit

@When[os == "Linux"]
@C
foreign func cj_bridge_load_url(url: CString): Unit

/**
 * 注册一段预执行脚本（插件 jsShim 等）：须在 cj_bridge_start 之前调用，桥在 document-start 注入
 */
@When[os == "Linux"]
@C
foreign func cj_bridge_add_init_script(js: CString): Unit

@When[os == "Linux"]
@C
foreign func cj_bridge_reload(): Unit

@When[os == "Linux"]
@C
foreign func cj_bridge_set_window(title: CString, width: Int32, height: Int32): Unit

@When[os == "Linux"]
@C
foreign func cj_bridge_set_devtools(enabled: Int32): Unit

@When[os == "Linux"]
@C
foreign func cj_bridge_set_icon(path: CString): Unit

@When[os == "Linux"]
@C
foreign func cj_bridge_open_devtools(): Unit

@When[os == "Linux"]
@C
foreign func cj_bridge_set_dialog_callback(cb: CFunc<(CString) -> Unit>): Unit

/**
 * 原生对话框（阻塞式）：kind 0=打开文件 1=保存文件 2=info 3=warning 4=error 5=confirm。
 * 返回 1 = 用户确认；文件类选中路径经 cj_bridge_set_dialog_callback 注册的回调送回。
 */
@When[os == "Linux"]
@C
foreign func cj_bridge_show_dialog(kind: Int32, title: CString, message: CString, filter: CString): Int32

@When[os == "Linux"]
@C
foreign func cj_bridge_run_js(js: CString): Unit

@When[os == "Linux"]
@C
foreign func cj_bridge_quit(): Unit

@When[os == "Linux"]
@C
foreign func cj_bridge_is_ready(): Int32

@When[os == "Linux"]
@C
foreign func cj_bridge_should_quit(): Int32

/**
 * Linux WebKit 宿主实现：通过 C 桥驱动
 */
@When[os == "Linux"]
public class WebKitHost <: WebViewHost {
    // 消息回调：GTK 线程（原生 pthread）→ 仓颉
    public var onMessage: (String) -> Unit = { _ => }
    // 销毁回调
    public var onDestroy: () -> Unit = { => }
    // 窗口配置（标题 / 尺寸），start() 前由 TauriApp 注入
    private var config: WindowConfig = WindowConfig()
    // 预执行脚本（插件 jsShim 等）：start 前收集，prepareHost 一次性交给桥，桥在 document-start 注入
    private var initScripts = ArrayList<String>()

    public init() {}

    public func setMessageHandler(handler: (String) -> Unit): Unit {
        this.onMessage = handler
    }

    public func setWindowConfig(config: WindowConfig): Unit {
        this.config = config
    }

    public func setDevTools(enabled: Bool): Unit {
        this.config.devTools = enabled
    }

    public func addInitScript(js: String): Unit {
        // 空串忽略（插件没写 shim 时不必占位，桥侧也会再挡一次）
        if (js.size > 0) {
            this.initScripts.add(js)
        }
    }

    public func openDevTools(): Unit {
        unsafe {
            cj_bridge_open_devtools()
        }
    }

    public func showFileDialog(save: Bool, title: String, filter: String): String {
        var kind: Int32 = 0
        if (save) {
            kind = 1
        }
        var ok: Int32 = 0
        unsafe {
            ok = cj_bridge_show_dialog(kind, LibC.mallocCString(title), LibC.mallocCString(""),
                                       LibC.mallocCString(filter))
        }
        if (ok == 0) {
            // 取消 / 宿主未就绪：上游按「空路径」处理，不再读结果槽位
            return ""
        }
        return HostGlobals.dialogResult
    }

    public func showMessageDialog(kind: String, title: String, message: String): Bool {
        var ok: Int32 = 0
        unsafe {
            ok = cj_bridge_show_dialog(dialogKindCode(kind), LibC.mallocCString(title),
                                       LibC.mallocCString(message), LibC.mallocCString(""))
        }
        return ok != 0
    }

    /**
     * 启动前的共同装配：回调槽位、窗口配置、图标
     */
    private func prepareHost(): Unit {
        HostGlobals.onMessage = this.onMessage
        HostGlobals.onDestroy = this.onDestroy
        var devTools: Int32 = 0
        if (this.config.devTools) {
            devTools = 1
        }
        unsafe {
            cj_bridge_init(hostOnMessage, hostOnDestroy)
            // 原生对话框的结果回调：与消息回调同一套路（C 桥 UI 线程 → 仓颉全局槽位）
            cj_bridge_set_dialog_callback(dialogOnResult)
            cj_bridge_set_window(LibC.mallocCString(this.config.title),
                                 Int32(this.config.width), Int32(this.config.height))
            cj_bridge_set_devtools(devTools)
            // 窗口图标：空串表示系统默认图标
            cj_bridge_set_icon(LibC.mallocCString(this.config.iconPath))
            // 预执行脚本（插件 jsShim 等）：与 BRIDGE_JS 同一条 document-start 通道，按注册顺序排在桥之后
            for (js in this.initScripts) {
                cj_bridge_add_init_script(LibC.mallocCString(js))
            }
        }
    }

    public func start(html: String): Unit {
        this.prepareHost()
        unsafe {
            cj_bridge_start(LibC.mallocCString(html))
        }
    }

    public func startUrl(url: String): Unit {
        this.prepareHost()
        unsafe {
            cj_bridge_load_url(LibC.mallocCString(url))
            // 空串表示「页面由 cj_bridge_load_url 指定」（同一次启动里 URL 优先）
            cj_bridge_start(LibC.mallocCString(""))
        }
    }

    public func reload(): Unit {
        unsafe {
            cj_bridge_reload()
        }
    }

    public func runJs(js: String): Unit {
        unsafe {
            cj_bridge_run_js(LibC.mallocCString(js))
        }
    }

    public func quit(): Unit {
        unsafe {
            cj_bridge_quit()
        }
    }

    public func shouldQuit(): Bool {
        unsafe {
            cj_bridge_should_quit() != 0
        }
    }
}

// C 回调中转：C 桥线程 → 仓颉闭包（经全局槽位）
@When[os == "Linux"]
@C
func hostOnMessage(json: CString): Unit {
    try {
        HostGlobals.onMessage(json.toString())
    } catch (e: Exception) {
        eprintln("[cj-tauri] host callback error: ${e}")
    }
}

@When[os == "Linux"]
@C
func hostOnDestroy(): Unit {
    try {
        HostGlobals.onDestroy()
    } catch (e: Exception) {
        eprintln("[cj-tauri] destroy callback error: ${e}")
    }
}
