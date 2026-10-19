package cjTauri.tests

import cjTauri.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * JS 字符串字面量转义的用例（鸿蒙 ArkWeb 侧的 label 注入靠它）。
 *
 * 为什么值得单独测：这段逻辑的失效形状是**静默的**——生成的脚本当场语法错误，
 * 页面里 `__CJ_TAURI_LABEL__` 停在默认值 `main`，于是「按 label 过滤的事件」全部失灵，
 * 而宿主与页面两边都不报错（AGENTS §4 同族坑）。原先它带 `@When[env == "ohos"]`
 * 门禁、桌面 `cjpm test` 编不到，所以下沉到共享层后必须在这里锁住。
 *
 * 断言取**字符层面**的期望值（`\"` 就是两个字符：反斜杠 + 引号），
 * 不整体比对拼好的脚本——那样改一改前缀就得连带改一堆测试。
 */

@Test
func testJsStringLiteralWrapsPlainText(): Unit {
    @Expect(jsStringLiteral("main"), "\"main\"")
}

@Test
func testJsStringLiteralEscapesDoubleQuote(): Unit {
    // 不转义的话 label 一变就提前收敛，脚本变成 `= "a";b";` —— 语法错误
    @Expect(jsStringLiteral("a\"b"), "\"a\\\"b\"")
}

@Test
func testJsStringLiteralEscapesBackslash(): Unit {
    // Windows 风格 label / 路径片段带反斜杠：不转义会把后一个字符一起吃掉
    @Expect(jsStringLiteral("a\\b"), "\"a\\\\b\"")
}

@Test
func testJsStringLiteralKeepsUtf8Bytes(): Unit {
    // 按字节扫，汉字不能被拆分或改写（三字节序列原样带过）
    @Expect(jsStringLiteral("窗口"), "\"窗口\"")
}

@Test
func testJsStringLiteralHandlesEmptyString(): Unit {
    @Expect(jsStringLiteral(""), "\"\"")
}

@Test
func testJsStringLiteralCombinesQuoteAndBackslash(): Unit {
    // 两者相邻时最容易漏转义：期望 `"` `\` `\` `"` `\` `\` ...` 严格交错
    @Expect(jsStringLiteral("\"\\"), "\"\\\"\\\\\"")
}

@Test
func testJsStringLiteralLeavesOtherControlCharsAlone(): Unit {
    // 口径是「只转义反斜杠与双引号」：制表符 / 换行不属于 label 语义，
    // 这里断言**不**做额外加工，避免将来有人把它改成全量 JSON 编码器而悄悄改变契约
    let tab = "\t"
    let got = jsStringLiteral(tab)
    // 未转义 = 长度只多出两侧引号（2 + 1 字节的制表符）
    @Expect(got.size, 3)
    @Expect(got.contains("\t"), true)
}
