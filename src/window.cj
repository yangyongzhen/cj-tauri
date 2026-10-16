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

    // 自适应开窗（可选，B 项之后新增）：设了它就按**屏幕工作区的百分比**算窗口尺寸，再夹到
    // min/max；工作区 = 去掉面板 / 任务栏的可摆放区域，由平台在**建窗那一刻**（自家宿主线程）
    // 读取——拿不到就如实退回上面的 width/height 并打一行 stderr。不设（None）行为一字不变。
    public var autoSize: ?WindowAutoSize

    public init() {
        this.title = "cj-tauri"
        this.width = 900
        this.height = 640
        this.devTools = true
        this.iconPath = ""
        this.minimizeToTray = false
        this.autoSize = None
    }

    public init(title: String, width: Int64, height: Int64) {
        this.title = title
        this.width = width
        this.height = height
        this.devTools = true
        this.iconPath = ""
        this.minimizeToTray = false
        this.autoSize = None
    }
}

/**
 * 自适应开窗策略（配合 WindowConfig.autoSize）
 *
 * 语义：先按 `percent`% 的**屏幕工作区**算，再夹到 `min*..max*`（0 = 该维不限），最后兜到 320x240。
 * 例：`WindowConfig("我的应用", 1080, 760)` 配 `WindowAutoSize(80)` →
 * 1920x1080 的屏上开 1536x864；4K 屏上被 max 夹住；小屏被 min 兜住。
 *
 * 为什么要平台参与：屏幕工作区只有平台（GTK 的 monitor / Win32 的 SPI_GETWORKAREA）拿得到，
 * 而这类调用只能在桥的宿主线程上做——所以框架把「策略」与「定稿」分开：仓颉侧 start() 之前
 * 只登记策略（同 cj_bridge_set_window 的时机），平台在建窗那一刻解析成最终尺寸。
 */
public class WindowAutoSize {
    public var percent: Int64
    public var minWidth: Int64
    public var minHeight: Int64
    public var maxWidth: Int64
    public var maxHeight: Int64

    /**
     * @param percent 屏幕工作区百分比（1..100）
     */
    public init(percent: Int64) {
        this.percent = percent
        this.minWidth = 0
        this.minHeight = 0
        this.maxWidth = 0
        this.maxHeight = 0
    }

    /** 设置最小尺寸（0 = 不限） */
    public func minSize(w: Int64, h: Int64): WindowAutoSize {
        this.minWidth = w
        this.minHeight = h
        return this
    }

    /** 设置最大尺寸（0 = 不限；大屏上防止窗口铺满整个 4K） */
    public func maxSize(w: Int64, h: Int64): WindowAutoSize {
        this.maxWidth = w
        this.maxHeight = h
        return this
    }
}
