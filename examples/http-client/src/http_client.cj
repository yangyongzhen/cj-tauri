/**
 * HTTP API 客户端示例的网络核心（**不依赖框架**，只 import std / stdx）
 *
 * 刻意与 `main.cj` 分层：这里只有「解析目标 → 判白名单 → 发请求 → 按上限读体 → 组装结果」，
 * 一条 IPC、一个命令都不认识。好处是这一层是**纯逻辑**（除了真发请求那一步），
 * 将来要给它补 `cjpm test` 不必先搭一个宿主；命令层只负责把入参搬进来、把结果拼成 JSON。
 *
 * 三条口径都在这里落地，理由见 docs/设计决策记录.md D-017：
 *  1. **主机白名单是唯一能收住 SSRF 的地方**（命令参数是页面可控字符串）——缺省只放本机，fail-safe；
 *  2. **大响应体读满即停**，而不是先读进来再截：先读进来等于把内存交给对端；
 *  3. **非文本体不进 IPC**：Content-Type 不在文本白名单里就只回字节数，回投一段随机字节没有意义。
 */
package http_client

import std.collection.*
import std.convert.*
import std.env.*
import std.io.*
import std.time.*
import stdx.encoding.json.*
import stdx.encoding.url.*
import stdx.net.http.*
// TlsClientConfig 在 stdx.net.tls 里，不在 net.http（movie 示例两行都在，这里同理）
import stdx.net.tls.*

/** 响应体默认上限：1 MiB（`CJ_HTTP_BODY_LIMIT` 可调）——见 D-017 第 3 条 */
let HTTP_DEFAULT_BODY_LIMIT: Int64 = 1024 * 1024

/** 单次请求默认超时 10s（`timeoutMs` 参数可覆盖） */
let HTTP_DEFAULT_TIMEOUT_MS: Int64 = 10000

/**
 * 白名单缺省值：**只放本机**
 *
 * fail-safe 而不是 fail-open——没配 `CJ_HTTP_ALLOW` 时，这个页面发不出任何对外的请求。
 * 手工玩公网端点要显式 `CJ_HTTP_ALLOW=*`（README 里写明了代价）。
 */
let HTTP_DEFAULT_ALLOW_HOSTS: String = "127.0.0.1,localhost,::1"

/**
 * 主机白名单（逗号分隔解析，`*` 表示全放行）
 *
 * 只在**命令层之外**判一次，且只判 host：不判端口、不判路径——端口不是 SSRF 的边界
 * （`127.0.0.1:8080` 与 `127.0.0.1:9090` 在本机是同一类东西），路径由对端自己管。
 */
public class HostAllowList {
    private let hosts: ArrayList<String>
    // 必须是 var：解析 `*` 时要就地置位（仓颉的 let 字段不可再赋值）
    private var anyHost: Bool

    public init(raw: String) {
        this.hosts = ArrayList<String>()
        this.anyHost = false
        for (part in raw.split(",")) {
            let h = part.trimAscii().toAsciiLower()
            if (h.size == 0) {
                continue
            }
            if (h == "*") {
                this.anyHost = true
                continue
            }
            this.hosts.add(h)
        }
    }

    /** 从环境变量取白名单；没配就是「只放本机」 */
    public static func fromEnv(): HostAllowList {
        match (getVariable("CJ_HTTP_ALLOW")) {
            case Some(v) => return HostAllowList(v)
            case None => ()
        }
        return HostAllowList(HTTP_DEFAULT_ALLOW_HOSTS)
    }

    /**
     * host 是否放行
     *
     * `URL.hostName` 对 IPv6 字面量可能带方括号（`[::1]`），所以两种写法都比一次；
     * 大小写不敏感（host 名本来就大小写不敏感，白名单里写 `LocalHost` 不该失效）。
     */
    public func allows(host: String): Bool {
        if (this.anyHost) {
            return true
        }
        let h = host.trimAscii().toAsciiLower()
        var bare = h
        if (h.size >= 2 && h.startsWith("[") && h.endsWith("]")) {
            bare = h[1..h.size - 1]
        }
        for (item in this.hosts) {
            if (item == h || item == bare) {
                return true
            }
        }
        return false
    }

