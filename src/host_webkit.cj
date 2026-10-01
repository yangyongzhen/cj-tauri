package cjTauri

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

    public func openDevTools(): Unit {
        unsafe {
            cj_bridge_open_devtools()
        }
    }

    public func start(html: String): Unit {
        HostGlobals.onMessage = this.onMessage
        HostGlobals.onDestroy = this.onDestroy
        var devTools: Int32 = 0
        if (this.config.devTools) {
            devTools = 1
        }
        unsafe {
            cj_bridge_init(hostOnMessage, hostOnDestroy)
            cj_bridge_set_window(LibC.mallocCString(this.config.title),
                                 Int32(this.config.width), Int32(this.config.height))
            cj_bridge_set_devtools(devTools)
            // 窗口图标：空串表示系统默认图标
            cj_bridge_set_icon(LibC.mallocCString(this.config.iconPath))
            cj_bridge_start(LibC.mallocCString(html))
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
