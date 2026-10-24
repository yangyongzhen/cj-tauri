package cjTauri

/**
 * 鸿蒙 ArkWeb 宿主（`@When[env == "ohos"]` 门禁）
 *
 * ## 为什么判据是 `env == "ohos"`
 *
 * 鸿蒙目标下 `os` 仍报 `Linux`（探针实测），与桌面 Linux 撞车；`arch` 只能把 x86_64 桌面
 * 与 aarch64 分开，可桌面 aarch64 Linux 一样是 `aarch64`——用它当判据会把「跑在 GTK 上」
 * 误判成「跑在 ArkWeb 上」。官方条件编译映射表给的是 `env`：`aarch64-linux-ohos` → `env == "ohos"`，
 * 桌面 Linux 是 `gnu`，两者才真正互斥（`docs/` 里的条件编译文档「目标平台和条件编译映射表」）。
 *
 * ## 为什么 ArkUI 组件不在这里
 *
 * 框架核心包一旦 import `kit.ArkUI` / `ohos.arkui.*`，**所有**消费方（含桌面构建）都要跟着
 * 拉 ArkUI 依赖。所以本文件只做「与 UI 无关的那半边」：页面来源定稿、脚本队列、IPC 接线、
 * 生命周期标志；建 `Web` 组件的那半边在应用侧（`ArkWebView` 样板），经 [ArkWebRuntime] 取用。
 *
 * ## 线程模型（与桌面两平台的根本差异）
 *
 * 桌面：`start()` 里阻塞着跑宿主事件循环，`waitForExit()` 等它退出。
 * 鸿蒙：ArkUI 的事件循环归系统所有（UI 线程），`start()` **不能**阻塞——它只登记页面来源，
 * 由 UI 线程上的 `Web` 组件在 build 时取走。于是 `TauriApp.run()` 必须跑在非 UI 线程
 * （应用在 Ability 里 `spawn`），UI 线程负责建树。
 *
 * 跨线程只走两条路：① 本文件的队列（`Mutex` 保护）② 页面消息经 `javaScriptProxy`
 * 同步进来。**不要在应用线程直接调 ArkWeb/ArkUI**——与桌面 Linux 侧
 * 「GTK/WebKit 调用必须在原生 pthread 内」同源的约束。
 */

@When[env == "ohos"]
import std.collection.*

@When[env == "ohos"]
import std.fs.File

@When[env == "ohos"]
import std.sync.*

@When[env == "ohos"]
import stdx.encoding.json.JsonArray

@When[env == "ohos"]
import stdx.encoding.json.JsonString

// 页面来源契约（load(source) 收敛，RFC §4.3）：Asset 由胶水注入的 rawfile 解析器材化
@When[env == "ohos"]
import cjTauri.platform.*

/**
 * 鸿蒙宿主的进程级运行时：沙箱目录、各窗口宿主、跨线程队列开关
 *
 * 应用要做两件事（都是「框架拿不到、只有 Ability 有」的东西）：
 * 1. 在 `onCreate` 里 `ArkWebRuntime.configure(context.filesDir)`——`run(html)` 没有
 *    `loadData` 可用（ArkWeb 的仓颉绑定没有这个 API），内联 HTML 只能写进沙箱再以 `file://` 加载；
 * 2. 在 `onWindowStageCreate` 里 `windowStage.loadContent("EntryView")`，并在**非 UI 线程**
 *    `spawn { app.run(html) }`——UI 线程要让给 ArkUI 建树。
 */
@When[env == "ohos"]
public class ArkWebRuntime {
    /* 应用沙箱目录（filesDir 下的子目录由本类自己创建）。空串 = 尚未 configure。 */
    static var sandboxDir: String = ""

    /* label → 宿主。UI 组件按 label 取自己的那一份；多窗口下不许共用一个实例。 */
    static let hosts: HashMap<String, ArkWebHost> = HashMap<String, ArkWebHost>()

    /* 应用级退出标志：鸿蒙的「关窗」等于「退出 Ability」，只能由应用侧执行 terminateSelf。 */
    static var quitRequested: Bool = false

    /* 队列锁：worker 线程写、UI 线程读（见文件头的线程模型）。 */
    static let queueLock: Mutex = Mutex()

    /**
     * 配置沙箱目录（必须在 `TauriApp.run()` 之前调用，且只调一次）
     *
     * 用 `context.filesDir`：鸿蒙上它是应用私有可写目录，进程重启后内容仍在，
     * 于是页面文件可以在**每次启动**重建（内容由应用决定，不做持久化依赖）。
     */
    public static func configure(filesDir: String): Unit {
        if (filesDir.size == 0) {
            eprintln("[cj-tauri] ArkWebRuntime.configure: filesDir is empty, run(html) will be rejected")
            return
        }
        ArkWebRuntime.sandboxDir = filesDir
        eprintln("[cj-tauri] ArkWeb sandbox: ${filesDir}")
    }

    /** 登记一个宿主（构造时调；同一 label 重复登记＝替换，与进程级唯一窗口的语义一致） */
    static func register(host: ArkWebHost): Unit {
        synchronized(ArkWebRuntime.queueLock) {
            ArkWebRuntime.hosts[host.label()] = host
        }
    }

