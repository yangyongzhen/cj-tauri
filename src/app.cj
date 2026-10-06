package cjTauri

import std.collection.*
import std.env.*
import stdx.encoding.json.*

/**
 * 附加窗口的登记项（试验性 API `TauriApp.addWindow` 的装配状态）
 *
 * 为什么宿主在这里就建好、html 也先留着：窗口表要在 run() 之前定稿（`hostOf` 当场可用），
 * 而原生窗口要等 run() 才创建——两者分开存，正好对上宿主自己的两段式节奏
 * （宿主对象构造时就有、原生窗口 start() 时才建）。
 */
class ExtraWindowSpec {
    let label: String
    let host: WebViewHost
    let html: String

    init(label: String, host: WebViewHost, html: String) {
        this.label = label
        this.host = host
        this.html = html
    }
}

/**
 * TauriApp 装配（对标 tauri::Builder / App）
 *
 * 用法：
 *   let app = TauriApp()
 *   app.register("greet", GreetCommand())
 *   app.addCapabilityJson(...)   // 或 addCapability(cap)
 *   app.run(html)                // 启动宿主并阻塞
 *
 * 多窗口（试验性，批次 3 的最小切片）：`addWindow(label, config, html)` 登记附加窗口，
 * run() / runUrl() 统一启动；事件按 label 路由（`emitToWindow` / `hostOf`）。
 */
public class TauriApp <: AppHost {
    private var hub: IpcHub = IpcHub()
    private var capabilities: CapabilityRegistry = CapabilityRegistry()
    private var host: WebViewHost = createHost(DEFAULT_WINDOW_LABEL)
    private var config: WindowConfig = WindowConfig()
    // 窗口注册表（批次 2）：单窗口阶段只有一条 "main"，多窗口时是「label → 宿主」的唯一权威来源
    private var windows: WindowRegistry = WindowRegistry()
    // 附加窗口（批次 3 多窗口 UI 的最小切片，试验性）：addWindow() 登记、run() / runUrl() 统一启动
    private var extraWindows: ArrayList<ExtraWindowSpec> = ArrayList<ExtraWindowSpec>()
    // 应用层留存的菜单模型（label → 模型）：setMenu() 记一份，供「只改某一维状态」反查另一维
    private var menus: HashMap<String, MenuModel> = HashMap<String, MenuModel>()
    // 应用层的 shell 事件钩子（对标 Tauri 的 on_menu_event）：框架分发时先跑钩子、再投前端事件
    private var shellHooks: ArrayList<(String, String) -> Unit> = ArrayList<(String, String) -> Unit>()
    private var started: Bool = false
    private var plugins: ArrayList<Plugin> = ArrayList<Plugin>()
    // 各插件 jsShim() 收集成的「预执行脚本」列表，prepare() 时定稿，run / runUrl 时交给宿主
    private var pluginScripts: ArrayList<String> = ArrayList<String>()

    public init() {}

    /**
     * 设置窗口配置（标题 / 尺寸），对标 tauri.conf.json 的 app.windows
     */
    public func window(config: WindowConfig): TauriApp {
        this.config = config
        return this
    }

    /**
     * 登记一个附加窗口（**试验性**：批次 3「多窗口 UI」的最小切片，先给出可验证的通路）
     *
     * 语义：本方法只**登记 + 装配宿主**，原生窗口在 run() / runUrl() 里统一创建——
     * 与默认窗口「构造时有宿主对象、start() 时才建窗口」是同一套节奏（WebViewHost 的契约）。
     * 因此必须在 run() / runUrl() 之前调用；登记后 `hostOf(label)` 立刻可用。
     *
     * 现在**只接内联 HTML**（URL 变体等真实需求出现再加，判据见架构文档 §5）；
     * 空 label / 重复 label 在调用点直接抛异常（WindowRegistry.add 的约定，不延迟到 run）。
     *
     * 已知限制（**未解决**，架构文档 §7.5 的残余项）：`onDestroy` 与对话框结果回调不带宿主 id，
     * 多窗口下分不清是哪个窗口关的；对话框仍是同一时刻一个（桥侧互斥）。本方法不解这两条。
     */
    public func addWindow(label: String, config: WindowConfig, html: String): TauriApp {
        if (this.started) {
            throw CommandException("addWindow 必须在 run() / runUrl() 之前调用（页面加载前窗口表要定稿）")
        }
        let host = createHost(label)
        host.setWindowConfig(config)
        // label 注入与默认窗口走同一条通道（document-start 预执行脚本，桥 JS 懒读，先后顺序无所谓）
        host.addInitScript("window.__CJ_TAURI_LABEL__ = ${JsonString(label)};")
        // 登记放在这里（而不是 run 里）：重复 label / 空 label 当场报错，调用点即可见
        this.windows.add(WindowRecord(label, host, config))
        this.extraWindows.add(ExtraWindowSpec(label, host, html))
        return this
    }

