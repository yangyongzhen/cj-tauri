package cli

import std.collection.*

/**
 * 清单 `[links]` 段（各目标端追加链接选项）的解析 / 渲染 / 校验用例
 *
 * 放在**根包内**而不是 `src/tests/` 子包：本工程 `output-type = "executable"`，
 * 子包 import 根包会被 cjpm 当场拒绝（`root package is not compiled as a lib`），
 * 实测 2026-10-24。这也是本仓框架包（lib）与 CLI 包（exe）测试落点的差异。
 *
 * 这组用例守三条不变量：
 * ① **未写时零影响**——老工程升级 CLI 后生成物不变，`cj-tauri check` 不该判漂移；
 * ② **写了则追加**——用户库拼在框架默认值之后，而不是把它顶掉；
 * ③ **三端互相独立**——写一个目标端不影响另外两个。
 */

// 最小可校验清单：validate 要求 id/name/version/package 齐全，缺了会引入噪声错误
private let LINKS_APP_BASE = "[app]\n" +
    "  id = \"com.example.links\"\n" +
    "  name = \"links\"\n" +
    "  version = \"1.0.0\"\n" +
    "  package = \"links\"\n"

private func linksHasErr(errs: ArrayList<String>, needle: String): Bool {
    for (e in errs) {
        if (e.contains(needle)) {
            return true
        }
    }
    return false
}

/** ① 未写 [links]：字段全空，渲染物与加入本能力之前一致（不含用户库） */
@Test
func linksAbsentKeepsFrameworkDefault(): Unit {
    let m = Manifest.fromToml(LINKS_APP_BASE, "test")
    @Expect(m.linkOhos == "")
    @Expect(m.linkDesktopLinux == "")
    @Expect(m.linkDesktopWindows == "")
    let toml = m.renderOhosEntryToml("/fw", "2.0.0")
    // 框架默认值原样收尾，没有多出空格或空项
    @Expect(toml.contains("-lpasteboard -ludmf\""))
    @Expect(!toml.contains("lohbattery"))
}

/** ② 写了 [links]：用户库追加在框架默认值之后 */
@Test
func linksAppendedAfterDefault(): Unit {
    let m = Manifest.fromToml(LINKS_APP_BASE + "[links]\n  ohos = \"-lohbattery_info\"\n", "test")
    @Expect(m.linkOhos == "-lohbattery_info")
    let toml = m.renderOhosEntryToml("/fw", "2.0.0")
    @Expect(toml.contains("-lpasteboard -ludmf -lohbattery_info\""))
    @Expect(m.validate().size == 0)
}

/** ③ 桌面两端各自独立：只写 linux 时 windows 段保持默认 */
@Test
func linksAreScopedPerTarget(): Unit {
    let m = Manifest.fromToml(LINKS_APP_BASE + "[links]\n  desktop-linux = \"-lcamera\"\n", "test")
    @Expect(m.linkDesktopWindows == "")
    let toml = m.renderDesktopToml("/fw", "2.0.0")
    // linux 段带上用户库，windows 段仍是默认收尾
    @Expect(toml.contains("-lcamera\""))
    @Expect(toml.contains("-lcjtbridge --subsystem=windows\""))
}

/** 非法值（双引号）必须被 validate 拦下：拼进生成 toml 会造出坏文件 */
@Test
func linksRejectsDoubleQuote(): Unit {
    let m = Manifest.fromToml(LINKS_APP_BASE + "[links]\n  ohos = -lfoo\"bar\n", "test")
    let errs = m.validate()
    @Expect(errs.size > 0)
    @Expect(linksHasErr(errs, "不能含双引号"))
}

/** 未知键要报错：清单由本 CLI 生态生成与消费，拼错键应在 check 期暴露 */
@Test
func linksRejectsUnknownKey(): Unit {
    var thrown = false
    try {
        let _ = Manifest.fromToml(LINKS_APP_BASE + "[links]\n  ohosx = \"-lfoo\"\n", "test")
    } catch (e: Exception) {
        thrown = true
    }
    @Expect(thrown)
}
