/**
 * AGC 登录（OAuth loopback）与令牌存储。
 *
 * 流程（对齐 flutter auth.dart）：
 *   ① 本机起一次性 HTTP 服务（只绑 127.0.0.1、端口由系统分配）；
 *   ② 打开 …/console/DevEcoIDE/apply?port=<port>&appid=1009&code=<32 位 hex>；
 *   ③ 浏览器回调 /callback?tempToken=…&siteId=1&code=…：
 *        Host 必须是 127.0.0.1:<port> / localhost:<port>；siteId 必须是 "1"（大陆站点）；
 *        code 只核对记录、不硬拒绝（华为回调里自带它自己的 code，硬比对会误杀正常登录；
 *        真正的安全边界是只绑回环 + 一次性服务 + tempToken 还要过华为校验）；
 *   ④ tempToken → GET …/temptoken/check → 响应体本身就是 JWT（校验 a.b.c 形状）；
 *   ⑤ GET …/jwToken/check（头 refresh: true / jwtToken: <JWT>）→ userInfo.accessToken 等；
 *   ⑥ JWT 加密落盘（AES-128-GCM + 本机 KEK），下次直接用。
 *
 * 为什么要加密落盘：JWT 等于账号的会话票据，存本地密文而不是明文；
 * 令牌约 4 小时过期，过期重跑一次 --login。
 */

package cli

import std.collection.*
import std.fs.*
import std.io.*
import std.process.*
import std.sync.*
import stdx.encoding.json.*
import stdx.net.http.*

/** 一次登录的结果 */
public class AgcLoginOutcome {
    public var ok: Bool = false
    public var error: String = ""
    /** 换来的 JWT（落盘前的原文；别写日志） */
    public var jwt: String = ""
    /** AGC 请求头 oauth2Token 用的会话 token */
    public var accessToken: String = ""
    /** AGC 请求头 uid */
    public var userId: String = ""
    public var userName: String = ""
    public var refreshToken: String = ""
    /** 国度码（userInfo.nationalCode，注意不是 countryCode） */
    public var countryCode: String = ""
    public var isRealName: Bool = false
    /** 团队（登录成功后顺手拉一次，缺省取第一个） */
    public var teamId: String = ""
    public var teamName: String = ""
    public var teamCount: Int64 = 0
    /** 回调服务实际用的端口（排障用） */
    public var port: Int64 = 0
}

/** 回调服务的共享状态（handler 写、主线程等） */
class SignCallbackState {
    public let done = AtomicBool(false)
    public var port: Int64 = 0
    public var tempToken: String = ""
    public var siteId: String = ""
    public var quit: Bool = false
    public var code: String = ""
    public var rejectReason: String = ""
    /** 第一次到达的回调原始输入（排障证据；tempToken 只记长度） */
    public var rawQuery: String = ""
    public var loginUrl: String = ""
}

/**
 * 判定一次回调该怎么做（纯函数，不碰网络/状态）。
 * 取值：accept = 收下 tempToken 去换 JWT；ignore = 只回 400 继续等；quit = 用户取消。
 * 三条实测校准的规则：
 *   ① 只有显式 quit 才终止会话——缺参数的回调（浏览器/华为页面的预检跳转）不废掉整次登录；
 *   ② code 不匹配不拒绝——华为回调里自带它自己的 code，硬比对会把正常登录判成 Bad code；
 *   ③ 非大陆站点（siteId != "1"）不收，但也不终止（用户可能换账号重试）。
 */
public func judgeCallback(code: String, tempToken: String, siteId: String, quit: Bool,
    expectCode: String): CallbackVerdict {
    let v = CallbackVerdict()
    if (quit) {
        v.decision = "quit"
        v.reason = "登录被取消（浏览器侧 quit）"
        return v
    }
    if (tempToken == "" || siteId == "") {
        v.decision = "ignore"
        v.reason = "回调缺 tempToken/siteId（可能是页面预检跳转），已忽略、继续等待"
        return v
    }
    if (!isChinaSite(siteId)) {
        v.decision = "ignore"
        v.reason = "非大陆站点账号（siteId=${siteId}），已忽略；请用大陆站点账号重试"
        return v
    }
    v.decision = "accept"
    v.tempToken = tempToken
    v.siteId = siteId
    if (code != expectCode) {
        v.reason = "回调 code 与本机生成的不一致（已放行，仅记录）"
    }
    return v
}

/** 一次回调的判定结果 */
public class CallbackVerdict {
    public var decision: String = "ignore"
    public var reason: String = ""
    public var tempToken: String = ""
    public var siteId: String = ""
}

