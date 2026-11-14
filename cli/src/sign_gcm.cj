/**
 * hvigor `AesGcmKit` 兼容的口令加解密 + AES-128-GCM 纯仓颉实现。
 *
 * 写进 build-profile.json5 的 storePassword / keyPassword 不是明文，而是 DevEco/hvigor
 * 的 AesGcmKit 密文；hvigor 在 SignHap 时用它解开 .p12。要"自己生成一套签名材料"，
 * 就必须能自己造这个密文（移植自灵渠 0.39.13 的实现，算法逐条对齐
 * hvigor-ohos-plugin 的 decipher-util.js）：
 *
 *   material/{ac, ce, fd/0,1,2}      每个目录恰好一个文件（随机 32 hex 文件名）
 *   passphrase = lossyUtf8( XOR(fd0, fd1, fd2, FIXED16) )
 *   rootKey    = PBKDF2-HMAC-SHA256(passphrase, salt, 10000, 16)
 *   workKey    = AES-128-GCM-decrypt(rootKey, payload(ce))
 *   ciphertext = hex( payload( AES-128-GCM-encrypt(workKey, password) ) )
 *   payload(x) = [ len(4B BE)=|ct|+16 | IV(12) | ct | tag(16) ]
 *
 * 两个源码级细节：
 *   ① lossyUtf8：Node 的 Buffer.toString('utf8') 把非法序列换成 U+FFFD 再编码回 UTF-8
 *      才喂给 PBKDF2；直接拿原始字节做 PBKDF2 会得到不同的 rootKey；
 *   ② material/ 是 ~/.ohos/config 级共享的（不是每个 p12 一套），所以同一台机器上
 *      新造的口令密文 hvigor 也解得开。
 *
 * AES-128-GCM 为什么自己写：仓颉 std/stdx 没有 AES（stdx.crypto 只有 SM4，SM4-GCM 实测抛
 * create tag error）。这里只支持 AES-128（16B key），逐 bit GHASH，只用于口令/令牌这种
 * 几十字节的数据，不要拿去加密大文件。
 */

package cli

import std.collection.*
import std.crypto.digest.*
import std.fs.*
import std.time.*
import stdx.crypto.crypto.SecureRandom
import stdx.crypto.digest.*

/** AesGcmKit 的 16 字节固定分量（hvigor 源码常量，别改） */
public let AES_GCM_KIT_FIXED: Array<Byte> = [
    0x31, 0xf3, 0x09, 0x73, 0xd6, 0xaf, 0x5b, 0xb8, 0xd3, 0xbe, 0xb1, 0x58, 0x65, 0x83, 0xc0, 0x77
]

public let AES_GCM_IV_LEN: Int64 = 12
public let AES_GCM_TAG_LEN: Int64 = 16
public let AES_GCM_KEY_LEN: Int64 = 16
public let PBKDF2_ITERATIONS: Int64 = 10000

// ============================================================
// AES-128（ECB 核心，仅供 GCM 内部使用）
// ============================================================

let AES_SBOX: Array<Byte> = [
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16
]

func gcmXtime(x: Int64): Int64 {
    let v = (x << 1) & 0x1FF
    if ((v & 0x100) != 0) {
        return (v & 0xFF) ^ 0x1B
    }
    return v & 0xFF
}

func gcmExpandKey128(key: Array<Byte>): Array<Byte> {
    let w = Array<Byte>(176, repeat: 0)
    for (i in 0..16) {
        w[i] = key[i]
    }
    var rcon: Int64 = 1
    var i: Int64 = 16
    while (i < 176) {
        var t = Array<Int64>(4, repeat: 0)
        for (j in 0..4) {
            t[j] = Int64(w[i - 4 + j])
        }
        if (i % 16 == 0) {
            let tmp = t[0]
            t[0] = Int64(AES_SBOX[t[1]])
            t[1] = Int64(AES_SBOX[t[2]])
            t[2] = Int64(AES_SBOX[t[3]])
            t[3] = Int64(AES_SBOX[tmp])
            t[0] = t[0] ^ rcon
            rcon = gcmXtime(rcon)
        }
        for (j in 0..4) {
            w[i + j] = UInt8((Int64(w[i - 16 + j]) ^ t[j]) & 0xFF)
        }
        i = i + 4
    }
    return w
}

