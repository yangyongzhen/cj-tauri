/**
 * 鸿蒙真机签名 · 离线层：profile 解析 / UDID / 本机材料扫描 / 体检判定 / 写回 build-profile。
 *
 * 背景真机实测：鸿蒙真机只信任「华为签发、且 profile 的 device-ids 含本机 UDID」的证书，
 * 且 profile（.p7b）是按 bundleName 签发的——别的包名的材料哪怕含本机也不能用
 * （hvigor 报 00303074）。所以"能不能装"可以完全本地判定：
 *
 *   ① ~/.ohos/config/default_<工程>_<hash>.p7b 是 PKCS#7 包着一个明文 JSON
 *      （type / bundle-info.bundle-name / debug-info.device-ids），直接按字节取 JSON 解析；
 *   ② 本机 UDID 用 `hdc shell bm get --udid` 取；
 *   ③ 两边对上 + 包名一致 → signingConfigs 写回 build-profile.json5 即可直装。
 *
 * 口令密文为什么能自己造：material/ 目录（~/.ohos/config 级共享）里有 workKey 材料，
 * sign_gcm.cj 按同一算法加密的密文 hvigor 解得开。
 */

package cli

import std.collection.*
import std.crypto.digest.*
import std.env.*
import std.fs.*
import std.process.*
import std.time.*
import stdx.crypto.digest.*
import stdx.encoding.json.*

// ============================================================
// profile（.p7b）解析
// ============================================================

/** 一份 profile 的关键信息（从 .p7b 里嵌的 JSON 解析） */
public class OhosProfile {
    public var p7bPath: String = ""
    public var profileType: String = ""   // debug / release（`type` 是仓颉关键字，不能当字段名）
    public var bundleName: String = ""
    public var deviceIds: ArrayList<String> = ArrayList<String>()
    public var parseError: String = ""

    /** 这台设备能不能用这份 profile 装 */
    public func allows(udid: String): Bool {
        if (this.profileType != "debug") {
            return false
        }
        for (d in this.deviceIds) {
            if (d == udid) {
                return true
            }
        }
        return false
    }
}

/**
 * 从 .p7b 原始字节（按 ASCII 净化视图）里取出内嵌的 JSON 文档。
 *
 * .p7b 是 PKCS#7 二进制，高位字节不是合法 UTF-8，强转会吞字节或抛错。
 * profile 里的 JSON 是明文（DER 之后紧跟），但从第一个 `{` 扫到**深度归零**的那个 `}`
 * 才算安全——后面是证书等二进制，`0x7D` 会原样留下成 `}`，"取最后一个 `}`"
 * 会把尾部垃圾带进 JSON。扫描时按字符串字面量/转义规则跳过，避免 `"..."` 里的花括号干扰配对。
 */
public func extractProfileJson(raw: String): String {
    let bytes = raw.toArray()
    let openBrace: UInt8 = 123
    let closeBrace: UInt8 = 125
    let dquote: UInt8 = 34
    let backslash: UInt8 = 92
    var start: Int64 = -1
    for (i in 0..bytes.size) {
        if (bytes[i] == openBrace) {
            start = i
            break
        }
    }
    if (start < 0) {
        return ""
    }
    var depth: Int64 = 0
    var inStr = false
    var esc = false
    var i = start
    while (i < bytes.size) {
        let c = bytes[i]
        if (inStr) {
            if (esc) {
                esc = false
            } else if (c == backslash) {
                esc = true
            } else if (c == dquote) {
                inStr = false
            }
        } else if (c == dquote) {
            inStr = true
        } else if (c == openBrace) {
            depth++
        } else if (c == closeBrace) {
            depth--
            if (depth == 0) {
                return String.fromUtf8(bytes[start..(i + 1)])
            }
        }
        i++
    }
    return ""
}

func signStrFieldOf(o: JsonObject, key: String): String {
    match (o.get(key)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsString => return v.asString().getValue()
            case _ => return ""
        }
        case None => return ""
    }
}

func signArrFieldOf(o: JsonObject, key: String): ArrayList<String> {
    let out = ArrayList<String>()
    match (o.get(key)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsArray =>
                let arr = v.asArray()
                for (i in 0..arr.size()) {
                    let e = arr.get(i).getOrThrow()
                    match (e.kind()) {
                        case JsonKind.JsString => out.add(e.asString().getValue())
                        case _ => ()
                    }
                }
            case _ => ()
        }
        case None => ()
    }
    return out
}

