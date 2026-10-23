package cjTauri

import std.collection.ArrayList

/**
 * L0 适配层契约（RFC-002 §5.1）——每端各实现一份，框架只依赖这些接口
 *
 * 这些接口**不是给业务用的**：业务拿到的只有 AppContext。
 * 批次 1 接入装配层时，Platform.discover() 会按端挑选实现。
 */

/** 资产读取：按逻辑名取内容（读盘 / 内嵌常量 / rawfile 由实现决定） */
public interface AssetResolver {
    func readText(name: String): Option<String>
    func exists(name: String): Bool
}

/** 目录与特性发现：沙箱端必须实现，桌面端由 Platform 给默认 */
public interface PlatformEnv {
    func paths(appId: String): AppPaths
    func assets(root: String): AssetResolver
    /** RFC 写 Set<PlatformFeature>；批次 0 用 ArrayList 近似，接口定型时统一替换 */
    func features(): ArrayList<PlatformFeature>
}

/** 页面材化：把 Asset 逻辑名变成宿主可加载的形态（L0 内部细节） */
public interface PageMaterializer {
    func resolve(asset: String, page: String): PageSource
}
