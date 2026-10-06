package cjTauri.tests

import cjTauri.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * shell 事件信封的解析与语义映射（RFC-002 §5.5 / §5.6）。
 *
 * 为什么值得单独钉：信封格式坏掉的表现是「点了菜单，事件静默不到前端」——实机只能看见
 * 「什么都没发生」。解析与映射是纯函数，在这一层锁住，实机就只剩「桥有没有把事件送上来」一件事。
 * 期望值与 C 侧字面量成对维护：native/bridge_core.c 的 cj_core_menu_clicked()。
 */

@Test
func testShellEventNameForKnownKinds(): Unit {
    @Expect(shellEventNameFor("menu").getOrThrow(), "menu:click")
    @Expect(shellEventNameFor("tray").getOrThrow(), "tray:click")
    @Expect(shellEventNameFor("drop").getOrThrow(), "dragdrop:files")
}

@Test
func testShellEventNameForUnknownKindIsNone(): Unit {
    // 不认识的 kind 不抛异常：调用方提示一句后丢弃（异常穿 FFI 边界代价更大）
    @Expect(shellEventNameFor("ghost").isNone(), true)
    @Expect(shellEventNameFor("").isNone(), true)
}

@Test
func testParseShellEnvelopeReadsMenuClick(): Unit {
    let env = parseShellEnvelope(
        "{\"kind\":\"menu\",\"id\":\"file.save\",\"enabled\":true,\"checked\":false}")
    @Expect(env.isSome(), true)
    let obj = env.getOrThrow()
    @Expect(shellString(obj, "kind").getOrThrow(), "menu")
    @Expect(shellString(obj, "id").getOrThrow(), "file.save")
    @Expect(shellBool(obj, "enabled").getOrThrow(), true)
    @Expect(shellBool(obj, "checked").getOrThrow(), false)
}

@Test
func testParseShellEnvelopeRejectsMalformed(): Unit {
    // 非 JSON / 顶层不是对象 / 空串：一律 None，不抛
    @Expect(parseShellEnvelope("garbage").isNone(), true)
    @Expect(parseShellEnvelope("[1,2,3]").isNone(), true)
    @Expect(parseShellEnvelope("\"menu\"").isNone(), true)
    @Expect(parseShellEnvelope("").isNone(), true)
}

@Test
func testShellFieldReadersRejectWrongTypesAndMissingKeys(): Unit {
    let obj = parseShellEnvelope("{\"id\":7,\"enabled\":\"true\"}").getOrThrow()
    // 类型不对当缺失处理：id 是数字不是字符串、enabled 是字符串不是布尔
    @Expect(shellString(obj, "id").isNone(), true)
    @Expect(shellBool(obj, "enabled").isNone(), true)
    // 缺字段同样是 None——缺 enabled/checked 宁可不写模型，也不能拿默认值顶（见 shellBool 注释）
    @Expect(shellString(obj, "missing").isNone(), true)
    @Expect(shellBool(obj, "missing").isNone(), true)
}

@Test
func testShellEnvelopeSurvivesEscapedId(): Unit {
    // C 桥对 id 里的 \ 与 " 做最小转义（bridge_core.c 的 cj_json_escape_into），
    // 转义后仍是合法 JSON：解析回来必须是原字符串
    let obj = parseShellEnvelope("{\"kind\":\"menu\",\"id\":\"a\\\"b\"}").getOrThrow()
    @Expect(shellString(obj, "id").getOrThrow(), "a\"b")
}
