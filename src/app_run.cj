package cjTauri

import std.collection.*
import std.env.*
import stdx.encoding.json.*
import cjTauri.platform.*

/**
 * TauriApp 的启动、退出与清单导出（`src/app.cj` 的同包分片）
 *
 * 为什么拆出来：这里是「一次 run 的完整节奏」——prepare 装配 → 插件 shim → 默认窗口 →
 * 附加窗口 → 等事件循环退出 → 收宿主编，外加 CLI 取清单用的 `CJ_TAURI_MANIFEST` 通道。
 * 它与「业务怎么描述应用」（app.cj 的配置 API）和「事件怎么走」（app_events.cj）是两件事。
 *
 * 拆开只是同包换文件：包边界与对外 API 一行未变（`extend` 补齐成员）。
 * 同包拆分的代价（有意接受）：`extend` 碰不到 `private` 成员，被跨文件使用的字段与少数内部
 * 方法在 `app.cj` 里放宽成包内可见——对包外（应用 / 插件 / 测试子包）完全不可见。
 */
extend TauriApp {
    /**
     * 启动应用：装配 IPC → 启动 WebView 宿主 → 阻塞运行（兼容入口，等价 run(Inline(html))）
     */
    public func run(html: String): Unit {
        this.run(PageSource.Inline(html))
    }

    /**
     * 按 URL 启动应用（兼容入口，等价 run(Url(url))）
     *
     * 与 run(html) 平行：同一段装配，只是页面来源换成 URL。有了真实来源，
     * 相对路径资源、动态 import、前端路由才成立（file:// 页面禁止 fetch/XHR）。
     * 开发时可配合 TauriApp.devUrl() 指向前端 dev server（Vite 的 HMR 就这样接进来）。
     */
    public func runUrl(url: String): Unit {
        this.run(PageSource.Url(url))
    }

    /**
     * 统一页面入口（批次 1，RFC-002 §4.3）：业务与清单只写 PageSource 一种表达
     *
     * - Inline(html)：直接给 HTML（探针、错误页）
     * - Asset(name)：逻辑名，经注入的 AssetResolver 解析；未注入时按 cwd 相对路径读盘；
     *   devMode（CJ_TAURI_DEV_URL 存在）下自动改写为 DevServer（RFC §4.3）
     * - Url(url) / DevServer(url)：直载
     *
     * 装配流程与旧入口完全一致：dumpManifest → 插件 shim → 默认窗口 → 附加窗口 → 等待退出。
     */
    public func run(source: PageSource): Unit {
        let src = rewriteForDev(source, TauriApp.devUrl())
        this.runWith({ h => h.load(src) })
    }

    /** 装配与启动的共同骨架：所有页面入口在 load(source) 收敛，宿主怎么落地是 L0 的事（RFC §4.3/§6.2） */
    private func runWith(start: (WebViewHost) -> Unit): Unit {
        this.prepare()
        if (this.dumpManifestIfRequested()) {
            return
        }
        this.registerPluginScripts()
        this.registerDefaultWindow()
        // 资产解析器随装配进宿主：桌面读盘、鸿蒙 rawfile 材化，各端 load() 自决怎么用
        this.host.setAssetResolver(this.assetResolver)
        start(this.host)
        this.startExtraWindows()
        this.waitForExit()
        // 事件循环已退出：释放全部宿主编（幂等；句柄由 C 侧回收，见 docs/架构演进-多平台与多窗口.md §6.1）
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
     * 必须在 load 之前调用：宿主创建 WebView 时一次性交给 C 桥，
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
     * 启动前的装配：内置命令、capability、宿主回调与 sink
     */
    private func prepare(): Unit {
        if (this.started) {
            throw CommandException("app already started")
        }
        this.started = true

        // 环境变量兜底（RFC-003 第 5 期）：应用没显式开日志时，`CJ_TAURI_LOG` 仍能把它开起来——
        // 已经分发出去的 exe 改不了代码，报障时靠这一个变量拿凭证。放在装配的最早处，
        // 让宿主与插件的启动期日志都赶得上；不设这个变量 = 一行不动，行为与之前完全一致。
        if (currentLogFilePath().size == 0) {
            let envPath = logEnvOr("CJ_TAURI_LOG", "")
            if (envPath.size > 0) {
                let _ = this.setLogFile(envPath)
            }
        }

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
        // 路径 scope 的缺省行为提示（RFC-003 第 4 期）：没为吃 scope 的插件写规则 = 全量放行，如实告知
        warnUnscopedPlugins(this.plugins, this.capabilities)

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
        // 最小化到托盘同属「建窗时定稿」的窗口行为（窗口过程要提前知道这条策略），
        // 所以与窗口配置一起在 start() 之前交给宿主——能力位不含托盘时平台会拒绝并出声
        this.host.setMinimizeToTray(this.config.minimizeToTray)
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
     * 必须在 load() 之前：① 页面一加载就可能发 invoke / emit，回执要按 label 找到窗口；
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
     * 启动 addWindow() 登记过的附加窗口
     *
     * 放在默认窗口 start() 之后：主窗先出现，附加窗口紧随其后（顺序只影响观感与探针取证节奏）。
     * 每个附加窗口在启动前挂上应用级回调——与默认窗口同一只派发器。
     */
    private func startExtraWindows(): Unit {
        for (w in this.extraWindows) {
            this.wireHostCallbacks(w.host)
            // shell 事件分发要在 load 之前装（菜单点击随时可能来，装晚了就漏）
            this.wireShellEvents(w.host, w.label)
            w.host.load(PageSource.Inline(w.html))
            eprintln("[cj-tauri] 附加窗口已启动：label=\"${w.label}\"")
        }
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
    private func wireHostCallbacks(host: WebViewHost): Unit {
        host.setMessageHandler({ raw =>
            this.hub.handleRawMessage(raw)
        })
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
