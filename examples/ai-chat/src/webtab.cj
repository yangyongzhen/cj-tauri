package aiChat

import cjTauri.*
import std.collection.*
import std.sync.*
import stdx.encoding.json.*

/**
 * 网页版启动台：把 DeepSeek / Kimi / 豆包 这些「网页版免费可用」的服务做成应用内入口
 *
 * ## 形态：同窗内嵌视图（真标签页），不是新窗口、也不是 iframe
 *
 * 早先的做法是「点一家 → 开一扇独立原生窗口」，实测两点不可接受：任务栏越点越乱，
 * 而且窗口会飘到主窗背后，用户当作第二个应用。现在是**同一扇窗里的标签页**：
 * 每个 tab 一个宿主内嵌视图（`createEmbeddedView`），切换就是换谁露出来——
 * 不重载、不丢滚动位置。另一种候选是「单视图复用 navigate」，它每次切 tab 都要重新加载
 * 1–3 秒，已否决。
 *
 * 为什么不用 iframe：iframe 里是**第三方上下文**，WebView2 默认拦第三方 cookie 登录态存不住，
 * 多数站点还有 X-Frame-Options 直接白屏。内嵌视图是宿主自己的 WebView，功能与浏览器里一致。
 *
 * ## 安全边界：外部页面不给桥
 *
 * 内嵌视图装的是第三方站点，而能力校验是**全局**的（`CapabilityRegistry.canInvoke` 不按窗口分权）。
 * 所以平台层建视图时**不注入桥、也不注入插件 shim**：外部页面里的脚本摸 `window.__CJ_TAURI__`
 * 得到 undefined，也就没有 invoke 宿主命令这条路（页面也不需要回投任何东西）。
 *
 * ## 上限与 LRU
 *
 * 每个内嵌视图背后是一个渲染进程（几十 MB 起），8 个站点全开约 300–600 MB。所以**按需创建、
 * 上限 4 个**：超了就把最久没用过的那一个 destroy 掉（`evictOne`）。关掉的 tab 若不显式 destroy
 * 只是看不见，内存还占着——这条在 `close` 里也守着。
 */

/** 一个网页版站点：id 是页面能传的唯一凭据（不接受 URL，见 show 的白名单） */
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

/** 一个已建的内嵌视图：句柄 + LRU 计次（tick 越大越近用过） */
class EmbeddedViewState {
    let view: Int64
    var tick: Int64

    init(view: Int64, tick: Int64) {
        this.view = view
        this.tick = tick
    }
}

/**
 * 网页版标签页的实现：`webtab:list` / `show` / `bounds` / `hide` / `close`
 *
 * 命令按 worker 线程并发分发（AGENTS §2），映射表用 `Mutex` 守着。宿主**按发起命令的窗口**
 * 解析（`ipc.window`）——固定用主窗那一个会让「哪个窗点的 tab 就画在哪个窗」失效（AGENTS §4）。
 */
public class WebTabCommands <: CommandHandler {
    private let lock: Mutex = Mutex()
    /** 站点 id -> 已建的内嵌视图（关掉/淘汰时移除） */
    private let views: HashMap<String, EmbeddedViewState> = HashMap<String, EmbeddedViewState>()
    /** LRU 计次器：只在锁内自增 */
    private var tick: Int64 = 0
    /** 同时存在的内嵌视图上限（每个背后一个渲染进程，见文件头「上限与 LRU」） */
    private let maxViews: Int64 = 4
    private let hostResolver: (String) -> Option<WebViewHost>

