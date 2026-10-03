package menu_probe

import cjTauri.*
import std.collection.*

/*
 * 菜单能力位探针（Windows 实机；RFC-002 §5 的落地验证）
 *
 * 要证的不是「菜单栏能显示」，而是「点下去这一整条链是通的」，所以本探针**不靠人点菜单**：
 * 驱动脚本 click-menu.ps1 用 Win32 找到窗口 → 从窗口的菜单里读出菜单项的命令 id →
 * PostMessage WM_COMMAND。链路是：
 *   PostMessage(WM_COMMAND) → 平台层（bridge_win.c）查 cmd_id → app id 映射，回投 core
 *   → core 打 `menu clicked: id=… enabled=… checked=…` 并调 on_shell（带宿主句柄）
 *   → 仓颉 shellOnEvent → 按句柄在路由表里认领 → 本窗口的 shellHandler（本例）
 *   → 打 `[menuprobe] window=… shell {…}`；对 edit.toggle 再回手 setMenuItemState
 *   → 平台在 UI 线程上改真菜单 → 驱动脚本用 GetMenuItemInfo **读回**状态
 * 所以「菜单挂上去了没有、状态真变了没有」由外部（Win32 查询）判，而不是应用自己说「我设好了」。
 *
 * 两窗口（main + second）是**故意的**：两个宿主各建一份菜单、各装一个回调，而 C 侧只有一个
 * 回调入口，事件按宿主句柄路由。驱动脚本只点**第二个窗口**的菜单——若第一个窗口也跟着响，
 * 路由就是坏的（这条正是本轮新写的 cj_bridge_host_eq + HostGlobals.shellRoutes 的判据）。
 *
 * 断言口径（run.bat 逐字断言）：
 *   [menuprobe] window=main   capabilities=N menu-capable=true
 *   [menuprobe] window=main   menu set bytes=N
 *   [cj-bridge] menu applied: items=N            ← 菜单在宿主 UI 线程上真建好
 *   [cj-bridge] menu clicked: id=file.new enabled=1 checked=0
 *   [menuprobe] window=second shell {"kind":"menu","id":"file.new",…}
 *   [menuprobe] window=second state requested id=view.sidebar enabled=false checked=true
 *   [cj-bridge] menu item state: id=view.sidebar enabled=0 checked=1
 *   [menuprobe] after run
 */

/** 探针的菜单模型：两窗各建一份（同一份线路文本，各窗独立菜单对象） */
func probeMenu(): MenuModel {
    var help = ArrayList<MenuItem>()
    help.add(MenuItem.normal("help.about", "About"))
    var items = ArrayList<MenuItem>()
    items.add(MenuItem.normalWithAccel("file.new", "New", "Ctrl+N"))
    items.add(MenuItem.checkbox("view.sidebar", "Sidebar", false))
    items.add(MenuItem.separator())
    items.add(MenuItem.submenu("Help", help))
    items.add(MenuItem.normal("edit.toggle", "Disable sidebar"))
    return MenuModel(items)
}

/* 页面只负责「看得见」：驱动脚本从 Win32 那一侧点菜单，前端不参与本次验证。
   刻意不写 JS——内联 JS 的反斜杠会被三引号字符串先吃掉（AGENTS §4），没有脚本就没有这个坑。 */
const PROBE_HTML = """
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>cj-tauri menu probe</title></head>
<body style="font-family: system-ui; background:#1a1a2e; color:#eee; padding:24px">
<h1>cj-tauri menu probe</h1>
<p>窗口顶上是原生菜单栏：New / Sidebar（勾选）/ Help 子菜单 / Disable sidebar。</p>
<p>点击由 click-menu.ps1 用 Win32 触发，证据在桥的 stderr 日志里。</p>
</body></html>
"""

/**
 * 一个窗口的 shell 事件落点
 *
 * 应用侧只做两件事：把事件原样打进 stderr（诊断走 stderr 是项目铁律），
 * 以及对其中一项回手改状态——这一项把「运行期改状态」这条通路也拉进证据里。
 */
class WindowProbe {
    private let label: String
    private let host: WebViewHost
    private var statePushed: Bool = false
    private var capsReported: Bool = false

    init(label: String, host: WebViewHost) {
        this.label = label
        this.host = host
    }

    public func onShell(json: String): Unit {
        // 能力位在这里读才是真值：句柄建窗时才存在，预置阶段读到 0 不代表平台没这本事
        if (!this.capsReported) {
            this.capsReported = true
            let caps = this.host.hostCapabilities()
            eprintln("[menuprobe] window=${this.label} capabilities=${caps} menu-capable=${(caps & CJ_CAP_MENU) != 0}")
        }
        eprintln("[menuprobe] window=${this.label} shell ${json}")
        // 读的是「点击」这个动作本身，不是解析结果：只要这一项被点过，就证明
        // 句柄 → 路由表 → 本窗口回调这条链把事件送到了正确的实例上
        if (let Some(_) <- json.indexOf("edit.toggle")) {
            if (!this.statePushed) {
                this.statePushed = true
                eprintln("[menuprobe] window=${this.label} state requested id=view.sidebar enabled=false checked=true")
                this.host.setMenuItemState("view.sidebar", false, true)
            }
        }
    }
}

/** 给一个已登记的窗口装上菜单 + shell 回调（两窗都走它，只有 label 不同） */
func armWindow(app: TauriApp, label: String): Unit {
    match (app.hostOf(label)) {
        case Some(host) =>
            // 不在这里读能力位：宿主还没起来，读到的 0 是「句柄还没有」而不是「平台没这本事」，
            // 拿它当判据会得出错误结论（运行期那次读到的才算数，见 onShell）
            let probe = WindowProbe(label, host)
            host.setShellHandler({ json => probe.onShell(json) })
            let wire = probeMenu().toWire()
            host.setMenu(wire)
            eprintln("[menuprobe] window=${label} menu set bytes=${wire.size}")
        case None =>
            eprintln("[menuprobe] window=${label} not registered")
    }
}

main(): Int64 {
    eprintln("[menuprobe] main start")
    let app = TauriApp()
        .window(WindowConfig("cj-tauri menu probe (main)", 760, 460))
    // 第二窗口与第一窗口用同一份菜单模型：用来验证「事件按宿主句柄路由」
    app.addWindow("second", WindowConfig("cj-tauri menu probe (second)", 760, 460), PROBE_HTML)
    armWindow(app, "main")
    armWindow(app, "second")
    eprintln("[menuprobe] before run")
    app.run(PROBE_HTML)
    eprintln("[menuprobe] after run")
    return 0
}
