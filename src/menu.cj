package cjTauri

import std.collection.*

/**
 * 窗口菜单栏的**纯仓颉模型**（RFC-002 §5.1）：只描述意图，不含任何平台概念。
 *
 * 分层：模型（本文件）→ `WebViewHost.setMenu()`（src/host.cj）→ C 桥 `cj_bridge_set_menu` →
 * 平台翻译层（native/bridge_win.c 的 CreateMenu 族 / bridge_linux.c 的 GtkMenuBar）。
 * 菜单文本来自**应用作者**（不是页面可控的不可信输入），所以这里不做转义——
 * 非法字段让那一项出局并出声，而不是写一套转义/反转义。
 */
public enum MenuItemKind {
    | Normal // 普通项：点击回调自己的 id
    | Checkbox // 可勾选项：回调里带 checked
    | Separator // 分隔线：无 id、不可点
    | Submenu // 子菜单：自身不可点，只承载 children
}

public class MenuItem {
    public let id: String
    public let label: String
    public let kind: MenuItemKind
    /** 快捷键**提示**文本（如 "Ctrl+S"）。v1 只显示，不抢页面按键 */
    public let accelerator: String
    public var enabled: Bool
    public var checked: Bool
    /** 仅 Submenu 用；其它 kind 恒为空表 */
    public let children: ArrayList<MenuItem>

    public init(id: String, label: String, kind: MenuItemKind, accelerator: String,
                enabled: Bool, checked: Bool, children: ArrayList<MenuItem>) {
        this.id = id
        this.label = label
        this.kind = kind
        this.accelerator = accelerator
        this.enabled = enabled
        this.checked = checked
        this.children = children
    }

    /** 普通菜单项（最常用） */
    public static func normal(id: String, label: String): MenuItem {
        return MenuItem(id, label, MenuItemKind.Normal, "", true, false, ArrayList<MenuItem>())
    }

    /** 带快捷键提示的普通项 */
    public static func normalWithAccel(id: String, label: String, accelerator: String): MenuItem {
        return MenuItem(id, label, MenuItemKind.Normal, accelerator, true, false, ArrayList<MenuItem>())
    }

    /** 勾选项（初始 checked） */
    public static func checkbox(id: String, label: String, checked: Bool): MenuItem {
        return MenuItem(id, label, MenuItemKind.Checkbox, "", true, checked, ArrayList<MenuItem>())
    }

    /** 子菜单：id 留空（自身不回调），动作交给 children */
    public static func submenu(label: String, children: ArrayList<MenuItem>): MenuItem {
        return MenuItem("", label, MenuItemKind.Submenu, "", true, false, children)
    }

    /** 分隔线 */
    public static func separator(): MenuItem {
        return MenuItem("", "", MenuItemKind.Separator, "", true, false, ArrayList<MenuItem>())
    }
}

/**
 * 菜单模型：`items` 是菜单栏的顶层，子菜单靠 `MenuItem.children` 递归。
 *
 * **不可变**（items 只读）：运行期改状态走 `WebViewHost.setMenuItemState(id, …)`，不在这里改——
 * 状态的真身在平台对象上（Windows 的 HMENU、GTK 的 GtkCheckMenuItem），只改模型平台不会自己变。
 */
public class MenuModel {
    public let items: ArrayList<MenuItem>

    public init(items: ArrayList<MenuItem>) {
        this.items = items
    }

    /**
     * 线路格式（RFC-002 §5.4）：一行一项，字段用制表符分隔，**行首制表符数 = 层级**。
     *
     *     <tabs><kind>\t<id>\t<label>\t<flags>\t<accel>\n
     *
     * kind：`n` 普通 / `c` 勾选 / `s` 分隔线 / `m` 子菜单；
     * flags：十进制，bit0 = 可用、bit1 = 勾选（`3` = 又可用又勾选）；
     * 分隔线与子菜单也走满 5 个字段（id / label / accel 为空），C 侧因此不必为它们开特例。
     *
     * 为什么 kind 放最前：C 侧先分派再取值，日志里一眼能看出这行是什么。
     * 为什么不是 JSON：C 侧（bridge_core.c）是纯 C、不引第三方，行式文本解析几十行就够，
     * 且坏了能直接 `fprintf` 到 stderr（诊断走 stderr 是项目铁律）。JSON 留在仓颉侧给 CLI / 清单用。
     * 为什么不做转义：字段里出现制表符 / 换行会破坏「一行一项」的结构——v1 的口径是
     * **丢弃该项 + stderr 逐项提示**（见 emit），而不是引入转义/反转义这一对必须同时正确的函数。
     */
    public func toWire(): String {
        return MenuModel.emit(this.items, 0)
    }

    private static func emit(items: ArrayList<MenuItem>, depth: Int64): String {
        var out = ""
        for (item in items) {
            if (!MenuModel.wireSafe(item.id) || !MenuModel.wireSafe(item.label) ||
                !MenuModel.wireSafe(item.accelerator)) {
                eprintln("[cj-tauri] menu: item dropped from wire (id/label/accelerator contains tab or newline)")
                continue
            }
            out += MenuModel.tabs(depth) + MenuModel.kindCode(item.kind) + "\t" + item.id + "\t" +
                item.label + "\t" + MenuModel.flags(item).toString() + "\t" + item.accelerator + "\n"
            if (MenuModel.isSubmenu(item.kind)) {
                out += MenuModel.emit(item.children, depth + 1)
            }
        }
        return out
    }

    /**
     * 枚举值**不能用 `==` 比较**（实测：Cangjie 1.2.0 编译期报
     * `invalid binary operator '==' on type 'Enum-MenuItemKind' and 'Enum-MenuItemKind'`），只有 match 能判。
     */
    private static func isSubmenu(kind: MenuItemKind): Bool {
        match (kind) {
            case MenuItemKind.Submenu => true
            case _ => false
        }
    }

    /**
     * 字段里不许有制表符 / 换行 / 回车：它们是线路格式的结构字符。
     * 注意本 SDK 里 `for (cp in someString)` 迭代出的是 **UInt8 字节**（不是 UInt32 码点，AGENTS §4 那条已更正）：
     * 三个结构字符都在 ASCII 范围内，按字节比对既够用、也不受多字节字符影响。
     */
    private static func wireSafe(s: String): Bool {
        for (cp in s) {
            if (cp == 9u8 || cp == 10u8 || cp == 13u8) {
                return false
            }
        }
        return true
    }

    private static func tabs(n: Int64): String {
        var out = ""
        var i = 0
        while (i < n) {
            out += "\t"
            i++
        }
        return out
    }

    private static func kindCode(kind: MenuItemKind): String {
        match (kind) {
            case MenuItemKind.Normal => "n"
            case MenuItemKind.Checkbox => "c"
            case MenuItemKind.Separator => "s"
            case MenuItemKind.Submenu => "m"
        }
    }

    /** flags：bit0 = 可用、bit1 = 勾选（十进制传输，C 侧只要 atoi） */
    private static func flags(item: MenuItem): Int64 {
        var f = 0
        if (item.enabled) {
            f += 1
        }
        if (item.checked) {
            f += 2
        }
        return f
    }
}
