package cjTauri

// 共享的 hex 工具：serial / mqtt / redis 三个插件都要做「字节 ↔ 十六进制」换算，
// 放核心共享层（与 scope.cj 同判据：判定逻辑只在共享层，避免插件间互相引用导致连坐链接）。

let HEX_DIGITS: String = "0123456789abcdef"

/** 字节 → 小写十六进制（二进制帧给前端看的就是它） */
public func bytesToHex(bytes: Array<UInt8>): String {
    let digits = HEX_DIGITS.toArray()
    let out = Array<UInt8>(bytes.size * 2, repeat: 0)
    var i = 0
    while (i < bytes.size) {
        let b = bytes[i]
        out[i * 2] = digits[Int64((b >> 4) & UInt8(0x0F))]
        out[i * 2 + 1] = digits[Int64(b & UInt8(0x0F))]
        i++
    }
    return String.fromUtf8(out)
}

/** 十六进制 → 字节；奇数长度或含非十六进制字符返回 None（调用方报可读错误） */
public func hexToBytes(text: String): Option<Array<UInt8>> {
    let src = text.toArray()
    if (src.size % 2 != 0) {
        return None
    }
    let out = Array<UInt8>(src.size / 2, repeat: 0)
    var i = 0
    while (i < out.size) {
        let hi = hexDigit(src[i * 2])
        let lo = hexDigit(src[i * 2 + 1])
        if (hi < 0 || lo < 0) {
            return None
        }
        out[i] = UInt8(hi * 16 + lo)
        i++
    }
    return Some(out)
}

private func hexDigit(b: UInt8): Int64 {
    if (b >= UInt8(48) && b <= UInt8(57)) {
        return Int64(b - UInt8(48))
    }
    if (b >= UInt8(97) && b <= UInt8(102)) {
        return Int64(b - UInt8(87))
    }
    if (b >= UInt8(65) && b <= UInt8(70)) {
        return Int64(b - UInt8(55))
    }
    return -1
}
