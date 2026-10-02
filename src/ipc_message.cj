package cjTauri

import stdx.encoding.json.*

/**
 * 窗口 label 的缺省值（对外契约，不能改）
 *
 * 与桥 JS 的 `windowLabel` 缺省、`emitToWindow(..., "main")` 是同一个约定：老前端与现有示例
 * 都写死 `"main"`，默认值一错，事件就静默收不到、回执就静默投不回原窗口（见架构文档 §6.4）。
 */
let DEFAULT_WINDOW_LABEL = "main"

/**
 * IPC 消息模型（对标 Tauri IPC 协议）
 *
 * JS → 仓颉 (invoke):
 *   {"type":"invoke","id":1,"cmd":"greet","args":{...},"window":"main"}
 * JS → 仓颉 (emit):
 *   {"type":"emit","id":2,"event":"tick","payload":{...},"window":"main"}
 *   `window` 是发起窗口的 label（批次 2 起由桥 JS 带上）。**缺省 / 非字符串 / 空串一律按 "main" 处理**：
 *   上行方向没有「广播」语义——一条回执必须能回到唯一一个窗口，否则前端那条 promise 永远 pending。
 * 仓颉 → JS (resolve/reject):
 *   {"type":"resolve","id":1,"ok":true,"data":...}
 *   {"type":"resolve","id":1,"ok":false,"error":"..."}
 * 仓颉 → JS (event):
 *   {"type":"event","event":"tick","payload":{...},"window":"main"}
 *   window 字段缺省 = 广播（所有窗口）；定向推送时给接收窗口的 label，
 *   页面里由桥按自己的 label 过滤（多窗口落地前只有一个 "main"）。
 *   `emitLatest` 发出的报文多一个 "coalesce":true —— 页面侧同一帧内同名事件只投最后一次
 *   payload（中间值丢弃），tick = 一帧。
 */

public class InvokeRequest {
    public let id: Int64
    public let cmd: String
    public let args: JsonObject
    /** 发起窗口的 label（批次 2 起随报文来）；回执按它回投给同一窗口 */
    public let window: String

    public init(id: Int64, cmd: String, args: JsonObject, window!: String = DEFAULT_WINDOW_LABEL) {
        this.id = id
        this.cmd = cmd
        this.args = args
        this.window = window
    }

    /**
     * 从 JS 侧 postMessage 的原始 JSON 解析 invoke 请求。
     * 解析失败返回 None（由调用方判定为非法消息）。
     */
    public static func parse(raw: String): Option<InvokeRequest> {
        try {
            let envOpt = parseEnvelope(raw)
            if (envOpt.isNone()) {
                return None
            }
            let env = envOpt.getOrThrow()
            if (env.msgType != "invoke") {
                return None
            }
            let obj = env.obj
            let idV = obj.get("id")
            let cmdV = obj.get("cmd")
            if (idV.isNone() || cmdV.isNone()) {
                return None
            }
            let id = idV.getOrThrow().asInt().getValue()
            let cmd = cmdV.getOrThrow().asString().getValue()
            var args = JsonObject()
            if (let Some(a) <- obj.get("args")) {
                match (a.kind()) {
                    case JsonKind.JsObject => args = a.asObject()
                    case _ => ()
                }
            }
            return Some(InvokeRequest(id, cmd, args, window: parseWindowLabel(obj)))
        } catch (e: Exception) {
            return None
        }
    }
}

/**
 * 前端 emit 事件（对标 Tauri v2 前端 `emit()` → `plugin:event|emit`）
 *
 * 语义与 Tauri 的**有意差异**（选了更保守的一条，理由与后续演进口径见 docs/IPC-通信机制.md §7）：
 * 事件只投给**后端监听器**（`IpcHub.listenEvent` 注册的），不回投给任何页面。
 * Tauri 的 `emit` 是全局广播（含发起者自己），在单窗口下退化成「自己发自己收」，
 * 且多窗口寻址（报文里的 window 字段）还没落地——等窗口有了再把投递侧接到窗口注册表上，
 * 前端与报文格式都不用改。
 *
 * 带 id 是有意的：事件未授权 / 报文非法都要能把失败**回给前端**（reject 同一个 id），
 * 而不是只在 stderr 里悄悄丢（对照 Tauri 的 `emit()` 返回 Promise<void>）。
 */
public class EmitRequest {
    public let id: Int64
    public let event: String
    public let payload: JsonValue
    /** 发起窗口的 label（批次 2 起随报文来）；resolve 回执按它回投给同一窗口 */
    public let window: String

    public init(id: Int64, event: String, payload: JsonValue, window!: String = DEFAULT_WINDOW_LABEL) {
        this.id = id
        this.event = event
        this.payload = payload
        this.window = window
    }

    /**
     * 解析前端 emit 报文；payload 缺省为空对象，解析失败返回 None。
     */
    public static func parse(raw: String): Option<EmitRequest> {
        try {
            let envOpt = parseEnvelope(raw)
            if (envOpt.isNone()) {
                return None
            }
            let env = envOpt.getOrThrow()
            if (env.msgType != "emit") {
                return None
            }
            let obj = env.obj
            let idV = obj.get("id")
            let eventV = obj.get("event")
            if (idV.isNone() || eventV.isNone()) {
                return None
            }
            let id = idV.getOrThrow().asInt().getValue()
            let event = eventV.getOrThrow().asString().getValue()
            var payload: JsonValue = JsonObject()
            if (let Some(p) <- obj.get("payload")) {
                payload = p
            }
            return Some(EmitRequest(id, event, payload, window: parseWindowLabel(obj)))
        } catch (e: Exception) {
            return None
        }
    }
}