    /** 给日志与页面看的一行描述 */
    public func describe(): String {
        if (this.anyHost) {
            return "*"
        }
        var out = ""
        for (h in this.hosts) {
            if (out.size > 0) {
                out = out + ","
            }
            out = out + h
        }
        if (out.size == 0) {
            return "(空——任何 host 都不放行)"
        }
        return out
    }

    /** 白名单条目（页面要显示「现在放行谁」） */
    public func items(): Array<String> {
        return this.hosts.toArray()
    }

    public func allowAny(): Bool {
        return this.anyHost
    }
}

/**
 * 解析目标地址：只接受 http / https，返回（规范化后的 url, host）
 *
 * 规范化后的 url 会用**解析器自己的** `toString()`，而不是用户原样输入的那串——
 * 回投给页面的应当是「真正发出去的那个地址」，否则页面显示的地址与实际请求可能不是一回事
 * （大小写、默认端口、路径编码都可能被解析器规整）。
 */
public func parseTargetUrl(raw: String): (String, String) {
    let trimmed = raw.trimAscii()
    if (trimmed.size == 0) {
        throw IllegalArgumentException("地址为空")
    }
    let u = URL.parse(trimmed)
    let scheme = u.scheme.toAsciiLower()
    if (scheme != "http" && scheme != "https") {
        throw IllegalArgumentException("只支持 http / https，收到「${u.scheme}」")
    }
    let host = u.hostName
    if (host.size == 0) {
        throw IllegalArgumentException("地址里没有主机名：${raw}")
    }
    return (u.toString(), host)
}

/**
 * 按块读到 EOF，但**读满上限就停**（见 D-017 第 3 条）
 *
 * 返回值是（字节, 是否被截断）。停在上限处**不继续读**：对端还在吐数据时我们直接关连接，
 * 这比「读完了再切掉」省的是内存——一个 10 GB 的响应体能带走进程，切得再早也来不及。
 */
public func readBodyCapped(body: InputStream, limit: Int64): (Array<Byte>, Bool) {
    let buf = ByteBuffer()
    let chunk = Array<Byte>(8192, repeat: 0)
    var total: Int64 = 0
    var n = body.read(chunk)
    while (n > 0) {
        let room = limit - total
        if (n >= room) {
            if (room > 0) {
                buf.write(chunk[0..room])
            }
            return (buf.bytes(), true)
        }
        buf.write(chunk[0..n])
        total = total + n
        n = body.read(chunk)
    }
    return (buf.bytes(), false)
}

/**
 * Content-Type 是否够文本
 *
 * 判据是「页面上能不能当文字看」，所以放行 `text` 开头的类型、JSON、XML、表单，以及
 * `+json` / `+xml` 这类结构化后缀（`application/…+json` 这种带后缀的写法很常见）。
 * 没给 Content-Type 时按文本试（下面还有一次 UTF-8 校验兜底）。
 *
 * 注：这里的注释**不能**把 `text` 后面的通配写出来——仓颉的块注释里出现斜杠加星号会开启
 * 嵌套注释，整个文件都编译不过（AGENTS §4 那条坑，这次又踩了一遍）。
 */
public func isTextualContent(contentType: String): Bool {
    let ct = contentType.toAsciiLower()
    if (ct.size == 0) {
        return true
    }
    if (ct.startsWith("text/")) {
        return true
    }
    if (ct.startsWith("application/json") || ct.startsWith("application/xml")) {
        return true
    }
    if (ct.startsWith("application/x-www-form-urlencoded")) {
        return true
    }
    if (ct.contains("+json") || ct.contains("+xml")) {
        return true
    }
    return false
}

/**
 * 一次成功请求的原始结果（只装数据，不认识 IPC）
 *
 * `headers` 是**逐条**的 (名, 值) 列表，刻意不做合并：同名头可以出现多次，而 HTTP 语义里
 * 只有**部分**头允许合并（`Set-Cookie` 就不许）——合并成逗号串等于在页面上伪造一个不存在的头。
 */
