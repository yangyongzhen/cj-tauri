package leetcode_gui

import cjTauri.*
import std.collection.*
import stdx.encoding.json.*

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

/**
 * 读前端页面并把 CodeMirror 内联进占位符：内嵌优先（单文件产物没有随行的 ui/），
 * 否则按相对路径读盘——两条路都在 `src/packed_resources.cj`。
 *
 * 页面是 run(html) 的内联来源（Windows 下 NavigateToString，无真实来源），
 * `<script src>` 相对路径不成立，vendor 必须内联——markdown-notes 同款做法。
 */
func readUi(): String {
    var html = textOrFile(PACKED_UI_B64, UI_PATH, "前端页面")
    match (vendorOrFile(0)) {
        case Some(t) => html = html.replace("/*__VENDOR_CSS__*/", t)
        case None => eprintln("[lc] vendor 缺失 ${VENDOR_FILES[0]}（编辑器样式降级）")
    }
    match (vendorOrFile(1)) {
        case Some(t) => html = html.replace("/*__VENDOR_CORE__*/", t)
        case None => eprintln("[lc] vendor 缺失 ${VENDOR_FILES[1]}（语法高亮与行号降级为纯 textarea）")
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

    // 能力清单：内嵌优先（单文件产物没有随行的 capabilities/），否则交给 run() 自动扫描目录。
    // 框架契约是「显式挂载即不自动扫描」，所以两条路互斥、不会叠加或打架。
    if (PACKED_CAPS_B64.size > 0) {
        // 打包器把每个 capabilities/*.json 各自 base64、再用 "," 拼起来（base64 表里没有逗号）；
        // 逐个挂载而不是拼成一份 json——每份清单在框架里本来就是一个独立的 Capability。
        var capsN: Int64 = 0
        for (part in splitBy(PACKED_CAPS_B64, 44u8)) {
            app.addCapabilityJson(JsonValue.fromStr(decodeBase64(part)))
            capsN += 1
        }
        eprintln("[lc] 能力清单来自内嵌资源（${capsN} 份，共 ${PACKED_CAPS_B64.size} 字节 base64）")
    }

    // 预置类能力：菜单必须在 start()/run() 之前定稿
    app.setMenu(buildMenu())
    app.onShellEvent(onShellEvent)

    eprintln("[lc] before run")
    app.run(html)
    eprintln("[lc] after run")
    return 0
}
