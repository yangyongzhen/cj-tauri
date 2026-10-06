package movie_app

import std.collection.*
import std.env.*
import std.io.*
import std.sync.*
import stdx.encoding.base64.*
import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.net.tls.common.*
import cjTauri.*

/**
 * 后台影视接口基址（接口文档：<base>/static/docs/）
 *
 * 换自建后端不必改代码：设环境变量 CJ_MOVIE_API 覆盖即可（**不要带结尾斜杠**）。
 */
let DEFAULT_MOVIE_API_BASE = "http://49.235.52.102:8000"

/**
 * 单次请求的超时秒数
 *
 * 后台有一半接口是「现抓上游」的（影视解析 mvsource、剧集榜单 tvhot、合集 getmvmenus），
 * 上游不可达时它会卡在自己的 http 客户端超时上、然后回 503 + 纯文本 `Request Timeout`。
 * 不设超时的话前端那条 invoke 会一直转圈，用户看到的是「卡住」而不是「失败」。
 */
let MOVIE_API_TIMEOUT_SECONDS = 20

/**
 * 取封面时冒充的浏览器 UA
 *
 * 防盗链的图源（百度图片代理）会看 UA：不带浏览器 UA 时同样给 200 + 空 body。
 */
let MOVIE_BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0"

/** 单张封面的字节上限（超过就拒，避免一次 invoke 把几十 MB 塞进 IPC） */
let MOVIE_IMAGE_MAX_BYTES = 5 * 1024 * 1024

/** 后台接口基址（env CJ_MOVIE_API 优先） */
func movieApiBase(): String {
    if (let Some(v) <- getVariable("CJ_MOVIE_API")) {
        if (v.size > 0) {
            return v
        }
    }
    return DEFAULT_MOVIE_API_BASE
}

/**
 * 建一个 HTTP 客户端
 *
 * **每次调用现建一个**，不共享：命令是分发到 worker 线程上执行的（IpcHub.handleInvoke 的
 * 异步分发模型），跨线程共用一个 Client 的连接池属于没验证过的用法——这个示例宁可多花一次
 * 建连，也不要埋一个「偶发串包」的坑。
 */
func newMovieHttpClient(): Client {
    return ClientBuilder()
        /*
         * **必须显式配 TLS**：仓颉的 HTTP 客户端**不带默认 TLS**——发 https 请求会直接抛
         * `HttpException: TLS must be configured when HTTPS requests are sent.`
         * 实测踩坑：后台接口是 http，所以一直没暴露；封面是 https，54 次取图全灭。
         * `TlsClientConfig()` 默认用系统证书库校验（verifyMode = Default），
         * 不要图省事关校验——那等于把封面通道交给中间人。
         */
        .tlsConfig(TlsClientConfig())
        .readTimeout(Duration.second * MOVIE_API_TIMEOUT_SECONDS)
        .writeTimeout(Duration.second * MOVIE_API_TIMEOUT_SECONDS)
        .autoRedirect(true)
        .build()
}

/**
 * 榜单 kind → 后台路径（未收录的 kind 返回 None，由调用方报可读错误）
 *
 * 集中在这里而不是散进命令：后台路径基本是 `<kind>movie` 这个形状，只有 usmovie
 * 不收 city——查一张表比六处 match 好核对（也方便对着 /static/docs/ 的 swagger 复查）。
 */
func movieListPathOf(kind: String): Option<String> {
    match (kind) {
        case "hot" => return Some("/api/v1/hotmovie")
        case "new" => return Some("/api/v1/newmovie")
        case "soon" => return Some("/api/v1/soonmovie")
        case "top" => return Some("/api/v1/topmovie")
        case "week" => return Some("/api/v1/weekmovie")
        case "us" => return Some("/api/v1/usmovie")
        case _ => return None
    }
}