    /** 注销（dispose 时调；对应的 UI 组件随后会被系统回收） */
    static func unregister(label: String): Unit {
        synchronized(ArkWebRuntime.queueLock) {
            ArkWebRuntime.hosts.remove(label)
        }
    }

    /**
     * 按 label 取宿主：**UI 侧（`ArkWebView` 组件）唯一的取用入口**
     *
     * 返回 None 是正常状态（应用先建树、`app.run()` 稍后才登记宿主），组件据此显示空白，
     * 下一轮轮询再取——不要在这里报错。
     */
    public static func hostFor(label: String): Option<ArkWebHost> {
        synchronized(ArkWebRuntime.queueLock) {
            match (ArkWebRuntime.hosts.get(label)) {
                case Some(h) => return Some(h)
                case None => return None
            }
        }
    }

    /** 应用级退出请求（`quit()` / 窗口销毁都置它；Ability 侧轮询后自己 `terminateSelf()`） */
    public static func requestQuit(): Unit {
        ArkWebRuntime.quitRequested = true
    }

    /** 是否已请求退出（应用在 Ability 里轮询它来决定要不要 terminateSelf） */
    public static func shouldQuit(): Bool {
        return ArkWebRuntime.quitRequested
    }
}

/**
 * 一条待应用侧呈现的原生消息框（`dialog:message` 命令的载荷）
 *
 * 为什么要过一道队列：ArkUI 的弹窗 `getUIContext().showAlertDialog(...)` 只能在**应用侧组件**
 * 里、且在 UI 线程上调（框架不碰 ArkUI，见文件头），而命令 handler 跑在 worker 线程上。
 * 于是框架只描述「弹什么」，呈现与点击结果交给 UI 侧回填。
 *
 * `kind` 原样透传（`dialog` 插件的语义：`info` / `warning` / `error` 只有一个「确定」，
 * `confirm` 才有取消）。按钮文案与布局属于呈现，由应用侧决定，框架不猜。
 */
@When[env == "ohos"]
public class ArkWebDialogRequest {
    public let id: Int64
    public let kind: String
    public let title: String
    public let message: String

    public init(id: Int64, kind: String, title: String, message: String) {
        this.id = id
        this.kind = kind
        this.title = title
        this.message = message
    }

    /** 是否「确定 / 取消」两键（其余 kind 只有一个确定键，弹出即成立） */
    public func isConfirm(): Bool {
        return this.kind == "confirm"
    }
}

/**
 * `showMessageDialog` 等 UI 侧回填的上限（毫秒）
 *
 * 桌面两平台在这里真的阻塞到用户点按钮，鸿蒙上只能等 UI 线程来取。窗口没建、页面没跑
 * 的情况下无限期钉住一个 worker 线程比超时更糟，所以给一个宽上限：超时就如实返回 false
 * 并在 stderr 里说清是「没弹出来」而不是「用户取消」——两者对调用方都是 false，但日志分得清。
 */
@When[env == "ohos"]
let CJ_ARKWEB_DIALOG_WAIT_MS: Int64 = 120000

/** 等回填的轮询间隔（毫秒）：只影响「点了按钮 → 命令返回」的延迟，与页面心跳无关 */
@When[env == "ohos"]
let CJ_ARKWEB_DIALOG_POLL_MS: Int64 = 20

/**
 * 一个鸿蒙窗口的宿主
 *
 * 与桌面宿主的分工差异：这里**所有**图形相关动作都只是「入队 / 记状态」，真正执行发生在
 * UI 线程（`ArkWebView` 组件的 build 与定时器里）。这样框架侧不需要任何 ArkUI 符号，
 * 也不会在 worker 线程上碰 ArkUI（那会 abort，见 AGENTS §4 的栈边界坑）。
 */
@When[env == "ohos"]
public class ArkWebHost <: WebViewHost {
    private let windowLabel: String
    // 资产解析器：胶水在 load 前注入（rawfile 材化）；鸿蒙没有 cwd 读盘兜底
    private var assetResolver: Option<AssetResolver> = None

    /* 页面来源：start(html) 先存 html、落盘后 pageUrl 才成立；startUrl 直接定 pageUrl。 */
    private var pageHtml: String = ""
    private var pageUrl: String = ""

    /* document-start 预执行脚本（插件 shim 与 label 注入走这条通道，顺序敏感）。 */
    private var initScripts: ArrayList<String> = ArrayList<String>()

    /* 待 UI 线程执行的脚本（runJs / 注入 / 回投都进这里，见 takePendingScripts）。 */
    private var pendingScripts: ArrayList<String> = ArrayList<String>()

    private var devToolsEnabled: Bool = false
    private var visible: Bool = true
    private var disposed: Bool = false
    private var quitFlag: Bool = false

    /* 取证计数：页面开始 / 结束加载各几次，桥日志按它对账（AGENTS §1 门禁 2）。 */
    private var pageBeginCount: Int64 = 0
    private var pageEndCount: Int64 = 0
    private var jsInCount: Int64 = 0

