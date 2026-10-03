package cjTauri

import std.collection.*

/**
 * WebView 宿主层（对标 Tauri 2 的 tao + wry 抽象）
 *
 * 平台差异由条件编译隔离在各自的宿主文件内，上层完全共用：
 *   - Linux 桌面：host_webkit.cj（WebKitGTK，经 native/bridge_linux.c 在原生 pthread 运行）
 *   - Windows   ：host_webview2.cj（WebView2 / Edge Chromium，经 native/bridge_win.c）
 *   - 鸿蒙       ：ArkWeb（架构预留，条件编译位）
 * IPC 桥（ipc_hub.cj）与能力安全模型（capability.cj）跨平台复用。
 */

/**
 * 宿主能力位（与 native/bridge_core.h 的 `CJ_CAP_*` **逐位对齐**，两侧不许各写各的）
 *
 * 由平台在 C 侧 `cj_plat_init` 时填好，经 `WebViewHost.hostCapabilities()` 取回。
 * 「这台机器上的框架支持什么」是**静态事实**（编出来的桥有没有那块），不是运行期探测：
 * 应用据此决定要不要建菜单 / 托盘，拿不到就别骗自己。
 *
 * 与能力安全模型（capability.cj）的 `Capability` 不是一回事：那个管「页面能不能调某个命令」，
 * 这个管「宿主有没有这个本事」——所以名字里带 host 前缀，别混。
 */
public const CJ_CAP_MENU: Int32 = 1

public const CJ_CAP_TRAY: Int32 = 2

public const CJ_CAP_DRAG_DROP: Int32 = 4

public interface WebViewHost {
    /**
     * 本窗口的 label（单窗口阶段恒为 "main"）
     *
     * 与 `WindowRecord.label` 是同一个值：注册表是路由的权威来源，宿主自己也留一份——
     * 给前端注入 label（`window.__CJ_TAURI_LABEL__`）以及将来的窗口内自省都用它。
     */
    public func label(): String

    /**
     * 启动宿主：创建窗口 + WebView，加载 HTML，进入事件循环
     */
    public func start(html: String): Unit

    /**
     * 按 URL 启动宿主（http(s):// 或 file://）
     *
     * 与 start(html) 二选一：同一次启动里两者都设时 URL 优先。
     * URL 页面有真实来源，相对路径资源、动态 import、前端路由才成立（file:// 下禁止 fetch/XHR）。
     */
    public func startUrl(url: String): Unit

    /**
     * 注册一段「页面脚本执行前」注入的初始化脚本（多次调用按注册顺序注入）
     *
     * 必须在 start() / startUrl() 之前调用：宿主创建 WebView 时一次性交给 C 桥，桥以
     * document-start 注入（WebKit user script / WebView2 AddScriptToExecuteOnDocumentCreated）。
     * 因此它对 HTML 与 URL 两种页面来源**一视同仁**——插件的 jsShim 走的就是这条通道（RFC §5.4 的 v2 方案），
     * 不再靠字符串拼 HTML。空串忽略；脚本是普通 JS 片段，不要自带 <script> 标签。
     */
    public func addInitScript(js: String): Unit

    /**
     * 重新加载当前页面（整页 reload，对标浏览器刷新）
     *
     * 页面尚未加载时为空操作；开发者工具里的刷新按钮等价于此。
     */
    public func reload(): Unit

    /**
     * 应用窗口配置（标题 / 尺寸）；必须在 start() 之前调用，宿主据此创建窗口
     */
    public func setWindowConfig(config: WindowConfig): Unit

    /**
     * 是否允许打开开发者工具；必须在 start() 之前调用
     */
    public func setDevTools(enabled: Bool): Unit

    /**
     * 运行时打开开发者工具（WebView2 DevTools / WebKit Inspector）
     */
    public func openDevTools(): Unit

    /**
     * 设置本窗口的菜单栏（RFC-002 §5.2 的线路文本；空串 = 清空菜单栏）
     *
     * 调用时机两头都行：`start()` 之前调用会在建窗时一次建好（未就绪的文本由 C 桥记着）；
     * 之后就投到宿主 UI 线程重建整棵菜单。
     * 平台没有菜单能力（`hostCapabilities()` 不含 `CJ_CAP_MENU`）时不影响其它功能——
     * 「能力位为 0 就别建菜单」是调用方的约定，宿主不替应用猜。
     */
    public func setMenu(wire: String): Unit

    /**
     * 运行期改单个菜单项的状态（按 id 找；找不到只记一行日志，不报错）
     *
     * 只改状态、不改结构：结构变化走 `setMenu` 整棵重建。状态的真身在平台对象上
     * （Windows 的 HMENU、GTK 的 GtkCheckMenuItem），模型本身是只读的——理由见 src/menu.cj。
     */
    public func setMenuItemState(id: String, enabled: Bool, checked: Bool): Unit

