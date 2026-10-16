package cjTauri

// Windows 侧才用得上（类整体门禁在 Windows）：加同款门禁，免得 Linux 构建把这条当「未使用 import」清掉
@When[os == "Windows"]
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
foreign func cj_bridge_init(h: CPointer<Unit>, m: CFunc<(CString) -> Unit>, d: CFunc<(CPointer<Unit>) -> Unit>): Unit

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
foreign func cj_bridge_set_window_auto(h: CPointer<Unit>, pct: Int32, minW: Int32, minH: Int32,
                                       maxW: Int32, maxH: Int32): Unit

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
foreign func cj_bridge_set_dialog_callback(h: CPointer<Unit>, cb: CFunc<(CPointer<Unit>, CString) -> Unit>): Unit

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
 * 菜单栏（RFC-002 §5.4 的线路文本）：空串 = 清空。未就绪时桥只记下，建窗时一次建好。
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_set_menu(h: CPointer<Unit>, wire: CString): Unit

/**
 * 运行期改单个菜单项的状态（按 id 找；找不到只记日志）
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_set_menu_item_state(h: CPointer<Unit>, id: CString, enabled: Int32,
                                           checked: Int32): Unit

/**
 * 拖放策略（RFC-002 §5）：Windows 侧当前为桩（能力位如实不置位），同名同签名保上层零平台分支
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_set_drag_drop(h: CPointer<Unit>, enabled: Int32, files: Int32): Unit

/**
 * 全局快捷键（RFC-003 第 5 期）：Windows 侧走 `RegisterHotKey`（见 native/platforms/windows/
 * bridge_win.c），wire 词法与 Linux 同规（Ctrl/Alt/Shift/Super + 常用键名），触发经 on_shell 回投
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_set_global_hotkeys(h: CPointer<Unit>, wire: CString): Unit

/**
 * 托盘（RFC-002 §7.C）：Windows 侧走 `Shell_NotifyIconW`（菜单是 CreatePopupMenu，只弹不挂窗口），
 * 点击与 Linux 同信封回投 `{"kind":"tray","id":…}`
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_set_tray(h: CPointer<Unit>, wire: CString): Unit

/**
 * 窗口可见性（`show()` / `hide()` 的 C 侧落点）：start 之前调只记 pending，就绪后投 UI 线程执行
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_set_window_visible(h: CPointer<Unit>, visible: Int32): Unit

/**
 * 最小化到托盘策略位（须在 start 之前调）：窗口过程据此把「最小化」改写成「隐藏」
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_set_minimize_to_tray(h: CPointer<Unit>, enabled: Int32): Unit

/**
 * shell 事件回调（菜单点击等）：首参是宿主句柄，多窗口靠它分辨事件属于哪个窗口
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_set_shell_callback(h: CPointer<Unit>,
                                          cb: CFunc<(CPointer<Unit>, CString) -> Unit>): Unit

/**
 * 宿主能力位（CJ_CAP_* 的按位或）：未 init 返回 0
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_host_capabilities(h: CPointer<Unit>): Int32

/**
 * 句柄同一性判定（返回 1 = 同一个宿主）：仓颉侧 CPointer 不能比较，判定交回 C 侧
 */
@When[os == "Windows"]
@C
foreign func cj_bridge_host_eq(a: CPointer<Unit>, b: CPointer<Unit>): Int32

/**
 * Windows WebView2 宿主实现：通过 C 桥驱动
 */
@When[os == "Windows"]
public class WebView2Host <: WebViewHost {
    // 消息回调：宿主线程（原生 Win32 消息循环）→ 仓颉
    public var onMessage: (String) -> Unit = { _ => }
    // 销毁回调（应用经 setDestroyHandler 装配；由 C 桥按句柄认领，多窗口不串）
    public var onDestroy: () -> Unit = { => }
    // 本窗口文件对话框的结果：C 桥按句柄经路由回调写入（两窗各写各的，不许串台）
    private var dialogResult: String = ""
    // 本窗口的 shell 事件（菜单点击等）回调：TauriApp 装配时经 setShellHandler 覆盖它做分发，
    // 未覆盖时只留一行 stderr——菜单点了没人管，至少能在日志里看见。
    public var shellHandler: (String) -> Unit = { json =>
        eprintln("[cj-tauri] shell event (no handler): ${json}")
    }
    // 窗口配置（标题 / 尺寸），start() 前由 TauriApp 注入
    private var config: WindowConfig = WindowConfig()
    // 预执行脚本（插件 jsShim 等）：start 前收集，prepareHost 一次性交给桥，桥在 document-start 注入
    private var initScripts = ArrayList<String>()
    // 宿主编（C 侧分配）：空指针 = 尚未创建；dispose() 后置空
    private var handle: CPointer<Unit> = CPointer<Unit>()
    // 本窗口的 label（字段名不叫 label：接口有同名方法）。单窗口阶段是常量，
    // 与 TauriApp 注册的 WindowRecord.label 一致；多窗口时由构造参数给定。
    private let windowLabel: String

