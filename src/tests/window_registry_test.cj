package cjTauri.tests

import cjTauri.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 窗口注册表单测：纯逻辑，不创建窗口，可在无 GUI 环境跑。
 * 两条对外契约借用例钉住：① label 缺省值 "main"（现有示例与探针写死它）；
 * ② labels() 按登记顺序（广播据此保持确定顺序，HashMap 的迭代顺序不保证）。
 */

/** 断言某段调用抛异常（此处要断的是「拒绝」这个行为本身，@Expect 断言不了） */
func thrownBy(body: () -> Unit): Bool {
    try {
        body()
        return false
    } catch (e: Exception) {
        return true
    }
}

func rec(label: String): WindowRecord {
    return WindowRecord(label, FakeHost(label), WindowConfig())
}

@Test
func testRegistryAddAndGet(): Unit {
    let reg = WindowRegistry()
    reg.add(rec("main"))
    @Expect(reg.size(), 1)
    @Expect(reg.get("main").isSome(), true)
    @Expect(reg.get("main").getOrThrow().label, "main")
}

@Test
func testRegistryRejectsDuplicateLabel(): Unit {
    let reg = WindowRegistry()
    reg.add(rec("main"))
    // 覆盖会让「一个 label 挂着两个宿主」静默成立，必须抛
    @Expect(thrownBy({ => reg.add(rec("main")) }), true)
    @Expect(reg.size(), 1)
}

@Test
func testRegistryRejectsEmptyLabel(): Unit {
    let reg = WindowRegistry()
    @Expect(thrownBy({ => reg.add(rec("")) }), true)
    @Expect(reg.size(), 0)
}

@Test
func testRegistryMissingLabelIsNone(): Unit {
    let reg = WindowRegistry()
    @Expect(reg.get("settings").isNone(), true)
}

@Test
func testRegistryLabelsKeepInsertionOrder(): Unit {
    let reg = WindowRegistry()
    reg.add(rec("main"))
    reg.add(rec("settings"))
    reg.add(rec("log"))
    let ls = reg.labels()
    @Expect(ls.size, 3)
    @Expect(ls[0], "main")
    @Expect(ls[1], "settings")
    @Expect(ls[2], "log")
}

@Test
func testRegistryRemoveIsIdempotent(): Unit {
    let reg = WindowRegistry()
    reg.add(rec("main"))
    reg.add(rec("settings"))
    reg.remove("main")
    @Expect(reg.size(), 1)
    @Expect(reg.get("main").isNone(), true)
    // 关窗路径可能重复触发：删不存在的 label 不该抛
    reg.remove("main")
    @Expect(reg.size(), 1)
    let ls = reg.labels()
    @Expect(ls.size, 1)
    @Expect(ls[0], "settings")
}

@Test
func testRecordKeepsConfigSnapshot(): Unit {
    let r = WindowRecord("main", FakeHost("main"), WindowConfig("编辑器", 1024, 768))
    @Expect(r.config.title, "编辑器")
    @Expect(r.config.width, 1024)
    @Expect(r.config.height, 768)
}

@Test
func testTargetsBroadcastKeepsOrder(): Unit {
    let reg = WindowRegistry()
    reg.add(rec("main"))
    reg.add(rec("settings"))
    let ts = reg.targets("")
    @Expect(ts.size, 2)
    @Expect(ts[0].label, "main")
    @Expect(ts[1].label, "settings")
}

@Test
func testTargetsSingleWindow(): Unit {
    let reg = WindowRegistry()
    reg.add(rec("main"))
    reg.add(rec("settings"))
    let ts = reg.targets("settings")
    @Expect(ts.size, 1)
    @Expect(ts[0].label, "settings")
}

@Test
func testTargetsUnknownLabelIsEmpty(): Unit {
    let reg = WindowRegistry()
    reg.add(rec("main"))
    // 未注册的 label 不回落成广播：写错 label 就该听不到，由调用方打日志
    @Expect(reg.targets("nope").size, 0)
}
