package cjTauri.platform

/**
 * 平台自述（RFC-002 §5.1）
 *
 * 供宿主选择、资产策略、日志与埋点共用；**业务不得据此分支**——
 * 业务判断"这个端有没有某设施"请走 AppContext.supports(PlatformFeature)。
 *
 * 为什么 os 是字符串而不是枚举：宿主实现由 L0 注册（HostProvider），框架核心
 * 不 import 任何平台包；批次 1 接入 createHost 时会给出各端的取值常量。
 */
public class TargetInfo {
    /** "Windows" / "Linux" / "HarmonyOS" / "macOS" / "Android"（鸿蒙与 Linux 桌面都会报 Linux，靠 hostKind 区分） */
    public let os: String
    /** "x86_64" / "aarch64" */
    public let arch: String
    /** "webkitgtk" / "webview2" / "arkweb" / "wkwebview" / "android-webview" */
    public let hostKind: String
    /** "desktop" / "mobile"：只决定窗口语义（桌面多窗、移动端多任务），不决定能力位 */
    public let display: String

    public init(os: String, arch: String, hostKind: String, display: String) {
        this.os = os
        this.arch = arch
        this.hostKind = hostKind
        this.display = display
    }

    public func describe(): String {
        "${os}/${arch} host=${hostKind} display=${display}"
    }
}
