package cjTauri.plugins.dialog

import cjTauri.*

import std.collection.*
import stdx.encoding.json.*

/**
 * 官方插件 dialog：原生对话框（对标 Tauri 的 dialog 插件）
 *
 * 命令：dialog:open / dialog:save / dialog:pickFolder / dialog:message
 * 权限：**不自动放行**，应用要在 capabilities 里显式声明，两种写法等价：
 *   "commands": ["dialog:open", "dialog:message"]     // 明文逐条
 *   "permissions": ["dialog:default"]                 // 命名权限集（v1.1，一次放行一组）
 * 前端：window.__CJ_TAURI__.dialog.open({ filter: "文本文件|*.txt|所有文件|*.*" })
 *       window.__CJ_TAURI__.dialog.pickFolder({ title: "选择目录" })  // 选目录（返回选中目录的绝对路径）
 *
 * 与 fs 插件的差别：这里要落到**系统对话框**，所以弹窗归宿主层（Windows 走 Win32 通用对话框、
 * Linux 走 GTK），插件只做参数校验与命令分发——平台差异不进插件，与 AGENTS.md §2 的架构契约一致。
 * 对话框需要父窗口，故必须等应用启动（start 之后）再调用；更早调用得到的是空结果（取消）。
 */
public class DialogPlugin <: Plugin {
    // 四个命令共用一个处理器实例：setup() 里把宿主交给它（装配必须在 run()/runUrl() 之前完成）
    private let handler: DialogCommands = DialogCommands()

    public init() {}

    public func name(): String {
        return "dialog"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        m.add("open", this.handler)
        m.add("save", this.handler)
        m.add("pickFolder", this.handler)
        m.add("message", this.handler)
        return m
    }

    /**
     * 命名权限集（v1.1）：files 放行三个「挑路径」命令（open / save / pickFolder），
     * message（模态提示框）不在其中。只想让用户挑个文件或目录的应用引用 files 即可，
     * 不必顺带拿到「能弹任意提示框」的能力。
     */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let files = ArrayList<String>()
        files.add("open")
        files.add("save")
        files.add("pickFolder")
        m.add("files", files)
        let all = ArrayList<String>()
        all.add("open")
        all.add("save")
        all.add("pickFolder")
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
            " pickFolder: function (args) { return window.__CJ_TAURI__.invoke('dialog:pickFolder', args); }," +
            " message: function (args) { return window.__CJ_TAURI__.invoke('dialog:message', args); }" +
            " }; })();\n"
    }

    /**
     * 装配宿主：命令要靠它弹原生对话框。
     * 这里只是把宿主对象记下来（宿主在构造 TauriApp 时就存在），真正弹窗要等 start 之后。
     *
     * **两个槽都装**：`app.webviewHost()` 只是默认窗那一个，多窗口下拿它等于
     * 「谁先装配谁收所有弹窗」（第二扇窗的框排进默认窗队列，实测见 docs/鸿蒙ArkWeb接入踩坑.md §10.12）；
     * `app.hostOf` 才是按报文里的窗口取正确宿主的那条路，命令执行时用。
     */
    public func setup(app: TauriApp): Unit {
        this.handler.attachHost(app.webviewHost())
        this.handler.attachHostResolver({ label => app.hostOf(label) })
    }
}

/**
 * dialog 插件的命令处理器（三个命令共用一份，按全名分派，与内置 SystemCommands 同形）
 */
// public 是给单测用的（跨包要能直接构造命令处理器，见 AGENTS §2「单测要直接构造的命令 handler 须 public」）
public class DialogCommands <: CommandHandler {
    // 宿主层（弹原生对话框）；未经 DialogPlugin 装配时为 None，命令给出可读的错误而不是崩
    private var host: Option<WebViewHost> = None

    /* 按 label 解析宿主（多窗口的正路）：单槽 `host` 只记着**装配时那一个**宿主，
       多窗口下用它就是「谁先装配谁收所有弹窗」——2026-10-20 鸿蒙真机实测：两扇窗同时弹框，
       hilog 两次 `dialog take label=main`，第二次的 title 却是 second，且 main 的 @State
       被覆盖成对面内容、第二窗自己的框从未显示（判据与过程见 docs/鸿蒙ArkWeb接入踩坑.md §10.12）。
       单测也靠它注入桩宿主，不必构造真实 TauriApp。 */
    private var hostByWindow: Option<(String) -> Option<WebViewHost>> = None

    public init() {}

    /**
     * 装配**单个**宿主（单窗口 / 单测用）
     *
     * 多窗口一律走 `attachHostResolver`：这个槽不带窗口身份，第二扇窗的命令会落到这里那一个宿主上。
     * 两者同时装时可以共存——解析器优先，`host` 退成兜底（解析器给出 None 时才用）。
     */
    public func attachHost(h: WebViewHost): Unit {
        this.host = Some(h)
    }

    /** 装配「label → 宿主」解析器；由 DialogPlugin.setup() 传入 `app.hostOf` */
    public func attachHostResolver(resolve: (String) -> Option<WebViewHost>): Unit {
        this.hostByWindow = Some(resolve)
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "dialog:open" => JsonString(this.pickFile(args, false, ipc))
            case "dialog:save" => JsonString(this.pickFile(args, true, ipc))
            case "dialog:pickFolder" => JsonString(this.pickFolder(args, ipc))
            case "dialog:message" => JsonBool(this.message(args, ipc))
            case _ => throw CommandException("unknown dialog command: ${cmd}")
        }
    }

    /**
     * 取**发起这条命令的窗口**的宿主
     *
     * 多窗口下必须按 `ipc.window` 解析：用装配时那一个宿主，第二扇窗的弹窗会排进默认窗的队列，
     * 表象是「另一扇窗里冒出别人的框」外加「自己那个框永远不出现」。
     * 解析器在场而窗口没登记时**如实报错**，不要悄悄回落到单槽——那正是串台的来源。
     */
    private func requireHost(ipc: IpcContext): WebViewHost {
        match (this.hostByWindow) {
            case Some(resolve) => match (resolve(ipc.window)) {
                case Some(h) => return h
                // 解析器在场＝多窗口正路：这里回落到单槽就是「弹到别人窗口里」，
                // 所以宁可不弹，把窗口 label 原样报出去（少一个框好过串台）。
                case None => throw CommandException(
                    "dialog: 窗口 \"${ipc.window}\" 没有登记宿主（addWindow(); 默认窗在 run() 之前也可用）")
            }
            case None => ()
        }
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

    private func pickFile(args: JsonObject, save: Bool, ipc: IpcContext): String {
        var title = this.optionalString(args, "title", "")
        if (title.size == 0) {
            if (save) {
                title = "保存文件"
            } else {
                title = "打开文件"
            }
        }
        let filter = this.optionalString(args, "filter", "")
        return this.requireHost(ipc).showFileDialog(save, title, filter)
    }

    /** 选目录（宿主侧 kind=6）：只有 title 一个可选参数；取消回空串，与文件框同语义 */
    private func pickFolder(args: JsonObject, ipc: IpcContext): String {
        var title = this.optionalString(args, "title", "")
        if (title.size == 0) {
            title = "选择文件夹"
        }
        return this.requireHost(ipc).showFolderDialog(title)
    }

    private func message(args: JsonObject, ipc: IpcContext): Bool {
        let text = this.requireString(args, "message")
        let kind = this.optionalString(args, "kind", "info")
        var title = this.optionalString(args, "title", "")
        if (title.size == 0) {
            title = "提示"
        }
        return this.requireHost(ipc).showMessageDialog(kind, title, text)
    }
}
