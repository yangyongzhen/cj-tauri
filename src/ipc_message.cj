package cjTauri

import stdx.encoding.json.*

/**
 * IPC 消息模型（对标 Tauri IPC 协议）
 *
 * JS → 仓颉 (invoke):
 *   {"type":"invoke","id":1,"cmd":"greet","args":{...}}
 * 仓颉 → JS (resolve/reject):
 *   {"type":"resolve","id":1,"ok":true,"data":...}
 *   {"type":"resolve","id":1,"ok":false,"error":"..."}
 * 仓颉 → JS (event):
 *   {"type":"event","event":"tick","payload":{...}}
 */

public class InvokeRequest {
    public let id: Int64
    public let cmd: String
    public let args: JsonObject

    public init(id: Int64, cmd: String, args: JsonObject) {
        this.id = id
        this.cmd = cmd
        this.args = args
    }

    /**
     * 从 JS 侧 postMessage 的原始 JSON 解析 invoke 请求。
     * 解析失败返回 None（由调用方判定为非法消息）。
     */
    public static func parse(raw: String): Option<InvokeRequest> {
        try {
            let root = JsonValue.fromStr(raw)
            match (root.kind()) {
                case JsonKind.JsObject => ()
                case _ => return None
            }
            let obj = root.asObject()
            let typeV = obj.get("type")
            if (typeV.isNone()) {
                return None
            }
            match (typeV.getOrThrow().kind()) {
                case JsonKind.JsString => ()
                case _ => return None
            }
            if (typeV.getOrThrow().asString().getValue() != "invoke") {
                return None
            }
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
            return Some(InvokeRequest(id, cmd, args))
        } catch (e: Exception) {
            return None
        }
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
     */
    public static func event(event: String, payload: JsonValue): String {
        var obj = JsonObject()
        obj.put("type", JsonString("event"))
        obj.put("event", JsonString(event))
        obj.put("payload", payload)
        return obj.toJsonString()
    }
}
