package cjTauri.plugins.http

import std.collection.*
import stdx.encoding.json.*

/*
 * http 插件的**传输层契约**（两平台共用，本文件不含任何平台代码）
 *
 * 分工（照 AGENTS §2 的平台差异纪律）：
 * - 本文件：回给页面的形状、流式句柄接口、**请求头解析与安全过滤**——判定只此一份；
 * - `http_desktop.cj`（@When[env != "ohos"]）：stdx.net.http + 显式 TLS；
 * - `http_ohos.cj`（@When[env == "ohos"]）：系统网络栈 ohos.net.http。
 *
 * 为什么值得抽这一层：仓颉运行时在鸿蒙上装不了 OpenSSL 3（真机
 * `MUSL-LDSO: load libcrypto_openssl.z.so failed … errno=2`），stdx 的 TLS 从第一步就不可用，
 * 于是 `http:get` 在鸿蒙上**必然是 https 全灭、http 照旧**——这种「半死」状态最难排查。
 * 换系统栈之后命令名、入参、返回值、白名单判定都不变，前端契约一行都不用改。
 */

/**
 * 一次出网请求的结果（**两平台同一形状**）
 *
 * 回给页面的是 `{status, contentType, body, truncated}` 四项，与 `httpReplyJson` 一一对应。
 * `truncated` 表示「撞上 `CJ_HTTP_MAX_BYTES` 上限被截断」，不是出错。
 */
public class HttpReply {
    public let status: Int64
    public let contentType: String
    public let body: String
    public let truncated: Bool

    public init(status: Int64, contentType: String, body: String, truncated: Bool) {
        this.status = status
        this.contentType = contentType
        this.body = body
        this.truncated = truncated
    }
}

/** `HttpReply` → 命令返回值（两边各拼一次迟早会漂字段名，所以收在一处） */
public func httpReplyJson(reply: HttpReply): JsonValue {
    let obj = JsonObject()
    obj.put("status", JsonInt(reply.status))
    obj.put("contentType", JsonString(reply.contentType))
    obj.put("body", JsonString(reply.body))
    obj.put("truncated", JsonBool(reply.truncated))
    return obj
}

/**
 * 流式响应句柄：把「边收边发」收敛成 read / close 两步
 *
 * 桌面由 stdx 的响应体包装（连接与响应都归它持有，close 一并释放）；**没有流式能力的平台
 * 在构造处如实抛错**——返回一个假句柄假装成功是不可接受的（AGENTS §1 第 4 条：
 * 跑不起来就说跑不起来）。
 *
 * 句柄只被 `http:postStream` 的那条命令线程用，**不做跨线程共享**（与 stdx 响应的
 * 单线程语义一致）。
 */
public interface HttpResponseStream {
    func status(): Int64
    func contentType(): String
    /** 读一块进 buf，返回字节数；0 表示 EOF */
    func read(buf: Array<Byte>): Int64
    func close(): Unit
}

/**
 * 解析页面给的 `headers` 对象（可选）→ 请求头表（键已小写化）
 *
 * 这是**安全判定**，不是格式转换，所以只写一份：条数与单条长度有上限，且
 * **Host / Content-Length 一律剔除**——前者能改写白名单判过的目标（白名单判的是 URL 里的
 * host），后者由库自己算，页面写进来的值与实际发出的一样才不误导。
 * 非字符串值直接跳过（不做隐式转换：`{"X": 1}` 该被忽略，不是变成 "1"）。
 */
public func parsePageHeaders(args: JsonObject): HashMap<String, String> {
    let out = HashMap<String, String>()
    let v = match (args.get("headers")) {
        case Some(h) => h
        case None => return out
    }
    // JsonKind 没有 ==（AGENTS §4）：枚举比较只能走 match
    let isObject = match (v.kind()) {
        case JsonKind.JsObject => true
        case _ => false
    }
    if (!isObject) {
        return out
    }
    var count: Int64 = 0
    // 遍历用 getFields()（JsonObject 不是按索引取的容器，store 插件同款先例）
    for ((name0, value) in v.asObject().getFields()) {
        if (count >= CJ_HTTP_MAX_HEADERS) {
            break
        }
        let name = name0.toAsciiLower()
        if (name == "host" || name == "content-length") {
            continue
        }
        let isString = match (value.kind()) {
            case JsonKind.JsString => true
            case _ => false
        }
        if (!isString) {
            continue
        }
        let hval = value.asString().getValue()
        if (hval.size <= CJ_HTTP_MAX_HEADER_VALUE) {
            out[name] = hval
            count++
        }
    }
    return out
}

/**
 * 从响应头里取 Content-Type（同 Y 头名的**大小写不敏感**取值）
 *
 * 桌面侧 stdx 用 `headers.getFirst`（且**没有 get**，AGENTS §4）；鸿蒙侧 `HttpResponse.header`
 * 是 `HashMap<String, String>` 且键保留服务端大小写，只能逐个小写比对。
 * 两平台都要「按名字取头」这一件事，所以收成一个只吃表的纯函数，谁都能用。
 */
public func headerValueOf(header: HashMap<String, String>, want: String): String {
    let lower = want.toAsciiLower()
    for ((k, v) in header) {
        if (k.toAsciiLower() == lower) {
            return v
        }
    }
    return ""
}