func gcmEncryptBlock128(rk: Array<Byte>, input: Array<Byte>): Array<Byte> {
    var s = Array<Int64>(16, repeat: 0)
    for (i in 0..16) {
        s[i] = Int64(input[i]) ^ Int64(rk[i])
    }
    // state 按列存放：s[4*c + r]
    for (round in 1..=10) {
        let t = Array<Int64>(16, repeat: 0)
        for (c in 0..4) {
            for (r in 0..4) {
                t[4 * c + r] = Int64(AES_SBOX[s[4 * ((c + r) % 4) + r]])
            }
        }
        for (k in 0..16) {
            s[k] = t[k]
        }
        if (round != 10) {
            for (c in 0..4) {
                let a0 = s[4 * c + 0]
                let a1 = s[4 * c + 1]
                let a2 = s[4 * c + 2]
                let a3 = s[4 * c + 3]
                s[4 * c + 0] = gcmXtime(a0) ^ (gcmXtime(a1) ^ a1) ^ a2 ^ a3
                s[4 * c + 1] = a0 ^ gcmXtime(a1) ^ (gcmXtime(a2) ^ a2) ^ a3
                s[4 * c + 2] = a0 ^ a1 ^ gcmXtime(a2) ^ (gcmXtime(a3) ^ a3)
                s[4 * c + 3] = (gcmXtime(a0) ^ a0) ^ a1 ^ a2 ^ gcmXtime(a3)
            }
        }
        for (k in 0..16) {
            s[k] = s[k] ^ Int64(rk[16 * round + k])
        }
    }
    let out = Array<Byte>(16, repeat: 0)
    for (i in 0..16) {
        out[i] = UInt8(s[i] & 0xFF)
    }
    return out
}

// ============================================================
// GF(2^128) 乘法（GHASH 用）
// ============================================================

func gcmXor16(a: Array<Byte>, b: Array<Byte>): Array<Byte> {
    let r = Array<Byte>(16, repeat: 0)
    for (i in 0..16) {
        r[i] = a[i] ^ b[i]
    }
    return r
}

func gcmGf128Mul(x: Array<Byte>, y: Array<Byte>): Array<Byte> {
    var z = Array<Int64>(16, repeat: 0)
    var v = Array<Int64>(16, repeat: 0)
    for (i in 0..16) {
        v[i] = Int64(y[i])
    }
    for (i in 0..128) {
        let bit = (Int64(x[i / 8]) >> (7 - (i % 8))) & 1
        if (bit == 1) {
            for (k in 0..16) {
                z[k] = z[k] ^ v[k]
            }
        }
        let lsb = v[15] & 1
        var carry: Int64 = 0
        for (k in 0..16) {
            let cur = v[k]
            v[k] = (cur >> 1) | (carry << 7)
            carry = cur & 1
        }
        if (lsb == 1) {
            v[0] = v[0] ^ 0xE1
        }
    }
    let out = Array<Byte>(16, repeat: 0)
    for (i in 0..16) {
        out[i] = UInt8(z[i] & 0xFF)
    }
    return out
}

func gcmAbsorb(s0: Array<Byte>, h: Array<Byte>, data: Array<Byte>): Array<Byte> {
    var s = s0
    var i: Int64 = 0
    while (i < data.size) {
        let blk = Array<Byte>(16, repeat: 0)
        var n: Int64 = 0
        while (n < 16 && i + n < data.size) {
            blk[n] = data[i + n]
            n = n + 1
        }
        s = gcmGf128Mul(gcmXor16(s, blk), h)
        i = i + 16
    }
    return s
}

