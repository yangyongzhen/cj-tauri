package cjTauri

/**
 * 窗口配置（对标 tauri.conf.json 的 app.windows[] 项）
 *
 * 用法：
 *   let app = TauriApp().window(WindowConfig("我的应用", 1200, 800))
 *
 *   // 要自定义窗口图标（可选）：
 *   var cfg = WindowConfig("我的应用", 1200, 800)
 *   cfg.iconPath = "assets/app.ico"
 *   let app = TauriApp().window(cfg)
 *
 * 默认值与此前桥内硬编码的值一致（标题 cj-tauri / 900x640），
 * 因此不调用 window() 的应用行为不变。
 */
public class WindowConfig {
    public var title: String
    public var width: Int64
    public var height: Int64
    // 是否允许打开开发者工具（WebView2 的 AreDevToolsEnabled / WebKit 的 developer extras）
    public var devTools: Bool
    // 窗口图标路径：Windows 用 .ico（LoadImageW 只认 .ico）；Linux 走 GTK，png/ico 都行。
    // 空字符串 = 用系统默认图标（默认行为，不影响老应用）。
    public var iconPath: String

    public init() {
        this.title = "cj-tauri"
        this.width = 900
        this.height = 640
        this.devTools = true
        this.iconPath = ""
    }

    public init(title: String, width: Int64, height: Int64) {
        this.title = title
        this.width = width
        this.height = height
        this.devTools = true
        this.iconPath = ""
    }
}