/**
 * 该榜单是否必填 `city`
 *
 * 只有 `/api/v1/hotmovie` 的请求体把 city 标成 required（swagger 原文）——其余榜单少这个字段会
 * 被 go-zero 判 400。多余的字段倒是不报错（encoding/json 忽略未知字段），但既然只有一家要，
 * 就只在它那条路上给，免得把「后台要什么」写模糊。
 */
func movieListNeedsCity(kind: String): Bool {
    return kind == "hot"
}

/**
 * 切源接口的路径：`/api/v1/mvsourceitem/<sid>?note=<note>[&aid=<aid>]`
 *
 * 参数白名单在命令层做（commands.cj 的 isSafeSourceNote / isSafeSourceAid）——放行集刻意收窄到
 * `[a-z0-9_-]`，所以这里直接拼、不需要百分号转义。
 * `aid` 为空时**整个参数省掉**：后台对「只有 note」的请求按集数最多的源解析（实测 uku 不带 aid
 * 回 194 集，带 aid=58817 回同名另一版本的 30 集）。单文件源（电影）的 aid 就是空串，走的就是这条。
 */
func movieSourceItemPath(sid: String, note: String, aid: String): String {
    if (aid.size == 0) {
        return "/api/v1/mvsourceitem/${sid}?note=${note}"
    }
    return "/api/v1/mvsourceitem/${sid}?note=${note}&aid=${aid}"
}

/**
 * 把响应体读成字节
 *
 * 不能用 `std.io.readToEnd(resp.body)`：那个泛型的约束是 `T <: InputStream & Seekable`，
 * 而 `HttpResponse.body` 的**静态类型只有 InputStream**——能 seek 的是它的实现类
 * （HttpRawBody / HttpNormalBody 都带 read+seek+length），静态类型上看不见，
 * 于是编译期报 "unable to infer generic argument"（实测）。
 * 所以这里自己按块读到 EOF：InputStream 只有 read(Array<Byte>) 这一个入口能用。
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
 * 封面地址分流：返回 `(请求用的 URL, 该图源要求的 Referer)`
 *
 * **为什么要白名单**：`movie:image` 的参数是页面可控的字符串，不校验的话这个命令就成了
 * 「让后端替你请求任意地址」的跳板（SSRF）。这里只放行后台确实会给的两个图源。
 */
func imageSourceOf(raw: String): (String, String) {
    if (raw.startsWith("https://image.baidu.com/search/down?url=")) {
        // 百度图片的下载代理：只认自家域名来的 Referer
        return (raw, "https://image.baidu.com/")
    }
    for (n in ["1", "2", "3", "4", "9", "10", "11"]) {
        if (raw.startsWith("https://img${n}.doubanio.com/")) {
            // 豆瓣图床：要豆瓣站的 Referer
            return (raw, "https://movie.douban.com/")
        }
    }
    throw CommandException("不在白名单内的封面地址：${raw}")
}

/**
 * 取封面并转成 `data:` URL 交给页面
 *
 * **为什么图片也要绕一趟仓颉侧**（这是本示例最实在的一条经验）：
 * 后台给的封面全是**防盗链**资源，实测（2026-10-05）：
 *   - `image.baidu.com/search/down?url=…`：带 `Referer: https://image.baidu.com/` → 26628 字节；
 *     换成别的 Referer（或不带）→ **HTTP 200 + `image/jpeg` + 0 字节**；
 *   - 豆瓣原图 `img*.doubanio.com`：要 `Referer: https://movie.douban.com/`，否则 418。
 * 失败还是「200 空 body」这种最坑的形状——前端只能从 `<img>` 的 onerror 知道它没成。
 *
 * 而**页面没法补救**：浏览器只允许用 Referrer-Policy 减少 Referer、不允许替换，
 * 何况页面是 `NavigateToString` 载入的（来源 opaque），根本发不出图源要的那个 Referer。
 * 于是 `cover`/`images`/`cast[].cover` 直连必然全灭——图片只能由仓颉侧取回来再交给页面。
 * 顺带这也把「前端只走 invoke」的契约贯彻到了图片上。
 */
