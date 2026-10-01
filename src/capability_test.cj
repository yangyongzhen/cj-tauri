package cjTauri

import std.collection.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 能力安全模型单元测试：默认最小权限是框架的核心承诺，
 * 这里锁住「未声明一律拒绝」「声明了才放行」「畸形清单不炸」三条行为。
 */

@Test
func testFromJsonParsesAllFields(): Unit {
    let raw = "{\"identifier\":\"default\",\"windows\":[\"main\"],\"commands\":[\"greet\",\"system:ping\"],\"events\":[\"tick\"]}"
    let cap = Capability.fromJson(JsonValue.fromStr(raw))
    @Expect(cap.isSome(), true)
    let c = cap.getOrThrow()
    @Expect(c.identifier, "default")
    @Expect(c.commands.size, 2)
    @Expect(c.canInvoke("greet"), true)
    @Expect(c.canInvoke("system:ping"), true)
    @Expect(c.canEmit("tick"), true)
    @Expect(c.windows.size, 1)
}

@Test
func testFromJsonDefaultsToDenyAll(): Unit {
    // 只给 identifier：清单合法但什么都不放行（默认最小权限）
    let cap = Capability.fromJson(JsonValue.fromStr("{\"identifier\":\"empty\"}"))
    @Expect(cap.isSome(), true)
    let c = cap.getOrThrow()
    @Expect(c.canInvoke("greet"), false)
    @Expect(c.canEmit("tick"), false)
    @Expect(c.commands.size, 0)
    @Expect(c.events.size, 0)
}

@Test
func testFromJsonRejectsInvalidShape(): Unit {
    // 顶层不是对象
    @Expect(Capability.fromJson(JsonValue.fromStr("[1,2]")).isNone(), true)
    // 缺 identifier
    @Expect(Capability.fromJson(JsonValue.fromStr("{\"commands\":[\"a\"]}")).isNone(), true)
    // identifier 不是字符串
    @Expect(Capability.fromJson(JsonValue.fromStr("{\"identifier\":7}")).isNone(), true)
    // commands 不是数组：宽容跳过，清单本身仍合法（放行集合为空）
    let lenient = Capability.fromJson(JsonValue.fromStr("{\"identifier\":\"x\",\"commands\":\"greet\"}"))
    @Expect(lenient.isSome(), true)
    @Expect(lenient.getOrThrow().canInvoke("greet"), false)
    // 注：非 JSON 文本在 JsonValue.fromStr 处就抛 JsonException，进不到 fromJson；
    // 这层防护在调用方——InvokeRequest.parse 与 capability_loader 的 try 里（前者见 ipc 测试）。
}

@Test
func testFromJsonSkipsNonStringEntries(): Unit {
    // 数组里混入数字/对象：跳过而不是整体失败
    let raw = "{\"identifier\":\"mixed\",\"commands\":[\"ok\",7,{\"a\":1}],\"events\":[true,\"tick\"]}"
    let cap = Capability.fromJson(JsonValue.fromStr(raw))
    @Expect(cap.isSome(), true)
    let c = cap.getOrThrow()
    @Expect(c.canInvoke("ok"), true)
    @Expect(c.commands.size, 1)
    @Expect(c.canEmit("tick"), true)
    @Expect(c.events.size, 1)
}

@Test
func testRegistryAggregatesCapabilities(): Unit {
    let reg = CapabilityRegistry()
    let a = Capability("a")
    a.allowCommand("greet")
    let b = Capability("b")
    b.allowCommand("system:ping")
    b.allowEvent("tick")
    reg.add(a)
    reg.add(b)
    @Expect(reg.size(), 2)
    // 任一清单放行即通过
    @Expect(reg.canInvoke("greet"), true)
    @Expect(reg.canInvoke("system:ping"), true)
    // 都没声明的一律拒绝
    @Expect(reg.canInvoke("system:echo"), false)
    @Expect(reg.canEmit("tick"), true)
    @Expect(reg.canEmit("other"), false)
}

@Test
func testRegistryEmptyDeniesEverything(): Unit {
    let reg = CapabilityRegistry()
    @Expect(reg.canInvoke("system:version"), false)
    @Expect(reg.canEmit("tick"), false)
    @Expect(reg.size(), 0)
}

@Test
func testRegistryAddFromJson(): Unit {
    let reg = CapabilityRegistry()
    let ok = reg.addFromJson(JsonValue.fromStr("{\"identifier\":\"x\",\"commands\":[\"greet\"]}"))
    @Expect(ok, true)
    @Expect(reg.canInvoke("greet"), true)
    // 畸形清单：返回 false 且不影响已有能力
    let bad = reg.addFromJson(JsonValue.fromStr("{\"nope\":1}"))
    @Expect(bad, false)
    @Expect(reg.size(), 1)
    @Expect(reg.canInvoke("greet"), true)
}

@Test
func testLoaderToleratesMissingDir(): Unit {
    // 目录不存在不是错误：返回 0，注册表保持为空（首次放到没有 capabilities/ 的目录里跑就是这样）
    let reg = CapabilityRegistry()
    @Expect(loadCapabilitiesFromDir("no/such/capabilities/dir", reg), 0)
    @Expect(reg.size(), 0)
}