/**
 * /callback 处理器。
 * 用类而不是 lambda：仓颉的 lambda 不能捕获可变局部变量，而这里必须把回调参数带回主线程。
 */
class SignCallbackHandler <: HttpRequestHandler {
    private let state: SignCallbackState
    private let expectCode: String

    public init(state: SignCallbackState, expectCode: String) {
        this.state = state
        this.expectCode = expectCode
    }

    public func handle(ctx: HttpContext): Unit {
        let res = ctx.responseBuilder
        if (ctx.request.url.path != AGC_CALLBACK_PATH) {
            res.status(404)
            res.body("not found".toArray())
            return
        }
        // Host 白名单：只认我们自己的两个名字（本机回环）
        var host = ""
        match (ctx.request.headers.getFirst("Host")) {
            case Some(v) => host = v
            case None => ()
        }
        let h = agcLowerAscii(host.trimAscii())
        let port = this.state.port
        let okHost = h == "127.0.0.1:${port}" || h == "localhost:${port}"
        if (!okHost) {
            // 只回 400，不终止等待：可能只是某个杂请求/旧链接打进来
            res.status(400)
            res.header("Connection", "close")
            res.body("Bad Host".toArray())
            return
        }
        var query = ""
        match (ctx.request.url.query) {
            case Some(v) => query = v
            case None => ()
        }
        // 华为登录页可能是 POST 表单把回调参数发回来：只读 query 会漏掉 tempToken，
        // 于是被判成"预检跳转"→ 用户看到页面反复回到回调页
        var bodyText = ""
        try {
            bodyText = StringReader(ctx.request.body).readToEnd()
        } catch (e: Exception) {
            let _ = e
        }
        let q = parseQueryParams(query)
        if (bodyText.trimAscii() != "") {
            let bq = parseQueryParams(bodyText)
            for ((k, v) in bq) {
                if (!q.contains(k)) {
                    q.add(k, v)
                }
            }
        }
        var gotCode = ""
        var tempToken = ""
        var siteId = ""
        var quit = false
        match (q.get("code")) {
            case Some(v) => gotCode = v
            case None => ()
        }
        match (q.get("tempToken")) {
            case Some(v) => tempToken = v
            case None => ()
        }
        match (q.get("siteId")) {
            case Some(v) => siteId = v
            case None => ()
        }
        match (q.get("quit")) {
            case Some(v) => quit = true
            case None => ()
        }
        if (this.state.rawQuery == "") {
            this.state.rawQuery = "queryLen=${query.size} bodyLen=${bodyText.size}" +
                "&codeLen=${gotCode.size}&siteId=${siteId}"
        }
        let verdict = judgeCallback(gotCode, tempToken, siteId, quit, this.expectCode)
        match (verdict.decision) {
            case "quit" =>
                this.state.quit = true
                this.state.rejectReason = verdict.reason
                res.status(302)
                res.header("Location", loginRedirectUrl(false))
                res.body(signLoginPageHtml(false, "已取消登录").toArray())
                this.state.done.store(true)
                return
            case "ignore" =>
                this.state.rejectReason = verdict.reason
                if (!isChinaSite(siteId) && tempToken != "") {
                    res.status(200)
                    res.header("Content-Type", "text/html; charset=utf-8")
                    res.body(signLoginPageHtml(false, verdict.reason).toArray())
                } else {
                    res.status(400)
                    res.header("Content-Type", "text/html; charset=utf-8")
                    res.body(("<!doctype html><meta charset=\"utf-8\"><title>内部回调地址</title>" +
                        "<body style=\"font-family:system-ui;padding:40px;color:#333\">" +
                        "<h2>这是内部回调地址</h2><p>它只用于接收华为登录页的跳转，<b>不要手动打开</b>。</p>" +
                        "<p><a href=\"" + this.state.loginUrl + "\" style=\"font-size:18px\">" +
                        "点这里去华为登录页（同一条有效链接）</a></p>" +
                        "<p style=\"color:#888\">或者回到终端里复制打印出来的那条 /console/DevEcoIDE/apply?... 链接。</p>" +
                        "</body>").toArray())
                }
                return
            case _ => ()
        }
        if (verdict.reason != "") {
            this.state.rejectReason = verdict.reason
        }
        this.state.code = gotCode
        this.state.tempToken = tempToken
        this.state.siteId = siteId
        res.status(302)
        res.header("Location", loginRedirectUrl(true))
        res.body(signLoginPageHtml(true, "授权完成，可以关闭此页").toArray())
        this.state.done.store(true)
    }
}

