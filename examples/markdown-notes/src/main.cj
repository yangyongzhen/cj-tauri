package markdown_notes

import cjTauri.*
import cjTauri.plugins.fs.*
import cjTauri.plugins.store.*
import cjTauri.plugins.dialog.*
import std.collection.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*

/**
 * Markdown 笔记/编辑器示例（零 Node、零构建）
 *
 * 页面是**独立的 ui/index.html**，不内联进仓颉三引号字符串——两个具体理由：
 *  1. AGENTS §4 的坑：三引号字符串会先被仓颉处理反斜杠转义，而 Markdown 渲染器必然要写正则与转义，
 *     内联进去等于让整段 `<script>` 静默语法错误（页面一行都不执行，stderr 毫无提示）；
 *  2. 独立文件能直接被 `node --check` 静态验语法，也能被抓图工具当普通页面打开排查。
 * 页面仍然是 `run(html)` 的内联来源（无真实来源），所以**不依赖任何相对 fetch**：能拿到的数据全走 IPC。
 *
 * 能力面（capabilities/default.json）：
 *  - `fs:default`（readText / writeText / exists / list / remove）——但**命令放行 ≠ 路径放行**：
 *    scope 允许 `$CWD/notes` 与 `$HOME`（「文件 → 打开…」要读外部文件），deny 兜掉
 *    `*.secret.md` 与 `.ssh` / `.git` 目录（通配写进清单 json，别在注释里照抄——
 *    星号斜杠会提前闭合本注释，AGENTS §4 第一条坑），越界一律拒；
 *  - `store:default`——记住「上次打开的笔记」，重启还在；
 *  - `dialog:default`——「打开…」弹原生文件选择框、「关于…」弹模态消息框；
 *  - `notes:env`——把宿主侧的启动参数（自检开关、工作区名）交给页面，页面读不到进程环境变量。
 *
 * 工作区 `notes/` 由 run.sh 播种（`mkdir -p notes` + 一份欢迎笔记）：
 * 插件面里**故意没有 mkdir**——建目录属于应用装配期的事，不该由一个页面能调的命令持有。
 *
 * 自检（无人值守取证，`CJ_MARKDOWN_SELFCHECK=1` 时由页面脚本自动跑一轮）：
 *   E2E 侧看两处日志——页面每条断言经 `report` 回投（`[frontend] SELFCHECK …`），
 *   被拒的越界读在桥 stderr 留 `[cj-tauri] scope denied (fs): …`。
 */
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

/**
 * `notes:env`：宿主侧的启动参数交给页面。
 * 页面没有进程环境，而「要不要跑自检」必须由启动它的脚本决定；走命令的另一个好处是
 * 页面不必知道 HTML 怎么来的（读盘 / 内联 / 将来打包内嵌都不影响它）。
 */
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
        return out
    }
}

/** 读前端页面：内嵌优先（单文件产物），否则按相对路径读盘（仓库内正常构建走这条） */
func readUi(path: String): String {
    try {
        return textOrFile(PACKED_UI_B64, path, "前端页面")
    } catch (e: Exception) {
        eprintln("[markdown-notes] 读不到前端页面 ${path}：${e}")
        eprintln("[markdown-notes] 请在示例根目录启动（ui/ 与 capabilities/ 都按相对路径解析）")
        return ""
    }
}

/**
 * 把 vendor 库内联进页面占位符：run(html) 的页面没有真实来源，`<script src>` 相对路径
 * 取不到文件，只能装配期读盘内联。占位符是页面里两个形如「斜杠星 VENDOR」的注释标记
 * （__VENDOR_JS__ 与 __VENDOR_CSS__）——这里不能把它们写全，块注释里出现星号斜杠会
 * 开嵌套注释（AGENTS §4 第一条坑，实测编译报 unterminated block comment）。
 * 库文件缺失不致命——渲染退化为纯文本也不该启动失败，每份读不到只留一行 stderr。
 */
