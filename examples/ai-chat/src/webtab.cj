package aiChat

import cjTauri.*
// PageSource 在 cjTauri.platform 里（app.cj / app_run.cj 同样单独 import 这个包）
import cjTauri.platform.*
import std.collection.*
import std.sync.*
import stdx.encoding.json.*

/**
 * 网页版启动台：把 DeepSeek / Kimi / 豆包 这些「网页版免费可用」的服务做成应用内入口
 *
 * ## 为什么不 iframe 嵌进主页面
 *
 * iframe 里是**第三方上下文**：WebView2 默认拦第三方 cookie，登录态存不住；
 * 站点跳 OAuth 时多数自带 X-Frame-Options，登录那一步直接白屏；窗口间还有弹窗拦截。
 * 表现是「页面能看见、登录过不去」，比打不开更难排查。
 *
 * 所以每家**一个独立原生窗口**（各自一个 WebView2，共用本应用的用户数据目录，
 * 登录一次就记住），功能与浏览器里完全一致——这正是多窗口该干的事。
 *
 * ## 为什么窗口在这里「运行期」建，而不是走 `addWindow`
 *
 * `addWindow(label, config, html)` 只接**内联 HTML**，且必须在 `run()` 之前登记；
 * 而启动台是用户点哪家才开哪家，不能启动时就把八扇窗全建出来。这里的落法是
 * `resolveHost(label)`（public，装配层同款解析）+ `host.load(PageSource.Url(…))`：
 * C 桥在自己的宿主线程上建窗跑消息循环，所以从命令 worker 线程调用是安全的。
 * 代价是这些宿主不经过 `addWindow`，不登记进 app 的窗口表——所以本类自己维护
 * label -> 宿主 的映射，并在窗口销毁回调里摘掉（关了再点 = 重开）。
 *
 * ## 安全边界：外部页面不给桥
 *
 * 桥是 C 侧在每个窗口 document-start 无条件注入的，而能力校验是**全局**的
 * （`CapabilityRegistry.canInvoke` 不按窗口分权）。这意味着外站页面里的脚本
 * 只要能摸到 `window.__CJ_TAURI__`，就能 invoke 本应用已放行的命令（如 fs:readText）。
 * 所以开窗前把桥抹掉：`addInitScript` 排在桥之后（AGENTS §2 的注入顺序契约），
 * 页面脚本更在后面，摸到的就是 undefined。这些窗口只需要「像浏览器一样看网页」，
 * 不需要回投任何东西。
 */

/** 一个网页版站点：id 是页面能传的唯一凭据（不接受 URL，见 openSite 的白名单） */
class WebTabSite {
    let id: String
    let name: String
    let url: String
    let note: String
    let accent: String

    init(id: String, name: String, url: String, note: String, accent: String) {
        this.id = id
        this.name = name
        this.url = url
        this.note = note
        this.accent = accent
    }
}

/**
 * 站点表：新增一家只改这里（外加 UI 不用动——卡片由 `webtab:list` 驱动渲染）。
 *
 * `accent` 是卡片色块的品牌色，纯展示用；换一家站点不必同步改前端。
 * ChatGPT 那条在国内多数网络不可达，注记里写明了，别让用户以为是应用的问题。
 */
let WEB_TAB_SITES: Array<WebTabSite> = [
    WebTabSite(
        "deepseek", "DeepSeek", "https://chat.deepseek.com/",
        "深度思考 R1 / V3，额度与网页版一致", "#4d6bfe"),
    WebTabSite(
        "kimi", "Kimi", "https://www.kimi.com/",
        "长文本与联网检索，支持拖文件", "#111827"),
    WebTabSite(
        "doubao", "豆包", "https://www.doubao.com/chat/",
        "字节自研，多模态与语音都可用", "#3370ff"),
    WebTabSite(
        "tongyi", "通义千问", "https://www.tongyi.com/qianwen/",
        "阿里通义，文档与代码能力见长", "#615ced"),
    WebTabSite(
        "chatglm", "智谱清言", "https://chatglm.cn/",
        "GLM 系列，支持联网与智能体", "#3859ff"),
    WebTabSite(
        "yuanbao", "腾讯元宝", "https://yuanbao.tencent.com/chat/",
        "混元 + DeepSeek 双模型可切", "#0052d9"),
    WebTabSite(
        "yiyan", "文心一言", "https://yiyan.baidu.com/",
        "百度文心，插件生态较全", "#2932e1"),
    WebTabSite(
        "chatgpt", "ChatGPT", "https://chatgpt.com/",
        "OpenAI 官方；国内网络通常直连不通", "#10a37f")
]

