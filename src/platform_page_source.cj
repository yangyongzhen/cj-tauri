package cjTauri

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
