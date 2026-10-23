package cjTauri

import std.env.*
import std.collection.ArrayList

/**
 * 平台发现（RFC-002 §4.2 / §5.3）——全框架唯一的「端在哪儿」知识入口
 *
 * 按约定（RFC §5.3），os 名匹配的 @When 只允许出现在本文件与 targets 目录下的生成胶水；
 * CI 用 `grep -r '@When\[os' src/ | grep -v src/platform/` 守这条线。
 * @When 分支一律成对出现（本仓库惯例，参照 host_webview2.cj），保证任何目标下每个
 * 符号恰好有一个定义；跨平台文件里只用短名。
 *
 * 批次 0 边界：本文件只提供**可编译的默认实现**（桌面 Linux / Windows 实测，
 * 鸿蒙走 mobile(filesDir)），特性位清单是占位值，接端时按实测修正。
 */
public class Platform {
    /**
     * 桌面端默认发现：paths 走平台规范目录（RFC §5.2），dev 看 CJ_TAURI_DEV_URL
     *
     * arch 默认 x86_64；ARM64 Linux 桌面请显式传 arch（它的 os 与 x86_64 Linux 相同，
     * 这是仓库已知的「同 os 多宿主」来源，见 RFC §5.1）。
     * appId 由 launch() 从清单传入（清单解析在批次 1 落地，见 RFC §3/§13.1 风险 1）。
     */
    public static func discover(appId: String, arch: String): AppContext {
        return desktop(appId, arch)
    }

    public static func desktop(appId: String, arch: String): AppContext {
        let data = "${dataRoot()}/${appId}"
        let target = TargetInfo(desktopOs(), arch, desktopHostKind(), "desktop")
        let fs = ArrayList<PlatformFeature>()
        fs.add(PlatformFeature.MultiWindow)
        fs.add(PlatformFeature.FilePicker)
        fs.add(PlatformFeature.ClipboardImage)
        fs.add(PlatformFeature.Tray)
        return AppContext(
            AppPaths(data, "${cacheRoot()}/${appId}", "${cacheRoot()}/${appId}/tmp"),
            target, TauriApp.devUrl().isSome(), fs)
    }

    /**
     * 移动端发现：沙箱目录由系统能力入口传入（鸿蒙 Ability 的 filesDir / Android 的 filesDir）
     *
     * 沙箱端没有 dev server，dev 恒为 false；hostKind 是占位（鸿蒙 ArkWeb，
     * Android 接入时由其 Provider 决定），特性位清单接端实测后修正。
     */
    public static func mobile(filesDir: String, arch: String): AppContext {
        let target = TargetInfo("Linux", arch, "arkweb", "mobile")
        let fs = ArrayList<PlatformFeature>()
        fs.add(PlatformFeature.MultiWindow)
        fs.add(PlatformFeature.ClipboardImage)
        fs.add(PlatformFeature.SoftKeyboardInset)
        return AppContext(
            AppPaths(filesDir, "${filesDir}/cache", "${filesDir}/cache/tmp"),
            target, false, fs)
    }

    // ---- 平台名与目录根：@When 成对门禁，只落在这几个函数（RFC §5.3）----

    @When[os == "Windows"]
    private static func desktopOs(): String {
        return "Windows"
    }

    @When[os != "Windows"]
    private static func desktopOs(): String {
        return "Linux"
    }

    @When[os == "Windows"]
    private static func desktopHostKind(): String {
        return "webview2"
    }

    @When[os != "Windows"]
    private static func desktopHostKind(): String {
        return "webkitgtk"
    }

    @When[os == "Windows"]
    private static func dataRoot(): String {
        return getVariable("APPDATA") ?? "."
    }

    @When[os == "Windows"]
    private static func cacheRoot(): String {
        return getVariable("LOCALAPPDATA") ?? "."
    }

    @When[os == "Linux" && env != "ohos"]
    private static func dataRoot(): String {
        return getVariable("XDG_DATA_HOME") ?? "${getVariable("HOME") ?? "."}/.local/share"
    }

    @When[os == "Linux" && env != "ohos"]
    private static func cacheRoot(): String {
        return getVariable("XDG_CACHE_HOME") ?? "${getVariable("HOME") ?? "."}/.cache"
    }

    // ohos 目标上 desktop() 不会被调用，但符号必须存在才能编译；
    // 返回占位值，真机路径由 mobile(filesDir) 提供。
    @When[env == "ohos"]
    private static func dataRoot(): String {
        return "."
    }

    @When[env == "ohos"]
    private static func cacheRoot(): String {
        return "."
    }

    // 其余目标（macOS 等）暂按 HOME 兜底：接入对应端时在这里补实现并真机验证。
    @When[os != "Windows" && os != "Linux"]
    private static func dataRoot(): String {
        return "${getVariable("HOME") ?? "."}/.local/share"
    }

    @When[os != "Windows" && os != "Linux"]
    private static func cacheRoot(): String {
        return "${getVariable("HOME") ?? "."}/.cache"
    }
}
