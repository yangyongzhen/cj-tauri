package music_app

import std.collection.*

/**
 * LRC 歌词解析（纯函数，不碰网络）
 *
 * 为什么解析放在**仓颉侧**而不是页面：这份活是个纯文本解析器，放在这边才能被单测 / 日志复核
 * （命令层会把 `lines` 的条数打进 stderr）；页面拿到的是 `[{at, text}]`，只负责按播放进度高亮，
 * 不必在 JS 里再实现一遍「多时间戳标签 / 小数位归一化」这些边角。
 *
 * 支持的真实形状（取自本后台 `musicsearchlrc` 实测返回）：
 *   `[by:山有喵]`            —— 元信息标签，**整行丢弃**（不当歌词正文）
 *   `[00:06.47]原唱：大小百合` —— 标准行：分:秒.两位小数
 *   `[00:10.00][01:20.00]副歌` —— 一行多个时间戳：按每个时间戳各出一条
 * 小数位 1 / 2 / 3 位都归一化成毫秒（.4 → 400ms，.47 → 470ms，.478 → 478ms）。
 */

/** 一行歌词：起始毫秒 + 正文（正文已去掉首尾空白） */
public class LrcLine {
    public let at: Int64
    public let text: String

    public init(at: Int64, text: String) {
        this.at = at
        this.text = text
    }
}

/**
 * 按字节切行
 *
 * **本 SDK 里 `for (b in s)` 迭代出的是 UInt8 字节**（AGENTS §4 那条已更正，不是码点）——
 * 对本文件正合适：LRC 的语法字符（`[` `]` `:` `.` 数字）全是单字节 ASCII，
 * 而中文正文是 UTF-8 多字节、首字节必 ≥ 0x80，永远不会被误判成语法字符。
 */
func splitLrcLines(raw: String): ArrayList<String> {
    let out = ArrayList<String>()
    var buf = ArrayList<UInt8>()
    for (b in raw) {
        if (b == 10u8) {          // '\n'
            // CRLF：行尾的 '\r' 不属于正文
            let n = buf.size
            if (n > 0 && buf[n - 1] == 13u8) {
                out.add(String.fromUtf8(buf.toArray()[0..n - 1]))
            } else {
                out.add(String.fromUtf8(buf.toArray()))
            }
            buf = ArrayList<UInt8>()
            continue
        }
        buf.add(b)
    }
    if (buf.size > 0) {
        out.add(String.fromUtf8(buf.toArray()))
    }
    return out
}

/** 字符串 → 字节数组（下面按索引扫描要用） */
func bytesOfString(s: String): Array<UInt8> {
    let out = ArrayList<UInt8>()
    for (b in s) {
        out.add(b)
    }
    return out.toArray()
}

/** 数字字符的值；非数字返回 -1 */
func digitValue(b: UInt8): Int64 {
    if (b >= 48u8 && b <= 57u8) {     // '0'..'9'
        return Int64(b - 48u8)
    }
    return -1
}

/**
 * 解析 `[` 与 `]` 之间的内容：`mm:ss.xx` → 毫秒
 *
 * 不是时间标签（`by` / `ti` / `ar` / `offset` 这类元信息）就返回 None，由调用方把整行丢掉。
 * 严格要求「括号内全部字符都参与解析」，否则 `[by:山有喵]` 里的 `：` 与汉字会被当成
 * 「分钟之后的杂字符」而误判——那正是当初最想避开的一类假阳性。
 */
func parseLrcStamp(b: Array<UInt8>, from: Int64, to: Int64): Option<Int64> {
    var i = from
    var minutes: Int64 = 0
    var mDigits = 0
    while (i < to && digitValue(b[i]) >= 0) {
        minutes = minutes * 10 + digitValue(b[i])
        i += 1
        mDigits += 1
    }
    if (mDigits == 0 || i >= to || b[i] != 58u8) {    // ':'
        return None
    }
    i += 1
    var seconds: Int64 = 0
    var sDigits = 0
    while (i < to && digitValue(b[i]) >= 0) {
        seconds = seconds * 10 + digitValue(b[i])
        i += 1
        sDigits += 1
    }
    if (sDigits == 0) {
        return None
    }
    var frac: Int64 = 0
    var fDigits = 0
    if (i < to && (b[i] == 46u8 || b[i] == 58u8)) {   // '.' 或 ':' 都当作小数分隔符
        i += 1
        while (i < to && digitValue(b[i]) >= 0) {
            if (fDigits < 3) {                        // 只取前三位，第四位起忽略
                frac = frac * 10 + digitValue(b[i])
                fDigits += 1
            }
            i += 1
        }
    }
    if (i != to) {                                    // 还有没解析掉的字符 → 不是时间标签
        return None
    }
    var ms = frac
    if (fDigits == 0) {
        ms = 0
    } else if (fDigits == 1) {
        ms = frac * 100
    } else if (fDigits == 2) {
        ms = frac * 10
    }
    return Some(minutes * 60000 + seconds * 1000 + ms)
}

/** 去掉首尾空白（ASCII：空格 / 制表 / 换行），中间的空白保留 */
func trimAsciiText(s: String): String {
    let b = bytesOfString(s)
    var start: Int64 = 0
    var end: Int64 = b.size
    while (start < end) {
        let c = b[start]
        if (c == 32u8 || c == 9u8 || c == 13u8 || c == 10u8) {
            start += 1
        } else {
            break
        }
    }
    while (end > start) {
        let c = b[end - 1]
        if (c == 32u8 || c == 9u8 || c == 13u8 || c == 10u8) {
            end -= 1
        } else {
            break
        }
    }
    if (start >= end) {
        return ""
    }
    return String.fromUtf8(b[start..end])
}

/** 按时间升序（插入排序：LRC 基本本就有序，退化成近 O(n)；多时间戳行也不会乱） */
func sortLrcLines(lines: ArrayList<LrcLine>): ArrayList<LrcLine> {
    let arr = lines.toArray()
    let n = arr.size
    if (n > 1) {
        for (i in 1..n) {
            let cur = arr[i]
            var j = i - 1
            while (j >= 0 && arr[j].at > cur.at) {
                arr[j + 1] = arr[j]
                j -= 1
            }
            arr[j + 1] = cur
        }
    }
    let out = ArrayList<LrcLine>()
    for (x in arr) {
        out.add(x)
    }
    return out
}

/**
 * 解析整份 LRC：返回按时间升序的歌词行
 *
 * 元信息标签行与空行都不产出条目——页面拿到的数组就是「该唱的每一句」，
 * 高亮逻辑因此不必再判 `[by:…]` 这类噪声。
 */
public func parseLrc(raw: String): ArrayList<LrcLine> {
    let out = ArrayList<LrcLine>()
    for (line in splitLrcLines(raw)) {
        let b = bytesOfString(line)
        let stamps = ArrayList<Int64>()
        var i: Int64 = 0
        var metaTag = false
        while (i < b.size && b[i] == 91u8) {          // '['
            var j = i + 1
            while (j < b.size && b[j] != 93u8) {      // ']'
                j += 1
            }
            if (j >= b.size) {
                metaTag = true
                break
            }
            match (parseLrcStamp(b, i + 1, j)) {
                case Some(ms) => stamps.add(ms)
                case None =>
                    metaTag = true
                    break
            }
            i = j + 1
        }
        if (metaTag || stamps.size == 0) {
            continue
        }
        let text = trimAsciiText(String.fromUtf8(b[i..b.size]))
        if (text.size == 0) {
            continue
        }
        for (ms in stamps) {
            out.add(LrcLine(ms, text))
        }
    }
    return sortLrcLines(out)
}