func gcmPutBe64(buf: Array<Byte>, off: Int64, value: Int64) {
    for (i in 0..8) {
        buf[off + i] = UInt8((value >> (56 - 8 * i)) & 0xFF)
    }
}

func gcmInc32(ctr: Array<Byte>) {
    for (i in 0..4) {
        let idx = 15 - i
        if (ctr[idx] == 0xFF) {
            ctr[idx] = 0
        } else {
            ctr[idx] = ctr[idx] + 1
            return
        }
    }
}

func gcmJ0(nonce: Array<Byte>, h: Array<Byte>): Array<Byte> {
    if (nonce.size == 12) {
        let j = Array<Byte>(16, repeat: 0)
        for (i in 0..12) {
            j[i] = nonce[i]
        }
        j[15] = 1
        return j
    }
    var s = gcmAbsorb(Array<Byte>(16, repeat: 0), h, nonce)
    let lenBlk = Array<Byte>(16, repeat: 0)
    gcmPutBe64(lenBlk, 8, nonce.size * 8)
    return gcmGf128Mul(gcmXor16(s, lenBlk), h)
}

// ============================================================
// 对外 API：加密输出 ciphertext || tag(16B)；解密 tag 不符抛异常
// ============================================================

/** AES-128-GCM 加密：返回 ciphertext || tag(16B) */
public func aes128GcmEncrypt(key: Array<Byte>, nonce: Array<Byte>, plaintext: Array<Byte>,
    aad: Array<Byte>): Array<Byte> {
    if (key.size != 16) {
        throw IllegalArgumentException("AES-128 key must be 16 bytes, got ${key.size}")
    }
    if (nonce.size == 0) {
        throw IllegalArgumentException("nonce must not be empty")
    }
    let rk = gcmExpandKey128(key)
    let h = gcmEncryptBlock128(rk, Array<Byte>(16, repeat: 0))
    let j0 = gcmJ0(nonce, h)
    // CTR 模式加密
    let out = ArrayList<Byte>()
    let ctr = Array<Byte>(16, repeat: 0)
    for (i in 0..16) {
        ctr[i] = j0[i]
    }
    var i: Int64 = 0
    while (i < plaintext.size) {
        gcmInc32(ctr)
        let ks = gcmEncryptBlock128(rk, ctr)
        var n: Int64 = 0
        while (n < 16 && i + n < plaintext.size) {
            out.add(plaintext[i + n] ^ ks[n])
            n = n + 1
        }
        i = i + 16
    }
    let ct = out.toArray()
    // tag = E(k, J0) XOR GHASH(aad || ct || len)
    var s = gcmAbsorb(Array<Byte>(16, repeat: 0), h, aad)
    s = gcmAbsorb(s, h, ct)
    let lenBlk = Array<Byte>(16, repeat: 0)
    gcmPutBe64(lenBlk, 0, aad.size * 8)
    gcmPutBe64(lenBlk, 8, ct.size * 8)
    s = gcmGf128Mul(gcmXor16(s, lenBlk), h)
    let tag = gcmXor16(gcmEncryptBlock128(rk, j0), s)
    let sealed = ArrayList<Byte>()
    sealed.add(all: ct)
    sealed.add(all: tag)
    return sealed.toArray()
}

