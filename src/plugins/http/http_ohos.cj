package cjTauri.plugins.http

@When[env == "ohos"]
import cjTauri.*

@When[env == "ohos"]
import ohos.net.http.*

@When[env == "ohos"]
import std.collection.*

/*
 * 鸿蒙侧的出网实现：系统网络栈 `ohos.net.http`（NetworkKit）
 *
 * ## 为什么不是 stdx.net.http
 *
 * 仓颉运行时在鸿蒙上**装不了 OpenSSL 3**：真机 hilog 是
 *   `MUSL-LDSO: load libcrypto_openssl.z.so failed, namespace=moduleNs_default, errno=2`
 * （`libssl_openssl.z.so` 同样），即运行时按名字 dlopen、设备上没有这个库。于是 stdx 的 TLS
 * 从第一步就不可用，全部 https 当场失败、http 照旧——这种「半死」状态最容易误判成网络/权限问题
 * （AGENTS §4 有完整形状，判据见 `docs/鸿蒙ArkWeb接入踩坑.md` §10.15）。
 *
 * 换成系统栈之后 TLS / 证书链 / 代理都交给 OS，本文件只管组请求、等结果、解码。
 * **不要**往 hap 里塞 OpenSSL：运行时是 musl 静态链，AOSP 那份的 ABI 与符号都对不上。
 *
 * ## 为什么这里是阻塞等回调
 *
 * `HttpRequest.request` 只有回调形态（没有同步版本），而命令 handler 跑在框架的 worker
 * 线程上（不是 UI 线程），所以「发请求 → sleep 轮询等回调」是安全的：冻不住界面。
 * **这个写法不能搬到 UI 线程**（那会把界面卡满整个超时预算）。
 *
 * ## 形状依据与未验证项（本机没有鸿蒙仓颉工具链，编不了这一支）
 *
 * 建客户端的调用形状照抄 `examples/ohos/ohos-movie/entry/src/main/cangjie/ohos_movie_image.cj`
 * ——那份是**真机验证过**的（`client.request(url, options) { err, resp => … }` 位置参数 + 尾随
 * 闭包、`HttpDataType.ArrayBuffer`、`resp.responseCode` / `resp.result` / `resp.header`、
 * `client.destroy()`）。两处是本机核不到、要在真机构建时确认的：
 * ① `RequestMethod` 的成员名（`Get` 是 precedent 里的写法，`Post` / `Delete` 按同一命名风格推）；
 * ② `HttpRequestOptions.extraData` 承载 POST 体（官方文档确认该字段存在，仓内无用法先例）。
 * 真机首跑若在这两处报错，改的是**这一支**，不要回头动 `plugin_http.cj`（命令面对两平台一致）。
 */

/** 轮询回调的间隔（毫秒）：与 ohos-movie 取封面的轮询同口径 */
@When[env == "ohos"]
let OHOS_HTTP_POLL_MS: Int64 = 20

/**
 * 回调与命令线程之间搬结果用的盒子
 *
 * 仓颉的 lambda **不能捕获可变的局部变量**（AGENTS §4），所以结果装在对象里、闭包只改字段。
 * 回调线程与轮询线程之间没有加锁——与真机验证过的 `ohos_movie_image.cj` 同形（那边同样只写
 * `done` / `bytes` 这类简单字段）。真要改成并发安全的，两边得一起改，别只改这边。
 */
@When[env == "ohos"]
class OhosHttpFeed {
    var done = false
    var failure: Option<String> = None
    var status: Int64 = 0
    var bytes: Array<Byte> = []
    var contentType: String = ""
}

/** 命令的 HTTP 方法 → 系统栈的枚举（GET 是兜底：本插件只会传这三者之一） */
@When[env == "ohos"]
func ohosMethodOf(method: String): RequestMethod {
    if (method == "POST") {
        return RequestMethod.Post
    }
    if (method == "DELETE") {
        return RequestMethod.Delete
    }
    return RequestMethod.Get
}

/** 把响应体统一成字节：期望类型是 ArrayBuffer，个别实现仍可能回字符串 */
@When[env == "ohos"]
func ohosResponseBytes(data: HttpData): Array<Byte> {
    match (data) {
        case ArrayData(b) => return b
        case StringData(s) => return s.toArray()
        case _ => return Array<Byte>()
    }
}

/**
 * 发一次请求，返回 `(状态码, Content-Type, 响应体字节)`
 *
 * 失败一律转成 `CommandException`（业务错误）：命令面回给页面的是业务错误，不是框架内部异常。
 * 超时既可能是 `request` 同步抛、也可能是回调来得太晚，两种都收口到同一句话。
 */
