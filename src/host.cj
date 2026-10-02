package cjTauri

/**
 * WebView 宿主层（对标 Tauri 2 的 tao + wry 抽象）
 *
 * 平台差异由条件编译隔离在各自的宿主文件内，上层完全共用：
 *   - Linux 桌面：host_webkit.cj（WebKitGTK，经 native/bridge_linux.c 在原生 pthread 运行）
 *   - Windows   ：host_webview2.cj（WebView2 / Edge Chromium，经 native/bridge_win.c）
 *   - 鸿蒙       ：ArkWeb（架构预留，条件编译位）
 * IPC 桥（ipc_hub.cj）与能力安全模型（capability.cj）跨平台复用。
 */
public interface WebViewHost {
    /**
     * 本窗口的 label（单窗口阶段恒为 "main"）
     *
     * 与 `WindowRecord.label` 是同一个值：注册表是路由的权威来源，宿主自己也留一份——
     * 给前端注入 label（`window.__CJ_TAURI_LABEL__`）以及将来的窗口内自省都用它。
     */
    public func label(): String

    /**
     * 启动宿主：创建窗口 + WebView，加载 HTML，进入事件循环
     */
    public func start(html: String): Unit

    /**
     * 按 URL 启动宿主（http(s):// 或 file://）
     *
     * 与 start(html) 二选一：同一次启动里两者都设时 URL 优先。
     * URL 页面有真实来源，相对路径资源、动态 import、前端路由才成立（file:// 下禁止 fetch/XHR）。
     */
    public func startUrl(url: String): Unit

    /**
     * 注册一段「页面脚本执行前」注入的初始化脚本（多次调用按注册顺序注入）
     *
     * 必须在 start() / startUrl() 之前调用：宿主创建 WebView 时一次性交给 C 桥，桥以
     * document-start 注入（WebKit user script / WebView2 AddScriptToExecuteOnDocumentCreated）。
     * 因此它对 HTML 与 URL 两种页面来源**一视同仁**——插件的 jsShim 走的就是这条通道（RFC §5.4 的 v2 方案），
     * 不再靠字符串拼 HTML。空串忽略；脚本是普通 JS 片段，不要自带 <script> 标签。
     */
    public func addInitScript(js: String): Unit

    /**
     * 重新加载当前页面（整页 reload，对标浏览器刷新）
     *
     * 页面尚未加载时为空操作；开发者工具里的刷新按钮等价于此。
     */
    public func reload(): Unit

    /**
     * 应用窗口配置（标题 / 尺寸）；必须在 start() 之前调用，宿主据此创建窗口
     */
    public func setWindowConfig(config: WindowConfig): Unit

    /**
     * 是否允许打开开发者工具；必须在 start() 之前调用
     */
    public func setDevTools(enabled: Bool): Unit

    /**
     * 运行时打开开发者工具（WebView2 DevTools / WebKit Inspector）
     */
    public func openDevTools(): Unit

    /**
     * 原生文件选择对话框（阻塞到用户关闭）：返回选中的路径，取消 / 失败返回空串。
     *
     * filter 是「描述|模式|描述|模式」拼串（Windows 惯例；GTK 端按同一格式解析），
     * 例如 "文本文件|*.txt|所有文件|*.*"；空串表示不限制。
     * 必须在 start() / startUrl() 之后调用——对话框要拿已创建的应用窗口当父窗口。
     */
    public func showFileDialog(save: Bool, title: String, filter: String): String

    /**
     * 原生消息对话框（阻塞到用户关闭）：返回用户是否点了「确定」。
     *
     * kind 取 "info" / "warning" / "error" / "confirm"（其它值按 info 处理）。
     * info / warning / error 只有一个「确定」，弹出即成立；只有 confirm 会返回 false。
     */
    public func showMessageDialog(kind: String, title: String, message: String): Bool

    /**
     * 原生 → JS：在 WebView 中执行脚本
     */
    public func runJs(js: String): Unit

    /**
     * 停止本窗口的事件循环（低层原语）
     *
     * 应用级退出请用 `AppHost.quit()`——它会走所有窗口；单窗口下两者等价。
     * 原语留在宿主上是因为「循环归谁所有」只有实现方知道（两平台的收尾方式不同：
     * Linux 只收主循环、窗口留给收尾销毁，Windows 直接 DestroyWindow），上层不该自己拼。
     */
    public func quit(): Unit

