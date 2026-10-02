package cjTauri

import std.collection.*

/**
 * C 桥 FFI 声明（native/libcjtbridge.dll）
 * Win32 窗口 + WebView2（Edge Chromium）在 C 桥的宿主线程内运行（见 native/bridge_win.c 头注释）。
 * 与 Linux 端（host_webkit.cj）同名同签名，两端宿主实现同构。
 *
 * 句柄制（批次 1）：宿主状态在 C 侧按句柄隔离，导出一律首参收句柄（`cj_host*`）。
 * 句柄内存由 C 侧分配/回收（create 分配、destroy 释放）——跨 FFI 绝不「这边分配那边释放」
 * （Windows 上 CRT 与仓颉运行时不是同一个分配器）；生命周期约定见
 * docs/架构演进-多平台与多窗口.md §6.1。
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_create(): CPointer<Unit>

/**
 * 释放宿主编：对空指针安全、幂等；调用后该句柄不可再用
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_destroy(h: CPointer<Unit>): Unit

@When[os == "Windows"]
@C
foreign func cj_bridge_init(h: CPointer<Unit>, m: CFunc<(CString) -> Unit>, d: CFunc<() -> Unit>): Unit

@When[os == "Windows"]
@C
foreign func cj_bridge_start(h: CPointer<Unit>, html: CString): Unit

@When[os == "Windows"]
@C
foreign func cj_bridge_load_url(h: CPointer<Unit>, url: CString): Unit

/**
 * 注册一段预执行脚本（插件 jsShim 等）：须在 cj_bridge_start 之前调用，桥在 document-start 注入
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_add_init_script(h: CPointer<Unit>, js: CString): Unit

@When[os == "Windows"]
@C
foreign func cj_bridge_reload(h: CPointer<Unit>): Unit

@When[os == "Windows"]
@C
foreign func cj_bridge_set_window(h: CPointer<Unit>, title: CString, width: Int32, height: Int32): Unit

@When[os == "Windows"]
@C
foreign func cj_bridge_set_devtools(h: CPointer<Unit>, enabled: Int32): Unit

@When[os == "Windows"]
@C
foreign func cj_bridge_set_icon(h: CPointer<Unit>, path: CString): Unit

@When[os == "Windows"]
@C
foreign func cj_bridge_open_devtools(h: CPointer<Unit>): Unit

@When[os == "Windows"]
@C
foreign func cj_bridge_set_dialog_callback(h: CPointer<Unit>, cb: CFunc<(CString) -> Unit>): Unit

/**
 * 原生对话框（阻塞式）：kind 0=打开文件 1=保存文件 2=info 3=warning 4=error 5=confirm。
 * 返回 1 = 用户确认；文件类选中路径经 cj_bridge_set_dialog_callback 注册的回调送回。
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_show_dialog(h: CPointer<Unit>, kind: Int32, title: CString, message: CString,
                                   filter: CString): Int32

@When[os == "Windows"]
@C
foreign func cj_bridge_run_js(h: CPointer<Unit>, js: CString): Unit

@When[os == "Windows"]
@C
foreign func cj_bridge_quit(h: CPointer<Unit>): Unit

@When[os == "Windows"]
@C
foreign func cj_bridge_is_ready(h: CPointer<Unit>): Int32

@When[os == "Windows"]
@C
foreign func cj_bridge_should_quit(h: CPointer<Unit>): Int32

/**
 * Windows WebView2 宿主实现：通过 C 桥驱动
 */
@When[os == "Windows"]
public class WebView2Host <: WebViewHost {
    // 消息回调：宿主线程（原生 Win32 消息循环）→ 仓颉
    public var onMessage: (String) -> Unit = { _ => }
    // 销毁回调
    public var onDestroy: () -> Unit = { => }
    // 窗口配置（标题 / 尺寸），start() 前由 TauriApp 注入
    private var config: WindowConfig = WindowConfig()
    // 预执行脚本（插件 jsShim 等）：start 前收集，prepareHost 一次性交给桥，桥在 document-start 注入
    private var initScripts = ArrayList<String>()
    // 宿主编（C 侧分配）：空指针 = 尚未创建；dispose() 后置空
    private var handle: CPointer<Unit> = CPointer<Unit>()
    // 本窗口的 label（字段名不叫 label：接口有同名方法）。单窗口阶段是常量，
    // 与 TauriApp 注册的 WindowRecord.label 一致；多窗口时由构造参数给定。
    private let windowLabel: String = DEFAULT_WINDOW_LABEL

