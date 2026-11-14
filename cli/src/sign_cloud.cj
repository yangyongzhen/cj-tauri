/**
 * AGC 云侧动作层：团队 / 设备 / 证书 / profile / 对象下载。
 *
 * 分层：纯函数负责"解析响应 / 拼请求体 / 判成功"，agcXxx 负责发请求。
 * 请求体字段与判序抄自 flutter cloud.dart / device.dart / profile.dart。
 */

package cli

import std.collection.*
import std.crypto.digest.*
import std.fs.*
import std.process.*
import stdx.crypto.digest.*
import stdx.encoding.json.*

/** 云端已注册设备 */
public class AgcDevice {
    public var udid: String = ""
    public var name: String = ""
    public var id: String = ""
}

/** 云端证书 */
public class AgcCert {
    public var id: String = ""
    public var certName: String = ""
    public var certObjectId: String = ""
    /** 到期时间（毫秒时间戳；取不到给 0） */
    public var expireMs: Int64 = 0
    /** AGC 侧状态（实测：1=可用、2=已过期） */
    public var status: Int64 = 0
}

// ============================================================
// 纯函数层
// ============================================================

func signJsonObjectField(root: JsonValue, key: String): JsonValue {
    match (root.kind()) {
        case JsonKind.JsObject => match (root.asObject().get(key)) {
            case Some(v) => return v
            case None => return JsonObject()
        }
        case _ => return JsonObject()
    }
}

func signJsonArrayField(root: JsonValue, key: String): JsonArray {
    match (root.kind()) {
        case JsonKind.JsObject => match (root.asObject().get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsArray => return v.asArray()
                case _ => return JsonArray()
            }
            case None => return JsonArray()
        }
        case _ => return JsonArray()
    }
}

func signJsonStringField(root: JsonValue, key: String): String {
    match (root.kind()) {
        case JsonKind.JsObject => match (root.asObject().get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
            case None => return ""
        }
        case _ => return ""
    }
}

/** 取整数字段（数字或"数字字符串"都认；取不到给 fallback） */
func signJsonIntField(root: JsonValue, key: String, fallback: Int64): Int64 {
    match (root.kind()) {
        case JsonKind.JsObject => match (root.asObject().get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case JsonKind.JsString => return signDigitsOnlyValue(v.asString().getValue())
                case _ => return fallback
            }
            case None => return fallback
        }
        case _ => return fallback
    }
}

/** 取布尔字段（取不到给 false） */
public func signJsonBoolField(root: JsonValue, key: String): Bool {
    match (root.kind()) {
        case JsonKind.JsObject => match (root.asObject().get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsBool => return v.asBool().getValue()
                case _ => return false
            }
            case None => return false
        }
        case _ => return false
    }
}

/** 纯数字串 → 数值（非纯数字返回 -1）；给网段判断用 */
public func signDigitsOnlyValue(s: String): Int64 {
    let t = s.trimAscii()
    if (t == "") {
        return -1
    }
    var v: Int64 = 0
    for (b in t.toArray()) {
        if (b < 48 || b > 57) {
            return -1
        }
        v = v * 10 + Int64(b - 48)
        if (v > 1000000) {
            return -1
        }
    }
    return v
}

/** 解析 device/list 响应（实测：AGC 真正用的字段名是 list，其余是旧代字段名兜底） */
public func parseDeviceList(root: JsonValue): ArrayList<AgcDevice> {
    let out = ArrayList<AgcDevice>()
    if (!agcSucceeded(root)) {
        return out
    }
    var list = signJsonArrayField(root, "list")
    if (list.size() == 0) {
        list = signJsonArrayField(root, "devicesInfo")
    }
    if (list.size() == 0) {
        list = signJsonArrayField(root, "deviceList")
    }
    for (i in 0..list.size()) {
        let e = list.get(i).getOrThrow()
        let d = AgcDevice()
        d.id = signJsonStringField(e, "id")
        d.udid = signJsonStringField(e, "udid")
        d.name = signJsonStringField(e, "deviceName")
        if (d.udid != "") {
            out.add(d)
        }
    }
    return out
}

/** 本机 UDID 是否已注册（大小写不敏感：云端存大写） */
public func deviceRegistered(devices: ArrayList<AgcDevice>, udid: String): Bool {
    let want = agcUpperAscii(udid.trimAscii())
    if (want == "") {
        return false
    }
    for (d in devices) {
        if (agcUpperAscii(d.udid.trimAscii()) == want) {
            return true
        }
    }
    return false
}