/** 登录成功/失败页（纯文本 HTML，刻意不带外链） */
public func signLoginPageHtml(ok: Bool, msg: String): String {
    let color = if (ok) { "#1f7a45" } else { "#b03a2e" }
    let title = if (ok) { "登录成功" } else { "登录未完成" }
    return "<!doctype html><meta charset=\"utf-8\"><title>${title}</title>" +
        "<body style=\"font-family:system-ui;padding:40px;color:#333\">" +
        "<h2 style=\"color:${color}\">${title}</h2><p>${msg}</p>" +
        "<p style=\"color:#888\">cj-tauri · 自动签名登录</p></body>"
}

/** 32 位小写 hex（16 随机字节）：登录回调的防伪 code */
public func signRandomHex32(): String {
    return toHexLower(signRandomBytes(16))
}

/**
 * 打开浏览器。
 * 别用 cmd /c start：<url> 里带 &，cmd 会把 & 当命令分隔符，浏览器只拿到残缺链接。
 * 改用 rundll32 url.dll,FileProtocolHandler：不经 cmd 的命令解析。
 * 其它平台用 xdg-open / open（按 argv 收参，没有 shell 解析问题）。
 */
public func signOpenUrlInBrowser(url: String): String {
    var cmd = ""
    var args = ArrayList<String>()
    if (signIsWindowsHost()) {
        cmd = "rundll32"
        args.add("url.dll,FileProtocolHandler")
        args.add(url)
    } else if (exists(Path("/usr/bin/xdg-open"))) {
        cmd = "xdg-open"
        args.add(url)
    } else {
        cmd = "open"
        args.add(url)
    }
    try {
        let (code, _, errOut) = executeWithOutput(cmd, args.toArray())
        if (code != 0) {
            return "打开浏览器失败（exit=${code}）：${lenientUtf8(errOut)}"
        }
        return ""
    } catch (e: Exception) {
        return "打开浏览器失败：${e}"
    }
}

