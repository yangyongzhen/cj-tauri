package ohos_app_cangjie_entry

import kit.PerformanceAnalysisKit.Hilog
import ohos.net.http.*
import std.collection.*
import stdx.encoding.json.*
import cjTauri.*
import ohos_app_cangjie_entry.movielib.*

/*
 * 鸿蒙侧的封面命令（`movie:image` 的 ohos 实现）
 *
 * ## 为什么不直接用 movielib 里的 MovieImageCommand
 *
 * 那个实现走 `stdx.net.http` + `tlsConfig(TlsClientConfig())`，而**仓颉运行时在鸿蒙上装不了
 * TLS**：真机 hilog 里是
 *   `MUSL-LDSO: load libcrypto_openssl.z.so failed, namespace=moduleNs_default, errno=2`
 * （libssl_openssl.z.so 同样），即运行时按名字去 dlopen OpenSSL 3、设备上没有这个库。
 * 于是所有 https 请求当场失败——本示例的后台接口是 http（片单、搜索、播放全都正常），
 * 唯独封面是豆瓣/百度图床的 https，54 张全灭，页面回退成「首字色块」。
 *
 * 修法不是把 OpenSSL 塞进 hap（版本/符号对不上就再炸一次），而是**改用系统网络栈**
 * （`ohos.net.http`，NetworkKit）：TLS、证书链、代理都交给系统，应用侧只管发请求。
 * 平台差异落在这一层正好——两个实现同一个命令名、同一份白名单，前端契约不变。
 *
 * ## 为什么这里是阻塞的
 *
 * `HttpRequest.request` 只有回调形态（没有同步版本），而命令 handler 跑在框架的 worker
 * 线程上（不是 UI 线程），所以「发请求 → 等回调」用 sleep 轮询收口是安全的：冻不住界面。
 */

/** 等封面的上限（毫秒）：比后台接口的 20s 短一档，封面取不到不该让页面等更久 */
let OHOS_IMAGE_TIMEOUT_MS: Int64 = 15000

/** 轮询回调的间隔（毫秒） */
let OHOS_IMAGE_POLL_MS: Int64 = 20

/**
 * 回调与命令线程之间搬结果用的盒子
 *
 * 仓颉的 lambda **不能捕获可变的局部变量**（AGENTS §4），所以结果装在对象里、闭包只改字段。
 */
class OhosImageFeed {
    var done = false
    var failure: Option<String> = None
    var status: Int64 = 0
    var bytes: Array<Byte> = []
    var contentType: String = ""
}

/**
 * 从响应头里取 Content-Type（头名大小写不敏感，逐个小写比对）
 *
 * `HttpResponse.header` 是 `HashMap<String, String>`，键名保留服务端的大小写，
 * 所以不能只 `get("content-type")` 一次了事。
 */
func ohosHeaderOf(header: HashMap<String, String>, want: String): String {
    for ((k, v) in header) {
        if (k.toAsciiLower() == want) {
            return v
        }
    }
    return ""
}

/** 把响应体统一成字节：期望类型是 ArrayBuffer，个别实现仍可能回字符串 */
func ohosResponseBytes(data: HttpData): Array<Byte> {
    match (data) {
        case ArrayData(b) => return b
        case StringData(s) => return s.toArray()
        case _ => return Array<Byte>()
    }
}

/**
 * 用系统网络栈取一张图，返回 `(mime, 字节)`
 *
 * `url` / `referer` 由调用方按白名单给出（复用 movielib 的 `imageSourceOf`，判定只许一份）。
 */
