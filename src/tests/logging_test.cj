package cjTauri.tests

import cjTauri.*
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
