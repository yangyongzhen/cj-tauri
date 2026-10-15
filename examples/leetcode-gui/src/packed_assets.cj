package leetcode_gui

/**
 * 单文件打包用的内嵌资源（存根）
 *
 * 这是**存根**：仓库里三个量都是空串，正常构建仍然按相对路径从 `ui/` 与 `capabilities/` 读盘。
 * `scripts/pack-win-single.sh` 会在**临时构建副本**里把本文件覆盖成真实内容（标准 base64、无换行），
 * 于是单个 exe 不再需要任何随行文件——页面、CodeMirror 与能力清单全在二进制里。
 *
 * 与 examples/music（页面 + 清单）、examples/markdown-notes（多一份 vendor 数组）同款机制；
 * 本示例的 vendor 是 CodeMirror 两份（样式 + 核心），顺序见 `src/packed_resources.cj` 的 VENDOR_FILES，
 * 与 `ui/vendor/pack-files.txt` 逐字对齐。判据固定是「非空即内嵌」，逻辑在 `src/packed_resources.cj`；
 * 本文件只有数据，不要往里加代码，打包脚本是整体覆盖它的。
 */
public let PACKED_UI_B64: String = ""
public let PACKED_VENDOR_B64: String = ""
public let PACKED_CAPS_B64: String = ""
