package ohos_app_cangjie_entry

import kit.ArkUI.*
import kit.ArkWeb.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.component.web.Web
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList
import cjTauri.*

/*
 * 菜单条外观常量（0xAARRGGBB，Int64 就是 ResourceColor）。
 *
 * 对齐的是桌面应用的菜单栏：一行文字、悬停时浅灰底浮起、**没有**按钮那种描边与实心块。
 * 早先用 `Button` 时观感与 Windows 差得远——那是一排按钮，不是菜单栏（用户实测反馈）。
 *
 * 必须写在**使用点之前**：仓颉的全局 `let` 按出现顺序解析，写在文件尾部时 `@Component`
 * 宏展开出来的 build() 会报 `variable 'MENU_BAR_BG' is used before being defined`。
 */
let MENU_BAR_BG: Int64 = 0xFFF9F9F9

let MENU_BAR_HOVER: Int64 = 0xFFE8E8E8

let MENU_BAR_TEXT: Int64 = 0xFF1A1A1A

let MENU_BAR_TEXT_DISABLED: Int64 = 0xFF9AA0A6

/*
 * 鸿蒙键盘码：**仓颉 SDK 不导出键码常量**（`KeyEvent.keyCode` 只是裸 `Int32`），
 * 下面三个值是 `uinput -K` 注键 + hilog 探针在真机上量出来的，不是猜的：
 * 字母区 `KEYCODE_A = 2017` 起连续排到 `KEYCODE_Z = 2042`，左右 Ctrl 各 2072 / 2073。
 * 要支持别的组合键（如功能键 F1..F12）照同一办法量一遍再补，别照 Android 的 29 起算抄。
 */
let KEY_LETTER_A: Int64 = 2017

let KEY_CTRL_LEFT: Int64 = 2072

let KEY_CTRL_RIGHT: Int64 = 2073

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

/**
 * 取一条待呈现的原生弹窗（**UI 线程**；没有就返回 None）
 *
 * 弹窗的**呈现**必须在组件上下文里做（`getUIContext()` 只在组件内可调），所以这里只把请求
 * 取出来，真正的画面交给 `build()` 里的声明式 overlay——命令式 `showDialog` 从 JS 桥接
 * 回调栈上启动会被 ArkUI 静默丢弃（取证见 docs/鸿蒙ArkWeb接入踩坑.md §10.11）。
 */
func arkWebTakeDialog(label: String): Option<ArkWebDialogRequest> {
    match (ArkWebRuntime.hostFor(label)) {
        case Some(h) =>
            let request = h.takePendingDialog()
            match (request) {
                case Some(r) => Hilog.info(1, "CjTauri", "dialog take label=${label} id=${r.id.toString()} kind=${r.kind}")
                case None => ()
            }
            return request
        case None => return None
    }
}

