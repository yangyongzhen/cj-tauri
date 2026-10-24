package ohos_app_cangjie_entry

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import std.collection.HashMap
import cjTauri.*

/*
 * 「每个窗口已回填的请求 id」——组件与父组件共享的一格状态（同包、UI 线程内）。
 *
 * 为什么需要它：父组件要判断「当前这条还在展示、不能再取下一条」，而展示中这件事
 * 只有组件自己知道（`answered` 是它的私有 @State）。把答案放在这里，两边读同一份，
 * 就不用把闭包当构造参数传给 @Component（那条路宏支持有限，且多窗口下容易串台）。
 *
 * 没登记过的窗口回 -1：与 `dialogRequestId` 的初值相等，所以**首次**允许取请求。
 */
let dialogAnswered: HashMap<String, Int64> = HashMap<String, Int64>()

/** 取某窗口「已回填的请求 id」，没记录过返回 -1（= 还没有任何一条被答过） */
func dialogAnsweredIdOf(label: String): Int64 {
    match (dialogAnswered.get(label)) {
        case Some(v) => return v
        case None => return -1
    }
}

/** 记下某窗口已回填的 id（回填发生在 UI 线程，与读取同线程，不需要锁） */
func markDialogAnswered(label: String, id: Int64): Unit {
    dialogAnswered[label] = id
}

/*
 * 对话框 overlay 的外观常量（0xAARRGGBB，Int64 就是 ResourceColor）。
 *
 * **遮罩必须带 alpha**：早先这里是 `Color.Black`（= 0xFF000000，完全不透明），
 * 弹出时整页被一块黑板盖住——用户真机实测的原话是「背景全黑了」。
 * 现在 0x66 ≈ 40% 不透明，页面内容透得出来，才像对话框盖在页面上。
 *
 * 这几个常量就是业务侧的定制位：改配色改这里，改布局改下面 `CjDialogHost.build()`。
 * 想彻底换成自己的样式（比如页内 HTML 弹窗）就不要调 `dialog:message`——
 * overlay 只是「零配置可用」的默认实现，不是唯一通路。
 */
let DIALOG_SCRIM: Int64 = 0x66000000

let DIALOG_CARD_BG: Int64 = 0xFFFFFFFF

let DIALOG_TITLE_TEXT: Int64 = 0xFF1A1A1A

let DIALOG_BODY_TEXT: Int64 = 0xFF44474F

/* 取消键的浅灰底：中性动作不抢主色，桌面惯例里主色只给「确定」 */
let DIALOG_BTN_NEUTRAL: Int64 = 0xFFF1F3F5

/* 确定键底色按 kind 区分：info 蓝 / warning 橙 / error 红；单键与双键共用这一支 */
let DIALOG_ACCENT_INFO: Int64 = 0xFF0A59F7

let DIALOG_ACCENT_WARNING: Int64 = 0xFFED6F21

let DIALOG_ACCENT_ERROR: Int64 = 0xFFE84026

/*
 * kind → 强调色（`normalizeDialogKind` 是框架共享层的归一，认不出的 kind 已回落成 info）
 *
 * 只影响「确定键底色」这一个可视点：警告与错误在桌面惯例里都用颜色区分，
 * 而单键/双键的**语义**判定在框架侧（`dialogShapeOf`），这里不重复判一次。
 */
func dialogAccentColor(kind: String): Int64 {
    match (normalizeDialogKind(kind)) {
        case "warning" => return DIALOG_ACCENT_WARNING
        case "error" => return DIALOG_ACCENT_ERROR
        case _ => return DIALOG_ACCENT_INFO
    }
}

