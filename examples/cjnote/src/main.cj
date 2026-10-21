// cjnote：本地优先的 AI 笔记（M1 骨架）
// 三栏布局：左笔记列表 / 中 CodeMirror 编辑器 / 右 AI 侧栏（占位，M3 接 AI 通路）
//
// 页面是独立 ui/index.html（不内联三引号字符串）：Markdown 渲染必然有正则与反斜杠，
// 内联会踩 AGENTS §4 的三引号转义坑；独立文件还能 node --check 验语法。
// run(html) 的页面没有真实来源，vendor 库在装配期读盘内联进占位符（markdown-notes 同款）。

package cjnote

import cjTauri.*
import cjTauri.plugins.store.*
import cjTauri.plugins.http.*
import cjTauri.plugins.log.*
import cjTauri.plugins.clipboard.*
import cjTauri.plugins.dialog.*
import cjTauri.plugins.ws.*
import std.env.*
import std.fs.*
import std.collection.*
import stdx.encoding.json.*
import stdx.crypto.common.*
import stdx.crypto.kit.*

/** 前端自检/日志回投：页面每条断言打一行 stderr，取证 grep 这一个前缀 */
public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        if (let Some(line) <- args.get("line")) {
            match (line.kind()) {
                case JsonKind.JsString => eprintln("[frontend] " + line.asString().getValue())
                case _ => ()
            }
        }
        return JsonBool(true)
    }
}

/** theme:apply：页面里自绘的主题菜单选完之后，把原生「视图→界面主题」三项勾选一次写齐。
 *  页面按钮与原生菜单是两条入口，只改页面会露馅成「页面已是深色、菜单还勾着跟随系统」。 */
public class ThemeSyncCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        var name = "system"
        if (let Some(v) <- args.get("name")) {
            match (v.kind()) {
                case JsonKind.JsString => name = v.asString().getValue()
                case _ => ()
            }
        }
        let label = ipc.window
        let _ = this.app.setMenuItemStateTo(label, "apptheme.system", true, name == "system")
        let _ = this.app.setMenuItemStateTo(label, "apptheme.light", true, name == "light")
        let _ = this.app.setMenuItemStateTo(label, "apptheme.dark", true, name == "dark")
        return JsonBool(true)
    }
}

/** linenos:sync：「显示行号」勾选态从页面回写原生菜单。页面启动时从偏好恢复行号后
 *  必须调一次，否则菜单勾与实际显示对不上（两条入口只改一条就露馅，同 theme:apply）。 */
public class LinenosSyncCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        var on = false
        if (let Some(v) <- args.get("on")) {
            match (v.kind()) {
                case JsonKind.JsBool => on = v.asBool().getValue()
                case _ => ()
            }
        }
        let label = ipc.window
        let _ = this.app.setMenuItemStateTo(label, "view.linenos", true, on)
        return JsonBool(true)
    }
}

/** titlebar:sync：把「文档名 · 保存状态 · 字数」推到原生标题行（与菜单栏同一行右侧）。
 *  返回 `supported` 让页面知道这次是真的写进去了、还是本平台没有这块（Windows = false）——
 *  页面据它决定要不要保留自己那条顶栏：没这块的平台把顶栏删了就彻底没标题了。 */
public class TitlebarSyncCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        var text = ""
        if (let Some(v) <- args.get("text")) {
            match (v.kind()) {
                case JsonKind.JsString => text = v.asString().getValue()
                case _ => ()
            }
        }
        var supported = false
        if (let Some(host) <- this.app.hostOf(ipc.window)) {
            if ((host.hostCapabilities() & CJ_CAP_SUBTITLE) != 0) {
                supported = true
                host.setTitlebarSubtitle(text)
            }
        }
        let out = JsonObject()
        out.put("supported", JsonBool(supported))
        return out
    }
}

/** notes:env：宿主侧启动参数交给页面（页面没有进程环境） */
public class NotesEnvCommand <: CommandHandler {
    private let selfCheck: Bool

    public init(selfCheck: Bool) {
        this.selfCheck = selfCheck
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let _ = ipc
        let out = JsonObject()
        out.put("selfcheck", JsonBool(this.selfCheck))
        out.put("workspace", JsonString("notes"))
        // 框架版本随环境一起给页面：「关于」浮层要显示它（页面没有别的地方能拿到）
        out.put("version", JsonString(CJ_TAURI_VERSION))
        return out
    }
}

/** note:readExternal：把用户从原生对话框选中的外部 .md 读成页面可编辑的文本。
 *  路径虽然来自对话框，但对页面仍是**可控字符串**——后缀白名单 + 4MB 上限先行挡一道，
 *  别让这条命令退化成任意文件读取（页面一旦被注入，就能顺着它读 ~/.ssh 之类）。
 *  本工程没接 fs 插件：一条只读文本的命令不值得为它引整份 scope 机制（判定收在这里一处）。 */
