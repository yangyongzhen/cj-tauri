package cjTauri.tests

import cjTauri.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 菜单模型的线路格式测试（RFC-002 §5.4）。
 * 线路格式是仓颉侧与 C 桥之间唯一的契约，所以这里**锁字节**：字段顺序、层级缩进、flags 编码，
 * 以及「非法字段整项出局」这条口径——它决定了 C 侧能不能不做转义。
 */

@Test
func testMenuWireNormalItem(): Unit {
    let items = ArrayList<MenuItem>()
    items.add(MenuItem.normal("file.open", "打开"))
    @Expect(MenuModel(items).toWire(), "n\tfile.open\t打开\t1\t\n")
}

@Test
func testMenuWireSeparatorAlsoKeepsFiveFields(): Unit {
    // 分隔线的 id / label 为空，但字段数不变：C 侧解析不用为它开特例
    let items = ArrayList<MenuItem>()
    items.add(MenuItem.separator())
    @Expect(MenuModel(items).toWire(), "s\t\t\t1\t\n")
}

@Test
func testMenuWireSubmenuIndentsChildrenAndEncodesFlags(): Unit {
    let children = ArrayList<MenuItem>()
    children.add(MenuItem.checkbox("view.sidebar", "侧栏", true))
    children.add(MenuItem.normalWithAccel("view.zoom", "放大", "Ctrl+="))
    let items = ArrayList<MenuItem>()
    items.add(MenuItem.submenu("视图", children))
    // 子项行首多一个制表符 = 层级 1；勾选项 flags=3（可用 + 勾选）
    @Expect(MenuModel(items).toWire(),
        "m\t\t视图\t1\t\n" +
        "\tc\tview.sidebar\t侧栏\t3\t\n" +
        "\tn\tview.zoom\t放大\t1\tCtrl+=\n")
}

@Test
func testMenuWireDisabledItemEncodesFlagZero(): Unit {
    let item = MenuItem.normal("file.save", "保存")
    item.enabled = false
    let items = ArrayList<MenuItem>()
    items.add(item)
    @Expect(MenuModel(items).toWire(), "n\tfile.save\t保存\t0\t\n")
}

@Test
func testMenuWireDropsItemWithNewlineInLabel(): Unit {
    // 标签里换行会破坏「一行一项」：该整项出局，其余项照常出口
    let items = ArrayList<MenuItem>()
    items.add(MenuItem.normal("bad", "两行\n标签"))
    items.add(MenuItem.normal("good", "正常"))
    @Expect(MenuModel(items).toWire(), "n\tgood\t正常\t1\t\n")
}

@Test
func testMenuWireDropsItemWithTabInId(): Unit {
    let items = ArrayList<MenuItem>()
    items.add(MenuItem.normal("a\tb", "标签"))
    @Expect(MenuModel(items).toWire(), "")
}

@Test
func testMenuWireNestedSubmenuGoesTwoLevels(): Unit {
    let inner = ArrayList<MenuItem>()
    inner.add(MenuItem.normal("a.b.c", "三层"))
    let mid = ArrayList<MenuItem>()
    mid.add(MenuItem.submenu("二层", inner))
    let items = ArrayList<MenuItem>()
    items.add(MenuItem.submenu("一层", mid))
    @Expect(MenuModel(items).toWire(),
        "m\t\t一层\t1\t\n" +
        "\tm\t\t二层\t1\t\n" +
        "\t\tn\ta.b.c\t三层\t1\t\n")
}
