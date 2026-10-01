/**
 * cj-tauri CLI：通用工具层
 *
 * 路径与字符串处理统一按 UTF-8 字节做 ASCII 分隔符扫描，切分点都在 ASCII 边界上，
 * 对含中文的路径安全（仓颉迭代 String 得到的是码点，这里显式走字节以避免码点/字节混淆）。
 */
package cli

import std.fs.*

// ===== 字节级字符判定 =====

func isPathSep(b: UInt8): Bool {
    return b == 0x2F || b == 0x5C // '/' or '\'
}

func isSpaceByte(b: UInt8): Bool {
    return b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A
}

func isAsciiDigit(b: UInt8): Bool {
    return b >= 0x30 && b <= 0x39
}

func isAsciiAlpha(b: UInt8): Bool {
    return (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
}

func toUpperByte(b: UInt8): UInt8 {
    if (b >= 0x61 && b <= 0x7A) {
        return b - 0x20
    }
    return b
}

func toLowerByte(b: UInt8): UInt8 {
    if (b >= 0x41 && b <= 0x5A) {
        return b + 0x20
    }
    return b
}

// ===== 路径 =====

/** 拼接路径（统一用 '/'，Windows 亦兼容） */
func joinPath(a: String, b: String): String {
    let ab = a.toArray()
    if (ab.size == 0) {
        return b
    }
    if (isPathSep(ab[ab.size - 1])) {
        return a + b
    }
    return a + "/" + b
}

/** 去掉末尾的路径分隔符 */
func stripTrailingSep(p: String): String {
    let b = p.toArray()
    var n = b.size
    while (n > 1 && isPathSep(b[n - 1])) {
        n--
    }
    return String.fromUtf8(b[0..n])
}

/** 父目录；已到根或无法解析时返回 None */
func parentDir(p: String): Option<String> {
    let s = stripTrailingSep(p)
    let b = s.toArray()
    var i = b.size
    while (i > 0) {
        i--
        if (isPathSep(b[i])) {
            if (i == 0) {
                return Some(String.fromUtf8(b[0..1])) // "/"
            }
            // Windows 盘符根 "C:/"
            if (i == 2 && b[1] == 0x3A) {
                return Some(String.fromUtf8(b[0..3]))
            }
            return Some(String.fromUtf8(b[0..i]))
        }
    }
    return None
}

/** 最后一段（文件/目录名） */
func baseName(p: String): String {
    let s = stripTrailingSep(p)
    let b = s.toArray()
    var i = b.size
    while (i > 0) {
        i--
        if (isPathSep(b[i])) {
            return String.fromUtf8(b[i + 1..b.size])
        }
    }
    return s
}

/** 去掉首尾 ASCII 空白（含 \r） */
func trimAscii(s: String): String {
    let b = s.toArray()
    var start = 0
    var end = b.size
    while (start < end && isSpaceByte(b[start])) {
        start++
    }
    while (end > start && isSpaceByte(b[end - 1])) {
        end--
    }
    if (start == 0 && end == b.size) {
        return s
    }
    return String.fromUtf8(b[start..end])
}

/** 路径含空格时给出告警（cjpm 的 link-option 以空格分隔，无法转义） */
func warnIfSpacey(label: String, p: String): Unit {
    let b = p.toArray()
    for (x in b) {
        if (x == 0x20) {
            eprintln("[cj-tauri] 告警: ${label} 路径含空格，cjpm 的 link-option 可能解析失败: ${p}")
            return
        }
    }
}

// ===== 文件 =====

func readText(p: String): String {
    return String.fromUtf8(File.readFrom(p))
}

/** 覆盖写（File.create 对已存在文件会抛异常，故先删） */
func writeText(p: String, content: String): Unit {
    if (exists(p)) {
        remove(p)
    }
    let f = File.create(p)
    f.write(content.toArray())
    f.close()
}

func ensureDir(p: String): Unit {
    if (!exists(p)) {
        Directory.create(p, recursive: true)
    }
}

func listDir(p: String): Array<FileInfo> {
    return Directory.readFrom(p)
}

/** TOML 基本字符串转义：反斜杠与双引号 */
func escapeTomlString(p: String): String {
    return p.replace("\\", "\\\\").replace("\"", "\\\"")
}
