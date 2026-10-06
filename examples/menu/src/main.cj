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
 *   → 仓颉 host.cj 的 shellOnEvent 按句柄在路由表里认领 → 本窗口的 shellHandler
 *     （**框架**装的，见 TauriApp.wireShellEvents）
 *   → 框架 `dispatchShellEvent`：先跑应用钩子（本例 onShellEvent），再投前端事件 `menu:click`
 *   → 钩子里打 `[menuprobe] window=… shell {…}`，对 edit.toggle 再走**应用层 API** 改状态
 *     （app.setMenuItemStateTo → 宿主 → 平台在 UI 线程上改真菜单）
 *   → 驱动脚本用 GetMenuItemInfo **读回**状态
 * 所以「菜单挂上去了没有、状态真变了没有」由外部（Win32 查询）判，而不是应用自己说「我设好了」。
 *
 * 两窗口（main + second）是**故意的**：两个宿主各建一份菜单，而 C 侧只有一个回调入口，事件按宿主
 * 句柄路由。驱动脚本只点**第二个窗口**的菜单——若第一个窗口也跟着响，路由就是坏的
 * （这条正是 cj_bridge_host_eq + HostGlobals.shellRoutes 的判据）。探针这一侧也一并对上：
 * 应用级钩子只有**一份**（可叠加，不像宿主层 setShellHandler 那样后装覆盖先装），
 * 靠框架给的 label 认领到对应窗口的状态表——多窗口下「谁的事件是谁的」在这里也是可证伪的。
 *
 * 菜单/状态一律走应用层 API（app.setMenuTo / app.setMenuItemStateTo），不再直接摸宿主：
 * 这样「应用层模型 → 平台」这条新通路也进了证据里，而框架的 shell 分发（应用层接管宿主槽位）
 * 只有走应用层 API 才被真正执行到。
 *
 * 断言口径（run.bat 逐字断言）：
 *   [menuprobe] window=main   capabilities=N menu-capable=true
 *   [menuprobe] window=main   menu set bytes=N
 *   [cj-bridge] menu applied: items=N            ← 菜单在宿主 UI 线程上真建好
 *   [cj-bridge] menu clicked: id=file.new enabled=1 checked=0
 *   [menuprobe] window=second shell {"kind":"menu","id":"file.new",…}
 *   [menuprobe] window=second state requested id=view.sidebar enabled=false checked=true
 *   [cj-bridge] set menu item: id=view.sidebar enabled=0 checked=1
 *   [menuprobe] after run
 */

/** 探针的菜单模型：两窗各建一份（各窗独立菜单对象；模型也各存一份，见 arm） */
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
   刻意不写 JS——内联 JS 的反斜杠会被三引号字符串先吃掉（AGENTS §4），没有脚本就没有这个坑。
   前端那一跳（listen("menu:click") / menu.setChecked）由脚手架模板与文档承接。 */
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
 * 一个窗口的 shell 事件落点状态
 *
 * 应用侧只做两件事：把事件原样打进 stderr（诊断走 stderr 是项目铁律），
 * 以及对其中一项回手改状态——这一项把「运行期改状态」这条通路也拉进证据里。
 * 状态位是**每窗一份**的（两窗各有一个实例）：能力位只报一次、状态只推一次是窗口级的事实。
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

    public func onShell(app: TauriApp, json: String): Unit {
        // 能力位在这里读才是真值：句柄建窗时才存在，预置阶段读到 0 不代表平台没这本事
        if (!this.capsReported) {
            this.capsReported = true
            let caps = this.host.hostCapabilities()
            eprintln("[menuprobe] window=${this.label} capabilities=${caps} menu-capable=${(caps & CJ_CAP_MENU) != 0}")
        }
        eprintln("[menuprobe] window=${this.label} shell ${json}")
        // 读的是「点击」这个动作本身，不是解析结果：只要这一项被点过，就证明
        // 句柄 → 路由表 → 本窗口回调 → 应用层分发这条链把事件送到了正确的实例上
        if (let Some(_) <- json.indexOf("edit.toggle")) {
            if (!this.statePushed) {
                this.statePushed = true
                eprintln("[menuprobe] window=${this.label} state requested id=view.sidebar enabled=false checked=true")
                // 改的是**事件发生的那个窗口**的菜单：label 由框架给的钩子参数说了算
                app.setMenuItemStateTo(this.label, "view.sidebar", false, true)
            }
        }
    }
}

/** 应用级钩子的认领表 + 窗口装配（一份钩子管所有窗口，靠 label 找到本窗口的状态） */
class ProbeRouter {
    private let app: TauriApp
    private let probes: HashMap<String, WindowProbe> = HashMap<String, WindowProbe>()

    init(app: TauriApp) {
        this.app = app
    }

    /** 给一个已登记的窗口装菜单（两窗都走它，只有 label 不同） */
    public func arm(label: String): Unit {
        match (this.app.hostOf(label)) {
            case Some(host) =>
                // 不在这里读能力位：宿主还没起来，读到的 0 是「句柄还没有」而不是「平台没这本事」，
                // 拿它当判据会得出错误结论（运行期那次读到的才算数，见 onShell）
                this.probes.add(label, WindowProbe(label, host))
                // 菜单模型两窗各建一份：同一个实例给两窗会让「改一窗的状态」串到另一窗的模型上
                let menu = probeMenu()
                let wire = menu.toWire()
                this.app.setMenuTo(label, menu)
                eprintln("[menuprobe] window=${label} menu set bytes=${wire.size}")
            case None =>
                eprintln("[menuprobe] window=${label} not registered")
        }
    }

    /** 框架分发时按 label 认领；未知 label 说明框架与探针的窗口集合对不上，出声 */
    public func onShell(json: String, label: String): Unit {
        match (this.probes.get(label)) {
            case Some(probe) => probe.onShell(this.app, json)
            case None => eprintln("[menuprobe] shell event 来自未登记的窗口：label=\"${label}\"")
        }
    }
}

main(): Int64 {
    eprintln("[menuprobe] main start")
    let app = TauriApp()
        .window(WindowConfig("cj-tauri menu probe (main)", 760, 460))
    // 第二窗口与第一窗口各建一份菜单：用来验证「事件按宿主句柄路由」
    app.addWindow("second", WindowConfig("cj-tauri menu probe (second)", 760, 460), PROBE_HTML)
    let router = ProbeRouter(app)
    // 应用级钩子：必须在 run() 之前注册（框架在装配窗口时装自己的宿主分发器，钩子挂在它上面）
    app.onShellEvent({ json, label => router.onShell(json, label) })
    router.arm("main")
    router.arm("second")
    eprintln("[menuprobe] before run")
    app.run(PROBE_HTML)
    eprintln("[menuprobe] after run")
    return 0
}
