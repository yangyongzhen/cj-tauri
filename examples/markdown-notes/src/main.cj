package markdownNotes

import cjTauri.*
import cjTauri.plugins.fs.*
import cjTauri.plugins.store.*
import cjTauri.plugins.dialog.*
import std.collection.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*
@When[env == "ohos"]
import kit.PerformanceAnalysisKit.Hilog

/**
 * Markdown 笔记/编辑器示例——新形态（RFC-002 §7）
 *
 * 页面（assets/ui/index.html）、窗口尺寸、能力目录都由清单 cj-tauri.toml 决定，
 * 由 `cj-tauri sync` 派生的骨架 launcher 落实；本文件只放业务：插件、命令、菜单、
 * vendor 注入与工作区播种。桌面与鸿蒙共用这一份（RFC §7.3）。
 *
 * 能力面（assets/capabilities/default.json）：
 *  - `fs:default`——但**命令放行 ≠ 路径放行**：scope 允许 `$CWD/notes` 与 `$HOME`，
 *    deny 兜掉 `*.secret.md` 与 `.ssh` / `.git` 目录（通配写进清单 json，别在注释里照抄——
 *    星号斜杠会提前闭合本注释，AGENTS §4 第一条坑），越界一律拒；
 *  - `store:default`——记住「上次打开的笔记」，重启还在；
 *  - `dialog:default`——「打开…」弹原生文件选择框、「关于…」弹模态消息框；
 *  - `notes:env`——把宿主侧的启动参数（自检开关、工作区名）交给页面。
 *
 * vendor 库注入（marked / highlight.js / 三份 hljs 主题）：**经 addInitScript 注入**，
 * 不再走旧形态的「装配期替换页面占位符」——新形态页面由 launcher 按清单加载，
 * 业务不持有页面 HTML。两平台的 Asset 页面都以内联字符串进引擎（WebView2
 * NavigateToString / ArkWeb start(html)），页面没有真实来源，`<script src>` 相对引用
 * 两边都取不到文件；document-start 注入（排在页面脚本之前）与 typing-poem 的
 * three.js 同一先例。占位符（__VENDOR_JS__ / hljs-theme-*）留在页面里无害，
 * 主题切换按 `style[id^="hljs-theme-"]` 前缀抓元素，注入的样式元素同样被覆盖到。
 *
 * 工作区 `notes/` 由装配期播种（建目录 + 一份欢迎笔记，幂等）：建目录是应用装配的事，
 * 不该由「页面能调到的命令」持有（fs 插件面里故意没有 mkdir 命令的口子给页面）。
 *
 * 自检（无人值守取证，`CJ_MARKDOWN_SELFCHECK=1` 时由页面脚本自动跑一轮）：
 *   E2E 侧看两处日志——页面每条断言经 `report` 回投（`[frontend] SELFCHECK …`），
 *   被拒的越界读在桥 stderr 留 `[cj-tauri] scope denied (fs): …`。
 */
/**
 * 诊断输出的唯一出口：桌面走 stderr（每行即时落盘，端到端验证以它为准）；
 * 鸿蒙侧 eprintln 不进 hilog（AGENTS §4），改走 Hilog（domain 1 + tag CjMarkdown），
 * `hdc shell hilog` 里能逐条对账——页面自检、scope 拒绝、工作区播种全走这一只口子。
 */
@When[env == "ohos"]
func diagLine(line: String): Unit {
    Hilog.info(1, "CjMarkdown", line)
}

@When[env != "ohos"]
func diagLine(line: String): Unit {
    eprintln(line)
}

/** 设备自检开关：鸿蒙侧默认开（设备上没有环境变量可设；桌面由 CJ_MARKDOWN_SELFCHECK=1 显式开）。
 *  与 serial-assistant 的 deviceProbeEnabled() 同一模式。 */
@When[env == "ohos"]
func selfCheckEnabled(): Bool {
    return true
}

@When[env != "ohos"]
func selfCheckEnabled(): Bool {
    match (getVariable("CJ_MARKDOWN_SELFCHECK")) {
        case Some(v) => return v == "1"
        case None => return false
    }
}

public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        if (let Some(line) <- args.get("line")) {
            match (line.kind()) {
                case JsonKind.JsString => diagLine("[frontend] " + line.asString().getValue())
                case _ => ()
            }
        }
        return JsonBool(true)
    }
}

/**
 * `notes:env`：宿主侧的启动参数交给页面。
 * 页面没有进程环境，而「要不要跑自检」必须由启动它的脚本决定；走命令的另一个好处是
 * 页面不必知道 HTML 怎么来的（launcher 读盘 / rawfile 材化都不影响它）。
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

/**
 * 取 vendor 库文本：资产解析器优先（桌面按 assets/ 读盘、鸿蒙按 rawfile 读 hap），
 * 读不到再回落 vendorOrFile（内嵌 base64 优先，其次磁盘）——三形态各有着落点，
 * 设备上 cwd 没有磁盘目录也不再全灭（此前 vendor 全缺的根因）。
 */
func vendorText(app: TauriApp, idx: Int64): Option<String> {
    if (idx < 0 || idx >= VENDOR_FILES.size) {
        return None
    }
    match (app.readAsset(VENDOR_FILES[idx])) {
        case Some(t) => return Some(t)
        case None => return vendorOrFile(idx)
    }
}

/**
 * vendor 库经 addInitScript 注入（document-start，早于页面脚本）。
 * JS 库原文直接作为脚本体（不需要包 script 标签）；CSS 要包进 style 元素，
 * 文本经 JSON 字符串编码——JSON 的转义规则就是合法的 JS 字符串字面量转义，
 * 不手写 replace（minified 库里反斜杠与引号极密，手拼必坏，AGENTS §4 三引号坑同源）。
 */
