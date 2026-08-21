package cjTauri

/**
 * WebView 宿主层（对标 Tauri WRY + TAO）
 *
 * 平台差异抽象：Linux 桌面 = webkit2gtk（经 C 桥在原生线程运行）；
 * 鸿蒙 = ArkWeb（arkweb_cangjie_wrapper，预留）。
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
}
