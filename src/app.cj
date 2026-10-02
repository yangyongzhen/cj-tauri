package cjTauri

import std.collection.*
import std.env.*
import stdx.encoding.json.*

/**
 * TauriApp 装配（对标 tauri::Builder / App）
 *
 * 用法：
 *   let app = TauriApp()
 *   app.register("greet", GreetCommand())
 *   app.addCapabilityJson(...)   // 或 addCapability(cap)
 *   app.run(html)                // 启动宿主并阻塞
 */
public class TauriApp {
    private var hub: IpcHub = IpcHub()
    private var capabilities: CapabilityRegistry = CapabilityRegistry()
    private var host: WebViewHost = createHost()
    private var config: WindowConfig = WindowConfig()
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
     * 向所有窗口推送事件（经 capability 校验）
     */
    public func emit(event: String, payload: JsonValue): Unit {
        this.hub.emitToWindow(event, payload, "main")
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
        this.host.start(html)
        this.waitForExit()
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
        this.host.startUrl(url)
        this.waitForExit()
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
        this.host.setMessageHandler({ raw =>
            this.hub.handleRawMessage(raw)
        })
        this.hub.jsSink = { json =>
            // 直派：JSON 本身就是合法 JS 对象字面量，直接嵌进 eval 交给桥的 _dispatch。
            // 不走 window.postMessage —— 那样每条响应要多一次结构化克隆 + 一次 message 事件派发，
            // 而且那个监听器是全页面（含 iframe / opener）都能投递的伪造入口。
            let js = "window.__CJ_TAURI__._dispatch(${json});"
            this.host.runJs(js)
        }
        this.hub.devToolsSink = { =>
            this.host.openDevTools()
        }

        this.host.setWindowConfig(this.config)
    }

    /**
     * 阻塞等待：宿主事件循环退出（窗口关闭 / quit）后返回
     */
    private func waitForExit(): Unit {
        var spins: Int64 = 0
        while (!this.host.shouldQuit() && spins < 360_000) {  // 最长 ~1 小时（10ms 步进）
            sleep(Duration.millisecond * 10)
            spins += 1
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
