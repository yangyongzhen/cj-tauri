package markdown_notes

import cjTauri.*
import cjTauri.plugins.*
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
 *    scope 只允许 `$CWD/notes` 与其下（`deny` 兜掉 `*.secret.md`），越界一律拒；
 *  - `store:default`——记住「上次打开的笔记」，重启还在；
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

/** 读前端页面；读不到要说清「在哪启动」，否则报错只有一个找不到的路径 */
func readUi(path: String): String {
    try {
        return String.fromUtf8(File.readFrom(path))
    } catch (e: Exception) {
        eprintln("[markdown-notes] 读不到前端页面 ${path}：${e}")
        eprintln("[markdown-notes] 请在示例根目录启动（ui/ 与 capabilities/ 都按相对路径解析）")
        return ""
    }
}

/** 应用菜单：文件操作集中在原生菜单栏，与工具栏按钮走同一批页面动作（事件 `menu:click`） */
func buildAppMenu(): MenuModel {
    var file = ArrayList<MenuItem>()
    file.add(MenuItem.normalWithAccel("file.new", "新建笔记", "Ctrl+N"))
    file.add(MenuItem.normalWithAccel("file.save", "保存", "Ctrl+S"))
    file.add(MenuItem.separator())
    file.add(MenuItem.normal("file.rename", "重命名…"))
    file.add(MenuItem.normal("file.delete", "删除…"))
    file.add(MenuItem.separator())
    file.add(MenuItem.normal("file.reload", "刷新列表"))
    var help = ArrayList<MenuItem>()
    help.add(MenuItem.normal("help.about", "关于…"))
    var view = ArrayList<MenuItem>()
    view.add(MenuItem.checkbox("view.preview", "预览窗格", true))
    var items = ArrayList<MenuItem>()
    items.add(MenuItem.submenu("文件", file))
    items.add(MenuItem.submenu("视图", view))
    items.add(MenuItem.submenu("帮助", help))
    return MenuModel(items)
}

/** 菜单事件路由：单窗示例，事件里带 id 就记一行日志（前端经 `menu:click` 接住执行动作） */
class MenuRouter {
    public func onShell(json: String, label: String): Unit {
        let _ = label
        if (let Some(_) <- json.indexOf("\"menu\"")) {
            eprintln("[markdown-notes] menu click ${json}")
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

    let html = readUi("ui/index.html")
    if (html.size == 0) {
        return 1
    }

    eprintln("[markdown-notes] main start (selfcheck=${selfCheck})")

    let app = TauriApp()
        .window(WindowConfig("cj-tauri Markdown 笔记", 1180, 760))
        .plugin(FsPlugin())
        .plugin(StorePlugin())
        .register("report", ReportCommand())
        .register("notes:env", NotesEnvCommand(selfCheck))

    // 原生菜单 + 事件回投：必须在 run() 之前装配（AGENTS §2「预置类宿主能力」）；
    // 点击事件由框架自动投前端 `menu:click`，能力清单 events 里声明了 "menu" 才放行
    let router = MenuRouter()
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