    /**
     * 本宿主的静态能力位（`CJ_CAP_*` 的按位或）：能不能做菜单 / 托盘 / 文件拖入
     *
     * 宿主尚未创建（`dispose()` 之后 / `start()` 之前未分配句柄）返回 0。
     * 注意与命令级的能力安全模型无关：这里说的是宿主本事，不是页面权限。
     */
    public func hostCapabilities(): Int32

    /**
     * 装配本窗口的 shell 事件回调（菜单点击等；载荷是 C 桥的 JSON 信封）
     *
     * 与 `setMessageHandler` 同一套路，区别是事件源在宿主侧（应用菜单）而不是页面。
     * **多窗口下必须按宿主身份路由**：C 侧回调首参是句柄，只有本窗口的句柄才转给本实例的
     * 这个回调——这正是「回调带宿主身份」的落地方式（见 docs/RFC-菜单-托盘-拖放.md §5.5）。
     */
    public func setShellHandler(handler: (String) -> Unit): Unit

    /**
     * 原生文件选择对话框（阻塞到用户关闭）：返回选中的路径，取消 / 失败返回空串。
     *
     * filter 是「描述|模式|描述|模式」拼串（Windows 惯例；GTK 端按同一格式解析），
     * 例如 "文本文件|*.txt|所有文件|*.*"；空串表示不限制。
     * 必须在 start() / startUrl() 之后调用——对话框要拿已创建的应用窗口当父窗口。
     */
    public func showFileDialog(save: Bool, title: String, filter: String): String

    /**
     * 原生消息对话框（阻塞到用户关闭）：返回用户是否点了「确定」。
     *
     * kind 取 "info" / "warning" / "error" / "confirm"（其它值按 info 处理）。
     * info / warning / error 只有一个「确定」，弹出即成立；只有 confirm 会返回 false。
     */
    public func showMessageDialog(kind: String, title: String, message: String): Bool

    /**
     * 原生 → JS：在 WebView 中执行脚本
     */
    public func runJs(js: String): Unit

    /**
     * 停止本窗口的事件循环（低层原语）
     *
     * 应用级退出请用 `AppHost.quit()`——它会走所有窗口；单窗口下两者等价。
     * 原语留在宿主上是因为「循环归谁所有」只有实现方知道（两平台的收尾方式不同：
     * Linux 只收主循环、窗口留给收尾销毁，Windows 直接 DestroyWindow），上层不该自己拼。
     */
    public func quit(): Unit

    /**
     * 装配前端消息回调（WebView 送来的 JSON 字符串 → IPC hub）
     */
    public func setMessageHandler(handler: (String) -> Unit): Unit

    /**
     * 宿主事件循环是否已退出（窗口关闭等），app.run 据此阻塞与收尾
     *
     * 同为低层原语：应用级等待用 `AppHost.waitForExit()`，调用方不必自己写轮询。
     */
    public func shouldQuit(): Bool

    /**
     * 释放宿主资源（宿主编由 C 侧分配与回收，跨 FFI 不换分配器）：幂等、无需检查调用时机
     *
     * TauriApp.run / runUrl 在 waitForExit() 之后调用它；实现方须把句柄置空——
     * 释放后该实例不可再启动（原生窗口已随销毁路径在关窗时收尾）。
     * 为什么「关窗」不等于「释放」：见 docs/架构演进-多平台与多窗口.md §6.1。
     */
    public func dispose(): Unit
}

/**
 * 应用级宿主（对标 Tauri 2 的 `AppHandle`）
 *
 * 与 `WebViewHost` 的分工：`WebViewHost` 是**一个窗口**（创建、投脚本、对话框、本窗口的循环原语），
 * `AppHost` 是**整个应用**（退出、按 label 取窗口；将来还有托盘与应用菜单——批次 3 只定模型）。
 * 批次 2 由 `TauriApp` 实现：它持有窗口注册表，也只有它知道「哪些窗口还开着、应用该不该退」。
 *
 * 为什么 quit / waitForExit 收在这一层：它们跨窗口。宿主仍保留 `quit()` / `shouldQuit()` 作低层原语
 * （循环归宿主所有），但**应用的公开入口只有这里**——多窗口时代的「退出」必然是「先把各窗口收掉」。
 */
public interface AppHost {
    /**
     * 退出应用：收掉所有窗口的事件循环，`run()` / `runUrl()` 随即返回
     */
    public func quit(): Unit

    /**
     * 阻塞到应用退出（窗口关闭 / quit）后返回；`run()` / `runUrl()` 内部调它
     */
    public func waitForExit(): Unit

    /**
     * 按 label 取窗口宿主（对标 Tauri 的 `app.get_webview_window(label)`）；未注册返回 None
     */
    public func hostOf(label: String): Option<WebViewHost>
}

/**
 * C 桥原生线程 → 仓颉回调的全局槽位。
 * 各平台宿主在 start() 时把自己的回调装配到这里，C 侧的 @C 函数经此转入仓颉闭包。
 */
/**
 * 一条 shell 事件路由：C 侧句柄 → 本窗口的派发闭包
 *
 * `dispatch` 是可变的：闭包读的是宿主实例的 `shellHandler` 字段（不是快照），
 * 所以应用在 `start()` 之后再调 `setShellHandler` 同样生效。
 */