/** 解析 profile 内嵌 JSON（结构：type / bundle-info.bundle-name / debug-info.device-ids） */
public func parseOhosProfile(json: String, p7bPath: String): OhosProfile {
    let p = OhosProfile()
    p.p7bPath = p7bPath
    let text = json.trimAscii()
    if (text.size == 0) {
        p.parseError = "profile 里没找到 JSON 文档"
        return p
    }
    var root: JsonValue
    try {
        root = JsonValue.fromStr(text)
    } catch (e: Exception) {
        p.parseError = "profile JSON 解析失败：${e}"
        return p
    }
    match (root.kind()) {
        case JsonKind.JsObject => ()
        case _ =>
            p.parseError = "profile JSON 不是对象"
            return p
    }
    let obj = root.asObject()
    p.profileType = signStrFieldOf(obj, "type")
    // bundle-name 在 bundle-info 里
    match (obj.get("bundle-info")) {
        case Some(bi) => match (bi.kind()) {
            case JsonKind.JsObject =>
                p.bundleName = signStrFieldOf(bi.asObject(), "bundle-name")
            case _ => ()
        }
        case None => ()
    }
    if (p.bundleName == "") {
        p.bundleName = signStrFieldOf(obj, "bundle-name")
    }
    // device-ids 在 debug-info 里（个别版本在顶层）
    var ids = signArrFieldOf(obj, "device-ids")
    if (ids.size == 0) {
        match (obj.get("debug-info")) {
            case Some(di) => match (di.kind()) {
                case JsonKind.JsObject => ids = signArrFieldOf(di.asObject(), "device-ids")
                case _ => ()
            }
            case None => ()
        }
    }
    p.deviceIds = ids
    return p
}

/** 字节 → ASCII 净化视图：可打印 ASCII 原样保留，其余统一换成空格（见 extractProfileJson 的理由） */
public func signLatin1Of(data: Array<UInt8>): String {
    let view = Array<UInt8>(data.size, repeat: 32)
    for (i in 0..data.size) {
        let b = data[i]
        if (b >= 32 && b <= 126) {
            view[i] = b
        }
    }
    return String.fromUtf8(view)
}

/** 扫 configDir（~/.ohos/config）下的 .p7b，返回能解析的 profile 列表（解析失败也收，带 parseError） */
public func discoverProfiles(configDir: String): ArrayList<OhosProfile> {
    let out = ArrayList<OhosProfile>()
    if (!exists(Path(configDir))) {
        return out
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(configDir)
    } catch (e: Exception) {
        let _ = e
        return out
    }
    for (info in entries) {
        if (info.isDirectory() || !info.name.endsWith(".p7b")) {
            continue
        }
        let p = "${configDir}/${info.name}"
        try {
            let raw = signLatin1Of(File.readFrom(p))
            out.add(parseOhosProfile(extractProfileJson(raw), p))
        } catch (e: Exception) {
            let bad = OhosProfile()
            bad.p7bPath = p
            bad.parseError = "读不到：${e}"
            out.add(bad)
        }
    }
    return out
}

/** 在候选材料里挑「type=debug 且含本机 UDID」的那份；bundle 非空时还要包名一致 */
public func pickProfile(cands: ArrayList<OhosProfile>, udid: String, bundle: String): Option<OhosProfile> {
    for (p in cands) {
        if (!p.allows(udid)) {
            continue
        }
        if (bundle != "" && p.bundleName != bundle) {
            continue
        }
        return Some(p)
    }
    return None
}

// ============================================================
// UDID
// ============================================================

func signIsHexDigit(b: UInt8): Bool {
    return (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102)
}

/**
 * 从 `hdc shell bm get --udid` 的输出里取 UDID。
 * 不按固定排版解析（不同 hdc 版本前缀文案会变），而是取最长的连续十六进制串（≥16 位）。
 */
public func parseUdid(out: String): String {
    let bytes = out.toArray()
    var best = ""
    var i: Int64 = 0
    while (i < bytes.size) {
        if (signIsHexDigit(bytes[i])) {
            let begin = i
            while (i < bytes.size && signIsHexDigit(bytes[i])) {
                i++
            }
            if (i - begin >= 16) {
                let cand = String.fromUtf8(bytes[begin..i])
                if (cand.size > best.size) {
                    best = cand
                }
            }
        } else {
            i++
        }
    }
    return best
}