    public init() {}

    public func label(): String {
        return this.windowLabel
    }

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
            cj_bridge_open_devtools(this.handle)
        }
    }

    public func showFileDialog(save: Bool, title: String, filter: String): String {
        var kind: Int32 = 0
        if (save) {
            kind = 1
        }
        var ok: Int32 = 0
        unsafe {
            ok = cj_bridge_show_dialog(this.handle, kind, LibC.mallocCString(title),
                                       LibC.mallocCString(""), LibC.mallocCString(filter))
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
            ok = cj_bridge_show_dialog(this.handle, dialogKindCode(kind), LibC.mallocCString(title),
                                       LibC.mallocCString(message), LibC.mallocCString(""))
        }
        return ok != 0
    }

    /**
     * 创建宿主编（幂等）：首次启动时分配，dispose() 后置空
     */
    private func ensureHandle(): Unit {
        if (this.handle.isNull()) {
            unsafe {
                this.handle = cj_bridge_create()
            }
        }
    }

    /**
     * 启动前的共同装配：宿主编、回调槽位、窗口配置、图标
     */
    private func prepareHost(): Unit {
        this.ensureHandle()
        HostGlobals.onMessage = this.onMessage
        HostGlobals.onDestroy = this.onDestroy
        var devTools: Int32 = 0
        if (this.config.devTools) {
            devTools = 1
        }
        unsafe {
            cj_bridge_init(this.handle, hostOnMessage, hostOnDestroy)
            // 原生对话框的结果回调：与消息回调同一套路（C 桥宿主线程 → 仓颉全局槽位）
            cj_bridge_set_dialog_callback(this.handle, dialogOnResult)
            cj_bridge_set_window(this.handle, LibC.mallocCString(this.config.title),
                                 Int32(this.config.width), Int32(this.config.height))
            cj_bridge_set_devtools(this.handle, devTools)
            // 窗口图标：空串表示系统默认图标
            cj_bridge_set_icon(this.handle, LibC.mallocCString(this.config.iconPath))
            // 预执行脚本（插件 jsShim 等）：与 BRIDGE_JS 同一条 document-start 通道，按注册顺序排在桥之后
            for (js in this.initScripts) {
                cj_bridge_add_init_script(this.handle, LibC.mallocCString(js))
            }
        }
    }

    public func start(html: String): Unit {
        this.prepareHost()
        unsafe {
            cj_bridge_start(this.handle, LibC.mallocCString(html))
        }
    }

    public func startUrl(url: String): Unit {
        this.prepareHost()
        unsafe {
            cj_bridge_load_url(this.handle, LibC.mallocCString(url))
            // 空串表示「页面由 cj_bridge_load_url 指定」（同一次启动里 URL 优先）
            cj_bridge_start(this.handle, LibC.mallocCString(""))
        }
    }

    public func reload(): Unit {
        unsafe {
            cj_bridge_reload(this.handle)
        }
    }

    public func runJs(js: String): Unit {
        unsafe {
            cj_bridge_run_js(this.handle, LibC.mallocCString(js))
        }
    }

    public func quit(): Unit {
        unsafe {
            cj_bridge_quit(this.handle)
        }
    }

    public func shouldQuit(): Bool {
        unsafe {
            cj_bridge_should_quit(this.handle) != 0
        }
    }

    /**
     * 释放宿主编（幂等，未创建过则是空操作）：事件循环退出后调用一次，之后句柄置空、本实例不可再启动
     */
    public func dispose(): Unit {
        if (this.handle.isNull()) {
            return
        }
        unsafe {
            cj_bridge_destroy(this.handle)
        }
        this.handle = CPointer<Unit>()
    }
}

// C 回调中转：C 桥线程 → 仓颉闭包（经全局槽位）
@When[os == "Windows"]
@C
func hostOnMessage(json: CString): Unit {
    try {
        HostGlobals.onMessage(json.toString())
    } catch (e: Exception) {
        eprintln("[cj-tauri] host callback error: ${e}")
    }
}

@When[os == "Windows"]
@C
func hostOnDestroy(): Unit {
    try {
        HostGlobals.onDestroy()
    } catch (e: Exception) {
        eprintln("[cj-tauri] destroy callback error: ${e}")
    }
}