    public init() {
        this.windowLabel = DEFAULT_WINDOW_LABEL
    }

    /**
     * 带 label 构造（多窗口）：label 必须与 TauriApp 注册表里登记的那个一致，
     * 页面侧的 `window.__CJ_TAURI_LABEL__` 也取同一个值（由 TauriApp 注入）。
     */
    public init(label: String) {
        this.windowLabel = label
    }

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

    public func setMenu(wire: String): Unit {
        // 句柄先建出来：setMenu 允许在 start() 之前调——文本由桥记着，建窗时一次建好
        this.ensureHandle()
        unsafe {
            cj_bridge_set_menu(this.handle, LibC.mallocCString(wire))
        }
    }

    public func setMenuItemState(id: String, enabled: Bool, checked: Bool): Unit {
        if (this.handle.isNull()) {
            // 还没建宿主就谈不上「改状态」：静默返回，不拿空句柄去 FFI
            return
        }
        var e: Int32 = 0
        var c: Int32 = 0
        if (enabled) {
            e = 1
        }
        if (checked) {
            c = 1
        }
        unsafe {
            cj_bridge_set_menu_item_state(this.handle, LibC.mallocCString(id), e, c)
        }
    }

    public func setDragDropPolicy(enabled: Bool, files: Bool): Unit {
        // 与 setMenu 同形：允许在 start() 之前调。Windows 侧桥当前是桩（能力位如实不置位），
        // 但仓颉侧 API 与调用点不写平台分支——实机轮补 IDropTarget 后上层零改动
        this.ensureHandle()
        var en: Int32 = 0
        var fi: Int32 = 0
        if (enabled) {
            en = 1
        }
        if (files) {
            fi = 1
        }
        unsafe {
            cj_bridge_set_drag_drop(this.handle, en, fi)
        }
    }

    public func setGlobalHotkeys(wire: String): Unit {
        // 与 setMenu 同形：允许在 start() 之前调。Windows 侧桥当前是桩（能力位如实不置位），
        // 仓颉侧 API 不写平台分支——实机轮补 RegisterHotKey 后上层零改动
        this.ensureHandle()
        unsafe {
            cj_bridge_set_global_hotkeys(this.handle, LibC.mallocCString(wire))
        }
    }

    public func setTray(wire: String): Unit {
        // 与 setMenu 同形：允许在 start() 之前调。Windows 侧桥当前是桩（能力位如实不置位），
        // 仓颉侧 API 不写平台分支——实机轮补 Shell_NotifyIconW 后上层零改动
        this.ensureHandle()
        unsafe {
            cj_bridge_set_tray(this.handle, LibC.mallocCString(wire))
        }
    }

    public func setWindowVisible(visible: Bool): Unit {
        // 与 setTray 同形：允许在 start() 之前调（桥记 pending，建窗时定稿）；就绪后投宿主 UI 线程
        this.ensureHandle()
        var v: Int32 = 0
        if (visible) {
            v = 1
        }
        unsafe {
            cj_bridge_set_window_visible(this.handle, v)
        }
    }

    public func setMinimizeToTray(enabled: Bool): Unit {
        // 策略位：窗口过程要在建窗时就拿到它，所以只在 start() 之前调有意义（与 setDragDropPolicy 同规）
        this.ensureHandle()
        var e: Int32 = 0
        if (enabled) {
            e = 1
        }
        unsafe {
            cj_bridge_set_minimize_to_tray(this.handle, e)
        }
    }

