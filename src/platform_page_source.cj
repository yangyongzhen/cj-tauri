package cjTauri

import std.fs.*

/**
 * 页面来源（RFC-002 §4.3）——取代 run(html) / runUrl(url) 双入口的唯一表达
 *
 * 业务与清单只写 Asset("ui/index.html") 这一种；devMode 下由框架改写为
 * DevServer；Asset 在各端怎么落地（读盘 / rawfile 材化 / assets base URL）
 * 是 L0 适配层（PageMaterializer）的事，业务与骨架都不接触沙箱路径。
 */
public enum PageSource {
    /** 代码里直接给的 HTML 字符串（探针、错误页用） */
    | Inline(String)
    /** 资产逻辑名，如 "ui/index.html"（sync 生成期校验存在，见 RFC §6.1） */
    | Asset(String)
    /** http(s):// 或 file:// 直载 */
    | Url(String)
    /** 开发期前端 dev server（HMR），由 CJ_TAURI_DEV_URL 注入 */
    | DevServer(String)
}

/** 解析结果：宿主最终执行的动作（纯数据，可测） */
public enum PageLoad {
    | StartHtml(String)  // host.start(html)
    | StartUrl(String)   // host.startUrl(url)
}

/**
 * PageSource → PageLoad 的唯一决策点（批次 1，RFC §4.3）
 *
 * - Inline / Url / DevServer：直接映射
 * - Asset：优先走注入的 AssetResolver；未注入时按 cwd 相对路径读盘——与现有模板
 *   textOrFile 的桌面行为等价，鸿蒙 rawfile / 内嵌常量的实现在批次 2 随清单接入
 * - 找不到资产：抛可照做的错误，不静默白屏（与 host_factory「不静默回落」同约定）
 */
public func resolvePage(source: PageSource, resolver: Option<AssetResolver>): PageLoad {
    match (source) {
        case Inline(html) => return PageLoad.StartHtml(html)
        case Url(url) => return PageLoad.StartUrl(url)
        case DevServer(url) => return PageLoad.StartUrl(url)
        case Asset(name) =>
            match (resolver) {
                case Some(r) =>
                    match (r.readText(name)) {
                        case Some(html) => return PageLoad.StartHtml(html)
                        case None =>
                            throw CommandException("资产未找到：${name}（请检查注入的 AssetResolver 与清单 [assets] 配置）")
                    }
                case None =>
                    var text = ""
                    try {
                        text = String.fromUtf8(File.readFrom(name))
                    } catch (e: Exception) {
                        throw CommandException("资产未找到：${name}（未注入 AssetResolver，按相对路径读盘失败：${e}；鸿蒙 rawfile / 内嵌场景请注入对应解析器）")
                    }
                    return PageLoad.StartHtml(text)
            }
    }
}

/**
 * devMode 改写（RFC §4.3）：CJ_TAURI_DEV_URL 存在时，Asset 页面自动改走 dev server
 *
 * 只改 Asset：显式 Inline（探针）/ Url / DevServer 是业务明说的意图，不改写。
 * 纯函数，可测。
 */
public func rewriteForDev(source: PageSource, devUrl: Option<String>): PageSource {
    match (devUrl) {
        case Some(url) =>
            match (source) {
                case Asset(_) => return PageSource.DevServer(url)
                case _ => return source
            }
        case None => return source
    }
}
