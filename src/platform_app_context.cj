package cjTauri

import std.collection.ArrayList

/**
 * 应用可写目录（RFC-002 §5.2）
 *
 * 默认跟应用 id 走平台规范目录（XDG / AppData / filesDir），不落可执行文件旁边；
 * 便携版（数据跟 exe）是显式选项，由骨架构建期注入，见 RFC §5.2。
 * Windows 下统一用 "/" 分隔符（Windows API 均接受），减少按端拼路径的分支。
 */
public class AppPaths {
    public let dataDir: String   // 收藏库、状态等持久数据
    public let cacheDir: String  // 可清理缓存
    public let tempDir: String   // 本次运行临时文件

    public init(dataDir: String, cacheDir: String, tempDir: String) {
        this.dataDir = dataDir
        this.cacheDir = cacheDir
        this.tempDir = tempDir
    }
}

/**
 * 运行时上下文（RFC-002 §4.5）——框架在 launch() 里构建，业务只读
 *
 * supports() 是业务唯一的平台判断入口；target 字段仅供日志与埋点，
 * code review 里出现「按 target.os 分支」应被拒绝（RFC 硬约束 1）。
 */
public class AppContext {
    public let paths: AppPaths
    public let target: TargetInfo
    /** 开发期：资产优先读盘、允许 DevServer */
    public let dev: Bool
    private let features: ArrayList<PlatformFeature>

    public init(paths: AppPaths, target: TargetInfo, dev: Bool, features: ArrayList<PlatformFeature>) {
        this.paths = paths
        this.target = target
        this.dev = dev
        this.features = features
    }

    /** 特性探测：批次 0 用线性扫（特性位数 ≤ 十几，不值得上哈希表） */
    public func supports(f: PlatformFeature): Bool {
        for (item in features) {
            if (PlatformFeature.same(item, f)) {
                return true
            }
        }
        return false
    }

    /** 供日志输出：本端支持哪些特性位（降级行为要可观测，见 RFC §8） */
    public func describeFeatures(): String {
        let sb = StringBuilder()
        var first = true
        for (item in features) {
            if (!first) {
                sb.append(", ")
            }
            first = false
            sb.append(featureName(item))
        }
        return sb.toString()
    }

    private static func featureName(f: PlatformFeature): String {
        match (f) {
            case Tray => "Tray"
            case MultiWindow => "MultiWindow"
            case FilePicker => "FilePicker"
            case ClipboardImage => "ClipboardImage"
            case SoftKeyboardInset => "SoftKeyboardInset"
        }
    }
}
