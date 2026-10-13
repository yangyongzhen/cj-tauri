package cjTauri.plugins

import cjTauri.*

import std.collection.*
import stdx.encoding.json.*

/**
 * 官方插件 clipboard：系统剪贴板（对标 Tauri 的 clipboard-manager 插件，RFC-003 第 3 期）
 *
 * 命令：clipboard:write / clipboard:read
 * 权限：**不自动放行**，应用要在 capabilities 里显式声明，两种写法等价：
 *   "commands": ["clipboard:read"]                 // 明文逐条
 *   "permissions": ["clipboard:readonly"]          // 命名权限集（只放行 read）
 *   "permissions": ["clipboard:default"]           // 命名权限集（读写全量）
 * 前端：window.__CJ_TAURI__.clipboard.writeText("...") / readText()
 *
 * 真正的读写落在 C 桥（`cj_bridge_clipboard_*`）：GTK / Win32 的剪贴板调用都必须在
 * 宿主 UI 线程上，core 那边做「UI 线程分流 + 单槽等待」。插件只做参数校验与命令分发，
 * 平台差异不进插件（AGENTS §2 的架构契约）。
 *
 * 读写都要宿主已就绪（start 之后）；更早调用得到 false / None。
 */
public class ClipboardPlugin <: Plugin {
    private let handler: ClipboardCommands = ClipboardCommands()

    public init() {}

    public func name(): String {
        return "clipboard"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        m.add("write", this.handler)
        m.add("read", this.handler)
        return m
    }

    /**
     * 命名权限集（v1.1）：readonly 只放行读——剪贴板里可能有用户敏感内容，
     * 「只写不读」是合理的最小授权面。
     */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let ro = ArrayList<String>()
        ro.add("read")
        m.add("readonly", ro)
        let all = ArrayList<String>()
        all.add("read")
        all.add("write")
        m.add("default", all)
        return m
    }

    /**
     * 前端 shim：往桥对象上挂一个 clipboard 命名空间（与 dialog 同款）
     */
    public func jsShim(): String {
        return "(function () { var t = window.__CJ_TAURI__ || (window.__CJ_TAURI__ = {});" +
            " t.clipboard = {" +
            " writeText: function (text) { return window.__CJ_TAURI__.invoke('clipboard:write', { text: text }); }," +
            " readText: function () { return window.__CJ_TAURI__.invoke('clipboard:read', {}); }" +
            " }; })();\n"
    }

    public func setup(app: TauriApp): Unit {
        this.handler.attachHost(app.webviewHost())
    }
}

/**
 * 剪贴板命令处理器：write 收 { text }，read 无参。
 */
public class ClipboardCommands <: CommandHandler {
    private var host: Option<WebViewHost> = None

    public init() {}

    /** 由 ClipboardPlugin.setup() 调用 */
    public func attachHost(h: WebViewHost): Unit {
        this.host = Some(h)
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = ipc
        match (cmd) {
            case "clipboard:write" =>
                let text = this.requireString(args, "text")
                if (this.requireHost().clipboardWriteText(text)) {
                    return JsonNull()
                }
                throw CommandException("clipboard: 写入失败（宿主未就绪 / 平台拒绝）")
            case "clipboard:read" =>
                match (this.requireHost().clipboardReadText()) {
                    case Some(text) => return JsonString(text)
                    case None => return JsonNull() // 空 / 非文本：合法结果，不是错误
                }
            case _ => throw CommandException("unknown clipboard command: ${cmd}")
        }
    }

    private func requireHost(): WebViewHost {
        match (this.host) {
            case Some(h) => h
            case None => throw CommandException(
                "clipboard: 宿主未装配（用 .plugin(ClipboardPlugin()) 装配插件后才可用）")
        }
    }

    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => throw CommandException("clipboard: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("clipboard: missing argument \"${key}\"")
        }
    }
}
