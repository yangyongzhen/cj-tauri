package cjTauri.plugins.http

import cjTauri.*

@When[env != "ohos"]
import std.collection.*

@When[env != "ohos"]
import std.io.*

@When[env != "ohos"]
import stdx.net.http.*

@When[env != "ohos"]
import stdx.net.tls.*

/*
 * 桌面两端的出网实现（Linux / Windows）：stdx.net.http
 *
 * 与鸿蒙侧的分界：本文件只在 `env != "ohos"` 编译，`http_ohos.cj` 反之。
 * 上层（`plugin_http.cj`）只认两个函数名，不出现任何平台分支。
 */

/**
 * 发一次请求并读完响应体（撞 `CJ_HTTP_MAX_BYTES` 上限则截断并置 `truncated`）
 *
 * 调用方（`HttpCommands`）已经做过主机白名单判定与参数解析——本函数只管「怎么发出去」。
 * 三个口径与改造前完全一致，别顺手改：
 * - **禁自动重定向**：3xx 原样回给页面，白名单只判第一跳；
 * - 每个请求**新建 Client**（共享 Client 的线程安全性本仓没验证过，见 `HttpPlugin` 类注释）；
 * - `resp.body` 的静态类型只有 InputStream，`readToEnd` 编译不过（泛型约束要 Seekable，
 *   AGENTS §4），所以按块读到 EOF 或上限。
 */
@When[env != "ohos"]
public func httpTransportSend(method: String, url: String, host: String,
    headers: HashMap<String, String>, body: String): HttpReply {
    var builder = HttpRequestBuilder().url(url)
    if (method == "GET") {
        builder = builder.get()
    } else if (method == "DELETE") {
        // DELETE 也带 JSON 体：cjh 的工作区删除靠 body 传 path（其 rest_api 的 DELETE 分支
        // 读的就是请求体），所以这里不能走「无体 DELETE」那条路
        builder = builder.delete().body(body)
    } else {
        builder = builder.post().body(body)
    }
    // 默认头：JSON 客户端最常见形态；页面可用 headers 覆盖/追加（Host/Content-Length 已剔除）
    builder = builder.header("Accept", "application/json, text/event-stream, */*")
    for ((name, value) in headers) {
        builder = builder.header(name, value)
    }

    let client = ClientBuilder()
        .tlsConfig(tlsConfigForHost(host))
        .autoRedirect(false)
        .readTimeout(Duration.second * CJ_HTTP_TIMEOUT_SECONDS)
        .writeTimeout(Duration.second * CJ_HTTP_TIMEOUT_SECONDS)
        .build()
    var status: Int64 = 0
    var ctype = ""
    var text = ""
    var truncated = false
    try {
        let resp = client.send(builder.build())
        status = Int64(resp.status)
        // 头名大小写在 HTTP 里不敏感，但取法只有 getFirst（**没有 get**，AGENTS §4）
        ctype = match (resp.headers.getFirst("Content-Type")) {
            case Some(v) => v
            case None => ""
        }
        // ByteBuffer 没有 size 属性：字节数自己累加（要掐上限，所以不用现成的 readBodyBytes）
        let buf = ByteBuffer()
        let chunk = Array<Byte>(8192, repeat: 0)
        var total: Int64 = 0
        var n = resp.body.read(chunk)
        while (n > 0) {
            if (total + n > CJ_HTTP_MAX_BYTES) {
                buf.write(chunk[0..(CJ_HTTP_MAX_BYTES - total)])
                truncated = true
                break
            }
            buf.write(chunk[0..n])
            total += n
            n = resp.body.read(chunk)
        }
        resp.close()
        text = String.fromUtf8(buf.bytes())
    } finally {
        client.close()
    }
    return HttpReply(status, ctype, text, truncated)
}

/**
 * 打开一个流式响应（SSE / 长回复增量回投用）
 *
 * 句柄持有 body 与 client，`close()` 一并释放——**句柄不关闭等于泄漏连接**，调用方必须
 * 放在 finally 里。连接与响应都归这一条命令线程所有，不跨线程共享。
 */
@When[env != "ohos"]
public func httpTransportOpenStream(url: String, host: String,
    headers: HashMap<String, String>, body: String): HttpResponseStream {
    var builder = HttpRequestBuilder().url(url).post().body(body)
    builder = builder.header("Accept", "text/event-stream")
    for ((name, value) in headers) {
        builder = builder.header(name, value)
    }
    let client = ClientBuilder()
        .tlsConfig(tlsConfigForHost(host))
        .autoRedirect(false)
        .readTimeout(Duration.second * CJ_HTTP_TIMEOUT_SECONDS)
        .writeTimeout(Duration.second * CJ_HTTP_TIMEOUT_SECONDS)
        .build()
    try {
        let resp = client.send(builder.build())
        let ctype = match (resp.headers.getFirst("Content-Type")) {
            case Some(v) => v
            case None => ""
        }
        return StdHttpStream(Int64(resp.status), ctype, resp.body, client)
    } catch (e: Exception) {
        // 建连/握手/首字节就失败：client 还没交给句柄，这里必须自己收掉，否则泄漏
        client.close()
        throw e
    }
}

/**
 * stdx 响应体的流式包装
 *
 * 只持 `InputStream` 与 `Client`，**不持响应对象**——响应体的读与关闭已经够用，
 * 少一个类型依赖少一处跨版本形状风险。
 */
@When[env != "ohos"]
class StdHttpStream <: HttpResponseStream {
    private let st: Int64
    private let ct: String
    private let body: InputStream
    private let client: Client
    private var closed = false

    init(st: Int64, ct: String, body: InputStream, client: Client) {
        this.st = st
        this.ct = ct
        this.body = body
        this.client = client
    }

    // 接口成员隐式 public，实现类里必须显式写 public（否则报「must be at least as visible」）
    public func status(): Int64 {
        return this.st
    }

    public func contentType(): String {
        return this.ct
    }

    public func read(buf: Array<Byte>): Int64 {
        return this.body.read(buf)
    }

    /** 幂等：finally 与异常路径都可能调到，重复关不抛 */
    public func close(): Unit {
        if (this.closed) {
            return
        }
        this.closed = true
        try {
            this.client.close()
        } catch (_: Exception) {
            // 关连接失败不影响已经收到的内容，吞掉
        }
    }
}

/**
 * 建 TLS 客户端配置：**域名必须显式写 `serverName`（SNI）**
 *
 * stdx 的 `TlsClientConfig()` 默认不发 SNI，而多租户 HTTPS 边缘（实测 Cloudflare 后面的
 * api 域名）收不到 SNI 就以 `handshake failure`(40) 拒掉握手——表象是「TLS 握手失败」，
 * 同一地址 curl / openssl 打起来一切正常，极易误判成对端故障、甚至误判成白名单问题
 * （AGENTS §4 有这条坑）。IP 字面量**不带** SNI：RFC 6066 不许，且「https 直连 IP」原本
 * 可用，不能反被改坏。
 *
 * 这七行故意留在插件里而不进核心共享层：核心一引用 `stdx.net.tls`，不用 TLS 的应用也会
 * 被拉上 OpenSSL 依赖，单文件打包契约跟着变形（§2 的包粒度纪律）；ws 插件里那份是同样的七行。
 */
@When[env != "ohos"]
func tlsConfigForHost(host: String): TlsClientConfig {
    var cfg = TlsClientConfig()
    if (!isIpLiteralHost(host)) {
        cfg.serverName = host
    }
    return cfg
}