    public init(hostResolver: (String) -> Option<WebViewHost>) {
        this.hostResolver = hostResolver
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "webtab:list" => return listSites()
            case "webtab:show" => return this.show(args, ipc)
            case "webtab:bounds" => return this.bounds(args, ipc)
            case "webtab:hide" => return this.hideAll(ipc)
            case "webtab:close" => return this.close(args, ipc)
            case _ => throw CommandException("unknown webtab command: ${cmd}")
        }
    }

    /** 站点表（含展示用的品牌色），前端卡片与 tab 栏据此渲染，别在页面里再抄一份 */
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
     * 显示某个站点的标签页：没建过就建（同窗内嵌视图），建过就直接露出来
     *
     * 白名单是这里的要害：页面**只能**传 id，任何字符串都要先在这张表里命中。
     * 若允许传 URL，「打开任意网页」就等于送给页面一个可钓鱼 / 可探测内网的宿主能力。
     *
     * `rect` 必填（页面 client 坐标）：视图是宿主原生控件，不参与页面排版，
     * 应用必须按自己的布局上报矩形，否则它会盖住侧栏或露白边。
     */
    private func show(args: JsonObject, ipc: IpcContext): JsonValue {
        let site = pickSite(stringArg(args, "id"))
        let (rx, ry, rw, rh) = rectArg(args)
        if (rw <= 0 || rh <= 0) {
            throw CommandException("webtab:show 需要参数 rect {x, y, width, height}（页面 client 坐标）")
        }
        let host = this.hostOf(ipc)
        var handle: Int64 = -1
        var created = false
        this.lock.lock()
        match (this.views.get(site.id)) {
            case Some(v) =>
                handle = v.view
                this.tick = this.tick + 1
                v.tick = this.tick
                host.setEmbeddedViewBounds(handle, Int32(rx), Int32(ry), Int32(rw), Int32(rh))
            case None =>
                // 满了就先按 LRU 淘汰一个（绝不淘汰本次要显示的这个）
                if (this.views.size >= this.maxViews) {
                    this.evictOne(host, site.id)
                }
                handle = host.createEmbeddedView(site.url, Int32(rx), Int32(ry), Int32(rw), Int32(rh))
                if (handle > 0) {
                    this.tick = this.tick + 1
                    this.views.add(site.id, EmbeddedViewState(handle, this.tick))
                    created = true
                }
        }
        // 同一个宿主上只留一个可见视图：切换 tab = 换谁露出来（隐藏的那个停在原页面，不重载）
        if (created || handle > 0) {
            let current = handle
            let keys = ArrayList<String>()
            for (k in this.views.keys()) {
                keys.add(k)
            }
            for (k in keys) {
                match (this.views.get(k)) {
                    case Some(v) =>
                        if (v.view != current) {
                            host.setEmbeddedViewVisible(v.view, false)
                        }
                    case None => ()
                }
            }
        }
        this.lock.unlock()
        if (handle <= 0) {
            // 平台没落地内嵌视图（如鸿蒙）：如实降级，别假装开好了
            throw CommandException("webtab: 当前平台不支持窗口内嵌视图（createEmbeddedView 回 0）")
        }
        host.setEmbeddedViewVisible(handle, true)
        if (created) {
            eprintln("[cj-ai-chat] web view created: ${site.id} -> ${site.url} (view=${handle})")
        }
        return resultJson(site, handle, if (created) { "created" } else { "shown" })
    }

    /** 页面布局变了（resize / 侧栏折叠 / DPI 变化）：重报当前视图的矩形 */
    private func bounds(args: JsonObject, ipc: IpcContext): JsonValue {
        let site = pickSite(stringArg(args, "id"))
        let (rx, ry, rw, rh) = rectArg(args)
        if (rw <= 0 || rh <= 0) {
            throw CommandException("webtab:bounds 需要参数 rect {x, y, width, height}")
        }
        let host = this.hostOf(ipc)
        var view: Int64 = 0
        this.lock.lock()
        let st = this.views.get(site.id)
        this.lock.unlock()
        match (st) {
            case Some(v) =>
                view = v.view
                host.setEmbeddedViewBounds(v.view, Int32(rx), Int32(ry), Int32(rw), Int32(rh))
            case None => throw CommandException("web tab not open: ${site.id}")
        }
        return resultJson(site, view, "resized")
    }

    /** 收起整个「网页」页（用户切到别的侧栏 tab）：所有内嵌视图藏起来，页面重新露出来 */
    private func hideAll(ipc: IpcContext): JsonValue {
        let host = this.hostOf(ipc)
        var count: Int64 = 0
        this.lock.lock()
        let keys = ArrayList<String>()
        for (k in this.views.keys()) {
            keys.add(k)
        }
        for (k in keys) {
            match (this.views.get(k)) {
                case Some(v) =>
                    host.setEmbeddedViewVisible(v.view, false)
                    count = count + 1
                case None => ()
            }
        }
        this.lock.unlock()
        let o = JsonObject()
        let _ = o.put("hidden", JsonInt(count))
        return o
    }

    /** 关掉某个站点（应用层切 tab 时点 ×）：销毁视图，把它背后的渲染进程一起收掉 */
    private func close(args: JsonObject, ipc: IpcContext): JsonValue {
        let site = pickSite(stringArg(args, "id"))
        let host = this.hostOf(ipc)
        this.lock.lock()
        let st = this.views.remove(site.id)
        this.lock.unlock()
        match (st) {
            case Some(v) =>
                host.destroyEmbeddedView(v.view)
                eprintln("[cj-ai-chat] web view closed: ${site.id} (view=${v.view})")
            case None => ()
        }
        return resultJson(site, 0, "closed")
    }

    /** LRU 淘汰一个（调用方持锁）：挑 tick 最小、且不是 keepId 的那个 */
    private func evictOne(host: WebViewHost, keepId: String): Unit {
        let keys = ArrayList<String>()
        for (k in this.views.keys()) {
            if (k != keepId) {
                keys.add(k)
            }
        }
        var victim = ""
        var victimTick: Int64 = 0
        var first = true
        for (k in keys) {
            match (this.views.get(k)) {
                case Some(v) =>
                    if (first || v.tick < victimTick) {
                        victimTick = v.tick
                        victim = k
                        first = false
                    }
                case None => ()
            }
        }
        if (victim.size == 0) {
            return
        }
        let st = this.views.remove(victim)
        match (st) {
            case Some(v) =>
                host.destroyEmbeddedView(v.view)
                eprintln("[cj-ai-chat] web view evicted (LRU): ${victim} (view=${v.view})")
            case None => ()
        }
    }

    /** 按发起命令的窗口解析宿主：固定用主窗那一个会让多窗口串台（AGENTS §4） */
    private func hostOf(ipc: IpcContext): WebViewHost {
        match (this.hostResolver(ipc.window)) {
            case Some(h) => return h
            case None => throw CommandException("web tab: window not registered: ${ipc.window}")
        }
    }
}

