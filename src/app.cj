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
    // 各插件 jsShim() 的汇总，prepare() 时定稿，run(html) 时并入页面
    private var pluginJs: String = ""

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
        // 插件 JS 随 HTML 一起进宿主：必须早于页面脚本，见 plugin.cj 的 injectPluginJs
        this.host.start(injectPluginJs(html, this.pluginJs))
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
        if (this.pluginJs.size > 0) {
            // HTML 不在本进程里（dev server / 远程页面），无法把 shim 并进去：
            // 只能等宿主注入，时序上可能晚于页面脚本。这是 v1 的已知局限（RFC §5.4）。
            eprintln("[cj-tauri] runUrl 模式：插件 JS 无法随 HTML 注入，__CJ_TAURI__.<插件名> 可能晚于页面脚本")
            eprintln("[cj-tauri]   前端请照模板的 waitForBridge 等桥出现后再用插件 API")
        }
        this.host.startUrl(url)
        this.waitForExit()
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
        this.pluginJs = assemblePluginJs(this.plugins)
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
            // JSON 本身就是合法 JS 对象字面量，直接嵌入（toJsonString 已转义字符串内特殊字符）
            let js = "window.postMessage(${json}, '*');"
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