/** 解析 cert/list 响应 */
public func parseCertList(root: JsonValue): ArrayList<AgcCert> {
    let out = ArrayList<AgcCert>()
    let list = signJsonArrayField(root, "certList")
    for (i in 0..list.size()) {
        let e = list.get(i).getOrThrow()
        let c = AgcCert()
        c.id = signJsonStringField(e, "id")
        c.certName = signJsonStringField(e, "certName")
        c.certObjectId = signJsonStringField(e, "certObjectId")
        c.expireMs = signJsonIntField(e, "expireTime", 0)
        c.status = signJsonIntField(e, "status", 0)
        out.add(c)
    }
    return out
}

/** 按名字找证书（新建后列表里重新定位用） */
public func findCertByName(certs: ArrayList<AgcCert>, name: String): Option<AgcCert> {
    for (c in certs) {
        if (c.certName == name) {
            return Some(c)
        }
    }
    return None
}

/** 云端证书是否可用（状态 1 且未过期；状态取不到时按"有到期时间且没过"判） */
public func isCertUsable(c: AgcCert): Bool {
    if (c.status != 0 && c.status != 1) {
        return false
    }
    if (c.expireMs > 0 && c.expireMs <= signNowMs()) {
        return false
    }
    return c.id != ""
}

/** 找「名字匹配且可用」的证书 */
public func findUsableCert(certs: ArrayList<AgcCert>, name: String): Option<AgcCert> {
    for (c in certs) {
        if (c.certName == name && isCertUsable(c)) {
            return Some(c)
        }
    }
    return None
}

/** 自动签名证书名前缀（只清理自己的过期件，别动别人的） */
public func isAutoSignCertName(name: String): Bool {
    return name.startsWith("auto_debug_") || name.startsWith("auto_release_")
}

/** 自己名下已过期的自动签名证书（占配额的那种） */
public func staleCertsOf(certs: ArrayList<AgcCert>): ArrayList<AgcCert> {
    let out = ArrayList<AgcCert>()
    for (c in certs) {
        if (!isAutoSignCertName(c.certName)) {
            continue
        }
        if (c.status == 2 || (c.expireMs > 0 && c.expireMs <= signNowMs())) {
            out.add(c)
        }
    }
    return out
}

/**
 * 从 `hdc shell getprop hw_sc.build.os.deviceType` 输出判设备类型码。
 * 判序照 flutter（liteWearable 必须先于 wearable 判，否则子串会把前者吃掉）：
 * liteWearable=1 / wearable=2 / tv=3 / 其它=4（手机/平板/PC 在 flutter 里都落 4）。
 */
public func signDeviceTypeOf(getpropOut: String): String {
    let t = getpropOut.trimAscii()
    if (t.indexOf("liteWearable").isSome()) {
        return "1"
    }
    if (t.indexOf("wearable").isSome()) {
        return "2"
    }
    if (t.indexOf("tv").isSome()) {
        return "3"
    }
    return "4"
}

/** device/add 的请求体（deviceName 要唯一：随机数 + 时间戳） */
public func buildDeviceAddBody(udid: String, deviceType: String, nonce: String): String {
    var o = JsonObject()
    o.put("deviceName", JsonString("cj_tauri_device_${nonce}"))
    o.put("udid", JsonString(agcUpperAscii(udid).trimAscii()))
    o.put("deviceType", JsonString(deviceType))
    return o.toJsonString()
}

/** cert/add 的请求体（certType：1=debug / 2=release） */
public func buildCertAddBody(csrPem: String, certName: String, certType: String): String {
    var o = JsonObject()
    o.put("csr", JsonString(csrPem))
    o.put("certName", JsonString(certName))
    o.put("certType", JsonString(certType))
    return o.toJsonString()
}

/**
 * provision/add 的请求体。
 * deviceList 只在 debug（test）profile 里带；aclPermissionList 为空时不带
 * （带空数组会被 AGC 判非法）。
 */
