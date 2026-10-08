package music_app

import std.collection.*
import std.env.*
import std.io.*
import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.net.tls.common.*
import cjTauri.*

/**
 * 后台音乐接口的传输层
 *
 * 接口文档：<base>/static/docs/（swagger 原文在 <base>/static/docs/swagger/imovie.json）。
 * 本文件只管「怎么说话」——路径与请求体的形状在 commands.cj 里定，封面与歌词的加工在
 * cover.cj / lrc.cj 里。
 */

/**
 * 后台接口基址
 *
 * 与 examples/movie 是同一台后台（爱影家 / 知乎日报 / 爱音乐三个 app 共用一个 go-zero 服务）。
 * 换自建后端不必改代码：设环境变量 CJ_MUSIC_API 覆盖（**不要带结尾斜杠**）。
 */
let DEFAULT_MUSIC_API_BASE = "http://49.235.52.102:8000"

/**
 * 单次请求的超时秒数
 *
 * 与 examples/movie 同口径：后台有几个接口是「现抓上游」的（音乐榜单要现抓网易云歌单），
 * 上游不顺时它会卡在自己的 http 客户端上再回 400/503。不设超时的话，前端那条 invoke
 * 会一直转圈，用户看到的是「卡住」而不是「失败」。
 */
let MUSIC_API_TIMEOUT_SECONDS = 20

/**
 * 取封面时冒充的浏览器 UA
 *
 * 封面走的是百度图片代理（`image.baidu.com/search/down?url=…`），实测它同时看 Referer 与 UA：
 * 少任何一个都会回 **HTTP 200 + 空 body**（不是 4xx），详见 cover.cj。
 */
let MUSIC_BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0"

/** 后台接口基址（env CJ_MUSIC_API 优先） */
func musicApiBase(): String {
    if (let Some(v) <- getVariable("CJ_MUSIC_API")) {
        if (v.size > 0) {
            return v
        }
    }
    return DEFAULT_MUSIC_API_BASE
}

/**
 * 建一个 HTTP 客户端
 *
 * 与 examples/movie 同样的取舍：**每次调用现建一个、不共享**。命令是分发到 worker 线程上执行的
 * （IpcHub.handleInvoke 的异步分发模型），跨线程共用一个 Client 的连接池属于没验证过的用法——
 * 这个示例宁可多花一次建连，也不要埋一个「偶发串包」的坑。
 */
func newMusicHttpClient(): Client {
    return ClientBuilder()
        /*
         * **必须显式配 TLS**：仓颉的 HTTP 客户端**不带默认 TLS**——发 https 请求会直接抛
         * `HttpException: TLS must be configured when HTTPS requests are sent.`
         * 后台接口本身是 http，但封面是 https（百度图片代理 / 网易云图床），
         * 这条就是 examples/movie 54 次取图全灭买来的教训（AGENTS §4）。
         */
        .tlsConfig(TlsClientConfig())
        .readTimeout(Duration.second * MUSIC_API_TIMEOUT_SECONDS)
        .writeTimeout(Duration.second * MUSIC_API_TIMEOUT_SECONDS)
        .autoRedirect(true)
        .build()
}

/**
 * 把响应体读成字节
 *
 * 不能用 `std.io.readToEnd(resp.body)`：那个泛型的约束是 `T <: InputStream & Seekable`，
 * 而 `HttpResponse.body` 的**静态类型只有 InputStream**（能 seek 的是它的实现类），
 * 静态类型上看不见 → 编译期报 "unable to infer generic argument"（实测，见 AGENTS §4）。
 * 所以自己按块读到 EOF：InputStream 只有 `read(Array<Byte>)` 这一个入口能用。
 */
func readBodyBytes(body: InputStream): Array<Byte> {
    let buf = ByteBuffer()
    let chunk = Array<Byte>(8192, repeat: 0)
    var n = body.read(chunk)
    while (n > 0) {
        if (n == chunk.size) {
            buf.write(chunk)
        } else {
            buf.write(chunk[0..n])
        }
        n = body.read(chunk)
    }
    return buf.bytes()
}

/** 把响应体读成字符串 */
func readBodyText(body: InputStream): String {
    return String.fromUtf8(readBodyBytes(body))
}

/**
 * 调后台接口：`body = None` 走 GET，`Some` 走 POST + JSON
 *
 * 返回**后台原始 JSON**，不做字段裁剪。后台的失败分两级，裁剪会丢信息：
 *   1. 传输级失败（连不上 / 非 200 / 响应不是 JSON）→ 抛 CommandException，
 *      IpcHub 把 message 原样回投成前端 catch 到的 error；
 *   2. 业务级失败是 **HTTP 200 + `code: 400` + `message` + `data: null`**
 *      （`musicmenus` 的 kind 不存在时实测就是这个形状：`mongo: no documents in result`；
 *      `musicsearch` 关键词没结果则是 `code: 0` + 空 `data`）——
 *      必须原样交给页面，页面才能把 message 显示成列表里的一行提示，而不是整页报错。
 *
 * 每次都往 stderr 打一行调用记录（`[music]` 前缀）：本项目的端到端取证以 stderr 为准
 * （仓颉 println 的 stdout 有缓冲，进程被强杀时日志会丢）。
 */
func musicApiCall(path: String, body: Option<JsonObject>): JsonValue {
    let url = musicApiBase() + path
    let client = newMusicHttpClient()
    var status: Int64 = 0
    var text = ""
    var transportError: Option<String> = None
    try {
        var builder = HttpRequestBuilder().url(url)
        match (body) {
            case Some(b) =>
                // Content-Type 必须显式给：后台是 go-zero，缺了它会直接回 400
                builder = builder.post().header("Content-Type", "application/json").body(b.toJsonString())
            case None =>
                builder = builder.get()
        }
        let resp = client.send(builder.build())
        status = Int64(resp.status)
        text = readBodyText(resp.body)
        resp.close()
    } catch (e: Exception) {
        transportError = Some("${e}")
    }
    client.close()

    if (let Some(msg) <- transportError) {
        eprintln("[music] ${path} -> 连不上后台：${msg}")
        throw CommandException("连不上后台接口（${url}）：${msg}")
    }
    if (status != 200) {
        eprintln("[music] ${path} -> HTTP ${status} body=${text}")
        throw CommandException("后台接口返回 HTTP ${status}（${path}）")
    }

    var parsed: Option<JsonValue> = None
    try {
        parsed = Some(JsonValue.fromStr(text))
    } catch (e: Exception) {
        parsed = None
    }
    match (parsed) {
        case Some(v) =>
            eprintln("[music] ${path} -> 200 ok bytes=${text.size}")
            return v
        case None =>
            eprintln("[music] ${path} -> 200 但响应不是 JSON：${text}")
            throw CommandException("后台接口返回的不是 JSON（${path}）")
    }
}
