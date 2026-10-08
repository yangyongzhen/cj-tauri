package music_app

import stdx.encoding.base64.*
import stdx.net.http.*
import cjTauri.*

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
        eprintln("[music] image 缩略没成（HTTP ${status} bytes=${data.size}）→ 回退原图原尺寸重试")
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
        eprintln("[music] image ${usedUrl} -> 连不上图源：${msg}")
        throw CommandException("取封面失败（连不上图源）：${msg}")
    }
    // 防盗链被拒就是「200 + 空 body」：这一条日志是排查封面不显示的关键凭证
    if (status != 200 || data.size == 0) {
        var typeNote = ""
        if (ctype.size > 0) {
            typeNote = " type=${ctype}"
        }
        eprintln("[music] image ${usedUrl} -> HTTP ${status} bytes=${data.size}${typeNote}")
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
    eprintln("[music] image ${usedUrl} -> 200 ok bytes=${data.size} ${mime} (${sizeNote})")
    return "data:${mime};base64," + toBase64String(data)
}
