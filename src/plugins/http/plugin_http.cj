package cjTauri.plugins.http

import cjTauri.*

import std.collection.*
import std.io.*
import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*

/** 单次响应体上限：8 MiB（LLM 非流式回复通常远小于它；够装一份大 README） */
public let CJ_HTTP_MAX_BYTES: Int64 = 8 * 1024 * 1024

/** 请求超时（读写同一预算）：ClientBuilder 没有 connectTimeout，目标不可达会卡在
 * TCP connect 上——超时预算按「整体别太久」给，长挂由前端超时/取消兜 */
public let CJ_HTTP_TIMEOUT_SECONDS: Int64 = 60

/** 页面可带的请求头上限（条数与单条长度）：防用一堆超长头把内存撑爆 */
public let CJ_HTTP_MAX_HEADERS: Int64 = 16
public let CJ_HTTP_MAX_HEADER_VALUE: Int64 = 4096

/**
 * 官方插件 http：**页面可控的出网口**（RFC-003 HTTP 白名单收口）
 *
 * 命令：http:get（{url}）/ http:post（{url, body, headers?}）/ http:delete（{url, body}），返回
 * { status, contentType, body, truncated }；失败抛 CommandException（业务错误）。
 * 权限：**不自动放行**——"permissions": ["http:default"] 或在 commands 里明文写。
 *
 * 安全语义（与 fs 的路径 scope 同构，判定逻辑复用共享层 scopeAllows/globMatch）：
 * - **主机白名单**：清单写 "scopes": { "http": { "allow": ["api.deepseek.com"] } }。
 *   allow 必须显式命中、先 deny 后 allow；**没写 scopes.http = 一律拒绝**并打一行 stderr
 *   （与 fs「空 allow = 全拒」同方向：出网是高危面，不做「没写就放行」的旧行为）。
 * - **只认 host，不认端口**：匹配目标是 URL 里的 host（小写化）；端口不参与匹配——
 *   白名单声明「我信这个主机」，同一台主机的端口不会让信任变多。
 * - **禁自动重定向**（autoRedirect(false)）：3xx 原样回给页面——重定向到别的主机
 *   不会替页面**追出去**（白名单只判第一跳；要跟就由页面显式再发一次、再过一遍白名单）。
 * - Host / Content-Length 头不许页面自带（前者能改写白名单判过的目标，后者由库自己算）。
 *
 * TLS：显式 tlsConfig(TlsClientConfig())——仓颉 HTTP 客户端**不带默认 TLS**，
 * 不配的话 https 直接抛 HttpException（AGENTS §4，movie 54 次取图全灭的教训）。
 *
 * 性能口径（为什么**每个请求新建 Client**而不是共享一个）：
 * - 最大的性能收益本来就在**流式**：一次 LLM 对话只有一次请求，而这条流要挂几十秒——
 *   建连 + TLS 握手（约百毫秒量级）摊在整条流里可忽略；频繁短请求不是本插件的靶场景。
 * - 跨线程共享 Client 的连接池是否线程安全，本仓**没有验证过**（music 示例宁可每次
 *   建连也不埋「偶发串包」的坑，见 examples/music/src/api.cj 的注释）；命令 worker 是
 *   并发的，用锁包共享 Client 会把并发请求串行化，反而伤多窗口/多会话场景。
 * - 真到了「高频短请求」成为瓶颈那天，先实测 stdx 连接池的线程安全再改共享——
 *   那是一次有判据的优化，不是现在凭感觉做。
 */
public class HttpPlugin <: Plugin {
    public init() {}

    public func name(): String {
        return "http"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        // 键写**短名**：前缀由框架补（写全名会得到 http:http:get，且所有命令都成未注册）
        m.add("get", HttpCommands())
        m.add("post", HttpCommands())
        m.add("delete", HttpCommands())
        m.add("postStream", HttpCommands())
        return m
    }

    /** 命名权限集（v1.1）：default = GET + POST + POST 流式 */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let all = ArrayList<String>()
        all.add("get")
        all.add("post")
        all.add("delete")
        all.add("postStream")
        m.add("default", all)
        return m
    }

    /** 流式命令推事件：每个 body 块经 http:chunk 回投（应用要在清单 events 里放行）。
     * 这里写**短名**——框架自动补「<插件名>:」前缀，写全名会得到 http:http:chunk（实测）。 */
    public func events(): ArrayList<String> {
        let ev = ArrayList<String>()
        ev.add("chunk")
        return ev
    }

    /** 吃 scope：主机白名单的判定在清单 scopes.http（没写 = 全拒，见类注释） */
    public func scopeAware(): Bool {
        return true
    }
}

