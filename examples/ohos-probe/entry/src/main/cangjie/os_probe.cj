package ohos_app_cangjie_entry

// @When 在 aarch64-linux-ohos 目标下的取值探针：
// cjc 只接受 os ∈ {Windows, Linux, macOS, iOS}，鸿蒙没有独立取值，
// 这里用三个分支各带一个独特字面量，编译后看哪个活下来。

@When[os == "Linux"]
public let OS_PROBE: String = "PROBE_OS_LINUX"

@When[os == "Windows"]
public let OS_PROBE: String = "PROBE_OS_WINDOWS"

@When[os == "macOS"]
public let OS_PROBE: String = "PROBE_OS_MACOS"
