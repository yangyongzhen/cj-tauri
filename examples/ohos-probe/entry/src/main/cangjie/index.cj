package ohos_app_cangjie_entry

import kit.ArkUI.*
import kit.ArkWeb.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.component.web.Web
import ohos.arkui.state_macro_manage.*
/* `PromptAction` / `ShowDialogOptions` / `ButtonInfo` 只在 ui_context 包里，
   `kit.ArkUI` 没有重导出它（2026-10-20 核对 kit.ArkUI.cj.d 的 public import 清单确认）。 */
import ohos.arkui.ui_context.*
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
 * 取出来并打日志，真正的 `PromptAction.showDialog` 留在 `build()` 的 proxy 回调里。
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

/*
 * 历史落法为什么被撤掉（**别再改回命令式弹窗**）
 *
 * 最初的实现走 `UIContext.showAlertDialog`，2026-10-20 真机实测：不抛异常、立即返回、
 * 窗口不出现、也不给回填。换成 `PromptAction.showDialog`（带 `workerthread: true`
 * 与结果回调）后，「从页面按钮触发」那条路**依然**静默无效，而原生 `Button.onClick`
 * 调同一个 API 却能正常弹出（截图 + `native button dialog returned` 为证）。
 * 两者的 tid 完全相同（都是 UI 主线程 6549），把 `showDialog` 投到工作线程也不画——
 * 结论是「在这条 JS 桥接回调栈上启动命令式 overlay 会被 ArkUI 丢弃」。
 * 所以现在只保留声明式 overlay（`@State` + `build()` 里按状态渲染），
 * 单键框（info / warning / error）语义不变：弹出即成立，任何结束都回填 true；
 * 双键框取消 / 点遮罩 / 返回键一律回填 false。
 */

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

    /* 声明式弹窗的状态（`@State` 不能与 private 同用，宏会拒绝）。
       为什么不用 `PromptAction.showDialog`：那条命令式路径从 JS 桥接回调里调会被
       ArkUI 静默丢弃（取证见 `docs/鸿蒙ArkWeb接入踩坑.md` §10.11），而声明式 overlay
       只是组件树的一部分，重绘走正常渲染通道。 */
    @State
    var dialogActive: Bool = false

    @State
    var dialogTitle: String = ""

    @State
    var dialogMessage: String = ""

    @State
    var dialogIsConfirm: Bool = false

    @State
    var dialogRequestId: Int64 = 0

    public func build() {
        // build() 里只能写 UI 组件语法，proxy 方法表只能内联进调用参数
        Stack(alignContent: Alignment.BottomEnd) {
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
                                            /* 取证诊断：`dialog take` 之后到画面之间没有任何日志时，
                                               分不清是抛异常还是「调了但没画」——两侧各留一行。 */
                                            Hilog.info(1, "CjTauriProbe", "dialog show begin label=${this.windowLabel} id=${request.id.toString()} title=${request.title} msg=${request.message}")
                                            /* 真机取证（2026-10-20）定死了这条路的边界：**同一个** `showDialog`，
                                               从原生 `Button.onClick` 调能画出窗口，从这条 proxy 回调调则静默丢弃
                                               （无异常、无窗口、无回调）；两者 tid 完全相同（都是 UI 主线程 6549），
                                               再投到工作线程（`workerthread: true` 允许）也一样不画。
                                               所以被丢的不是「线程不对」，而是「在这条 JS 桥接回调栈上启动命令式
                                               overlay」这件事本身——我们不在那条栈上跟 ArkUI 争，改走声明式：
                                               这里只置状态，画面由 `build()` 按 `@State` 重绘（overlay 属于组件树，
                                               不经过命令式 overlay 创建）。 */
                                            Hilog.info(1, "CjTauriProbe", "dialog present label=${this.windowLabel} id=${request.id.toString()} title=${request.title} confirm=${request.isConfirm().toString()}")
                                            this.dialogRequestId = request.id
                                            this.dialogIsConfirm = request.isConfirm()
                                            this.dialogTitle = request.title
                                            this.dialogMessage = request.message
                                            this.dialogActive = true
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

            /* 对照按钮：`onClick` 一定跑在 UI 线程上。它若能弹出而 proxy 那条不能，
               问题就在「proxy 回调的线程/上下文」而不是「本机 ArkUI 弹窗不可用」——
               刚好把 showAlertDialog 静默无效的两种解释分开（见 docs/鸿蒙ArkWeb接入踩坑.md §10.10）。 */
            Button("原生对照弹窗")
                .width(140)
                .height(40)
                .onClick({ _ => this.probeNativeDialog() })

            /* 声明式弹窗：`dialogActive` 一变就重绘出一层覆盖整个窗口的卡片。
               它和 `Web` 同属一棵组件树，所以不需要任何命令式 overlay 调用——
               这正是它能绕开「桥接回调里 showDialog 被丢弃」的原因。 */
            if (this.dialogActive) {
                Column {
                    Column(space: 10) {
                        Text(this.dialogTitle).fontSize(20).fontColor(Color.Black)
                        Text(this.dialogMessage).fontSize(15).fontColor(Color.Black)
                        Row(space: 12) {
                            if (this.dialogIsConfirm) {
                                Button("取消")
                                    .fontSize(16)
                                    .onClick({ _ => this.finishDialog(false) })
                            }
                            Button("确定")
                                .fontSize(16)
                                .onClick({ _ => this.finishDialog(true) })
                        }
                    }
                    .width(76.percent)
                    .padding(18)
                    .backgroundColor(Color.White)
                    .borderRadius(14)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(Color.Black)
            }
        }.width(100.percent).height(100.percent)
    }

    /**
     * 声明式弹窗的按钮回调（跑在 UI 线程的普通 `onClick` 上，不走 JS 桥接栈）
     *
     * 先收起 overlay 再回填：回填会进框架的队列锁，用户连点时第二下不该还压在
     * 同一个 id 上（框架那侧对同一个 id 的第二次答案会按 `awaitingDialogs` 丢弃）。
     */
    private func finishDialog(confirmed: Bool): Unit {
        let id = this.dialogRequestId
        this.dialogActive = false
        Hilog.info(1, "CjTauriProbe", "declarative dialog answer id=${id.toString()} confirmed=${confirmed.toString()}")
        answerArkWebDialog(this.windowLabel, id, confirmed)
    }

    /**
     * 原生按钮的对照弹窗：固定内容、不经过框架的排队通道
     *
     * 有意不复用 `arkWebTakeDialog`：这里的目的是把「弹窗 API 本身能不能画」与
     * 「框架排队 / proxy 回调上下文」两件事分开取证，混用会让结论又糊回去。
     */
    private func probeNativeDialog(): Unit {
        Hilog.info(1, "CjTauriProbe", "native button clicked label=${this.windowLabel}")
        try {
            getUIContext().getPromptAction().showDialog(
                ShowDialogOptions(
                    title: "原生按钮对照",
                    message: "onClick 在 UI 线程上；这个框也不出现就说明本机弹窗 API 不可用",
                    buttons: [ButtonInfo(text: "知道了", color: Color.Blue, primary: true)]
                ),
                callback: { _, index =>
                    let idxText = match (index) {
                        case Some(i) => i.toString()
                        case None => "none"
                    }
                    Hilog.info(1, "CjTauriProbe", "native button dialog callback index=${idxText}")
                }
            )
            Hilog.info(1, "CjTauriProbe", "native button dialog returned")
        } catch (err: Exception) {
            Hilog.info(1, "CjTauriProbe", "native button dialog threw err=${err}")
        }
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