/** 按 id 查站点；找不到就如实抛（页面传错 id 不该静默落地到某一家） */
func pickSite(id: String): WebTabSite {
    if (id.size == 0) {
        throw CommandException("web tab 需要参数 \"id\"（站点标识，如 deepseek）")
    }
    for (s in WEB_TAB_SITES) {
        if (s.id == id) {
            return s
        }
    }
    throw CommandException("unknown web tab: ${id}")
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

/** 取整数参数（JSON 数字不区分整/浮点，两种都认；其余按兜底值处理） */
func intArg(args: JsonObject, key: String, fallback: Int64): Int64 {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case JsonKind.JsFloat => return Int64(v.asFloat().getValue())
                case _ => return fallback
            }
        case None => return fallback
    }
}

/** 取页面上报的矩形：`{"rect": {"x":…, "y":…, "width":…, "height":…}}`，缺字段按 0 */
func rectArg(args: JsonObject): (Int64, Int64, Int64, Int64) {
    match (args.get("rect")) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsObject =>
                    let o = v.asObject()
                    let x = intArg(o, "x", 0)
                    let y = intArg(o, "y", 0)
                    let w = intArg(o, "width", 0)
                    let h = intArg(o, "height", 0)
                    return (x, y, w, h)
                case _ => return (0, 0, 0, 0)
            }
        case None => return (0, 0, 0, 0)
    }
}

/** 回给前端的报文：id / 视图句柄 / action（created 新建、shown 唤回、resized、closed） */
func resultJson(site: WebTabSite, view: Int64, action: String): JsonValue {
    let o = JsonObject()
    let _ = o.put("id", JsonString(site.id))
    let _ = o.put("view", JsonInt(view))
    let _ = o.put("action", JsonString(action))
    let _ = o.put("url", JsonString(site.url))
    return o
}
