package aiChat

/**
 * 单文件打包用的内嵌资源（存根）
 *
 * 这是**存根**：仓库里三个量都是空串，正常构建仍然按相对路径从 `ui/` 与 `capabilities/` 读盘。
 * `scripts/pack-win-single.sh` 会在**临时构建副本**里把本文件覆盖成真实内容（标准 base64、无换行），
 * 于是单个 exe 不再需要任何随行文件——页面、vendor 库与能力清单全在二进制里。
 *
 * 与 examples/music / cjnote 同款机制；判据固定是「非空即内嵌」，取用逻辑在
 * `src/packed_resources.cj`。本文件只有数据，不要往里加代码，打包脚本是整体覆盖它的。
 *
 * `PACKED_VENDOR_B64` 这一条是本示例要的：页面把 highlight.js 与它的主题内联进占位符
 * （`inlineVendor()`），单文件产物里没有 `ui/vendor/`，不编进二进制就等于代码无高亮。
 * 清单在 `ui/vendor/pack-files.txt`——**行序即契约**，与 `vendorSegments()` 的取用序逐字对齐。
 */
public let PACKED_UI_B64: String = ""
public let PACKED_VENDOR_B64: String = ""
public let PACKED_CAPS_B64: String = ""