public class ReadExternalCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        match (args.get("path")) {
            case Some(v) =>
                match (v.kind()) {
                    case JsonKind.JsString => return this.readExternal(v.asString().getValue())
                    case _ => throw CommandException("note:readExternal: 参数 path 必须是字符串")
                }
            case None => throw CommandException("note:readExternal: 缺参数 \"path\"")
        }
    }

    func readExternal(path: String): JsonValue {
        let lower = path.toAsciiLower()
        var suffixOk = false
        for (s in [".md", ".markdown", ".txt"]) {
            if (lower.endsWith(s)) {
                suffixOk = true
            }
        }
        if (!suffixOk) {
            throw CommandException("note:readExternal: 只接受 .md / .markdown / .txt 文件")
        }
        if (!exists(path)) {
            throw CommandException("note:readExternal: 文件不存在")
        }
        let bytes = File.readFrom(path)
        if (bytes.size > 4 * 1024 * 1024) {
            throw CommandException("note:readExternal: 文件超过 4MB，拒绝读入")
        }
        let text: String = try {
            String.fromUtf8(bytes)
        } catch (e: Exception) {
            throw CommandException("note:readExternal: 不是 UTF-8 文本（${e}）")
        }
        let out = JsonObject()
        out.put("path", JsonString(path))
        out.put("name", JsonString(baseNameOf(path)))
        out.put("body", JsonString(text))
        eprintln("[cjnote] readExternal ${path} (${bytes.size} bytes)")
        return out
    }
}

/** 取路径最后一段（两平台分隔符都认）：外部草稿的默认笔记名就是它 */
func baseNameOf(path: String): String {
    var s = path
    let bySlash = s.split("/")
    if (bySlash.size > 0) {
        s = bySlash[bySlash.size - 1]
    }
    let byBackslash = s.split("\\")
    if (byBackslash.size > 0) {
        s = byBackslash[byBackslash.size - 1]
    }
    return s
}

/** 读一份文本文件，读不到返回空串（调用方打 stderr，不致命） */
func readTextOr(path: String, hint: String): String {
    try {
        return String.fromUtf8(File.readFrom(path))
    } catch (e: Exception) {
        eprintln("[cjnote] 缺 ${path}（${hint}）：${e}")
        return ""
    }
}

/** 把 vendor 库内联进页面占位符：run(html) 无真实来源，`<script src>` 相对路径取不到。
 *  库缺失不致命——渲染退化为纯文本也不该启动失败，每份只留一行 stderr。 */
func inlineVendor(html: String): String {
    var js = readTextOr("ui/vendor/marked.min.js", "渲染退化为纯文本") + "\n"
    js += readTextOr("ui/vendor/highlight.min.js", "代码无高亮") + "\n"
    js += readTextOr("ui/vendor/codemirror.min.js", "编辑器退化为纯 textarea") + "\n"
    var out = html.replace("/*__VENDOR_JS__*/", js)
    let cmCss = readTextOr("ui/vendor/codemirror.min.css", "编辑器无样式")
    let hlCss = readTextOr("ui/vendor/github-dark.min.css", "高亮无配色")
    out = out.replace("/*__VENDOR_CSS__*/", cmCss + "\n" + hlCss)
    return out
}

/** 应用菜单：文件 / 视图 / 帮助（与 markdown-notes 同一套结构与 id 约定）。
 *  点击由框架自动投前端事件 `menu:click`（能力清单 events 里已声明），菜单与顶栏按钮
 *  收敛到同一批页面动作函数，两条入口行为天然一致。 */
