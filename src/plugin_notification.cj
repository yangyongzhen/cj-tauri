package cjTauri

import std.collection.*
import stdx.encoding.json.*

/**
 * 官方插件 notification：系统通知（对标 Tauri 的 notification 插件，RFC-003 第 3 期）
 *
 * 命令：notification:notify
 * 权限：**不自动放行**，应用要在 capabilities 里显式声明：
 *   "commands": ["notification:notify"]
 *   "permissions": ["notification:default"]
 * 前端：window.__CJ_TAURI__.notification.notify({ title, body })
 *
 * 实现落 C 桥 `cj_bridge_notification_notify`：Linux 走 freedesktop Notifications
 * （会话总线）；**Windows 桩阶段返回 -4 未实现**——命令如实报失败，`system:host` 的能力位
 * 同口径不置 CJ_CAP_NOTIFICATION，不假装成功（AGENTS §1 的如实交付口径）。
 *
 * 「发后即忘」：提交即返回，通知显示与否不回传（freedesktop 协议本就没有同步回执）。
 */
public class NotificationPlugin <: Plugin {
    private let handler: NotificationCommands = NotificationCommands()

    public init() {}

    public func name(): String {
        return "notification"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        m.add("notify", this.handler)
        return m
    }

    /**
     * 命名权限集（v1.1）：只有一条命令，default 与明文等价——保留集名是为了
     * 应用清单写法统一（全部走 permissions 数组）。
     */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let all = ArrayList<String>()
        all.add("notify")
        m.add("default", all)
        return m
    }

    /**
     * 前端 shim：往桥对象上挂一个 notification 命名空间（与 dialog 同款）
     */
    public func jsShim(): String {
        return "(function () { var t = window.__CJ_TAURI__ || (window.__CJ_TAURI__ = {});" +
            " t.notification = {" +
            " notify: function (o) { return window.__CJ_TAURI__.invoke('notification:notify', o || {}); }" +
            " }; })();\n"
    }

    public func setup(app: TauriApp): Unit {
        this.handler.attachHost(app.webviewHost())
    }
}

/**
 * 通知命令处理器：notify 收 { title, body? }。body 省略 / null 都合法。
 */
class NotificationCommands <: CommandHandler {
    private var host: Option<WebViewHost> = None

    public init() {}

    /** 由 NotificationPlugin.setup() 调用 */
    func attachHost(h: WebViewHost): Unit {
        this.host = Some(h)
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = ipc
        match (cmd) {
            case "notification:notify" =>
                let title = this.requireString(args, "title")
                let body = this.optionalString(args, "body")
                if (this.requireHost().notify(title, body)) {
                    return JsonNull()
                }
                throw CommandException(
                    "notification: 发送失败（宿主未就绪 / 本平台未实现 / 桌面环境不可用）")
            case _ => throw CommandException("unknown notification command: ${cmd}")
        }
    }

    private func requireHost(): WebViewHost {
        match (this.host) {
            case Some(h) => h
            case None => throw CommandException(
                "notification: 宿主未装配（用 .plugin(NotificationPlugin()) 装配插件后才可用）")
        }
    }

    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => throw CommandException("notification: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("notification: missing argument \"${key}\"")
        }
    }

    /** 可选字符串参数：缺失 / null 都按空串（body 可省） */
    private func optionalString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case JsonKind.JsNull => return ""
                case _ => throw CommandException("notification: argument \"${key}\" must be a string")
            }
            case None => return ""
        }
    }
}
