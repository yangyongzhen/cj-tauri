package cookieExport

import cjTauri.*
import std.collection.*
import std.convert.*    // Int64.parse：页面传上来的坐标是 JSON 数字
import stdx.encoding.json.*

/**
 * 内嵌登录视图：**宿主自己的 WebView**，不是 iframe。
 *
 * 为什么不塞 iframe 进主页面：iframe 是第三方上下文，WebView2 默认拦第三方 cookie，
 * 登录态根本存不住；多数站点还有 `X-Frame-Options: DENY` 直接白屏。内嵌视图与浏览器里一模一样，
 * 而且它和主窗**共享宿主 cookie 仓库**——在这里登录完，`cookie:probe` 立刻就能读到。
 *
 * 安全边界（沿用 ai-chat webtab）：登录页是外部站点，**不注入桥、不注入插件 shim**。
 * 它拿不到 `window.__CJ_TAURI__`，只能当一个普通网页用。
 */

/** 一个平台最多一扇登录视图：重复点「登录」只是把它显示出来，不叠窗口 */
public class LoginCommands <: CommandHandler {
    private let hostResolver: (String) -> Option<WebViewHost>
    private let views: HashMap<String, Int64> = HashMap<String, Int64>()

    public init(hostResolver: (String) -> Option<WebViewHost>) {
        this.hostResolver = hostResolver
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "login:show" => return this.show(args, ipc)
            case "login:bounds" => return this.bounds(args, ipc)
            case "login:hide" => return this.setVisible(args, ipc, false)
            case "login:close" => return this.close(args, ipc)
            case _ => throw CommandException("unknown login command: ${cmd}")
        }
    }

    private func hostOf(ipc: IpcContext): WebViewHost {
        match (this.hostResolver(ipc.window)) {
            case Some(h) => return h
            case None => throw CommandException("login: 窗口未登记: ${ipc.window}")
        }
    }

    private func show(args: JsonObject, ipc: IpcContext): JsonValue {
        let def = requirePlatform(argStr(args, "platform"))
        let host = this.hostOf(ipc)
        let x = argInt(args, "x")
        let y = argInt(args, "y")
        let w = argInt(args, "w")
        let h = argInt(args, "h")
        match (this.views.get(def.id)) {
            case Some(handle) =>
                // 已经建过：只调位置+露出（保留用户已登录的会话，重建会把登录态所在页面刷掉）
                host.setEmbeddedViewBounds(handle, Int32(x), Int32(y), Int32(w), Int32(h))
                host.setEmbeddedViewVisible(handle, true)
                return okView(handle, false)
            case None => ()
        }
        let handle = host.createEmbeddedView(def.loginUrl, Int32(x), Int32(y), Int32(w), Int32(h))
        if (handle == 0) {
            throw CommandException("当前平台不支持窗口内嵌视图（createEmbeddedView 回 0）")
        }
        this.views.add(def.id, handle)
        host.setEmbeddedViewVisible(handle, true)
        return okView(handle, true)
    }

    private func bounds(args: JsonObject, ipc: IpcContext): JsonValue {
        let def = requirePlatform(argStr(args, "platform"))
        let host = this.hostOf(ipc)
        match (this.views.get(def.id)) {
            case Some(handle) =>
                host.setEmbeddedViewBounds(handle, Int32(argInt(args, "x")), Int32(argInt(args, "y")),
                                           Int32(argInt(args, "w")), Int32(argInt(args, "h")))
                return okView(handle, false)
            case None => return errJson("该平台还没有打开的登录视图")
        }
    }

    private func setVisible(args: JsonObject, ipc: IpcContext, visible: Bool): JsonValue {
        let def = requirePlatform(argStr(args, "platform"))
        let host = this.hostOf(ipc)
        match (this.views.get(def.id)) {
            case Some(handle) =>
                host.setEmbeddedViewVisible(handle, visible)
                return okView(handle, false)
            case None => return errJson("该平台还没有打开的登录视图")
        }
    }

    private func close(args: JsonObject, ipc: IpcContext): JsonValue {
        let def = requirePlatform(argStr(args, "platform"))
        let host = this.hostOf(ipc)
        match (this.views.get(def.id)) {
            case Some(handle) =>
                host.destroyEmbeddedView(handle)
                this.views.remove(def.id)
                let o = JsonObject()
                o.put("ok", JsonBool(true))
                return o
            case None => return errJson("该平台还没有打开的登录视图")
        }
    }

    private func okView(handle: Int64, created: Bool): JsonValue {
        let o = JsonObject()
        o.put("ok", JsonBool(true))
        o.put("handle", JsonInt(handle))
        o.put("created", JsonBool(created))
        return o
    }
}

/** 视图像素参数一律按 Int64 收，转 Int32 只在送进宿主那一刻做（越界由宿主裁） */
func argInt(args: JsonObject, key: String): Int64 {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                // 页面来的坐标是 Number：stdx 把它分成 JsInt / JsFloat 两种（没有 JsNumber）
                case JsonKind.JsInt =>
                    try {
                        return Int64.parse(v.toString())
                    } catch (e: Exception) {
                        return 0
                    }
                case JsonKind.JsFloat => return Int64(v.asFloat().getValue())
                case _ => return 0
            }
        case None => return 0
    }
}