/** AES-128-GCM 解密：输入 ciphertext || tag(16B)，tag 不符抛 IllegalArgumentException */
public func aes128GcmDecrypt(key: Array<Byte>, nonce: Array<Byte>, sealed: Array<Byte>,
    aad: Array<Byte>): Array<Byte> {
    if (sealed.size < 16) {
        throw IllegalArgumentException("sealed data shorter than 16-byte tag")
    }
    let ctLen = sealed.size - 16
    let ct = sealed[0..ctLen]
    let tag = sealed[ctLen..sealed.size]
    let rk = gcmExpandKey128(key)
    let h = gcmEncryptBlock128(rk, Array<Byte>(16, repeat: 0))
    let j0 = gcmJ0(nonce, h)
    var s = gcmAbsorb(Array<Byte>(16, repeat: 0), h, aad)
    s = gcmAbsorb(s, h, ct)
    let lenBlk = Array<Byte>(16, repeat: 0)
    gcmPutBe64(lenBlk, 0, aad.size * 8)
    gcmPutBe64(lenBlk, 8, ct.size * 8)
    s = gcmGf128Mul(gcmXor16(s, lenBlk), h)
    let expect = gcmXor16(gcmEncryptBlock128(rk, j0), s)
    // 常数时间比较
    var diff: Int64 = 0
    for (i in 0..16) {
        diff = diff | (Int64(expect[i] ^ tag[i]))
    }
    if (diff != 0) {
        throw IllegalArgumentException("GCM tag mismatch")
    }
    let out = ArrayList<Byte>()
    let ctr = Array<Byte>(16, repeat: 0)
    for (i in 0..16) {
        ctr[i] = j0[i]
    }
    var i: Int64 = 0
    while (i < ct.size) {
        gcmInc32(ctr)
        let ks = gcmEncryptBlock128(rk, ctr)
        var n: Int64 = 0
        while (n < 16 && i + n < ct.size) {
            out.add(ct[i + n] ^ ks[n])
            n = n + 1
        }
        i = i + 16
    }
    return out.toArray()
}

// ============================================================
// PBKDF2-HMAC-SHA256（RFC 8018）——stdx 没有现成实现，自己写
// ============================================================

/** HMAC-SHA256（32B） */
public func signHmacSha256(key: Array<Byte>, data: Array<Byte>): Array<Byte> {
    let mac = HMAC(key, HashType.SHA256)
    mac.write(data)
    return mac.finish()
}

public func signPbkdf2HmacSha256(password: Array<Byte>, salt: Array<Byte>, iterations: Int64,
    dkLen: Int64): Array<Byte> {
    let hLen: Int64 = 32
    let blocks: Int64 = (dkLen + hLen - 1) / hLen
    let out = ArrayList<Byte>()
    var i: Int64 = 1
    while (i <= blocks) {
        // U1 = HMAC(password, salt || INT32BE(i))
        let first = ArrayList<Byte>()
        first.add(all: salt)
        first.add(UInt8((i >> 24) & 0xFF))
        first.add(UInt8((i >> 16) & 0xFF))
        first.add(UInt8((i >> 8) & 0xFF))
        first.add(UInt8(i & 0xFF))
        var u: Array<Byte> = signHmacSha256(password, first.toArray())
        let acc = u.clone()
        var j: Int64 = 1
        while (j < iterations) {
            u = signHmacSha256(password, u)
            for (k in 0..acc.size) {
                acc[k] = acc[k] ^ u[k]
            }
            j += 1
        }
        out.add(all: acc)
        i += 1
    }
    let all = out.toArray()
    return all[0..dkLen]
}

/**
 * 有损 UTF-8 规范化：合法序列原样保留，非法序列按一个 U+FFFD（EF BF BD）替换。
 *
 * 与 Node Buffer.toString('utf8') 同语义——AesGcmKit 的 passphrase 就是这么来的。
 * 不这么做的后果：rootKey 对不上，解出的 workKey 是错的，hvigor 只报"签名失败"。
 */
