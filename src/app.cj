package cjTauri

import std.collection.*
import std.env.*
import stdx.encoding.json.*
import cjTauri.platform.*

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
 *
 * **本文件只放「应用是什么」的声明与装配 API**（字段、构造、注册命令 / 插件 / 能力、窗口与宿主查询）。
 * 其余同职责的分片（都是 `extend TauriApp`，包边界与对外 API 完全不变）：
 * - `src/app_run.cj`    —— 启动 / 退出 / 清单导出（run 三入口、prepare、事件循环等待）
 * - `src/app_events.cj` —— 事件收发与 shell 事件分发（emit 三兄弟、listenEvent、deliverJs）
 * - `src/app_host_ops.cj` —— 宿主能力预置（菜单 / 托盘 / 快捷键 / 拖放 / 可见性 / 日志）
 *
 * 拆分的代价（有意接受）：仓颉的 `extend` 碰不到 `private` 成员，所以**被跨文件使用的字段与
 * 少数内部方法在这里是包内可见**（不写修饰符）而不是 `private`。对包外完全不可见——
 * 子包（`cjTauri.plugins.*` / `cjTauri.tests`）只认 `public`，应用侧看到的 API 一行未变。
 */
public class TauriApp <: AppHost {
    // 以下字段不写 private：同包分片（app_run / app_events / app_host_ops）经 extend 访问它们，
    // 而 extend 看不到 private 成员。包可见已是最小代价，见类注释。
    var hub: IpcHub = IpcHub()
    var capabilities: CapabilityRegistry = CapabilityRegistry()
    // 批次 1（RFC-002 §5.4）：注册表优先、内置实现兜底
    var host: WebViewHost = resolveHost(DEFAULT_WINDOW_LABEL)
    // Asset 页面的解析器（批次 1 可注入；缺省按 cwd 相对路径读盘，清单派生在批次 2）
    var assetResolver: Option<AssetResolver> = None
    var config: WindowConfig = WindowConfig()
    // 窗口注册表（批次 2）：单窗口阶段只有一条 "main"，多窗口时是「label → 宿主」的唯一权威来源
    var windows: WindowRegistry = WindowRegistry()
    // 附加窗口（批次 3 多窗口 UI 的最小切片，试验性）：addWindow() 登记、run() / runUrl() 统一启动
    var extraWindows: ArrayList<ExtraWindowSpec> = ArrayList<ExtraWindowSpec>()
    // 应用层留存的菜单模型（label → 模型）：setMenu() 记一份，供「只改某一维状态」反查另一维
    var menus: HashMap<String, MenuModel> = HashMap<String, MenuModel>()
    // 应用层的 shell 事件钩子（对标 Tauri 的 on_menu_event）：框架分发时先跑钩子、再投前端事件
    var shellHooks: ArrayList<(String, String) -> Unit> = ArrayList<(String, String) -> Unit>()
    var started: Bool = false
    var plugins: ArrayList<Plugin> = ArrayList<Plugin>()
    // 各插件 jsShim() 收集成的「预执行脚本」列表，prepare() 时定稿，run / runUrl 时交给宿主
    var pluginScripts: ArrayList<String> = ArrayList<String>()

    public init() {}

    /**
     * 设置窗口配置（标题 / 尺寸），对标 tauri.conf.json 的 app.windows
     */
    public func window(config: WindowConfig): TauriApp {
        this.config = config
        return this
    }

    /**
     * 注入资产解析器（批次 1，RFC-002 §6）
     *
     * 供 run(Asset("ui/index.html")) 取页面与资产；不注入时按 cwd 相对路径读盘，
     * 与现有模板 textOrFile 的桌面行为等价。鸿蒙 rawfile / 内嵌常量的实现由
     * 各端适配层提供，批次 2 随清单派生接入。
     */
    public func assets(resolver: AssetResolver): TauriApp {
        this.assetResolver = Some(resolver)
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
        let host = resolveHost(label)
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
     * 重新加载当前页面（整页 reload，等价于浏览器刷新）
     */
    public func reload(): Unit {
        this.host.reload()
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
     * 阻塞等待：宿主事件循环退出（窗口关闭 / quit）后返回
     *
     * 公开是 AppHost 契约要求的（插件等不必自己写轮询）；内部按宿主自己的节奏收尾。
     *
     * 为什么它在这里而不在 `app_run.cj`：接口成员只能由类体实现，`extend` 里补写不算实现
     * （编译报 `unimplemented interface function 'waitForExit'`）。判定与退出判定
     * `allWindowsExited()` 因此分居两个文件——那一个已经放宽成包内可见。
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
     *
     * 为什么它和 `waitForExit` 一起留在类体：类体的方法**看不到** `extend` 里新增的成员
     * （编译报 `'allWindowsExited' is not a member of class 'TauriApp'`），所以「类体 → extend」
     * 这条方向不能有调用。判定与被判定只能同侧。
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
     * 运行期给某插件的 scope 追加一条白名单模式（**不落盘**，重启即失效）：插件名如 `"http"`，
     * 模式写法同 `src/scope.cj`（主机名 / 路径，支持 `*` `**` `?` 与变量）。
     *
     * 调用时机是硬约束：**只应在应用已取得用户明确确认之后调**——框架替你做不了确认，它不理解
     * 你的 UI 语义。典型落法是先在原生确认框里问到「是」
     * （`host.showMessageDialog("confirm", …, "允许 <主机> 出网？")` 返回 true）再调本方法；
     * 页面自己点不了原生对话框，所以「确认」这一步天然挡得住被注入的页面自行加白。
     * 另外，清单 `scopes.<插件>.deny` 命中即拒，这里加白掀不掉 deny（判定顺序仍是先 deny 后 allow）。
     *
     * 需要重启仍生效就在启动时把存过的模式重新叠一遍（持久化与存放位置由应用自己决定）。
     *
     * 返回 false = 这条模式**没被采纳**（空串、或含 `*` / `?` 与制表/换行这类脏字符）：加白的语义是
     * 「往白名单里加一条具体值」，带通配透传进来等于全放行，所以注册中心当场拒。调用方应把 false
     * 当成「没放行」如实回给用户，别写成成功。
     */
    public func allowScopePattern(plugin: String, pattern: String): Bool {
        return this.capabilities.addRuntimeScopeAllow(plugin, pattern)
    }

    /**
     * 某插件的 scope 此刻是否放行某个值（口径与判定完全一致：清单 + 运行期叠加，先 deny 后 allow）。
     * 没写 scope 的插件恒为 true（旧行为：全量放行）。
     */
    public func isScopeAllowed(plugin: String, value: String): Bool {
        return this.capabilities.scopeAllowsValue(plugin, value)
    }

    /**
     * 直接添加 capability
     */
    public func addCapability(cap: Capability): TauriApp {
        this.capabilities.add(cap)
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
}
