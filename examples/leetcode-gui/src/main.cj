package leetcode_gui

import cjTauri.*
import std.collection.*
import std.fs.*

/**
 * 仓颉版力扣 · cj-tauri 示例应用
 *
 * 三栏布局（前端在 ui/index.html）：
 *   左  题库列表（题号 / 标题 / 难度徽标）
 *   中  代码编辑区（textarea 等宽字体，仓颉代码）
 *   下  终端 / 运行结果区（编译错误、逐条用例判定、耗时）
 *
 * 原生菜单（应用层 API，run() 之前装配）：
 *   运行(Run)        → 菜单点击 → shell 事件 → onShellEvent 分发到前端 menu:click
 *                      → 前端 invoke leetcode:run（cjc 编译 + 运行判定）
 *   重置代码(Reset)  → 恢复模板
 *   帮助(About)      → 关于信息
 *
 * 菜单事件链路照 AGENTS §2：应用层只挂可叠加的 app.onShellEvent 钩子，框架自动把
 * kind=menu 的事件投成前端 menu:click——前端直接 listen，不走宿主 API。
 *
 * 运行目录 = 本示例根（capabilities/、ui/ 按相对路径解析）。
 * 判题产物在 target/leetcode/ 下（.gitignore 已含 target/，不入库）。
 */

/** 前端页面路径（工作目录 = 项目根） */
let UI_PATH = "ui/index.html"

/** vendor 库路径（CodeMirror 5，MIT，见 ui/vendor/codemirror.LICENSE.txt 与 AGENTS §5 登记） */
let VENDOR_CSS = "ui/vendor/codemirror.min.css"
let VENDOR_JS = "ui/vendor/codemirror.min.js"

/**
 * 读 vendor 文件；缺失返回 None（页面占位符留空注释，编辑器降级 textarea）。
 * 页面是 run(html) 的内联来源（Windows 下 NavigateToString，无真实来源），
 * `<script src>` 相对路径不成立，vendor 必须内联——markdown-notes 同款做法。
 */
func vendorOrNone(path: String, what: String): Option<String> {
    try {
        return Some(String.fromUtf8(File.readFrom(path)))
    } catch (e: Exception) {
        eprintln("[lc] vendor 缺失 ${path}（${what}降级为纯 textarea）：${e}")
        return None
    }
}

/** 读前端页面并把 vendor 内联进占位符；读不到页面给可读错误 */
func readUi(): String {
    var html = ""
    try {
        html = String.fromUtf8(File.readFrom(UI_PATH))
    } catch (e: Exception) {
        throw Exception("读不到前端页面 ${UI_PATH}（${e}）——请在 examples/leetcode-gui 目录下启动")
    }
    match (vendorOrNone(VENDOR_CSS, "编辑器样式")) {
        case Some(t) => html = html.replace("/*__VENDOR_CSS__*/", t)
        case None => ()
    }
    match (vendorOrNone(VENDOR_JS, "语法高亮与行号")) {
        case Some(t) => html = html.replace("/*__VENDOR_CORE__*/", t)
        case None => ()
    }
    return html
}

/** 原生菜单模型：运行 / 重置 / 关于。id 与前端 menu:click 的处理一一对应 */
func buildMenu(): MenuModel {
    var helpItems = ArrayList<MenuItem>()
    helpItems.add(MenuItem.normal("help.about", "关于"))

    var runItems = ArrayList<MenuItem>()
    runItems.add(MenuItem.normalWithAccel("run.submit", "运行", "Ctrl+R"))
    runItems.add(MenuItem.normalWithAccel("run.reset", "重置代码", "Ctrl+Shift+R"))
    runItems.add(MenuItem.separator())
    runItems.add(MenuItem.submenu("帮助", helpItems))

    return MenuModel(runItems)
}

/** 菜单事件落点：stderr 留痕（诊断走 stderr 是项目铁律） */
func onShellEvent(json: String, label: String): Unit {
    eprintln("[lc] shell event label=${label} ${json}")
}

main(): Int64 {
    eprintln("[lc] main start")

    // 环境自检：cjc 是判题的前置，启动时先给一句环境结论（缺失时打安装引导）
    match (findCjc()) {
        case Some(p) => eprintln("[lc] cjc found: ${p}（判题功能就绪）")
        case None => eprintln("[lc] cjc not found —— 判题不可用。\n${CJC_GUIDE}")
    }

    // 远程题包缓存并入（problems-remote.local.json，上次「加载更多」的结果）：
    // 在 PROBLEMS 被任何命令读到之前完成，缓存题与内置题同池
    loadPackCache()

    let html = readUi()

    let app = TauriApp()
        .window(WindowConfig("仓颉力扣 · cj-tauri", 1280, 820))
        // 三处联动之一：命令注册（其余两处：能力清单 commands 已声明、前端已 invoke）
        .register("leetcode:list", ListProblemsCommand())
        .register("leetcode:get", GetProblemCommand())
        .register("leetcode:run", RunCommand())
        .register("leetcode:saveDraft", SaveDraftCommand())
        .register("leetcode:loadDraft", LoadDraftCommand())
        .register("leetcode:packs", ListPacksCommand())
        .register("leetcode:fetchMore", FetchMoreCommand())
        .register("leetcode:solution", SolutionCommand())
        .register("leetcode:stats", StatsCommand())

    // 预置类能力：菜单必须在 start()/run() 之前定稿
    app.setMenu(buildMenu())
    app.onShellEvent(onShellEvent)

    eprintln("[lc] before run")
    app.run(html)
    eprintln("[lc] after run")
    return 0
}