func inlineVendor(html: String): String {
    // vendor 走内嵌优先（vendorOrFile，下标 = packed_resources.cj 里 VENDOR_FILES 的固定顺序）；
    // 缺失不致命——渲染退化为纯文本也不该启动失败，每份读不到只留一行 stderr
    var js = ""
    match (vendorOrFile(0)) {
        case Some(t) => js += t + "\n"
        case None => eprintln("[markdown-notes] vendor 库缺失 ui/vendor/marked.min.js（渲染退化为纯文本）")
    }
    match (vendorOrFile(1)) {
        case Some(t) => js += t + "\n"
        case None => eprintln("[markdown-notes] vendor 库缺失 ui/vendor/highlight.min.js（代码无高亮）")
    }
    var out = html.replace("/*__VENDOR_JS__*/", js)
    // 三份代码主题全部内联成独立的 <style>：唯一默认打开的是 dimmed（不带 media），
    // 其余 media="not all" 禁用；切换由前端改这些 style 的 media 属性——不重渲、不读盘
    out = inlineTheme(out, "/*__THEME_DIMMED__*/", 2, "ui/vendor/github-dark-dimmed.min.css")
    out = inlineTheme(out, "/*__THEME_DARK__*/", 3, "ui/vendor/github-dark.min.css")
    out = inlineTheme(out, "/*__THEME_ONE__*/", 4, "ui/vendor/atom-one-dark.min.css")
    return out
}

/** 读一份 hljs 主题样式替换到对应占位符（vendorIdx = VENDOR_FILES 顺序里的下标）；
    缺了就留一行 stderr（切到该主题时前端会退格提示） */
func inlineTheme(out: String, placeholder: String, vendorIdx: Int64, path: String): String {
    match (vendorOrFile(vendorIdx)) {
        case Some(t) => return out.replace(placeholder, t)
        case None =>
            eprintln("[markdown-notes] vendor 样式缺失 ${path}（该主题不可用）")
            return out
    }
}

/** 应用菜单：文件操作集中在原生菜单栏，与工具栏按钮走同一批页面动作（事件 `menu:click`） */
func buildAppMenu(): MenuModel {
    var file = ArrayList<MenuItem>()
    file.add(MenuItem.normalWithAccel("file.open", "打开…", "Ctrl+O"))
    file.add(MenuItem.normalWithAccel("file.new", "新建笔记", "Ctrl+N"))
    file.add(MenuItem.normalWithAccel("file.save", "保存", "Ctrl+S"))
    file.add(MenuItem.separator())
    file.add(MenuItem.normal("file.rename", "重命名…"))
    file.add(MenuItem.normal("file.delete", "删除…"))
    file.add(MenuItem.separator())
    file.add(MenuItem.normal("file.reload", "刷新列表"))
    var help = ArrayList<MenuItem>()
    help.add(MenuItem.normal("help.about", "关于…"))
    // 视图三态互斥（单选语义由 MenuRouter 回写勾选态）：仅编辑 / 分屏 / 仅预览
    var view = ArrayList<MenuItem>()
    // 视图三态单选（checkbox 才显示勾选态；此前用的 normal 根本没有勾）
    view.add(MenuItem.checkbox("view.mode.edit", "仅编辑", false))
    view.add(MenuItem.checkbox("view.mode.split", "编辑 + 预览", true))
    view.add(MenuItem.checkbox("view.mode.preview", "仅预览", false))
    view.add(MenuItem.separator())
    // 应用主题也是单选组：跟随系统 / 浅色 / 深色 / 护眼 / 墨黑（前端按 CSS 变量整体换肤）
    view.add(MenuItem.checkbox("apptheme.system", "界面主题：跟随系统", true))
    view.add(MenuItem.checkbox("apptheme.light", "界面主题：浅色", false))
    view.add(MenuItem.checkbox("apptheme.dark", "界面主题：深色", false))
    view.add(MenuItem.checkbox("apptheme.green", "界面主题：护眼", false))
    view.add(MenuItem.checkbox("apptheme.black", "界面主题：墨黑", false))
    view.add(MenuItem.separator())
    // 代码主题也是单选组；勾选态由应用层模型回写，前端拿 media 属性换样式
    view.add(MenuItem.checkbox("theme.dimmed", "代码主题：Dimmed", true))
    view.add(MenuItem.checkbox("theme.dark", "代码主题：GitHub Dark", false))
    view.add(MenuItem.checkbox("theme.one", "代码主题：One Dark", false))
    var items = ArrayList<MenuItem>()
    items.add(MenuItem.submenu("文件", file))
    items.add(MenuItem.submenu("视图", view))
    items.add(MenuItem.submenu("帮助", help))
    return MenuModel(items)
}

