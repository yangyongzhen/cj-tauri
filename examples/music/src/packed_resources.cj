package music_app

import std.collection.*
import std.fs.*

/**
 * 内嵌资源的取用（单文件打包用）
 *
 * 打包脚本把页面与能力清单按 base64 写进 `src/packed_assets.cj`，
 * 本文件负责「解码」与「内嵌优先、否则读盘」两件事。
 *
 * 为什么走 base64 而不是生成字符串字面量：页面正文里有成片的反斜杠与引号
 * （minified 逻辑、正则、CSS 转义尤其密集），转义错一个字符就是整段脚本静默不执行
 * （见 AGENTS §4 的三引号坑）。base64 的字符表只有 `A-Za-z0-9+/=`，生成与解码都不涉及转义，坏不了。
 */

/** 取 base64 字符的值；`=` 与空白（含换行）一律返回 -1，由调用方跳过 */
func base64Value(b: UInt8): Int64 {
    if (b >= 65u8 && b <= 90u8) {          // A-Z
        return Int64(b - 65u8)
    }
    if (b >= 97u8 && b <= 122u8) {         // a-z
        return Int64(b - 97u8) + 26
    }
    if (b >= 48u8 && b <= 57u8) {          // 0-9
        return Int64(b - 48u8) + 52
    }
    if (b == 43u8) {                       // +
        return 62
    }
    if (b == 47u8) {                       // /
        return 63
    }
    return -1
}

/**
 * 标准 base64 解码为 UTF-8 文本
 *
 * 按「累积 6 位、够 8 位就吐一个字节」实现，末尾的 `=` 天然被跳过（少几位就少吐几个字节）。
 * 不校验非法字符——输入是构建期由本仓库自己生成的，这里就不为它添防御分支。
 */
func decodeBase64(s: String): String {
    let out = ArrayList<Byte>()
    var acc: Int64 = 0
    var bits: Int64 = 0
    for (b in s) {
        let v = base64Value(b)
        if (v < 0) {
            continue
        }
        acc = (acc << 6) | v
        bits += 6
        if (bits >= 8) {
            bits -= 8
            out.add(UInt8((acc >> bits) & 0xFF))
        }
    }
    return String.fromUtf8(out.toArray())
}

/**
 * 按单字节分隔符切分文本
 *
 * 只服务于「打包器把若干段 base64 用逗号拼起来」这一种输入（base64 字符表里没有逗号），
 * 不做通用分词。空串会切出一个空片段，调用方按 `size > 0` 自行兜住。
 */
func splitBy(s: String, sep: UInt8): ArrayList<String> {
    let out = ArrayList<String>()
    var buf = ArrayList<Byte>()
    for (b in s) {
        if (b == sep) {
            out.add(String.fromUtf8(buf.toArray()))
            buf = ArrayList<Byte>()
            continue
        }
        buf.add(b)
    }
    out.add(String.fromUtf8(buf.toArray()))
    return out
}

/** 从磁盘读文本：读不到就把「请在哪个目录启动」写进异常里（工作目录是这类问题的第一嫌疑） */
func readTextFile(path: String, what: String): String {
    var bytes: Array<Byte> = []
    try {
        bytes = File.readFrom(path)
    } catch (e: Exception) {
        throw Exception("读不到${what} ${path}（${e}）——请在 examples/music 目录下启动：" +
            "capabilities/ 与 ui/ 都按项目根相对路径读")
    }
    return String.fromUtf8(bytes)
}

/**
 * 内嵌优先：打包产物里 base64 非空就用它，否则按相对路径读盘（仓库内正常构建走这条）
 *
 * `what` 只用于读盘失败时的报错文案（「请在哪个目录启动」），内嵌路径用不到它。
 */
func textOrFile(b64: String, path: String, what: String): String {
    if (b64.size > 0) {
        return decodeBase64(b64)
    }
    return readTextFile(path, what)
}
