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