/** 调 hdc 取本机设备 UDID（拿不到返回空串） */
public func deviceUdidViaHdc(hdcPath: String): String {
    if (hdcPath == "") {
        return ""
    }
    try {
        let (code, out, _) = executeWithOutput(hdcPath, ["shell", "bm", "get", "--udid"])
        if (code != 0) {
            return ""
        }
        return parseUdid(lenientUtf8(out))
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

// ============================================================
// 工程 build-profile.json5 的轻量 JSON5 读取
// ============================================================

/** 从 JSON5 文本里取 "key" 之后的值（支持双引号/单引号/裸值；取不到返回 ""） */
public func json5ValueAfter(text: String, key: String): String {
    let marker = "\"${key}\""
    let at = text.indexOf(marker)
    var pos: Int64 = 0
    match (at) {
        case Some(i) => pos = i + marker.size
        case None =>
            // 无引号键（JSON5 允许）：退化成找 key 后跟冒号
            match (text.indexOf("${key}:")) {
                case Some(j) => pos = j + key.size
                case None => return ""
            }
    }
    let bytes = text.toArray()
    var i = pos
    // 跳到冒号
    while (i < bytes.size && bytes[i] != 58 && bytes[i] != 10 && bytes[i] != 13) {
        i++
    }
    if (i >= bytes.size || bytes[i] != 58) {
        return ""
    }
    i++
    // 跳过空白
    while (i < bytes.size && (bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13)) {
        i++
    }
    if (i >= bytes.size) {
        return ""
    }
    let dq: UInt8 = 34
    let sq: UInt8 = 39
    if (bytes[i] == dq || bytes[i] == sq) {
        let q = bytes[i]
        i++
        let begin = i
        var esc = false
        while (i < bytes.size) {
            let c = bytes[i]
            if (esc) {
                esc = false
            } else if (c == 92) {
                esc = true
            } else if (c == q) {
                return signUnescapeJson5(String.fromUtf8(bytes[begin..i]))
            }
            i++
        }
        return ""
    }
    // 裸值：读到分隔符为止
    let begin = i
    while (i < bytes.size) {
        let c = bytes[i]
        if (c == 44 || c == 125 || c == 93 || c == 10 || c == 13 || c == 32 || c == 9) {
            break
        }
        i++
    }
    return String.fromUtf8(bytes[begin..i])
}

/**
 * JSON5 字符串值的转义还原。
 * Windows 上 build-profile.json5 的路径写成 "D:\\oh\\...\\x.cer"，不还原就带着双反斜杠
 * 去做 exists() 判断 → 永远"文件不存在"。只处理常见转义，\uXXXX 按原样保留。
 */
public func signUnescapeJson5(raw: String): String {
    let bytes = raw.toArray()
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < bytes.size) {
        let c = bytes[i]
        if (c != 92 || i + 1 >= bytes.size) {
            out.add(c)
            i++
            continue
        }
        let n = bytes[i + 1]
        if (n == 110) {          // n
            out.add(10)
        } else if (n == 116) {   // t
            out.add(9)
        } else if (n == 114) {   // r
            out.add(13)
        } else if (n == 98) {    // b
            out.add(8)
        } else if (n == 102) {   // f
            out.add(12)
        } else if (n == 117) {   // u：不还原，原样保留（路径里不该出现）
            out.add(c)
            out.add(n)
            i += 2
            continue
        } else {
            // \\ \" \/ \' 等：反斜杠是转义符，丢掉它只留字符
            out.add(n)
        }
        i += 2
    }
    return String.fromUtf8(out.toArray())
}

/** 工程 build-profile.json5 里与签名相关的信息（轻量 JSON5 提取，不用 JSON 库——json5 严格解析器读不了） */
public class ProjSigning {
    public var hasSigningConfigs: Bool = false
    public var signingConfigName: String = ""
    public var certPath: String = ""
    public var profilePath: String = ""
    public var storeFile: String = ""
    public var certType: String = ""
}

/** 解析 build-profile.json5 文本 → 签名相关信息 */
public func parseProjSigning(text: String): ProjSigning {
    let s = ProjSigning()
    if (text == "") {
        return s
    }
    s.signingConfigName = json5ValueAfter(text, "signingConfig")
    s.certPath = json5ValueAfter(text, "certpath")
    s.profilePath = json5ValueAfter(text, "profile")
    s.storeFile = json5ValueAfter(text, "storeFile")
    s.certType = json5ValueAfter(text, "type")
    // signingConfigs 是否非空：定位键后看紧邻的 [ 里是不是立刻 ]
    var from: Int64 = -1
    match (text.indexOf("\"signingConfigs\"")) {
        case Some(at) => from = at + "\"signingConfigs\"".size
        case None => match (text.indexOf("signingConfigs:")) {
            case Some(at) => from = at + "signingConfigs:".size
            case None => ()
        }
    }
    if (from >= 0) {
        let bytes = text.toArray()
        var i = from
        var sawOpen = false
        while (i < bytes.size) {
            let c = bytes[i]
            if (c == 91) {   // [
                sawOpen = true
                i++
                break
            }
            if (c == 123 || c == 34 || c == 93) {   // { " ]
                break
            }
            i++
        }
        if (sawOpen) {
            while (i < bytes.size) {
                let c = bytes[i]
                if (c == 93) {   // ]
                    break
                }
                if (c == 32 || c == 9 || c == 10 || c == 13 || c == 44) {
                    i++
                    continue
                }
                s.hasSigningConfigs = true
                break
            }
        }
    }
    return s
}

// ============================================================
// 体检判定
// ============================================================

/** hvigor 的包名不匹配错误码（写进 reason 里，方便按报错原文检索） */
public let SIGN_BUNDLE_MISMATCH_CODE: String = "00303074"

/** 签名体检结论 */
public class SignCheck {
    public var ok: Bool = false
    public var reason: String = ""
    public var nextStep: String = ""
    public var configuredName: String = ""
    public var configuredFilesExist: Bool = false
    public var configuredAllowsDevice: Bool = false
    public var udid: String = ""
    /** 本机候选材料的包名是否等于工程 bundleName（hvigor 在 SignHap 会校验） */
    public var bundleMatch: Bool = true

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("ok", JsonBool(this.ok))
        o.put("reason", JsonString(this.reason))
        o.put("nextStep", JsonString(this.nextStep))
        o.put("configuredName", JsonString(this.configuredName))
        o.put("configuredFilesExist", JsonBool(this.configuredFilesExist))
        o.put("configuredAllowsDevice", JsonBool(this.configuredAllowsDevice))
        o.put("udid", JsonString(this.udid))
        o.put("bundleMatch", JsonBool(this.bundleMatch))
        return o
    }
}