func ohosFetchImage(url: String, referer: String): (String, Array<Byte>) {
    let feed = OhosImageFeed()
    let headers = HashMap<String, String>()
    headers["Referer"] = referer
    headers["User-Agent"] = MOVIE_BROWSER_UA
    headers["Accept"] = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"

    let options = HttpRequestOptions(
        method: RequestMethod.Get,
        expectDataType: HttpDataType.ArrayBuffer,
        header: headers,
        readTimeout: UInt32(OHOS_IMAGE_TIMEOUT_MS),
        connectTimeout: UInt32(OHOS_IMAGE_TIMEOUT_MS)
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
                    feed.bytes = ohosResponseBytes(r.result)
                    feed.contentType = ohosHeaderOf(r.header, "content-type")
                case None => ()
            }
            feed.done = true
        }
    } catch (e: Exception) {
        // 同步抛（缺 ohos.permission.INTERNET、明文流量被策略拦、域名不可达等）
        feed.failure = Some("${e}")
        feed.done = true
    }

    // 等回调：命令在 worker 线程上跑，这里阻塞不会冻界面
    var waited: Int64 = 0
    while (!feed.done && waited < OHOS_IMAGE_TIMEOUT_MS) {
        sleep(Duration.millisecond * OHOS_IMAGE_POLL_MS)
        waited += OHOS_IMAGE_POLL_MS
    }
    try {
        client.destroy()
    } catch (_: Exception) {
        // 释放失败不影响结论（进程里这个 client 用完即弃）
    }

    if (let Some(msg) <- feed.failure) {
        Hilog.warn(1, "CjMovie", "image transport failed: ${msg}")
        throw CommandException("取封面失败（系统网络栈）：${msg}")
    }
    if (!feed.done) {
        Hilog.warn(1, "CjMovie", "image timeout after ${waited}ms")
        throw CommandException("取封面超时（${waited}ms 内没有响应）")
    }
    if (feed.status != 200 || feed.bytes.size == 0) {
        // 防盗链被拒就是「200 + 空 body」，这条日志是排查封面不显示的关键凭证
        Hilog.warn(1, "CjMovie",
            "image http=${feed.status} bytes=${feed.bytes.size} type=${feed.contentType}")
        throw CommandException("封面取不到（HTTP ${feed.status}，${feed.bytes.size} 字节）——图源防盗链，或该图已下架")
    }
    if (feed.bytes.size > MOVIE_IMAGE_MAX_BYTES) {
        throw CommandException("封面太大（${feed.bytes.size} 字节，上限 ${MOVIE_IMAGE_MAX_BYTES}）")
    }

    var mime = "image/jpeg"
    if (feed.contentType.contains("png")) {
        mime = "image/png"
    } else if (feed.contentType.contains("webp")) {
        mime = "image/webp"
    } else if (feed.contentType.contains("gif")) {
        mime = "image/gif"
    }
    return (mime, feed.bytes)
}

/** base64 字符表按算术生成（不做常量数组，省一屏字面量） */
func ohosBase64Char(idx: Int64): UInt8 {
    if (idx < 26) {
        return UInt8(65 + idx)
    }
    if (idx < 52) {
        return UInt8(97 + idx - 26)
    }
    if (idx < 62) {
        return UInt8(48 + idx - 52)
    }
    if (idx == 62) {
        return UInt8(43)
    }
    return UInt8(47)
}

/** 字节 → base64（页面要的是 `data:` URL，框架侧没有现成的编码器） */
func ohosBytesToBase64(data: Array<Byte>): String {
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i + 3 <= data.size) {
        let n = (Int64(data[i]) << 16) | (Int64(data[i + 1]) << 8) | Int64(data[i + 2])
        out.add(ohosBase64Char((n >> 18) & 63))
        out.add(ohosBase64Char((n >> 12) & 63))
        out.add(ohosBase64Char((n >> 6) & 63))
        out.add(ohosBase64Char(n & 63))
        i += 3
    }
    let rest = data.size - i
    if (rest == 1) {
        let n = Int64(data[i]) << 16
        out.add(ohosBase64Char((n >> 18) & 63))
        out.add(ohosBase64Char((n >> 12) & 63))
        out.add(UInt8(61))
        out.add(UInt8(61))
    } else if (rest == 2) {
        let n = (Int64(data[i]) << 16) | (Int64(data[i + 1]) << 8)
        out.add(ohosBase64Char((n >> 18) & 63))
        out.add(ohosBase64Char((n >> 12) & 63))
        out.add(ohosBase64Char((n >> 6) & 63))
        out.add(UInt8(61))
    }
    return String.fromUtf8(out.toArray())
}

/** 从 invoke 参数里读字符串（与 movielib 的 argString 同形，那份不跨包可见） */
func ohosArgString(args: JsonObject, key: String, fallback: String): String {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return fallback
            }
        case None => return fallback
    }
}

/**
 * `movie:image` 的鸿蒙实现：`{url}` → `data:image/...;base64,...`
 *
 * 与 movielib 的 `MovieImageCommand` 同名同契约，差别只有取图通道（系统网络栈 vs stdx + TLS）。
 * 白名单、UA、体积上限全部复用 movielib 的常量与 `imageSourceOf`——安全判定只许一份。
 */
public class OhosMovieImageCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let raw = ohosArgString(args, "url", "")
        if (raw.size == 0) {
            throw CommandException("缺少封面地址")
        }
        let (url, referer) = imageSourceOf(raw)
        let (mime, bytes) = ohosFetchImage(url, referer)
        return JsonString("data:${mime};base64," + ohosBytesToBase64(bytes))
    }
}
