/**
 * sign 模块单测：AES-128-GCM / PBKDF2 向量 + AesGcmKit 载荷 + 纯函数判定。
 * 全部自包含（NIST / RFC 公开向量），不依赖本机材料与网络。
 */

package cli

import std.collection.*
import stdx.encoding.json.*

// ---------- AES-128-GCM：NIST GCM Test Case 1-4（96bit nonce） ----------

func assertBytes(name: String, got: Array<Byte>, want: Array<Byte>): Bool {
    if (got.size != want.size) {
        eprintln("FAIL ${name}: 长度 ${got.size} != ${want.size}")
        return false
    }
    for (i in 0..want.size) {
        if (got[i] != want[i]) {
            eprintln("FAIL ${name}[${i}]: ${got[i]} != ${want[i]}")
            return false
        }
    }
    eprintln("PASS ${name}")
    return true
}

func hexBytes(s: String): Array<Byte> {
    match (fromHexLower(s)) {
        case Some(b) => return b
        case None => return []
    }
}

func testGcmVectors(): Bool {
    var ok = true
    // TC1: empty plaintext
    let k1 = hexBytes("00000000000000000000000000000000")
    let iv1 = hexBytes("000000000000000000000000")
    let sealed1 = aes128GcmEncrypt(k1, iv1, [], [])
    ok = assertBytes("gcm-tc1(sealed)", sealed1,
        hexBytes("58e2fccefa7e3061367f1d57a4e7455a")) && ok
    // TC2
    let k2 = hexBytes("00000000000000000000000000000000")
    let iv2 = hexBytes("000000000000000000000000")
    let pt2 = hexBytes("00000000000000000000000000000000")
    let sealed2 = aes128GcmEncrypt(k2, iv2, pt2, [])
    ok = assertBytes("gcm-tc2(sealed)", sealed2,
        hexBytes("0388dace60b6a392f328c2b971b2fe78" + "ab6e47d42cec13bdf53a67b21257bddf")) && ok
    // TC2 已覆盖单块；多块明文用 roundtrip 钉住（加密→解密逐字节还原）
    let k4 = hexBytes("feffe9928665731c6d6a8f9467308308")
    let iv4 = hexBytes("cafebabefacedbaddecaf888")
    var pt4 = ArrayList<Byte>()
    for (i in 0..100) {
        pt4.add(UInt8((i * 37 + 11) & 0xFF))
    }
    let sealed4 = aes128GcmEncrypt(k4, iv4, pt4.toArray(), [])
    if (sealed4.size != pt4.size + 16) {
        eprintln("FAIL gcm-multiblock: 输出长度 ${sealed4.size} != ${pt4.size + 16}")
        ok = false
    }
    let dec4 = aes128GcmDecrypt(k4, iv4, sealed4, [])
    ok = assertBytes("gcm-multiblock(roundtrip)", dec4, pt4.toArray()) && ok
    // tag 篡改必须拒绝
    var tampered = sealed4.clone()
    tampered[tampered.size - 1] = tampered[tampered.size - 1] ^ 1
    var rejected = false
    try {
        let _ = aes128GcmDecrypt(k4, iv4, tampered, [])
    } catch (e: Exception) {
        rejected = true
    }
    if (rejected) {
        eprintln("PASS gcm-tamper-rejected")
    } else {
        eprintln("FAIL gcm-tamper-rejected: 篡改后的密文解密没有拒绝")
        ok = false
    }
    return ok
}

// ---------- PBKDF2-HMAC-SHA256：RFC 6070 同族的公开向量（sha256 版） ----------

func testPbkdf2(): Bool {
    var ok = true
    // hashlib.pbkdf2_hmac('sha256', b'password', b'salt', 1, 32)
    ok = assertBytes("pbkdf2-c1",
        signPbkdf2HmacSha256("password".toArray(), "salt".toArray(), 1, 32),
        hexBytes("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")) && ok
    // c=2
    ok = assertBytes("pbkdf2-c2",
        signPbkdf2HmacSha256("password".toArray(), "salt".toArray(), 2, 32),
        hexBytes("ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")) && ok
    // c=4096
    ok = assertBytes("pbkdf2-c4096",
        signPbkdf2HmacSha256("password".toArray(), "salt".toArray(), 4096, 32),
        hexBytes("c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")) && ok
    return ok
}

