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
public let CJ_TAURI_VERSION = "1.0.0"

/**
 * IPC 报文协议版本（报文形状是跨层契约，加版本字段是协议治理惯例）：事件 / 回执信封的 `protocol` 字段
 * 与 `system:version` 返回的 `protocol` 字段都来自这里——单一代码来源，改协议时同步抬版本。
 *
 * 为什么同进程也要有：报文形状现在是跨层契约（C 桥 bridge_js.h 的页面侧解析、CLI 的
 * manifest 消费、将来 HarmonyOS/独立进程形态的跨进程边界），有版本字段才能在「旧页面
 * 配新框架」这类错配时给出可诊断的信号，而不是行为悄悄漂移。
 * v1：`type` + `event`/`id` + `payload` (+ 可选 `coalesce`/`window`)；本字段加入记 v1，
 * 此后任何「删字段 / 改语义」必须抬到 v2。
 */
public let CJ_IPC_PROTOCOL = "1"

/** 当前宿主平台标识（`system:version` 的 platform 字段） */
// 鸿蒙目标的 `os` 仍报 Linux（实测），所以 `os` 维度分不开「GTK 宿主」与「ArkWeb 宿主」。
// 判据用 `env`：鸿蒙目标（`aarch64-linux-ohos`）是 `ohos`，桌面 Linux 是 `gnu`——两者互斥；
// 而 `arch` 不行（桌面 aarch64 Linux 同样是 `aarch64`，会被误报成鸿蒙）。
// 平台标识必须是真实的那一个：`linux` / `ohos` 混用会让前端与证据链分不清跑在哪个宿主上。
@When[os == "Linux" && env != "ohos"]
public func currentPlatform(): String {
    return "linux"
}

@When[env == "ohos"]
public func currentPlatform(): String {
    return "ohos"
}

@When[os == "Windows"]
public func currentPlatform(): String {
    return "windows"
}
