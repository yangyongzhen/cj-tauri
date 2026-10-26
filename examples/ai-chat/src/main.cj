package aiChat

import std.env.*
// cjTauri.plugins.fs 与 std.fs 短名相同（都叫 fs）：本应用的链接命令行会**漏掉插件那个库**，
// 实测与 import 顺序无关（详见 cjpm.toml 的 link-option 注释）——靠清单显式补 -lcjTauri.plugins.fs。
import cjTauri.plugins.fs.*
import std.collection.*
import cjTauri.*
import cjTauri.plugins.http.*
import cjTauri.plugins.log.*
import cjTauri.plugins.store.*
import cjTauri.plugins.clipboard.*
import cjTauri.plugins.ws.*
import cjTauri.plugins.dialog.*
import stdx.encoding.json.*

/**
 * ai-chat：AI 对话客户端（cj-tauri 示例）
 *
 * 零新命令设计：对话全部经 **http 插件**的 `http:postStream`（SSE 流式）+ `http:get`
 * 出网，配置经 **store 插件**持久化——本应用只做「装配 + 能力清单」，没有一行
 * 自己的网络/存储代码。框架缺口（HTTP 白名单收口 + 流式）由 http 插件承担：
 * - 出网主机白名单写在本目录 `capabilities/app.json` 的 `scopes.http`（page 可控 URL
 *   的第一道闸；没写 = 全拒）；
 * - 流式回复走 `http:chunk` 事件（emitLatest），前端自己解析 SSE 帧（`data:` 行 + [DONE]）。
 *
 * 依赖方向：main.cj 只 import 插件包（子包不得反向 import 应用包）。
 */

let UI_PATH = "ui/index.html"

func envOr(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(v) => return v
        case None => return fallback
    }
}

/** 读前端页面（工作目录 = 工程根：capabilities/ 与 ui/ 按相对路径读）。
    vendor 库在装配期内联进占位符——run(html) 的页面没有真实来源，
    `<script src>` 相对路径取不到文件（markdown-notes 同款机制）。
    单文件产物里没有随行文件：页面与 vendor 都可能在二进制里（`packed_resources.cj`）。 */
func loadUi(): String {
    let raw = textOrFile(PACKED_UI_B64, UI_PATH, "前端页面")
    return inlineVendor(raw)
}

/** 把 vendor 库内联进页面占位符（顺序见 `vendorSegments()` 的契约）。
    库缺失不致命——高亮退化为无色纯文本，不该启动失败，每份读不到只留一行 stderr。 */
func inlineVendor(html: String): String {
    let segs = vendorSegments()
    var js = ""
    var css = ""
    if (segs.size > 0) {
        js = segs[0]
    }
    if (segs.size > 1) {
        css = segs[1]
    }
    if (js.size > 0) {
        js = js + "\n"
    }
    return html.replace("/*__VENDOR_JS__*/", js).replace("/*__VENDOR_CSS__*/", css)
}

/** 前端主动退应用（quit 在平台层投 GUI 线程，命令里调是安全的） */
public class QuitCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let _ = ipc
        eprintln("[cj-ai-chat] quit requested by frontend")
        this.app.quit()
        return JsonBool(true)
    }
}