    /**
     * 运行时打开开发者工具（等价于前端 invoke("system:devtools")）
     */
    public func openDevTools(): Unit {
        this.host.openDevTools()
    }

    /**
     * 宿主实例（插件的 setup() 取用）
     *
     * 需要窗口 / 原生能力的插件命令（原生对话框等）走它；纯仓颉插件（如 fs）用不到。
     * 宿主对象在构造 TauriApp 时就已存在，但**原生窗口要等 run()/runUrl() 才创建**——
     * 依赖窗口的操作必须在启动之后调用，实现方自己会给出可读的降级结果。
     */
    public func webviewHost(): WebViewHost {
        return this.host
    }

    /**
     * 按 label 取窗口宿主（AppHost 契约，对标 `app.get_webview_window(label)`）；未注册返回 None
     *
     * 单窗口阶段只可能命中 "main"；多窗口落地后这是插件拿到「别的窗口」的唯一入口。
     */
    public func hostOf(label: String): Option<WebViewHost> {
        match (this.windows.get(label)) {
            case Some(rec) => return Some(rec.host)
            case None =>
                // 默认窗口的注册表登记发生在 prepare()（那时窗口配置才定稿），所以 run() 之前
                // 查 "main" 会落空——但宿主对象在 TauriApp 构造时就已经存在。
                // 这里按 label 兜住，让「run() 之前 hostOf(label) 可用」对默认窗与 addWindow
                // 登记的窗一致：预置菜单 / 拖放策略都必须在 start() 之前调（RFC-菜单-托盘-拖放 §5.2），
                // 默认窗拿不到宿主就等于这条通路对最常见的用法直接不存在。
                if (label == DEFAULT_WINDOW_LABEL) {
                    return Some(this.host)
                }
                return None
        }
    }

    /**
     * 退出应用（AppHost 契约，对标 Tauri 的 `app.exit()`）：收掉所有窗口的事件循环，run() / runUrl() 随即返回
     *
     * 单窗口下与宿主自己的 `quit()` 等价；多窗口时这里是「先收各窗口的循环、再各自收尾」的唯一入口——
     * 所以命令处理器里退应用走它，不要直接调 `webviewHost().quit()`（那只是本窗口的低层原语）。
     */
    public func quit(): Unit {
        for (rec in this.windows.targets("")) {
            rec.host.quit()
        }
    }

    /**
     * 设置**默认窗口**的菜单栏（对标 Tauri 的 `Menu::set_as_app_menu` / `Window::set_menu`）
     *
     * 建议在 `run()` / `runUrl()` **之前**调用：预置类宿主能力要赶在页面加载前定稿
     * （RFC-002 §5.2）。之后调用也能用（宿主会把整棵树重建到 UI 线程上），只是页面上会看到
     * 菜单「晚一步」出现。
     *
     * 应用层会把模型留一份（见 `setMenuTo`），这样「只改某一维状态」的 API 才有
     * 「另一维现在是什么」可查——平台侧一次调用会同时写 enabled 与 checked。
     */
    public func setMenu(menu: MenuModel): TauriApp {
        return this.setMenuTo(DEFAULT_WINDOW_LABEL, menu)
    }

    /**
     * 设置**指定窗口**的菜单栏（多窗口）
     *
     * 同一个 `MenuModel` 实例给多个窗口时，两窗留存的「模型状态」是**同一个对象**——运行期改
     * 一个窗口的勾选会顺带改到另一个窗口的模型（平台上两份菜单仍是独立的）。要各自独立，
     * 就每个窗口各建一份模型。
     */
    public func setMenuTo(label: String, menu: MenuModel): TauriApp {
        match (this.hostOf(label)) {
            case Some(host) =>
                this.menus.add(label, menu)
                host.setMenu(menu.toWire())
            case None =>
                eprintln("[cj-tauri] setMenu: 未注册的窗口 label \"${label}\"（菜单未设置）")
        }
        return this
    }