func buildAppMenu(): MenuModel {
    var file = ArrayList<MenuItem>()
    file.add(MenuItem.normalWithAccel("file.open", "打开…", "Ctrl+O"))
    file.add(MenuItem.normalWithAccel("file.quickOpen", "快速打开…", "Ctrl+P"))
    file.add(MenuItem.separator())
    file.add(MenuItem.normalWithAccel("file.new", "新建笔记", "Ctrl+N"))
    file.add(MenuItem.normalWithAccel("file.save", "保存", "Ctrl+S"))
    // 重命名/删除作用于当前笔记（与 markdown-notes 同约定）；外部文件在页面侧被拒
    file.add(MenuItem.normal("file.rename", "重命名…"))
    file.add(MenuItem.normal("file.delete", "删除…"))
    file.add(MenuItem.normal("file.refresh", "刷新列表"))
    file.add(MenuItem.separator())
    // 退出在应用层收口（不经过页面：页面卡住时也要能退）
    file.add(MenuItem.normalWithAccel("file.quit", "退出", "Ctrl+Q"))
    // 视图三态是单选组（勾选态由 MenuRouter 整组回写，见其注释）
    var view = ArrayList<MenuItem>()
    view.add(MenuItem.checkbox("view.mode.edit", "编辑", false))
    view.add(MenuItem.checkbox("view.mode.preview", "预览", false))
    view.add(MenuItem.checkbox("view.mode.split", "分屏", true))
    view.add(MenuItem.separator())
    // 界面主题同组单选：取值与顶栏按钮的 system → light → dark 一致
    view.add(MenuItem.checkbox("apptheme.system", "界面主题：跟随系统", true))
    view.add(MenuItem.checkbox("apptheme.light", "界面主题：浅色", false))
    view.add(MenuItem.checkbox("apptheme.dark", "界面主题：深色", false))
    view.add(MenuItem.separator())
    // 独立开关（非单选组）：默认不显示行号，勾选状态由页面持久化后经 menu:sync 回写
    view.add(MenuItem.checkbox("view.linenos", "显示行号", false))
    var help = ArrayList<MenuItem>()
    help.add(MenuItem.normal("help.about", "关于 cjnote…"))
    var items = ArrayList<MenuItem>()
    items.add(MenuItem.submenu("文件", file))
    items.add(MenuItem.submenu("视图", view))
    items.add(MenuItem.submenu("帮助", help))
    return MenuModel(items)
}

/** 报文里是否精确带某 id（`"id":"<id>"` 带闭合引号）。indexOf 返回 Option，
 *  走 match 拆 None/Some——本机 cjc 对 Option 直接比对推不出泛型（AGENTS §4） */
func hasId(json: String, id: String): Bool {
    match (json.indexOf("\"id\":\"" + id + "\"")) {
        case Some(_) => true
        case None => false
    }
}

/** id 是否以某前缀开头：按 `"id":"<前缀>` 找，**不带闭合引号**。
 *  带点前缀（如 `view.mode.`）加闭合引号永远不中，单选组回写会整组失效 */
func hasIdPrefix(json: String, prefix: String): Bool {
    match (json.indexOf("\"id\":\"" + prefix)) {
        case Some(_) => true
        case None => false
    }
}

/** 菜单事件路由：框架已把**被点那一项**的 checked/enabled 回写到应用层模型
 *  （`TauriApp.syncMenuStateFromShellObj`），这里只管单选组的另一维：命中组内任一项时
 *  把整组勾选态一次写齐，否则另几项的勾会留在原地（单选组露馅）。 */
class MenuRouter {
    private let app: TauriApp

    init(app: TauriApp) {
        this.app = app
    }

    public func onShell(json: String, label: String): Unit {
        if (let Some(_) <- json.indexOf("\"menu\"")) {
            eprintln("[cjnote] menu click ${json}")
        }
        // 退出：应用层直接收口，不回投页面
        if (hasId(json, "file.quit")) {
            eprintln("[cjnote] menu quit")
            this.app.quit()
            return
        }
        if (hasIdPrefix(json, "view.mode.")) {
            this.app.setMenuItemStateTo(label, "view.mode.edit", true, hasId(json, "view.mode.edit"))
            this.app.setMenuItemStateTo(label, "view.mode.split", true, hasId(json, "view.mode.split"))
            this.app.setMenuItemStateTo(label, "view.mode.preview", true, hasId(json, "view.mode.preview"))
        }
        if (hasIdPrefix(json, "apptheme.")) {
            this.app.setMenuItemStateTo(label, "apptheme.system", true, hasId(json, "apptheme.system"))
            this.app.setMenuItemStateTo(label, "apptheme.light", true, hasId(json, "apptheme.light"))
            this.app.setMenuItemStateTo(label, "apptheme.dark", true, hasId(json, "apptheme.dark"))
        }
    }
}