@When[env == "ohos"]
func ohosRequest(method: String, url: String, headers: HashMap<String, String>,
    body: String): (Int64, String, Array<Byte>) {
    let feed = OhosHttpFeed()
    // 页面头原样带上（Host / Content-Length 已在 parsePageHeaders 里剔除——判定只在那份）
    let hdrs = HashMap<String, String>()
    for ((k, v) in headers) {
        hdrs[k] = v
    }
    if (!hdrs.contains("accept")) {
        // 默认头与非流式命令的桌面侧一致（页面给了就尊重页面的）
        hdrs["Accept"] = "application/json, text/event-stream, */*"
    }
    let timeoutMs = UInt32(CJ_HTTP_TIMEOUT_SECONDS * 1000)
    let client = createHttp()
    try {
        // GET 不带体：extraData 在 GET 上会被拼成查询参数，所以两种形状分开构造
        let options = if (method == "GET") {
            HttpRequestOptions(
                method: RequestMethod.Get,
                expectDataType: HttpDataType.ArrayBuffer,
                header: hdrs,
                readTimeout: timeoutMs,
                connectTimeout: timeoutMs
            )
        } else {
            HttpRequestOptions(
                method: ohosMethodOf(method),
                extraData: StringData(body),
                expectDataType: HttpDataType.ArrayBuffer,
                header: hdrs,
                readTimeout: timeoutMs,
                connectTimeout: timeoutMs
            )
        }
        client.request(url, options) { err, resp =>
            match (err) {
                case Some(e) => feed.failure = Some("${e}")
                case None => ()
            }
            match (resp) {
                case Some(r) =>
                    feed.status = Int64(r.responseCode)
                    feed.bytes = ohosResponseBytes(r.result)
                    feed.contentType = headerValueOf(r.header, "content-type")
                case None => ()
            }
            feed.done = true
        }
    } catch (e: Exception) {
        // 同步抛：缺 ohos.permission.INTERNET、明文流量被策略拦、域名不可达等
        feed.failure = Some("${e}")
        feed.done = true
    }

    // 等回调：命令在 worker 线程上跑，这里阻塞不会冻界面（见文件头「为什么这里是阻塞的」）
    let budgetMs = CJ_HTTP_TIMEOUT_SECONDS * 1000
    var waited: Int64 = 0
    while (!feed.done && waited < budgetMs) {
        sleep(Duration.millisecond * OHOS_HTTP_POLL_MS)
        waited += OHOS_HTTP_POLL_MS
    }
    try {
        client.destroy()
    } catch (_: Exception) {
        // 释放失败不影响结论（这个 client 用完即弃，每条命令自己建一个）
    }

    if (let Some(msg) <- feed.failure) {
        eprintln("[cj-tauri] http transport failed (ohos): ${msg}")
        throw CommandException("http: request failed on HarmonyOS: ${msg}")
    }
    if (!feed.done) {
        eprintln("[cj-tauri] http transport timeout (ohos): ${waited}ms ${url}")
        throw CommandException("http: no response within ${waited}ms on HarmonyOS")
    }
    return (feed.status, feed.contentType, feed.bytes)
}

/** 非流式请求：与桌面侧同一契约（截断口径、Content-Type 取值都在这里对齐） */
@When[env == "ohos"]
public func httpTransportSend(method: String, url: String, host: String,
    headers: HashMap<String, String>, body: String): HttpReply {
    // host 只在建 TLS 时用得上（桌面侧写 SNI）；鸿蒙把 TLS 交给系统，按 URL 里的域名自动协商
    let _ = host
    let (status, ctype, bytes) = ohosRequest(method, url, headers, body)
    var truncated = false
    var cut = bytes.size
    if (cut > CJ_HTTP_MAX_BYTES) {
        cut = CJ_HTTP_MAX_BYTES
        truncated = true
    }
    return HttpReply(status, ctype, String.fromUtf8(bytes[0..cut]), truncated)
}

/**
 * 流式请求：**鸿蒙侧如实拒绝**，不假装成功
 *
 * 系统栈的 `request` 一次回整包（`requestInStream` + `dataReceive` 是 ArkTS 侧 API 18 起的形态，
 * 仓颉绑定上**没有验证过**，本机也没有鸿蒙工具链可核）——所以这里宁可当场报「不可用」，
 * 也不返回一个永远读到 EOF 的假句柄：那种失败在页面上表现为「模型一句话都不回」，
 * 没有凭证、极难排查（AGENTS §1 第 4 条：跑不起来就说跑不起来）。
 * 命令本身照常注册、白名单照常判定——不可用的是**流式这一种取法**，不是整条出网链路。
 */
@When[env == "ohos"]
public func httpTransportOpenStream(url: String, host: String,
    headers: HashMap<String, String>, body: String): HttpResponseStream {
    let _ = url
    let _ = host
    let _ = headers
    let _ = body
    throw CommandException(
        "http:postStream is not available on HarmonyOS: the system network stack returns the whole body at once (no incremental chunks). Use http:post instead.")
}
