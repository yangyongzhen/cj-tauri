package cjTauri

import std.collection.*
import stdx.encoding.json.*

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

/**
 * 宿主能力位的**可读形态**（RFC-002 §5.3）：`CJ_CAP_*` 位域 → 具名布尔 + `toJson`。
 *
 * 为什么要有它：`hostCapabilities()` 给的是位域，应用与 `system:host` 的调用方要的是
 * 「menu 有没有」这种具名答案；位域 ↔ 名字的对应只留在这一个地方，
 * 免得每个消费点各写各的 `(caps & CJ_CAP_MENU) != 0`（写错一位就是一个静默的假答案）。
 *
 * `platform` 不在位域里，由调用方（`currentPlatform()`）单独给——位域来自 C 桥，平台标识来自
 * 仓颉侧的条件编译，两者本就是两个来源。
 */
public class HostCapabilities {
    public let platform: String
    public let menu: Bool
    public let tray: Bool
    public let dragDrop: Bool

    public init(platform: String, menu: Bool, tray: Bool, dragDrop: Bool) {
        this.platform = platform
        this.menu = menu
        this.tray = tray
        this.dragDrop = dragDrop
    }

    /** 位域 → 具名布尔（`platform` 由调用方给，见类注释） */
    public static func fromBits(platform: String, caps: Int32): HostCapabilities {
        return HostCapabilities(
            platform,
            (caps & CJ_CAP_MENU) != 0,
            (caps & CJ_CAP_TRAY) != 0,
            (caps & CJ_CAP_DRAG_DROP) != 0
        )
    }

    /** `system:host` 的返回形状：`{"platform":"windows","menu":true,"tray":true,"dragDrop":true}` */
    public func toJson(): JsonValue {
        var obj = JsonObject()
        obj.put("platform", JsonString(this.platform))
        obj.put("menu", JsonBool(this.menu))
        obj.put("tray", JsonBool(this.tray))
        obj.put("dragDrop", JsonBool(this.dragDrop))
        return obj
    }
}

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
     * 装配本窗口的销毁回调（窗口关闭 / 退出收尾时恰好触发一次）
     *
     * 多窗口下按宿主身份路由（C 侧回调首参是句柄），所以每扇窗口装自己的——回调不带参数，
     * 因为「是哪扇窗」在装配时就已确定（应用可经 `app.hostOf(label)` 逐窗安装）。
     * 与 `setShellHandler` 同为**可变槽位**：在 `start()` 之后再装同样生效（路由闭包读字段，不是快照）。
     */
    public func setDestroyHandler(handler: () -> Unit): Unit

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
 * C 桥原生线程 → 仓颉回调的中转。
 * 各平台宿主在 prepareHost() 时把「本句柄 → 本实例的回调」登记进路由表，C 侧的 @C 函数按句柄取用。
 */
/**
 * 一条**宿主级回调路由**：C 侧句柄 → 本窗口的三个回调
 *
 * C 侧所有回调的入口都是模块级 @C 函数（每个宿主注册的是同一个函数指针），句柄是唯一能分辨
 * 「哪个窗口」的凭据——三类回调都按句柄查表，查到谁就派发给谁。
 *
 * 闭包都是可变的：读的是宿主实例的字段（不是快照），所以应用在 `start()` 之后再调
 * `setShellHandler` / `setDestroyHandler` 同样生效。
 */
class HostRoute {
    let handle: CPointer<Unit>
    var onShell: (String) -> Unit
    var onDestroy: () -> Unit
    var onDialog: (String) -> Unit

    init(handle: CPointer<Unit>, onShell: (String) -> Unit, onDestroy: () -> Unit,
         onDialog: (String) -> Unit) {
        this.handle = handle
        this.onShell = onShell
        this.onDestroy = onDestroy
        this.onDialog = onDialog
    }
}

class HostGlobals {
    // 前端消息：**有意保留单槽**。报文自带发起窗口的 window label（架构文档 §7.3），
    // TauriApp 给所有窗口装的是同一只派发器，路由不靠句柄（见 src/app.cj 的 wireHostCallbacks）。
    static var onMessage: (String) -> Unit = { _ => }
    // 其余三类回调没有「自带身份」的载荷（销毁无载荷、文件框结果只有路径、shell 事件只有信封），
    // 只能让 C 侧把句柄带回来。表里每条只认领自己的句柄。
    // 单槽时代的症状：后装配的窗口覆盖先装配的——「哪扇窗关了」认错、两窗同时开文件框时结果串台
    // （见 docs/架构演进-多平台与多窗口.md §7.5）。
    // 登记发生在 prepareHost（run() 之前、宿主线程还没起），派发时才读表 → 登记期没有并发。
    static var hostRoutes: ArrayList<HostRoute> = ArrayList<HostRoute>()

