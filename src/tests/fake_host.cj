package cjTauri.tests

import cjTauri.*
import std.collection.*

/*
 * WebViewHost 的测试替身：记录被调用的痕迹，其余空实现。
 * 用途：不创建原生窗口就能测装配路径（TauriApp 装配、WindowRegistry、事件派发）。
 * 接口增删方法时这里必须跟着改——那是**有意的**：编译器会点名这一处，
 * 免得像 C 桥那样「改了一份忘了另一份」。
 */
class FakeHost <: WebViewHost {
    // 字段不叫 label：接口有 label() 方法，同名会撞
    public let windowLabel: String
    public var started: Bool = false
    public var startedUrl: String = ""
    public var shownHtml: String = ""
    public var jsCalls: ArrayList<String> = ArrayList<String>()
    public var initScripts: ArrayList<String> = ArrayList<String>()
    public var config: WindowConfig = WindowConfig()
    public var handler: (String) -> Unit = { _ => }
    public var disposed: Bool = false
    public var quitCalled: Bool = false
    public var devToolsEnabled: Bool = false
    // 对话框入参按「调一次记一次」存成字符串：桩不真弹窗，用例要断言的是「谁被调了、带了什么」
    public var fileDialogArgs: String = ""
    public var messageDialogArgs: String = ""
    // 菜单：线路文本 / 单项状态按原样记下（桩不建真菜单，用例断言的是投下来的内容）
    public var menuWire: String = ""
    public var menuItemStateArgs: String = ""
    // shell 事件回调（菜单点击等）：用例可以自己调它，模拟「桥把事件送进来了」
    public var shellHandler: (String) -> Unit = { _ => }
    // 销毁回调：用例可以自己调它，模拟「桥通知本窗销毁了」
    public var destroyHandler: () -> Unit = { => }
    // 能力位：桩给「有菜单」，用例要测「平台没这个本事」时自行覆盖它
    public var caps: Int32 = CJ_CAP_MENU

    public init(windowLabel: String) {
        this.windowLabel = windowLabel
    }

    public func start(html: String): Unit {
        this.started = true
        this.shownHtml = html
    }

    public func label(): String {
        return this.windowLabel
    }

    public func startUrl(url: String): Unit {
        this.started = true
        this.startedUrl = url
    }

    public func addInitScript(js: String): Unit {
        this.initScripts.add(js)
    }

    public func reload(): Unit {}

    public func setWindowConfig(config: WindowConfig): Unit {
        this.config = config
    }

    public func setDevTools(enabled: Bool): Unit {
        this.devToolsEnabled = enabled
    }

    public func openDevTools(): Unit {}

    public func setMenu(wire: String): Unit {
        this.menuWire = wire
    }

    public func setMenuItemState(id: String, enabled: Bool, checked: Bool): Unit {
        this.menuItemStateArgs = "${id}|${enabled}|${checked}"
    }

    public func hostCapabilities(): Int32 {
        return this.caps
    }

    public func setShellHandler(handler: (String) -> Unit): Unit {
        this.shellHandler = handler
    }

    public func setDestroyHandler(handler: () -> Unit): Unit {
        this.destroyHandler = handler
    }

    public func showFileDialog(save: Bool, title: String, filter: String): String {
        this.fileDialogArgs = "${save}|${title}|${filter}"
        return ""
    }

    public func showMessageDialog(kind: String, title: String, message: String): Bool {
        this.messageDialogArgs = "${kind}|${title}|${message}"
        return false
    }

    public func runJs(js: String): Unit {
        this.jsCalls.add(js)
    }

    public func quit(): Unit {
        this.quitCalled = true
    }

    public func setMessageHandler(handler: (String) -> Unit): Unit {
        this.handler = handler
    }

    public func shouldQuit(): Bool {
        return false
    }

    public func dispose(): Unit {
        this.disposed = true
    }
}