func fetchImageDataUrl(raw: String): String {
    let (url, referer) = imageSourceOf(raw)
    let client = newMovieHttpClient()
    var status: Int64 = 0
    var data: Array<Byte> = []
    var ctype = ""
    var transportError: Option<String> = None
    try {
        let resp = client.send(HttpRequestBuilder()
            .url(url)
            .get()
            .header("Referer", referer)
            .header("User-Agent", MOVIE_BROWSER_UA)
            .header("Accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8")
            .build())
        status = Int64(resp.status)
        match (resp.headers.getFirst("Content-Type")) {
            // 头名大小写在 HTTP 里不敏感，但不同实现的取法不同；取不到就按 .jpg 兜底
            case Some(v) => ctype = v
            case None => ()
        }
        data = readBodyBytes(resp.body)
        resp.close()
    } catch (e: Exception) {
        transportError = Some("${e}")
    }
    client.close()

    if (let Some(msg) <- transportError) {
        eprintln("[movie] image ${raw} -> 连不上：${msg}")
        throw CommandException("取封面失败（连不上图源）：${msg}")
    }
    // 防盗链被拒就是「200 + 空 body」：这一条日志是排查封面不显示的关键凭证
    if (status != 200 || data.size == 0) {
        var typeNote = ""
        if (ctype.size > 0) {
            typeNote = " type=${ctype}"
        }
        eprintln("[movie] image ${raw} -> HTTP ${status} bytes=${data.size}${typeNote}")
        throw CommandException("封面取不到（HTTP ${status}，${data.size} 字节）——图源防盗链，或该图已下架")
    }
    if (data.size > MOVIE_IMAGE_MAX_BYTES) {
        throw CommandException("封面太大（${data.size} 字节，上限 ${MOVIE_IMAGE_MAX_BYTES}）")
    }

    // 按 Content-Type 定前缀；取不到就按 jpg 兜底（后台这两家的封面基本是 jpg）
    var mime = "image/jpeg"
    if (ctype.contains("png")) {
        mime = "image/png"
    } else if (ctype.contains("webp")) {
        mime = "image/webp"
    } else if (ctype.contains("gif")) {
        mime = "image/gif"
    }
    eprintln("[movie] image ${raw} -> 200 ok bytes=${data.size} ${mime}")
    return "data:${mime};base64," + toBase64String(data)
}

/**
 * 调后台接口：`body = None` 走 GET，`Some` 走 POST + JSON
 *
 * 返回**后台原始 JSON**，不做字段裁剪。理由是后台的失败分两级，裁剪会丢信息：
 *   1. 传输级失败（连不上 / 非 200 / 响应不是 JSON）→ 抛 CommandException，
 *      IpcHub 把 message 原样回投成前端 catch 到的 error；
 *   2. 业务级失败是 **HTTP 200 + `data: null` + `message: "403 Forbidden"`**
 *      （上游限流时这一批接口就是这个样子）——这种情况必须原样交给页面，
 *      页面才能把 message 显示成列表里的一行提示，而不是整页报错。
 *
 * 每次都往 stderr 打一行调用记录（`[movie]` 前缀）：本项目的端到端取证以 stderr 为准
 * （仓颉 println 的 stdout 有缓冲，进程被强杀时日志会丢），实机验证就读这几行。
 */
func movieApiCall(path: String, body: Option<JsonObject>): JsonValue {
    let url = movieApiBase() + path
    let client = newMovieHttpClient()
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
        eprintln("[movie] ${path} -> 连不上后台：${msg}")
        throw CommandException("连不上后台接口（${url}）：${msg}")
    }
    if (status != 200) {
        eprintln("[movie] ${path} -> HTTP ${status} body=${text}")
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
            eprintln("[movie] ${path} -> 200 ok bytes=${text.size}")
            return v
        case None =>
            eprintln("[movie] ${path} -> 200 但响应不是 JSON：${text}")
            throw CommandException("后台接口返回的不是 JSON（${path}）")
    }
}