    /**
     * 运行期改默认窗口某个菜单项的状态（enabled 与 checked 一起写）
     *
     * 只想改其中一维就用 `setMenuItemEnabled` / `setMenuItemChecked`——它们会拿模型里的
     * 另一维补齐，免得把用户刚点出来的勾选抹掉。
     */
    public func setMenuItemState(id: String, enabled: Bool, checked: Bool): TauriApp {
        return this.setMenuItemStateTo(DEFAULT_WINDOW_LABEL, id, enabled, checked)
    }

    /** 指定窗口版本（多窗口）：语义同 `setMenuItemState`，作用于 `label` 那个窗口 */
    public func setMenuItemStateTo(label: String, id: String, enabled: Bool, checked: Bool): TauriApp {
        this.applyMenuState(label, id, enabled, checked)
        return this
    }

    /**
     * 只改默认窗口某个菜单项的**启用**状态；勾选态取自应用层留存的模型
     *
     * 模型里没有这个 id 时抛 `CommandException`（**不**静默拿 false 顶上）：静默写会抹掉
     * 用户看到的勾选，报错至少说得清「哪个 id 在哪个窗口找不到」。
     */
    public func setMenuItemEnabled(id: String, enabled: Bool): TauriApp {
        return this.setMenuItemEnabledTo(DEFAULT_WINDOW_LABEL, id, enabled)
    }

    /** 指定窗口版本（多窗口）：语义同 `setMenuItemEnabled` */
    public func setMenuItemEnabledTo(label: String, id: String, enabled: Bool): TauriApp {
        let cur = this.requireMenuItem(label, id)
        this.applyMenuState(label, id, enabled, cur.checked)
        return this
    }

    /** 只改默认窗口某个菜单项的**勾选**状态；启用态取自应用层留存的模型 */
    public func setMenuItemChecked(id: String, checked: Bool): TauriApp {
        return this.setMenuItemCheckedTo(DEFAULT_WINDOW_LABEL, id, checked)
    }

    /** 指定窗口版本（多窗口）：语义同 `setMenuItemChecked` */
    public func setMenuItemCheckedTo(label: String, id: String, checked: Bool): TauriApp {
        let cur = this.requireMenuItem(label, id)
        this.applyMenuState(label, id, cur.enabled, checked)
        return this
    }

    /**
     * 取「另一维状态」的当前值（从应用层留存的模型里查）
     *
     * 模型不存在通常意味着应用用 `WebViewHost.setMenu()` 直设了菜单、绕过了应用层——
     * 报错里点名这条出路，比让人对着「状态怎么被抹了」猜要好。
     */
    private func requireMenuItem(label: String, id: String): MenuItem {
        match (this.menus.get(label)) {
            case None =>
                throw CommandException(
                    "菜单模型不存在：窗口 \"${label}\" 的菜单是用 app.setMenu() 设的吗？" +
                    "（用 WebViewHost.setMenu 直设的菜单应用层没有模型，改单项状态请用 setMenuItemStateTo）"
                )
            case Some(model) =>
                match (model.findById(id)) {
                    case Some(item) => return item
                    case None => throw CommandException("菜单项不存在：\"${id}\"（窗口 \"${label}\"）")
                }
        }
    }

    /**
     * 写菜单项状态：平台侧 + 应用层模型同步（模型里的 item 是可变对象，见 src/menu.cj）
     *
     * 模型不跟上会出错：勾选项在平台上一被点就自己翻了 checked，模型若还记旧值，
     * 下一次「只改启用」就会拿旧值去写，把刚点出来的勾选抹回去。
     * 模型缺失只提示、不拦——平台侧照写（与 `WebViewHost.setMenuItemState` 的「找不到静默忽略」一致）。
     */
    private func applyMenuState(label: String, id: String, enabled: Bool, checked: Bool): Unit {
        match (this.menus.get(label)) {
            case Some(model) =>
                match (model.findById(id)) {
                    case Some(item) =>
                        item.enabled = enabled
                        item.checked = checked
                    case None => eprintln("[cj-tauri] setMenuItemState: 模型里没有 \"${id}\"（只改平台侧）")
                }
            case None => eprintln("[cj-tauri] setMenuItemState: 窗口 \"${label}\" 无应用层菜单模型（只改平台侧）")
        }
        match (this.hostOf(label)) {
            case Some(host) => host.setMenuItemState(id, enabled, checked)
            case None => eprintln("[cj-tauri] setMenuItemState: 未注册的窗口 label \"${label}\"（未生效）")
        }
    }

