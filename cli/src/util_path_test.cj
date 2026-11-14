package cli

import std.collection.*

/**
 * 框架路径的「取出来 → 写进骨架」这条链路的用例（issue #10）
 *
 * 守两条不变量：
 * ① **业务包里的 TOML 转义要还原**——`cjpm.toml` 写的是 `path = "E:\\test\\a"`，
 *    读出来必须是 `E:\test\a`；不还原就会一路变成 `E://test//a` 写进 targets/；
 * ② **渲染/toTomlPath 要把重复分隔符合并**——老骨架里已经躺着 `E://test//a`，
 *    只归一化期望值的话，这些工程会被永久判漂移、且重跑 sync 也「看着没修好」。
 *
 * 放在根包内（同 `manifest_test.cj`）：CLI 是 executable 工程，子包 import 根包会被 cjpm 拒绝。
 */

/** 按字节把字符串塞进 ArrayList（`pathFromCjTauriLine` 收的就是这种行缓冲） */
private func lineBytes(s: String): ArrayList<Byte> {
    let out = ArrayList<Byte>()
    for (b in s) {
        out.add(b)
    }
    return out
}

@Test
func toTomlPathCollapsesRepeatedSeparators(): Unit {
    // 老骨架写出来的形状：每个分隔符都翻了倍
    @Expect(toTomlPath("E://test//harmonyos//test//cj-tauri") == "E:/test/harmonyos/test/cj-tauri")
    @Expect(toTomlPath("/a///b////c") == "/a/b/c")
}

@Test
func toTomlPathConvertsBackslashAndIsIdempotent(): Unit {
    @Expect(toTomlPath("E:\\test\\a") == "E:/test/a")
    let once = toTomlPath("E://test//a")
    @Expect(toTomlPath(once) == once)   // 幂等：再跑一遍不会再变
}

@Test
func toTomlPathKeepsUncPrefix(): Unit {
    // 开头两个分隔符是 UNC（Windows 共享路径；Linux 上 `//x` 也是绝对路径），不能合并掉
    @Expect(toTomlPath("//server/share//a") == "//server/share/a")
}

@Test
func bizDeclarationUnescapesTomlBackslashes(): Unit {
    // 业务包 cjpm.toml 的原文（TOML 基本串里 `\` 必须转义）
    match (pathFromCjTauriLine(lineBytes("  cjTauri = { path = \"E:\\\\test\\\\a\" }"))) {
        case Some(p) => @Expect(p == "E:\\test\\a")
        case None => @Expect(false)
    }
    // 正斜杠写法原样返回（不必动）
    match (pathFromCjTauriLine(lineBytes("  cjTauri = { path = \"E:/test/a\" }"))) {
        case Some(p) => @Expect(p == "E:/test/a")
        case None => @Expect(false)
    }
}

@Test
func bizDeclarationKeepsUnknownEscapes(): Unit {
    // 只认 `\\` 与 `\"`：其它 `\x` 原样留着，别把用户路径里的字符吃掉
    match (pathFromCjTauriLine(lineBytes("  cjTauri = { path = \"a\\nb\" }"))) {
        case Some(p) => @Expect(p == "a\\nb")
        case None => @Expect(false)
    }
    // 没有 cjTauri 这一行 → None（交给 resolveFrameworkRoot 兜底）
    match (pathFromCjTauriLine(lineBytes("  other = \"x\""))) {
        case Some(_) => @Expect(false)
        case None => @Expect(true)
    }
}