/** 回填用户的选择（overlay 按钮回调里调；宿主可能已销毁——如实留日志，不假装成功） */
func answerArkWebDialog(label: String, id: Int64, confirmed: Bool): Unit {
    Hilog.info(1, "CjTauri", "dialog answer label=${label} id=${id.toString()} confirmed=${confirmed.toString()}")
    match (ArkWebRuntime.hostFor(label)) {
        case Some(h) => h.answerDialog(id, confirmed)
        case None => Hilog.info(1, "CjTauri", "dialog answer without host")
    }
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

    /*
     * 菜单快照：框架存模型（`ArkWebHost.setMenu` 解析线路格式）、**应用侧**画（`bindMenu`）——
     * 这是「框架包不引用 ArkUI」前提下的唯一分工（见框架 src/arkweb_menu.cj 的类注释）。
     *
     * 刷新节拍借用页面的心跳：`setMenuItemState` 的改动没有别的通知通道（框架碰不到 ArkUI），
     * 而页面每 500ms 发一次 pull 心跳正好会进 proxy 回调，顺手重取一次快照即可。
     * 应用不调 `setMenu` 时这份快照为空，菜单条不占位、界面与以前完全一样。
     */
    @State
    var menuSnapshot: ArrayList<ArkWebMenuItem> = ArrayList<ArkWebMenuItem>()

    /* 声明式弹窗的状态（@State 不能与 private 同用，宏会拒绝；理由同探针工程 §10.11） */
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

    /* 菜单条当前悬停的那一格（按下标，-1 = 都没有）。只为「悬停浅灰底」这一个视觉状态服务，
       与菜单模型无关——模型刷新时下标可能指向别的项，下一次 onHover 就会纠正。 */
    @State
    var menuHoverIndex: Int64 = -1

    /* Ctrl 的按下态：仓颉 `KeyEvent` 没有修饰键查询接口，只能自己按 keyCode 记账
       （Down 置位、Up 清位）。@State 只为复用同一套字段声明习惯，取值不进布局。 */
    @State
    var ctrlDown: Bool = false

    public func build() {
        /*
         * Stack 包住「页面 + 对话框 overlay」：overlay 与 Web 同属一棵组件树、走声明式重绘，
         * 绕开「桥接回调里 showDialog 被丢弃」的坑（docs/鸿蒙ArkWeb接入踩坑.md §10.11）。
         */
        Stack(alignContent: Alignment.Center) {
        Column {
            /*
             * 菜单条：**有菜单才占位**（没调 setMenu 的应用看不到它）。
             *
             * 分组渲染：顶层每个子菜单（文件 / 视图 / 帮助）各占一格，点开弹该组的扁平项——
             * 仓颉侧 `MenuElement` 没有嵌套，组内仍是一层，但顶层按组分开，
             * 不再是一根「文件 / 打开…」摊平的大列表。分隔线与禁用项不画。
             *
             * 用 `Text` 而不是 `Button`：后者自带描边/实心块/按压缩放，一排排开就是「一排按钮」，
             * 与 Windows 的菜单栏（纯文字 + 悬停浅灰底）差异明显。悬停态由 `menuHoverIndex` 记，
             * `onHover` 只改这个状态、不碰别的，重绘范围就是那一格的底色。
             */
            if (this.menuSnapshot.size > 0) {
                Row {
                    /* lambda 形参**必须标类型**：不标时 @Component 宏展开后给 ForEach 补不出 T，
                       报的是 `expected type argument`（指向宏展开出来的 `ForEach<>`），
                       而 `ForEach<T>(…)` 这种写法又会被宏读成「组件 + 尾随块」而报
                       `expected expression after '<'`——两条都试过，只有标类型这条路能过。 */
                    ForEach(this.menuSnapshot, itemGenerator: { item: ArkWebMenuItem, index: Int64 =>
                        if (item.isSubmenu() && item.enabled) {
                            Text(menuItemText(item))
                                .fontSize(14)
                                .fontColor(menuBarTextColor(item))
                                .height(30)
                                .padding(top: 0, right: 12, bottom: 0, left: 12)
                                .borderRadius(6)
                                .backgroundColor(menuBarCellBg(this.menuHoverIndex == index))
                                .onHover({ hover => this.menuHoverIndex = if (hover) { index } else { -1 } })
                                .bindMenu(this.groupElements(item))
                        } else if (item.enabled && !item.isSeparator()) {
                            Text(menuItemText(item))
                                .fontSize(14)
                                .fontColor(menuBarTextColor(item))
                                .height(30)
                                .padding(top: 0, right: 12, bottom: 0, left: 12)
                                .borderRadius(6)
                                .backgroundColor(menuBarCellBg(this.menuHoverIndex == index))
                                .onHover({ hover => this.menuHoverIndex = if (hover) { index } else { -1 } })
                                .onClick({ _ => this.fireMenu(item.id) })
                        }
                    }, keyGenerator: { item: ArkWebMenuItem, index: Int64 => keyOf(item, index) })
                }
                .width(100.percent)
                .height(40)
                .padding(top: 0, right: 6, bottom: 0, left: 6)
                .backgroundColor(MENU_BAR_BG)
                .alignItems(VerticalAlign.Center)
            }
            if (this.pageUrl.size > 0) {
                Web(src: this.pageUrl, controller: this.controller)
                    .width(100.percent)
                    .height(100.percent)
                    .fileAccess(true)
                    .onKeyEvent({ e => this.handleMenuKey(e) })
                    .javaScriptProxy(
                        funcList: [
                            {
                                raw =>
                                    let ack = onProxyPost(this.windowLabel, raw, this.controller)
                                    /* 心跳节拍：页面每 500ms 一次 pull，顺手把宿主里的菜单模型
                                       重取一次（setMenuItemState 的改动没有别的通知通道），
                                       并取一次待呈现的对话框——呈现点必须同时满足 UI 线程
                                       与组件上下文，proxy 回调两者都占。 */
                                    this.reloadMenu()
                                    this.presentPendingDialog()
                                    return ack
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

        /* 声明式对话框 overlay：dialogActive 一变就重绘出覆盖层。
           它与 Web 同属一棵组件树——这正是它能绕开「桥接回调里命令式 showDialog
           被丢弃」的原因（docs/鸿蒙ArkWeb接入踩坑.md §10.11）。 */
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

    /** 从宿主取一条待呈现对话框并点亮 overlay（proxy 回调里调：UI 线程 + 组件上下文） */
    private func presentPendingDialog(): Unit {
        match (arkWebTakeDialog(this.windowLabel)) {
            case Some(request) =>
                Hilog.info(1, "CjTauri", "dialog present label=${this.windowLabel} id=${request.id.toString()} title=${request.title}")
                this.dialogRequestId = request.id
                this.dialogIsConfirm = request.isConfirm()
                this.dialogTitle = request.title
                this.dialogMessage = request.message
                this.dialogActive = true
            case None => ()
        }
    }

    /**
     * overlay 按钮回调（普通 onClick，不走 JS 桥接栈）。
     * 先收起再回填：回填进框架的队列锁，连点时第二下不该压在同一个 id 上。
     */
    private func finishDialog(confirmed: Bool): Unit {
        let id = this.dialogRequestId
        this.dialogActive = false
        answerArkWebDialog(this.windowLabel, id, confirmed)
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

    /*
     * 从宿主取一份菜单快照。没有宿主时保持空表——UI 照常建树，别等菜单才画 Web
     * （那条链会死成「不建 Web → onPageBegin 不来 → 地址永远空」的白屏，见 AGENTS §4）。
     */
    private func reloadMenu(): Unit {
        match (ArkWebRuntime.hostFor(this.windowLabel)) {
            case Some(h) => this.menuSnapshot = h.menuModel()
            case None => ()
        }
    }

    /*
     * 一个子菜单组 → `bindMenu` 的扁平项表。
     *
     * 仓颉侧 `MenuElement` 只有 `value` + `action`：**组内没有嵌套、没有禁用位**。分隔线
     * 不画（画出来点了没反应会被误读成「宿主没落地」）；勾选项用「✓ 」前缀表达——
     * 点击经 fireMenu 交回宿主，框架回写模型，下一次心跳重取快照时勾选态跟上。
     */
    private func groupElements(group: ArkWebMenuItem): Array<MenuElement> {
        let out = ArrayList<MenuElement>()
        for (child in group.children) {
            if (!child.enabled || child.isSeparator()) {
                continue
            }
            let target = child.id
            out.add(MenuElement(value: menuItemText(child), action: { => this.fireMenu(target) }))
        }
        return out.toArray()
    }

    /* 一项被点了：交回宿主（宿主回投 shell 报文，与桌面同形），顺带刷新勾选态 */
    private func fireMenu(id: String): Unit {
        // 留一行 hilog 再往下走：设备上框架 stderr 不进 hilog（AGENTS §4），
        // 应用侧这行是「原生真的收到点击」的唯一凭证。
        Hilog.info(1, "CjTauri", "menu click label=${this.windowLabel} id=${id}")
        match (ArkWebRuntime.hostFor(this.windowLabel)) {
            case Some(h) =>
                h.noteMenuClick(id)
                this.reloadMenu()
            case None => Hilog.info(1, "CjTauri", "menu click without host: label=${this.windowLabel}")
        }
    }

    /*
     * 菜单快捷键的按键入口（鸿蒙专属）。
     *
     * 桌面两平台由宿主把 `MenuItem.accel` 绑成真热键（Windows `RegisterHotKey` / Linux X11 grab），
     * 鸿蒙宿主没有这一层（`hostCapabilities()` 的快捷键位是 0），所以应用侧按 accel 自己认键、
     * 再走 `fireMenu` 回投 `menu:click` ——页面侧收到的仍是一条普通菜单事件，不需要为鸿蒙另写分支。
     *
     * Ctrl 的按下态自己记：仓颉 `KeyEvent` 只暴露 `keyType` / `keyCode` / `keyText`，
     * 没有修饰键查询接口（`getModifierKeyState` 不在导出里），所以按下/抬起各记一次。
     *
     * 匹配方向刻意选「拿 accel 反算键码」：事件里只有裸 `keyCode`，若反过来把键码翻成字符
     * 就得自己维护整张字母表；现在只需认识 `Ctrl+<字母>` 这一种形状。
     */
    private func accelKeyCode(accel: String): Int64 {
        /* 只认 `Ctrl+<单个大写字母>`（6 字节）。其它形状（`Shift+F5` / `Alt+…`）暂不认，
           如实不响应，而不是瞎猜键码——量过的只有字母区与 Ctrl。 */
        if (accel.size != 6 || !accel.startsWith("Ctrl+")) {
            return -1
        }
        var offset: Int64 = -1
        for (b in accel[5..6]) {
            let c = Int64(b)
            if (c >= 65 && c <= 90) {
                offset = c - 65
            }
        }
        if (offset < 0) {
            return -1
        }
        return KEY_LETTER_A + offset
    }

    /* 在菜单快照里按键码反查条目 id（子菜单递归到底）；禁用项不响应，与桌面宿主一致。 */
    private func accelIdIn(items: ArrayList<ArkWebMenuItem>, code: Int64): String {
        for (item in items) {
            if (item.enabled && accelKeyCode(item.accel) == code) {
                return item.id
            }
            let nested = this.accelIdIn(item.children, code)
            if (nested.size > 0) {
                return nested
            }
        }
        return ""
    }

    private func handleMenuKey(e: KeyEvent): Unit {
        let isDown = match (e.keyType) {
            case KeyType.Down => true
            case _ => false
        }
        let code = Int64(e.keyCode)
        /* Ctrl 的按下态只能自己记账：`KeyEvent` 没有修饰键查询接口
           （真机核对过——`keyText` 也只是 `KEYCODE_O` 这样的裸名字）。 */
        if (code == KEY_CTRL_LEFT || code == KEY_CTRL_RIGHT) {
            this.ctrlDown = isDown
            return
        }
        /* **在抬起时判定**：焦点在 Web 内容里时，字母的 key-down 被 ArkWeb/CEF 吃掉当文本输入，
           只有 key-up 会冒泡到 ArkUI（真机日志可证：同一串 Ctrl+S 只见到 ctrl 的 down/up 与
           S 的 up）。若按按下判定，所有组合键都会静默失效。 */
        if (isDown || !this.ctrlDown) {
            return
        }
        let id = this.accelIdIn(this.menuSnapshot, code)
        if (id.size > 0) {
            this.fireMenu(id)
        } else {
            /* 留一行：否则「按了没反应」分不清是键没到、还是 accel 没对上。 */
            Hilog.info(1, "CjTauri", "menu accel miss code=${code}")
        }
    }
}

/*
 * ForEach 的键：**必须唯一**，所以拼上序号。
 *
 * 顶层子菜单的 `id` 恒为空串（`MenuItem.submenu` 的规定：子菜单自身不回调，动作交给 children），
 * 直接拿 `item.id` 当键会让「文件 / 视图 / 帮助」三个键全撞成 ""，ArkUI 按重复键去重——
 * 表现是**菜单条上只剩第一组**（2026-10-24 真机实测：日志里三组都在，屏上只画出「文件」）。
 */
func keyOf(item: ArkWebMenuItem, index: Int64): String {
    return "${index.toString()}-${item.kind}-${item.id}"
}

/* 菜单项的显示文本：勾选项带「✓」前缀（MenuElement 没有勾选位，只能写进标签） */
func menuItemText(item: ArkWebMenuItem): String {
    if (item.isCheckbox() && item.checked) {
        return "✓ ${item.label}"
    }
    return item.label
}

/*
 * 菜单条外观常量在上面（文件头 import 之后）——全局 `let` 必须先定义后使用。
 */

/* 文字色随启用态变（禁用项按桌面惯例置灰，但不画、也不响应点击的是分隔线） */
func menuBarTextColor(item: ArkWebMenuItem): Int64 {
    if (item.enabled) {
        return MENU_BAR_TEXT
    }
    return MENU_BAR_TEXT_DISABLED
}

/* 悬停格的底色：仓颉**没有** `cond ? a : b` 三元运算符（`?` 只用在可选类型上），
   拿它写会报 `expected '?' after '?'` 一串看不懂的语法错——一律用 if 表达式。 */
func menuBarCellBg(hovered: Bool): Int64 {
    if (hovered) {
        return MENU_BAR_HOVER
    }
    return MENU_BAR_BG
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