public func buildProvisionBody(certIds: ArrayList<String>, bundleName: String,
    provisionName: String, deviceIds: ArrayList<String>,
    aclPermissions: ArrayList<String>): String {
    var o = JsonObject()
    var certs = JsonArray()
    for (c in certIds) {
        certs.add(JsonString(c))
    }
    o.put("certList", certs)
    o.put("packageName", JsonString(bundleName))
    o.put("provisionName", JsonString(provisionName))
    if (deviceIds.size > 0) {
        var devs = JsonArray()
        for (d in deviceIds) {
            devs.add(JsonString(d))
        }
        o.put("deviceList", devs)
    }
    if (aclPermissions.size > 0) {
        var acls = JsonArray()
        for (a in aclPermissions) {
            acls.add(JsonString(a))
        }
        o.put("aclPermissionList", acls)
    }
    return o.toJsonString()
}

/** 从 provision/add 响应里取 (profileId, provisionFileUrl) */
public func parseProvisionAdd(root: JsonValue): (String, String) {
    if (!agcSucceeded(root)) {
        return ("", "")
    }
    return (signJsonStringField(root, "id"), signJsonStringField(root, "provisionFileUrl"))
}

/**
 * 下载 URL 的 SSRF 护栏：只放 https、拒本机与内网地址。
 * 下载链是 AGC 返回的临时 URL，若被诱导去访问内网就是典型的 SSRF。
 * 内网清单按 flutter 的实现范围（localhost / 127.0.0.1 / ::1 / 10. / 192.168. /
 * 172.16-31. / 169.254. / .internal / .local）。
 */
public func isSafeDownloadUrl(u: String): Bool {
    let s = u.trimAscii()
    if (!s.startsWith("https://")) {
        return false
    }
    let lowered = agcLowerAscii(s)
    let afterScheme = lowered[8..lowered.size]
    var authority = afterScheme
    match (afterScheme.indexOf("/")) {
        case Some(at) => authority = afterScheme[0..at]
        case None => ()
    }
    // 取 host：带方括号的 IPv6 要整段取到 ]，不能按第一个 : 切（[::1] 按 : 切会得到 [）
    var host = authority
    if (authority.startsWith("[")) {
        match (authority.indexOf("]")) {
            case Some(at) => host = authority[0..(at + 1)]
            case None => host = authority
        }
    } else {
        match (authority.indexOf(":")) {
            case Some(at) => host = authority[0..at]
            case None => ()
        }
    }
    if (host == "" || host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]") {
        return false
    }
    // 其它带 : 的 host（未加方括号的 IPv6 等）一律拒：不猜
    if (host.indexOf(":").isSome()) {
        return false
    }
    if (host.startsWith("10.") || host.startsWith("192.168.") || host.startsWith("169.254.")) {
        return false
    }
    if (host.startsWith("172.")) {
        let parts = host.split(".", -1)
        if (parts.size >= 2) {
            let second = signDigitsOnlyValue(parts[1])
            if (second >= 16 && second <= 31) {
                return false
            }
        }
    }
    if (host.endsWith(".internal") || host.endsWith(".local")) {
        return false
    }
    return true
}

// ============================================================
// 动作层：发请求（网络 + 落盘）
// ============================================================

/** AGC 业务请求的公共头（uid / teamId / oauth2Token 三件套） */
func agcAuthHeaders(accessToken: String, uid: String, teamId: String): ArrayList<String> {
    let h = ArrayList<String>()
    h.add("oauth2Token: ${accessToken}")
    h.add("uid: ${uid}")
    h.add("teamId: ${teamId}")
    return h
}

/** 发一次 AGC 请求并解析 JSON；返回 (根对象, 错误) */
func agcCall(method: String, path: String, accessToken: String, uid: String, teamId: String,
    body: String): (JsonValue, String) {
    let r = agcHttp(method, agcUrl(path), agcAuthHeaders(accessToken, uid, teamId), body, 30000)
    if (r.error != "") {
        return (JsonObject(), r.error)
    }
    if (r.body.trimAscii() == "") {
        return (JsonObject(), "AGC 返回空响应（HTTP ${r.status}）")
    }
    var root: JsonValue
    try {
        root = JsonValue.fromStr(r.body)
    } catch (e: Exception) {
        return (JsonObject(), "AGC 响应不是 JSON（HTTP ${r.status}）：${e}")
    }
    if (!agcSucceeded(root)) {
        return (root, "AGC 错误 ${agcErrorCode(root)}：${agcErrorMsg(root)}")
    }
    return (root, "")
}