main(): Int64 {
    // ws 插件底层是 stdx.net.http 的 WebSocket 客户端，升级握手要 TLS 配置，
    // 而 tls 取的是**全局** crypto kit——不注册就报 "Global crypto kit is not set"，
    // 连明文 ws:// 也一样（TlsClientConfig 在 connect 阶段就会被构造）。启动即注册。
    setGlobalCryptoKit(DefaultCryptoKit())

    var selfCheck = false
    if (let Some(v) <- getVariable("CJNOTE_SELFCHECK")) {
        if (v == "1") {
            selfCheck = true
        }
    }

    let htmlRaw = readTextOr("ui/index.html", "请在工程根目录启动")
    if (htmlRaw.size == 0) {
        return 1
    }
    let html = inlineVendor(htmlRaw)

    eprintln("[cjnote] main start (selfcheck=${selfCheck})")

    // 笔记存取（M2 自研，替代 fs 插件）：路径全部由 NoteStore 内部拼，页面只传文件名
    let noteCmds = NoteCommands(NoteStore("notes"))

    let app = TauriApp()
        .window(WindowConfig("cjnote — AI 笔记", 1280, 800))
        .plugin(StorePlugin())
        .plugin(HttpPlugin())
        .plugin(LogPlugin())
        .plugin(ClipboardPlugin())
        .plugin(DialogPlugin())
        // cjh 后端通道：ws:frame 事件回投聊天流（cjh web 的 /ws）
        .plugin(WsPlugin())
        .register("report", ReportCommand())
        .register("notes:env", NotesEnvCommand(selfCheck))
        .register("note:list", noteCmds)
        .register("note:search", noteCmds)
        .register("note:brief", noteCmds)
        .register("note:open", noteCmds)
        .register("note:save", noteCmds)
        .register("note:create", noteCmds)
        .register("note:delete", noteCmds)
        .register("note:rename", noteCmds)
        .register("note:readExternal", ReadExternalCommand())

    // 页面自绘主题菜单 → 原生菜单勾选（两条入口必须一致，见 ThemeSyncCommand 注释）
    let _ = app.register("theme:apply", ThemeSyncCommand(app))
    let _ = app.register("linenos:sync", LinenosSyncCommand(app))
    // 页面 → 原生标题行（宿主支持时页面顶栏整行让出来，见 TitlebarSyncCommand 注释）
    let _ = app.register("titlebar:sync", TitlebarSyncCommand(app))
    // cjh 生命周期交给页面问（三态 + 端点），进程句柄在 cjh_host.cj 的全局里
    let cjhCmds = CjhCommands()
    let _ = app.register("cjh:status", cjhCmds)
    let _ = app.register("cjh:start", cjhCmds)
    let _ = app.register("cjh:config", cjhCmds)
    let _ = app.register("cjh:saveConfig", cjhCmds)
    let _ = app.register("cjh:restart", cjhCmds)

    // 工作区在装配期建好 + 播种欢迎笔记（幂等：目录/文件已存在不重建）。
    // 建目录是应用装配的事，不进 fs 插件命令面（markdown-notes 同款）。
    if (!exists("notes")) {
        try {
            Directory.create("notes", recursive: true)
            eprintln("[cjnote] 工作区 notes/ 不存在，已创建")
        } catch (e: Exception) {
            eprintln("[cjnote] 创建工作区 notes/ 失败（列表会空）：${e}")
        }
    }
    if (!exists("notes/欢迎.md")) {
        let welcome: String = "# 欢迎，来到 cjnote\n\n本地优先的 AI 笔记：笔记是磁盘上的纯 .md 文件，AI 长在编辑工作流里。\n\n这是你的第一篇笔记，改改看：\n\n- **粗体**、*斜体*、`行内码`\n- 中间编辑，右侧预览实时渲染\n- 右侧栏是 AI（M3 接通）\n\n```cangjie\nprintln(\"你好，仓颉\")\n```\n"
        try {
            File.writeTo("notes/欢迎.md", welcome.toArray())
            eprintln("[cjnote] 已播种欢迎笔记 notes/欢迎.md")
        } catch (e: Exception) {
            eprintln("[cjnote] 播种欢迎笔记失败（不影响使用）：${e}")
        }
    }

    // cjh（唯一 AI 后端）**不在装配期 spawn**：实测在 GTK/WebKit 多线程环境起来后的装配线程里
    // launch() 子进程会让主线程死锁在 futex_wait——窗口能显示但菜单、点击、IPC 全部无响应。
    // 改为页面起来后经 cjh:status 发现未运行 → cjh:start（命令 worker 线程）拉起；
    // cjh:start 会复用已在跑的实例，不顶掉用户自己的 cjh。
    // 注：真实屏「迟早整页冻结」另经 gdb 定案为 WebKit JSC 抢占 SIGUSR1（与 fork 无关），
    // 已在 cj-tauri 框架层修复（issue #4：桥里保存/恢复信号处理器）。

    // 原生菜单 + 事件回投：必须在 run() 之前装配（预置类宿主能力，AGENTS §2）；
    // 点击由框架自动投前端 `menu:click`（能力清单 events 已声明），退出这类动作在应用层直接收口
    let router = MenuRouter(app)
    app.onShellEvent({ json, label => router.onShell(json, label) })
    // 默认窗口 label 固定 "main"（与 capabilities 的 windows 一致）
    match (app.hostOf("main")) {
        case Some(_) =>
            app.setMenuTo("main", buildAppMenu())
            eprintln("[cjnote] menu attached")
        case None => eprintln("[cjnote] 默认窗口未登记，菜单未装")
    }

    app.run(html)
    // 只收自己拉起的 cjh（用户自己的实例不动，见 shutdownCjh）
    shutdownCjh()
    eprintln("[cjnote] after run")
    return 0
}
