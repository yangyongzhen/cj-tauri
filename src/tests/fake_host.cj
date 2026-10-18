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
    // 选目录与文件框分开记：用例要断言「走的是目录那条路」，不能与 fileDialogArgs 混为一谈
    public var folderDialogTitle: String = ""
    // 菜单：线路文本 / 单项状态按原样记下（桩不建真菜单，用例断言的是投下来的内容）
    public var menuWire: String = ""
    public var menuItemStateArgs: String = ""
    // 标题栏副标题：桩只记最后一次文本（用例断言的是「投下来的是什么」）
    public var titlebarSubtitleText: String = ""
    public var dragDropArgs: String = ""
    public var hotkeyWire: String = ""
    public var trayWire: String = ""
    public var windowVisibleValue: Bool = true
    public var minimizeToTrayValue: Bool = false
    // shell 事件回调（菜单点击等）：用例可以自己调它，模拟「桥把事件送进来了」
    public var shellHandler: (String) -> Unit = { _ => }
    // 销毁回调：用例可以自己调它，模拟「桥通知本窗销毁了」
    public var destroyHandler: () -> Unit = { => }
    // 剪贴板 / 通知：写与通知按「调一次记一次」，读值可注入（默认空，用例按需设）
    public var clipboardWritten: String = ""
    public var clipboardReadValue: Option<String> = None<String>
    public var notifiedArgs: String = ""
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

    public func setTitlebarSubtitle(text: String): Unit {
        this.titlebarSubtitleText = text
    }

    public func setDragDropPolicy(enabled: Bool, files: Bool): Unit {
        this.dragDropArgs = "${enabled}|${files}"
    }

    public func setGlobalHotkeys(wire: String): Unit {
        this.hotkeyWire = wire
    }

    public func setTray(wire: String): Unit {
        this.trayWire = wire
    }

    // 窗口可见性 / 最小化策略：桩只记最后一次设置（用例断言的是「谁被调了、带了什么」）
    public func setWindowVisible(visible: Bool): Unit {
        this.windowVisibleValue = visible
    }

    public func setMinimizeToTray(enabled: Bool): Unit {
        this.minimizeToTrayValue = enabled
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

    public func showFileDialogPreset(save: Bool, title: String, filter: String,
                                     defaultName: String): String {
        // 记痕带预置名：多窗取证靠它断言「本窗拿到的是本窗预置的名字」
        this.fileDialogArgs = "${save}|${title}|${filter}|${defaultName}"
        return ""
    }

    public func showFolderDialog(title: String): String {
        // 桩不真弹窗：记下标题即可（用例断言的是「谁被调了、带了什么」）
        this.folderDialogTitle = title
        return ""
    }

    public func showMessageDialog(kind: String, title: String, message: String): Bool {
        this.messageDialogArgs = "${kind}|${title}|${message}"
        return false
    }

    public func clipboardWriteText(text: String): Bool {
        this.clipboardWritten = text
        return true
    }

    public func clipboardReadText(): Option<String> {
        return this.clipboardReadValue
    }

    public func notify(title: String, body: String): Bool {
        this.notifiedArgs = "${title}|${body}"
        return true
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