    /*
     * 原生对话框（showMessageDialog）的三个槽，全部受 ArkWebRuntime.queueLock 保护：
     * worker 线程入队并等待、UI 线程取走并回填，跨线程只经这两个动作交接。
     * id 单调自增（每窗一份），所以「晚到的答案」撞不上新请求。
     */
    private var dialogSeq: Int64 = 0
    private let pendingDialogs: ArrayList<ArkWebDialogRequest> = ArrayList<ArkWebDialogRequest>()
    private let awaitingDialogs: HashSet<Int64> = HashSet<Int64>()
    private let dialogAnswers: HashMap<Int64, Bool> = HashMap<Int64, Bool>()
    private var dialogRequestCount: Int64 = 0
    private var dialogAnswerCount: Int64 = 0

    /*
     * 菜单模型快照：worker 线程写（setMenu / setMenuItemState）、UI 线程读（menuModel），
     * 与上面三个对话框槽同受 queueLock 保护。ArkUI 那半边（bindMenu）在应用侧，
     * 框架这边只存模型——理由见 arkweb_menu.cj 的类注释。
     */
    private var menuRoot: ArrayList<ArkWebMenuItem> = ArrayList<ArkWebMenuItem>()
    private var menuItemCount: Int64 = 0
    private var menuClickCount: Int64 = 0

    private var messageHandler: (String) -> Unit = { _ => }
    private var shellHandler: (String) -> Unit = { _ => }
    private var destroyHandler: () -> Unit = { => }

    public init(label: String) {
        this.windowLabel = label
        ArkWebRuntime.register(this)
        eprintln("[cj-tauri] ArkWeb host created: label=\"${label}\"")
    }

    public func label(): String {
        return this.windowLabel
    }

    /**
     * 登记内联 HTML 页面（不阻塞：真正的组件由 UI 线程建）
     *
     * 与桌面不同，这里**没有** `loadData` 可调（ArkWeb 的仓颉绑定只给了 `loadUrl`），
     * 所以 HTML 先落盘到沙箱、再以 `file://` 交给 `Web` 组件。副作用要如实说：页面有了
     * 真实来源（`location.protocol == "file:"`），`fetch` / XHR 会被同源策略挡住——
     * 与 Tauri 2 在 `run(html)` 下的表现一致，不是本实现独有的限制。
     */
    public func start(html: String): Unit {
        this.pageHtml = html
        this.pageUrl = this.writeHtmlToSandbox(html)
        eprintln("[cj-tauri] ArkWeb page: label=\"${this.windowLabel}\" source=inline url=\"${this.pageUrl}\"")
    }

    /**
     * 登记 URL 页面（http(s):// 或 file://）
     *
     * 这条路径有真实来源，相对资源 / 动态 import / 前端路由都成立；`CJ_TAURI_DEV_URL`
     * 的 dev server 就靠它。注入时机见 `injectInitScriptsOnBegin` 的说明。
     */
    public func startUrl(url: String): Unit {
        this.pageHtml = ""
        this.pageUrl = url
        eprintln("[cj-tauri] ArkWeb page: label=\"${this.windowLabel}\" source=url url=\"${url}\"")
    }

    /**
     * 加载页面（唯一入口，RFC §4.3）
     *
     * 与桌面的差异：Asset **没有 cwd 读盘兜底**——hap 里没有工程目录，资产只能来自
     * 胶水注入的 resolver（rawfile 材化）。缺注入或资产缺失时如实报错，不静默白屏。
     */
    public func load(source: PageSource): Unit {
        match (source) {
            case Inline(html) => this.start(html)
            case Url(url) => this.startUrl(url)
            case DevServer(url) => this.startUrl(url)
            case Asset(name) =>
                match (this.assetResolver) {
                    case Some(r) =>
                        match (r.readText(name)) {
                            case Some(html) => this.start(html)
                            case None =>
                                throw AssetResolutionException("资产未找到：${name}（胶水注入的 rawfile 里没有这个资产，检查清单 [assets] 与骨架 rawfile 拷贝）")
                        }
                    case None =>
                        throw AssetResolutionException("资产 ${name} 未注入 AssetResolver（鸿蒙侧胶水须先把 rawfile 材化并注入解析器，再 load）")
                }
        }
    }

    /** 注入资产解析器（胶水在 load 前调用，rawfile 材化器） */
    public func setAssetResolver(resolver: Option<AssetResolver>): Unit {
        this.assetResolver = resolver
    }

    /**
     * 注册预执行脚本（必须早于 load，与桌面同一契约）
     *
     * 内联 HTML 走「拼进 head 最前」这条通道（真正早于页面脚本）；URL 页面只能等
     * `onPageBegin` 再 runJavaScript——那时页面顶层脚本可能已经跑过，**这是本平台的已知限制**，
     * 不是静默降级：首次注入会在 stderr 说明一次（见 `noteLateInjection`）。
     */
    public func addInitScript(js: String): Unit {
        if (js.size == 0) {
            return
        }
        this.initScripts.add(js)
    }

    public func reload(): Unit {
        this.enqueueScript("__cjTauriReloadRequest()", true)
    }

