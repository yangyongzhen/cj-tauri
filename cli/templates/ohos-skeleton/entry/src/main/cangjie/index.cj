package ohos_app_cangjie_entry

import kit.ArkUI.*
import kit.ArkWeb.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.component.web.Web
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList
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

    public func build() {
        Column {
            /*
             * 菜单条：**有菜单才占位**（没调 setMenu 的应用看不到它）。
             *
             * `bindMenu` 出的是扁平菜单——仓颉侧 `MenuElement` 只有 `value` + `action`，
             * 没有嵌套子菜单、也没有禁用位。层级改用「父 / 子」标签表达，分隔线与禁用项不画
             * （画出来点了没反应，比不画更容易被误读成「宿主没落地」）。
             */
            if (this.menuSnapshot.size > 0) {
                Row {
                    Button("菜单")
                        .fontSize(14)
                        .height(32)
                        .margin(left: 8)
                        .bindMenu(this.menuElements())
                }
                .width(100.percent)
                .height(44)
            }
            if (this.pageUrl.size > 0) {
                Web(src: this.pageUrl, controller: this.controller)
                    .width(100.percent)
                    .height(100.percent)
                    .fileAccess(true)
                    .javaScriptProxy(
                        funcList: [
                            {
                                raw =>
                                    let ack = onProxyPost(this.windowLabel, raw, this.controller)
                                    /* 心跳节拍：页面每 500ms 一次 pull，顺手把宿主里的菜单模型
                                       重取一次（setMenuItemState 的改动没有别的通知通道）。 */
                                    this.reloadMenu()
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
     * 快照 → `bindMenu` 的扁平项表。
     *
     * 仓颉侧 `MenuElement` 只有 `value` + `action`：**没有嵌套、没有禁用位**。于是层级用
     * 「父 / 子」标签表达，分隔线与禁用项不画（画出来点了没反应会被误读成「宿主没落地」）。
     */
    private func menuElements(): Array<MenuElement> {
        let out = ArrayList<MenuElement>()
        for (item in this.menuSnapshot) {
            if (item.isSubmenu()) {
                for (child in item.children) {
                    if (!child.enabled || child.isSeparator()) {
                        continue
                    }
                    let target = child.id
                    let text = "${menuItemText(item)} / ${menuItemText(child)}"
                    out.add(MenuElement(value: text, action: { => this.fireMenu(target) }))
                }
            } else if (item.enabled && !item.isSeparator()) {
                let target = item.id
                out.add(MenuElement(value: menuItemText(item), action: { => this.fireMenu(target) }))
            }
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
}

/* 菜单项的显示文本：勾选项带「✓」前缀（MenuElement 没有勾选位，只能写进标签） */
func menuItemText(item: ArkWebMenuItem): String {
    if (item.isCheckbox() && item.checked) {
        return "✓ ${item.label}"
    }
    return item.label
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
