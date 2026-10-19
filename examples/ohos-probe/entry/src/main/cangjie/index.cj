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
 * 这个 `@Component` **必须住在应用模块里**，不能由框架包提供：2026-10-19 真机实测证明，
 * 框架包（独立编译单元、`output-type = "static"`）一旦 import `kit.ArkUI.*` / `kit.ArkWeb.*`，
 * 应用就会在启动瞬间死在包初始化（`cjTauri::package_global_init` 里 `bl _CGP9kit.ArkUIiiHv@plt`
 * 跳进未映射地址，hilog 只有一行 SIGSEGV，窗口起不来）。判据与完整对照实验见
 * `docs/鸿蒙ArkWeb接入踩坑.md`；框架侧只留了 `arkWebProxyPost` / `arkWebProxyPoll` 这两个
 * 不碰 ArkUI 的桥接函数。
 *
 * 这也正好符合 ArkUI 的模型：组件树属于应用的 UIAbility，框架不自己建窗。
 */
/**
 * proxy 的 `post` 入口：先交给框架处理报文，再把队列里的脚本推回页面
 *
 * 为什么「顺手推」放在这里：`javaScriptProxy` 的回调就在 UI 线程上，而
 * `controller.runJavaScript` 也必须在 UI 线程调。页面 → 原生的**返回值通道不可用**
 * （实测恒为 `null`，见 `docs/鸿蒙ArkWeb接入踩坑.md` 8.1.5.1），所以鸿蒙侧只能
 * 「页面发心跳 → 原生在该回调里把待执行脚本推出去」，这是唯一的回投路径。
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

/**
 * 取一条待呈现的原生弹窗（**UI 线程**；没有就返回 None）
 *
 * 弹窗的**呈现**必须在组件上下文里做（`getUIContext()` 只在组件内可调），所以这里只把请求
 * 取出来并打日志，真正的 `showAlertDialog` 留在 `build()` 的 proxy 回调里。
 */
func arkWebTakeDialog(label: String): Option<ArkWebDialogRequest> {
    match (ArkWebRuntime.hostFor(label)) {
        case Some(h) =>
            let request = h.takePendingDialog()
            match (request) {
                case Some(r) => Hilog.info(1, "CjTauriProbe", "dialog take label=${label} id=${r.id.toString()} kind=${r.kind}")
                case None => ()
            }
            return request
        case None => return None
    }
}

/**
 * 回填用户的选择（弹窗按钮 / 取消回调里调）
 *
 * 宿主可能已经没了（窗口销毁与命令超时）：那种情况下框架侧会丢弃这次答案，这里如实留日志，
 * 不要假装回填成功。
 */
func answerArkWebDialog(label: String, id: Int64, confirmed: Bool): Unit {
    Hilog.info(1, "CjTauriProbe", "dialog answer label=${label} id=${id.toString()} confirmed=${confirmed.toString()}")
    match (ArkWebRuntime.hostFor(label)) {
        case Some(h) => h.answerDialog(id, confirmed)
        case None => Hilog.info(1, "CjTauriProbe", "dialog answer without host")
    }
}

/**
 * `kind == confirm` 的双键弹窗（确定 / 取消）
 *
 * 取消、点遮罩、返回键都回填 false——与桌面 C 桥的语义一致（用户没确认就是没确认）。
 * 单键框（info / warning / error）相反：一律 true，那种框弹出即成立，没有「取消」这条路。
 */
func confirmArkWebDialog(request: ArkWebDialogRequest, label: String): AlertDialogParamWithButtons {
    return AlertDialogParamWithButtons(
        message: request.message,
        title: request.title,
        autoCancel: true,
        cancel: { => answerArkWebDialog(label, request.id, false) },
        primaryButton: AlertDialogButtonOptions(
            value: "取消",
            action: { => answerArkWebDialog(label, request.id, false) }
        ),
        secondaryButton: AlertDialogButtonOptions(
            value: "确定",
            action: { => answerArkWebDialog(label, request.id, true) }
        )
    )
}

/** 单键弹窗（info / warning / error）：只有一个「确定」 */
func infoArkWebDialog(request: ArkWebDialogRequest, label: String): AlertDialogParamWithConfirm {
    return AlertDialogParamWithConfirm(
        message: request.message,
        title: request.title,
        autoCancel: true,
        cancel: { => answerArkWebDialog(label, request.id, true) },
        confirm: AlertDialogButtonOptions(
            value: "确定",
            action: { => answerArkWebDialog(label, request.id, true) }
        )
    )
}

@Component
class CjTauriWebView {
    /* label 决定：①页面里 __CJ_TAURI_LABEL__ ②报文里的 window 字段 ③宿主取哪份页面来源。
       由父组件按窗口传入（`CjTauriWebView(windowLabel: "second")`）：多窗口下若用固定常量，
       两扇窗会认领同一份宿主、事件与回执全部串台——这正是本文件要取证的那条路由。
       必须是 `@Prop`（本机既有工程 NavBar/EmptyWidget 的写法）：普通成员被宏展开成
       `ObservedProperty` 形参，外面传一个字符串进来会报「expected 4 arguments」。 */
    @Prop
    var windowLabel: String