    public func setWindowConfig(config: WindowConfig): Unit {
        // 鸿蒙应用窗口由 Ability 的 WindowStage 决定，逻辑尺寸概念与桌面不同：
        // 这里如实说明不生效，而不是假装设成功（能力位也不含任何窗口控制位）。
        let _ = config
        eprintln("[cj-tauri] ArkWeb: window config is managed by WindowStage on this platform (ignored)")
    }

    public func setDevTools(enabled: Bool): Unit {
        this.devToolsEnabled = enabled
        // 真正调 setWebDebuggingAccess 的时机在 UI 侧（controller 就绪之后）。
        eprintln("[cj-tauri] ArkWeb: web debugging requested: ${enabled}")
    }

    public func openDevTools(): Unit {
        // ArkWeb 的调试走「设备侧 Web 调试」通道，没有桌面那种独立 DevTools 窗口。
        eprintln("[cj-tauri] ArkWeb: openDevTools is not available on this platform (use web debugging)")
    }

    /* ---- 菜单：框架存模型，应用侧用 bindMenu 画（见 arkweb_menu.cj 的类注释） ---- */

    /**
     * 收下应用给的菜单线路格式（`MenuModel.toWire()`），解析成快照存起来。
     *
     * **不阻塞、也不画界面**：真正的菜单由应用侧的 `ArkWebView` 在 `bindMenu` 里画，
     * UI 线程经 [menuModel] 取快照。这样框架包不引用 ArkUI（AGENTS §4 的 SIGSEGV 坑）。
     */
    public func setMenu(wire: String): Unit {
        let parsed = parseArkWebMenuWire(wire)
        var rows: Int64 = 0
        synchronized(ArkWebRuntime.queueLock) {
            this.menuRoot = parsed
            rows = countMenuItems(parsed)
            this.menuItemCount = rows
        }
        eprintln("[cj-tauri] ArkWeb: menu applied (${wire.size} bytes, ${rows} item(s), app-side bindMenu)")
    }

    /**
     * 运行期改单项状态（按 id 找，找不到静默忽略——与桌面两平台同口径）。
     *
     * 这里**不再抛异常**：菜单模型住在本进程，改动是纯内存动作；UI 下一轮 [menuModel]
     * 拿到的就是新状态（`bindMenu` 每次 build 重新生成，不需要额外通知）。
     */
    public func setMenuItemState(id: String, enabled: Bool, checked: Bool): Unit {
        var hit = false
        synchronized(ArkWebRuntime.queueLock) {
            for (item in this.menuRoot) {
                match (item.find(id)) {
                    case Some(node) =>
                        node.enabled = enabled
                        node.checked = checked
                        hit = true
                    case None => ()
                }
            }
        }
        eprintln("[cj-tauri] ArkWeb: menu item state id=\"${id}\" enabled=${enabled} checked=${checked} hit=${hit}")
    }

    /**
     * UI 线程取菜单快照（每次一份深拷贝，UI 改它不会动到宿主里的模型）。
     *
     * 应用侧的 `ArkWebView` 在 `build()` 里按它生成 `bindMenu` 的 `MenuElement` 数组；
     * 没有菜单时回空表（应用照常建树，别等菜单才画 Web）。
     */
    public func menuModel(): ArrayList<ArkWebMenuItem> {
        let out = ArrayList<ArkWebMenuItem>()
        synchronized(ArkWebRuntime.queueLock) {
            for (item in this.menuRoot) {
                out.add(item.snapshot())
            }
        }
        return out
    }

    /**
     * 应用侧 UI 里「这一项被点了」→ 回投 shell 事件。
     *
     * 报文与桌面 C 桥的 `cj_core_menu_clicked` **逐字同形**
     * （`{"kind":"menu","id":…,"enabled":…,"checked":…}`），于是应用层的 `onShellEvent`、
     * 前端 `menu:click`、以及应用按事件同步自己模型的代码都不用分平台。
     *
     * 勾选项的翻转由本函数做（与 Windows 侧「Win32 不替我们翻，自己翻」同口径）：
     * 报出去的是**翻转后**的状态，页面照它更新即可。
     */
    public func noteMenuClick(id: String): Unit {
        var enabled = true
        var checked = false
        var found = false
        synchronized(ArkWebRuntime.queueLock) {
            for (item in this.menuRoot) {
                match (item.find(id)) {
                    case Some(node) =>
                        if (node.isCheckbox()) {
                            node.checked = !node.checked
                        }
                        enabled = node.enabled
                        checked = node.checked
                        found = true
                    case None => ()
                }
            }
        }
        if (!found) {
            eprintln("[cj-tauri] ArkWeb: menu click ignored (id=\"${id}\" is not in the current menu)")
            return
        }
        this.menuClickCount++
        eprintln("[cj-tauri] ArkWeb: menu clicked id=\"${id}\" enabled=${enabled} checked=${checked}")
        this.shellHandler("{\"kind\":\"menu\",\"id\":\"${arkWebJsonEscape(id)}\",\"enabled\":${enabled}," +
            "\"checked\":${checked}}")
    }

    public func setTitlebarSubtitle(text: String): Unit {
        let _ = text
    }