    /**
     * 把 shell 事件里的**平台真值**回写到应用层模型（kind=menu、id 命中时）
     *
     * 为什么必须做：勾选项在平台上一被点就自己翻了 checked，模型还记着旧值——之后一次
     * 「只改启用」拿着旧值去写，就把用户刚点出来的勾选抹回去了。
     * 模型 / 项不存在时静默：事件也可能来自没用应用层菜单的窗口（宿主层直设菜单的老路径）。
     */
    private func syncMenuStateFromShell(label: String, id: String, enabled: Bool, checked: Bool): Unit {
        match (this.menus.get(label)) {
            case Some(model) =>
                match (model.findById(id)) {
                    case Some(item) =>
                        item.enabled = enabled
                        item.checked = checked
                    case None => ()
                }
            case None => ()
        }
    }

    /**
     * 注册命令处理器
     */
    public func register(cmd: String, handler: CommandHandler): TauriApp {
        this.hub.register(cmd, handler)
        return this
    }

    /**
     * 装配插件（对标 Tauri v2 的 .plugin(...)）
     *
     * 插件的命令会自动加上 "<插件名>:" 前缀后注册；事件登记、前端 JS 与未授权提示
     * 都在 run()/runUrl() 的 prepare() 阶段统一收尾（那时能力清单才加载完）。
     * 必须在 run()/runUrl() 之前调用——页面加载前命令表要定稿。
     */
    public func plugin(p: Plugin): TauriApp {
        if (!isValidPluginName(p.name())) {
            throw Exception("invalid plugin name: \"${p.name()}\"（要求非空、且不含 ':'）")
        }
        this.plugins.add(p)
        return this
    }

    /**
     * 从 JSON 添加 capability 清单
     */
    public func addCapabilityJson(json: JsonValue): TauriApp {
        this.capabilities.addFromJson(json)
        return this
    }

    /**
     * 从目录加载所有 *.json capability 清单（对标 Tauri 的 capabilities/ 目录）
     * 与 run() 的自动扫描等价，只是作用在指定目录上。
     */
    public func loadCapabilities(dir: String): TauriApp {
        let n = loadCapabilitiesFromDir(dir, this.capabilities)
        eprintln("[cj-tauri] 已从 ${dir} 加载 ${n} 个 capability 清单")
        return this
    }

    /**
     * 直接添加 capability
     */
    public func addCapability(cap: Capability): TauriApp {
        this.capabilities.add(cap)
        return this
    }

    /**
     * 向所有窗口推送事件（对标 Tauri 的 `emit`；经 capability 校验，未声明的事件不投递）
     */
    public func emit(event: String, payload: JsonValue): Unit {
        this.hub.emitAll(event, payload)
    }

    /**
     * 向所有窗口推送「只保最新」的事件：同一帧内同名事件只投最后一次 payload，中间值丢弃
     *
     * 给进度 / 动画 / 滚动位置这类高频且「中间值没有意义」的事件用；需要每条都到达的场合继续 `emit`。
     * 能力校验与 `emit` 共用一份 `events` 白名单（不额外放行）。与 Tauri v2 的差异：它核心不做合并，
     * 高频事件要么应用层自己限流、要么改用 `Channel`——我们的选择是给一条显式的 API，
     * 理由与源码级对照见 docs/IPC-通信机制.md §6 第 5 项。
     */
    public func emitLatest(event: String, payload: JsonValue): Unit {
        this.hub.emitLatest(event, payload, "")
    }

    /**
     * 向指定窗口推送事件（对标 Tauri 的 `app.emit_to(label, event, payload)`）
     *
     * 多窗口的定向投递入口。label 未注册时**什么都不投**并打一条 stderr——不回落成广播：
     * 写错 label 的表现就该是「谁都没收到」，静默变广播比丢事件更难查（见 WindowRegistry.targets）。
     * 空串 = 广播，与 `emit` 等价。
     */
    public func emitToWindow(event: String, payload: JsonValue, window: String): Unit {
        this.hub.emitToWindow(event, payload, window)
    }

