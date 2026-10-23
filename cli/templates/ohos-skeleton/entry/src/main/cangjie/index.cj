package ohos_app_cangjie_entry

import kit.ArkUI.*
import kit.ArkWeb.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.component.web.Web
import ohos.arkui.state_macro_manage.*
import cjTauri.*

/*
 * 应用侧的 ArkWeb 宿主组件
 *
 * 这个 `@Component` **必须住在应用模块里**，不能由框架包提供：框架包一旦 import
 * `kit.ArkUI.*` / `kit.ArkWeb.*`，合并进应用动态库后包初始化链会跳到坏地址、启动即 SIGSEGV。
 * 框架侧只留 `arkWebProxyPost` / `arkWebProxyPoll` 两个不碰 ArkUI 的桥接函数。
 *
 * 单窗口版：label 用框架默认的 DEFAULT_WINDOW_LABEL。要做多窗口就照着加一份、
 * 换成别的 label（框架的宿主路由是按 label 查的，不会串台）。
 */

/**
 * proxy 的 `post` 入口：先交给框架处理报文，再把队列里的脚本推回页面
 *
 * 为什么「顺手推」放在这里：`javaScriptProxy` 的回调就在 UI 线程上，而
 * `controller.runJavaScript` 也必须在 UI 线程调。页面 → 原生的**返回值通道不可用**
 * （实测恒为 `null`），所以鸿蒙侧只能「页面发心跳 → 原生在该回调里把待执行脚本推出去」，
 * 这是唯一的回投路径；框架会把它收到的 invoke 结果 / event 都排进这个队列。
 */
func onProxyPost(label: String, raw: String, ctrl: WebviewController): String {
    let ack = arkWebProxyPost(label, raw)
    match (ArkWebRuntime.hostFor(label)) {
        case Some(h) =>
            let pending = h.takePendingScripts()
            var i = 0
            while (i < pending.size) {
                ctrl.runJavaScript(pending[i], { _, _ => () })
                i += 1
            }
        case None => ()
    }
    return ack
}

@Component
class CjTauriWebView {
    /* label 决定：①页面里 __CJ_TAURI_LABEL__ ②报文里的 window 字段 ③宿主取哪份页面来源。
       必须是 `@Prop`：普通成员会被宏展开成 ObservedProperty 形参，外面传字符串进来会报
       「expected 4 arguments」。 */
    @Prop
    var windowLabel: String

    /* 组件生命周期内必须保持同一个 controller 实例（ArkWeb 的硬约束） */
    private let controller: WebviewController = WebviewController()

    /* 页面地址由宿主给定；@State 让它参与刷新（宿主登记页面往往晚于组件首次 build）。
       `@State` 不允许与 private/public/static 同用——宏会直接拒绝。 */
    @State
    var pageUrl: String = ""

    public func build() {
        Column {
            if (this.pageUrl.size > 0) {
                Web(src: this.pageUrl, controller: this.controller)
                    .width(100.percent)
                    .height(100.percent)
                    .fileAccess(true)
                    .javaScriptProxy(
                        funcList: [
                            { raw => onProxyPost(this.windowLabel, raw, this.controller) },
                            /* `poll` 只为兼容页面上可能残留的旧桥脚本：返回值传不回 JS，
                               真正的脚本推送已在 `onProxyPost` 里完成。 */
                            { _ => "" }
                        ],
                        name: ARKWEB_PROXY_NAME, methodList: ["post", "poll"],
                        controller: this.controller
                    )
                    .onPageBegin({ _ => this.onPageBegin() })
                    .onPageEnd({ _ => this.onPageEnd() })
            }
        }.width(100.percent).height(100.percent)
    }

    /**
     * 组件挂载钩子（首次 `build()` 之前调用一次）
     *
     * **必须在这里同步宿主地址**：宿主把页面落盘后才把 `file://` 地址放进自己的字段，
     * 而 `build()` 是声明式的一次性求值——`pageUrl` 仍为空就永远不建 `Web`，
     * `onPageBegin` 也就永远不会来，页面白屏。
     */
    protected override func aboutToAppear(): Unit {
        match (ArkWebRuntime.hostFor(this.windowLabel)) {
            case Some(h) =>
                let u = h.currentUrl()
                if (u.size > 0) {
                    this.pageUrl = u
                }
                Hilog.info(1, "CjTauri", "aboutToAppear label=${this.windowLabel} pageUrl=${u}")
            case None => Hilog.info(1, "CjTauri", "aboutToAppear without host")
        }
    }

    private func onPageBegin(): Unit {
        Hilog.info(1, "CjTauri", "page begin label=${this.windowLabel}")
        match (ArkWebRuntime.hostFor(this.windowLabel)) {
            case Some(h) =>
                h.notePageBegin()
                let url = h.currentUrl()
                if (url.size > 0 && url != this.pageUrl) {
                    this.pageUrl = url
                }
                // 桥脚本与插件 shim 都在 initScripts 里：ArkWeb 没有 document-start 注入，
                // `onPageBegin` 是能拿到的最早时机。
                for (js in h.initScriptsSnapshot()) {
                    this.runScript(js)
                }
                this.runScript(arkWebLabelScript(this.windowLabel))
            case None => Hilog.info(1, "CjTauri", "page begin without host: label=${this.windowLabel}")
        }
    }

    private func onPageEnd(): Unit {
        Hilog.info(1, "CjTauri", "page end label=${this.windowLabel}")
        match (ArkWebRuntime.hostFor(this.windowLabel)) {
            case Some(h) =>
                h.notePageEnd()
                // 组件首次 build 时宿主可能还没登记（页面为空），这里再同步一次并触发刷新
                let url = h.currentUrl()
                if (url.size > 0 && url != this.pageUrl) {
                    this.pageUrl = url
                }
            case None => ()
        }
    }

    /** 单条脚本执行（ArkWeb 的 runJavaScript 是异步的，回调里只做失败日志） */
    private func runScript(js: String): Unit {
        if (js.size == 0) {
            return
        }
        // runJavaScript(script, callback) 两个都是位置参数（命名参数前缀会被编译器拒）
        this.controller.runJavaScript(
            js,
            {
                err, result =>
                    match (err) {
                        case Some(e) => Hilog.info(1, "CjTauri", "runJavaScript failed: ${e.message}")
                        case None => Hilog.info(1, "CjTauri", "runJavaScript ok")
                    }
                    let _ = result
            }
        )
    }
}

@Entry
@Component
class EntryView {
    func build() {
        Column {
            // 高度由**外层容器**给：自定义组件的调用点不能挂链式修饰（`.height(...)`），
            // 那样宏展开时补不上 `__gen_parent`，报的是「missing arguments for parameter list」。
            Column() {
                CjTauriWebView(windowLabel: DEFAULT_WINDOW_LABEL)
            }.width(100.percent).height(100.percent)
        }.width(100.percent).height(100.percent)
    }
}