    public func setDragDropPolicy(enabled: Bool, files: Bool): Unit {
        let _ = enabled
        let _ = files
        eprintln("[cj-tauri] ArkWeb: drag/drop policy unsupported (host capability bit is 0)")
    }

    public func setGlobalHotkeys(wire: String): Unit {
        let _ = wire
    }

    public func setTray(wire: String): Unit {
        let _ = wire
    }

    public func setWindowVisible(visible: Bool): Unit {
        this.visible = visible
        // 可见性由 ArkUI 的组件树决定（`visibility` 属性），宿主只记状态供 UI 侧读取。
        eprintln("[cj-tauri] ArkWeb: window visible -> ${visible}")
    }

    public func setMinimizeToTray(enabled: Bool): Unit {
        let _ = enabled
    }

    /** 能力位全 0：鸿蒙侧还没有任何一项宿主级能力通过实机取证（AGENTS §1 门禁 4） */
    public func hostCapabilities(): Int32 {
        /*
         * 菜单是鸿蒙侧第一项真落地的宿主能力：框架存模型（arkweb_menu.cj）、应用侧 bindMenu 画、
         * 点击经 noteMenuClick 回投（报文与桌面同形）。其余位仍为 0——判据是「仓颉侧有没有 API」：
         * 托盘（鸿蒙无系统托盘）、全局快捷键（只有组件级 keyboardshortcut）、拖入文件（SDK 只有
         * 拖出侧的 drag / dragPreview，没有 drop 回调）、通知（SDK 无 notification_manager 模块）、
         * 标题栏副标题（无 setWindowTitle）。AGENTS §1 门禁 4：没有实机证据的位置 1。
         */
        return CJ_CAP_MENU
    }

    public func setShellHandler(handler: (String) -> Unit): Unit {
        this.shellHandler = handler
    }

    public func setDestroyHandler(handler: () -> Unit): Unit {
        this.destroyHandler = handler
    }

    public func showFileDialog(save: Bool, title: String, filter: String): String {
        let _ = save
        let _ = title
        let _ = filter
        eprintln("[cj-tauri] ArkWeb: native file dialog unsupported (needs a picker module)")
        return ""
    }

    public func showFileDialogPreset(save: Bool, title: String, filter: String, defaultName: String): String {
        let _ = defaultName
        return this.showFileDialog(save, title, filter)
    }

    public func showFolderDialog(title: String): String {
        let _ = title
        eprintln("[cj-tauri] ArkWeb: native folder dialog unsupported (needs a picker module)")
        return ""
    }

    /**
     * 原生消息框（`dialog:message` 命令的落点）
     *
     * 与桌面的差异：桌面在 C 桥里**同步阻塞**到用户点按钮；鸿蒙的弹窗只有 ArkUI 侧能做，
     * 所以这里退成「入队 → 有界轮询等 UI 侧回填」。等待发生在命令 worker 线程上
     * （命令分发本来就是异步的，见 AGENTS §2），不占 UI 线程，窗口照常响应。
     *
     * 返回 false 的三种情况要在日志里分得清：宿主已销毁（拒绝）、UI 侧没来取（超时）、
     * 用户点了取消（answered + confirmed=false）。
     */
    public func showMessageDialog(kind: String, title: String, message: String): Bool {
        if (this.disposed) {
            eprintln("[cj-tauri] ArkWeb dialog rejected: label=\"${this.windowLabel}\" (host disposed)")
            return false
        }
        var id: Int64 = 0
        synchronized(ArkWebRuntime.queueLock) {
            this.dialogSeq += 1
            id = this.dialogSeq
            this.dialogRequestCount += 1
            this.pendingDialogs.add(ArkWebDialogRequest(id, kind, title, message))
            this.awaitingDialogs.add(id)
        }
        eprintln(
            "[cj-tauri] ArkWeb dialog queued: label=\"${this.windowLabel}\" id=${id} kind=\"${kind}\" title=\"${title}\""
        )
        var waited: Int64 = 0
        while (waited < CJ_ARKWEB_DIALOG_WAIT_MS) {
            var answered = false
            var confirmed = false
            synchronized(ArkWebRuntime.queueLock) {
                if (this.dialogAnswers.contains(id)) {
                    confirmed = this.dialogAnswers[id]
                    this.dialogAnswers.remove(id)
                    answered = true
                }
            }
            if (answered) {
                eprintln(
                    "[cj-tauri] ArkWeb dialog answered: label=\"${this.windowLabel}\" id=${id} confirmed=${confirmed}"
                )
                return confirmed
            }
            sleep(Duration.millisecond * CJ_ARKWEB_DIALOG_POLL_MS)
            waited += CJ_ARKWEB_DIALOG_POLL_MS
        }
        synchronized(ArkWebRuntime.queueLock) {
            this.awaitingDialogs.remove(id)
            this.dropPendingDialog(id)
            this.dialogAnswers.remove(id)
        }
        eprintln(
            "[cj-tauri] ArkWeb dialog timed out: label=\"${this.windowLabel}\" id=${id} after ${CJ_ARKWEB_DIALOG_WAIT_MS}ms (UI side never answered; this is NOT a user cancel)"
        )
        return false
    }