/** 报文里是否带某 id（精确匹配 "id":"…" 键值；indexOf 返回 Option，走 match 拆 None/Some，
 *  避开本机 cjc 对 Option 直接比对的坑——AGENTS §4 的 JsonKind/enum 推断教训） */
func hasId(json: String, id: String): Bool {
    match (json.indexOf("\"id\":\"" + id + "\"")) {
        case Some(_) => true
        case None => false
    }
}

/** 报文里的 id 是否以某前缀开头（按 `"id":"<前缀>` 找，不要求闭合引号）。
 *  2026-10-14 实测踩坑：之前写 hasId(json, "view.mode.")——多带了闭合引号，
 *  `"id":"view.mode.edit"` 里根本不含 `"id":"view.mode."` 这个字面量，于是组回写
 *  从未执行过，单选组的勾选态全部留在初始值（勾可以同时亮着）。 */
func hasIdPrefix(json: String, prefix: String): Bool {
    match (json.indexOf("\"id\":\"" + prefix)) {
        case Some(_) => true
        case None => false
    }
}

/** 菜单事件路由：单窗示例，事件里带 id 就记一行日志（前端经 `menu:click` 接住执行动作）。
 *  视图三态与代码主题是两组「单选」菜单项：命中其中一项，必须把整组勾选态一次写齐——
 *  只回写被点的那一项会让另外两项的勾留在原地，单选组就露馅（AGENTS §2 菜单状态走
 *  setMenuItemStateTo，由应用层模型回写） */
class MenuRouter {
    private let app: TauriApp

    init(app: TauriApp) {
        this.app = app
    }

    public func onShell(json: String, label: String): Unit {
        if (let Some(_) <- json.indexOf("\"menu\"")) {
            eprintln("[markdown-notes] menu click ${json}")
        }
        // 视图三态互斥：命中其中一项，三项勾选态一起写（前缀用 hasIdPrefix——
        // hasId 要求精确匹配带闭合引号，"view.mode." 这种带点的前缀永远不中，见函数注释）
        if (hasIdPrefix(json, "view.mode.")) {
            this.app.setMenuItemStateTo(label, "view.mode.edit", true, hasId(json, "view.mode.edit"))
            this.app.setMenuItemStateTo(label, "view.mode.split", true, hasId(json, "view.mode.split"))
            this.app.setMenuItemStateTo(label, "view.mode.preview", true, hasId(json, "view.mode.preview"))
        }
        // 界面主题同组互斥：五份勾选态一起写
        if (hasIdPrefix(json, "apptheme.")) {
            this.app.setMenuItemStateTo(label, "apptheme.system", true, hasId(json, "apptheme.system"))
            this.app.setMenuItemStateTo(label, "apptheme.light", true, hasId(json, "apptheme.light"))
            this.app.setMenuItemStateTo(label, "apptheme.dark", true, hasId(json, "apptheme.dark"))
            this.app.setMenuItemStateTo(label, "apptheme.green", true, hasId(json, "apptheme.green"))
            this.app.setMenuItemStateTo(label, "apptheme.black", true, hasId(json, "apptheme.black"))
        }
        // 代码主题同组互斥：三份勾选态一起写，保证任一时刻恰好一个勾着
        if (hasIdPrefix(json, "theme.")) {
            this.app.setMenuItemStateTo(label, "theme.dimmed", true, hasId(json, "theme.dimmed"))
            this.app.setMenuItemStateTo(label, "theme.dark", true, hasId(json, "theme.dark"))
            this.app.setMenuItemStateTo(label, "theme.one", true, hasId(json, "theme.one"))
        }
    }
}