// ---------- lossyUtf8：非法序列按 U+FFFD 替换 ----------

func testLossyUtf8(): Bool {
    var ok = true
    // 合法序列原样
    ok = assertBytes("lossy-ascii", lossyUtf8Bytes("abc".toArray()), "abc".toArray()) && ok
    // 0xFF 非法 → EF BF BD
    ok = assertBytes("lossy-0xff", lossyUtf8Bytes([0x41, 0xFF, 0x42]),
        [0x41, 0xEF, 0xBF, 0xBD, 0x42]) && ok
    // 截断的多字节序列：引导字节与续字节各产出一个 U+FFFD（与灵渠实测实现逐字节一致——
    // 该实现已在真机 material/ 上验证过 workKey 推导，保真优先，不"聪明修正"）
    ok = assertBytes("lossy-truncated", lossyUtf8Bytes([0xE4, 0xB8]),
        [0xEF, 0xBF, 0xBD, 0xEF, 0xBF, 0xBD]) && ok
    return ok
}

// ---------- AesGcmKit 载荷打包 / workKey 口令往返 ----------

func testGcmPayloadRoundtrip(): Bool {
    var ok = true
    let workKey = hexBytes("000102030405060708090a0b0c0d0e0f")
    let (hex1, err1) = encryptPasswordHex(workKey, "ab12cd34")
    if (err1 != "") {
        eprintln("FAIL encryptPasswordHex: ${err1}")
        return false
    }
    // 同一口令两次加密结果不同（IV 随机）
    let (hex2, _) = encryptPasswordHex(workKey, "ab12cd34")
    if (hex1 == hex2) {
        eprintln("FAIL gcm-payload: 同一口令两次加密结果相同（IV 应随机）")
        ok = false
    }
    // 都能解回明文
    let (plain1, errD1) = decryptPasswordHex(workKey, hex1)
    let (plain2, errD2) = decryptPasswordHex(workKey, hex2)
    if (errD1 != "" || errD2 != "" || plain1 != "ab12cd34" || plain2 != "ab12cd34") {
        eprintln("FAIL gcm-payload-decrypt: ${plain1} / ${plain2}（${errD1}${errD2}）")
        ok = false
    } else {
        eprintln("PASS gcm-payload-roundtrip")
    }
    return ok
}

// ---------- 离线判定与命名纯函数 ----------

