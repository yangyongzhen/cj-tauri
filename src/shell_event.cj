package cjTauri

import stdx.encoding.json.*

/**
 * shell 事件信封（C 桥 → 仓颉）的解析与语义映射：RFC-002 §5.5 / §5.6
 *
 * 信封形状（当前定稿，菜单）：`{"kind":"menu","id":"file.save","enabled":true,"checked":false}`
 * 托盘 / 拖放落地后各带自己的 kind（`tray` / `drop`），kind 决定投给前端哪个事件名。
 *
 * 为什么单独成文件：这里是**纯函数**（不进窗口、不碰线程），能脱离宿主在单测里直接验。
 * 信封格式坏掉的表现是「事件静默不到」——没有纯函数边界时，只能靠实机点击去猜。
 */

/** `kind` → 前端事件名；不认识的 kind 返回 None（调用方提示一句后丢弃，不抛异常） */
public func shellEventNameFor(kind: String): Option<String> {
    match (kind) {
        case "menu" => return Some("menu:click")
        case "tray" => return Some("tray:click")
        case "drop" => return Some("dragdrop:files")
        case _ => return None
    }
}

/**
 * 解析信封成对象；不是合法 JSON 对象就返回 None
 *
 * 不抛异常：数据从 C 桥来（**不是**页面可控输入），格式坏了宁可丢一条事件 + 留一行日志，
 * 也不要让异常穿到 FFI 边界——仓颉异常穿过 C 侧回调，进程状态就说不清了。
 */
public func parseShellEnvelope(json: String): Option<JsonObject> {
    try {
        let v = JsonValue.fromStr(json)
        match (v.kind()) {
            case JsonKind.JsObject => return Some(v.asObject())
            case _ => return None
        }
    } catch (e: Exception) {
        return None
    }
}

/** 取信封里的字符串字段（缺失 / 类型不对都给 None） */
public func shellString(obj: JsonObject, key: String): Option<String> {
    match (obj.get(key)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsString => return Some(v.asString().getValue())
            case _ => return None
        }
        case None => return None
    }
}

/**
 * 取信封里的布尔字段（缺失 / 类型不对都给 None）
 *
 * 缺字段**不能**当 false 用：这两个值要回写到应用层菜单模型（见 `TauriApp` 的模型同步），
 * 拿默认值顶等于把「用户刚点出来的勾选」按默认值改掉——宁可不写。
 */
public func shellBool(obj: JsonObject, key: String): Option<Bool> {
    match (obj.get(key)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsBool => return Some(v.asBool().getValue())
            case _ => return None
        }
        case None => return None
    }
}
