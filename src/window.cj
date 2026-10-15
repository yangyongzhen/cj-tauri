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

    // 最小化到托盘（B 项）：用户在标题栏点「最小化」时窗口**隐藏**（从任务栏消失、只留托盘图标），
    // 而不是缩成任务栏按钮。默认 false = 老行为不变。
    // 必须与服务端配套：应用得先 setTray(...)，否则隐藏之后界面上没有任何入口——
    // 框架不替应用拦这个组合（它不知道应用的托盘菜单长什么样），但真到最小化那一刻平台会
    // 复核托盘是否**真的**装上了：没装就降级为普通最小化并打一行 stderr，避免「窗口没了也点不回来」。
    public var minimizeToTray: Bool

    public init() {
        this.title = "cj-tauri"
        this.width = 900
        this.height = 640
        this.devTools = true
        this.iconPath = ""
        this.minimizeToTray = false
    }

    public init(title: String, width: Int64, height: Int64) {
        this.title = title
        this.width = width
        this.height = height
        this.devTools = true
        this.iconPath = ""
        this.minimizeToTray = false
    }
}