/** 拉团队列表；返回第一个团队（与 flutter 的 teams.first.id 一致） */
public func agcTeamList(accessToken: String, uid: String): Option<AgcTeam> {
    let headers = ArrayList<String>()
    headers.add("oauth2Token: ${accessToken}")
    headers.add("uid: ${uid}")
    headers.add("source: cli")
    headers.add("lang: zh")
    let r = agcHttp("GET", agcUrl(AGC_TEAM_LIST_PATH), headers, "", 30000)
    if (r.error != "" || r.status != 200) {
        return None
    }
    var root: JsonValue
    try {
        root = JsonValue.fromStr(r.body)
    } catch (e: Exception) {
        let _ = e
        return None
    }
    if (!agcSucceeded(root)) {
        return None
    }
    let teams = signJsonArrayField(root, "teams")
    if (teams.size() == 0) {
        return None
    }
    let first = teams.get(0).getOrThrow()
    let t = AgcTeam()
    t.id = signJsonStringField(first, "id")
    t.name = signJsonStringField(first, "name")
    t.count = Int64(teams.size())
    if (t.id == "") {
        return None
    }
    return Some(t)
}

/** 团队信息 */
public class AgcTeam {
    public var id: String = ""
    public var name: String = ""
    public var count: Int64 = 0
}

/** 拉全部团队（UDID 可能注册在非默认团队里：profile 按团队签，必须选对团队） */
public func agcTeamListAll(accessToken: String, uid: String): (ArrayList<AgcTeam>, String) {
    let headers = ArrayList<String>()
    headers.add("oauth2Token: ${accessToken}")
    headers.add("uid: ${uid}")
    headers.add("source: cli")
    headers.add("lang: zh")
    let r = agcHttp("GET", agcUrl(AGC_TEAM_LIST_PATH), headers, "", 30000)
    if (r.error != "") {
        return (ArrayList<AgcTeam>(), r.error)
    }
    if (r.status != 200) {
        return (ArrayList<AgcTeam>(), "HTTP ${r.status}")
    }
    var root: JsonValue
    try {
        root = JsonValue.fromStr(r.body)
    } catch (e: Exception) {
        return (ArrayList<AgcTeam>(), "响应不是 JSON：${e}")
    }
    if (!agcSucceeded(root)) {
        return (ArrayList<AgcTeam>(), "AGC 错误 ${agcErrorCode(root)}：${agcErrorMsg(root)}")
    }
    let out = ArrayList<AgcTeam>()
    let teams = signJsonArrayField(root, "teams")
    for (i in 0..teams.size()) {
        let e = teams.get(i).getOrThrow()
        let t = AgcTeam()
        t.id = signJsonStringField(e, "id")
        t.name = signJsonStringField(e, "name")
        t.count = Int64(teams.size())
        if (t.id != "") {
            out.add(t)
        }
    }
    return (out, "")
}

/** 拉设备列表（分页：start 从 1 起、每页 100，与 flutter 一致） */
public func agcDeviceList(accessToken: String, uid: String, teamId: String): (ArrayList<AgcDevice>, String) {
    let all = ArrayList<AgcDevice>()
    var page: Int64 = 1
    while (page <= 10) {          // 硬上限：设备上千台的账号不该在这个工具里折腾
        let (root, err) = agcCall("GET",
            "${AGC_DEVICE_LIST_PATH}?encodeFlag=0&start=${page}&pageSize=100",
            accessToken, uid, teamId, "")
        if (err != "") {
            return (all, err)
        }
        let got = parseDeviceList(root)
        for (d in got) {
            all.add(d)
        }
        if (got.size < 100) {
            break
        }
        page += 1
    }
    return (all, "")
}

/** 注册本机设备（已注册就跳过） */
public func agcEnsureDevice(accessToken: String, uid: String, teamId: String, udid: String,
    deviceType: String): (Bool, String) {
    let (devices, e1) = agcDeviceList(accessToken, uid, teamId)
    if (e1 != "") {
        return (false, "拉设备列表失败：${e1}")
    }
    if (deviceRegistered(devices, udid)) {
        return (true, "设备已注册（共 ${devices.size} 台）")
    }
    let nonce = toHexLower(signRandomBytes(3))
    let body = buildDeviceAddBody(udid, deviceType, nonce)
    let (_, e2) = agcCall("POST", AGC_DEVICE_ADD_PATH, accessToken, uid, teamId, body)
    if (e2 != "") {
        // `205389858 UDID is repeat`：语义上等于"已注册"，不当失败
        if (e2.contains("205389858")) {
            return (true, "设备已注册（AGC 回报 UDID 重复，视为已注册）")
        }
        // 名字重复不是致命：换个 nonce 重试一次
        if (e2.contains("205389857")) {
            let body2 = buildDeviceAddBody(udid, deviceType, toHexLower(signRandomBytes(4)))
            let (_, e3) = agcCall("POST", AGC_DEVICE_ADD_PATH, accessToken, uid, teamId, body2)
            if (e3 == "") {
                return (true, "设备注册成功（换名重试）")
            }
            return (false, "注册设备失败：${e3}")
        }
        return (false, "注册设备失败：${e2}")
    }
    return (true, "设备注册成功")
}

