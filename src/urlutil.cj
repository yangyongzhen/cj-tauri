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

/**
 * host 是不是 IP 字面量（IPv4 / IPv6，可带方括号）。
 *
 * 为什么需要它：建 TLS 客户端时要用 host 当 **SNI**（`serverName`），而 RFC 6066 明确不许 SNI 里放
 * IP 字面量——stdx 默认不发 SNI，本仓给「域名」补上 SNI 的那一轮必须把 IP 排除在外，否则
 * 「https 直连 IP」这类原本可用的端点会被对端当场拒掉（修一个坑别踩出另一个）。
 * 判定只认严格形态：四段十进制且每段 <= 255 的 IPv4，或含冒号 / 带方括号的 IPv6——
 * 纯十六进制字母的域名（如 `dead.beef`）是域名，不是 IP。
 */
public func isIpLiteralHost(host: String): Bool {
    if (host.size == 0) {
        return false
    }
    let b = host.toArray()
    // 带方括号 = IPv6 字面量（urlHostOf 会把方括号一起返回）
    if (b[0] == 91u8 && b[b.size - 1] == 93u8) {
        return true
    }
    for (i in 0..b.size) {
        if (b[i] == 58u8) {
            return true    // 含冒号即 IPv6（含 ::1 这类简写）
        }
    }
    var segs = 0
    var digits = 0
    var value: Int64 = 0
    for (i in 0..b.size) {
        let c = b[i]
        if (c == 46u8) {
            if (digits == 0 || value > 255) {
                return false
            }
            segs = segs + 1
            digits = 0
            value = 0
        } else if (c >= 48u8 && c <= 57u8) {
            digits = digits + 1
            if (digits > 3) {
                return false
            }
            value = value * 10 + Int64(c - 48u8)
        } else {
            return false
        }
    }
    if (digits == 0 || value > 255) {
        return false
    }
    return segs == 3
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