    /**
     * 注册后端事件监听器：前端 `emit(event, payload)` 会调用到这里
     * （对标 Tauri Rust 侧的 `app.listen(...)`）
     *
     * 与 `emit` 是相反方向：`emit` 是后端 → 前端，本方法收前端 → 后端。
     * 后端自己 emit 出去的事件**不**回流到监听器（否则「收到就再广播」会自激）。
     * 装配期调用（`run()` / `runUrl()` 之前，或插件的 setup() 里）；注册本身不需要能力授权——
     * 权限卡在前端那侧（emit 的事件必须在 capability 的 events 里声明）。
     */
    public func listenEvent(event: String, handler: (JsonValue) -> Unit): TauriApp {
        this.hub.listenEvent(event, handler)
        return this
    }

    /**
     * 读取 CLI 注入的前端 dev server 地址（CJ_TAURI_DEV_URL）
     *
     * 模板可以直接用：
     *   if (let Some(url) <- TauriApp.devUrl()) { app.runUrl(url) }
     *   else { app.run(html) }
     */
    public static func devUrl(): Option<String> {
        if (let Some(v) <- getVariable("CJ_TAURI_DEV_URL")) {
            if (v.size > 0) {
                return Some(v)
            }
        }
        return None
    }

    /**
     * 启动应用：装配 IPC → 启动 WebView 宿主 → 阻塞运行
     */
    public func run(html: String): Unit {
        this.prepare()
        if (this.dumpManifestIfRequested()) {
            return
        }
        this.registerPluginScripts()
        this.registerDefaultWindow()
        this.host.start(html)
        this.startExtraWindows()
        this.waitForExit()
        // 事件循环已退出：释放全部宿主编（幂等；句柄由 C 侧回收，见 docs/架构演进-多平台与多窗口.md §6.1）
        this.disposeWindows()
    }

    /**
     * 按 URL 启动应用（http(s):// 或 file://）
     *
     * 与 run(html) 平行：同一段装配，只是页面来源换成 URL。有了真实来源，
     * 相对路径资源、动态 import、前端路由才成立（file:// 页面禁止 fetch/XHR）。
     * 开发时可配合 TauriApp.devUrl() 指向前端 dev server（Vite 的 HMR 就这样接进来）。
     */
    public func runUrl(url: String): Unit {
        this.prepare()
        if (this.dumpManifestIfRequested()) {
            return
        }
        this.registerPluginScripts()
        this.registerDefaultWindow()
        this.host.startUrl(url)
        this.startExtraWindows()
        this.waitForExit()
        this.disposeWindows()
    }

    /**
     * 清单导出（RFC §8 第 7 条的遗留项：让 `cj-tauri info` 消费 describePluginsJson）
     *
     * 设了 CJ_TAURI_MANIFEST 时，装配一完成就把清单打到 stdout 并返回 true——**不创建窗口**。
     * 于是 CLI / CI 在既没有 X 显示、也没装 WebView2 Runtime 的机器上照样能拿到真实的装配结果。
     * 为什么只能这样拿：CLI 进程里没有应用自己的 TauriApp，插件是应用 main() 里装配的，
     * 所以「不启动窗口，但把 main() 跑到装配完成」是唯一能取到真值的路子（详见 manifestDumpMode）。
     */
    private func dumpManifestIfRequested(): Bool {
        match (manifestDumpMode()) {
            case Some(mode) =>
                // flush 显式给：CLI 用管道抓 stdout，不能指望进程退出时的缓冲冲刷
                print(renderPluginManifest(this.plugins, mode), flush: true)
                eprintln("[cj-tauri] 已导出插件清单（mode=${mode}）：本轮未创建窗口")
                return true
            case None => return false
        }
    }

    /**
     * 把插件 jsShim 注册到宿主的「预执行脚本」通道
     *
     * 必须在 start / startUrl 之前调用：宿主创建 WebView 时一次性交给 C 桥，
     * 桥以 document-start 注入（早于页面脚本，两平台语义一致）。
     * HTML 与 URL 两种来源共用这条通道——v1 那个「runUrl 模式下 shim 注入不进去」的局限就此消掉（RFC §5.4），
     * 所以这里不再需要对使用者的额外提醒。
     */
    private func registerPluginScripts(): Unit {
        for (js in this.pluginScripts) {
            this.host.addInitScript(js)
        }
        if (this.pluginScripts.size > 0) {
            eprintln("[cj-tauri] 插件 JS 已注册为预执行脚本：${this.pluginScripts.size} 段")
        }
    }

    /**
     * 重新加载当前页面（整页 reload，等价于浏览器刷新）
     */
    public func reload(): Unit {
        this.host.reload()
    }

