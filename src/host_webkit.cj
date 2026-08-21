package cjTauri

/**
 * C 桥 FFI 声明（native/libcjtbridge.so）
 * 所有 GTK/WebKit 调用在 C 桥的原生 pthread 内执行（见 native/bridge.c 头注释）。
 */
@C
foreign func cj_bridge_init(m: CFunc<(CString) -> Unit>, d: CFunc<() -> Unit>): Unit

@C
foreign func cj_bridge_start(html: CString): Unit

@C
foreign func cj_bridge_run_js(js: CString): Unit

@C
foreign func cj_bridge_quit(): Unit

@C
foreign func cj_bridge_is_ready(): Int32

/**
 * Linux WebKit 宿主实现：通过 C 桥驱动
 */
public class WebKitHost <: WebViewHost {
    // 消息回调：GTK 线程（原生 pthread）→ 仓颉
    public var onMessage: (String) -> Unit = { _ => }
    // 销毁回调
    public var onDestroy: () -> Unit = { => }

    public init() {}

    public func start(html: String): Unit {
        unsafe {
            cj_bridge_init(hostOnMessage, hostOnDestroy)
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
}

// C 回调中转：C 桥线程 → 仓颉闭包（经全局宿主引用）
class HostGlobals {
    static var host: Option<WebKitHost> = None
}

@C
func hostOnMessage(json: CString): Unit {
    try {
        let s = json.toString()
        if (let Some(h) <- HostGlobals.host) {
            h.onMessage(s)
        }
    } catch (e: Exception) {
        eprintln("[cj-tauri] host callback error: ${e}")
    }
}

@C
func hostOnDestroy(): Unit {
    try {
        if (let Some(h) <- HostGlobals.host) {
            h.onDestroy()
        }
    } catch (e: Exception) {
        eprintln("[cj-tauri] destroy callback error: ${e}")
    }
}