main(): Int64 {
    let win = WindowConfig("ai-chat, made by cj-tauri", 1320, 860)
    win.devTools = true

    // 单文件包：先把嵌在 exe 里的随包资源（OpenSSL DLL、cjh 安装包）释放到安装目录并预加载
    // （本进程 https 直连与一键部署都要用）。开发构建 / 目录包无内嵌资源时零副作用。
    let _ = releaseEmbeddedBundle()
    let app = TauriApp()
        .window(win)
        .plugin(HttpPlugin())
        .plugin(LogPlugin())
        .plugin(StorePlugin())
        .plugin(ClipboardPlugin())   // 复制按钮的后端：clipboard:write（消息/代码块一键复制）
        .plugin(WsPlugin())          // cjh 后端通道：ws:frame 事件回投聊天流（cjh web /ws）
        // 工作区「浏览…」：原生目录选择框（dialog:pickFolder）——手输绝对路径的替代路；
        // 不装配会得到 command not registered（新增能力三处联动，漏一处就用不了，见 AGENTS §2）
        .plugin(DialogPlugin())
        // 文件预览：cjh **没有** /api/fs/read，所以内容读自家 fs 插件（fs:readText）。
        // 该插件 scopeAware——能读的范围由 capabilities 的 scopes.fs 决定，不是全放行。
        .plugin(FsPlugin())
        // 日志落盘：GUI 产物双击没控制台，报障时一个文件看全（C 桥 + 仓颉 + 页面 log:write）
        .setLogToDefaultFile("ai-chat")

    // 本应用不驻留系统托盘（2026-10-25 用户裁定：网页入口改为主窗内的标签页之后，
    // 「窗口藏进托盘再唤出」这套常驻形态就不需要了）。于是也不再有
    // minimizeToTray 与「唤出面板」快捷键——窗口就是一个普通窗口。
    // 想要托盘的话，框架能力位与 clipboard-history 示例仍是完整可用的样板。

    app.register("quit", QuitCommand(app))

    // cjh 的两条运维命令（Agent 模式引导卡用）：状态查询 + 按选中的可执行文件拉起。
    // 页面切 Agent 模式先问 cjh:status——三态决定给不给引导；用户选完文件调 cjh:start
    // （命令三处联动：这里注册 + capabilities/app.json 的 commands + 页面的 invoke）。
    let cjhCmds = CjhCommands()
    app.register("cjh:status", cjhCmds)
    app.register("cjh:start", cjhCmds)
    app.register("cjh:deploy", cjhCmds)
    app.register("app:allowHost", AllowHostCommand(app))

    // 网页版启动台（src/webtab.cj）：侧栏「网页」里的每张卡片点开 = 同窗内嵌视图（真标签页）。
    // 宿主按发起命令的窗口解析（多窗口下不串台）；能力清单的 commands 里同样要登记这五条
    // （三处联动，漏一处就是 command not allowed）
    let webTabs = WebTabCommands({ label => app.hostOf(label) })
    // webtab 五条命令共享一份原生视图状态：页面快速连点时乱序会让原生视图与 DOM 错位
    //（2026-10-26 实测，前端曾用 promise 队列自救）——改走框架串行组，按到达序执行（issue #6-④）。
    // 前端的 webInvoke 排队保留：它保证「页面发出顺序 = 宿主收到顺序」，两层各管一段。
    app.registerSerial("webtab:list", webTabs, "webtab")
    app.registerSerial("webtab:show", webTabs, "webtab")
    app.registerSerial("webtab:bounds", webTabs, "webtab")
    app.registerSerial("webtab:hide", webTabs, "webtab")
    app.registerSerial("webtab:close", webTabs, "webtab")

    // cjh web 托管：run 之前确保后端就绪（复用已运行的，或按 CJ_AICHAT_CJH spawn）。
    // 数据面不在这层——页面经 ws 插件连 ws://127.0.0.1:<port>/ws、经 http 插件打 /api/…。
    let cjhUp = ensureCjhWeb()
    if (cjhUp) {
        // 托管成功：把 ws 端点告诉页面（document-start，早于页面脚本，见 AGENTS §2）
        let js = "window.__CJH_WS__ = 'ws://127.0.0.1:" + cjhPort().toString() + "/ws';" +
            "window.__CJH_API__ = 'http://127.0.0.1:" + cjhPort().toString() + "';\n"
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[cj-ai-chat] cjh 端点已注入页面")
            case None => eprintln("[cj-ai-chat] 主窗未登记，cjh 端点没注入")
        }
    }

    // 探针模式（CJ_AICHAT_PROBE=1）：注入自检开关，页面跑完一轮经 log:write 回投 stderr
    if (envOr("CJ_AICHAT_PROBE", "") == "1") {
        // CJ_AICHAT_PROBE_BIN 给自检一条可用的 cjh 路径：原生「选择文件」框没人点不了，
        // 自检就调按钮背后那个 cjh:start 把这条链路跑完（对话框本身仍要人点，见 README）。
        let probeBin = envOr("CJ_AICHAT_PROBE_BIN", "")
        let js = "window.__CJ_TAURI_SELF_CHECK__ = true;\n" +
            (if (probeBin.size > 0) { "window.__AICHAT_PROBE_BIN__ = '" + probeBin + "';\n" } else { "" })
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[cj-ai-chat] 探针模式已注入")
            case None => eprintln("[cj-ai-chat] 探针模式：主窗未登记，配置没注入")
        }
    }

    // 网页版启动台探针（CJ_AICHAT_PROBE_WEBTAB=1）：与主自检**分开跑**——这一轮会真的
    // 弹出一扇原生窗口（DeepSeek 网页版）并留在桌面，常规自检不该带这个副作用。
    // 断言覆盖「站点表在 / 开得出来 / 重复点击不重复建 / 非法 id 被白名单挡住」四段。
    if (envOr("CJ_AICHAT_PROBE_WEBTAB", "") == "1") {
        let js = "window.__AICHAT_PROBE_WEBTAB__ = true;\n"
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[cj-ai-chat] 网页版探针已注入")
            case None => eprintln("[cj-ai-chat] 网页版探针：主窗未登记，配置没注入")
        }
    }

    // 一键部署探针（CJ_AICHAT_PROBE_DEPLOY=1）：只注入开关，页面走 cjh:deploy 全链路
    // （校验 → 解包 → 拉起 → 健康检查）。与上面的自检**两轮分开跑**：那一轮不装任何东西，
    // 这一轮要真的落一份到安装目录并起进程——同时跑会互相读到对方装到一半的状态。
    if (envOr("CJ_AICHAT_PROBE_DEPLOY", "") == "1") {
        let js = "window.__AICHAT_PROBE_DEPLOY__ = true;\n"
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[cj-ai-chat] 一键部署探针已注入")
            case None => eprintln("[cj-ai-chat] 部署探针：主窗未登记，配置没注入")
        }
    }

    // 页面用 run(html) 内联（clipboard-history 同款）：runUrl 的相对路径 WebKit 解析不了
    // （实机踩过：页面显示 The URL can't be shown），file:// 绝对路径可用但内联更省事——
    // 本页面零外部资源（无图片/无 vendor），内联无副作用。
    // 运行期加白是内存态、重启即空：把本机清单里用户确认过的主机在 run() 前叠回去
    let persistedHosts = applyPersistedAllowedHosts(app)
    if (persistedHosts > 0) {
        eprintln("[cj-ai-chat] 已叠加本机 allow 清单：${persistedHosts} 个主机")
    }

    // 单文件产物没有随行的 capabilities/：清单编在二进制里，逐个挂上去。
    // 一旦调用 addCapabilityJson 就不再自动扫描（框架约定），所以这条分支只在打包产物里生效。
    if (PACKED_CAPS_B64.size > 0) {
        var caps = 0
        for (part in splitBy(PACKED_CAPS_B64, 44u8)) {
            if (part.size == 0) {
                continue
            }
            let _ = app.addCapabilityJson(JsonValue.fromStr(decodeBase64(part)))
            caps += 1
        }
        eprintln("[cj-ai-chat] 能力清单来自内嵌资源：${caps} 份")
    }

    let html = loadUi()
    app.run(html)
    // run 返回 = 窗口已收尾：只终止**自己拉起的** cjh（复用的不动）
    shutdownCjh()
    return 0
}
