package markdownNotes

import std.collection.*
import std.fs.*

/**
 * 内嵌资源的取用（单文件打包用）——与 examples/music/src/packed_resources.cj 同款，
 * 多一个 vendor 库数组：打包脚本把 5 个 vendor 文件按 VENDOR_FILES 的顺序各自 base64、
 * 用 "," 拼进 PACKED_VENDOR_B64，vendorOrFile 按下标取（两边顺序改一边就会错位）。
 *
 * 为什么走 base64 而不是生成字符串字面量：页面正文里有成片的反斜杠与引号
 * （minified 库、正则、CSS 转义尤其密集），转义错一个字符就是整段脚本静默不执行
 * （见 AGENTS §4 的三引号坑）。base64 的字符表只有 `A-Za-z0-9+/=`，生成与解码都不涉及转义，坏不了。
 */

/** vendor 库的固定顺序（下标即语义：0=marked 1=hljs 2..4=主题 CSS，见 main.cj 的 vendorText）。
 *  存的是**逻辑名**（供 TauriApp.readAsset：桌面按 assets/ 前缀读盘、鸿蒙按 rawfile 名读 hap）；
 *  磁盘回落（vendorOrFile）按新形态布局加 assets/ 前缀。 */
let VENDOR_FILES: Array<String> = [
    "ui/vendor/marked.min.js", "ui/vendor/highlight.min.js",
    "ui/vendor/github-dark-dimmed.min.css", "ui/vendor/github-dark.min.css",
    "ui/vendor/atom-one-dark.min.css"
]

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

/** 按单字节分隔符切分文本（打包器把多段 base64 用逗号拼起来，base64 字符表里没有逗号） */
func splitBy(s: String, sep: UInt8): ArrayList<String> {
    let out = ArrayList<String>()
    let buf = ArrayList<Byte>()
    for (b in s) {
        if (b == sep) {
            out.add(String.fromUtf8(buf.toArray()))
            buf.clear()
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
        throw Exception("读不到${what} ${path}（${e}）——请在 examples/markdown-notes 目录下启动：" +
            "assets/ui/ 都按项目根相对路径读")
    }
    return String.fromUtf8(bytes)
}

/**
 * vendor 库内嵌优先：PACKED_VENDOR_B64 非空时按下标取第 i 个文件（逗号分隔的各段 base64），
 * 否则读盘。找不到（下标越界 / 读盘失败）返回 None，由调用方决定降级方式。
 */
func vendorOrFile(i: Int64): Option<String> {
    if (i < 0 || i >= VENDOR_FILES.size) {
        return None
    }
    if (PACKED_VENDOR_B64.size > 0) {
        let parts = splitBy(PACKED_VENDOR_B64, 44u8)   // 44 = ','
        if (i < parts.size) {
            return Some(decodeBase64(parts[i]))
        }
        return None
    }
    try {
        return Some(readTextFile("assets/" + VENDOR_FILES[i], "vendor 库"))
    } catch (e: Exception) {
        let _ = e
        return None
    }
}