/** 纯判定：给定工程的签名配置是否齐全 + profile 是否含本机 UDID，给出能否直装与下一步 */
public func judgeSign(hasConfig: Bool, filesExist: Bool, allowsDevice: Bool, profileType: String,
    udid: String, hasCandidate: Bool): SignCheck {
    let c = SignCheck()
    c.udid = udid
    c.configuredFilesExist = filesExist
    c.configuredAllowsDevice = allowsDevice
    if (udid == "") {
        c.ok = false
        c.reason = "拿不到设备 UDID（设备没连？跑 `hdc shell bm get --udid` 看看）"
        c.nextStep = "连上鸿蒙设备并开启 USB 调试后重试"
        return c
    }
    if (!hasConfig) {
        c.ok = false
        c.reason = "工程的 build-profile.json5 里没有 signingConfigs（或 products 没指 signingConfig）"
        if (hasCandidate) {
            c.nextStep = "机器上已有匹配本机 UDID 的材料：跑 `cj-tauri sign --apply` 把它写回 build-profile.json5"
        } else {
            c.nextStep = "跑 `cj-tauri sign --login`（网页登录 AGC 一次）+ `cj-tauri sign --auto`，为本机 UDID 与本包名现签一套材料"
        }
        return c
    }
    if (!filesExist) {
        c.ok = false
        c.reason = "signingConfigs 指向的 .p12/.cer/.p7b 有文件不存在（材料被删/换机器）"
        c.nextStep = "确认 certpath/profile/storeFile 三个路径都存在；缺了就跑 `cj-tauri sign --auto` 重新签发"
        return c
    }
    if (profileType != "debug") {
        c.ok = false
        c.reason = "当前 signingConfig 用的是 ${profileType} profile（上架用，不含 device-ids），真机直装必失败 9568322"
        c.nextStep = "products[].signingConfig 切到 debug 那份（上架前再切回 release）"
        return c
    }
    if (!allowsDevice) {
        c.ok = false
        c.reason = "profile 的 device-ids 里没有本机 UDID（设备没注册进这份 profile）"
        c.nextStep = "跑 `cj-tauri sign --login` + `cj-tauri sign --auto` 把本机注册进这个包名的 profile，或换一份含本机 UDID 的材料"
        return c
    }
    c.ok = true
    c.reason = "签名配置齐全，且 profile 绑定了本机 UDID，可直装"
    c.nextStep = "hvigor assembleHap → hdc install -r → aa start"
    return c
}

/** 候选材料的包名是否等于工程包名（两边都非空且逐字符相等；bundleName 区分大小写） */
public func bundleMatches(projectBundle: String, candidateBundle: String): Bool {
    let a = projectBundle.trimAscii()
    let b = candidateBundle.trimAscii()
    if (a == "" || b == "") {
        return false
    }
    return a == b
}

/** 本机材料的包名清单（回答"为什么没有我这个包名的"）：com.a(27台/含本机)、com.b(26台/含本机) */
public func profileBundleCensus(cands: ArrayList<OhosProfile>, udid: String): String {
    var text = ""
    for (p in cands) {
        if (p.parseError != "" || p.bundleName == "") {
            continue
        }
        if (text != "") {
            text += "、"
        }
        let allows = if (udid == "") { "UDID未知" } else if (p.allows(udid)) { "含本机" } else {
            "不含本机"
        }
        text += "${p.bundleName}(${p.deviceIds.size}台/${allows})"
    }
    return text
}

// ============================================================
// 写回签名配置（apply）
// ============================================================

/** 一段 signingConfigs 里 material 的字段（口令是密文，原样写回） */
public class SigningMaterial {
    public var name: String = "default"
    public var certType: String = "HarmonyOS"
    public var storeFile: String = ""
    public var storePassword: String = ""
    public var keyAlias: String = "debugKey"
    public var keyPassword: String = ""
    public var signAlg: String = "SHA256withECDSA"
    public var profile: String = ""
    public var certpath: String = ""

    /** 口令齐了才算可用（缺口令的块写回去 hvigor 也解不开） */
    public func complete(): Bool {
        if (this.storeFile == "" || this.profile == "" || this.certpath == "") {
            return false
        }
        return this.storePassword != "" && this.keyPassword != ""
    }
}

/** 路径取文件名（两种分隔符都认） */
public func signFileNameOf(p: String): String {
    var cut: Int64 = -1
    let bytes = p.toArray()
    for (i in 0..bytes.size) {
        if (bytes[i] == 47 || bytes[i] == 92) {
            cut = i
        }
    }
    if (cut < 0) {
        return p
    }
    return p[(cut + 1)..]
}

/** 两个路径是不是指向同一份材料（只比文件名：材料都在 ~/.ohos/config 下，文件名即身份） */
public func sameMaterialFile(a: String, b: String): Bool {
    if (a == "" || b == "") {
        return false
    }
    return signLowerAsciiOf(signFileNameOf(a)) == signLowerAsciiOf(signFileNameOf(b))
}

/** ASCII 小写化 */
public func signLowerAsciiOf(s: String): String {
    let bytes = s.toArray()
    for (i in 0..bytes.size) {
        let b = bytes[i]
        if (b >= 65 && b <= 90) {
            bytes[i] = b + 32
        }
    }
    return String.fromUtf8(bytes)
}

