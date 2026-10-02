package cjTauri

import std.collection.*
import stdx.encoding.json.*

/**
 * 官方插件 dialog：原生对话框（对标 Tauri 的 dialog 插件）
 *
 * 命令：dialog:open / dialog:save / dialog:message
 * 权限：**不自动放行**，应用要在 capabilities 里显式声明，两种写法等价：
 *   "commands": ["dialog:open", "dialog:message"]     // 明文逐条
 *   "permissions": ["dialog:default"]                 // 命名权限集（v1.1，一次放行一组）
 * 前端：window.__CJ_TAURI__.dialog.open({ filter: "文本文件|*.txt|所有文件|*.*" })
 *
 * 与 fs 插件的差别：这里要落到**系统对话框**，所以弹窗归宿主层（Windows 走 Win32 通用对话框、
 * Linux 走 GTK），插件只做参数校验与命令分发——平台差异不进插件，与 AGENTS.md §2 的架构契约一致。
 * 对话框需要父窗口，故必须等应用启动（start 之后）再调用；更早调用得到的是空结果（取消）。
 */
public class DialogPlugin <: Plugin {
    // 三个命令共用一个处理器实例：setup() 里把宿主交给它（装配必须在 run()/runUrl() 之前完成）
    private let handler: DialogCommands = DialogCommands()

    public init() {}

    public func name(): String {
        return "dialog"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        m.add("open", this.handler)
        m.add("save", this.handler)
        m.add("message", this.handler)
        return m
    }

    /**
     * 命名权限集（v1.1）：files 只放行两个文件选择命令，message（模态提示框）不在其中。
     * 只想让用户挑个文件的应用引用 files 即可，不必顺带拿到「能弹任意提示框」的能力。
     */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let files = ArrayList<String>()
        files.add("open")
        files.add("save")
        m.add("files", files)
        let all = ArrayList<String>()
        all.add("open")
        all.add("save")
        all.add("message")
        m.add("default", all)
        return m
    }

    /**
     * 前端 shim：往桥对象上挂一个 dialog 命名空间（与 FsPlugin 同款，不碰 invoke / listen / emit）
     */
    public func jsShim(): String {
        return "(function () { var t = window.__CJ_TAURI__ || (window.__CJ_TAURI__ = {});" +
            " t.dialog = {" +
            " open: function (args) { return window.__CJ_TAURI__.invoke('dialog:open', args); }," +
            " save: function (args) { return window.__CJ_TAURI__.invoke('dialog:save', args); }," +
            " message: function (args) { return window.__CJ_TAURI__.invoke('dialog:message', args); }" +
            " }; })();\n"
    }

    /**
     * 装配宿主：命令要靠它弹原生对话框。
     * 这里只是把宿主对象记下来（宿主在构造 TauriApp 时就存在），真正弹窗要等 start 之后。
     */
    public func setup(app: TauriApp): Unit {
        this.handler.attachHost(app.webviewHost())
    }
}

/**
 * dialog 插件的命令处理器（三个命令共用一份，按全名分派，与内置 SystemCommands 同形）
 */
class DialogCommands <: CommandHandler {
    // 宿主层（弹原生对话框）；未经 DialogPlugin 装配时为 None，命令给出可读的错误而不是崩
    private var host: Option<WebViewHost> = None

    public init() {}

    /** 由 DialogPlugin.setup() 调用 */
    func attachHost(h: WebViewHost): Unit {
        this.host = Some(h)
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "dialog:open" => JsonString(this.pickFile(args, false))
            case "dialog:save" => JsonString(this.pickFile(args, true))
            case "dialog:message" => JsonBool(this.message(args))
            case _ => throw CommandException("unknown dialog command: ${cmd}")
        }
    }

    private func requireHost(): WebViewHost {
        match (this.host) {
            case Some(h) => h
            case None => throw CommandException(
                "dialog: 宿主未装配（用 .plugin(DialogPlugin()) 装配插件后才可用）")
        }
    }

    /** 取必需的字符串参数；缺失或类型不对时抛业务错误，前端拿到的是可读原文 */
    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => throw CommandException("dialog: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("dialog: missing argument \"${key}\"")
        }
    }

    /** 取可选字符串参数：缺失或类型不对都退回默认值（标题 / 过滤器都不是必需的） */
    private func optionalString(args: JsonObject, key: String, fallback: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => fallback
            }
            case None => fallback
        }
    }

    private func pickFile(args: JsonObject, save: Bool): String {
        var title = this.optionalString(args, "title", "")
        if (title.size == 0) {
            if (save) {
                title = "保存文件"
            } else {
                title = "打开文件"
            }
        }
        let filter = this.optionalString(args, "filter", "")
        return this.requireHost().showFileDialog(save, title, filter)
    }

    private func message(args: JsonObject): Bool {
        let text = this.requireString(args, "message")
        let kind = this.optionalString(args, "kind", "info")
        var title = this.optionalString(args, "title", "")
        if (title.size == 0) {
            title = "提示"
        }
        return this.requireHost().showMessageDialog(kind, title, text)
    }
}
