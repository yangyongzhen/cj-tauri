package cjTauri.tests

import cjTauri.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 日志落盘的策略层用例（RFC-003 第 5 期）。
 *
 * 只测**纯函数**（默认目录推导、环境变量回退、路径拼接）：真的开 fd 那一段归桩自检
 * （`native/tests/test_bridge_core.c` 的 `log file` 用例）与实机 E2E——单测里调桥的
 * `foreign func` 会踩「子包调不了 foreign func」那条（AGENTS §4，链接期报未定义符号）。
 *
 * 环境变量类的用例一律用**肯定不存在**的变量名：跑测试的机器上 `CJ_TAURI_LOG` 之类
 * 可能真的设着，拿它当「未设置」来断言就是一条会随机器飘的红线。
 */

/** 保证不存在的变量名（前缀统一，便于将来 grep） */
let ABSENT_LOG_ENV: String = "CJ_TAURI_LOG_TEST_ABSENT"

@Test
func testLogEnvFallsBackWhenVariableMissing(): Unit {
    @Expect(logEnvOr(ABSENT_LOG_ENV, "dflt"), "dflt")
}

@Test
func testLogBudgetFallsBackWhenVariableMissing(): Unit {
    @Expect(logBudgetFromEnv(ABSENT_LOG_ENV, 7), 7)
    // 0 与负数在调用方语义里是「不轮转」，不是「用 0 当默认」——回退值原样带回
    @Expect(logBudgetFromEnv(ABSENT_LOG_ENV, 0), 0)
}

@Test
func testDefaultLogPathUsesAppNameAndPlatformDir(): Unit {
    let p = defaultLogPath("music")
    // 分隔符按平台给，所以不整体比对路径；钉的是「文件名 = 应用名」、「落在 cj-tauri 目录下」
    @Expect(p.endsWith("music.log"), true)
    @Expect(p.contains("cj-tauri"), true)
    // 应用没给名字时走兜底：不能拼出没有主名的 ".log"
    @Expect(defaultLogPath("").endsWith("app.log"), true)
}

@Test
func testDefaultLogDirIsNonEmptyAndConventional(): Unit {
    let d = defaultLogDir()
    @Expect(d.size > 0, true)
    @Expect(d.contains("cj-tauri"), true)
    // 默认预算是个能落地的值：>0 才会轮转，keep>0 才有档案可留
    @Expect(CJ_LOG_DEFAULT_MAX_KB > 0, true)
    @Expect(CJ_LOG_DEFAULT_KEEP > 0, true)
}

@Test
func testLogPathOrDefaultPrefersEnvOverPlatformDir(): Unit {
    // 报障路径优先：环境变量给了路径就用它，平台惯例目录被忽略（人家不必知道目录在哪）
    @Expect(logPathOrDefault("/tmp/from-env.log", "music"), "/tmp/from-env.log")
    // 空串＝未设置，才落平台惯例目录，文件名跟应用名走（与 logEnvOr 同口径）
    let d = logPathOrDefault("", "music")
    @Expect(d.endsWith("music.log"), true)
    @Expect(d.contains("cj-tauri"), true)
    @Expect(d == defaultLogPath("music"), true)
}

/*
 * 鸿蒙 hilog 分片器（2026-11-12）：hilog 对单条日志有长度上限，框架的超长诊断行要切多条送出去。
 * 分片器与平台无关、无 FFI 依赖，所以在本机能验——鸿蒙分支其余部分编不了（本机 SDK 只有
 * linux / windows 两个目标），能本地验证的部分别留成「未验证」。
 */

@Test
func testHilogSplitKeepsShortLineIntact(): Unit {
    @Expect(hilogSplit("", 1000).size, 1)
    @Expect(hilogSplit("", 1000)[0], "")
    @Expect(hilogSplit("abc", 1000).size, 1)
    // 恰好等于预算也是单片：不因「相等」多切一条空的出来
    @Expect(hilogSplit("abcdefgh", 8).size, 1)
}

@Test
func testHilogSplitChunksLongAsciiLine(): Unit {
    let sb = StringBuilder()
    for (_ in 0..2500) {
        sb.append("x")
    }
    let line = sb.toString()
    let parts = hilogSplit(line, 1000)
    @Expect(parts.size, 3)
    var joined = ""
    for (p in parts) {
        @Expect(p.size <= 1000, true)
        joined = joined + p
    }
    @Expect(joined, line) // 不丢内容、不改内容：取证要对得上原文
}

@Test
func testHilogSplitNeverCutsInsideUtf8Char(): Unit {
    // 400 个汉字 = 1200 字节；1000 字节预算硬切就落在第 334 个汉字中间
    let sb = StringBuilder()
    for (_ in 0..400) {
        sb.append("汉")
    }
    let line = sb.toString()
    let parts = hilogSplit(line, 1000)
    @Expect(parts.size, 2)
    var joined = ""
    for (p in parts) {
        // 分片器内部走 String.fromUtf8（非法 UTF-8 会抛），这里再钉住两条可观测性质
        @Expect(p.size <= 1000, true)
        @Expect(p.size % 3, 0) // 汉字 3 字节：每片都落在整字边界上
        joined = joined + p
    }
    @Expect(joined, line)
}

@Test
func testHilogSplitSurvivesTinyBudget(): Unit {
    // 预算比一个汉字还小：按 4 字节下限走，仍须是合法 UTF-8 且能拼回原文
    let line = "仓颉日志"
    let parts = hilogSplit(line, 2)
    var joined = ""
    for (p in parts) {
        joined = joined + p
    }
    @Expect(joined, line)
    @Expect(parts.size > 0, true)
}
