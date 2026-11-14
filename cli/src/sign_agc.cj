/**
 * AGC 自动签名 · 常量与 HTTP 层（把 DevEco Studio 的自动签名流程脚本化）。
 *
 * 端点与常量抄自 flutter_flutter 提交 e2793de 的 packages/flutter_tools/lib/src/ohos/signing/
 * （auth.dart / cloud.dart / device.dart / profile.dart / material.dart / keymanager.dart），
 * 每条常量都有出处，不按猜测填。
 *
 * 三条贯穿全文件的纪律：
 *   ① AGC 的成功判据是 body 里的 ret.code == 0，不是 HTTP 200；
 *   ② 错误文案优先取 ret.msg（可能是对象、也可能是被 JSON 编码过的字符串）；
 *   ③ 下载必须 HTTPS + 非内网（SSRF 护栏），且先校验 sha256 再落盘。
 */

package cli

import std.collection.*
import std.crypto.digest.*
import std.io.*
import stdx.crypto.digest.*
import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.TlsClientConfig

/** 登录与 JWT 用的站点（不是 AGC 业务 API 的基址） */
public let AGC_LOGIN_BASE: String = "https://cn.devecostudio.huawei.com"
/** AGC 业务 API 基址（证书/设备/profile） */
public let AGC_API_BASE: String = "https://connect-api.cloud.huawei.com"

/** DevEco 系列应用 ID（写死在 flutter 源码里的常量） */
public let AGC_APP_ID: String = "1009"
/** DevEco 侧 API 版本号 */
public let AGC_API_VERSION: String = "1.0.0"
/** 只支持中国大陆站点账号（回调里 siteId 必须是 "1"） */
public let AGC_COUNTRY: String = "CN"
/** AGC 成功判据：body 里的 ret.code == 0 */
public let AGC_SUCCESS_CODE: Int64 = 0

/** 登录页路径（后面拼 ?port=&appid=&code=） */
public let AGC_APPLY_PATH: String = "console/DevEcoIDE/apply"
/** tempToken → JWT */
public let AGC_TEMP_TOKEN_PATH: String = "authrouter/auth/api/temptoken/check"
/** JWT 校验（取 userId / accessToken） */
public let AGC_JWT_CHECK_PATH: String = "authrouter/auth/api/jwToken/check"
/** 团队列表 */
public let AGC_TEAM_LIST_PATH: String = "/api/ups/user-permission-service/v1/user-team-list"

/** 证书 / 设备 / profile 端点（cloud.dart 常量） */
public let AGC_CERT_LIST_PATH: String = "/api/cps/harmony-cert-manage/v1/cert/list"
public let AGC_CERT_ADD_PATH: String = "/api/cps/harmony-cert-manage/v1/cert/add"
// 删除证书是 DELETE，且参数必须放请求体（{"certIds":[...]}）：放 query 一律被回
// `Body parameter is required.`，且体还要带 Content-Length（实测）。
public let AGC_CERT_DELETE_PATH: String = "/api/cps/harmony-cert-manage/v1/cert/delete"
public let AGC_DEVICE_LIST_PATH: String = "/api/cps/device-manage/v1/device/list"
public let AGC_DEVICE_ADD_PATH: String = "/api/cps/device-manage/v1/device/add"
public let AGC_PROVISION_ADD_TEST_PATH: String = "/api/cps/provision-manage/v1/ide/test/provision/add"
public let AGC_PROVISION_DELETE_PATH: String = "/api/cps/provision-manage/v1/provision/delete"
/** 材料下载：把对象 URL 换成带签名的临时下载链 */
public let AGC_DOWNLOAD_URL_PATH: String = "/api/amis/app-manage/v1/objects/url/reapply"

/** 回调服务只认这个路径（flutter 的 AuthLoopbackServer 同款） */
public let AGC_CALLBACK_PATH: String = "/callback"
/** 登录成功后重定向（浏览器上给用户看的页面） */
public let AGC_LOGIN_SUCCESS_PATH: String = "console/DevEcoCLI/loginSuccess"
public let AGC_LOGIN_FAILED_PATH: String = "console/DevEcoCLI/loginFailed"

// ============================================================
// 纯函数层（可单测，不联网）
// ============================================================

/** 登录页 URL：…/console/DevEcoIDE/apply?port=<port>&appid=1009&code=<32 位小写 hex> */
public func oauthLoginUrl(port: Int64, code: String): String {
    return "${AGC_LOGIN_BASE}/${AGC_APPLY_PATH}?port=${port}&appid=${AGC_APP_ID}&code=${code}"
}

/** tempToken → JWT 的完整 URL（tempToken 按 & 截断后再编码，flutter 同款） */
public func tempTokenCheckUrl(tempToken: String): String {
    var first = tempToken.trimAscii()
    match (first.indexOf("&")) {
        case Some(at) => if (at > 0) {
            first = first[0..at]
        }
        case None => ()
    }
    return "${AGC_LOGIN_BASE}/${AGC_TEMP_TOKEN_PATH}?tempToken=${urlEncodeSign(first)}" +
        "&site=${AGC_COUNTRY}&version=${AGC_API_VERSION}&appid=${AGC_APP_ID}"
}

