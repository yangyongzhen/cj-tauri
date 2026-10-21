package cjnote

import std.collection.*

/**
 * 内嵌资源的取用（单文件打包用）
 *
 * 打包脚本把页面、vendor 库与能力清单按 base64 写进 `src/packed_assets.cj`，
 * 本文件负责「解码」与「内嵌优先、否则读盘」两件事。
 *
 * 为什么走 base64 而不是生成字符串字面量：页面与 vendor 库正文里有成片的反斜杠与引号
 * （minified 逻辑、正则、CSS 转义尤其密集），转义错一个字符就是整段脚本静默不执行
 * （见 AGENTS §4 的三引号坑）。base64 的字符表只有 `A-Za-z0-9+/=`，生成与解码都不涉及转义，坏不了。
 *
 * 与 examples/music 的差别只有一条：cjnote 的页面还要靠三个 vendor 脚本与两份 vendor 样式
 * （`inlineVendor()` 往占位符里填），所以多一个按契约顺序取回的 `vendorSegments()`。
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

/** 取第 i 段，越界返回空串（段数由构建期保证，这里只是不让一个下标把启动带走） */
func segAt(segs: ArrayList<String>, i: Int64): String {
    match (segs.get(i)) {
        case Some(s) => return s
        case None => return ""
    }
}

/**
 * 内嵌优先：打包产物里 base64 非空就用它，否则按相对路径读盘
 *
 * `what` 只用于读盘失败时的 stderr 文案（「缺什么、退化成了什么」）；内嵌路径用不到它。
 * 读盘失败不抛异常、返回空串——vendor 库缺一份只该让渲染退化，不该让应用起不来
 * （与 `readTextOr` 的既有口径一致）。
 */
func textOrFile(b64: String, path: String, what: String): String {
    if (b64.size > 0) {
        return decodeBase64(b64)
    }
    return readTextOr(path, what)
}

/**
 * vendor 库按**契约顺序**取回（5 段：三个 js 在前、两份 css 在后）
 *
 * 顺序是三方对齐的：`ui/vendor/pack-files.txt` 的行序、打包脚本生成 `PACKED_VENDOR_B64` 的拼接序、
 * 以及 `inlineVendor()` 的取用序。改一边就得三边一起改，否则脚本串了样式的行。
 * 内嵌时据 base64 段解码；否则按同一顺序读盘，缺一份退化为空串（渲染降级，不致命）。
 */
func vendorSegments(): ArrayList<String> {
    let out = ArrayList<String>()
    if (PACKED_VENDOR_B64.size > 0) {
        for (part in splitBy(PACKED_VENDOR_B64, 44u8)) {
            out.add(decodeBase64(part))
        }
        return out
    }
    out.add(readTextOr("ui/vendor/marked.min.js", "渲染退化为纯文本"))
    out.add(readTextOr("ui/vendor/highlight.min.js", "代码无高亮"))
    out.add(readTextOr("ui/vendor/codemirror.min.js", "编辑器退化为纯 textarea"))
    out.add(readTextOr("ui/vendor/codemirror.min.css", "编辑器无样式"))
    out.add(readTextOr("ui/vendor/github-dark.min.css", "高亮无配色"))
    return out
}