    /**
     * 启动前的装配：内置命令、capability、宿主回调与 sink
     */
    private func prepare(): Unit {
        if (this.started) {
            throw CommandException("app already started")
        }
        this.started = true

        // 注入内置系统命令
        this.hub.register("system:version", SystemCommands())
        this.hub.register("system:ping", SystemCommands())
        this.hub.register("system:echo", SystemCommands())
        this.hub.register("system:devtools", SystemCommands())
        this.hub.register("system:host", SystemCommands())

        // 未显式挂载 capability 时，自动扫描 capabilities/ 目录（对标 Tauri）
        autoLoadCapabilities(this.capabilities)

        this.hub.setCapabilities(this.capabilities)

        // 插件装配：注册命令（带 "<插件名>:" 前缀）→ 注册命名权限集 → setup → 汇总前端 JS → 未授权提示。
        // 顺序有意放在能力清单加载之后：提示要反映真实的放行情况。
        for (p in this.plugins) {
            registerPluginCommands(this.hub, p)
            registerPluginPermissionSets(this.capabilities, p)
            p.setup(this)
        }
        this.pluginScripts = pluginInitScripts(this.plugins)
        if (this.plugins.size > 0) {
            eprintln("[cj-tauri] 已装配 ${this.plugins.size} 个插件：")
            eprintln(describePlugins(this.plugins))
            let sets = describePermissionSets(this.plugins)
            if (sets.size > 0) {
                eprintln("[cj-tauri] 命名权限集（在 capabilities 的 permissions 里按集名引用）：")
                eprintln(sets)
            }
            warnUnauthorizedPlugins(this.plugins, this.capabilities)
        }
        // 集注册完才可能判定「清单引用的集有没有插件提供」，故放在插件装配之后
        warnUnknownPermissionSets(this.capabilities)

        // 装配：宿主消息 → IPC hub；hub 输出 → 宿主 JS
        this.wireHostCallbacks(this.host)
        this.hub.jsSink = { json, window =>
            this.deliverJs(json, window)
        }
        this.hub.devToolsSink = { =>
            this.host.openDevTools()
        }
        // system:host 的取值通道：按发起命令的窗口 label 取该宿主的能力位
        this.hub.hostCapabilitiesSink = { label => this.windowCapabilities(label) }

        this.host.setWindowConfig(this.config)
    }

    /**
     * 某个窗口的宿主能力位（`system:host` 的取值实现）
     *
     * 未登记的 label 给 0 **并出声**：写错 label 的表现会是「能力位全 false」，看起来像
     * 「这个平台不支持菜单」，比一条日志难查得多。
     */
    private func windowCapabilities(label: String): Int32 {
        match (this.hostOf(label)) {
            case Some(h) => return h.hostCapabilities()
            case None =>
                eprintln("[cj-tauri] system:host: 未注册的窗口 label \"${label}\"（能力位按 0 返回）")
                return 0
        }
    }

    /**
     * 把默认窗口登记进注册表（label = "main"）并给它注入 label
     *
     * 必须在 start() / startUrl() 之前：① 页面一加载就可能发 invoke / emit，回执要按 label 找到窗口；
     * ② label 走宿主的预执行脚本通道（document-start）注入，晚于 start 就没机会了。
     * 桥 JS 是**懒读** `window.__CJ_TAURI_LABEL__` 的（首次用到才取、取到即缓存），
     * 所以注入脚本与桥 JS 的先后顺序无所谓——两平台的注入时机本就不同。
     * 多窗口落地前只登记这一条；将来增补窗口走同一个 add() + 注入，路由侧不用改。
     */
    private func registerDefaultWindow(): Unit {
        let label = DEFAULT_WINDOW_LABEL
        this.windows.add(WindowRecord(label, this.host, this.config))
        // JSON 字符串字面量与 JS 字符串字面量同构（双引号、同样的转义），拼进赋值语句是安全的
        this.host.addInitScript("window.__CJ_TAURI_LABEL__ = ${JsonString(label)};")
        // shell 事件分发要在 start 之前装（菜单点击随时可能来，装晚了就漏）
        this.wireShellEvents(this.host, label)
    }