public func lossyUtf8Bytes(data: Array<Byte>): Array<Byte> {
    let out = ArrayList<Byte>()
    var i: Int64 = 0
    let n = Int64(data.size)
    while (i < n) {
        let b = Int64(data[i])
        var need: Int64 = 0
        var cp: Int64 = 0
        if (b < 0x80) {
            out.add(UInt8(b))
            i += 1
            continue
        } else if ((b & 0xE0) == 0xC0) {
            need = 1
            cp = b & 0x1F
        } else if ((b & 0xF0) == 0xE0) {
            need = 2
            cp = b & 0x0F
        } else if ((b & 0xF8) == 0xF0) {
            need = 3
            cp = b & 0x07
        } else {
            out.add(all: [0xEF, 0xBF, 0xBD])
            i += 1
            continue
        }
        if (i + need >= n) {
            out.add(all: [0xEF, 0xBF, 0xBD])
            i += 1
            continue
        }
        var ok = true
        var k: Int64 = 1
        while (k <= need) {
            let c = Int64(data[i + k])
            if ((c & 0xC0) != 0x80) {
                ok = false
                break
            }
            cp = (cp << 6) | (c & 0x3F)
            k += 1
        }
        // 过长编码 / 代理区 / 超范围都算非法（Node 同款判断）
        if (ok) {
            let minCp = if (need == 1) { 0x80 } else if (need == 2) { 0x800 } else { 0x10000 }
            if (cp < minCp || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
                ok = false
            }
        }
        if (!ok) {
            out.add(all: [0xEF, 0xBF, 0xBD])
            i += 1
            continue
        }
        for (m in 0..(need + 1)) {
            out.add(data[i + m])
        }
        i = i + need + 1
    }
    return out.toArray()
}

// ============================================================
// 随机源
// ============================================================