    /**
     * 取一条待呈现的对话框（**只在 UI 线程调**：`ArkWebView` 组件的页面心跳回调里）
     *
     * 取走即从队列移除，所以同一个请求不会弹两次；返回 None 是绝大多数心跳的正常结果。
     */
    public func takePendingDialog(): Option<ArkWebDialogRequest> {
        synchronized(ArkWebRuntime.queueLock) {
            if (this.pendingDialogs.isEmpty()) {
                return None
            }
            let request = this.pendingDialogs[0]
            this.pendingDialogs.remove(at: 0)
            return Some(request)
        }
    }

    /**
     * 回填用户的选择（**只在 UI 线程调**：弹窗按钮的回调里）
     *
     * 只接受仍在等待的 id：超时之后等待方已经放弃，这时再记一个答案会把它一直挂在这个槽里
     * （没人取走），所以按 `awaitingDialogs` 校验一次，并在日志里说明被丢弃的那次点击。
     */
    public func answerDialog(id: Int64, confirmed: Bool): Unit {
        var accepted = false
        synchronized(ArkWebRuntime.queueLock) {
            if (this.awaitingDialogs.contains(id)) {
                this.awaitingDialogs.remove(id)
                this.dialogAnswers[id] = confirmed
                this.dialogAnswerCount += 1
                accepted = true
            }
        }
        if (accepted) {
            eprintln(
                "[cj-tauri] ArkWeb dialog answer: label=\"${this.windowLabel}\" id=${id} confirmed=${confirmed}"
            )
            return
        }
        eprintln(
            "[cj-tauri] ArkWeb dialog answer dropped: label=\"${this.windowLabel}\" id=${id} confirmed=${confirmed} (no longer awaiting)"
        )
    }

    /** 从待呈现队列里按 id 移除（超时清场用；调用方必须已持有 `queueLock`） */
    private func dropPendingDialog(id: Int64): Unit {
        var index: Int64 = 0
        while (index < this.pendingDialogs.size) {
            if (this.pendingDialogs[index].id == id) {
                this.pendingDialogs.remove(at: index)
                return
            }
            index += 1
        }
    }

    /**
     * 写文本进系统剪贴板（鸿蒙 = 原生 pasteboard，见 `clipboard_bridge.cj` 的鸿蒙段）
     *
     * 返回 false 只有三种可能：句柄拿不到、UDMF 对象建不出来、平台拒绝这次写入。
     * **不要把 false 读成「暂时没接」**——这条能力在鸿蒙上已经接了，false 就是真失败。
     */
    public func clipboardWriteText(text: String): Bool {
        return arkwebClipboardWriteText(text)
    }

    /**
     * 读系统剪贴板文本：None = 空 / 非文本 / 平台拒绝（含缺 `READ_PASTEBOARD` 权限）
     *
     * 三种 None 对调用方是同一个「没拿到」——接口契约就是 Option，不在这儿编造区分。
     */
    public func clipboardReadText(): Option<String> {
        return arkwebClipboardReadText()
    }

    public func notify(title: String, body: String): Bool {
        let _ = title
        let _ = body
        eprintln("[cj-tauri] ArkWeb: notification unsupported (host capability bit is 0)")
        return false
    }

    /**
     * 在页面里执行一段脚本（框架的 `resolve` / `event` 回投就走这条）
     *
     * 不直接调 `controller.runJavaScript`：那个 API 属于 UI 线程，而本方法几乎总是从
     * IPC worker 线程进来（命令异步分发，见 AGENTS §2）。所以只入队，由 UI 侧的定时器取走。
     * 这样「回投顺序」也自然跟着队列走。
     */
    public func runJs(script: String): Unit {
        if (script.size == 0 || this.disposed) {
            return
        }
        this.enqueueScript(script, true)
    }

    /**
     * 请求退出
     *
     * 鸿蒙没有「关掉这个窗口」这种宿主动作：窗口归 Ability，退出得由应用 `terminateSelf()`。
     * 所以这里只置标志（`shouldQuit()` 与 `ArkWebRuntime.shouldQuit()` 都能读到），
     * 应用据此结束自己的生命周期；框架不假装自己关掉了窗口。
     */
    public func quit(): Unit {
        if (this.quitFlag) {
            return
        }
        this.quitFlag = true
        ArkWebRuntime.requestQuit()
        eprintln("[cj-tauri] ArkWeb: quit requested: label=\"${this.windowLabel}\" (app should terminateSelf)")
    }

    public func setMessageHandler(handler: (String) -> Unit): Unit {
        this.messageHandler = handler
    }

    public func shouldQuit(): Bool {
        return this.quitFlag || ArkWebRuntime.shouldQuit()
    }

    public func dispose(): Unit {
        if (this.disposed) {
            return
        }
        this.disposed = true
        ArkWebRuntime.unregister(this.windowLabel)
        eprintln(
            "[cj-tauri] ArkWeb host disposed: label=\"${this.windowLabel}\" pageBegin=${this.pageBeginCount} pageEnd=${this.pageEndCount} jsIn=${this.jsInCount} dialogRequested=${this.dialogRequestCount} dialogAnswered=${this.dialogAnswerCount}"
        )
    }

