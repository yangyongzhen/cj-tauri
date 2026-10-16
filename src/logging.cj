package cjTauri

import std.env.*
import std.convert.*

/**
 * 日志落盘的策略层（RFC-003 第 5 期）：文件放哪、预算多少、环境变量怎么兜底。
 *
 * 落盘本身在 `src/log_bridge.cj`（进程级、无平台分支）；这里只管策略，纯函数 + `@When` 目录推导。
 *
 * 为什么要环境变量兜底：单文件产物是 Windows 的 GUI 子系统、双击时没有控制台，而**已经分发的
 * exe 改不了代码**——让报障的人带上 `CJ_TAURI_LOG` 再启动一次，就能拿到凭证；
 * 不设这些变量时行为与之前**完全一致**（不落盘、stderr 照旧）。
 */

/** 默认预算：256 KB 一份、留 2 份档案（最坏约 1 MB，常驻托盘类应用也吃得消） */
public let CJ_LOG_DEFAULT_MAX_KB: Int64 = 256
public let CJ_LOG_DEFAULT_KEEP: Int64 = 2

/** 应用名缺省值（应用没给名字时用它当文件名） */
public let CJ_LOG_DEFAULT_APP: String = "app"

/**
 * 单行上限（字节）：页面可控的字符串，超了只记一条说明
 *
 * 8 KiB 够放一段异常栈；不设上限的话，一行天文数字能同时把内存与日志文件撑爆，
 * 而这一行本身还未必有诊断价值。
 */
public let CJ_LOG_MAX_LINE: Int64 = 8192

/** 读环境变量（空串按未设置算）。公开只为子包用例可见（子包看不到父包非 public 符号） */
public func logEnvOr(name: String, dflt: String): String {
    if (let Some(v) <- getVariable(name)) {
        if (v.size > 0) {
            return v
        }
    }
    return dflt
}

/**
 * 解析预算类环境变量（CJ_TAURI_LOG_MAX_KB / CJ_TAURI_LOG_KEEP）
 *
 * 非法值按未设置算，并留一行 stderr——「设了但没生效」比「没设」难查得多。
 * 公开只为子包用例可见（子包看不到父包非 public 符号）
 */
public func logBudgetFromEnv(name: String, dflt: Int64): Int64 {
    if (let Some(v) <- getVariable(name)) {
        if (v.size > 0) {
            try {
                let n = Int64.parse(v)
                if (n > 0) {
                    return n
                }
                eprintln("[cj-tauri] ${name}=\"${v}\" 不是正整数，按默认值 ${dflt} 处理")
            } catch (e: Exception) {
                eprintln("[cj-tauri] ${name}=\"${v}\" 解析失败，按默认值 ${dflt} 处理")
            }
        }
    }
    return dflt
}

/**
 * 平台惯例的日志目录（不含文件名）
 *
 * Linux 认 `XDG_STATE_HOME`（缺省 `~/.local/state`）：日志属 state，不属 config——
 * 放 `~/.config` 会把「可丢弃的运行痕迹」混进配置备份里。
 */
@When[os == "Linux"]
public func defaultLogDir(): String {
    let base = logEnvOr("XDG_STATE_HOME", "")
    if (base.size > 0) {
        return "${base}/cj-tauri"
    }
    return "${logEnvOr("HOME", "/tmp")}/.local/state/cj-tauri"
}

/**
 * 平台惯例的日志目录（不含文件名）
 *
 * Windows 认 `%LOCALAPPDATA%`（`C:\Users\<用户>\AppData\Local`）：单机可丢的数据就该落这里，
 * 漫游配置里不放日志。变量缺失时退到 USERPROFILE，别拼出个以 `\cj-tauri` 开头的绝对路径。
 */
@When[os == "Windows"]
public func defaultLogDir(): String {
    let base = logEnvOr("LOCALAPPDATA", "")
    if (base.size > 0) {
        return "${base}\\cj-tauri\\logs"
    }
    return "${logEnvOr("USERPROFILE", "C:")}\\AppData\\Local\\cj-tauri\\logs"
}

/** 目录 + 文件名：分隔符按平台给（C 侧整条路径直接用，不做拼接） */
@When[os == "Linux"]
func logPathJoin(dir: String, name: String): String {
    return "${dir}/${name}"
}

/** 目录 + 文件名：分隔符按平台给（C 侧整条路径直接用，不做拼接） */
@When[os == "Windows"]
func logPathJoin(dir: String, name: String): String {
    return "${dir}\\${name}"
}

/** 应用名 → 平台惯例目录下的日志全路径（`CJ_TAURI_LOG` 的覆写由调用方先判） */
public func defaultLogPath(appName: String): String {
    let name = if (appName.size > 0) {
        appName
    } else {
        CJ_LOG_DEFAULT_APP
    }
    return logPathJoin(defaultLogDir(), "${name}.log")
}

/**
 * 「环境变量给了就用它，没给才落平台惯例目录」——`setLogToDefaultFile` 的选择器
 *
 * 抽成纯函数只为**可测**：单测里改环境变量会污染同进程的其它用例，所以把「读到什么」
 * 当参数传进来，判据钉在这个函数上（`envPath` 空串＝未设置，与 `logEnvOr` 同口径）。
 */
public func logPathOrDefault(envPath: String, appName: String): String {
    if (envPath.size > 0) {
        return envPath
    }
    return defaultLogPath(appName)
}