/** 从工程 build-profile.json5 文本里读出那份 signingConfigs 的字段（读不到字段就留空） */
public func signingMaterialOf(text: String): SigningMaterial {
    let m = SigningMaterial()
    let name = json5ValueAfter(text, "name")
    if (name != "") {
        m.name = name
    }
    let t = json5ValueAfter(text, "type")
    if (t != "") {
        m.certType = t
    }
    m.storeFile = json5ValueAfter(text, "storeFile")
    m.storePassword = json5ValueAfter(text, "storePassword")
    let alias = json5ValueAfter(text, "keyAlias")
    if (alias != "") {
        m.keyAlias = alias
    }
    m.keyPassword = json5ValueAfter(text, "keyPassword")
    let alg = json5ValueAfter(text, "signAlg")
    if (alg != "") {
        m.signAlg = alg
    }
    m.profile = json5ValueAfter(text, "profile")
    m.certpath = json5ValueAfter(text, "certpath")
    return m
}

/** 写进 json5 的字符串要做反向转义（Windows 路径的 `\` 必须成 `\\`） */
public func signJson5EscapeOf(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<UInt8>()
    for (b in bytes) {
        if (b == 92) {
            out.add(92)
            out.add(92)
        } else if (b == 34) {
            out.add(92)
            out.add(34)
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

/** 按 DevEco 的结构生成 signingConfigs 数组里的那一块（缩进按 indent 对齐） */
public func signingBlockJson5(m: SigningMaterial, indent: String): String {
    let i1 = indent
    let i2 = indent + "  "
    let i3 = indent + "    "
    return "${i1}{\n" +
        "${i2}\"name\": \"${m.name}\",\n" +
        "${i2}\"type\": \"${m.certType}\",\n" +
        "${i2}\"material\": {\n" +
        "${i3}\"certpath\": \"${signJson5EscapeOf(m.certpath)}\",\n" +
        "${i3}\"storePassword\": \"${m.storePassword}\",\n" +
        "${i3}\"keyAlias\": \"${m.keyAlias}\",\n" +
        "${i3}\"keyPassword\": \"${m.keyPassword}\",\n" +
        "${i3}\"profile\": \"${signJson5EscapeOf(m.profile)}\",\n" +
        "${i3}\"signAlg\": \"${m.signAlg}\",\n" +
        "${i3}\"storeFile\": \"${signJson5EscapeOf(m.storeFile)}\"\n" +
        "${i2}}\n" +
        "${i1}}"
}

/**
 * 定位 signingConfigs 的 [ 与配对的 ]。
 * 返回 (open 下标, close 下标, 键所在行的缩进, 错误)。扫描按深度配对并跳过 json5 字符串——
 * 就地更新时要处理"数组里已经有内容"的形态，"遇到第一个 ] 就停"只在空数组上成立。
 */
func locateSigningArray(text: String): (Int64, Int64, String, String) {
    let bytes = text.toArray()
    var keyEnd: Int64 = -1
    var lineStart: Int64 = 0
    match (text.indexOf("\"signingConfigs\"")) {
        case Some(at) =>
            keyEnd = at + "\"signingConfigs\"".size
            lineStart = at
        case None => match (text.indexOf("signingConfigs:")) {
            case Some(at) =>
                keyEnd = at + "signingConfigs:".size
                lineStart = at
            case None => return (-1, -1, "", "找不到 signingConfigs 字段（build-profile.json5 结构不认识）")
        }
    }
    // 该行的缩进：从键位置往回找到行首
    while (lineStart > 0 && bytes[lineStart - 1] != 10 && bytes[lineStart - 1] != 13) {
        lineStart--
    }
    var indentLen: Int64 = 0
    while (lineStart + indentLen < keyEnd && (bytes[lineStart + indentLen] == 32 || bytes[lineStart + indentLen] == 9)) {
        indentLen++
    }
    let keyIndent = String.fromUtf8(bytes[lineStart..(lineStart + indentLen)])
    // 找紧邻的 [
    var i = keyEnd
    while (i < bytes.size && bytes[i] != 91) {   // [
        if (bytes[i] == 123 || bytes[i] == 125) {   // { }
            return (-1, -1, "", "signingConfigs 后面没找到数组")
        }
        i++
    }
    if (i >= bytes.size) {
        return (-1, -1, "", "signingConfigs 后面没找到数组")
    }
    let open = i
    var depth: Int64 = 0
    var inStr = false
    var esc = false
    i++
    while (i < bytes.size) {
        let c = bytes[i]
        if (inStr) {
            if (esc) {
                esc = false
            } else if (c == 92) {        // \
                esc = true
            } else if (c == 34) {        // "
                inStr = false
            }
        } else if (c == 34) {
            inStr = true
        } else if (c == 91) {            // [
            depth++
        } else if (c == 93) {            // ]
            if (depth == 0) {
                return (open, i, keyIndent, "")
            }
            depth--
        }
        i++
    }
    return (-1, -1, "", "signingConfigs 数组没闭合")
}

/** [ 与 ] 之间是不是只有空白与逗号（即"空数组"） */
func arrayBodyIsBlank(text: String, open: Int64, close: Int64): Bool {
    let bytes = text.toArray()
    if (open < 0 || close <= open || close >= bytes.size) {
        return false
    }
    for (i in (open + 1)..close) {
        let c = bytes[i]
        if (c != 32 && c != 9 && c != 10 && c != 13 && c != 44) {
            return false
        }
    }
    return true
}

/**
 * 就地更新已有的 signingConfigs（只允许在同一套材料上更新）。
 * 复用本地 p12 时 .p7b/.cer 会因证书换发而变，此时 block 已存在——按"非空就拒绝"会让
 * 整条路线死在最后一步。安全边界：只有工程里那份 storeFile 与要写的是同一个 .p12 文件名
 * 才就地更新；换材料不做静默覆盖，报错让人决定。
 */
public func replaceOwnSigningConfigs(text: String, m: SigningMaterial): (String, String) {
    if (text == "") {
        return ("", "build-profile.json5 内容为空")
    }
    if (!m.complete()) {
        return ("", "材料不完整（缺 .p12/.cer/.p7b 或口令密文），无法写回")
    }
    // 判序：先看"有没有东西可更新"，再看"是不是同一套材料"（反过来空数组也落进"另一套材料"的报错）
    if (!parseProjSigning(text).hasSigningConfigs) {
        return ("", "signingConfigs 是空数组，应该走注入而不是更新")
    }
    let cur = signingMaterialOf(text)
    if (!sameMaterialFile(cur.storeFile, m.storeFile)) {
        return ("", "工程里已有另一套签名材料（${cur.storeFile}），不做覆盖（要换材料请先清空 signingConfigs）")
    }
    let (open, close, keyIndent, loErr) = locateSigningArray(text)
    if (loErr != "") {
        return ("", loErr)
    }
    // 名字沿用工程里那份：products[].signingConfig 指的就是它，改名会打断这条引用
    let keepName = if (cur.name != "") { cur.name } else { m.name }
    let savedName = m.name
    m.name = keepName
    let elemIndent = keyIndent + "  "
    let body = "[\n${signingBlockJson5(m, elemIndent)}\n${keyIndent}]"
    m.name = savedName
    let bytes = text.toArray()
    let head = String.fromUtf8(bytes[0..open])
    let tail = String.fromUtf8(bytes[(close + 1)..bytes.size])
    return (head + body + tail, "")
}

/**
 * 把一块 signingConfigs 注入 build-profile.json5 文本（纯文本手术，不重排整份文件）。
 * 只处理"signingConfigs 是空数组"这一种情况（其余一律不动）。返回 (新文本, 错误)。
 */
public func injectSigningConfigs(text: String, m: SigningMaterial): (String, String) {
    if (text == "") {
        return ("", "build-profile.json5 内容为空")
    }
    if (parseProjSigning(text).hasSigningConfigs) {
        return ("", "工程里已经有非空的 signingConfigs，不做覆盖（要重配请先手动清空）")
    }
    let (open, close, keyIndent, loErr) = locateSigningArray(text)
    if (loErr != "") {
        return ("", loErr)
    }
    if (!arrayBodyIsBlank(text, open, close)) {
        return ("", "signingConfigs 数组非空（或结构异常），不做覆盖")
    }
    let elemIndent = keyIndent + "  "
    let body = "[\n${signingBlockJson5(m, elemIndent)}\n${keyIndent}]"
    let bytes = text.toArray()
    let head = String.fromUtf8(bytes[0..open])
    // 从 ] 的下一个字符开始接原文：body 自己带了收尾的 ]，从 close 起接会多出一个 ]
    let tail = String.fromUtf8(bytes[(close + 1)..bytes.size])
    return (head + body + tail, "")
}

/** 把 products[].signingConfig 指到 name。已指向目标（不动）/ 空串（填上）/ 指向别的名字（报错）。 */
public func pointProductSigningConfig(text: String, name: String): (String, String) {
    if (text == "") {
        return ("", "build-profile.json5 内容为空")
    }
    if (name == "") {
        return ("", "签名配置名为空")
    }
    let marker = "\"signingConfig\""
    var at: Int64 = -1
    match (text.indexOf(marker)) {
        case Some(i) => at = i
        case None =>
            // products 里没有 signingConfig 键（模板缺省形态）：在第一个元素的 "name" 值后面插入
            return insertProductSigningConfig(text, name)
    }
    let bytes = text.toArray()
    var i = at + marker.size
    while (i < bytes.size && bytes[i] != 58 && bytes[i] != 10) {
        i++
    }
    if (i >= bytes.size || bytes[i] != 58) {
        return ("", "products[].signingConfig 后面没有冒号")
    }
    i++
    while (i < bytes.size && (bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13)) {
        i++
    }
    if (i >= bytes.size || bytes[i] != 34) {   // "
        return ("", "products[].signingConfig 的值不是字符串")
    }
    let valueStart = i + 1
    var valueEnd = valueStart
    while (valueEnd < bytes.size && bytes[valueEnd] != 34) {
        valueEnd++
    }
    if (valueEnd >= bytes.size) {
        return ("", "products[].signingConfig 的字符串没闭合")
    }
    let current = String.fromUtf8(bytes[valueStart..valueEnd])
    if (current == name) {
        return (text, "")
    }
    if (current != "") {
        return ("", "products[].signingConfig 已指向「${current}」，不自动改（请手动确认）")
    }
    let head = String.fromUtf8(bytes[0..valueStart])
    let tail = String.fromUtf8(bytes[valueEnd..bytes.size])
    return (head + name + tail, "")
}

/**
 * products[0] 没有 signingConfig 键时的插入：定位 "products" 数组第一个元素的
 * "name" 键所在行，在该行行尾插入 `"signingConfig": "<name>",`。
 * 找不到 "products" / "name" 就报错不猜。
 */
func insertProductSigningConfig(text: String, name: String): (String, String) {
    let bytes = text.toArray()
    var at: Int64 = -1
    match (text.indexOf("\"products\"")) {
        case Some(i) => at = i
        case None => return ("", "找不到 products 字段")
    }
    match (text.indexOf("\"name\"", at)) {
        case Some(k) => at = k
        case None => return ("", "products[0] 里找不到 name 字段")
    }
    // 找这个 "name" 键所在行的行尾（行内是 "name": "xxx" 的值行）
    var lineEnd = at
    while (lineEnd < bytes.size && bytes[lineEnd] != 10 && bytes[lineEnd] != 13) {
        lineEnd++
    }
    if (lineEnd >= bytes.size) {
        return ("", "products[0].name 行没有收尾")
    }
    // 取该行缩进，插入行保持同缩进
    var lineStart = lineEnd
    while (lineStart > 0 && bytes[lineStart - 1] != 10 && bytes[lineStart - 1] != 13) {
        lineStart--
    }
    var indentLen: Int64 = 0
    while (lineStart + indentLen < at && (bytes[lineStart + indentLen] == 32 || bytes[lineStart + indentLen] == 9)) {
        indentLen++
    }
    let indent = String.fromUtf8(bytes[lineStart..(lineStart + indentLen)])
    let head = String.fromUtf8(bytes[0..lineEnd])
    let tail = String.fromUtf8(bytes[lineEnd..bytes.size])
    // name 行可能已带尾逗号（"name": "default",）：有就不补前逗号；
    // 我们这行自己带尾逗号（后面还有 targetSdkVersion 等键）
    var lineText = String.fromUtf8(bytes[at..lineEnd])
    let hasComma = lineText.trimAscii().endsWith(",")
    let leading = if (hasComma) { "" } else { "," }
    let inserted = "${leading}\n${indent}\"signingConfig\": \"${name}\","
    return (head + inserted + tail, "")
}

/** 一次性做完「注入 signingConfigs + 指向 product」，任一步失败就返回原文本与错误 */
public func applySigningConfig(text: String, m: SigningMaterial): (String, String) {
    if (!m.complete()) {
        return ("", "材料不完整（缺 .p12/.cer/.p7b 或口令密文），无法写回")
    }
    let (step1, err1) = injectSigningConfigs(text, m)
    if (err1 != "") {
        return ("", err1)
    }
    let (step2, err2) = pointProductSigningConfig(step1, m.name)
    if (err2 != "") {
        return ("", err2)
    }
    return (step2, "")
}

// ============================================================
// 材料生产：命名规则（DevEco / ark-cli / flutter 共用的确定性命名）
// ============================================================

/** base64url 字母表（+→-、/→_），不带 = 填充 */
func b64UrlChar(v: Int64): Byte {
    if (v < 26) {
        return UInt8(65 + v)            // A-Z
    }
    if (v < 52) {
        return UInt8(97 + v - 26)       // a-z
    }
    if (v < 62) {
        return UInt8(48 + v - 52)       // 0-9
    }
    if (v == 62) {
        return UInt8(45)                // -
    }
    return UInt8(95)                    // _
}

/** base64url 编码，去掉 = 填充（DevEco 的 hash 就是这么算的） */
public func b64UrlNoPad(data: Array<Byte>): String {
    let out = ArrayList<Byte>()
    var i: Int64 = 0
    let n = Int64(data.size)
    while (i + 2 < n) {
        let b0 = Int64(data[i])
        let b1 = Int64(data[i + 1])
        let b2 = Int64(data[i + 2])
        out.add(b64UrlChar(b0 >> 2))
        out.add(b64UrlChar(((b0 & 3) << 4) | (b1 >> 4)))
        out.add(b64UrlChar(((b1 & 15) << 2) | (b2 >> 6)))
        out.add(b64UrlChar(b2 & 63))
        i += 3
    }
    let rest = n - i
    if (rest == 1) {
        let b0 = Int64(data[i])
        out.add(b64UrlChar(b0 >> 2))
        out.add(b64UrlChar((b0 & 3) << 4))
    } else if (rest == 2) {
        let b0 = Int64(data[i])
        let b1 = Int64(data[i + 1])
        out.add(b64UrlChar(b0 >> 2))
        out.add(b64UrlChar(((b0 & 3) << 4) | (b1 >> 4)))
        out.add(b64UrlChar((b1 & 15) << 2))
    }
    return String.fromUtf8(out.toArray())
}

/** 把宿主路径归一成前向斜杠（DevEco 的 hash 用前向斜杠；反斜杠算出的是另一个值） */
public func forwardSlashPath(p: String): String {
    let bytes = p.toArray()
    let out = ArrayList<Byte>()
    for (b in bytes) {
        if (b == 92) {
            out.add(UInt8(47))
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

/** 工程路径的 hash：base64url(sha256(前向斜杠路径))，去 = 填充（43 字符） */
public func projectPathHash(projectRoot: String): String {
    let text = forwardSlashPath(projectRoot.trimAscii())
    return b64UrlNoPad(digest(SHA256(), text.toArray()))
}

/** 文件名片段的最长长度（与 flutter / DevEco 一致） */
public let SIGN_NAME_MAX_LEN: Int64 = 64

/**
 * 把 product / 工程目录名净化成安全的文件名片段：
 * \ / : * ? " < > | = - 一律换成 _，连续的点换 _，超长截断 64，空则回落 default。
 * = 也在非法列表里：hash 后面那个 = 是我们拼上去的字面量分隔符，名字里再出现就歧义。
 */
public func sanitizeSignName(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed == "") {
        return "default"
    }
    let bytes = trimmed.toArray()
    let out = ArrayList<Byte>()
    var pendingDot = false
    for (b in bytes) {
        if (out.size >= SIGN_NAME_MAX_LEN) {
            break
        }
        var ch = b
        let illegal = ch == 92 || ch == 47 || ch == 58 || ch == 42 || ch == 63 || ch == 34 ||
            ch == 60 || ch == 62 || ch == 124 || ch == 61 || ch == 45
        if (illegal) {
            ch = UInt8(95)
        }
        if (ch == 46) {          // 连续的点合成一个 _
            pendingDot = true
            continue
        }
        if (pendingDot) {
            out.add(UInt8(95))
            pendingDot = false
            if (out.size >= SIGN_NAME_MAX_LEN) {
                break
            }
        }
        out.add(ch)
    }
    if (pendingDot && out.size < SIGN_NAME_MAX_LEN) {
        out.add(UInt8(95))
    }
    if (out.size == 0) {
        return "default"
    }
    return String.fromUtf8(out.toArray())
}

/** 工程目录名（路径末段；两种分隔符都认） */
func lastPathSegment(p: String): String {
    let bytes = p.toArray()
    var cut: Int64 = -1
    for (i in 0..bytes.size) {
        if (bytes[i] == 47 || bytes[i] == 92) {
            cut = i
        }
    }
    if (cut < 0) {
        return p
    }
    return p[(cut + 1)..p.size]
}

/** 四个材料文件共用的名字主干：{product}_{工程目录名}_{hash}（不含末尾的 =） */
public func signingFileBaseName(product: String, projectRoot: String): String {
    let dirName = lastPathSegment(projectRoot.trimAscii())
    let safeDir = if (dirName == "") { "default" } else { sanitizeSignName(dirName) }
    return "${sanitizeSignName(product)}_${safeDir}_${projectPathHash(projectRoot)}"
}

// ============================================================
// 环境与目录
// ============================================================

/** 读一个环境变量（读不到给空串） */
public func signEnvOf(name: String): String {
    match (getVariable(name)) {
        case Some(v) => return v
        case None => return ""
    }
}

/** 第一个非空的环境变量值 */
public func signFirstNonEmptyEnv(names: Array<String>): String {
    for (n in names) {
        let v = signEnvOf(n)
        if (v.trimAscii() != "") {
            return v.trimAscii()
        }
    }
    return ""
}

/** 宿主路径归一（Windows 上把 / 换成 \；其它平台不动） */
public func signHostPathOf(p: String): String {
    if (!signIsWindowsHost()) {
        return p
    }
    let out = ArrayList<Byte>()
    for (b in p.toArray()) {
        out.add(if (b == 47) { UInt8(92) } else { b })
    }
    return String.fromUtf8(out.toArray())
}

/** 宿主 OS 判定（仓颉没有现成的运行期平台 API，按文件系统形状判） */
public func signIsWindowsHost(): Bool {
    return exists(Path("C:/Windows"))
}

/** 临时目录（敏感中间产物只落这里，绝不进仓库） */
public func signTempDir(): String {
    let t = signFirstNonEmptyEnv(["TEMP", "TMP"])
    return if (t == "") { "/tmp" } else { t }
}

/** ~/.ohos/config 目录（材料与 material/ 都在这里，与 DevEco 共用） */
public func ohosConfigDir(): String {
    let home = signFirstNonEmptyEnv(["USERPROFILE", "HOME"])
    if (home == "") {
        return ""
    }
    return signHostPathOf("${home}/.ohos/config")
}

/** 本工具自己的状态目录（JWT 令牌密文等） */
public func cjTauriSignStateDir(): String {
    let home = signFirstNonEmptyEnv(["USERPROFILE", "HOME"])
    if (home == "") {
        return ""
    }
    return signHostPathOf("${home}/.cj-tauri/sign")
}

/** 第一个存在的环境变量值（路径类要验存在） */
public func signFirstExistingEnv(names: Array<String>): String {
    for (n in names) {
        let v = signEnvOf(n).trimAscii()
        if (v != "" && exists(Path(v))) {
            return v
        }
    }
    return ""
}

/** 时间戳（毫秒），给留底文件名用 */
public func signNowMs(): Int64 {
    return DateTime.now().toUnixTimeStamp().toMilliseconds()
}