/**
 * 报文信封：顶层 JSON 对象 + 字符串 type 字段。
 * invoke / emit 两条解析路径共用——两份重复的预检迟早漂移，而「type 必须是字符串」这类
 * 判定正是非法报文与正常报文的分界。
 */
class IpcEnvelope {
    let obj: JsonObject
    let msgType: String

    init(obj: JsonObject, msgType: String) {
        this.obj = obj
        this.msgType = msgType
    }
}

/**
 * 从报文里取发起窗口的 label：缺失 / 非字符串 / 空串一律回落到 `DEFAULT_WINDOW_LABEL`
 *
 * 为什么空串也回落：下行方向的空串是「广播」（谁在听谁收），上行方向没有这个语义——
 * 一条回执必须回到唯一一个窗口，否则前端那条 promise 永远 pending。
 */
func parseWindowLabel(obj: JsonObject): String {
    if (let Some(w) <- obj.get("window")) {
        match (w.kind()) {
            case JsonKind.JsString =>
                let s = w.asString().getValue()
                if (s.size > 0) {
                    return s
                }
            case _ => ()
        }
    }
    return DEFAULT_WINDOW_LABEL
}

/** 解析报文信封；非 JSON / 顶层不是对象 / type 缺失或不是字符串，一律 None */
func parseEnvelope(raw: String): Option<IpcEnvelope> {
    try {
        let root = JsonValue.fromStr(raw)
        match (root.kind()) {
            case JsonKind.JsObject => ()
            case _ => return None
        }
        let obj = root.asObject()
        if (let Some(t) <- obj.get("type")) {
            match (t.kind()) {
                case JsonKind.JsString => return Some(IpcEnvelope(obj, t.asString().getValue()))
                case _ => return None
            }
        }
        return None
    } catch (e: Exception) {
        return None
    }
}

public class IpcMessage {
    /**
     * 构造 resolve 响应 JSON（ok=true）
     */
    public static func resolve(id: Int64, data: JsonValue): String {
        var obj = JsonObject()
        obj.put("type", JsonString("resolve"))
        obj.put("id", JsonInt(id))
        obj.put("ok", JsonBool(true))
        obj.put("data", data)
        return obj.toJsonString()
    }

    /**
     * 构造 reject 响应 JSON（ok=false）
     */
    public static func reject(id: Int64, error: String): String {
        var obj = JsonObject()
        obj.put("type", JsonString("resolve"))
        obj.put("id", JsonInt(id))
        obj.put("ok", JsonBool(false))
        obj.put("error", JsonString(error))
        return obj.toJsonString()
    }

    /**
     * 构造事件推送 JSON
     *
     * @param window 接收窗口的 label；空串 = 广播（报文里不带 window 字段，桥放行）。
     *               多窗口落地前只会是 "main"，但字段现在就留在协议里，免得那次改造再动报文。
     */
    public static func event(event: String, payload: JsonValue, window: String): String {
        return eventJson(event, payload, window, false).toJsonString()
    }

    /**
     * 构造「只保最新」的事件推送 JSON（`IpcHub.emitLatest` 用）
     *
     * 报文只比 `event` 多一个 `coalesce: true`：页面侧桥把它落进「本帧槽位」，
     * 同一帧内同名事件只投最后一次 payload，中间值丢弃。要不要这种语义由**调用方显式选**——
     * 默认路径不做合并（静默丢数据比慢更难排查，Tauri v2 核心同样不合并）。
     * tick = 一帧，理由与对照见 docs/IPC-通信机制.md §6 第 5 项。
     */
    public static func eventLatest(event: String, payload: JsonValue, window: String): String {
        return eventJson(event, payload, window, true).toJsonString()
    }

    /** 事件报文的公共构造：`coalesce` 只在需要时落字段，旧报文形态逐字节不变 */
    private static func eventJson(event: String, payload: JsonValue, window: String, coalesce: Bool): JsonObject {
        var obj = JsonObject()
        obj.put("type", JsonString("event"))
        obj.put("event", JsonString(event))
        obj.put("payload", payload)
        if (coalesce) {
            obj.put("coalesce", JsonBool(true))
        }
        if (window.size > 0) {
            obj.put("window", JsonString(window))
        }
        return obj
    }

    /**
     * 尽力从报文里取出 id（只认顶层 int 字段），取下取不到返回 None。
     *
     * 用途是非法报文的回包：前端 `invoke` / `emit` 都带 id，只要 id 可读就应该回一条 reject，
     * 否则前端那条 promise 会永久 pending（比报错更难排查）。取不到 id 的（例如裸字符串、
     * 没有 id 的 JSON）没法对应到任何 promise，只能打 stderr。
     */
    public static func peekId(raw: String): Option<Int64> {
        try {
            let root = JsonValue.fromStr(raw)
            match (root.kind()) {
                case JsonKind.JsObject => ()
                case _ => return None
            }
            let idV = root.asObject().get("id")
            if (idV.isNone()) {
                return None
            }
            match (idV.getOrThrow().kind()) {
                case JsonKind.JsInt => return Some(idV.getOrThrow().asInt().getValue())
                case _ => return None
            }
        } catch (e: Exception) {
            return None
        }
    }
}