    /* 组件生命周期内必须保持同一个 controller 实例（ArkWeb 的硬约束） */
    private let controller: WebviewController = WebviewController()

    /* 页面地址由宿主给定；@State 让它参与刷新（宿主登记页面往往晚于组件首次 build）。
       `@State` 不允许与 private/public/static 同用——宏会直接拒绝。 */
    @State
    var pageUrl: String = ""

    public func build() {
        // build() 里只能写 UI 组件语法，proxy 方法表只能内联进调用参数
        Column {
            if (this.pageUrl.size > 0) {
                Web(src: this.pageUrl, controller: this.controller)
                    .width(100.percent)
                    .height(100.percent)
                    .fileAccess(true)
                    .javaScriptProxy(
                        funcList: [
                            { raw =>
                                let ack = onProxyPost(this.windowLabel, raw, this.controller)
                                /* 原生弹窗的呈现点：这里同时满足两个硬条件——UI 线程、
                                   且在组件上下文内（`getUIContext()` 只在组件里可用）。
                                   框架只负责排队（见 host_arkweb.cj 的 showMessageDialog），
                                   弹不弹、怎么弹由应用说了算。 */
                                match (arkWebTakeDialog(this.windowLabel)) {
                                    case Some(request) =>
                                        if (request.isConfirm()) {
                                            getUIContext().showAlertDialog(confirmArkWebDialog(request, this.windowLabel))
                                        } else {
                                            getUIContext().showAlertDialog(infoArkWebDialog(request, this.windowLabel))
                                        }
                                    case None => ()
                                }
                                ack
                            },
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
     * 页面开始加载：注入 label 与桥脚本，然后把宿主登记的地址同步过来
     *
     * ArkWeb 的仓颉绑定没有 `javaScriptOnDocumentStart`，`onPageBegin` 是能拿到的最早时机；
     * 内联 HTML 页面另走 `host_arkweb.cj` 的 head 拼接通道（真正早于页面脚本）。
     */
    /**
     * 组件挂载钩子（首次 `build()` 之前调用一次）
     *
     * **必须在这里同步宿主地址**：宿主把内联页面落盘后才把 `file://` 地址放进自己的字段
     * （应用侧组件读不到），而 `build()` 是声明式的一次性求值——`pageUrl` 仍为空就永远不建
     * `Web`，`onPageBegin` 也就永远不会来，页面白屏（实测 2026-10-19：窗口起来了、
     * `BindWebTagToWebInstance` 有、但 `page begin` 一次都不打）。
     */
    protected override func aboutToAppear(): Unit {
        match (ArkWebRuntime.hostFor(this.windowLabel)) {
            case Some(h) =>
                let u = h.currentUrl()
                if (u.size > 0) {
                    this.pageUrl = u
                }
                Hilog.info(1, "CjTauriProbe", "aboutToAppear label=${this.windowLabel} pageUrl=${u}")
            case None => Hilog.info(1, "CjTauriProbe", "aboutToAppear without host")
        }
    }

    private func onPageBegin(): Unit {
        Hilog.info(1, "CjTauriProbe", "page begin label=${this.windowLabel}")
        match (ArkWebRuntime.hostFor(this.windowLabel)) {
            case Some(h) =>
                h.notePageBegin()
                let url = h.currentUrl()
                if (url.size > 0 && url != this.pageUrl) {
                    this.pageUrl = url
                }
                for (js in h.initScriptsSnapshot()) {
                    this.runScript(js)
                }
                this.runScript(arkWebLabelScript(this.windowLabel))
            case None => eprintln("[cj-tauri] ArkWeb: page begin without host: label=\"${this.windowLabel}\"")
        }
    }

    private func onPageEnd(): Unit {
        Hilog.info(1, "CjTauriProbe", "page end label=${this.windowLabel}")
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
                    // 这里只判成败：`Hilog.info` 在带整型插值时会落到 4 参数重载，
                    // 写成固定串最稳（对象内容不必进日志，页面自己会显示）
                    match (err) {
                        case Some(e) => Hilog.info(1, "CjTauriProbe", "runJavaScript failed: ${e.message}")
                        case None => Hilog.info(1, "CjTauriProbe", "runJavaScript ok")
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
            // 上：默认窗口；下：附加窗口。两个实例各有自己的 controller 与宿主，
            // 上半屏与下半屏各自显示自己的 label——多窗口路由的「肉眼判据」。
            //
            // 高度由**外层容器**给：自定义组件的调用点不能挂链式修饰（`.height(...)`），
            // 那样宏展开时补不上 `__gen_parent`，报的是「missing arguments for parameter
            // list '(...Option<CustomView>...)'」——看着像参数写错，其实是调用形态不对
            // （本机 nutpishop 的 NavBar/EmptyWidget 调用点也都是纯调用）。
            Column() {
                CjTauriWebView(windowLabel: DEFAULT_WINDOW_LABEL)
            }.width(100.percent).height(50.percent)
            Column() {
                CjTauriWebView(windowLabel: SECOND_WINDOW_LABEL)
            }.width(100.percent).height(50.percent)
        }.width(100.percent).height(100.percent)
    }
}