func installVendorScripts(app: TauriApp): Unit {
    let marked = vendorText(app, 0)
    let hljs = vendorText(app, 1)
    match (app.hostOf("main")) {
        case Some(host) =>
            match (marked) {
                case Some(t) => host.addInitScript(t + "\n")
                case None => diagLine("[markdown-notes] vendor 库缺失 marked.min.js（渲染退化为纯文本）")
            }
            match (hljs) {
                case Some(t) => host.addInitScript(t + "\n")
                case None => diagLine("[markdown-notes] vendor 库缺失 highlight.min.js（代码无高亮）")
            }
            // 三份代码主题：全部注入成独立 style 元素（页面里那三个同名占位 style 是空的）；
            // 唯一默认打开的是 dimmed，其余先 media="not all" 禁用，切换由前端改 media——不重渲
            installTheme(app, host, "hljs-theme-dimmed", 2, "all")
            installTheme(app, host, "hljs-theme-dark", 3, "not all")
            installTheme(app, host, "hljs-theme-one", 4, "not all")
        case None => diagLine("[markdown-notes] 默认窗口未登记，vendor 注入跳过")
    }
}

/** 把一份 hljs 主题 CSS 注入成 style 元素（id 带前缀 hljs-theme-，页面切换逻辑按前缀抓） */
func installTheme(app: TauriApp, host: WebViewHost, id: String, vendorIdx: Int64, media: String): Unit {
    match (vendorText(app, vendorIdx)) {
        case Some(css) =>
            let js = "var s=document.createElement('style');s.id='" + id + "-inj';s.media='" + media +
                "';s.textContent=" + JsonString(css).toJsonString() +
                ";(document.head||document.documentElement).appendChild(s);"
            host.addInitScript(js)
        case None =>
            diagLine("[markdown-notes] vendor 样式缺失（下标 ${vendorIdx}，该主题不可用）")
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
            diagLine("[markdown-notes] menu click ${json}")
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

/** 工作区播种（幂等）：目录不存在就建，欢迎笔记不存在就写。鸿蒙侧 cwd 不可预期，
 *  两步都包 try——失败只留一行 stderr，应用照常启动（列目录会如实报错）。 */
func seedWorkspace(): Unit {
    if (!exists("notes")) {
        try {
            Directory.create("notes", recursive: true)
            diagLine("[markdown-notes] 工作区 notes/ 不存在，已创建")
        } catch (e: Exception) {
            diagLine("[markdown-notes] 创建工作区 notes/ 失败（列目录会报错）：${e}")
        }
    }
    if (!exists("notes/欢迎.md")) {
        let welcome: String = "# 欢迎使用 Markdown 笔记\n\n这是你的第一篇笔记，改改看：\n\n- **粗体**、*斜体*、`行内码`\n- 右侧实时预览，`Ctrl+S` 保存\n\n```js\nvar hello = \"world\";\n```\n"
        try {
            File.writeTo("notes/欢迎.md", welcome.toArray())
            diagLine("[markdown-notes] 已播种欢迎笔记 notes/欢迎.md")
        } catch (e: Exception) {
            diagLine("[markdown-notes] 播种欢迎笔记失败（不影响使用）：${e}")
        }
    }
}

/**
 * 业务装配点（RFC-002 §4.1）：骨架的 launcher（targets/ 下各目标的 src）调用它取 AppSpec。
 *
 * 平台知识只有一处：菜单要经 hostOf("main") 装（AGENTS §2「预置类宿主能力」——
 * 必须在 run() 之前；鸿蒙侧菜单 2026-10-24 真机取证通过，同一套 MenuModel 照走）。
 * 页面路径 / 窗口尺寸 / 能力目录由清单决定，launcher 会按清单覆盖。
 */
public func build(): AppSpec {
    // 自检开关按平台分流（selfCheckEnabled）：鸿蒙默认开（设备上设不了环境变量），
    // 桌面由 CJ_MARKDOWN_SELFCHECK=1 显式开；不可变量直接进闭包（AGENTS §4 闭包捕获坑）
    let selfCheckOn = selfCheckEnabled()
    diagLine("[markdown-notes] build start（业务包 markdownNotes，selfcheck=${selfCheckOn}）")

    // 尺寸与清单 [[windows]] 一致：launcher 会按清单再覆盖一次，两处一致是「清单为单一真相」
    // 的体现，这里只是给人看的默认值
    let spec = AppSpec()
        .window(WindowConfig("cj-tauri Markdown 笔记", 1180, 760))
        .plugin(FsPlugin())
        .plugin(StorePlugin())
        .plugin(DialogPlugin())
        .wire({ app =>
            app.register("report", ReportCommand())
            app.register("notes:env", NotesEnvCommand(selfCheckOn))
            // 原生菜单 + 事件回投：必须在 run() 之前装配（AGENTS §2「预置类宿主能力」）；
            // 点击事件由框架自动投前端 `menu:click`，能力清单 events 里声明了 "menu" 才放行
            let router = MenuRouter(app)
            app.onShellEvent({ json, label => router.onShell(json, label) })
            match (app.hostOf("main")) {
                case Some(_) =>
                    app.setMenuTo("main", buildAppMenu())
                    diagLine("[markdown-notes] menu attached")
                case None => diagLine("[markdown-notes] 默认窗口未登记，菜单未装")
            }
            installVendorScripts(app)
            seedWorkspace()
        })
    return spec
}