/** JWT 校验地址（无 query） */
public func jwtCheckUrl(): String {
    return "${AGC_LOGIN_BASE}/${AGC_JWT_CHECK_PATH}"
}

/** AGC 业务接口的完整 URL（path 以 / 开头） */
public func agcUrl(path: String): String {
    return "${AGC_API_BASE}${path}"
}

/** 登录成功 / 失败的重定向地址 */
public func loginRedirectUrl(success: Bool): String {
    let p = if (success) { AGC_LOGIN_SUCCESS_PATH } else { AGC_LOGIN_FAILED_PATH }
    return "${AGC_LOGIN_BASE}/${p}"
}

/** 只接受中国大陆站点账号（回调里的 siteId 必须是字符串 "1"） */
public func isChinaSite(siteId: String): Bool {
    return siteId.trimAscii() == "1"
}

/** JWT 形状校验：xxx.yyy.zzz，三段都由 [\w-] 组成（登录接口成功时响应体本身就是 JWT） */
public func isJwtShaped(token: String): Bool {
    let t = token.trimAscii()
    if (t == "") {
        return false
    }
    var dots: Int64 = 0
    for (b in t.toArray()) {
        if (b == 46) {                      // .
            dots += 1
            continue
        }
        let ok = (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) ||
            b == 95 || b == 45
        if (!ok) {
            return false
        }
    }
    return dots == 2
}

/** 解析 query 串成键值表（同一键重复时保留第一次） */
public func parseQueryParams(query: String): HashMap<String, String> {
    let out = HashMap<String, String>()
    let q = query.trimAscii()
    if (q == "") {
        return out
    }
    for (pair in q.split("&", -1)) {
        if (pair == "") {
            continue
        }
        match (pair.indexOf("=")) {
            case Some(eq) =>
                let k = urlDecodeSign(pair[0..eq])
                let v = urlDecodeSign(pair[(eq + 1)..pair.size])
                if (k != "" && !out.contains(k)) {
                    out.add(k, v)
                }
            case None =>
                let bare = urlDecodeSign(pair)
                if (bare != "" && !out.contains(bare)) {
                    out.add(bare, "")
                }
        }
    }
    return out
}

/** percent-decode（%2F → /，+ → 空格）；非法转义原样保留，不抛 */
public func urlDecodeSign(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<Byte>()
    var i: Int64 = 0
    while (i < bytes.size) {
        let b = bytes[i]
        if (b == 37 && i + 2 < bytes.size) {         // %
            let hi = signHexNibbleOf(bytes[i + 1])
            let lo = signHexNibbleOf(bytes[i + 2])
            if (hi >= 0 && lo >= 0) {
                out.add(UInt8((hi << 4) | lo))
                i += 3
                continue
            }
        }
        if (b == 43) {                                // + → 空格
            out.add(UInt8(32))
        } else {
            out.add(b)
        }
        i += 1
    }
    return String.fromUtf8(out.toArray())
}

/** percent-encode（只保留 unreserved 字符，其余转 %XX） */
public func urlEncodeSign(s: String): String {
    let out = ArrayList<Byte>()
    let digits = "0123456789ABCDEF".toArray()
    for (b in s.toArray()) {
        let unreserved = (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) ||
            b == 45 || b == 95 || b == 46 || b == 126
        if (unreserved) {
            out.add(b)
        } else {
            out.add(UInt8(37))
            out.add(digits[(Int64(b) >> 4) & 15])
            out.add(digits[Int64(b) & 15])
        }
    }
    return String.fromUtf8(out.toArray())
}

/**
 * 证书名（确定性的，让"要不要新建"变成一次名字查找）：
 * auto_debug_<teamId 去掉 \ / . :>.cer
 */
public func certNameFor(teamId: String): String {
    let out = ArrayList<Byte>()
    for (b in teamId.trimAscii().toArray()) {
        let illegal = b == 92 || b == 47 || b == 46 || b == 58
        out.add(if (illegal) { UInt8(95) } else { b })
    }
    return "auto_debug_${String.fromUtf8(out.toArray())}.cer"
}

/**
 * profile 名：sha256("{product}_{bundle}_{bundle}") 的前 16 位十六进制。
 * bundle 出现两次不是笔误——那是 DevEco/ark-cli 的确定性命名，改了就与已有 profile 对不上号。
 */
public func provisionNameOf(product: String, bundleName: String): String {
    let seed = "${product}_${bundleName}_${bundleName}"
    let hex = toHexLower(digest(SHA256(), seed.toArray()))
    return hex[0..16]
}

