package cjTauri

/**
 * URL → host 提取（核心共享层）：http 与 ws 两个插件共用同一套解析与大小写口径。
 *
 * 为什么放核心不放插件：主机白名单的「匹配目标」只要有第二份实现，就一定会有一份
 * 是错的——与 scope 判定同一条铁律（AGENTS §2：安全校验不吃「各插件各写一套」）。
 * 插件只管调，不自己扫字节。
 *
 * 语义：从 `scheme://[user@]host[:port][/path]` 提取 host（小写返回）。
 * 协议只认 http / https / ws / wss；解析不出 host 返回 None。按字节扫（URL 结构
 * 是 ASCII），不用 String 切片撞 UTF-8 边界。public 是为了单测可直接构造（跨包须 public）。
 */
public func urlHostOf(rawUrl: String): Option<String> {
    let b = rawUrl.toArray()
    // 找 "://"（58 47 47）
    var schemeEnd: Int64 = -1
    var i: Int64 = 0
    while (i + 2 < b.size) {
        if (b[i] == 58u8 && b[i + 1] == 47u8 && b[i + 2] == 47u8) {
            schemeEnd = i
            break
        }
        i++
    }
    if (schemeEnd <= 0) {
        return None
    }
    let scheme = asciiLowerOf(b[0..schemeEnd])
    if (scheme != "http" && scheme != "https" && scheme != "ws" && scheme != "wss") {
        return None
    }
    // host 段：到 '/' '?' '#' 为止
    var start = schemeEnd + 3
    var end = start
    while (end < b.size) {
        let c = b[end]
        if (c == 47u8 || c == 63u8 || c == 35u8) {
            break
        }
        end++
    }
    if (end == start) {
        return None
    }
    // 去 userinfo（最后一个 '@' 之前的部分）
    var at: Int64 = -1
    var k = end - 1
    while (k >= start) {
        if (b[k] == 64u8) {
            at = k
            break
        }
        k--
    }
    if (at >= 0) {
        start = at + 1
    }
    // 去端口（第一个 ':' 之后）——IPv6 字面量 [..] 截到 ']' 为止，方括号内不拆
    if (b[start] == 91u8) {
        var close: Int64 = -1
        var m = start + 1
        while (m < end) {
            if (b[m] == 93u8) {
                close = m
                break
            }
            m++
        }
        if (close >= 0) {
            end = close + 1
        }
    } else {
        var colon: Int64 = -1
        var m = start
        while (m < end) {
            if (b[m] == 58u8) {
                colon = m
                break
            }
            m++
        }
        if (colon >= 0) {
            end = colon
        }
    }
    if (end <= start) {
        return None
    }
    let host = asciiLowerOf(b[start..end])
    if (host.size == 0) {
        return None
    }
    return Some(host)
}

/** ASCII 字节 → 小写字符串（非 ASCII 原样保留）；host 匹配统一走这里 */
private func asciiLowerOf(bytes: Array<Byte>): String {
    let out = Array<Byte>(bytes.size, repeat: 0)
    for (i in 0..bytes.size) {
        var c = bytes[i]
        if (c >= 65u8 && c <= 90u8) {
            c = c + 32u8
        }
        out[i] = c
    }
    return String.fromUtf8(out)
}