/**
 * `webtab:list` / `webtab:open` 的实现
 *
 * 两条命令都只做「开一扇窗」，不参与对话数据面——网页版里的一切交互都发生在
 * 那个窗口自己的页面里，本应用不注入、不转发、不存储。
 */
public class WebTabCommands <: CommandHandler {
    /** 命令按 worker 线程并发分发（AGENTS §2），映射表要加锁 */
    private let lock: Mutex = Mutex()
    /** label -> 已开的宿主；窗口销毁时摘掉，下次点击才会重开 */
    private let opened: HashMap<String, WebViewHost> = HashMap<String, WebViewHost>()

    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        // 这两条命令与「从哪个窗口发起」无关：任何窗（含网页版自己，虽然它没桥）都能开
        let _ = ipc
        match (cmd) {
            case "webtab:list" => return this.listSites()
            case "webtab:open" => return this.openSite(args)
            case _ => throw CommandException("unknown webtab command: ${cmd}")
        }
    }

    /** 站点表（含展示用的品牌色），前端卡片据此渲染，别在页面里再抄一份 */
    private func listSites(): JsonValue {
        let arr = ArrayList<JsonValue>()
        for (s in WEB_TAB_SITES) {
            let o = JsonObject()
            let _ = o.put("id", JsonString(s.id))
            let _ = o.put("name", JsonString(s.name))
            let _ = o.put("url", JsonString(s.url))
            let _ = o.put("note", JsonString(s.note))
            let _ = o.put("accent", JsonString(s.accent))
            arr.add(o)
        }
        return JsonArray(arr)
    }

    /**
     * 按 id 开窗；已开过就把窗口唤回（不重复建，否则每点一次多一条 WebView 线程）
     *
     * 白名单是这里的要害：页面**只能**传 id，任何字符串都要先在这张表里命中。
     * 若允许传 URL，「打开任意网页」就等于送给页面一个可钓鱼 / 可探测内网的宿主能力。
     */
    private func openSite(args: JsonObject): JsonValue {
        let id = stringArg(args, "id")
        if (id.size == 0) {
            throw CommandException("webtab:open 需要参数 \"id\"（站点标识，如 deepseek）")
        }

        var picked: WebTabSite = WEB_TAB_SITES[0]
        var found = false
        for (s in WEB_TAB_SITES) {
            if (s.id == id) {
                picked = s
                found = true
            }
        }
        if (!found) {
            throw CommandException("unknown web tab: ${id}")
        }

        let label = "web-" + picked.id
        this.lock.lock()
        let existing = this.opened.get(label)
        this.lock.unlock()
        match (existing) {
            case Some(h) =>
                // 用户可能把它最小化到托盘或藏起来了（这些窗口没装托盘，走的是普通最小化）
                h.setWindowVisible(true)
                return resultJson(picked, label, "shown")
            case None => ()
        }

        let host = resolveHost(label)
        // 预置类宿主能力必须在 load 之前定稿（AGENTS §2）
        host.setWindowConfig(WindowConfig("${picked.name} — 网页版", 1180, 820))
        // 附庸窗：挂到主窗下——不重复占任务栏、跟随主窗显隐，用户就不会把它当成第二个应用。
        // 必须排在 load 之前：平台在建窗装配期读它定稿，否则会先占一格任务栏按钮再消失（闪一下）。
        host.setOwnerWindow(DEFAULT_WINDOW_LABEL)
        // 外部页面不握桥（见文件头「安全边界」）：排在桥之后注入，页面脚本摸到 undefined
        host.addInitScript("window.__CJ_TAURI__ = undefined;")
        host.setDestroyHandler({ => this.forget(label) })
        host.load(PageSource.Url(picked.url))

        this.lock.lock()
        this.opened.add(label, host)
        this.lock.unlock()
        eprintln("[cj-ai-chat] web tab opened: ${picked.id} -> ${picked.url}")
        return resultJson(picked, label, "opened")
    }

    /** 窗口被关掉：从映射里摘掉，下次点同一站点才会重新建宿主 */
    private func forget(label: String): Unit {
        this.lock.lock()
        let _ = this.opened.remove(label)
        this.lock.unlock()
        eprintln("[cj-ai-chat] web tab closed: ${label}")
    }
}

/** 取字符串参数（类型不对按空串处理，不猜） */
func stringArg(args: JsonObject, key: String): String {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
        case None => return ""
    }
}

/** 回给前端的成功报文：action = opened（新开）/ shown（唤回已有的） */
func resultJson(site: WebTabSite, label: String, action: String): JsonValue {
    let o = JsonObject()
    let _ = o.put("id", JsonString(site.id))
    let _ = o.put("label", JsonString(label))
    let _ = o.put("action", JsonString(action))
    let _ = o.put("url", JsonString(site.url))
    return o
}