/** AGC 响应是否成功：ret.code == 0（不是 HTTP 200） */
public func agcSucceeded(root: JsonValue): Bool {
    match (root.kind()) {
        case JsonKind.JsObject => ()
        case _ => return false
    }
    match (root.asObject().get("ret")) {
        case Some(r) => match (r.kind()) {
            case JsonKind.JsObject => match (r.asObject().get("code")) {
                case Some(c) => match (c.kind()) {
                    case JsonKind.JsInt => return c.asInt().getValue() == AGC_SUCCESS_CODE
                    case _ => return false
                }
                case None => return false
            }
            case _ => return false
        }
        case None => return false
    }
    return false
}

/** 从 AGC 响应里取错误文案（ret.msg 可能是对象，也可能是被 JSON 编码过的字符串） */
public func agcErrorMsg(root: JsonValue): String {
    match (root.kind()) {
        case JsonKind.JsObject => ()
        case _ => return ""
    }
    match (root.asObject().get("ret")) {
        case Some(r) => match (r.kind()) {
            case JsonKind.JsObject => match (r.asObject().get("msg")) {
                case Some(m) => match (m.kind()) {
                    case JsonKind.JsString => return m.asString().getValue()
                    case _ => return m.toString()
                }
                case None => return ""
            }
            case _ => return ""
        }
        case None => return ""
    }
    return ""
}

/** AGC 错误码（body 里的 ret.code；不是 HTTP 状态码），取不到给 -1 */
public func agcErrorCode(root: JsonValue): Int64 {
    match (root.kind()) {
        case JsonKind.JsObject => ()
        case _ => return -1
    }
    match (root.asObject().get("ret")) {
        case Some(r) => match (r.kind()) {
            case JsonKind.JsObject => match (r.asObject().get("code")) {
                case Some(c) => match (c.kind()) {
                    case JsonKind.JsInt => return c.asInt().getValue()
                    case _ => return -1
                }
                case None => return -1
            }
            case _ => return -1
        }
        case None => return -1
    }
    return -1
}

// ============================================================
// 动作层：HTTP 客户端
// ============================================================

/** 一次 HTTP 请求的最小结果 */
public class AgcHttpResult {
    public var status: Int64 = 0
    public var body: String = ""
    public var error: String = ""
}

/**
 * 发一次 GET/POST/DELETE。
 *
 * 三个"少一个就挂"的细节（实测才发现的）：
 *   · HTTPS 必须显式 tlsConfig(TlsClientConfig())，否则 HttpException: TLS must be configured…；
 *   · 必须 .noProxy()——客户端默认读系统 http_proxy/https_proxy，连本机回环都可能被送去代理；
 *   · 删除证书是 DELETE 带请求体，用 get() 会把体丢掉，服务端回 Body parameter is required.
 */
public func agcHttp(method: String, url: String, headers: ArrayList<String>, body: String,
    timeoutMs: Int64): AgcHttpResult {
    let r = AgcHttpResult()
    let isHttps = url.startsWith("https://")
    let secs = if (timeoutMs <= 0) { 15 } else { timeoutMs / 1000 }
    try {
        var cb = ClientBuilder().readTimeout(Duration.second * secs).writeTimeout(Duration.second * secs)
        if (isHttps) {
            cb = cb.tlsConfig(TlsClientConfig())
        }
        cb = cb.noProxy()
        let client = cb.build()
        var rb = HttpRequestBuilder().url(url)
        let verb = agcUpperAscii(method.trimAscii())
        rb = if (verb == "POST") {
            rb.post()
        } else if (verb == "DELETE") {
            rb.delete()
        } else {
            rb.get()
        }
        for (h in headers) {
            match (h.indexOf(":")) {
                case Some(cut) => if (cut > 0) {
                    rb = rb.header(h[0..cut].trimAscii(), h[(cut + 1)..h.size].trimAscii())
                }
                case None => ()
            }
        }
        if (body != "") {
            rb = rb.header("Content-Type", "application/json;charset=UTF-8")
            rb = rb.body(body)
        }
        let resp = client.send(rb.build())
        r.status = Int64(resp.status)
        r.body = StringReader(resp.body).readToEnd()
        try {
            resp.close()
        } catch (e: Exception) {
            let _ = e
        }
        try {
            client.close()
        } catch (e: Exception) {
            let _ = e
        }
    } catch (e: Exception) {
        r.error = "HTTP 请求失败：${e}"
    }
    return r
}

/** ASCII 大写（仓颉没有现成的 toUpperCaseAscii） */
public func agcUpperAscii(s: String): String {
    let out = ArrayList<Byte>()
    for (b in s.toArray()) {
        if (b >= 97 && b <= 122) {
            out.add(UInt8(Int64(b) - 32))
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

/** ASCII 小写 */
public func agcLowerAscii(s: String): String {
    let out = ArrayList<Byte>()
    for (b in s.toArray()) {
        if (b >= 65 && b <= 90) {
            out.add(UInt8(Int64(b) + 32))
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}