/*
 * 宿主对话框的默认呈现（声明式 overlay）。
 *
 * ## 为什么必须是声明式
 *
 * 页面经 `dialog:message` 要求弹框时，命令是从 `javaScriptProxy` 的 `post` 回调同步栈上回来的；
 * 在那条栈上调 `showAlertDialog` / `getPromptAction().showDialog`（含 `workerthread: true`）
 * 会被 ArkUI **静默丢弃**——不抛异常、窗口不画、回调不来（取证见 docs/鸿蒙ArkWeb接入踩坑.md §10.11）。
 * 所以唯一的落法是：回调里只置状态，`build()` 里按状态把 overlay 画成组件树的最后一个孩子。
 *
 * ## 为什么做成组件
 *
 * 内联在 `CjTauriWebView` 里时，业务想换个样子只能改模板——而 `targets/` 是 `cj-tauri sync`
 * 的派生物，改了下次 sync 就没了。抽成组件后业务只需在根 `Stack` 里放一个实例：
 *
 * ```
 * if (this.dialogActive) {
 *     CjDialogHost(windowLabel: this.windowLabel, requestId: this.dialogRequestId,
 *                  title: this.dialogTitle, message: this.dialogMessage,
 *                  twoKey: this.dialogIsConfirm, kind: this.dialogKind)
 * }
 * ```
 *
 * 调用点必须保持**纯调用**：挂链式修饰（`.width(...)` 之类）会让 `@Component` 宏展开时
 * 补不上 `__gen_parent`，报的是「expected N arguments」（见 AGENTS §4）。
 *
 * ## 点完为什么自己会消失
 *
 * 按钮回填走模块级 `answerArkWebDialog`（框架队列），而父组件的 `dialogActive` 不会因为
 * 一次点击而变——所以收起由组件自己记：`answered` 记住已回填的请求 id，`requestId`
 * 与它不等时才画。下一轮请求进来父组件赋一个新的 `requestId`，卡片自然重新出现。
 * 这条不依赖父组件回调，也就不需要把闭包当构造参数传进来。
 *
 * ## 收起后必须 visibility(None)，不能只把子内容裁掉
 *
 * 组件要挂在外层 `Stack` 里就得始终返回一个根节点，所以外层 `Column` 收起来之后**仍然在**——
 * 它是 100%×100% 的透明容器，在 ArkUI 里照样参与命中测试、照样吃掉落在页面上的点击。
 * 真机第二轮反馈的原话是「点完对话框后，点其他没反应了」：卡片确实没了，整页却点不动，
 * 凶手就是这层看不见的壳。
 *
 * `Visibility.Hidden` 不够——它只是不画，**布局占位与命中区都还在**；只有
 * `Visibility.None` 才既不占位也不响应事件。所以这里两分：该画时 Visible，收起时 None。
 * （同类风险：任何「常驻但条件内空的 overlay 容器」都要这么写，别只依赖背景透明。）
 */
@Component
class CjDialogHost {
    /* label 决定回填给哪个窗口的宿主（多窗口下不能串台） */
    @Prop
    var windowLabel: String

    /* 请求 id：父组件每来一条新请求就换一个值，组件据此判断该不该重新显示 */
    @Prop
    var requestId: Int64

    @Prop
    var title: String

    @Prop
    var message: String

    /* true = 双键（取消 + 确定），false = 单键（只有确定）；判定在框架侧，这里只消费 */
    @Prop
    var twoKey: Bool

    /* info / warning / error，只用于确定键配色 */
    @Prop
    var kind: String

    /* 已回填过的请求 id（-1 = 还没有）。@State 不允许与 private 同用，宏会拒绝。 */
    @State
    var answered: Int64 = -1

    func build() {
        /* 外层这一层 **不设背景**：遮罩只在「确实该画」的那一支里，否则收起的瞬间
           整页会被一层灰蒙住不散（内联版第一版就有这个毛病）。 */
        Column {
            if (this.requestId != this.answered) {
                Column {
                    Column(space: 14) {
                        Text(this.title)
                            .fontSize(19)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(DIALOG_TITLE_TEXT)
                            .width(100.percent)
                        Text(this.message)
                            .fontSize(15)
                            .fontColor(DIALOG_BODY_TEXT)
                            .width(100.percent)
                        Row(space: 12) {
                            if (this.twoKey) {
                                Button("取消")
                                    .fontSize(15)
                                    .fontColor(DIALOG_BODY_TEXT)
                                    .backgroundColor(DIALOG_BTN_NEUTRAL)
                                    .onClick({ _ => this.answer(false) })
                            }
                            Button("确定")
                                .fontSize(15)
                                .fontColor(Color.White)
                                .backgroundColor(dialogAccentColor(this.kind))
                                .onClick({ _ => this.answer(true) })
                        }
                        .width(100.percent)
                        .justifyContent(FlexAlign.End)
                    }
                    .width(86.percent)
                    .constraintSize(maxWidth: 420)
                    .padding(20)
                    .backgroundColor(DIALOG_CARD_BG)
                    .borderRadius(16)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(DIALOG_SCRIM)
            }
        }
        .width(100.percent)
        .height(100.percent)
        /* 收起后整块退出命中测试（详见类头注释）：只裁子内容会留下 100% 的透明层，
           真机上表现为「点完对话框后整页点不动」。 */
        .visibility(if (this.requestId != this.answered) {
            Visibility.Visible
        } else {
            Visibility.None
        })
    }

    /**
     * 回填用户的选择并收起自己。
     *
     * 先记 `answered` 再回填：回填会进框架的队列锁，连点时第二下不该再压在同一个 id 上
     * （那次回填会被宿主的 `awaitingDialogs` 校验拒掉，日志里看得见）。
     */
    private func answer(confirmed: Bool): Unit {
        let id = this.requestId
        this.answered = id
        /* 同时登记到共享状态：父组件靠它判断「上一条已答完、可以取下一条」，
           否则 overlay 收起后父组件永远以为还在展示，第二次点菜单就不弹了。 */
        markDialogAnswered(this.windowLabel, id)
        answerArkWebDialog(this.windowLabel, id, confirmed)
    }
}