/** 阻塞式登录：起回调服务 → 打印/打开登录页 → 等回调 → 换 JWT → 校验 → 拉团队 */
public func agcLogin(timeoutSec: Int64, openBrowser: Bool): AgcLoginOutcome {
    let out = AgcLoginOutcome()
    let state = SignCallbackState()
    // 允许外部指定回调 code（自动化/自测用）
    var expectCode = signRandomHex32()
    let codeOverride = signEnvOf("CJ_TAURI_SIGN_LOGIN_CODE").trimAscii()
    if (codeOverride.size == 32) {
        expectCode = codeOverride
    }
    var server: Option<Server> = None
    var port: Int64 = 0
    try {
        let s = ServerBuilder().addr("127.0.0.1").port(0).build()
        server = Some(s)
    } catch (e: Exception) {
        out.error = "起本机回调服务失败：${e}"
        return out
    }
    let srv = server.getOrThrow()
    // 顺序很关键：先注册路由、挂 afterBind，再 spawn serve，等绑定完成才读端口。
    // port(0) 的实际端口只有 bind 之后才有值；一开始就读会拿到 0。
    try {
        srv.distributor.register(AGC_CALLBACK_PATH, SignCallbackHandler(state, expectCode))
    } catch (e: Exception) {
        out.error = "注册回调路由失败：${e}"
        return out
    }
    let ready = SyncCounter(1)
    srv.afterBind({ => ready.dec() })
    let serveFailed = AtomicBool(false)
    spawn {
        try {
            srv.serve()
        } catch (e: Exception) {
            let _ = e
            serveFailed.store(true)
        }
    }
    ready.waitUntilZero()
    port = Int64(srv.port)
    state.port = port
    out.port = port
    if (port <= 0) {
        out.error = "拿不到回调服务端口"
        try {
            srv.closeGracefully()
        } catch (e: Exception) {
            let _ = e
        }
        return out
    }
    let url = oauthLoginUrl(port, expectCode)
    state.loginUrl = url
    println("")
    println("──────────────────────────────────────────────")
    println("  cj-tauri 鸿蒙自动签名：请在浏览器完成一次登录")
    println("  ${url}")
    println("  （本机回调已就绪：http://127.0.0.1:${port}${AGC_CALLBACK_PATH}）")
    println("──────────────────────────────────────────────")
    if (openBrowser) {
        let msg = signOpenUrlInBrowser(url)
        if (msg != "") {
            println("  ${msg}（可手动复制上面的链接到浏览器）")
        }
    }
    // 等回调（轮询 200ms；超时或服务异常都退出）
    var waited: Int64 = 0
    let limitMs = if (timeoutSec <= 0) { 300000 } else { timeoutSec * 1000 }
    while (waited < limitMs) {
        if (state.done.load()) {
            break
        }
        if (serveFailed.load()) {
            break
        }
        try {
            sleep(Duration.millisecond * 200)
        } catch (e: Exception) {
            let _ = e
        }
        waited += 200
    }
    try {
        srv.closeGracefully()
    } catch (e: Exception) {
        let _ = e
    }
    // 回调证据落文件（要当证据的东西别只打日志）
    if (state.rawQuery != "") {
        try {
            let dir = cjTauriSignStateDir()
            if (dir != "") {
                Directory.create(Path(dir), recursive: true)
                let line = "${signNowMs()} callback: ${state.rawQuery}\n"
                let logPath = "${dir}/login-callback.log"
                var prev = ""
                if (exists(Path(logPath))) {
                    prev = String.fromUtf8(File.readFrom(logPath))
                }
                File.writeTo(logPath, (prev + line).toArray())
            }
        } catch (e: Exception) {
            let _ = e
        }
    }
    if (state.tempToken == "") {
        out.error = if (state.rejectReason != "") { state.rejectReason } else { "回调里没有 tempToken" }
        if (!state.done.load() && state.quit) {
            out.error = state.rejectReason
        } else if (!state.done.load()) {
            out.error = "等回调超时（${timeoutSec} 秒）：浏览器里没有完成登录？"
        }
        return out
    }
    if (!state.done.load()) {
        out.error = "等回调超时（${timeoutSec} 秒）：浏览器里没有完成登录？"
        return out
    }
    // tempToken → JWT
    let jwtResp = agcHttp("GET", tempTokenCheckUrl(state.tempToken), ArrayList<String>(), "", 30000)
    if (jwtResp.error != "") {
        out.error = "换 JWT 失败：${jwtResp.error}"
        return out
    }
    let jwt = jwtResp.body.trimAscii()
    if (jwtResp.status != 200 || !isJwtShaped(jwt)) {
        out.error = "换 JWT 失败：HTTP ${jwtResp.status}，响应不是 JWT（前 80 字：${signClip(jwt, 80)}）"
        return out
    }
    out.jwt = jwt
    // JWT 校验 → userInfo
    let headers = ArrayList<String>()
    headers.add("refresh: true")
    headers.add("jwtToken: ${jwt}")
    let checkResp = agcHttp("GET", jwtCheckUrl(), headers, "", 30000)
    if (checkResp.error != "") {
        out.error = "校验 JWT 失败：${checkResp.error}"
        return out
    }
    if (checkResp.status != 200) {
        out.error = "校验 JWT 失败：HTTP ${checkResp.status}（token 可能已失效）"
        return out
    }
    var root: JsonValue
    try {
        root = JsonValue.fromStr(checkResp.body)
    } catch (e: Exception) {
        out.error = "校验 JWT 的响应不是 JSON：${e}"
        return out
    }
    let info = signJsonObjectField(root, "userInfo")
    out.accessToken = signJsonStringField(info, "accessToken")
    out.userId = signJsonStringField(info, "userId")
    out.userName = signJsonStringField(info, "name")
    out.refreshToken = signJsonStringField(info, "refreshToken")
    out.countryCode = signJsonStringField(info, "nationalCode")
    out.isRealName = signJsonStringField(info, "realName") == "true"
    if (out.accessToken == "") {
        out.error = "JWT 校验通过但没拿到 accessToken（账号可能未开通 AppGallery Connect）"
        return out
    }
    let saveErr = saveAgcToken(out)
    if (saveErr != "") {
        eprintln("[sign] 令牌落盘失败：${saveErr}")
    }
    // 团队（默认取第一个，与 flutter 一致）
    match (agcTeamList(out.accessToken, out.userId)) {
        case Some(t) =>
            out.teamId = t.id
            out.teamName = t.name
            out.teamCount = t.count
        case None => ()
    }
    out.ok = true
    return out
}

/** 取文本片段（错误信息只要前几句就够定位） */
public func signClip(s: String, n: Int64): String {
    if (s.size <= n) {
        return s
    }
    return "${s[0..n]}…"
}

// ============================================================
// 令牌落盘（AES-128-GCM + 本机 KEK）
// ============================================================

func signAgcKekPath(): String {
    return "${cjTauriSignStateDir()}/kek.bin"
}

func signAgcTokenPath(): String {
    return "${cjTauriSignStateDir()}/token.enc"
}