public class HttpExchange {
    public let method: String
    public let url: String
    public let status: Int64
    public let elapsedMs: Int64
    public let headers: ArrayList<(String, String)>
    public let bytes: Array<Byte>
    public let truncated: Bool
    public let contentType: String
    public let contentLength: Option<Int64>
    public let bodyLimit: Int64

    public init(method: String, url: String, status: Int64, elapsedMs: Int64,
        headers: ArrayList<(String, String)>, bytes: Array<Byte>, truncated: Bool,
        contentType: String, contentLength: Option<Int64>, bodyLimit: Int64) {
        this.method = method
        this.url = url
        this.status = status
        this.elapsedMs = elapsedMs
        this.headers = headers
        this.bytes = bytes
        this.truncated = truncated
        this.contentType = contentType
        this.contentLength = contentLength
        this.bodyLimit = bodyLimit
    }

    /**
     * 体怎么解读：`empty` / `text` / `binary`
     *
     * 非文本类型**不算错**——调试工具该如实说「这是一段二进制」，而不是丢个空体让人猜。
     * 类型说是文本、字节却不是合法 UTF-8 的，同样归 `binary`：那是响应自己的问题，
     * 但把非法字节塞进 IPC 只会让页面显示乱码或炸掉，不会让用户更明白。
     */
    public func bodyKind(): String {
        if (this.bytes.size == 0) {
            return "empty"
        }
        if (!isTextualContent(this.contentType)) {
            return "binary"
        }
        match (textOf(this.bytes)) {
            case Some(_) => return "text"
            case None => return "binary"
        }
    }

    /** 文本体；非文本或非法 UTF-8 时给空串（原因由 `bodyKind` 说明） */
    public func bodyText(): String {
        match (textOf(this.bytes)) {
            case Some(t) => return t
            case None => return ""
        }
    }

    /** 拼成回投给页面的 JSON（字段名就是页面上用的那套，不在命令层再翻译一遍） */
    public func toJson(): JsonObject {
        let out = JsonObject()
        out.put("method", JsonString(this.method))
        out.put("url", JsonString(this.url))
        out.put("status", JsonInt(this.status))
        out.put("elapsedMs", JsonInt(this.elapsedMs))
        let hs = JsonArray()
        for ((name, value) in this.headers) {
            let one = JsonObject()
            one.put("name", JsonString(name))
            one.put("value", JsonString(value))
            hs.add(one)
        }
        out.put("headers", hs)
        out.put("bodyKind", JsonString(this.bodyKind()))
        out.put("bodyText", JsonString(this.bodyText()))
        out.put("bodyBytes", JsonInt(Int64(this.bytes.size)))
        out.put("bodyTruncated", JsonBool(this.truncated))
        out.put("bodyLimit", JsonInt(this.bodyLimit))
        out.put("contentType", JsonString(this.contentType))
        match (this.contentLength) {
            case Some(n) => out.put("contentLength", JsonInt(n))
            case None => out.put("contentLength", JsonNull())
        }
        return out
    }
}

/**
 * 把字节按 UTF-8 试解；含 NUL 字节或非法序列时返回 `None`
 *
 * NUL 单独判一道：二进制响应里它很常见，而「一段带 NUL 的字符串」在页面上是显示不出来的
 * （截断在第一个 NUL 或者干脆成方块），与其让用户以为响应就是这样，不如直说这是二进制。
 */
func textOf(bytes: Array<Byte>): Option<String> {
    if (bytes.size == 0) {
        return Some("")
    }
    for (b in bytes) {
        if (b == 0u8) {
            return None
        }
    }
    try {
        return Some(String.fromUtf8(bytes))
    } catch (e: Exception) {
        return None
    }
}

/** 一次请求的结局：拿到响应 / 前置拒绝 / 传输失败——三种都不抛异常，由命令层决定怎么回投 */
public enum HttpOutcome {
    | Exchange(HttpExchange)
    | Refused(String)
    | Failed(String)
}

