package ionic_music

import stdx.encoding.base64.*
import stdx.net.http.*
import cjTauri.*

// 鸿蒙侧的封面取图走系统网络栈（NetworkKit）：设备上装不了 OpenSSL，stdx 的 TLS 不可用。
// 这三个 import 只在鸿蒙编进来——桌面侧用了会是「未使用 import」的零警告红线。
@When[env == "ohos"]
import ohos.net.http.*

@When[env == "ohos"]
import std.collection.*

/**
 * 封面取回：`http(s) 图片地址 → data:image/…;base64,…`
 *
 * **为什么不把封面地址直接交给页面的 `<img src>`**（这是本示例最实在的一条经验，examples/movie 同样踩过）：
 * 后台给的封面**全是百度图片代理**（`image.baidu.com/search/down?url=…`），而该代理按 Referer 放行——
 * 实测（2026-10-08）：
 *   - 带 `Referer: https://image.baidu.com/` → 200 + 真图（149 706 / 709 326 字节）；
 *   - 换成别的 Referer 或不带 → **HTTP 200 + `image/jpeg` + 0 字节**。
 * 失败形状是「200 空 body」这种最坑的样子，而**页面侧无解**：浏览器只允许用 Referrer-Policy
 * *减少* Referer、不允许替换，何况本应用的页面是 `run(html)` 从字符串载入的（来源 opaque）。
 * 于是封面只能由仓颉侧带对 Referer 取回来，再用 data URL 交给页面；顺带把「前端只走 invoke」
 * 这条契约贯彻到了图片上。
 */

/** 单张封面的字节上限（超过就拒，避免一次 invoke 把几十 MB 塞进 IPC） */
let MUSIC_IMAGE_MAX_BYTES = 5 * 1024 * 1024

/**
 * 单张封面回投的 base64 字符数上限（超过就降档到 200px 重取）
 *
 * 来历（2026-11-14 实机）：鸿蒙回投走「页面 50ms pull → 原生 runJavaScript 推脚本」，
 * 单条脚本过大时页面收不到。同一台设备上 qpic 500px（base64 ~86KB）正常显示，
 * 网易 500px（~200KB）显示破图，而设备侧直接拉那张图是 200/150778 字节——
 * 网络、证书、资源都排除，只剩载荷大小。阈值取 120KB 留出余量。
 *
 * **只在鸿蒙生效**：桌面两平台是「原生主动 evaluateJavaScript / postMessage」，
 * 大载荷一切正常（同尺寸封面实测正常渲染），不该被这条限制连累降质。
 */
@When[env == "ohos"]
func imagePayloadLimitChars(): Int64 {
    return 120 * 1024
}

@When[env != "ohos"]
func imagePayloadLimitChars(): Int64 {
    return MUSIC_IMAGE_MAX_BYTES * 2   // 桌面不设额外上限（字节上限已有 MUSIC_IMAGE_MAX_BYTES 兜底）
}

/** 缩略尺寸的可用区间（页面可控的值一律夹进这一段再用）；`0` 表示「要原图」 */
let MUSIC_IMAGE_SIZE_MIN = 48
let MUSIC_IMAGE_SIZE_MAX = 1024

/** 把页面传来的尺寸夹进可用区间：<= 0 当原图，其余夹到 [MIN, MAX] */
func clampImageSize(v: Int64): Int64 {
    if (v <= 0) {
        return 0
    }
    if (v < MUSIC_IMAGE_SIZE_MIN) {
        return MUSIC_IMAGE_SIZE_MIN
    }
    if (v > MUSIC_IMAGE_SIZE_MAX) {
        return MUSIC_IMAGE_SIZE_MAX
    }
    return v
}

/**
 * 剥掉百度图片代理，拿到**最里层的真实图地址**
 *
 * 后台的封面基本都套着 `image.baidu.com/search/down?url=<真图>`，歌单封面甚至套两层
 * （`…down?url=https://image.baidu.com/search/down?url=…`）。按 `url=` 切开取最后一段，
 * 正好就是最里层那一层——不管套几层、也不管原串是不是代理地址（不是代理时切开只有一段，等于原样返回）。
 */
func coverInnerAddressOf(raw: String): String {
    let parts = raw.split("url=")
    if (parts.size == 0) {
        return raw
    }
    return parts[parts.size - 1]
}

