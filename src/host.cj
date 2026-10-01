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
     * 原生 → JS：在 WebView 中执行脚本
     */
    public func runJs(js: String): Unit

    /**
     * 退出应用
     */
    public func quit(): Unit

    /**
     * 装配前端消息回调（WebView 送来的 JSON 字符串 → IPC hub）
     */
    public func setMessageHandler(handler: (String) -> Unit): Unit

    /**
     * 宿主事件循环是否已退出（窗口关闭等），app.run 据此阻塞与收尾
     */
    public func shouldQuit(): Bool
}

/**
 * C 桥原生线程 → 仓颉回调的全局槽位。
 * 各平台宿主在 start() 时把自己的回调装配到这里，C 侧的 @C 函数经此转入仓颉闭包。
 */
class HostGlobals {
    static var onMessage: (String) -> Unit = { _ => }
    static var onDestroy: () -> Unit = { => }
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