main(): Int64 {
    var selfCheck = false
    if (let Some(v) <- getVariable("CJ_MARKDOWN_SELFCHECK")) {
        if (v == "1") {
            selfCheck = true
        }
    }

    let htmlRaw = readUi("ui/index.html")
    if (htmlRaw.size == 0) {
        return 1
    }
    let html = inlineVendor(htmlRaw)

    eprintln("[markdown-notes] main start (selfcheck=${selfCheck})")

    let app = TauriApp()
        .window(WindowConfig("cj-tauri Markdown 笔记", 1180, 760))
        .plugin(FsPlugin())
        .plugin(StorePlugin())
        .plugin(DialogPlugin())
        .register("report", ReportCommand())
        .register("notes:env", NotesEnvCommand(selfCheck))

    // 能力清单：内嵌优先（单文件产物没有随行的 capabilities/），否则交给 run() 自动扫描目录。
    // 框架契约是「显式挂载即不自动扫描」，两条路互斥、不会叠加（与 examples/music 同款）。
    if (PACKED_CAPS_B64.size > 0) {
        var n: Int64 = 0
        for (part in splitBy(PACKED_CAPS_B64, 44u8)) {
            app.addCapabilityJson(JsonValue.fromStr(decodeBase64(part)))
            n += 1
        }
        eprintln("[markdown-notes] 能力清单来自内嵌资源（${n} 份）")
    }

    // 工作区目录在**装配期**建好（单文件 exe 双击启动时没有 run.sh 帮忙播种）：
    // 建目录是应用装配的事，不该由「页面能调到的命令」持有（fs 插件面里故意没有 mkdir）。
    // 目录为空就顺手播种一份欢迎笔记——空工作区首启「预览空白、列表没东西」，没人知道从哪开始。
    // 两个动作都幂等：目录已存在不重建，笔记已存在不覆盖。
    if (!exists("notes")) {
        try {
            Directory.create("notes", recursive: true)
            eprintln("[markdown-notes] 工作区 notes/ 不存在，已创建")
        } catch (e: Exception) {
            eprintln("[markdown-notes] 创建工作区 notes/ 失败（列目录会报错）：${e}")
        }
    }
    if (!exists("notes/欢迎.md")) {
        let welcome: String = "# 欢迎使用 Markdown 笔记\n\n这是你的第一篇笔记，改改看：\n\n- **粗体**、*斜体*、`行内码`\n- 右侧实时预览，`Ctrl+S` 保存\n\n```js\nvar hello = \"world\";\n```\n"
        try {
            File.writeTo("notes/欢迎.md", welcome.toArray())
            eprintln("[markdown-notes] 已播种欢迎笔记 notes/欢迎.md")
        } catch (e: Exception) {
            eprintln("[markdown-notes] 播种欢迎笔记失败（不影响使用）：${e}")
        }
    }

    // 原生菜单 + 事件回投：必须在 run() 之前装配（AGENTS §2「预置类宿主能力」）；
    // 点击事件由框架自动投前端 `menu:click`，能力清单 events 里声明了 "menu" 才放行
    let router = MenuRouter(app)
    app.onShellEvent({ json, label => router.onShell(json, label) })
    // 默认窗口 label 固定 "main"（与 capabilities 的 windows 一致；DEFAULT_WINDOW_LABEL 非 public）
    match (app.hostOf("main")) {
        case Some(_) =>
            app.setMenuTo("main", buildAppMenu())
            eprintln("[markdown-notes] menu attached")
        case None => eprintln("[markdown-notes] 默认窗口未登记，菜单未装")
    }

    app.run(html)
    eprintln("[markdown-notes] after run")
    return 0
}