class ShellRoute {
    let handle: CPointer<Unit>
    var dispatch: (String) -> Unit

    init(handle: CPointer<Unit>, dispatch: (String) -> Unit) {
        this.handle = handle
        this.dispatch = dispatch
    }
}

class HostGlobals {
    static var onMessage: (String) -> Unit = { _ => }
    static var onDestroy: () -> Unit = { => }
    // shell 事件（菜单点击等）的**路由表**：各宿主在装配时登记自己一条（句柄 + 派发闭包）。
    //
    // 为什么不是单槽：C 侧对所有窗口只有一个回调入口（`cj_on_shell_fn` 就是一个函数指针），
    // 「事件属于哪个窗口」只能在仓颉侧判；单槽会被后装配的窗口覆盖——先装的那个从此收不到自己的
    // 菜单点击（两窗探针一跑就露）。表里每条只认领自己的句柄。
    // 登记发生在 prepareHost（run() 之前、宿主线程还没起），派发时才读表 → 登记期没有并发。
    static var shellRoutes: ArrayList<ShellRoute> = ArrayList<ShellRoute>()

    /**
     * 登记（或更新）一条 shell 事件路由
     *
     * 同一句柄重复登记＝换掉旧闭包（宿主被重新 prepare 时不叠加、事件也不会派发两次）；
     * 句柄比较走 C 侧 `cj_bridge_host_eq`（仓颉的 `CPointer` 不支持 `==`）。
     * 顺带解决「旧宿主销毁、新宿主复用同一地址」：新宿主登记时就覆盖了那条陈旧路由。
     */
    static func registerShellRoute(handle: CPointer<Unit>, dispatch: (String) -> Unit): Unit {
        for (r in HostGlobals.shellRoutes) {
            var same: Int32 = 0
            unsafe {
                same = cj_bridge_host_eq(r.handle, handle)
            }
            if (same != 0) {
                r.dispatch = dispatch
                return
            }
        }
        HostGlobals.shellRoutes.add(ShellRoute(handle, dispatch))
    }
    // 文件类对话框的结果：C 桥在 GTK / 宿主线程上经 dialogOnResult 写入，
    // 阻塞等待的调用方醒来后读取。同一时刻只允许一个对话框（桥侧有互斥），单槽位够用。
    static var dialogResult: String = ""
}

/**
 * kind 字符串 → C 桥的对话框编号（与 native/bridge_linux.c、bridge_win.c 的取值一一对应）
 */
func dialogKindCode(kind: String): Int32 {
    match (kind) {
        case "warning" => 3
        case "error" => 4
        case "confirm" => 5
        case _ => 2
    }
}

/**
 * 对话框结果回调（C 桥 → 仓颉）：文件类对话框选中的路径经它送回。
 * 由 C 桥在自己的 UI 线程上调用，与 hostOnMessage 同一套路；先写槽位再由桥唤醒调用方。
 */
@C
func dialogOnResult(path: CString): Unit {
    try {
        HostGlobals.dialogResult = path.toString()
    } catch (e: Exception) {
        eprintln("[cj-tauri] dialog callback error: ${e}")
    }
}

/**
 * shell 事件回调（C 桥 → 仓颉）：菜单点击等经它送回，首参是**发生事件的宿主句柄**。
 *
 * 由 C 桥在宿主 UI 线程上调用（与 hostOnMessage 同一套路）；句柄→实例的解引用交给
 * 各宿主在 `setShellHandler` 时注册的筛选闭包，本函数只做「别抛穿 FFI 边界」这一件事。
 * 非 @When：两平台的 C 侧都调它（签名一致，首参不透明）。
 */
@C
func shellOnEvent(host: CPointer<Unit>, json: CString): Unit {
    try {
        // 逐条认领：句柄对得上的那条派发，其余静默跳过（C 侧只有一个入口，区分就在这里）
        for (r in HostGlobals.shellRoutes) {
            var mine: Int32 = 0
            unsafe {
                mine = cj_bridge_host_eq(r.handle, host)
            }
            if (mine != 0) {
                r.dispatch(json.toString())
            }
        }
    } catch (e: Exception) {
        eprintln("[cj-tauri] shell callback error: ${e}")
    }
}

/**
 * 创建当前平台的 WebView 宿主（对标 Tauri 2 的 runtime 选择）
 *
 * label 按窗口给定（多窗口）：默认窗口传 DEFAULT_WINDOW_LABEL，附加窗口传各自登记的 label。
 * 必须是构造参数而不是事后 setter——label 决定页面侧 `window.__CJ_TAURI_LABEL__` 与事件过滤，
 * 启动之后再改就晚了（见 docs/架构演进-多平台与多窗口.md §7.3）。
 */
@When[os == "Linux"]
func createHost(label: String): WebViewHost {
    return WebKitHost(label)
}

@When[os == "Windows"]
func createHost(label: String): WebViewHost {
    return WebView2Host(label)
}
