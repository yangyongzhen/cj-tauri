package cjTauri

import std.collection.*

/**
 * 全局快捷键的**纯仓颉模型**（RFC-003 第 5 期首个落地项）：只描述意图，不含任何平台概念。
 *
 * 分层与菜单同构（RFC-002 §5.1）：模型（本文件）→ `WebViewHost.setGlobalHotkeys()`
 * → C 桥 `cj_bridge_set_global_hotkeys` → 平台翻译层（Linux = X11 grab；Windows 桩如实报暂不支持）。
 *
 * wire 格式（与 `native/core/bridge_core.h` 的 `pending_hotkeys` 注释逐字对应）：
 * 一行一条 `<accel>:<id>`，如 `Ctrl+Alt+C:show-panel`。accel 的修饰键只有四个约定名
 * （Ctrl / Alt / Shift / Super），键名是单字符或 F1..F12 / Enter / Esc 等常用键——
 * 平台侧解析不了的那条整行丢弃并出声，而不是静默吞掉。
 *
 * 文本来自**应用作者**（不是页面可控输入），这里不做转义；id 里出现 `:` 或换行是应用自己的错，
 * toWire 不出口这种行（防御性跳过并留一句 stderr 的成本太高，直接约定 + 文档）。
 */
public class Hotkey {
    public let accel: String
    public let id: String

    public init(accel: String, id: String) {
        this.accel = accel
        this.id = id
    }
}

/** 快捷键模型：注册表即整表替换（运行期再调 setGlobalHotkeys = 先注销旧表再注册新表） */
public class HotkeyModel {
    public let keys: ArrayList<Hotkey>

    public init(keys: ArrayList<Hotkey>) {
        this.keys = keys
    }

    /** 便捷构造：可变参数式逐条 add */
    public init() {
        this.keys = ArrayList<Hotkey>()
    }

    public func add(accel: String, id: String): HotkeyModel {
        this.keys.add(Hotkey(accel, id))
        return this
    }

    /** 线路文本（每行 `<accel>:<id>`；空模型给空串 = 全部注销） */
    public func toWire(): String {
        let sb = StringBuilder()
        var first = true
        for (k in this.keys) {
            if (k.accel.contains(":") || k.accel.contains("\n") ||
                k.id.contains(":") || k.id.contains("\n")) {
                continue // 非法字段整条出局：wire 的分隔符就是这两个字符
            }
            if (!first) {
                sb.append("\n")
            }
            first = false
            sb.append(k.accel)
            sb.append(":")
            sb.append(k.id)
        }
        return sb.toString()
    }
}