    /**
     * 登记（或更新）一条宿主级路由
     *
     * 同一句柄重复登记＝换掉旧闭包（宿主被重新 prepare 时不叠加、事件也不会派发两次）；
     * 句柄比较走 C 侧 `cj_bridge_host_eq`（仓颉的 `CPointer` 不支持 `==`）。
     * 顺带解决「旧宿主销毁、新宿主复用同一地址」：新宿主登记时就覆盖了那条陈旧路由。
     */
    static func registerHostRoute(handle: CPointer<Unit>, onShell: (String) -> Unit,
                                  onDestroy: () -> Unit, onDialog: (String) -> Unit): Unit {
        for (r in HostGlobals.hostRoutes) {
            var same: Int32 = 0
            unsafe {
                same = cj_bridge_host_eq(r.handle, handle)
            }
            if (same != 0) {
                r.onShell = onShell
                r.onDestroy = onDestroy
                r.onDialog = onDialog
                return
            }
        }
        HostGlobals.hostRoutes.add(HostRoute(handle, onShell, onDestroy, onDialog))
    }

    /**
     * 按句柄取路由；查不到返回 None（句柄不属于本进程，或该宿主已注销）
     */
    static func hostRouteOf(handle: CPointer<Unit>): Option<HostRoute> {
        for (r in HostGlobals.hostRoutes) {
            var same: Int32 = 0
            unsafe {
                same = cj_bridge_host_eq(r.handle, handle)
            }
            if (same != 0) {
                return Some(r)
            }
        }
        return None
    }
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
 * 对话框结果回调（C 桥 → 仓颉）：文件类对话框选中的路径经它送回，首参是**发起这次对话框的宿主句柄**。
 *
 * 由 C 桥在自己的 UI 线程上调用，与 hostOnMessage 同一套路；按句柄写进对应宿主的结果位，
 * 再由桥唤醒阻塞的调用方去读。多窗口下两扇窗可以各自开着文件框，结果不许串台。
 * 非 @When：两平台的 C 侧都调它（签名一致，首参不透明）。
 */
@C
func dialogOnResult(host: CPointer<Unit>, path: CString): Unit {
    try {
        match (HostGlobals.hostRouteOf(host)) {
            case Some(r) => r.onDialog(path.toString())
            case None => eprintln("[cj-tauri] dialog callback: 未登记的宿主句柄（已丢弃）")
        }
    } catch (e: Exception) {
        eprintln("[cj-tauri] dialog callback error: ${e}")
    }
}

/**
 * 窗口销毁回调（C 桥 → 仓颉）：首参是**被销毁的宿主句柄**（每个宿主恰好触发一次）。
 *
 * 曾经写进全局单槽 → 多窗口下「哪扇窗关了」认错（后装配的窗口覆盖先装配的）；
 * 现在与 shell / 对话框一样按句柄认领。非 @When：两平台的 C 侧都调它。
 */
@C
func hostOnDestroy(host: CPointer<Unit>): Unit {
    try {
        match (HostGlobals.hostRouteOf(host)) {
            case Some(r) => r.onDestroy()
            case None => eprintln("[cj-tauri] destroy callback: 未登记的宿主句柄（已忽略）")
        }
    } catch (e: Exception) {
        eprintln("[cj-tauri] destroy callback error: ${e}")
    }
}

/**
 * shell 事件回调（C 桥 → 仓颉）：菜单点击等经它送回，首参是**发生事件的宿主句柄**。
 *
 * 由 C 桥在宿主 UI 线程上调用（与 hostOnMessage 同一套路）；句柄→实例的解引用走宿主级路由表，
 * 本函数只做「别抛穿 FFI 边界」这一件事。
 * 非 @When：两平台的 C 侧都调它（签名一致，首参不透明）。
 */
@C
func shellOnEvent(host: CPointer<Unit>, json: CString): Unit {
    try {
        // 认领自己那条：句柄对不上就静默跳过（C 侧只有一个入口，区分就在这里）
        match (HostGlobals.hostRouteOf(host)) {
            case Some(r) => r.onShell(json.toString())
            case None => () // 未登记（旧宿主已注销 / 非本进程句柄）：静默，别在热路径上刷屏
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

/**
 * 造一个「裸宿主句柄」：只分配 C 侧宿主对象（不 init / 不 start、不碰图形栈）
 *
 * 只给单元测试用（子包可见，不算对外 API）。为什么需要这层包皮：`cj_bridge_create` 是
 * `foreign func`——没有函数体、也就没有跨包符号，子包 `cjTauri.tests` 直接调会在**链接期**炸
 * （实测 `ld.lld: error: undefined symbol: cjTauri:cj_bridge_create`）；框架包内包一层就有实体符号了。
 */
func createBareHostHandle(): CPointer<Unit> {
    var h: CPointer<Unit> = CPointer<Unit>()
    unsafe {
        h = cj_bridge_create()
    }
    return h
}