    /* ------------------------- UI 侧（ArkWebView 组件）取用面 ------------------------- */

    /**
     * 组件要加载的地址（空串 = 还没登记，组件应保持空白并下一轮再问）
     *
     * 为什么可能为空：应用先建 UI 树、再 `spawn { app.run(html) }`，两者先后不定。
     * 组件拿到空串不是错误，是正常的启动竞态，别在这里打日志刷屏。
     */
    public func currentUrl(): String {
        return this.pageUrl
    }

    /** 是否要求可见（组件据此设 `visibility`）；隐藏态页面照常跑，还原入口由应用给 */
    public func isVisible(): Bool {
        return this.visible
    }

    /** 是否要求开启 Web 调试（组件在建 controller 后调 `setWebDebuggingAccess`） */
    public func devToolsWanted(): Bool {
        return this.devToolsEnabled
    }

    /**
     * 取走全部待执行脚本（**必须在 UI 线程调用**）
     *
     * 取走即清空：这些脚本的语义是「尽快执行一次」，重复执行会把 resolve 投两次
     * （页面侧 pending 表按 id 匹配，重复投递会让第二次变空操作，但语义仍应保持一次）。
     */
    public func takePendingScripts(): ArrayList<String> {
        let out = ArrayList<String>()
        synchronized(ArkWebRuntime.queueLock) {
            for (s in this.pendingScripts) {
                out.add(s)
            }
            this.pendingScripts.clear()
        }
        return out
    }

    /**
     * 取走 init 脚本（页面开始加载时调一次：内联 HTML 已拼进 head，这里的只用于 URL 页面）
     *
     * 不做「取走即清空」：URL 页面的 reload 后仍需要同一批 shim，清空会让第二次加载丢掉插件。
     */
    public func initScriptsSnapshot(): ArrayList<String> {
        let out = ArrayList<String>()
        synchronized(ArkWebRuntime.queueLock) {
            for (s in this.initScripts) {
                out.add(s)
            }
        }
        return out
    }

    /**
     * 页面轮询泵的原生端点（`javaScriptProxy` 的 `poll` 方法，UI 线程同步调用）
     *
     * 为什么是「页面拉」而不是「原生推」：ArkUI 的仓颉绑定没有定时器、也没有 UIContext，
     * 框架线程既定不了时也不能安全碰 ArkUI（AGENTS §4 的栈边界坑）；而页面里 `setInterval`
     * 是最普通的东西。于是把「什么时候执行待发脚本」交给页面，原生只做同步的取队列动作。
     *
     * 返回值是**脚本字符串的 JSON 数组**（不是 JSON 报文）：页面用间接 eval 逐条执行，
     * 这样 `_dispatch({...})` 这类语句能直接跑在全局作用域，而不是变成字符串。
     * 空队列返回 `[]`——页面侧据此连 JSON.parse 都不做。
     */
    public func pollScriptsJson(): String {
        synchronized(ArkWebRuntime.queueLock) {
            if (this.pendingScripts.isEmpty()) {
                return "[]"
            }
            let arr = JsonArray()
            for (s in this.pendingScripts) {
                arr.add(JsonString(s))
            }
            this.pendingScripts.clear()
            return arr.toString()
        }
    }

    /** 页面开始加载（UI 侧回调；用于注入与取证计数） */
    public func notePageBegin(): Unit {
        synchronized(ArkWebRuntime.queueLock) {
            this.pageBeginCount += 1
        }
        eprintln("[cj-tauri] ArkWeb page begin: label=\"${this.windowLabel}\" count=${this.pageBeginCount}")
    }

    /** 页面加载结束（UI 侧回调）；`system:host` 的取证就看这两个计数是否对得上 */
    public func notePageEnd(): Unit {
        synchronized(ArkWebRuntime.queueLock) {
            this.pageEndCount += 1
        }
        eprintln("[cj-tauri] ArkWeb page end: label=\"${this.windowLabel}\" count=${this.pageEndCount}")
    }

    /**
     * 页面 → 原生：`javaScriptProxy` 的同步回调（UI 线程）
     *
     * 报文格式与桌面两平台**同一份**（`{type:"invoke"|"emit", id, cmd, event, window, ...}`），
     * 所以 IPC 层不需要为鸿蒙分叉。这里只做计数与转发，不做校验——校验在 `IpcHub`。
     */
    public func acceptPageMessage(raw: String): Unit {
        if (raw.size == 0 || this.disposed) {
            return
        }
        // reload 是**控制消息、不进 IPC hub**：桌面两平台由 C 桥在投递前截掉（CJT_RELOAD_MSG），
        // 鸿蒙没有 C 桥这一层，拦截点就在这里。用子串判断而不是解析 JSON：报文由本框架自己的
        // 桥脚本产生，形状固定；解析失败会把 reload 静默丢掉，反而更难查。
        match (raw.indexOf("\"type\":\"reload\"")) {
            case Some(_) =>
                eprintln("[cj-tauri] ArkWeb: reload requested by page: label=\"${this.windowLabel}\"")
                this.reload()
                return
            case None => ()
        }
        // 拉取心跳同理：页面只是「叫一声」，真正的推送由 UI 侧（组件的 post 回调）用
        // runJavaScript 完成——`javaScriptProxy` 的返回值传不回页面（踩坑文档 8.1.5.1），
        // 所以这条报文不进 IPC hub，这里直接返回。
        match (raw.indexOf("\"type\":\"pull\"")) {
            case Some(_) => return
            case None => ()
        }
        synchronized(ArkWebRuntime.queueLock) {
            this.jsInCount += 1
        }
        this.messageHandler(raw)
    }