/** 本机 KEK：没有就生成一个 32 字节随机文件（只用于加密本地令牌，不外发） */
func signEnsureKek(): (Array<Byte>, String) {
    let path = signAgcKekPath()
    try {
        if (exists(Path(path))) {
            let data = File.readFrom(path)
            if (data.size >= 32) {
                return (data[0..32], "")
            }
        }
        let dir = cjTauriSignStateDir()
        if (dir != "" && !exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
        let key = signRandomBytes(32)
        File.writeTo(path, key)
        return (key, "")
    } catch (e: Exception) {
        return ([], "KEK 读写失败：${e}")
    }
}

/** 令牌 JSON（落盘前的一层结构；jwt/refreshToken 也一并密文保存） */
func signAgcTokenJson(out: AgcLoginOutcome): String {
    var o = JsonObject()
    o.put("savedAt", JsonInt(signNowMs()))
    o.put("userName", JsonString(out.userName))
    o.put("userId", JsonString(out.userId))
    o.put("accessToken", JsonString(out.accessToken))
    o.put("jwt", JsonString(out.jwt))
    o.put("refreshToken", JsonString(out.refreshToken))
    o.put("countryCode", JsonString(out.countryCode))
    o.put("isRealName", JsonBool(out.isRealName))
    o.put("teamId", JsonString(out.teamId))
    o.put("teamName", JsonString(out.teamName))
    return o.toJsonString()
}

/** 令牌密文落盘（整份 JSON 用 KEK 加密） */
public func saveAgcToken(out: AgcLoginOutcome): String {
    let (kek, err) = signEnsureKek()
    if (err != "") {
        return err
    }
    let plain = signAgcTokenJson(out).toArray()
    let iv = signRandomBytes(AES_GCM_IV_LEN)
    let sealed = aes128GcmEncrypt(kek[0..16], iv, plain, Array<Byte>())
    let payload = packGcmPayload(iv, sealed[0..(sealed.size - AES_GCM_TAG_LEN)],
        sealed[(sealed.size - AES_GCM_TAG_LEN)..sealed.size])
    match (payload) {
        case Some(raw) =>
            try {
                let sdir = cjTauriSignStateDir()
                if (sdir != "" && !exists(Path(sdir))) {
                    Directory.create(Path(sdir), recursive: true)
                }
                File.writeTo(signAgcTokenPath(), toHexLower(raw).toArray())
                return ""
            } catch (e: Exception) {
                return "令牌写盘失败：${e}"
            }
        case None => return "令牌载荷打包失败"
    }
}

/** 读回令牌；过期或损坏返回 None（让调用方提示重新登录） */
public func loadAgcToken(): Option<AgcLoginOutcome> {
    let path = signAgcTokenPath()
    if (!exists(Path(path))) {
        return None
    }
    let (kek, err) = signEnsureKek()
    if (err != "") {
        return None
    }
    var hexText = ""
    try {
        hexText = String.fromUtf8(File.readFrom(path))
    } catch (e: Exception) {
        let _ = e
        return None
    }
    match (fromHexLower(hexText)) {
        case Some(raw) =>
            match (unpackGcmPayload(raw)) {
                case Some(p) =>
                    var plain: Array<Byte> = []
                    try {
                        plain = aes128GcmDecrypt(kek[0..16], p.iv,
                            signConcatBytes(p.ciphertext, p.tag), Array<Byte>())
                    } catch (e: Exception) {
                        let _ = e
                        return None
                    }
                    var root: JsonValue
                    try {
                        root = JsonValue.fromStr(String.fromUtf8(plain))
                    } catch (e: Exception) {
                        let _ = e
                        return None
                    }
                    let out = AgcLoginOutcome()
                    out.accessToken = signJsonStringField(root, "accessToken")
                    out.userId = signJsonStringField(root, "userId")
                    out.userName = signJsonStringField(root, "userName")
                    out.jwt = signJsonStringField(root, "jwt")
                    out.refreshToken = signJsonStringField(root, "refreshToken")
                    out.countryCode = signJsonStringField(root, "countryCode")
                    out.isRealName = signJsonBoolField(root, "isRealName")
                    out.teamId = signJsonStringField(root, "teamId")
                    out.teamName = signJsonStringField(root, "teamName")
                    let savedAt = signJsonIntField(root, "savedAt", 0)
                    // 令牌约 4 小时过期：超期的按"没有令牌"处理（提示重新登录）
                    if (savedAt > 0 && signNowMs() - savedAt > 4 * 3600 * 1000) {
                        return None
                    }
                    if (out.accessToken == "" || out.userId == "") {
                        return None
                    }
                    return Some(out)
                case None => return None
            }
        case None => return None
    }
}
