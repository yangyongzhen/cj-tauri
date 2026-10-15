package cjTauri

import std.collection.*

/**
 * 托盘的**纯仓颉模型**（RFC-002 §5.1 / §7.C）：只描述意图，不含任何平台概念。
 *
 * 分层与菜单同构：模型（本文件）→ `WebViewHost.setTray()` → C 桥 `cj_bridge_set_tray` →
 * 平台翻译层（Linux = libayatana-appindicator3，可选编译；Windows 桩如实报未实现）。
 *
 * 托盘是**应用级**资源（一个进程一个图标）：重复 setTray = 整体重建（图标 / 提示 / 菜单一起换）；
 * 空线路 = 移除托盘。菜单项复用 `MenuItem`（v1 只收 Normal / Checkbox / Separator，
 * Submenu 整条跳过并打 stderr——托盘菜单平铺，别给子菜单）。
 *
 * 线路格式（与 `native/core/bridge_core.h` 的 `pending_tray` 注释逐字对应）：
 *
 *     icon\t<路径>\n        （空路径 = 平台用主题默认图标兜底）
 *     tooltip\t<文本>\n
 *     <kind>\t<id>\t<label>\t<flags>\t<accel>\n   （与菜单线路同格式，平铺一层）
 *
 * 菜单项被点以 `{"kind":"tray","id":"…"}` 走 shell 通道回投（前端事件 `tray:click`，
 * 需在能力清单 `events` 声明）。图标 / 提示文本来自应用作者，不做转义；
 * 字段含制表符 / 换行的头部值整体丢弃为空（wire 的结构字符，与菜单同一铁律）。
 */
public class TrayModel {
    /** 图标路径（png/ico 绝对路径）；空串 = 平台用主题默认图标兜底 */
    public let icon: String

    /** 悬停提示文本；空串 = 不设 */
    public let tooltip: String

    /** 托盘右键菜单（平铺一层；Submenu 项会被 toWire 丢弃并打 stderr） */
    public let items: ArrayList<MenuItem>

    public init(icon: String, tooltip: String, items: ArrayList<MenuItem>) {
        this.icon = icon
        this.tooltip = tooltip
        this.items = items
    }

    /** 无菜单托盘（纯图标 + 提示） */
    public init(icon: String, tooltip: String) {
        this.icon = icon
        this.tooltip = tooltip
        this.items = ArrayList<MenuItem>()
    }

    /** 线路文本（三段：icon 行 / tooltip 行 / 菜单行走 MenuModel.emit 同一遍发射器） */
    public func toWire(): String {
        // 托盘菜单平铺：Submenu 整条出局（枚举不能写 ==，AGENTS §4，走 match）
        let flat = ArrayList<MenuItem>()
        for (it in this.items) {
            if (TrayModel.isSubmenu(it.kind)) {
                eprintln("[cj-tauri] tray: submenu item dropped (v1 tray menu is flat): ${it.label}")
                continue
            }
            flat.add(it)
        }
        // 头部两行的结构字符会让整份线路解析错位：宁可丢提示也不装错
        var icon = this.icon
        var tooltip = this.tooltip
        if (TrayModel.hasStructChar(icon) || TrayModel.hasStructChar(tooltip)) {
            eprintln("[cj-tauri] tray: icon/tooltip contains tab or newline - dropped to empty")
            icon = ""
            tooltip = ""
        }
        var out = "icon\t" + icon + "\n"
        out += "tooltip\t" + tooltip + "\n"
        out += MenuModel.emit(flat, 0)
        return out
    }

    /** 枚举判别只能走 match（`==` 编译不过，见 MenuModel.isSubmenu 的实测注释） */
    private static func isSubmenu(kind: MenuItemKind): Bool {
        match (kind) {
            case MenuItemKind.Submenu => true
            case _ => false
        }
    }

    /** 结构字符（tab/LF/CR）检查——wire 的分隔符就是它们 */
    private static func hasStructChar(s: String): Bool {
        for (b in s) {
            if (b == 9u8 || b == 10u8 || b == 13u8) {
                return true
            }
        }
        return false
    }
}
