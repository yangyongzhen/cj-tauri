package cjTauri

/**
 * ArkWeb 宿主的菜单模型与线路格式解析（`@When[env == "ohos"]` 门禁）
 *
 * ## 为什么鸿蒙的菜单要「框架存模型、应用侧画」
 *
 * 桌面两平台的菜单由**宿主自己**画（Win32 `CreateMenu` / GTK `GtkMenuBar`），线路格式的解析在
 * C 桥的 `cj_core_menu_walk` 里。鸿蒙没有「宿主菜单栏」这种东西：ArkWeb 的仓颉绑定只给了
 * **组件级**的 `bindMenu`，而**框架包不许引用 ArkUI**（AGENTS §4：框架作为独立编译单元引用
 * `kit.ArkUI` 会让鸿蒙包初始化链跳坏地址，启动即 SIGSEGV）。于是分工只能是：
 *
 *   - 框架侧（本文件 + [ArkWebHost]）：把应用给的线路格式解析成**快照**，并留一个「某项被点了」
 *     的回投入口；
 *   - 应用侧（`ArkWebView` 样板）：用 `bindMenu` 把快照画出来，点击时调 `noteMenuClick`。
 *
 * 这与 dialog 的落法同源（框架入队 / 应用侧声明式渲染），也是**唯一**同时满足「框架不碰 ArkUI」
 * 与「菜单真的能点」的形状。判据在 `docs/鸿蒙ArkWeb接入踩坑.md` §10.11（声明式 overlay 那轮）。
 *
 * ## 线路格式
 *
 * 与 `src/menu.cj` 的 `MenuModel.toWire()` 逐字对应（同一份格式，别在鸿蒙侧另发明一种）：
 *
 *     <tabs><kind>\t<id>\t<label>\t<flags>\t<accel>\n
 *
 * `kind`：`n` 普通 / `c` 勾选 / `s` 分隔线 / `m` 子菜单；`flags` 十进制，bit0 = 可用、bit1 = 勾选。
 * 容错口径照 C 侧那遍解析（[cj_core_menu_walk]）：缺字段按空串 / 0，kind 为空的行整行跳过。
 */
@When[env == "ohos"]
import std.collection.ArrayList

/**
 * 一项菜单（快照）。
 *
 * 字段全是快照值：UI 线程拿到的是 [ArkWebHost.menuModel] 给的副本，改它不会影响宿主里的模型
 * （两边共享同一批可变对象会变成跨线程数据竞争）。
 */
@When[env == "ohos"]
public class ArkWebMenuItem {
    /** 线路格式的 kind 码：`n` / `c` / `s` / `m` */
    public let kind: String

    /** 应用给的稳定 id（回投与 `setMenuItemState` 的查找键）；分隔线为空串 */
    public let id: String

    public let label: String

    public var enabled: Bool

    public var checked: Bool

    /** 仅子菜单（kind = `m`）会填；其它 kind 恒为空表 */
    public let children: ArrayList<ArkWebMenuItem>

    public init(kind: String, id: String, label: String, enabled: Bool, checked: Bool,
                children: ArrayList<ArkWebMenuItem>) {
        this.kind = kind
        this.id = id
        this.label = label
        this.enabled = enabled
        this.checked = checked
        this.children = children
    }

    public func isSubmenu(): Bool {
        return this.kind == "m"
    }

    public func isCheckbox(): Bool {
        return this.kind == "c"
    }

    public func isSeparator(): Bool {
        return this.kind == "s"
    }

    /** 深拷贝：交给 UI 线程的快照（见类注释里的跨线程口径） */
    public func snapshot(): ArkWebMenuItem {
        let copyChildren = ArrayList<ArkWebMenuItem>()
        for (child in this.children) {
            copyChildren.add(child.snapshot())
        }
        return ArkWebMenuItem(this.kind, this.id, this.label, this.enabled, this.checked, copyChildren)
    }

    /** 按 id 找一项（含子孙），找不到回 None——`setMenuItemState` 的查找键 |
     */
    public func find(id: String): Option<ArkWebMenuItem> {
        if (this.id == id && !this.isSeparator()) {
            return Some(this)
        }
        for (child in this.children) {
            match (child.find(id)) {
                case Some(hit) => return Some(hit)
                case None => ()
            }
        }
        return None
    }
}

/**
 * 解析菜单线路格式 → 根列表（depth 0 的项）。
 *
 * 逐字节扫：`\n` 断行、`\t` 断字段、行首 `\t` 数即层级。跳级的行按「挂到当前最深可用层」容错
 * （线路来自应用，坏了只该少画一项，不该让宿主抛异常）。
 */
@When[env == "ohos"]
public func parseArkWebMenuWire(wire: String): ArrayList<ArkWebMenuItem> {
    let root = ArrayList<ArkWebMenuItem>()
    if (wire.size == 0) {
        return root
    }
    /* stack[d] = 第 d 层的挂载容器：stack[0] 是根，stack[d+1] 是上一个子菜单项的子表 */
    let stack = ArrayList<ArrayList<ArkWebMenuItem>>()
    stack.add(root)
    let bytes = wire.toArray()
    var i: Int64 = 0
    while (i < bytes.size) {
        var end = i
        while (end < bytes.size && bytes[end] != 10u8) {
            end++
        }
        var depth: Int64 = 0
        var p = i
        while (p < end && bytes[p] == 9u8) {
            depth++
            p++
        }
        if (p < end) {
            let fields = splitWireFields(wire, bytes, p, end)
            let kind = fields[0]
            if (kind.size > 0) {
                let id = wireField(fields, 1)
                let label = wireField(fields, 2)
                let flags = parseWireFlags(wireField(fields, 3))
                let item = ArkWebMenuItem(kind, id, label, (flags & 1) != 0, (flags & 2) != 0,
                                          ArrayList<ArkWebMenuItem>())
                /* 跳级（depth 大于当前栈深）按最深层挂，少画一层但不错位 */
                var slot = depth
                if (slot >= stack.size) {
                    slot = stack.size - 1
                }
                stack[slot].add(item)
                while (stack.size > slot + 1) {
                    stack.remove(at: stack.size - 1)
                }
                if (item.isSubmenu()) {
                    stack.add(item.children)
                }
            }
        }
        i = end + 1
    }
    return root
}

/* 一行内的字段（最多 5 个）：kind / id / label / flags / accel，缺的按空串（与 C 侧的容错同口径） */
@When[env == "ohos"]
private func splitWireFields(wire: String, bytes: Array<UInt8>, start: Int64, end: Int64): ArrayList<String> {
    let fields = ArrayList<String>()
    var seg = start
    var k = start
    while (k <= end && fields.size < 5) {
        if (k == end || bytes[k] == 9u8) {
            fields.add(wire[seg..k])
            seg = k + 1
        }
        k++
    }
    if (fields.size == 0) {
        fields.add("")
    }
    return fields
}

@When[env == "ohos"]
private func wireField(fields: ArrayList<String>, index: Int64): String {
    if (index < fields.size) {
        return fields[index]
    }
    return ""
}

/* flags 的十进制解析：不引 std.convert（`Int64.parse` 要那个扩展），几个字节自己算，顺带无异常 */
@When[env == "ohos"]
private func parseWireFlags(text: String): Int64 {
    let bytes = text.toArray()
    var value: Int64 = 0
    var seen = false
    for (b in bytes) {
        if (b < 48u8 || b > 57u8) {
            break
        }
        value = value * 10 + Int64(b - 48u8)
        seen = true
        if (value > 65535) {
            return 65535
        }
    }
    if (!seen) {
        return 0
    }
    return value
}