/**
 * 取图计划：返回 `(实际请求的地址, 该图源要求的 Referer)`——在白名单之上再加一层「要不要缩略」
 *
 * **为什么值得单独做缩略**（2026-10-08 实测同一张网易封面）：
 *   - 走百度代理 / 直连取**原图**：709 326 字节；
 *   - 直连网易图床并带 `?param=200y200`：**4 194 字节**（`?param=500y500` 是 22 KB）。
 * 榜单一次 30 首，按原图就是 ~21 MB base64 灌进 DOM（还要 30 次跨线程取图），而列表里那个框只有 56 px。
 * 于是列表按 200 取、主视觉与「正在播放」那两块按 500 取。
 *
 * **只对网易图床这么做**，不做通用猜测：它的地址在代理串里是明文的，`?param=` 又是它自己的参数
 * （注意是 `y` 不是 `x`），而且直连比走百度代理少一跳——实测直连不带 Referer 照样 200。
 * 其它图源保持原样原尺寸：没实测过的图源，宁可大一点也不要猜错参数把图取空。
 */
func coverPlanOf(raw: String, size: Int64): (String, String) {
    let inner = coverInnerAddressOf(raw)
    if (size >= MUSIC_IMAGE_SIZE_MIN && inner.contains(".music.126.net/") && !inner.contains("?")) {
        return (inner + "?param=${size}y${size}", "")
    }
    return coverSourceOf(raw)
}

/**
 * 封面地址分流：返回 `(请求用的地址, 该图源要求的 Referer)`
 *
 * **为什么要白名单**：`music:image` 的参数是页面可控的字符串，不校验的话这个命令就成了
 * 「让后端替你请求任意地址」的跳板（SSRF）。这里只放行后台确实会给的三个图源；
 * Referer 为空串表示该图源不看 Referer（实测直连即可）。
 */
func coverSourceOf(raw: String): (String, String) {
    if (raw.startsWith("https://image.baidu.com/search/down?url=") ||
        raw.startsWith("http://image.baidu.com/search/down?url=")) {
        // 百度图片的下载代理：只认自家域名来的 Referer
        // 注意后台有时给的是**套两层**的代理地址（歌单封面就是
        // `…/down?url=https://image.baidu.com/search/down?url=…`），实测外层按整串取回照样 200。
        return (raw, "https://image.baidu.com/")
    }
    if (raw.contains(".music.126.net/")) {
        // 网易云图床：实测不带 Referer 也能取（149 706 字节）
        return (raw, "")
    }
    if (raw.startsWith("https://qpic.y.qq.com/") || raw.startsWith("http://qpic.y.qq.com/")) {
        // QQ 音乐封面：实测不带 Referer 也能取（64 835 字节）
        return (raw, "")
    }
    throw CommandException("不在白名单内的封面地址：${raw}")
}

/**
 * 一次取图尝试：返回 `(状态码, 字节, Content-Type, 传输层错误)`
 *
 * 单独抽出来是为了「按计划取的地址没成、再退回原地址」那条路能复用同一段取图代码
 * （两处各写一遍很容易改了一处忘另一处）。传输层失败不抛异常、也不打日志，
 * 由调用方按「这次是不是还有后路」决定要不要喊。
 */
/**
 * 封面诊断：桌面经 logd 写 stderr、鸿蒙经 logd 写 hilog（真机上 stderr 不可见，取证只能走 hilog）
 *
 * 只调 `logd` 一次即可——框架的 logd 在两个平台各走自己的出口（AGENTS §4：框架内别再直接 eprintln）。
 */
func coverLog(line: String): Unit {
    logd(line)
}

/* ===================== 桌面两平台：stdx.net.http + TLS ===================== */

@When[env != "ohos"]
func coverHttpGet(url: String, referer: String): (Int64, Array<Byte>, String, Option<String>) {
    let client = newMusicHttpClient()
    var status: Int64 = 0
    var data: Array<Byte> = []
    var ctype = ""
    var transportError: Option<String> = None
    try {
        var builder = HttpRequestBuilder()
            .url(url)
            .get()
            .header("User-Agent", MUSIC_BROWSER_UA)
            .header("Accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8")
        if (referer.size > 0) {
            builder = builder.header("Referer", referer)
        }
        let resp = client.send(builder.build())
        status = Int64(resp.status)
        match (resp.headers.getFirst("Content-Type")) {
            // 头名大小写在 HTTP 里不敏感，但不同实现的取法不同（**没有 get**，写成 get 会得到
            // 一条指向不明的 "enum pattern is not matched" 报错）；取不到就按 jpeg 兜底
            case Some(v) => ctype = v
            case None => ()
        }
        data = readBodyBytes(resp.body)
        resp.close()
    } catch (e: Exception) {
        transportError = Some("${e}")
    }
    client.close()
    return (status, data, ctype, transportError)
}