/** 证书列表 */
public func agcCertList(accessToken: String, uid: String, teamId: String): (ArrayList<AgcCert>, String) {
    let (root, err) = agcCall("GET", AGC_CERT_LIST_PATH, accessToken, uid, teamId, "")
    if (err != "") {
        return (ArrayList<AgcCert>(), "拉证书列表失败：${err}")
    }
    return (parseCertList(root), "")
}

/** 新建证书（csr 是 PEM 文本） */
public func agcCertAdd(accessToken: String, uid: String, teamId: String, csrPem: String,
    certName: String, certType: String): (AgcCert, String) {
    let body = buildCertAddBody(csrPem, certName, certType)
    let (_, err) = agcCall("POST", AGC_CERT_ADD_PATH, accessToken, uid, teamId, body)
    if (err != "") {
        return (AgcCert(), "新增证书失败：${err}")
    }
    // 新增接口不一定回证书 id → 重新列一遍按名字找
    let (certs, e2) = agcCertList(accessToken, uid, teamId)
    if (e2 != "") {
        return (AgcCert(), e2)
    }
    match (findCertByName(certs, certName)) {
        case Some(c) => return (c, "")
        case None => return (AgcCert(), "证书已创建但列表里找不到 ${certName}（可能需要等一下再试）")
    }
}

/**
 * 删除云端证书（DELETE + 请求体）。
 * 参数位置是实测定出来的：放 query 一律回 Body parameter is required.；
 * DELETE 带体 {"certIds":["<id>"]} 回 ret.code==0。
 */
public func agcCertDelete(accessToken: String, uid: String, teamId: String,
    certIds: ArrayList<String>): (Bool, String) {
    if (certIds.size == 0) {
        return (false, "没有要删除的证书 id")
    }
    var arr = JsonArray()
    for (id in certIds) {
        arr.add(JsonString(id))
    }
    var o = JsonObject()
    o.put("certIds", arr)
    let (_, err) = agcCall("DELETE", AGC_CERT_DELETE_PATH, accessToken, uid, teamId, o.toJsonString())
    if (err != "") {
        return (false, "删除证书失败：${err}")
    }
    return (true, "已删除 ${certIds.size} 张云端证书")
}

/**
 * 把 AGC 的对象 URL 换成带签名的临时下载链，并下载到本地。
 * 顺序照 flutter：先 objects/url/reapply（body 是 {"sourceUrls":"<单字符串>"}），
 * 拿到 urlsInfo[0].newUrl，校验 SSRF 护栏与 sha256 后再落盘。
 */
public func agcDownloadObject(accessToken: String, uid: String, teamId: String, sourceUrl: String,
    destPath: String): (String, String) {
    if (sourceUrl == "") {
        return ("", "没有可下载的对象 URL")
    }
    var body = JsonObject()
    body.put("sourceUrls", JsonString(sourceUrl))
    let (root, err) = agcCall("POST", AGC_DOWNLOAD_URL_PATH, accessToken, uid, teamId,
        body.toJsonString())
    if (err != "") {
        return ("", "换下载链失败：${err}")
    }
    let infos = signJsonArrayField(root, "urlsInfo")
    if (infos.size() == 0) {
        return ("", "换下载链失败：响应里没有 urlsInfo")
    }
    let info0 = infos.get(0).getOrThrow()
    let newUrl = signJsonStringField(info0, "newUrl")
    let wantSha = agcLowerAscii(signJsonStringField(info0, "sha256"))
    if (!isSafeDownloadUrl(newUrl)) {
        return ("", "拒绝下载：下载链不是安全的 HTTPS 公网地址（${newUrl}）")
    }
    // 下载必须原样使用这条签名 URL：AWS SigV4 对 query 的字节敏感，通用客户端把 %2F
    // 重新编码 → 签名失效 → 403。优先走系统 curl（把 URL 当字节），失败再退内置客户端。
    let bytes = signDownloadRawBytes(newUrl)
    if (bytes.size == 0) {
        return ("", "下载失败：curl 与内置客户端都没拿到内容（URL 可能已过期，签名链有效期很短）")
    }
    if (wantSha != "") {
        let got = toHexLower(digest(SHA256(), bytes))
        if (got != wantSha) {
            return ("", "下载校验失败：sha256 期望 ${wantSha}，实际 ${got}（拒绝落盘）")
        }
    }
    try {
        signEnsureParentDirOf(destPath)
        File.writeTo(destPath, bytes)
    } catch (e: Exception) {
        return ("", "写盘失败 ${destPath}：${e}")
    }
    return (destPath, "")
}

