package ohos_app_cangjie_entry

// env 判据探针（AGENTS §4）：官方条件编译文档的映射表说 aarch64-linux-ohos 的
// env 取值为 "ohos"，桌面 Linux 是 "gnu"。这里三个分支各带独有字面量，
// 编译产物里 grep 就能知道哪个活下来——比肉眼看日志更直接。
@When[env == "ohos"]
public let ENV_PROBE: String = "PROBE_ENV_OHOS"

@When[env == "gnu"]
public let ENV_PROBE: String = "PROBE_ENV_GNU"

@When[env != "ohos" && env != "gnu"]
public let ENV_PROBE: String = "PROBE_ENV_OTHER"