/* ===================== 鸿蒙：系统网络栈 ohos.net.http ===================== */

/*
 * 为什么鸿蒙不能用上面那份：仓颉运行时在设备上装不了 OpenSSL 3——真机 hilog 是
 *   MUSL-LDSO: load libcrypto_openssl.z.so failed, errno=2
 * （libssl_openssl.z.so 同样），即 stdx 的 TLS 按名字 dlopen、设备上没有这两个库；
 * 实测 stat /system/lib64{,/ndk}/ 均无。于是 **http 照通、https 全灭**：
 * `TlsException: Can not load openssl library or function CRYPTO_get_ex_new_index.`
 * 本示例的后台接口是 http（歌单/歌词都正常），唯独封面是百度代理的 https —— 全灭，
 * 页面显示成破图（2026-11-14 真机取证：[music] image https://image.baidu.com/... -> 连不上图源）。
 *
 * 修法与 ohos-movie 同款：改用系统网络栈（NetworkKit），TLS/证书链/代理交给 OS。
 * 平台差异只落在这一层——命令名、白名单、data URL 契约都不变。
 *
 * 阻塞是因为 `HttpRequest.request` 只有回调形态；命令跑在框架 worker 线程上，冻不住界面。
 */

/** 等封面的上限（毫秒）——只在鸿蒙分支用（桌面走 stdx 的阻塞客户端，不需要轮询预算） */
@When[env == "ohos"]
let OHOS_COVER_TIMEOUT_MS: Int64 = 15000

/** 轮询回调的间隔（毫秒），同上 */
@When[env == "ohos"]
let OHOS_COVER_POLL_MS: Int64 = 20

/** 回调与调用线程之间搬结果用的盒子（仓颉 lambda 不能捕获可变局部变量） */
@When[env == "ohos"]
class OhosCoverFeed {
    var done = false
    var failure: Option<String> = None
    var status: Int64 = 0
    var bytes: Array<Byte> = []
    var contentType: String = ""
}

/** 响应体统一成字节（期望 ArrayBuffer，个别实现对文本回字符串） */
@When[env == "ohos"]
func ohosCoverBytes(data: HttpData): Array<Byte> {
    match (data) {
        case ArrayData(b) => return b
        case StringData(s) => return s.toArray()
        case _ => return Array<Byte>()
    }
}

/** 取响应头（键名保留服务端大小写，逐个小写比对） */
@When[env == "ohos"]
func ohosCoverHeader(header: HashMap<String, String>, want: String): String {
    for ((k, v) in header) {
        if (k.toAsciiLower() == want) {
            return v
        }
    }
    return ""
}

@When[env == "ohos"]
func coverHttpGet(url: String, referer: String): (Int64, Array<Byte>, String, Option<String>) {
    let feed = OhosCoverFeed()
    let headers = HashMap<String, String>()
    headers["User-Agent"] = MUSIC_BROWSER_UA
    headers["Accept"] = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
    if (referer.size > 0) {
        headers["Referer"] = referer
    }
    let options = HttpRequestOptions(
        method: RequestMethod.Get,
        expectDataType: HttpDataType.ArrayBuffer,
        header: headers,
        readTimeout: UInt32(OHOS_COVER_TIMEOUT_MS),
        connectTimeout: UInt32(OHOS_COVER_TIMEOUT_MS)
    )
    let client = createHttp()
    try {
        client.request(url, options) { err, resp =>
            match (err) {
                case Some(e) => feed.failure = Some("${e}")
                case None => ()
            }
            match (resp) {
                case Some(r) =>
                    feed.status = Int64(r.responseCode)
                    feed.bytes = ohosCoverBytes(r.result)
                    feed.contentType = ohosCoverHeader(r.header, "content-type")
                case None => ()
            }
            feed.done = true
        }
    } catch (e: Exception) {
        feed.failure = Some("${e}")
        feed.done = true
    }
    var waited: Int64 = 0
    while (!feed.done && waited < OHOS_COVER_TIMEOUT_MS) {
        sleep(Duration.millisecond * OHOS_COVER_POLL_MS)
        waited += OHOS_COVER_POLL_MS
    }
    try {
        client.destroy()
    } catch (_: Exception) {
        // 释放失败不影响结论（这个 client 用完即弃）
    }
    if (!feed.done) {
        return (0, Array<Byte>(), "", Some("系统网络栈超时（${OHOS_COVER_TIMEOUT_MS}ms 内没有响应）"))
    }
    return (feed.status, feed.bytes, feed.contentType, feed.failure)
}