    /**
     * 把一段回执 / 事件投递给目标窗口（批次 2 的 label 路由）
     *
     * @param window 目标窗口 label；空串 = 广播（按登记顺序投给每个窗口）
     *
     * 未注册的 label 打 stderr 而非静默丢弃：`emitToWindow` 写错 label 的表现是「前端什么都没
     * 收到」，只剩这条日志能定位。空注册表（清单导出模式等）到不了这里——那时没有页面能发消息。
     */
    private func deliverJs(json: String, window: String): Unit {
        // 直派：JSON 本身就是合法 JS 对象字面量，直接嵌进 eval 交给桥的 _dispatch。
        // 不走 window.postMessage —— 那样每条响应要多一次结构化克隆 + 一次 message 事件派发，
        // 而且那个监听器是全页面（含 iframe / opener）都能投递的伪造入口。
        let js = "window.__CJ_TAURI__._dispatch(${json});"
        let targets = this.windows.targets(window)
        if (targets.size == 0 && window.size > 0) {
            eprintln("[cj-tauri] 未注册的窗口 label：\"${window}\"（回执 / 事件未投递）")
            return
        }
        for (rec in targets) {
            rec.host.runJs(js)
        }
    }

    /**
     * 阻塞等待：宿主事件循环退出（窗口关闭 / quit）后返回
     *
     * 公开是 AppHost 契约要求的（插件等不必自己写轮询）；内部按宿主自己的节奏收尾。
     */
    public func waitForExit(): Unit {
        var spins: Int64 = 0
        while (!this.allWindowsExited() && spins < 360_000) {  // 最长 ~1 小时（10ms 步进）
            sleep(Duration.millisecond * 10)
            spins += 1
        }
    }

    /**
     * 全部已登记窗口的循环是否都已退出
     *
     * 多窗口的「退出」是**每个窗口都收工**：主窗关了而副窗还开着时，应用不该返回
     * （对标 Tauri：`app.exit()` 收掉全部窗口）。注册表为空（清单导出模式等）时回落到
     * 默认宿主，与单窗口时代的行为逐字等价。
     */
    private func allWindowsExited(): Bool {
        let recs = this.windows.targets("")
        if (recs.size == 0) {
            return this.host.shouldQuit()
        }
        for (rec in recs) {
            if (!rec.host.shouldQuit()) {
                return false
            }
        }
        return true
    }

    /**
     * 释放全部宿主编（幂等，见 WebViewHost.dispose 的契约）
     */
    private func disposeWindows(): Unit {
        for (rec in this.windows.targets("")) {
            rec.host.dispose()
        }
    }

    /**
     * 把一个宿主挂上应用级回调
     *
     * 多窗口下每个宿主都挂**同一只**派发器：报文自带发起窗口的 label（架构文档 §7.3），
     * 路由不需要按句柄分表——所以这里传的是同一个闭包，不是每窗口一份。
     */
    /**
     * 应用层的 shell 事件钩子（对标 Tauri 的 `on_menu_event`）
     *
     * 回调参数是 `(信封 JSON, 发生事件的窗口 label)`。给原始 JSON 而不是解析后的对象：钩子多半
     * 是应用自己写的诊断 / 日志（探针就靠它断言），原样透传最不容易丢信息。label 是必需的——
     * 钩子是应用级的，一份回调要能分辨事件来自哪个窗口。
     *
     * 与前端事件**两条路都走**：先按注册顺序跑钩子（应用侧决策，例如改菜单项状态），再投前端
     * 事件（页面自己 `listen("menu:click", …)`）。钩子里抛异常只留一行 stderr，不挡后面的钩子
     * 与前端事件。
     */
    public func onShellEvent(handler: (String, String) -> Unit): TauriApp {
        this.shellHooks.add(handler)
        return this
    }

    /**
     * 装配本窗口的 shell 事件分发（应用层是唯一安装者）
     *
     * 必须在宿主 `start()` / `startUrl()` **之前**装：窗口一建出来菜单点击就可能来，装晚了会漏。
     * 宿主层的 `setShellHandler` 是**可变槽位**（后装覆盖先装），所以应用要处理 shell 事件请用
     * `onShellEvent()`（应用级钩子，可叠加多条），不要和框架抢宿主槽位——抢赢的那个会让框架的
     * 前端事件分发失效。
     */
    private func wireShellEvents(host: WebViewHost, label: String): Unit {
        host.setShellHandler({ json => this.dispatchShellEvent(label, json) })
    }