    public func hostCapabilities(): Int32 {
        if (this.handle.isNull()) {
            return 0
        }
        var caps: Int32 = 0
        unsafe {
            caps = cj_bridge_host_capabilities(this.handle)
        }
        return caps
    }

    public func setShellHandler(handler: (String) -> Unit): Unit {
        this.shellHandler = handler
    }

    public func setDestroyHandler(handler: () -> Unit): Unit {
        this.onDestroy = handler
    }

    public func showFileDialog(save: Bool, title: String, filter: String): String {
        return this.showFileDialogPreset(save, title, filter, "")
    }

    public func showFileDialogPreset(save: Bool, title: String, filter: String,
                                     defaultName: String): String {
        var kind: Int32 = 0
        if (save) {
            kind = 1
        }
        var ok: Int32 = 0
        unsafe {
            // defaultName 经 message 参数通道交给桥（文件类对话框把它当预置文件名）
            ok = cj_bridge_show_dialog(this.handle, kind, LibC.mallocCString(title),
                                       LibC.mallocCString(defaultName), LibC.mallocCString(filter))
        }
        if (ok == 0) {
            // 取消 / 宿主未就绪：上游按「空路径」处理，不再读结果位
            return ""
        }
        return this.dialogResult
    }

    public func showMessageDialog(kind: String, title: String, message: String): Bool {
        var ok: Int32 = 0
        unsafe {
            ok = cj_bridge_show_dialog(this.handle, dialogKindCode(kind), LibC.mallocCString(title),
                                       LibC.mallocCString(message), LibC.mallocCString(""))
        }
        return ok != 0
    }

    public func clipboardWriteText(text: String): Bool {
        var rc: Int32 = -1
        unsafe {
            rc = cj_bridge_clipboard_write_text(this.handle, LibC.mallocCString(text))
        }
        if (rc != 0) {
            eprintln("[cj-tauri] clipboard write failed: code=${rc}")
        }
        return rc == 0
    }

    public func clipboardReadText(): Option<String> {
        let cs = unsafe { cj_bridge_clipboard_read_text(this.handle) }
        if (cs.isNull()) {
            return None<String> // 空 / 非文本 / 平台失败，协议层不区分
        }
        let text = cs.toString()
        unsafe {
            cj_bridge_clipboard_free(cs) // 归还缓冲：malloc 家族分配，必须走桥的 free
        }
        return Some(text)
    }

    public func notify(title: String, body: String): Bool {
        var rc: Int32 = -1
        unsafe {
            rc = cj_bridge_notification_notify(this.handle, LibC.mallocCString(title),
                                               LibC.mallocCString(body))
        }
        if (rc != 0) {
            // Windows 桩阶段返回 -4（未实现）：静态事实，stderr 一行说清，不算异常
            eprintln("[cj-tauri] notification failed: code=${rc}")
        }
        return rc == 0
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
        // 宿主级路由：「本句柄 → 本实例的三个回调」登记一条（表式，不覆盖别的窗口）
        HostGlobals.registerHostRoute(this.handle, { json => this.shellHandler(json) },
                                      { => this.onDestroy() },
                                      { path => this.dialogResult = path })
        var devTools: Int32 = 0
        if (this.config.devTools) {
            devTools = 1
        }
        unsafe {
            cj_bridge_init(this.handle, hostOnMessage, hostOnDestroy)
            // shell 事件回调（菜单点击等）：与消息回调同一套路，多一个首参用来分辨窗口
            cj_bridge_set_shell_callback(this.handle, shellOnEvent)
            // 原生对话框的结果回调：与消息回调同一套路，多一个首参（结果只落发起这次对话框的窗口）
            cj_bridge_set_dialog_callback(this.handle, dialogOnResult)
            cj_bridge_set_window(this.handle, LibC.mallocCString(this.config.title),
                                 Int32(this.config.width), Int32(this.config.height))
            // 自适应开窗策略（可选）：与 set_window 同一时机——只登记，平台建窗时才算最终尺寸
            match (this.config.autoSize) {
                case Some(auto) => cj_bridge_set_window_auto(this.handle, Int32(auto.percent),
                                                             Int32(auto.minWidth), Int32(auto.minHeight),
                                                             Int32(auto.maxWidth), Int32(auto.maxHeight))
                case None => ()
            }
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