/** 随机字节（口令 / IV 用；系统随机源拿不到时退到时间种子，仅影响不可预测性） */
public func signRandomBytes(n: Int64): Array<Byte> {
    try {
        let buf = Array<Byte>(n, repeat: 0)
        SecureRandom().nextBytes(buf)
        return buf
    } catch (e: Exception) {
        let _ = e
        let out = Array<Byte>(n, repeat: 0)
        var seed = Int64(DateTime.now().toUnixTimeStamp().toNanoseconds()) & 0x7FFFFFFFFFFFFFFF
        for (i in 0..n) {
            seed = (seed * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
            out[i] = UInt8((seed >> 33) & 0xFF)
        }
        return out
    }
}

// ============================================================
// AesGcmKit 载荷布局与 workKey
// ============================================================

/** 一段口令密文的三个组成部分 */
public class GcmPayload {
    public var iv: Array<Byte> = []
    public var ciphertext: Array<Byte> = []
    public var tag: Array<Byte> = []
}

/** 按 AesGcmKit 布局打包：[len(4BE) | IV(12) | ct | tag(16)]，len = |ct| + 16 */
public func packGcmPayload(iv: Array<Byte>, ciphertext: Array<Byte>,
    tag: Array<Byte>): Option<Array<Byte>> {
    if (iv.size != AES_GCM_IV_LEN || tag.size != AES_GCM_TAG_LEN) {
        return None
    }
    let bodyLen = Int64(ciphertext.size) + AES_GCM_TAG_LEN
    let out = ArrayList<Byte>()
    out.add(UInt8((bodyLen >> 24) & 0xFF))
    out.add(UInt8((bodyLen >> 16) & 0xFF))
    out.add(UInt8((bodyLen >> 8) & 0xFF))
    out.add(UInt8(bodyLen & 0xFF))
    for (b in iv) {
        out.add(b)
    }
    for (b in ciphertext) {
        out.add(b)
    }
    for (b in tag) {
        out.add(b)
    }
    return Some(out.toArray())
}

/** 拆包（太短 / 声明长度与实到不符 → None） */
public func unpackGcmPayload(raw: Array<Byte>): Option<GcmPayload> {
    let minLen = 4 + AES_GCM_IV_LEN + AES_GCM_TAG_LEN
    if (Int64(raw.size) < minLen) {
        return None
    }
    let bodyLen = (Int64(raw[0]) << 24) | (Int64(raw[1]) << 16) | (Int64(raw[2]) << 8) |
        Int64(raw[3])
    if (bodyLen < AES_GCM_TAG_LEN || 4 + AES_GCM_IV_LEN + bodyLen > Int64(raw.size)) {
        return None
    }
    let p = GcmPayload()
    p.iv = raw[4..(4 + AES_GCM_IV_LEN)]
    let body = raw[(4 + AES_GCM_IV_LEN)..(4 + AES_GCM_IV_LEN + bodyLen)]
    let ctLen = Int64(body.size) - AES_GCM_TAG_LEN
    p.ciphertext = body[0..ctLen]
    p.tag = body[ctLen..body.size]
    return Some(p)
}

/** 小写 hex 编码 */
public func toHexLower(data: Array<Byte>): String {
    let digits = "0123456789abcdef".toArray()
    let out = ArrayList<Byte>()
    for (b in data) {
        let v = Int64(b)
        out.add(digits[(v >> 4) & 15])
        out.add(digits[v & 15])
    }
    return String.fromUtf8(out.toArray())
}

/** hex → 字节（长度奇数或含非 hex 字符时为 None） */
public func fromHexLower(s: String): Option<Array<Byte>> {
    let text = s.trimAscii()
    let bytes = text.toArray()
    if (bytes.size % 2 != 0 || bytes.size == 0) {
        return None
    }
    let out = ArrayList<Byte>()
    var i: Int64 = 0
    while (i < bytes.size) {
        let hi = signHexNibbleOf(bytes[i])
        let lo = signHexNibbleOf(bytes[i + 1])
        if (hi < 0 || lo < 0) {
            return None
        }
        out.add(UInt8((hi << 4) | lo))
        i += 2
    }
    return Some(out.toArray())
}

/** 单个 hex 字符的数值（非 hex 给 -1） */
public func signHexNibbleOf(b: Byte): Int64 {
    if (b >= 48 && b <= 57) {
        return Int64(b - 48)
    }
    if (b >= 97 && b <= 102) {
        return Int64(b - 87)
    }
    if (b >= 65 && b <= 70) {
        return Int64(b - 55)
    }
    return -1
}

/** 拼两段字节 */
public func signConcatBytes(a: Array<Byte>, b: Array<Byte>): Array<Byte> {
    let out = ArrayList<Byte>()
    out.add(all: a)
    out.add(all: b)
    return out.toArray()
}

// ============================================================
// workKey 读取与口令加密（~/.ohos/config/material）
// ============================================================

/** material 目录（与 .p12 同级、~/.ohos/config 级共享） */
public func materialDirOfConfig(configDir: String): String {
    return "${configDir}/material"
}

/** 读目录里恰好一个文件的字节（0 个或多个都算错：DevEco 的约定是"一个目录一个文件"） */
func readUniqueFileBytes(dir: String): (Array<Byte>, String) {
    if (!exists(Path(dir))) {
        return ([], "目录不存在：${dir}")
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(dir)
    } catch (e: Exception) {
        return ([], "读目录失败 ${dir}：${e}")
    }
    let files = ArrayList<String>()
    for (info in entries) {
        if (!info.isDirectory() && info.name != ".DS_Store") {
            files.add("${dir}/${info.name}")
        }
    }
    if (files.size != 1) {
        return ([], "期望 ${dir} 下恰好 1 个文件，实际 ${files.size} 个")
    }
    try {
        return (File.readFrom(files[0]), "")
    } catch (e: Exception) {
        return ([], "读文件失败 ${files[0]}：${e}")
    }
}

/**
 * 从 material/ 解出 workKey（AES-128 的 16 字节）。
 * 失败一律带原因返回（材料缺文件、长度不对、GCM 认证失败都要说清是哪一步）。
 */
public func loadWorkKey(materialDir: String): (Array<Byte>, String) {
    let (salt, e1) = readUniqueFileBytes("${materialDir}/ac")
    if (e1 != "") {
        return ([], "盐（material/ac）：${e1}")
    }
    if (salt.size != AES_GCM_KEY_LEN) {
        return ([], "盐长度应为 ${AES_GCM_KEY_LEN}，实际 ${salt.size}")
    }
    let (ce, e2) = readUniqueFileBytes("${materialDir}/ce")
    if (e2 != "") {
        return ([], "workKey 密文（material/ce）：${e2}")
    }
    let comps = ArrayList<Array<Byte>>()
    for (i in 0..3) {
        let (c, ec) = readUniqueFileBytes("${materialDir}/fd/${i}")
        if (ec != "") {
            return ([], "随机分量 fd/${i}：${ec}")
        }
        if (c.size != AES_GCM_KEY_LEN) {
            return ([], "随机分量 fd/${i} 长度应为 ${AES_GCM_KEY_LEN}，实际 ${c.size}")
        }
        comps.add(c)
    }
    // passphrase = lossyUtf8(XOR(三个分量, 固定分量))
    let xored = Array<Byte>(AES_GCM_KEY_LEN, repeat: 0)
    for (c in comps) {
        for (i in 0..AES_GCM_KEY_LEN) {
            xored[i] = xored[i] ^ c[i]
        }
    }
    for (i in 0..AES_GCM_KEY_LEN) {
        xored[i] = xored[i] ^ AES_GCM_KIT_FIXED[i]
    }
    let passphrase = lossyUtf8Bytes(xored)
    let rootKey = signPbkdf2HmacSha256(passphrase, salt, PBKDF2_ITERATIONS, AES_GCM_KEY_LEN)
    match (unpackGcmPayload(ce)) {
        case Some(p) =>
            var workKey: Array<Byte> = []
            try {
                workKey = aes128GcmDecrypt(rootKey, p.iv,
                    signConcatBytes(p.ciphertext, p.tag), Array<Byte>())
            } catch (e: Exception) {
                return ([], "解 workKey 失败（material/ 与口令不配套）：${e}")
            }
            return (workKey, "")
        case None =>
            return ([], "material/ce 载荷格式不对（应为 len|iv|ct|tag）")
    }
}

/**
 * 口令 → build-profile.json5 里能直接写的那串 hex（AesGcmKit 兼容）。
 * 每次调用 IV 随机 → 同一口令两次加密结果不同（与 DevEco 一致，别写相等断言）。
 */
public func encryptPasswordHex(workKey: Array<Byte>, password: String): (String, String) {
    if (workKey.size != AES_GCM_KEY_LEN) {
        return ("", "workKey 长度应为 ${AES_GCM_KEY_LEN}，实际 ${workKey.size}")
    }
    let iv = signRandomBytes(AES_GCM_IV_LEN)
    let sealed = aes128GcmEncrypt(workKey, iv, password.toArray(), Array<Byte>())
    let ctLen = Int64(sealed.size) - AES_GCM_TAG_LEN
    if (ctLen < 0) {
        return ("", "GCM 输出异常（长度 ${sealed.size}）")
    }
    let ct = sealed[0..ctLen]
    let tag = sealed[ctLen..sealed.size]
    match (packGcmPayload(iv, ct, tag)) {
        case Some(raw) => return (toHexLower(raw), "")
        case None => return ("", "载荷打包失败（IV/tag 长度异常）")
    }
}

/** 反向：hex 密文 + workKey → 明文口令（自检用：证明我们写的密文 hvigor 也解得开） */
public func decryptPasswordHex(workKey: Array<Byte>, hex: String): (String, String) {
    match (fromHexLower(hex)) {
        case Some(raw) =>
            match (unpackGcmPayload(raw)) {
                case Some(p) =>
                    try {
                        let plain = aes128GcmDecrypt(workKey, p.iv,
                            signConcatBytes(p.ciphertext, p.tag), Array<Byte>())
                        return (String.fromUtf8(plain), "")
                    } catch (e: Exception) {
                        return ("", "口令解密失败：${e}")
                    }
                case None =>
                    return ("", "口令密文载荷格式不对")
            }
        case None =>
            return ("", "口令密文不是合法 hex")
    }
}