    /** 页面消息计数（取证：`js -> native` 次数对账，AGENTS §1 门禁 2） */
    public func messageCount(): Int64 {
        return this.jsInCount
    }

    /* ------------------------------ 内部辅助 ------------------------------ */

    /**
     * 入队一段脚本
     *
     * `direct` 只是留给调用点自说明用的（两处语义相同，暂不分支）；保留它是因为将来
     * 「document-start 注入」与「普通 runJs」可能需要不同的排队策略（前者要在 onPageBegin 之前）。
     */
    private func enqueueScript(script: String, direct: Bool): Unit {
        let _ = direct
        synchronized(ArkWebRuntime.queueLock) {
            this.pendingScripts.add(script)
        }
    }

    /**
     * 把内联 HTML 落盘并返回 `file://` 地址
     *
     * 为什么必须落盘：ArkWeb 的仓颉绑定没有 `loadData`（只有 `loadUrl`），内联字符串
     * 无法直接喂给组件。文件名按 label 分，多窗口互不覆盖。
     * 失败（未 configure、磁盘不可写）时返回空串——组件据此保持空白，stderr 留凭证，
     * **不**抛异常把 `app.run()` 带走（`run()` 抛异常的表现是应用秒退、hilog 一行都没有）。
     */
    private func writeHtmlToSandbox(html: String): String {
        if (ArkWebRuntime.sandboxDir.size == 0) {
            eprintln("[cj-tauri] ArkWeb: run(html) rejected: ArkWebRuntime.configure(filesDir) was not called")
            return ""
        }
        let path = "${ArkWebRuntime.sandboxDir}/cj-tauri-${this.windowLabel}.html"
        try {
            File.writeTo(path, this.injectBootstrap(html).toArray())
        } catch (e: Exception) {
            eprintln("[cj-tauri] ArkWeb: failed to write page to sandbox: ${path}: ${e.message}")
            return ""
        }
        return "file://${path}"
    }

    /**
     * 把 label、桥脚本与 init 脚本拼进 HTML 的 head 最前
     *
     * 为什么走这条而不是 `onPageBegin` 里 runJavaScript：ArkWeb 的仓颉绑定没有
     * `javaScriptOnDocumentStart`（桌面两平台都有对应 API），`onPageBegin` 是能拿到的最早时机，
     * 那时页面顶层脚本**可能已经跑过**——内联页面因此改走「直接拼进 HTML」，语义才与桌面一致
     * （document-start，早于页面脚本）。
     *
     * 拼装顺序：label → 桥 → init 脚本。init 脚本（插件 shim）可能读 `__CJ_TAURI_LABEL__`，
     * 所以 label 必须最先；桥要早于 shim，因为 shim 会调用 `invoke`。
     */
    private func injectBootstrap(html: String): String {
        let scripts = StringBuilder("<script>${arkWebLabelScript(this.windowLabel)}</script>")
        scripts.append("<script>${ARKWEB_BRIDGE_JS}</script>")
        for (js in this.initScriptsSnapshot()) {
            scripts.append("<script>${js}</script>")
        }
        let block = scripts.toString()
        // 插在 head 开标签之后（最早的可执行位置）；没有 head 就找 body，都没有就整段前置。
        match (html.indexOf("<head>")) {
            case Some(at) => return "${html[0..at + 6]}${block}${html[at + 6..html.size]}"
            case None => ()
        }
        match (html.indexOf("<body")) {
            case Some(at) => return "${html[0..at]}${block}${html[at..html.size]}"
            case None => ()
        }
        return "${block}${html}"
    }
}

/* 菜单项总数（含各级子孙）：只用于日志对账，不参与渲染 */
@When[env == "ohos"]
private func countMenuItems(items: ArrayList<ArkWebMenuItem>): Int64 {
    var total: Int64 = 0
    for (item in items) {
        total++
        total += countMenuItems(item.children)
    }
    return total
}

/* shell 报文里 id 的最小转义：只处理 `\` 与 `"`（与 C 侧 cj_json_escape_into 同口径） */
@When[env == "ohos"]
private func arkWebJsonEscape(text: String): String {
    // 迭代 String 得到的是 UInt8 字节（AGENTS §4），`String(byte)` 并不接受 UInt8——
    // 这里只需要处理两个 ASCII 元字符，直接走 replace 更稳，也不碰字节/码点的口径。
    return text.replace("\\", "\\\\").replace("\"", "\\\"")
}