    /**
     * shell 事件 → 应用层钩子 + 前端事件（按窗口投递）
     *
     * 路由靠**闭包捕获的 label**：C 侧已按宿主句柄把事件分给了本窗口的回调（见 host.cj 的
     * `ShellRoute`），这里再按 label 投前端事件，多窗口下不会串。事件放不放行由 capability 清单
     * 决定——没在清单里声明 `menu:click` 就是静默丢弃（最小权限不破）。
     *
     * 本函数跑在**宿主 UI 线程**上（C 桥的 shell 回调就在那儿），所以中途不碰 GTK / WebKit 之外
     * 的东西：投递走 `emitToWindow` → `jsSink`，与其它事件同一条路。
     */
    private func dispatchShellEvent(label: String, json: String): Unit {
        for (hook in this.shellHooks) {
            try {
                hook(json, label)
            } catch (e: Exception) {
                eprintln("[cj-tauri] shell hook 抛出异常（已忽略）：${e}")
            }
        }
        match (parseShellEnvelope(json)) {
            case None => eprintln("[cj-tauri] shell event 信封解析失败（已丢弃）：${json}")
            case Some(obj) =>
                var kind = ""
                if (let Some(k) <- shellString(obj, "kind")) {
                    kind = k
                }
                match (shellEventNameFor(kind)) {
                    case None => eprintln("[cj-tauri] shell event: 未知 kind \"${kind}\"（未投递）：${json}")
                    case Some(event) =>
                        if (kind == "menu") {
                            this.syncMenuStateFromShellObj(label, obj)
                        }
                        try {
                            this.hub.emitToWindow(event, obj, label)
                        } catch (e: Exception) {
                            eprintln("[cj-tauri] shell event 投递失败（已忽略）：${e}")
                        }
                }
        }
    }

    /**
     * 菜单事件里的平台真值 → 应用层模型：id / enabled / checked 三者齐了才写
     *
     * 缺字段不拿默认值顶（见 shellBool 的注释）——这条路径写错的表现是「勾选莫名回退」，
     * 比少同步一次难查得多。
     */
    private func syncMenuStateFromShellObj(label: String, obj: JsonObject): Unit {
        if (let Some(id) <- shellString(obj, "id")) {
            if (let Some(enabled) <- shellBool(obj, "enabled")) {
                if (let Some(checked) <- shellBool(obj, "checked")) {
                    this.syncMenuStateFromShell(label, id, enabled, checked)
                }
            }
        }
    }

    private func wireHostCallbacks(host: WebViewHost): Unit {
        host.setMessageHandler({ raw =>
            this.hub.handleRawMessage(raw)
        })
    }

    /**
     * 启动 addWindow() 登记过的附加窗口
     *
     * 放在默认窗口 start() 之后：主窗先出现，附加窗口紧随其后（顺序只影响观感与探针取证节奏）。
     * 每个附加窗口在启动前挂上应用级回调——与默认窗口同一只派发器。
     */
    private func startExtraWindows(): Unit {
        for (w in this.extraWindows) {
            this.wireHostCallbacks(w.host)
            // shell 事件分发要在 start 之前装（菜单点击随时可能来，装晚了就漏）
            this.wireShellEvents(w.host, w.label)
            w.host.start(w.html)
            eprintln("[cj-tauri] 附加窗口已启动：label=\"${w.label}\"")
        }
    }
}

/**
 * 清单导出模式（环境变量 CJ_TAURI_MANIFEST）
 *
 * 取值：`json` → 机器可读 JSON（`describePluginsJson`）；其它非空值 → 人类可读表（`describePlugins`）；
 * 未设置（或空串）→ None，即正常启动窗口。
 *
 * 为什么走环境变量，而不是给 TauriApp 加个方法：清单要**装配完成之后**才有值，而装配发生在
 * run() / runUrl() 内部——加方法就得让每个应用的 main() 多写一个分支，既有应用全都要改。
 * 环境变量让既有应用一行不动就能被 CLI 取出清单（就是 `cj-tauri info` 拿插件清单的通道）。
 */
func manifestDumpMode(): Option<String> {
    if (let Some(v) <- getVariable("CJ_TAURI_MANIFEST")) {
        if (v.size == 0) {
            return None
        }
        if (v == "json") {
            return Some("json")
        }
        return Some("text")
    }
    return None
}

/**
 * 渲染清单文本：`json` 模式给机器（工具 / CI 直接解析），其余给人（启动日志里那份表的同款形态）。
 * 抽成纯函数是为了单测能直接断言，不必真去跑一次宿主。
 */
func renderPluginManifest(plugins: ArrayList<Plugin>, mode: String): String {
    if (mode == "json") {
        return describePluginsJson(plugins).toJsonString()
    }
    if (plugins.size == 0) {
        return "（未装配插件）\n"
    }
    return describePlugins(plugins)
}