/** 建父目录 */
public func signEnsureParentDirOf(path: String): Unit {
    let bytes = path.toArray()
    var cut: Int64 = -1
    for (i in 0..bytes.size) {
        if (bytes[i] == 47 || bytes[i] == 92) {
            cut = i
        }
    }
    if (cut <= 0) {
        return
    }
    let dir = path[0..cut]
    if (!exists(Path(dir))) {
        Directory.create(Path(dir), recursive: true)
    }
}

/**
 * 申请 debug（test）profile，下载 .p7b 到目标路径。
 * 下载完立即删除云端 profile（profile 有数量配额，本地材料已经够用）。
 * 删除失败不影响结果，只记在返回串里。
 */
public func agcProvisionDebug(accessToken: String, uid: String, teamId: String, certId: String,
    bundleName: String, product: String, deviceIds: ArrayList<String>,
    aclPermissions: ArrayList<String>, destP7b: String): (String, String) {
    let certIds = ArrayList<String>()
    certIds.add(certId)
    let provName = provisionNameOf(product, bundleName)
    let body = buildProvisionBody(certIds, bundleName, provName, deviceIds, aclPermissions)
    let (root, err) = agcCall("POST", AGC_PROVISION_ADD_TEST_PATH, accessToken, uid, teamId, body)
    if (err != "") {
        return ("", "申请 profile 失败：${err}")
    }
    let (provId, fileUrl) = parseProvisionAdd(root)
    if (fileUrl == "") {
        return ("", "申请 profile 成功但没给 provisionFileUrl（id=${provId}）")
    }
    let (saved, e2) = agcDownloadObject(accessToken, uid, teamId, fileUrl, destP7b)
    var note = ""
    if (provId != "") {
        let (_, e3) = agcCall("DELETE", "${AGC_PROVISION_DELETE_PATH}?id=${provId}", accessToken, uid,
            teamId, "")
        note = if (e3 == "") { "云端 profile 已删除（id=${provId}）" } else { "云端 profile 删除失败：${e3}" }
    }
    if (e2 != "") {
        return ("", e2)
    }
    return (saved, note)
}

/**
 * 用系统 curl 原样下载（保留 URL 的原始字节，避免 AWS SigV4 签名被重编码 → 403）。
 * Win10 1803+ 与主流 Linux 都自带。返回拿到的字节（失败返回空）。
 */
public func signDownloadRawBytes(url: String): Array<Byte> {
    let tmp = "${signTempDir()}/cj-tauri-dl-${toHexLower(signRandomBytes(4))}.bin"
    let args = ArrayList<String>()
    args.add("-sS")
    args.add("-L")
    args.add("-f")
    args.add("--max-time")
    args.add("90")
    args.add("-o")
    args.add(tmp)
    args.add(url)
    try {
        let (code, _, _) = executeWithOutput("curl", args.toArray())
        if (code != 0) {
            // curl 不可用或下载失败：退回内置客户端
            let r = agcHttp("GET", url, ArrayList<String>(), "", 60000)
            if (r.error == "" && r.status == 200) {
                return r.body.toArray()
            }
            return []
        }
        if (!exists(Path(tmp))) {
            return []
        }
        let data = File.readFrom(tmp)
        try {
            remove(Path(tmp))
        } catch (e: Exception) {
            let _ = e
        }
        return data
    } catch (e: Exception) {
        let _ = e
        return []
    }
}