/**
 * 发一次请求（同步阻塞；命令分发本身异步，所以调用方跑在 worker 线程上，见 AGENTS §2）
 *
 * 前置校验（scheme / 白名单）放在**建 Client 之前**：被拒的请求连客户端都不该建。
 * `autoRedirect(true)` 与 `movie` 示例一致——跟随重定向是调试工具的常态；
 * 「看重定向本身」属于后续（现在跟着走到终点，只留最终状态码）。
 */
public func sendHttp(method: String, url: String, headers: ArrayList<(String, String)>,
    body: Option<String>, timeoutMs: Int64, limit: Int64, allow: HostAllowList): HttpOutcome {
    var target = ""
    var host = ""
    try {
        let (t, h) = parseTargetUrl(url)
        target = t
        host = h
    } catch (e: IllegalArgumentException) {
        return Refused("${e}")
    }
    if (!allow.allows(host)) {
        eprintln("[http-client] refused: host=${host} not in allowlist (${allow.describe()})")
        return Refused("主机「${host}」不在白名单里（当前放行：${allow.describe()}）；要放行请用 CJ_HTTP_ALLOW 启动")
    }

    let client = ClientBuilder()
        // 必须显式配 TLS：仓颉的 HTTP 客户端不带默认 TLS（AGENTS §4），
        // TlsClientConfig() 默认走系统证书库校验——不关校验，否则等于给中间人开门
        .tlsConfig(TlsClientConfig())
        // 客户端级兜底超时；真正的口径在请求级（见下），两个都设上以防某一层不生效
        .readTimeout(Duration.millisecond * timeoutMs)
        .writeTimeout(Duration.millisecond * timeoutMs)
        .autoRedirect(true)
        .build()

    var status: Int64 = 0
    var hs = ArrayList<(String, String)>()
    var data: Array<Byte> = []
    var truncated = false
    var ctype = ""
    var clen: Option<Int64> = None
    var transportError: Option<String> = None

    let started = DateTime.now()
    try {
        var builder = HttpRequestBuilder()
            .url(target)
            .method(method)
            .readTimeout(Duration.millisecond * timeoutMs)
            .writeTimeout(Duration.millisecond * timeoutMs)
        for ((name, value) in headers) {
            builder = builder.header(name, value)
        }
        match (body) {
            case Some(b) => builder = builder.body(b)
            case None => ()
        }
        let resp = client.send(builder.build())
        status = Int64(resp.status)
        for ((name, values) in resp.headers) {
            for (v in values) {
                // 先落成局部元组再 add：直接写 add((a, b)) 会被当成「两个实参」而报参数不匹配
                let pair = (name, v)
                hs.add(pair)
            }
        }
        match (resp.headers.getFirst("Content-Type")) {
            case Some(v) => ctype = v
            case None => ()
        }
        // Content-Length 只当「对端自报的」来用：HTTP/1.1 的分块响应根本没有它，
        // 而且它可能撒谎——所以截断判定看的是实际读到的字节，不是这个数
        match (resp.headers.getFirst("Content-Length")) {
            case Some(v) =>
                try {
                    clen = Some(Int64.parse(v))
                } catch (e: Exception) {
                    clen = None
                }
            case None => ()
        }
        let (chunkBytes, wasTruncated) = readBodyCapped(resp.body, limit)
        data = chunkBytes
        truncated = wasTruncated
        resp.close()
    } catch (e: Exception) {
        transportError = Some("${e}")
    }
    let elapsed = (DateTime.now() - started).toMilliseconds()
    client.close()

    if (let Some(msg) <- transportError) {
        eprintln("[http-client] ${method} ${target} -> failed: ${msg}")
        return Failed(msg)
    }
    // 每次请求一行 stderr：端到端取证以这几行为准（stdout 有缓冲，进程被强杀时会丢）
    eprintln("[http-client] ${method} ${target} -> ${status} ${data.size}B ${elapsed}ms truncated=${truncated}")
    if (truncated) {
        eprintln("[http-client] body truncated at ${limit} bytes (真实体更大，已停止读取)")
    }
    return Exchange(HttpExchange(method, target, status, elapsed, hs, data, truncated, ctype, clen, limit))
}