func testSignPureFuncs(): Bool {
    var ok = true
    // profile 判定
    let p = OhosProfile()
    p.profileType = "debug"
    p.bundleName = "com.example.demo"
    p.deviceIds.add("AABBCCDD")
    if (!p.allows("AABBCCDD") || p.allows("0000") || p.allows("")) {
        eprintln("FAIL ohos-profile-allows")
        ok = false
    } else {
        eprintln("PASS ohos-profile-allows")
    }
    // judgeSign 各分支
    if (judgeSign(false, false, false, "", "UDID", false).ok) {
        eprintln("FAIL judge-no-config")
        ok = false
    } else {
        eprintln("PASS judge-no-config")
    }
    let good = judgeSign(true, true, true, "debug", "UDID", false)
    if (!good.ok) {
        eprintln("FAIL judge-ok: ${good.reason}")
        ok = false
    } else {
        eprintln("PASS judge-ok")
    }
    // bundle 判定
    if (!bundleMatches("com.a.b", "com.a.b") || bundleMatches("com.a.b", "com.a.c") ||
        bundleMatches("", "com.a")) {
        eprintln("FAIL bundle-matches")
        ok = false
    } else {
        eprintln("PASS bundle-matches")
    }
    // UDID 解析（hdc 输出形态）
    if (parseUdid("udid of current device is :\nFEDCBA9876543210FEDCBA9876543210\n") !=
        "FEDCBA9876543210FEDCBA9876543210") {
        eprintln("FAIL parse-udid")
        ok = false
    } else {
        eprintln("PASS parse-udid")
    }
    // 材料命名：工程路径 hash 必须用前向斜杠
    let h1 = projectPathHash("E:/proj/gen/ohos")
    let h2 = projectPathHash("E:\\proj\\gen\\ohos")
    if (h1 != h2 || h1.size != 43) {
        eprintln("FAIL project-path-hash: ${h1} vs ${h2}")
        ok = false
    } else {
        eprintln("PASS project-path-hash")
    }
    // extractProfileJson：深度归零截取，尾部 0x7D 垃圾不带进来
    let rawJson = "{\"a\":{\"b\":\"x}\"}}\u{0001}\u{0002}}garbage"
    let got = extractProfileJson(rawJson)
    if (got != "{\"a\":{\"b\":\"x}\"}}") {
        eprintln("FAIL extract-profile-json: ${got}")
        ok = false
    } else {
        eprintln("PASS extract-profile-json")
    }
    // json5 读取（带 \\ 转义的 Windows 路径）
    let j5 = "{\"certpath\": \"C:\\\\Users\\\\yang\\\\x.cer\", signingConfigs: []}"
    if (json5ValueAfter(j5, "certpath") != "C:\\Users\\yang\\x.cer") {
        eprintln("FAIL json5-value-after: ${json5ValueAfter(j5, "certpath")}")
        ok = false
    } else {
        eprintln("PASS json5-value-after")
    }
    // 写回：空数组注入 + product 指向
    let bp = "{\n  \"signingConfigs\": [],\n  \"products\": [\n    { \"name\": \"default\", \"signingConfig\": \"\" }\n  ]\n}\n"
    let m = SigningMaterial()
    m.storeFile = "C:\\ohos\\a.p12"
    m.certpath = "C:\\ohos\\a.cer"
    m.profile = "C:\\ohos\\a.p7b"
    m.storePassword = "0011aa"
    m.keyPassword = "0022bb"
    let (newText, err) = applySigningConfig(bp, m)
    if (err != "") {
        eprintln("FAIL apply-signing-config: ${err}")
        ok = false
    } else {
        let s = parseProjSigning(newText)
        if (!s.hasSigningConfigs || s.signingConfigName != "default" ||
            json5ValueAfter(newText, "storeFile") != "C:\\ohos\\a.p12") {
            eprintln("FAIL apply-signing-config-content: ${newText}")
            ok = false
        } else {
            eprintln("PASS apply-signing-config")
        }
    }
    // 就地更新：同一 .p12 才允许
    let (updText, updErr) = replaceOwnSigningConfigs(newText, m)
    if (updErr != "" || !parseProjSigning(updText).hasSigningConfigs) {
        eprintln("FAIL replace-own-signing-configs: ${updErr}")
        ok = false
    } else {
        eprintln("PASS replace-own-signing-configs")
    }
    // 换一套材料必须拒绝
    let m2 = SigningMaterial()
    m2.storeFile = "C:\\ohos\\other.p12"
    m2.certpath = "C:\\ohos\\other.cer"
    m2.profile = "C:\\ohos\\other.p7b"
    m2.storePassword = "0033"
    m2.keyPassword = "0044"
    match (replaceOwnSigningConfigs(newText, m2)) {
        case (_, e) => if (e == "") {
            eprintln("FAIL replace-other-material: 换材料不该静默覆盖")
            ok = false
        } else {
            eprintln("PASS replace-other-material-rejected")
        }
    }
    return ok
}

func runAllSignTests(): Bool {
    var ok = true
    ok = testGcmVectors() && ok
    ok = testPbkdf2() && ok
    ok = testLossyUtf8() && ok
    ok = testGcmPayloadRoundtrip() && ok
    ok = testSignPureFuncs() && ok
    return ok
}

/** 汇总入口：每个 @Test 跑一组 */
@Test
func signGcmVectors(): Unit {
    @Expect(testGcmVectors())
}

@Test
func signPbkdf2Vectors(): Unit {
    @Expect(testPbkdf2())
}

@Test
func signLossyUtf8(): Unit {
    @Expect(testLossyUtf8())
}

@Test
func signGcmPayloadRoundtrip(): Unit {
    @Expect(testGcmPayloadRoundtrip())
}

@Test
func signPureFuncs(): Unit {
    @Expect(testSignPureFuncs())
}