/** http 命令处理器：get 收 {url}，post / delete 收 {url, body, headers?}（delete 的体同样是 JSON 文本） */
public class HttpCommands <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "http:get" => return this.fetch("GET", args, ipc)
            case "http:post" => return this.fetch("POST", args, ipc)
            case "http:delete" => return this.fetch("DELETE", args, ipc)
            case "http:postStream" => return this.fetchStream(args, ipc)
            case _ => throw CommandException("unknown http command: ${cmd}")
        }
    }

    /**
     * 流式 POST（SSE）：与 doFetch 同一套白名单/请求头判定，差别只在**读响应体**——
     * 按块读、每读一块就把增量经事件通道回投（emitLatest：同一帧内多条只保最新，
     * 渲染层本来就该按「最新累计文本」画，高频 delta 不必每条都到）。
     *
     * 事件 payload：{ status, contentType, delta, received, done, truncated }。
     * delta 是**本轮新增**的文本；UTF-8 多字节被块边界切开时，不完整的那几字节
     * 留到下一块拼齐再发（按 lead byte 回扫补齐边界，见 emitUtf8Chunks）。
     * 结束（EOF / 超限）后发 done=true 的最后一条，命令再返回总字节数。
     */
    private func fetchStream(args: JsonObject, ipc: IpcContext): JsonValue {
        let url = this.requireString(args, "url")
        let host = match (httpHostOf(url)) {
            case Some(h) => h
            case None => throw CommandException("http: host is outside the authorized scope")
        }
        this.checkHostScope(url, host, ipc)

        var builder = HttpRequestBuilder().url(url).post().body(this.requireString(args, "body"))
        builder = builder.header("Accept", "text/event-stream")
        builder = this.applyPageHeaders(builder, args)

        let client = ClientBuilder()
            .tlsConfig(TlsClientConfig())
            .autoRedirect(false)
            .readTimeout(Duration.second * CJ_HTTP_TIMEOUT_SECONDS)
            .writeTimeout(Duration.second * CJ_HTTP_TIMEOUT_SECONDS)
            .build()
        var status: Int64 = 0
        var ctype = ""
        var total: Int64 = 0
        var truncated = false
        try {
            let resp = client.send(builder.build())
            status = Int64(resp.status)
            match (resp.headers.getFirst("Content-Type")) {
                case Some(v) => ctype = v
                case None => ()
            }
            // carry：上一块末尾不完整的 UTF-8 序列（最多 3 字节），拼到下一块开头
            let chunk = Array<Byte>(8192, repeat: 0)
            let pending = ArrayList<Byte>()
            var n = resp.body.read(chunk)
            while (n > 0) {
                if (total + n > CJ_HTTP_MAX_BYTES) {
                    truncated = true
                    break
                }
                for (i in 0..n) {
                    pending.add(chunk[i])
                }
                total += n
                n = resp.body.read(chunk)
                // 发走所有完整 UTF-8 序列，尾巴（不完整的那几字节）留在 pending。
                // 必须 emit（每条都到）而不是 emitLatest：后者按事件名「同帧只保最新」，
                // 会把中间 delta 连同数据块一起覆盖掉——实测 chunks 数时好时坏、
                // 前端拼文本缺字；对话流的语义是每一块都到达，不合并。
                let delta = this.takeCompleteUtf8(pending)
                if (delta.size > 0) {
                    ipc.emit("http:chunk", this.chunkPayload(status, ctype, delta, total, false, false))
                }
            }
            // 收尾：流在汉字中间被掐断时，pending 里剩下的是补不齐的不完整序列（最多 3 字节）。
            // 这里**不能**直接 fromUtf8：它对非法序列抛 IllegalArgumentException，一抛就把整条
            // 流式命令 reject 掉——页面显示「请求失败」，而正文其实早就收完了。丢这几个字节更诚实，
            // 但要把丢弃这件事留一行 stderr（别让失败无声）。
            if (pending.size > 0) {
                var tail = ""
                try {
                    tail = String.fromUtf8(pending.toArray())
                } catch (e: Exception) {
                    eprintln("[cj-tauri] http:postStream 尾部 ${pending.size} 字节不是合法 UTF-8（流被掐断），已丢弃")
                }
                ipc.emit("http:chunk", this.chunkPayload(status, ctype, tail, total, true, truncated))
            } else {
                ipc.emit("http:chunk", this.chunkPayload(status, ctype, "", total, true, truncated))
            }
            resp.close()
        } finally {
            client.close()
        }
        let obj = JsonObject()
        obj.put("status", JsonInt(status))
        obj.put("contentType", JsonString(ctype))
        obj.put("received", JsonInt(total))
        obj.put("truncated", JsonBool(truncated))
        return obj
    }

    /**
     * 从 pending 里取走「完整的 UTF-8 序列」并转文本；不完整的尾巴留在原地。
     * `public` 是为了让单测可见（`cjTauri.tests` 是子包，跨包只认 public）：
     * 这是「少移 1 字节」那类坑的唯一判据点，用例在 `src/tests/plugin_http_test.cj`。
     */
    public func takeCompleteUtf8(pending: ArrayList<Byte>): String {
        if (pending.size == 0) {
            return ""
        }
        var keep: Int64 = 0
        // 回扫最多 3 字节找 lead byte（110xxxxx/1110xxxx/11110xxx），判序列是否齐
        let start = if (pending.size > 3) {
            pending.size - 3
        } else {
            0
        }
        var i = pending.size - 1
        while (i >= start) {
            // ArrayList.get 返回 Option<UInt8>（下标在界内才取值，这里恒在界内）
            let b = pending.get(i).getOrThrow()
            if (b < 0x80u8) {
                keep = 0
                break
            }
            if ((b & 0xC0u8) != 0x80u8) {
                // lead byte：判这串还缺几字节
                let need: Int64 = if (b >= 0xF0u8) {
                    3
                } else if (b >= 0xE0u8) {
                    2
                } else {
                    1
                }
                let have = pending.size - i
                keep = if (have < need + 1) {
                    have
                } else {
                    0
                }
                break
            }
            i--
        }
        let cut = pending.size - keep
        if (cut <= 0) {
            return ""
        }
        let out = String.fromUtf8(pending.toArray()[0..cut])
        // 移除已发走的部分（ArrayList.remove 收 Range）。Range 在本机工具链上是**右开**的
        // （实测：a[0..3] 取 3 个、remove(0..2) 移 2 个），所以这里必须写 0..cut。
        // 写成 0..(cut-1) 会少移 1 字节：上一个序列的末字节留在 pending 里，下一轮拼出来的
        // 字节序列非法，fromUtf8 当场抛 IllegalArgumentException，整条流式命令变成
        // 「请求失败」（2026-10-16 实机：command failed (http:postStream): Invalid utf8 byte sequence.
        // 且中文长回复才偶发——ASCII 结尾的块少移那个字节仍是合法 UTF-8，所以以前看不太出来）。
        pending.remove(0..cut)
        return out
    }

    private func chunkPayload(status: Int64, ctype: String, delta: String, received: Int64, done: Bool, truncated: Bool): JsonObject {
        let obj = JsonObject()
        obj.put("status", JsonInt(status))
        obj.put("contentType", JsonString(ctype))
        obj.put("delta", JsonString(delta))
        obj.put("received", JsonInt(received))
        obj.put("done", JsonBool(done))
        obj.put("truncated", JsonBool(truncated))
        return obj
    }

    private func fetch(method: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let url = this.requireString(args, "url")
        let host = match (httpHostOf(url)) {
            case Some(h) => h
            // 解析不出 host / 协议不是 http(s)：按白名单未命中处理（不透露解析细节）
            case None => throw CommandException("http: host is outside the authorized scope")
        }
        this.checkHostScope(url, host, ipc)
        return this.doFetch(method, url, args)
    }

    /** 白名单过后的真实请求：与判定分离，让 match 分支保持「单表达式」的形状
     * （仓颉的 match 分支体写 `=> {}` 块会被解析器当成 lambda——实测踩过，分支体一律单语句） */
    private func doFetch(method: String, url: String, args: JsonObject): JsonValue {
        var builder = HttpRequestBuilder().url(url)
        if (method == "GET") {
            builder = builder.get()
        } else if (method == "DELETE") {
            // DELETE 也带 JSON 体：cjh 的工作区删除靠 body 传 path（其 rest_api 的 DELETE 分支
            // 读的就是请求体），所以这里不能走「无体 DELETE」那条路
            builder = builder.delete().body(this.requireString(args, "body"))
        } else {
            let body = this.requireString(args, "body")
            builder = builder.post().body(body)
        }
        // 默认头：JSON 客户端最常见形态；页面可用 headers 覆盖/追加（Host/Content-Length 除外）
        builder = builder.header("Accept", "application/json, text/event-stream, */*")
        builder = this.applyPageHeaders(builder, args)

        let client = ClientBuilder()
            .tlsConfig(TlsClientConfig())
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
            match (resp.headers.getFirst("Content-Type")) {
                // 头名大小写在 HTTP 里不敏感，但取法只有 getFirst（**没有 get**，AGENTS §4）
                case Some(v) => ctype = v
                case None => ()
            }
            // 按块读到 EOF 或上限：resp.body 的静态类型只有 InputStream，
            // readToEnd 编译不过（泛型约束要 Seekable，AGENTS §4）；超限截断并如实标记。
            // ByteBuffer 没有 size 属性：字节数自己累加（music 的 readBodyBytes 同款不查
            // 长度，这里要掐上限，所以另立一版）
            let buf = ByteBuffer()
            let chunk = Array<Byte>(8192, repeat: 0)
            var n = resp.body.read(chunk)
            var total: Int64 = 0
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
        let obj = JsonObject()
        obj.put("status", JsonInt(status))
        obj.put("contentType", JsonString(ctype))
        obj.put("body", JsonString(text))
        obj.put("truncated", JsonBool(truncated))
        return obj
    }

    /** 主机白名单判定（共享层语义：先 deny 后 allow，allow 必须显式命中） */
    private func checkHostScope(url: String, host: String, ipc: IpcContext): Unit {
        // 分支体保持单语句（多语句的块会被解析器当 lambda，见 doFetch 注释）
        match (ipc.scopeRuleFor("http")) {
            case None => this.rejectOutsideScope(url, "no host whitelist declared")
            case Some(rule) => this.checkRuleAllows(url, host, rule)
        }
    }

    private func checkRuleAllows(url: String, host: String, rule: ScopeRule): Unit {
        if (!scopeAllows(rule, host)) {
            this.rejectOutsideScope(url, host)
        }
    }

    private func rejectOutsideScope(url: String, why: String): Nothing {
        eprintln("[cj-tauri] scope denied (http): ${url} -> ${why}")
        throw CommandException("http: host is outside the authorized scope")
    }

    /** 页面自带的请求头（可选 headers 对象，string → string），条数与长度有上限 */
    private func applyPageHeaders(builder: HttpRequestBuilder, args: JsonObject): HttpRequestBuilder {
        var b = builder
        match (args.get("headers")) {
            // 分支体保持单语句（块体会被解析器当 lambda，见 doFetch 注释）
            case Some(v) => b = this.applyHeadersObject(b, v)
            case None => ()
        }
        return b
    }

    private func applyHeadersObject(builder: HttpRequestBuilder, v: JsonValue): HttpRequestBuilder {
        var b = builder
        // JsonKind 没有 ==（AGENTS §4）：枚举比较只能走 match
        let isObject = match (v.kind()) {
            case JsonKind.JsObject => true
            case _ => false
        }
        if (!isObject) {
            return b
        }
        let hs = v.asObject()
        var count: Int64 = 0
        // 遍历用 getFields()（store 插件同款先例）：JsonObject 不是按索引取的容器
        for ((name0, value) in hs.getFields()) {
            if (count >= CJ_HTTP_MAX_HEADERS) {
                break
            }
            // 键小写化后跳过禁改的头
            let name = name0.toAsciiLower()
            if (name == "host" || name == "content-length") {
                // 白名单判的是 URL 里的 host，页面不许改写它
                continue
            }
            if (this.isStringKind(value)) {
                let hval = value.asString().getValue()
                if (hval.size <= CJ_HTTP_MAX_HEADER_VALUE) {
                    b = b.header(name, hval)
                    count++
                }
            }
        }
        return b
    }

    private func isStringKind(v: JsonValue): Bool {
        let r = match (v.kind()) {
            case JsonKind.JsString => true
            case _ => false
        }
        return r
    }

    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => throw CommandException("http: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("http: missing argument \"${key}\"")
        }
    }
}

/**
 * 从 URL 提取 host（小写返回）：核心 urlHostOf 的 **协议收紧包装**——
 * ws/wss 是 ws 插件的合法目标，但不是可抓取目标；http 插件只认 http/https。
 * 解析与大小写口径统一在核心层（urlutil.cj），这里不再有第二份字节扫描。
 * public 是为了单测可直接构造（跨包须 public）。
 */
public func httpHostOf(rawUrl: String): Option<String> {
    let lower = rawUrl.toAsciiLower()
    if (!lower.startsWith("http://") && !lower.startsWith("https://")) {
        return None
    }
    return urlHostOf(rawUrl)
}
