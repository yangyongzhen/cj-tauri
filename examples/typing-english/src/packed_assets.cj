package typing_english

/**
 * 单文件打包用的内嵌资源（存根）
 *
 * 这是**存根**：仓库里两个量都是空串，正常构建仍然按相对路径从 `ui/` 与 `capabilities/` 读盘。
 * `scripts/pack-win-single.sh` 会在**临时构建副本**里把本文件覆盖成真实内容（标准 base64、无换行），
 * 于是单个 exe 不再需要任何随行文件——页面与能力清单全在二进制里。
 *
 * 本示例**没有** three.js，所以只声明两条常量：打包器按「声明了哪几个就生成哪几个」工作，
 * 多写一条 `PACKED_THREE_B64` 反而会让它去找一个不存在的文件（照抄 typing-poem 的存根就会踩到）。
 *
 * 判据固定是「非空即内嵌」，逻辑在 `src/packed_resources.cj`；本文件只有数据，不要往里加代码，
 * 打包脚本是整体覆盖它的。
 */
public let PACKED_UI_B64: String = ""
public let PACKED_CAPS_B64: String = ""