    /**
     * 装配前端消息回调（WebView 送来的 JSON 字符串 → IPC hub）
     */
    public func setMessageHandler(handler: (String) -> Unit): Unit

    /**
     * 宿主事件循环是否已退出（窗口关闭等），app.run 据此阻塞与收尾
     *
     * 同为低层原语：应用级等待用 `AppHost.waitForExit()`，调用方不必自己写轮询。
     */
    public func shouldQuit(): Bool

    /**
     * 释放宿主资源（宿主编由 C 侧分配与回收，跨 FFI 不换分配器）：幂等、无需检查调用时机
     *
     * TauriApp.run / runUrl 在 waitForExit() 之后调用它；实现方须把句柄置空——
     * 释放后该实例不可再启动（原生窗口已随销毁路径在关窗时收尾）。
     * 为什么「关窗」不等于「释放」：见 docs/架构演进-多平台与多窗口.md §6.1。
     */
    public func dispose(): Unit
}

/**
 * 应用级宿主（对标 Tauri 2 的 `AppHandle`）
 *
 * 与 `WebViewHost` 的分工：`WebViewHost` 是**一个窗口**（创建、投脚本、对话框、本窗口的循环原语），
 * `AppHost` 是**整个应用**（退出、按 label 取窗口；将来还有托盘与应用菜单——批次 3 只定模型）。
 * 批次 2 由 `TauriApp` 实现：它持有窗口注册表，也只有它知道「哪些窗口还开着、应用该不该退」。
 *
 * 为什么 quit / waitForExit 收在这一层：它们跨窗口。宿主仍保留 `quit()` / `shouldQuit()` 作低层原语
 * （循环归宿主所有），但**应用的公开入口只有这里**——多窗口时代的「退出」必然是「先把各窗口收掉」。
 */
public interface AppHost {
    /**
     * 退出应用：收掉所有窗口的事件循环，`run()` / `runUrl()` 随即返回
     */
    public func quit(): Unit

    /**
     * 阻塞到应用退出（窗口关闭 / quit）后返回；`run()` / `runUrl()` 内部调它
     */
    public func waitForExit(): Unit

    /**
     * 按 label 取窗口宿主（对标 Tauri 的 `app.get_webview_window(label)`）；未注册返回 None
     */
    public func hostOf(label: String): Option<WebViewHost>
}

/**
 * C 桥原生线程 → 仓颉回调的全局槽位。
 * 各平台宿主在 start() 时把自己的回调装配到这里，C 侧的 @C 函数经此转入仓颉闭包。
 */
class HostGlobals {
    static var onMessage: (String) -> Unit = { _ => }
    static var onDestroy: () -> Unit = { => }
    // 文件类对话框的结果：C 桥在 GTK / 宿主线程上经 dialogOnResult 写入，
    // 阻塞等待的调用方醒来后读取。同一时刻只允许一个对话框（桥侧有互斥），单槽位够用。
    static var dialogResult: String = ""
}

/**
 * kind 字符串 → C 桥的对话框编号（与 native/bridge_linux.c、bridge_win.c 的取值一一对应）
 */
func dialogKindCode(kind: String): Int32 {
    match (kind) {
        case "warning" => 3
        case "error" => 4
        case "confirm" => 5
        case _ => 2
    }
}

/**
 * 对话框结果回调（C 桥 → 仓颉）：文件类对话框选中的路径经它送回。
 * 由 C 桥在自己的 UI 线程上调用，与 hostOnMessage 同一套路；先写槽位再由桥唤醒调用方。
 */
@C
func dialogOnResult(path: CString): Unit {
    try {
        HostGlobals.dialogResult = path.toString()
    } catch (e: Exception) {
        eprintln("[cj-tauri] dialog callback error: ${e}")
    }
}

/**
 * 创建当前平台的 WebView 宿主（对标 Tauri 2 的 runtime 选择）
 */
@When[os == "Linux"]
func createHost(): WebViewHost {
    return WebKitHost()
}

@When[os == "Windows"]
func createHost(): WebViewHost {
    return WebView2Host()
}
