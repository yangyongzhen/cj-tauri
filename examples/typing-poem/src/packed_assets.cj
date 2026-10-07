package typing_poem

/**
 * 单文件打包用的内嵌资源（存根）
 *
 * 这是**存根**：仓库里三个量都是空串，正常构建仍然按相对路径从 `ui/` 与 `capabilities/` 读盘。
 * `scripts/pack-win-single.sh` 会在**临时构建副本**里把本文件覆盖成真实内容（标准 base64、无换行），
 * 于是单个 exe 不再需要任何随行文件——页面、three.js、能力清单全在二进制里。
 *
 * 判据固定是「非空即内嵌」，逻辑在 `src/packed_resources.cj`；本文件只有数据，不要往里加代码，
 * 打包脚本是整体覆盖它的。
 */
public let PACKED_UI_B64: String = ""
public let PACKED_THREE_B64: String = ""
public let PACKED_CAPS_B64: String = ""
