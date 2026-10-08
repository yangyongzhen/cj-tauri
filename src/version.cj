package cjTauri

/**
 * 框架版本：仓颉侧的单一代码来源（`system:version` 命令返回它）。
 *
 * 发版时必须与以下位置同步，改完跑 `bash scripts/check-version.sh` 自检：
 *   - cjpm.toml               的 version（框架包）
 *   - cli/cjpm.toml           的 version（CLI 包）
 *   - cli/src/project.cj      的 cliVersion()
 *   - CHANGELOG.md            顶部第一个已发版段
 */
public let CJ_TAURI_VERSION = "0.8.0"

/** 当前宿主平台标识（`system:version` 的 platform 字段） */
@When[os == "Linux"]
public func currentPlatform(): String {
    return "linux"
}

@When[os == "Windows"]
public func currentPlatform(): String {
    return "windows"
}