/**
 * 取封面并转成 `data:` URL
 *
 * `size` 是页面要的边长（`0` = 原图）；能不能真的变小见 coverPlanOf 的说明。
 * 计划里的地址没取到时**退回原地址原尺寸重试一次**——缩略改造只对实测过的那一家图源做，
 * 上游哪天调整了就靠这条后路兜底：代价只是这一张图大一点，总好过封面直接空掉。
 *
 * 失败一律抛 CommandException（页面把它显示成占位图）：封面取不回不该让整页报错，
 * 但也不能静默——每次都往 stderr 打一行 `[music] image …`，实机验证读这几行。
 */
func fetchCoverDataUrl(raw: String, size: Int64): String {
    let (planUrl, planRef) = coverPlanOf(raw, size)
    let first = coverHttpGet(planUrl, planRef)
    var status = first[0]
    var data = first[1]
    var ctype = first[2]
    var transportError = first[3]
    var usedUrl = planUrl
    var usedSize = size

    if ((status != 200 || data.size == 0) && planUrl != raw) {
        coverLog("[music] image 缩略没成（HTTP ${status} bytes=${data.size}）→ 回退原图原尺寸重试")
        let (origUrl, origRef) = coverSourceOf(raw)
        let second = coverHttpGet(origUrl, origRef)
        status = second[0]
        data = second[1]
        ctype = second[2]
        transportError = second[3]
        usedUrl = origUrl
        usedSize = 0
    }

    if (let Some(msg) <- transportError) {
        coverLog("[music] image ${usedUrl} -> 连不上图源：${msg}")
        throw CommandException("取封面失败（连不上图源）：${msg}")
    }
    // 防盗链被拒就是「200 + 空 body」：这一条日志是排查封面不显示的关键凭证
    if (status != 200 || data.size == 0) {
        var typeNote = ""
        if (ctype.size > 0) {
            typeNote = " type=${ctype}"
        }
        coverLog("[music] image ${usedUrl} -> HTTP ${status} bytes=${data.size}${typeNote}")
        throw CommandException("封面取不到（HTTP ${status}，${data.size} 字节）——图源防盗链，或该图已下架")
    }
    if (data.size > MUSIC_IMAGE_MAX_BYTES) {
        throw CommandException("封面太大（${data.size} 字节，上限 ${MUSIC_IMAGE_MAX_BYTES}）")
    }

    // 按 Content-Type 定前缀；取不到就按 jpeg 兜底（后台这两家图床基本是 jpg）
    var mime = "image/jpeg"
    if (ctype.contains("png")) {
        mime = "image/png"
    } else if (ctype.contains("webp")) {
        mime = "image/webp"
    } else if (ctype.contains("gif")) {
        mime = "image/gif"
    }
    var sizeNote = "原图"
    if (usedSize > 0) {
        sizeNote = "${usedSize}px"
    }
    var b64 = toBase64String(data)
    // 回投载荷上限：鸿蒙「页面 50ms pull → 原生 runJavaScript 推回」这条通道，单条脚本
    // 过大时页面收不到（实测同一台设备：qpic 500px 封面 base64 ~86KB 正常显示，网易 500px
    // base64 ~200KB 显示成破图，而设备侧直接拉该图是 200/150778 字节——网络与资源都正常）。
    // 因此超过阈值就**降档到 200px 重取一次**：覆盖卡片只有百来像素，宁可小一点也不要空图。
    if (b64.size > imagePayloadLimitChars() && size > MUSIC_IMAGE_SIZE_MIN * 4) {
        let (smallUrl, smallRef) = coverPlanOf(raw, 200)
        let third = coverHttpGet(smallUrl, smallRef)
        if (third[0] == 200 && third[1].size > 0) {
            coverLog("[music] image 载荷 ${b64.size} 字符过大 → 降档 200px 重取（${third[1].size} 字节）")
            data = third[1]
            ctype = third[2]
            usedUrl = smallUrl
            usedSize = 200
            sizeNote = "200px(降档)"
            b64 = toBase64String(data)
            var mime2 = "image/jpeg"
            if (ctype.contains("png")) {
                mime2 = "image/png"
            } else if (ctype.contains("webp")) {
                mime2 = "image/webp"
            } else if (ctype.contains("gif")) {
                mime2 = "image/gif"
            }
            coverLog("[music] image ${usedUrl} -> 200 ok bytes=${data.size} ${mime2} (${sizeNote})")
            return "data:${mime2};base64," + b64
        }
    }
    coverLog("[music] image ${usedUrl} -> 200 ok bytes=${data.size} ${mime} (${sizeNote})")
    return "data:${mime};base64," + b64
}
