package cjTauri.plugins

import cjTauri.*

import std.collection.*
import std.net.*
import std.sync.*
import std.time.*
import stdx.encoding.json.*

/**
 * 官方插件 redis：Redis 客户端调试工具（键空间浏览、类型化取值、发布订阅、服务器诊断）
 *
 * 设计取舍见 `docs/设计决策记录.md` 的 **D-016**（以插件交付 + 配套示例；协议用纯仓颉 `std.net` 自实现，
 * 不进 C 桥）。协议编解码在 `src/plugins/redis_codec.cj`（纯函数 + 单测），本文件只管连接、会话状态与命令。
 *
 * 命令：`redis:connect` / `disconnect` / `select` / `status` / `info` / `dbsize` / `slowlog` /
 * `scan` / `keyInfo` / `keyRename` / `keyDelete` / `keyExpire` / `keyPersist` /
 * `value` / `valueWrite` / `subscribe` / `unsubscribe` / `publish` / `messages`
 * 事件：`redis:message`（发布订阅收到的一条）+ `redis:state`（连接与订阅状态变化）
 * 权限：**不自动放行**，应用要在 capabilities 里显式声明（明文 `"commands"` 或命名集 `"permissions": ["redis:default"]`）
 * 前端：`window.__CJ_TAURI__.redis.connect({ host: "127.0.0.1", port: 6379 })`
 *
 * **边界如实（D-016）**：只做 RESP2 与单实例（不做 Cluster / Sentinel 拓扑发现）、不做 TLS（`rediss://`）、
 * 不做 ACL 管理类命令（`ACL *`）、不做事务（MULTI/EXEC）与脚本（EVAL）；控制台式「任意命令直发」**有意不做**——
 * 那等于把整台服务器的权限面直接摊给页面，与「命令白名单」的模型相悖。
 * 协议版本由编解码层把关：RESP3 的 map / set / push 前缀一律判协议错误（不猜），页面对端要是 RESP3 会说清。
 *
 * 线程模型：**命令侧**（worker 线程）独占「写一发一读」的 cmd socket，一问一答由 `callLock` 串行化；
 * **发布订阅**走**另一条** socket，其读侧由订阅读线程独占（`redisSubLoop`），命令侧只写。
 * 两条线程都**不调 GTK / WebKit**：事件经 `app.emit()` → 桥的 jsSink 回投（任意线程调用都安全，
 * 见 `src/ipc_hub.cj` 的线程模型注释）。会话可变字段一律在 `RedisSession.lock` 下访问。
 *
 * 命令是**同步阻塞**的（一问一答），跑在命令 worker 线程上（分发本身是异步的，窗口不会被冻住），
 * 因此没有流式输出、也没有取消；每条命令的等待上限由 connect 时的 `timeoutMs` 决定（默认 3s）。
 */

/** `redis:messages` 环形缓冲上限（条）：超限丢最旧并计入 dropped（与 D-015 同一口径） */
let REDIS_RECENT_LIMIT: Int64 = 500

/** 单条发布订阅正文进缓冲 / 事件前的截断上限：256 KiB；超了照实报 truncated，不假装全量 */
let REDIS_RECENT_BODY_LIMIT: Int64 = 262144

/** 建连超时（毫秒）：死地址不能把命令 worker 挂住 */
let REDIS_CONNECT_TIMEOUT_MS: Int64 = 5000

/** 一问一答的默认读超时（毫秒）：可用 connect 的 timeoutMs 覆盖 */
let REDIS_DEFAULT_TIMEOUT_MS: Int64 = 3000

/** 订阅读线程的读超时（毫秒）：它既是「有数据就解」也是「停下来检查」的时基 */
let REDIS_SUB_TICK_MS: Int64 = 200

/** 订阅确认的有界等待（毫秒）：超时就如实报「回执未到」，不假装订阅成功 */
let REDIS_SUB_ACK_TIMEOUT_MS: Int64 = 3000

/** 收下一条命令回复时一次读的字节数 */
let REDIS_READ_CHUNK: Int64 = 16384

/** 等订阅读线程收尾的上限（毫秒）：等不到就如实打一行 stderr 再继续 */
let REDIS_SUB_EXIT_WAIT_MS: Int64 = 1000

/** 单条字符串值 / 集合元素的展示上限：超了只给前 N 字节并置 truncated（页面照实显示） */
let REDIS_VALUE_TEXT_LIMIT: Int64 = 65536

/** 一次 `scan` / `value` 分页最多取回的条目数（页面要的是「看一眼」，不是导库） */
let REDIS_PAGE_MAX: Int64 = 200

/**
 * 插件的全部命令短名（`permissions()` 的 `default` 集就是它，别再抄第二份）。
 *
 * 用 `let` 而不是 `const`：仓颉的 `const` 只收编译期常量表达式，`Array` 字面量编译不过（AGENTS §4）。
 */
let REDIS_PLUGIN_COMMANDS: Array<String> = [
    "connect", "disconnect", "select", "status", "info", "dbsize", "slowlog",
    "scan", "keyInfo", "keyRename", "keyDelete", "keyExpire", "keyPersist",
    "value", "valueWrite", "subscribe", "unsubscribe", "publish", "messages"
]

/** 只观不控的集合：浏览与诊断都算，改数据的一个都不给（`permissions()` 的 `readonly` 集） */
let REDIS_READONLY_COMMANDS: Array<String> = [
    "connect", "disconnect", "select", "status", "info", "dbsize", "slowlog",
    "scan", "keyInfo", "value", "subscribe", "unsubscribe", "messages"
]

/** 值类型名（TYPE 命令的返回值）：判断走哪条取值路径时用 */
let REDIS_TYPE_STRING = "string"
let REDIS_TYPE_LIST = "list"
let REDIS_TYPE_SET = "set"
let REDIS_TYPE_ZSET = "zset"
let REDIS_TYPE_HASH = "hash"
let REDIS_TYPE_STREAM = "stream"

/**
 * 一条 Redis 连接的全部可变状态（**所有字段都在 lock 下访问**——两次命令可能落在不同 worker 上）。
 *
 * cmd 与 sub 是两条独立的 TCP 连接：发布订阅一旦订阅上，那条连接就（按协议）只能收推送了，
 * 拿它继续发键空间命令是错的。所以「浏览 + 订阅」在用同一份连接参数的前提下各占一条。
 */
class RedisSession {
    let lock: Mutex = Mutex()

    /** 一问一答的串行化锁：请求与应答必须成对，两条命令交错写会把回复读串 */
    let callLock: Mutex = Mutex()

    /** 命令连接（None = 未连接）；读侧由命令线程独占 */
    var cmd: Option<TcpSocket> = None

    /** 命令连接的增量解析器（半条回复留在里面，跨 read 累计） */
    var cmdReader: RespReader = RespReader()

    /** 订阅连接与它的解析器（读侧由订阅读线程独占） */
    var sub: Option<TcpSocket> = None
    var subReader: RespReader = RespReader()

    /** idle / connecting / connected / closed / error：页面直接显示，所以用字符串而不是枚举 */
    var state: String = "idle"
    var host: String = ""
    var port: Int64 = 6379
    var db: Int64 = 0
    var authUsed: Bool = false
    var timeoutMs: Int64 = REDIS_DEFAULT_TIMEOUT_MS

    /**
     * 认证信息**只在内存里留一份**：订阅连接要再认证一次（两条连接各自 AUTH），所以会话得留着。
     * 它不进 status、不进事件、不进日志——任何回给页面的报文里都不该出现口令本身
     * （页面本来就知道自己填了什么，回显只会让口令多一份副本躺在缓冲与日志里）。
     */
    var username: String = ""
    var password: String = ""

    /** 已订阅的频道 / 模式（订阅命令写入，读线程按回执对账） */
    var channels: ArrayList<String> = ArrayList<String>()
    var patterns: ArrayList<String> = ArrayList<String>()

    /** 订阅读线程是否在跑；stopSubRequested 是「请读线程退出」的旗标 */
    var subAlive: Bool = false
    var stopSubRequested: Bool = false

    /** 已发出的订阅请求待确认条数（`subscribe` 命令读它做有界等待） */
    var subPendingAcks: Int64 = 0

    /** 序号与计数：seq 给页面去重（同一条约也走事件与拉取两条通道），其余供 status 对账 */
    var seq: Int64 = 0
    var calls: Int64 = 0
    var msgCount: Int64 = 0
    var dropped: Int64 = 0
    var lastError: String = ""

    /** 最近一次收发时刻（status 里给页面看「还活着吗」） */
    var lastTxAt: DateTime = DateTime.now()
    var lastRxAt: DateTime = DateTime.now()

    /** 发布订阅的环形缓冲（元素是给前端的 JSON）；满了丢最旧并累计 dropped */
    var recent: ArrayList<JsonValue> = ArrayList<JsonValue>()

    /** app 引用：`RedisPlugin.setup()` 装配进来，事件回投要用它 */
    var app: Option<TauriApp> = None
}

// ---------------------------------------------------------------- 事件与失败收口

/**
 * 记一条发布订阅报文：**赋 seq → 入缓冲（超限丢最旧并计 dropped）→ 推事件**，两条路在这里收口。
 *
 * 顺序刻意固定（与 MQTT 的 D-015 同款）：先入缓冲再推事件——清单没声明 `events` 时事件会被框架丢弃
 * （打一行 stderr），而 `redis:messages` 照旧拿得到，这正是「事件可以丢、拉取兜底」那条取舍。
 *
 * 调用方**不要**持有 `sess.lock`（本函数自己加锁）。
 */
func redisRecordMessage(sess: RedisSession, obj: JsonObject): Unit {
    var app: Option<TauriApp> = None
    sess.lock.lock()
    sess.seq += 1
    obj.put("seq", JsonInt(sess.seq))
    obj.put("ts", JsonString(DateTime.now().toString()))
    sess.msgCount += 1
    app = sess.app
    sess.recent.add(obj)
    // 超限：整块搬一次最旧的 N 条，代价 O(上限)，500 条量级可忽略；
    // 不用集合层的删除重载是为了让「丢的是什么」在这段代码里一眼可见（dropped 必须如实对得上）
    if (sess.recent.size > REDIS_RECENT_LIMIT) {
        let from = sess.recent.size - REDIS_RECENT_LIMIT
        let keep = ArrayList<JsonValue>()
        var i: Int64 = from
        while (i < sess.recent.size) {
            keep.add(sess.recent[i])
            i += 1
        }
        sess.dropped += from
        sess.recent = keep
        eprintln("[cj-tauri] redis: 订阅缓冲超限，丢弃最旧 ${from} 条（累计 dropped=${sess.dropped}）")
    }
    sess.lock.unlock()
    match (app) {
        case Some(a) => a.emit("redis:message", obj)
        case None => ()
    }
}

/**
 * 推 `redis:state`：连接与订阅状态是页面最需要**立刻**知道的事（被拒 / 掉线不能只躺在缓冲里）。
 * 调用方不要持锁。
 */
func redisEmitState(sess: RedisSession): Unit {
    var app: Option<TauriApp> = None
    let obj = JsonObject()
    sess.lock.lock()
    app = sess.app
    obj.put("state", JsonString(sess.state))
    obj.put("host", JsonString(sess.host))
    obj.put("port", JsonInt(sess.port))
    obj.put("db", JsonInt(sess.db))
    obj.put("auth", JsonBool(sess.authUsed))
    obj.put("subAlive", JsonBool(sess.subAlive))
    obj.put("channels", redisStringArray(sess.channels))
    obj.put("patterns", redisStringArray(sess.patterns))
    obj.put("calls", JsonInt(sess.calls))
    obj.put("messages", JsonInt(sess.msgCount))
    obj.put("dropped", JsonInt(sess.dropped))
    obj.put("error", JsonString(sess.lastError))
    // 状态变迁同时落一行 stderr：事件通道页面没接住时（没声明 events / 页面在重载），
    // 「连上过没有、什么时候掉的」仍能端到端对账——与框架其余能力的取证口径一致（AGENTS §1）
    eprintln("[cj-tauri] redis state: state=${sess.state} host=${sess.host}:${sess.port} db=${sess.db}" +
        " sub=${sess.subAlive} channels=${sess.channels.size} calls=${sess.calls} msgs=${sess.msgCount}" +
        " dropped=${sess.dropped}")
    sess.lock.unlock()
    match (app) {
        case Some(a) => a.emit("redis:state", obj)
        case None => ()
    }
}

/**
 * 置会话为错误态：停订阅线程、关两条 socket、记原因、推 `redis:state`。
 *
 * 命令线程与订阅读线程都可能调它（读失败 / 写失败 / 协议错误），所以必须**幂等**：
 * 谁先到谁把原因写进去，后到的看到 socket 已经是 None 就只收尾。
 */
func redisFailSession(sess: RedisSession, reason: String): Unit {
    var cmdSock: Option<TcpSocket> = None
    var subSock: Option<TcpSocket> = None
    var first = false
    sess.lock.lock()
    cmdSock = sess.cmd
    subSock = sess.sub
    sess.cmd = None
    sess.sub = None
    if (sess.state != "error") {
        first = true
        sess.state = "error"
        sess.lastError = reason
    }
    sess.stopSubRequested = true
    sess.subAlive = false
    sess.subPendingAcks = 0
    sess.lock.unlock()
    match (cmdSock) {
        case Some(s) => redisCloseQuiet(s)
        case None => ()
    }
    match (subSock) {
        case Some(s) => redisCloseQuiet(s)
        case None => ()
    }
    if (first) {
        eprintln("[cj-tauri] redis: ${reason}")
    }
    redisEmitState(sess)
}

/** 关一条 socket 且不因关闭失败打扰调用方（收尾路径上不该再抛异常） */
func redisCloseQuiet(sock: TcpSocket): Unit {
    try {
        sock.close()
    } catch (e: Exception) {
        let _ = e
    }
}

/** 字符串数组 → JSON 数组（保持原顺序：订阅顺序对用户是有意义的） */
func redisStringArray(items: ArrayList<String>): JsonValue {
    let arr = ArrayList<JsonValue>()
    for (s in items) {
        arr.add(JsonString(s))
    }
    return JsonArray(arr)
}

// ---------------------------------------------------------------- 参数与数值助手

/** 夹范围：浮点转整数前必须先夹，越界会抛异常把整条命令带走（AGENTS §4 的那条坑） */
func redisClampInt(v: Int64, lo: Int64, hi: Int64): Int64 {
    if (v < lo) {
        return lo
    }
    if (v > hi) {
        return hi
    }
    return v
}

/** 主机名 / IP 的安全字符集检查：不把它塞进 shell（走 argv），但仍拒绝明显荒唐的输入 */
func redisValidHost(host: String): Bool {
    if (host.size == 0 || host.size > 253) {
        return false
    }
    for (b in host) {
        let ok = (b >= 97u8 && b <= 122u8) || (b >= 65u8 && b <= 90u8) || (b >= 48u8 && b <= 57u8) ||
            b == 46u8 || b == 45u8 || b == 95u8 || b == 58u8 || b == 91u8 || b == 93u8
        if (!ok) {
            return false
        }
    }
    return true
}

/** 端口合法性：1..65535（0 不是可连的服务端口） */
func redisValidPort(port: Int64): Bool {
    return port >= 1 && port <= 65535
}

/** 库号合法性：0..255（Redis 默认 16 个库，但配置可调，这里只挡明显越界的） */
func redisValidDb(db: Int64): Bool {
    return db >= 0 && db <= 255
}

/**
 * 把一个 RESP 回复翻成 JSON（页面直接可用的形状）。
 *
 * `Failure` 在这里**不抛异常**而是翻成 `{"error": "..."}`：只有调用方知道「这个错误算不算失败」
 * （例如 `TYPE` 对不存在的键回的是 simple 而不是 error，但 `GET` 打错类型会回 WRONGTYPE）。
 * 真正需要把错误当失败的命令自己调 `redisExpectOk`。
 */
func redisReplyJson(v: RespValue): JsonValue {
    match (v) {
        case Simple(s) => return JsonString(s)
        case Failure(m) =>
            let obj = JsonObject()
            obj.put("error", JsonString(m))
            return obj
        case Number(n) => return JsonInt(n)
        case Bulk(None) => return JsonNull()
        case Bulk(Some(b)) => return JsonString(respSafeText(b))
        case Arr(None) => return JsonNull()
        case Arr(Some(items)) =>
            let arr = ArrayList<JsonValue>()
            for (it in items) {
                arr.add(redisReplyJson(it))
            }
            return JsonArray(arr)
    }
}

/**
 * 回复必须是「不是错误」：`-ERR ...` 一律翻成业务错误抛给前端。
 *
 * 抛之前落一行 stderr（`redis command failed`），与 MQTT 那条教训同口径：光有 reject 没有日志，
 * 命令「没反应」时端到端毫无凭证。
 */
func redisExpectOk(v: RespValue, what: String): RespValue {
    match (v) {
        case Failure(m) =>
            eprintln("[cj-tauri] redis command failed (${what}): ${m}")
            throw CommandException("redis: ${what} 失败（${m}）")
        case _ => return v
    }
}

/** 取整数回复（`Number`）；别的形状一律判协议异常（不该出现，出现了要能查） */
func redisNumberReply(v: RespValue, what: String): Int64 {
    match (v) {
        case Number(n) => return n
        case Failure(m) =>
            eprintln("[cj-tauri] redis command failed (${what}): ${m}")
            throw CommandException("redis: ${what} 失败（${m}）")
        case _ => throw CommandException("redis: ${what} 期望整数回复，实际是 ${respBrief(v)}")
    }
}

/** 取文本回复（simple / bulk 都算）；数组等复杂形状按调用方自己解 */
func redisTextReply(v: RespValue, what: String): String {
    match (v) {
        case Simple(s) => return s
        case Bulk(Some(b)) => return respSafeText(b)
        case Bulk(None) => return ""
        case Failure(m) =>
            eprintln("[cj-tauri] redis command failed (${what}): ${m}")
            throw CommandException("redis: ${what} 失败（${m}）")
        case _ => throw CommandException("redis: ${what} 期望文本回复，实际是 ${respBrief(v)}")
    }
}

// ---------------------------------------------------------------- socket 与「一问一答」

/** 日志用：超长文本按字节截断（不设上限的一条回复会把整段日志淹掉，排查反而更难） */
func redisClip(s: String, limit: Int64): String {
    if (s.size <= limit) {
        return s
    }
    // 字节切片可能切在 UTF-8 中间，交给与取值同一套口径（坏字节走 hex）保证日志可读
    return respSafeText(s.toArray()[0..limit]) + "…(截断)"
}

/** 日志用的回复摘要：simple / error 正文也截断，其余交给 respBrief（它本身就只说规模） */
func redisBriefClipped(v: RespValue): String {
    match (v) {
        case Simple(s) => return "simple(" + redisClip(s, 64) + ")"
        case Failure(m) => return "error(" + redisClip(m, 64) + ")"
        case _ => return respBrief(v)
    }
}

/** 落一行调用日志：命令名 + 回复摘要 + 累计调用数（**不打参数值**，免得用户的键值进日志） */
func redisLogCall(sess: RedisSession, what: String, reply: RespValue): Unit {
    sess.lock.lock()
    sess.calls += 1
    let n = sess.calls
    sess.lock.unlock()
    eprintln("[cj-tauri] redis call: ${what} -> ${redisBriefClipped(reply)} (n=${n})")
}

/**
 * 读一个完整回复：先看解析器里有没有攒够，没有就从 socket 再收。
 *
 * 超时口径分两层：socket 的 readTimeout 管「对端一直不说话」，本函数的 elapsed 管「说了半句停住」——
 * 两者都判会话坏（半条回复留在解析器里，接着用就是对错位的字节）。`what` 是命令短名，只进日志。
 */
func redisReadReply(sess: RedisSession, sock: TcpSocket, reader: RespReader, what: String): RespValue {
    let started = DateTime.now()
    // 用 `Option` 当循环条件而不是 `while (true)` + `return`：仓颉不把 `while (true)` 当发散表达式，
    // 函数尾表达式会被判成 Unit（`expected 'RespValue', found 'Unit'`），这类写法只能显式带出结果。
    var out: Option<RespValue> = None
    while (out.isNone()) {
        match (reader.respTryRead()) {
            case RespRead.Value(v) => out = Some(v)
            case RespRead.Malformed(m) =>
                redisFailSession(sess, "对端回复不符合 RESP2（${what}）：${m}")
                throw CommandException("redis: 协议错误（${m}）")
            case RespRead.Incomplete =>
                let buf = Array<UInt8>(REDIS_READ_CHUNK, repeat: 0)
                var got: Int64 = -1
                try {
                    got = sock.read(buf)
                } catch (e: SocketTimeoutException) {
                    if ((DateTime.now() - started).toMilliseconds() > sess.timeoutMs) {
                        redisFailSession(sess, "${what} 超时（${sess.timeoutMs}ms 未收到完整回复）")
                        throw CommandException("redis: ${what} 超时（${sess.timeoutMs}ms 未收到完整回复，会话已判坏）")
                    }
                    got = -1
                } catch (e: Exception) {
                    redisFailSession(sess, "${what} 读取失败：${e.message}")
                    throw CommandException("redis: ${what} 读取失败（${e.message}）")
                }
                if (got > 0) {
                    reader.feed(buf[0..got])
                    sess.lock.lock()
                    sess.lastRxAt = DateTime.now()
                    sess.lock.unlock()
                } else if (got == 0) {
                    redisFailSession(sess, "${what} 期间对端关闭了连接")
                    throw CommandException("redis: 对端关闭了连接（${what}）")
                }
                // got < 0：socket 读超时（窗口比命令总超时短），转下一轮继续等
        }
    }
    out.getOrThrow()
}

/** 写一帧（**调用方须持 callLock**）：写失败一律置会话错误态并抛出——宁可当场报错，不留假连接 */
func redisWriteFrame(sess: RedisSession, sock: TcpSocket, frame: Array<UInt8>): Unit {
    try {
        sock.write(frame)
    } catch (e: Exception) {
        redisFailSession(sess, "写入失败：${e.message}")
        throw CommandException("redis: 写入失败（${e.message}）")
    }
    sess.lock.lock()
    sess.lastTxAt = DateTime.now()
    sess.lock.unlock()
}

/** 取命令 socket：未连接就明确报错，不进后续流程（调试工具最怕「命令看着发出去了」） */
func redisRequireCmd(sess: RedisSession): TcpSocket {
    sess.lock.lock()
    let st = sess.state
    let sock = sess.cmd
    sess.lock.unlock()
    if (st != "connected") {
        throw CommandException("redis: 未连接（当前状态 ${st}），请先 redis:connect")
    }
    match (sock) {
        case Some(s) => return s
        case None => throw CommandException("redis: 连接已断开（socket 已回收），请重新 connect")
    }
}

/**
 * 在指定 socket 上「写一帧 + 读一个回复 + 记一行日志」（**调用方须持 callLock**）。
 * 握手（命令连接与订阅连接都要走）与流水线三条路都汇到这里，日志形状因此只有一个来源。
 */
func redisCallOn(sess: RedisSession, sock: TcpSocket, reader: RespReader, frame: Array<UInt8>,
                 what: String): RespValue {
    redisWriteFrame(sess, sock, frame)
    let reply = redisReadReply(sess, sock, reader, what)
    redisLogCall(sess, what, reply)
    return reply
}

/**
 * 帧级一问一答（**自己加锁**）：请求与应答必须成对，两条命令交错写会把回复读串。
 *
 * 这层保证「异常也一定解锁」——漏解锁会让之后所有命令永久卡住，比报错严重得多。
 */
func redisCallFrame(sess: RedisSession, frame: Array<UInt8>, what: String): RespValue {
    let sock = redisRequireCmd(sess)
    sess.callLock.lock()
    try {
        let reply = redisCallOn(sess, sock, sess.cmdReader, frame, what)
        sess.callLock.unlock()
        return reply
    } catch (e: Exception) {
        sess.callLock.unlock()
        throw e
    }
}

/** 文本命令：组帧后走帧级入口（参数里**不要**放二进制；要放二进制就自己组帧走 redisCallFrame） */
func redisCall(sess: RedisSession, parts: Array<String>): RespValue {
    return redisCallFrame(sess, respEncodeCommand(parts), parts[0])
}

/**
 * 流水线：一口气写 N 条命令再**按顺序**读 N 个回复（`scan` 之后给每个键取 TYPE/TTL 就是它）。
 * 整段在同一把锁里，因此不会与别的命令交错；返回数组按位置与 frames 一一对应，缺位会让页面拿错数据。
 */
func redisCallMany(sess: RedisSession, frames: ArrayList<Array<UInt8>>, what: String): ArrayList<RespValue> {
    let out = ArrayList<RespValue>()
    if (frames.size == 0) {
        return out
    }
    let sock = redisRequireCmd(sess)
    sess.callLock.lock()
    try {
        for (f in frames) {
            redisWriteFrame(sess, sock, f)
        }
        var i: Int64 = 0
        while (i < frames.size) {
            out.add(redisReadReply(sess, sock, sess.cmdReader, what))
            i += 1
        }
        sess.lock.lock()
        sess.calls += frames.size
        let n = sess.calls
        sess.lock.unlock()
        eprintln("[cj-tauri] redis call: PIPELINE ${what} n=${frames.size} 回执已按序读齐 (n=${n})")
    } catch (e: Exception) {
        sess.callLock.unlock()
        throw e
    }
    sess.callLock.unlock()
    return out
}

/**
 * 建一条 TCP 连接并设好超时（命令连接与订阅连接共用）。
 *
 * `readTimeoutMillis` 由调用方给：命令连接用一问一答的超时（等不到就报错），订阅连接用短 tick
 * （它就是读线程「有数据就解、没数据就查停不停」的时基）。连不上直接抛出，**不静默重试**。
 */
func redisOpenSocket(sess: RedisSession, readTimeoutMillis: Int64): TcpSocket {
    sess.lock.lock()
    let host = sess.host
    let port = sess.port
    sess.lock.unlock()
    let sock = TcpSocket(host, UInt16(port))
    try {
        sock.connect(timeout: Duration.millisecond * REDIS_CONNECT_TIMEOUT_MS)
    } catch (e: Exception) {
        throw CommandException("redis: 连接 ${host}:${port} 失败（${e.message}）")
    }
    sock.noDelay = true
    sock.writeTimeout = Duration.millisecond * REDIS_CONNECT_TIMEOUT_MS
    sock.readTimeout = Duration.millisecond * readTimeoutMillis
    return sock
}

/**
 * 建连后的握手：AUTH（建连时给了口令才做）→ SELECT（非 0 库才做）→ PING 验活。
 *
 * 三步都在这条 socket 上**同步**做（此时还没有第二个读者），任一步失败都置错误态并抛出——
 * 「看着连上了其实没通过认证」是调试工具最容易骗人的失败形状，必须当场暴露。
 * 订阅连接复用同一个函数：它也要 AUTH，但**不做 SELECT**（发布订阅与库无关，见 D-016）。
 */
func redisHandshake(sess: RedisSession, sock: TcpSocket, reader: RespReader, withSelect: Bool): Unit {
    sess.lock.lock()
    let pass = sess.password
    let user = sess.username
    let db = sess.db
    sess.lock.unlock()
    if (pass.size > 0) {
        var frame = respEncodeCommand(["AUTH", pass])
        if (user.size > 0) {
            frame = respEncodeCommand(["AUTH", user, pass])
        }
        redisExpectOk(redisCallOn(sess, sock, reader, frame, "AUTH"), "AUTH")
        sess.lock.lock()
        sess.authUsed = true
        sess.lock.unlock()
    }
    if (withSelect && db != 0) {
        redisExpectOk(redisCallOn(sess, sock, reader, respEncodeCommand(["SELECT", "${db}"]), "SELECT"), "SELECT")
    }
    // PING 是「这条连接真会谈 RESP 吗」的最小验证：回的不是 PONG 就当握手失败（不猜对端是什么）
    let pong = redisExpectOk(redisCallOn(sess, sock, reader, respEncodeCommand(["PING"]), "PING"), "PING")
    match (pong) {
        case Simple(s) =>
            if (s != "PONG") {
                throw CommandException("redis: 握手失败（PING 回的是 ${s}，不是 PONG）")
            }
        case _ => throw CommandException("redis: 握手失败（PING 回的形状是 ${respBrief(pong)}，不是 -PONG）")
    }
}

// ---------------------------------------------------------------- 命令侧：分派与各命令实现

/**
 * redis 插件的命令处理器：19 个命令共用一份，按全名分派（与 SerialCommands / MqttCommands 同形）。
 *
 * **每次 connect 都换一份新会话**，不复用上一份状态：旧会话的订阅线程只碰它自己那份，于是永远不会
 * 误关新连接的 socket、也不会把旧连接的断线状态盖到新连接上。重连路径额外做一件事——先让旧会话收尾
 * （`closePrevious`），否则它的收尾事件可能落在新连接的「connected」之后，页面就莫名其妙显成断线。
 */
class RedisCommands <: CommandHandler {
    /** 保护 current 指针：命令在 worker 线程上执行，页面连点 / 多条命令同时飞都是常态 */
    private let lock: Mutex = Mutex()
    private var current: RedisSession = RedisSession()
    private var app: Option<TauriApp> = None

    public init() {}

    /** 由 RedisPlugin.setup() 调用：拿 app 才能推事件（redis:message / redis:state） */
    public func attachApp(a: TauriApp): Unit {
        this.app = Some(a)
        this.lock.lock()
        this.current.app = this.app
        this.lock.unlock()
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = ipc
        match (cmd) {
            case "redis:connect" => this.connectCmd(args)
            case "redis:disconnect" => this.disconnectCmd(args)
            case "redis:select" => this.selectCmd(args)
            case "redis:status" => this.statusCmd(args)
            case "redis:info" => this.infoCmd(args)
            case "redis:dbsize" => this.dbsizeCmd(args)
            case "redis:slowlog" => this.slowlogCmd(args)
            case "redis:scan" => this.scanCmd(args)
            case "redis:keyInfo" => this.keyInfoCmd(args)
            case "redis:keyRename" => this.keyRenameCmd(args)
            case "redis:keyDelete" => this.keyDeleteCmd(args)
            case "redis:keyExpire" => this.keyExpireCmd(args)
            case "redis:keyPersist" => this.keyPersistCmd(args)
            case "redis:value" => this.valueCmd(args)
            case "redis:valueWrite" => this.valueWriteCmd(args)
            case "redis:subscribe" => this.subscribeCmd(args)
            case "redis:unsubscribe" => this.unsubscribeCmd(args)
            case "redis:publish" => this.publishCmd(args)
            case "redis:messages" => this.messagesCmd(args)
            case _ => throw CommandException("unknown redis command: ${cmd}")
        }
    }

    /** 取当前会话（拿的是引用；字段读写由调用方自己加锁） */
    private func session(): RedisSession {
        this.lock.lock()
        let s = this.current
        this.lock.unlock()
        return s
    }

    /** 取当前会话的 app 引用（会话里的 app 由 attachApp 填，这里只是搭桥给顶层函数用） */
    private func attachTo(sess: RedisSession): Unit {
        this.lock.lock()
        sess.app = this.app
        this.lock.unlock()
    }

    // ------------------------------------------------------------ 参数解析

    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => v.asString().getValue()
                case _ => throw CommandException("redis: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("redis: missing argument \"${key}\"")
        }
    }

    /** 可选字符串参数：缺失 / null 都按空串（用例：host 必填、db 可选） */
    private func optionalString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => v.asString().getValue()
                case JsonKind.JsNull => ""
                case _ => throw CommandException("redis: argument \"${key}\" must be a string")
            }
            case None => ""
        }
    }

    /** 可选字符串参数（要区分「没给」与「给了空串」时用它，例如 password） */
    private func optionalStringValue(args: JsonObject, key: String): Option<String> {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => Some(v.asString().getValue())
                case JsonKind.JsNull => None
                case _ => throw CommandException("redis: argument \"${key}\" must be a string")
            }
            case None => None
        }
    }

    /** 可选整数参数：缺失 / null 都取 fallback；JSON 侧 numeric 可能是整数也可能是浮点 */
    private func optionalInt(args: JsonObject, key: String, fallback: Int64): Int64 {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsInt => v.asInt().getValue()
                case JsonKind.JsFloat =>
                    // 浮点转整数先夹范围：越界会抛异常把整条命令带走（AGENTS §4 的那条坑）
                    redisClampInt(Int64(v.asFloat().getValue()), -65536, 65536)
                case JsonKind.JsNull => fallback
                case _ => throw CommandException("redis: argument \"${key}\" must be a number")
            }
            case None => fallback
        }
    }

    /** 可选布尔参数：缺失 / null 都取 fallback */
    private func optionalBool(args: JsonObject, key: String, fallback: Bool): Bool {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsBool => v.asBool().getValue()
                case JsonKind.JsNull => fallback
                case _ => throw CommandException("redis: argument \"${key}\" must be a boolean")
            }
            case None => fallback
        }
    }

    /** 必填的非空字符串数组（channels / keys）：元素必须都是字符串，空数组即拒（免得生成 `DEL` 这种残命令） */
    private func requireStringArray(args: JsonObject, key: String): ArrayList<String> {
        let out = ArrayList<String>()
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsArray =>
                    let items = v.asArray().getItems()
                    for (it in items) {
                        match (it.kind()) {
                            case JsonKind.JsString => out.add(it.asString().getValue())
                            case _ => throw CommandException("redis: argument \"${key}\" must be an array of strings")
                        }
                    }
                case _ => throw CommandException("redis: argument \"${key}\" must be an array of strings")
            }
            case None => throw CommandException("redis: missing argument \"${key}\"")
        }
        if (out.size == 0) {
            throw CommandException("redis: argument \"${key}\" must not be empty")
        }
        return out
    }

    /** 可选字符串数组：缺失 / null 都给空表 */
    private func optionalStringArray(args: JsonObject, key: String): ArrayList<String> {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsArray =>
                    let out = ArrayList<String>()
                    for (it in v.asArray().getItems()) {
                        match (it.kind()) {
                            case JsonKind.JsString => out.add(it.asString().getValue())
                            case _ => throw CommandException("redis: argument \"${key}\" must be an array of strings")
                        }
                    }
                    return out
                case JsonKind.JsNull => return ArrayList<String>()
                case _ => throw CommandException("redis: argument \"${key}\" must be an array of strings")
            }
            case None => return ArrayList<String>()
        }
    }

    /**
     * 取要写进 Redis 的字节：优先 `valueHex`（页面拿非 UTF-8 的旧值原样回写时走这条），
     * 否则用 `value` 的 UTF-8 字节。两者都给时以 hex 为准（它是无损的那一份）。
     */
    private func valueBytes(args: JsonObject, valueKey: String, hexKey: String): Array<UInt8> {
        let hex = this.optionalString(args, hexKey)
        if (hex.size > 0) {
            match (serialHexToBytes(hex)) {
                case Some(b) => return b
                case None => throw CommandException("redis: argument \"${hexKey}\" is not valid hex")
            }
        }
        return this.optionalString(args, valueKey).toArray()
    }

    // ------------------------------------------------------------ 连接类命令

    /**
     * `redis:connect { host, port?, db?, username?, password?, timeoutMs? }`
     *
     * 握手在**本命令线程上同步做**（TCP → AUTH → SELECT → PING），结果随命令结果回给前端：
     * 页面不用猜「到底连上没有」。有意**不做自动重连、不做静默降级**——调试工具最怕假连接。
     */
    private func connectCmd(args: JsonObject): JsonValue {
        let host = this.requireString(args, "host")
        let port = this.optionalInt(args, "port", 6379)
        let db = this.optionalInt(args, "db", 0)
        let user = this.optionalString(args, "username")
        let pass = this.optionalStringValue(args, "password")
        let timeoutMs = this.optionalInt(args, "timeoutMs", REDIS_DEFAULT_TIMEOUT_MS)
        if (!redisValidHost(host)) {
            throw CommandException("redis: host 非法（只收 IP / 主机名的安全字符 [A-Za-z0-9._:-]，长度 1..253）")
        }
        if (!redisValidPort(port)) {
            throw CommandException("redis: port 非法（须在 1..65535）")
        }
        if (!redisValidDb(db)) {
            throw CommandException("redis: db 非法（须在 0..255）")
        }
        if (timeoutMs < 200 || timeoutMs > 60000) {
            throw CommandException("redis: timeoutMs 非法（须在 200..60000）")
        }
        this.closePrevious()
        // 新会话（不复用旧状态）：旧会话的订阅线程只碰它自己那份，见类注释
        let sess = RedisSession()
        sess.host = host
        sess.port = port
        sess.db = db
        sess.timeoutMs = timeoutMs
        sess.state = "connecting"
        sess.username = user
        match (pass) {
            case Some(p) => sess.password = p
            case None => ()
        }
        this.lock.lock()
        this.current = sess
        this.lock.unlock()
        this.attachTo(sess)

        var opened: Option<TcpSocket> = None
        try {
            let sock = redisOpenSocket(sess, timeoutMs)
            opened = Some(sock)
            redisHandshake(sess, sock, sess.cmdReader, true)
            sess.lock.lock()
            sess.cmd = Some(sock)
            sess.state = "connected"
            sess.lock.unlock()
        } catch (e: CommandException) {
            match (opened) {
                case Some(s) => redisCloseQuiet(s)
                case None => ()
            }
            redisFailSession(sess, e.message)
            throw e
        }
        redisEmitState(sess)
        eprintln("[cj-tauri] redis connect: host=${host} port=${port} db=${db} auth=${sess.authUsed} ok")
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("host", JsonString(host))
        out.put("port", JsonInt(port))
        out.put("db", JsonInt(db))
        out.put("auth", JsonBool(sess.authUsed))
        out.put("timeoutMs", JsonInt(timeoutMs))
        out.put("note", JsonString("握手已含 AUTH（给了口令时）→ SELECT（非 0 库时）→ PING 验活"))
        out
    }

    /** `redis:disconnect`：收掉订阅线程与两条连接；状态置 closed（不是 error——是本端主动收） */
    private func disconnectCmd(args: JsonObject): JsonValue {
        let _ = args
        let sess = this.session()
        sess.lock.lock()
        sess.stopSubRequested = true
        let hadSub = sess.subAlive
        let hadChannels = sess.channels.size
        if (sess.state == "connected" || sess.state == "connecting") {
            sess.state = "closed"
        }
        sess.lock.unlock()
        this.waitSubExit(sess)
        sess.lock.lock()
        let subSock = sess.sub
        let cmdSock = sess.cmd
        sess.sub = None
        sess.cmd = None
        sess.subAlive = false
        sess.subPendingAcks = 0
        sess.channels = ArrayList<String>()
        sess.patterns = ArrayList<String>()
        sess.lock.unlock()
        match (subSock) {
            case Some(s) => redisCloseQuiet(s)
            case None => ()
        }
        match (cmdSock) {
            case Some(s) => redisCloseQuiet(s)
            case None => ()
        }
        redisEmitState(sess)
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("hadSub", JsonBool(hadSub))
        out.put("droppedChannels", JsonInt(hadChannels))
        out
    }

    /** `redis:select { db }`：切库（会话记下新库号，status 与事件里的 db 会跟着变） */
    private func selectCmd(args: JsonObject): JsonValue {
        let db = this.optionalInt(args, "db", 0)
        if (!redisValidDb(db)) {
            throw CommandException("redis: db 非法（须在 0..255）")
        }
        let sess = this.session()
        redisExpectOk(redisCall(sess, ["SELECT", "${db}"]), "SELECT")
        sess.lock.lock()
        sess.db = db
        sess.lock.unlock()
        redisEmitState(sess)
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("db", JsonInt(db))
        out
    }

    /**
     * `redis:status`：一份可对账的连接快照（页面顶栏就是它）。
     *
     * 口令**不在其中**（会话里留着是为了给订阅连接再认证一次，回显只会多一份副本）。
     * 注意 `state` 是字符串而不是枚举，页面直接显示，不需要自己攒一张对照表。
     */
    private func statusCmd(args: JsonObject): JsonValue {
        let _ = args
        let sess = this.session()
        let out = JsonObject()
        sess.lock.lock()
        out.put("state", JsonString(sess.state))
        out.put("host", JsonString(sess.host))
        out.put("port", JsonInt(sess.port))
        out.put("db", JsonInt(sess.db))
        out.put("auth", JsonBool(sess.authUsed))
        out.put("timeoutMs", JsonInt(sess.timeoutMs))
        out.put("subAlive", JsonBool(sess.subAlive))
        out.put("calls", JsonInt(sess.calls))
        out.put("messages", JsonInt(sess.msgCount))
        out.put("dropped", JsonInt(sess.dropped))
        out.put("buffered", JsonInt(sess.recent.size))
        out.put("lastError", JsonString(sess.lastError))
        out.put("lastTxAt", JsonString(sess.lastTxAt.toString()))
        out.put("lastRxAt", JsonString(sess.lastRxAt.toString()))
        out.put("channels", redisStringArray(sess.channels))
        out.put("patterns", redisStringArray(sess.patterns))
        sess.lock.unlock()
        out.put("note", JsonString("calls = 已往返的 RESP 命令数；dropped = 订阅缓冲满被丢弃的报文数"))
        out
    }

    // ------------------------------------------------------------ 服务器信息类命令

    /**
     * `redis:info { section? }`：服务器信息（不给 section 就是 INFO 全量，几 KB 量级）。
     *
     * 返回值同时给 `text`（原文）与 `sections`（结构化解析）：解析是**尽力而为**的——各版本字段会变，
     * 解析不出来时 text 永远是对的，页面别把解析结果当唯一真源。
     */
    private func infoCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let section = this.optionalString(args, "section")
        var reply = RespValue.Simple("")
        if (section.size > 0) {
            reply = redisCall(sess, ["INFO", section])
        } else {
            reply = redisCall(sess, ["INFO"])
        }
        let text = redisTextReply(reply, "INFO")
        let out = JsonObject()
        out.put("section", JsonString(section))
        out.put("bytes", JsonInt(text.size))
        out.put("text", JsonString(text))
        out.put("sections", redisInfoParse(text))
        out
    }

    /** `redis:dbsize`：当前库的键总数（一个 O(1) 的规模感来源，页面顶栏用它） */
    private func dbsizeCmd(args: JsonObject): JsonValue {
        let _ = args
        let sess = this.session()
        let size = redisNumberReply(redisCall(sess, ["DBSIZE"]), "DBSIZE")
        sess.lock.lock()
        let db = sess.db
        sess.lock.unlock()
        let out = JsonObject()
        out.put("db", JsonInt(db))
        out.put("size", JsonInt(size))
        out
    }

    /**
     * `redis:slowlog { count? }`：慢查询日志（`SLOWLOG GET <n>`，n 夹在 1..128）。
     *
     * 没开慢日志的服务器会回空数组——那是**对的答案**，不是错误，别把它翻成失败。
     */
    private func slowlogCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let count = redisClampInt(this.optionalInt(args, "count", 10), 1, 128)
        let reply = redisCall(sess, ["SLOWLOG", "GET", "${count}"])
        let entries = ArrayList<JsonValue>()
        for (it in respItemsOrEmpty(reply)) {
            entries.add(redisSlowlogEntry(it))
        }
        let out = JsonObject()
        out.put("requested", JsonInt(count))
        out.put("count", JsonInt(Int64(entries.size)))
        out.put("entries", JsonArray(entries))
        out
    }

    // ------------------------------------------------------------ 键空间类命令

    /**
     * `redis:scan { cursor?, match?, count?, type? }`：SCAN 一页，并**给每个键补 TYPE 与 TTL**。
     *
     * 为什么要补：浏览列表的用处一半在「这个键是什么、还有多久过期」，而 SCAN 只给键名。
     * 用一次流水线取齐（少一堆往返）；TYPE/TTL 都是 O(1)，不会把一页拖慢。
     *
     * `type` 过滤交给服务端（SCAN 的 TYPE 选项，Redis 6.0+）：老服务端不认会回错误，**那就如实抛**
     * ——退化成「客户端自己过滤」会让页面以为过滤生效了，而返回的条数对不上。
     */
    private func scanCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let cursor = this.optionalString(args, "cursor")
        let pattern = this.optionalString(args, "match")
        let typeFilter = this.optionalString(args, "type")
        let count = redisClampInt(this.optionalInt(args, "count", 100), 1, 1000)
        var parts = ArrayList<String>()
        parts.add("SCAN")
        if (cursor.size > 0) {
            parts.add(cursor)
        } else {
            parts.add("0")
        }
        if (pattern.size > 0) {
            parts.add("MATCH")
            parts.add(pattern)
        }
        parts.add("COUNT")
        parts.add("${count}")
        if (typeFilter.size > 0) {
            parts.add("TYPE")
            parts.add(typeFilter)
        }
        let reply = redisCall(sess, parts.toArray())
        // 回复形状固定是 `[下一个游标, [键 ...]]`：形状不对说明对端不是我以为的东西，当场报
        let top = respItemsOrEmpty(reply)
        if (top.size < 2) {
            throw CommandException("redis: SCAN 回复形状不对（${respBrief(reply)}）")
        }
        let next = respValueText(top[0])
        let keys = ArrayList<String>()
        for (k in respItemsOrEmpty(top[1])) {
            keys.add(respValueText(k))
        }
        let frames = ArrayList<Array<UInt8>>()
        var i: Int64 = 0
        while (i < Int64(keys.size) && i < REDIS_PAGE_MAX) {
            frames.add(respCmd2("TYPE", keys[i]))
            frames.add(respCmd2("TTL", keys[i]))
            i += 1
        }
        let replies = redisCallMany(sess, frames, "TYPE/TTL")
        let entries = ArrayList<JsonValue>()
        i = 0
        while (i < Int64(keys.size)) {
            let o = JsonObject()
            o.put("key", JsonString(keys[i]))
            if (i < REDIS_PAGE_MAX && i * 2 + 1 < Int64(replies.size)) {
                o.put("type", JsonString(respValueText(replies[i * 2])))
                o.put("ttl", JsonInt(redisNumberOr(replies[i * 2 + 1], -1)))
                o.put("enriched", JsonBool(true))
            } else {
                // 超出补全上限的键**如实标注未补全**：页面要么翻页要么调小 count，
                // 不许出现「type=?」这种看着像数据的东西（那比缺字段更容易被误读）
                o.put("type", JsonString(""))
                o.put("ttl", JsonInt(-1))
                o.put("enriched", JsonBool(false))
            }
            entries.add(o)
            i += 1
        }
        let out = JsonObject()
        out.put("cursor", JsonString(next))
        out.put("done", JsonBool(next == "0"))
        out.put("keys", JsonArray(entries))
        out.put("count", JsonInt(Int64(keys.size)))
        out.put("enriched", JsonInt(redisClampInt(Int64(keys.size), 0, REDIS_PAGE_MAX)))
        out.put("countOption", JsonInt(count))
        out
    }

    /** `redis:keyInfo { key }`：TYPE + TTL + 该类型的规模（STRLEN/HLEN/…/XLEN 之一） */
    private func keyInfoCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let key = this.requireString(args, "key")
        let typeName = respValueText(redisCall(sess, ["TYPE", key]))
        let out = JsonObject()
        out.put("key", JsonString(key))
        out.put("type", JsonString(typeName))
        out.put("exists", JsonBool(typeName != "none"))
        if (typeName == "none") {
            // 键不在了就到此为止：再发 TTL / 规模命令只会在日志里制造「这些命令为什么失败」的噪音
            return out
        }
        out.put("ttl", JsonInt(redisNumberOr(redisCall(sess, ["TTL", key]), -1)))
        out.put("size", JsonInt(redisKeySize(sess, key, typeName)))
        out.put("sizeUnit", JsonString(redisKeySizeUnit(typeName)))
        out
    }

    /** `redis:keyRename { key, newKey }`：RENAME（源键不存在时 Redis 回错误，如实抛出） */
    private func keyRenameCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let key = this.requireString(args, "key")
        let newKey = this.requireString(args, "newKey")
        if (key == newKey) {
            throw CommandException("redis: 新旧键名相同，RENAME 会被服务端判为错误（要么改名，要么别改）")
        }
        redisExpectOk(redisCall(sess, ["RENAME", key, newKey]), "RENAME")
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("key", JsonString(key))
        out.put("newKey", JsonString(newKey))
        out
    }

    /** `redis:keyDelete { keys: [...] }`：DEL 一把（一次发完，回的是真删掉的条数） */
    private func keyDeleteCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let keys = this.requireStringArray(args, "keys")
        var parts = ArrayList<String>()
        parts.add("DEL")
        for (k in keys) {
            parts.add(k)
        }
        let deleted = redisNumberReply(redisCall(sess, parts.toArray()), "DEL")
        let out = JsonObject()
        out.put("requested", JsonInt(Int64(keys.size)))
        out.put("deleted", JsonInt(deleted))
        out
    }

    /** `redis:keyExpire { key, seconds }`：EXPIRE（seconds=0 即立刻过期，允许；负数拒） */
    private func keyExpireCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let key = this.requireString(args, "key")
        let seconds = this.optionalInt(args, "seconds", 0)
        if (seconds < 0) {
            throw CommandException("redis: seconds 非法（不能为负；0 表示立刻过期）")
        }
        let applied = redisNumberReply(redisCall(sess, ["EXPIRE", key, "${seconds}"]), "EXPIRE")
        let out = JsonObject()
        out.put("key", JsonString(key))
        out.put("seconds", JsonInt(seconds))
        out.put("applied", JsonBool(applied == 1))
        out
    }

    /** `redis:keyPersist { key }`：PERSIST（去掉过期时间；键本身没了或原本就没过期时间都回 0） */
    private func keyPersistCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let key = this.requireString(args, "key")
        let applied = redisNumberReply(redisCall(sess, ["PERSIST", key]), "PERSIST")
        let out = JsonObject()
        out.put("key", JsonString(key))
        out.put("applied", JsonBool(applied == 1))
        out
    }

    // ------------------------------------------------------------ 取值类命令

    /**
     * `redis:value { key, cursor?, count?, match?, offset?, limit? }`：按类型取值。
     *
     * 每种类型走**它自己的分页语义**（hash/set 是游标，list/zset/stream 是区间，string 是一次取回），
     * 不硬套一种：硬套会让大键一次拉全量（页面卡死），或让游标型结构没法翻页。
     * 返回体里的 `mode`（whole / cursor / range / missing / unsupported）说明走的是哪条路，页面据此翻页。
     */
    private func valueCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let key = this.requireString(args, "key")
        let typeName = respValueText(redisCall(sess, ["TYPE", key]))
        let out = JsonObject()
        out.put("key", JsonString(key))
        out.put("type", JsonString(typeName))
        out.put("exists", JsonBool(typeName != "none"))
        if (typeName == "none") {
            out.put("mode", JsonString("missing"))
            return out
        }
        out.put("ttl", JsonInt(redisNumberOr(redisCall(sess, ["TTL", key]), -1)))
        if (typeName == REDIS_TYPE_STRING) {
            this.stringValue(sess, key, out)
        } else if (typeName == REDIS_TYPE_HASH) {
            this.hashValue(args, sess, key, out)
        } else if (typeName == REDIS_TYPE_SET) {
            this.setValue(args, sess, key, out)
        } else if (typeName == REDIS_TYPE_LIST) {
            this.listValue(args, sess, key, out)
        } else if (typeName == REDIS_TYPE_ZSET) {
            this.zsetValue(args, sess, key, out)
        } else if (typeName == REDIS_TYPE_STREAM) {
            this.streamValue(args, sess, key, out)
        } else {
            // 认不出的类型（新版本可能引入）：如实说「这个版本的工具还不认识它」，**不猜成 string**
            out.put("mode", JsonString("unsupported"))
            out.put("note", JsonString("这个类型当前工具还不支持取值（type=${typeName}）"))
        }
        out
    }

    /** 字符串：STRLEN + GET（一次取回；超展示上限只给前缀并置 truncated，原文长度照实报） */
    private func stringValue(sess: RedisSession, key: String, out: JsonObject): Unit {
        out.put("mode", JsonString("whole"))
        out.put("length", JsonInt(redisNumberReply(redisCall(sess, ["STRLEN", key]), "STRLEN")))
        match (respBytes(redisCall(sess, ["GET", key]))) {
            case Some(b) => out.put("value", redisValueDisplay(b))
            case None =>
                // GET 对不存在的键回 nil：TYPE 刚说是 string，说明两次命令之间键被删了——如实说，别假装是空串
                out.put("exists", JsonBool(false))
                out.put("mode", JsonString("missing"))
                out.put("note", JsonString("键在两次命令之间消失了（TYPE 说是 string，GET 回的是 nil）"))
        }
    }

    /** 哈希：HSCAN 游标分页（游标由页面原样带回来），总数用 HLEN 补 */
    private func hashValue(args: JsonObject, sess: RedisSession, key: String, out: JsonObject): Unit {
        out.put("mode", JsonString("cursor"))
        let top = respItemsOrEmpty(redisCall(sess, this.scanParts("HSCAN", key, args)))
        if (top.size < 2) {
            throw CommandException("redis: HSCAN 回复形状不对（${respBrief(redisCall(sess, ["HSCAN", key]))})")
        }
        out.put("cursor", JsonString(respValueText(top[0])))
        out.put("total", JsonInt(redisNumberOr(redisCall(sess, ["HLEN", key]), -1)))
        let entries = ArrayList<JsonValue>()
        for (pair in respPairs(top[1])) {
            let e = JsonObject()
            e.put("field", JsonString(pair[0]))
            e.put("value", JsonString(pair[1]))
            entries.add(e)
        }
        out.put("entries", JsonArray(entries))
        out.put("count", JsonInt(Int64(entries.size)))
    }

    /** 集合：SSCAN 游标分页，总数用 SCARD 补 */
    private func setValue(args: JsonObject, sess: RedisSession, key: String, out: JsonObject): Unit {
        out.put("mode", JsonString("cursor"))
        let top = respItemsOrEmpty(redisCall(sess, this.scanParts("SSCAN", key, args)))
        if (top.size < 2) {
            throw CommandException("redis: SSCAN 回复形状不对（${respBrief(redisCall(sess, ["SSCAN", key]))})")
        }
        out.put("cursor", JsonString(respValueText(top[0])))
        out.put("total", JsonInt(redisNumberOr(redisCall(sess, ["SCARD", key]), -1)))
        let members = ArrayList<JsonValue>()
        for (m in respItemsOrEmpty(top[1])) {
            members.add(JsonString(respValueText(m)))
        }
        out.put("members", JsonArray(members))
        out.put("count", JsonInt(Int64(members.size)))
    }

    /** 列表：区间读（offset + limit），总长用 LLEN 给（页面据此画分页） */
    private func listValue(args: JsonObject, sess: RedisSession, key: String, out: JsonObject): Unit {
        out.put("mode", JsonString("range"))
        let total = redisNumberReply(redisCall(sess, ["LLEN", key]), "LLEN")
        out.put("total", JsonInt(total))
        if (total == 0) {
            out.put("items", JsonArray(ArrayList<JsonValue>()))
            out.put("offset", JsonInt(0))
            out.put("limit", JsonInt(0))
            out.put("note", JsonString("列表是空的（LLEN 为 0）"))
            return
        }
        let offset = redisClampInt(this.optionalInt(args, "offset", 0), 0, 9007199254740991)
        let limit = redisClampInt(this.optionalInt(args, "limit", 50), 1, REDIS_PAGE_MAX)
        var stopIdx = offset + limit - 1
        if (stopIdx > total - 1) {
            stopIdx = total - 1
        }
        let items = ArrayList<JsonValue>()
        for (it in respItemsOrEmpty(redisCall(sess, ["LRANGE", key, "${offset}", "${stopIdx}"]))) {
            items.add(JsonString(respValueText(it)))
        }
        out.put("items", JsonArray(items))
        out.put("offset", JsonInt(offset))
        out.put("limit", JsonInt(stopIdx - offset + 1))
        out.put("note", JsonString("LRANGE ${offset} .. ${stopIdx}"))
    }

    /** 有序集合：区间读 + WITHSCORES（回复是 `[成员, 分值, ...]` 的扁平对） */
    private func zsetValue(args: JsonObject, sess: RedisSession, key: String, out: JsonObject): Unit {
        out.put("mode", JsonString("range"))
        let total = redisNumberReply(redisCall(sess, ["ZCARD", key]), "ZCARD")
        out.put("total", JsonInt(total))
        if (total == 0) {
            out.put("entries", JsonArray(ArrayList<JsonValue>()))
            out.put("offset", JsonInt(0))
            out.put("limit", JsonInt(0))
            out.put("note", JsonString("有序集合是空的（ZCARD 为 0）"))
            return
        }
        let offset = redisClampInt(this.optionalInt(args, "offset", 0), 0, 9007199254740991)
        let limit = redisClampInt(this.optionalInt(args, "limit", 50), 1, REDIS_PAGE_MAX)
        var stopIdx = offset + limit - 1
        if (stopIdx > total - 1) {
            stopIdx = total - 1
        }
        let entries = ArrayList<JsonValue>()
        for (pair in respPairs(redisCall(sess, ["ZRANGE", key, "${offset}", "${stopIdx}", "WITHSCORES"]))) {
            let e = JsonObject()
            e.put("member", JsonString(pair[0]))
            e.put("score", JsonString(pair[1]))
            entries.add(e)
        }
        out.put("entries", JsonArray(entries))
        out.put("offset", JsonInt(offset))
        out.put("limit", JsonInt(stopIdx - offset + 1))
    }

    /** 流：XRANGE 一页（`[id, [字段, 值, ...]]` 的嵌套形状），总数用 XLEN 补 */
    private func streamValue(args: JsonObject, sess: RedisSession, key: String, out: JsonObject): Unit {
        out.put("mode", JsonString("range"))
        out.put("total", JsonInt(redisNumberReply(redisCall(sess, ["XLEN", key]), "XLEN")))
        let count = redisClampInt(this.optionalInt(args, "count", 20), 1, REDIS_PAGE_MAX)
        let reply = redisCall(sess, ["XRANGE", key, "-", "+", "COUNT", "${count}"])
        let entries = ArrayList<JsonValue>()
        for (entry in respItemsOrEmpty(reply)) {
            let pair = respItemsOrEmpty(entry)
            let e = JsonObject()
            if (pair.size >= 2) {
                e.put("id", JsonString(respValueText(pair[0])))
                let fields = ArrayList<JsonValue>()
                for (fp in respPairs(pair[1])) {
                    let f = JsonObject()
                    f.put("field", JsonString(fp[0]))
                    f.put("value", JsonString(fp[1]))
                    fields.add(f)
                }
                e.put("fields", JsonArray(fields))
            } else {
                // 形状不认识就原样把人看的渲染给它，别丢——排查时「知道收到了什么怪东西」比好看重要
                e.put("raw", JsonString(respRender(entry)))
            }
            entries.add(e)
        }
        out.put("entries", JsonArray(entries))
        out.put("count", JsonInt(Int64(entries.size)))
    }

    /** HSCAN / SSCAN 的公共参数尾：`<key> <cursor> [MATCH 模式] COUNT 条数` */
    private func scanParts(cmd: String, key: String, args: JsonObject): Array<String> {
        let cursor = this.optionalString(args, "cursor")
        let pattern = this.optionalString(args, "match")
        let count = redisClampInt(this.optionalInt(args, "count", 100), 1, 1000)
        var parts = ArrayList<String>()
        parts.add(cmd)
        parts.add(key)
        if (cursor.size > 0) {
            parts.add(cursor)
        } else {
            parts.add("0")
        }
        if (pattern.size > 0) {
            parts.add("MATCH")
            parts.add(pattern)
        }
        parts.add("COUNT")
        parts.add("${count}")
        return parts.toArray()
    }

    // ------------------------------------------------------------ 改值类命令

    /**
     * `redis:valueWrite { key, type, op, ... }`：按类型改数据。
     *
     * `type` 必填且**不由服务端探测**：让页面明确说出它以为是哪种类型——先探测再改会有 TOCTOU
     * （两次命令之间类型可能已被别人换掉，改的就成另一件事了）。认识的 op 是白名单，
     * **不认识的 op 一律拒**，页面可控的字符串不进任何分支。
     */
    private func valueWriteCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let key = this.requireString(args, "key")
        let typeName = this.requireString(args, "type")
        let op = this.requireString(args, "op")
        var reply = RespValue.Simple("")
        if (typeName == REDIS_TYPE_STRING) {
            reply = this.writeString(args, sess, key, op)
        } else if (typeName == REDIS_TYPE_HASH) {
            reply = this.writeHash(args, sess, key, op)
        } else if (typeName == REDIS_TYPE_LIST) {
            reply = this.writeList(args, sess, key, op)
        } else if (typeName == REDIS_TYPE_SET) {
            reply = this.writeSet(args, sess, key, op)
        } else if (typeName == REDIS_TYPE_ZSET) {
            reply = this.writeZset(args, sess, key, op)
        } else if (typeName == REDIS_TYPE_STREAM) {
            reply = this.writeStream(args, sess, key, op)
        } else {
            throw CommandException("redis: type 非法（支持 string/hash/list/set/zset/stream，收到 ${typeName}）")
        }
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("key", JsonString(key))
        out.put("type", JsonString(typeName))
        out.put("op", JsonString(op))
        out.put("reply", JsonString(respBrief(reply)))
        match (reply) {
            case Number(n) => out.put("number", JsonInt(n))
            case Simple(s) => out.put("text", JsonString(s))
            case Bulk(Some(b)) => out.put("value", JsonString(respSafeText(b)))
            case Bulk(None) => out.put("value", JsonString(""))
            case _ => ()
        }
        out
    }

    private func writeString(args: JsonObject, sess: RedisSession, key: String, op: String): RespValue {
        let v = this.valueBytes(args, "value", "valueHex")
        if (op == "set") {
            return redisCallFrame(sess, respEncodeCommandRaw([redisRaw("SET"), redisRaw(key), v]), "SET")
        }
        if (op == "append") {
            return redisCallFrame(sess, respEncodeCommandRaw([redisRaw("APPEND"), redisRaw(key), v]), "APPEND")
        }
        throw CommandException("redis: string 不支持的 op（可用：set / append）")
    }

    private func writeHash(args: JsonObject, sess: RedisSession, key: String, op: String): RespValue {
        let field = this.requireString(args, "field")
        if (op == "hset") {
            let v = this.valueBytes(args, "value", "valueHex")
            return redisCallFrame(sess,
                respEncodeCommandRaw([redisRaw("HSET"), redisRaw(key), redisRaw(field), v]), "HSET")
        }
        if (op == "hdel") {
            return redisCall(sess, ["HDEL", key, field])
        }
        throw CommandException("redis: hash 不支持的 op（可用：hset / hdel）")
    }

    private func writeList(args: JsonObject, sess: RedisSession, key: String, op: String): RespValue {
        if (op == "push") {
            let v = this.valueBytes(args, "value", "valueHex")
            let head = this.optionalBool(args, "head", false)
            var cmd = "RPUSH"
            if (head) {
                cmd = "LPUSH"
            }
            return redisCallFrame(sess, respEncodeCommandRaw([redisRaw(cmd), redisRaw(key), v]), cmd)
        }
        if (op == "lset") {
            let index = this.optionalInt(args, "index", 0)
            if (index < 0) {
                throw CommandException("redis: lset 的 index 非法（不能为负）")
            }
            let v = this.valueBytes(args, "value", "valueHex")
            return redisCallFrame(sess,
                respEncodeCommandRaw([redisRaw("LSET"), redisRaw(key), redisRaw("${index}"), v]), "LSET")
        }
        if (op == "lrem") {
            let count = redisClampInt(this.optionalInt(args, "count", 0), -9007199254740991, 9007199254740991)
            let v = this.valueBytes(args, "value", "valueHex")
            return redisCallFrame(sess,
                respEncodeCommandRaw([redisRaw("LREM"), redisRaw(key), redisRaw("${count}"), v]), "LREM")
        }
        if (op == "pop") {
            let head = this.optionalBool(args, "head", false)
            var cmd = "RPOP"
            if (head) {
                cmd = "LPOP"
            }
            return redisCall(sess, [cmd, key])
        }
        throw CommandException("redis: list 不支持的 op（可用：push / lset / lrem / pop）")
    }

    private func writeSet(args: JsonObject, sess: RedisSession, key: String, op: String): RespValue {
        let member = this.valueBytes(args, "member", "memberHex")
        if (op == "sadd") {
            return redisCallFrame(sess,
                respEncodeCommandRaw([redisRaw("SADD"), redisRaw(key), member]), "SADD")
        }
        if (op == "srem") {
            return redisCallFrame(sess,
                respEncodeCommandRaw([redisRaw("SREM"), redisRaw(key), member]), "SREM")
        }
        throw CommandException("redis: set 不支持的 op（可用：sadd / srem）")
    }

    private func writeZset(args: JsonObject, sess: RedisSession, key: String, op: String): RespValue {
        let member = this.valueBytes(args, "member", "memberHex")
        if (op == "zadd") {
            // 分值走文本：Redis 自己认浮点文本（用 Double 转字符串反而会因精度写法不同被它当非法输入）
            let score = this.optionalString(args, "score")
            if (score.size == 0) {
                throw CommandException("redis: zadd 需要 score（例如 \"1.5\"）")
            }
            return redisCallFrame(sess,
                respEncodeCommandRaw([redisRaw("ZADD"), redisRaw(key), redisRaw(score), member]), "ZADD")
        }
        if (op == "zrem") {
            return redisCallFrame(sess,
                respEncodeCommandRaw([redisRaw("ZREM"), redisRaw(key), member]), "ZREM")
        }
        throw CommandException("redis: zset 不支持的 op（可用：zadd / zrem）")
    }

    private func writeStream(args: JsonObject, sess: RedisSession, key: String, op: String): RespValue {
        if (op != "xadd") {
            throw CommandException("redis: stream 不支持的 op（可用：xadd）")
        }
        let fields = this.requireStringArray(args, "fields")
        if (fields.size % 2 != 0) {
            throw CommandException("redis: xadd 的 fields 必须是「名, 值」成对的偶数个")
        }
        var id = this.optionalString(args, "id")
        if (id.size == 0) {
            id = "*"
        }
        let raws = ArrayList<Array<UInt8>>()
        raws.add(redisRaw("XADD"))
        raws.add(redisRaw(key))
        raws.add(redisRaw(id))
        var i: Int64 = 0
        while (i < Int64(fields.size)) {
            raws.add(redisRaw(fields[i]))
            raws.add(redisRaw(fields[i + 1]))
            i += 2
        }
        return redisCallFrame(sess, respEncodeCommandRaw(raws.toArray()), "XADD")
    }

    // ------------------------------------------------------------ 发布订阅类命令

    /**
     * `redis:subscribe { channels: [...], patterns?: [...] }`：订阅频道 / 模式。
     *
     * 订阅在**独立的一条连接**上做（协议：订阅状态下的连接只能收推送与发订阅类命令），
     * 读侧由 `redisSubLoop` 线程独占。请求写出后**有界等待回执**：到点没齐就如实报 `pending`
     * ——回执在路上但没到是真实状态，报 pending 比假装成功诚实（页面能凭它再查一次状态）。
     */
    private func subscribeCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let channels = this.optionalStringArray(args, "channels")
        let patterns = this.optionalStringArray(args, "patterns")
        if (channels.size == 0 && patterns.size == 0) {
            throw CommandException("redis: 至少要给 channels 或 patterns 之一")
        }
        this.ensureSubSocket(sess)
        // 只订阅「还没订过的」：重复 SUBSCRIBE 服务端会认，但那会让回执计数与去重都没必要
        let frames = ArrayList<Array<UInt8>>()
        let addedChannels = ArrayList<String>()
        let addedPatterns = ArrayList<String>()
        sess.lock.lock()
        for (c in channels) {
            if (!redisListHas(sess.channels, c)) {
                frames.add(respCmd2("SUBSCRIBE", c))
                sess.channels.add(c)
                addedChannels.add(c)
            }
        }
        for (p in patterns) {
            if (!redisListHas(sess.patterns, p)) {
                frames.add(respCmd2("PSUBSCRIBE", p))
                sess.patterns.add(p)
                addedPatterns.add(p)
            }
        }
        sess.subPendingAcks += Int64(frames.size)
        sess.lock.unlock()
        this.writeSubFrames(sess, frames)
        let allAcked = this.waitSubAcks(sess, REDIS_SUB_ACK_TIMEOUT_MS)
        sess.lock.lock()
        let pending = sess.subPendingAcks
        let channelsJson = redisStringArray(sess.channels)
        let patternsJson = redisStringArray(sess.patterns)
        sess.lock.unlock()
        if (!allAcked) {
            eprintln("[cj-tauri] redis sub: 订阅回执未在 ${REDIS_SUB_ACK_TIMEOUT_MS}ms 内到齐" +
                "（pending=${pending}），如实上报，不假装订阅成功")
        }
        redisEmitState(sess)
        let out = JsonObject()
        out.put("ok", JsonBool(allAcked))
        out.put("pending", JsonInt(pending))
        out.put("addedChannels", redisStringArray(addedChannels))
        out.put("addedPatterns", redisStringArray(addedPatterns))
        out.put("channels", channelsJson)
        out.put("patterns", patternsJson)
        out.put("note", JsonString("ok=false 表示有回执未在限时内到齐（pending 是没到的那几条）；" +
            "事件 redis:message 与拉取 redis:messages 两条通道都能拿到消息"))
        out
    }

    /**
     * `redis:unsubscribe { channels?: [...], patterns?: [...] }`：退订。
     *
     * 两个数组都不给 = **退订全部**（也就是把订阅连接收掉）。频道全退完时主动关闭订阅连接与读线程：
     * 留一条什么都不订的连接只会在服务器侧白占一个连接位。
     */
    private func unsubscribeCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let channels = this.optionalStringArray(args, "channels")
        let patterns = this.optionalStringArray(args, "patterns")
        let all = channels.size == 0 && patterns.size == 0
        var channelList = channels
        var patternList = patterns
        sess.lock.lock()
        if (all) {
            for (c in sess.channels) {
                channelList.add(c)
            }
            for (p in sess.patterns) {
                patternList.add(p)
            }
        }
        let frames = ArrayList<Array<UInt8>>()
        for (c in channelList) {
            if (redisListHas(sess.channels, c)) {
                frames.add(respCmd2("UNSUBSCRIBE", c))
            }
        }
        for (p in patternList) {
            if (redisListHas(sess.patterns, p)) {
                frames.add(respCmd2("PUNSUBSCRIBE", p))
            }
        }
        // 直接按「退完还剩什么」重建两张表（就地删元素要按索引倒着删，重建更好读也更不容易错）
        let keepChannels = ArrayList<String>()
        for (c in sess.channels) {
            if (!redisListHas(channelList, c)) {
                keepChannels.add(c)
            }
        }
        let keepPatterns = ArrayList<String>()
        for (p in sess.patterns) {
            if (!redisListHas(patternList, p)) {
                keepPatterns.add(p)
            }
        }
        sess.channels = keepChannels
        sess.patterns = keepPatterns
        let leftChannels = sess.channels.size
        let leftPatterns = sess.patterns.size
        let hasSub = match (sess.sub) {
            case Some(_) => true
            case None => false
        }
        if (leftChannels == 0 && leftPatterns == 0) {
            sess.stopSubRequested = true
        }
        sess.subPendingAcks += Int64(frames.size)
        sess.lock.unlock()
        if (!hasSub) {
            // 本来就没有订阅连接：退订是幂等的，如实说「没什么可退」而不是报错
            let o = JsonObject()
            o.put("ok", JsonBool(true))
            o.put("unsubscribed", JsonInt(0))
            o.put("channels", JsonArray(ArrayList<JsonValue>()))
            o.put("patterns", JsonArray(ArrayList<JsonValue>()))
            o.put("note", JsonString("没有活跃的订阅连接（或已经全退完），这次没有可退的订阅"))
            return o
        }
        this.writeSubFrames(sess, frames)
        if (leftChannels == 0 && leftPatterns == 0) {
            // 全退完：等读线程收尾再关连接。**先置停止旗标再关**，否则读线程会把「主动关闭」
            // 记成一次真故障（那条错读会把好好的会话判成 error）
            this.waitSubExit(sess)
            sess.lock.lock()
            let subSock = sess.sub
            sess.sub = None
            sess.subAlive = false
            sess.subPendingAcks = 0
            sess.lock.unlock()
            match (subSock) {
                case Some(s) => redisCloseQuiet(s)
                case None => ()
            }
            eprintln("[cj-tauri] redis sub: 订阅已全部退掉，订阅连接与读线程已收")
        } else {
            let _ = this.waitSubAcks(sess, REDIS_SUB_ACK_TIMEOUT_MS)
        }
        redisEmitState(sess)
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("unsubscribed", JsonInt(Int64(frames.size)))
        out.put("channels", JsonArray(ArrayList<JsonValue>()))
        out.put("patterns", JsonArray(ArrayList<JsonValue>()))
        out.put("note", JsonString("remaining 见 redis:status 的 channels / patterns"))
        out
    }

    /**
     * `redis:publish { channel, message | messageHex }`：发布一条消息，回的是**收到它的订阅者数**。
     *
     * 这个数字来自服务端，不含「本端另一条订阅连接」之外的自己——本端订阅连接算一个订阅者，
     * 所以自己订阅了自己的频道时，回值通常 ≥1，别把这个数当成「别人收到了」。
     */
    private func publishCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let channel = this.requireString(args, "channel")
        let payload = this.valueBytes(args, "message", "messageHex")
        let receivers = redisNumberReply(
            redisCallFrame(sess, respEncodeCommandRaw([redisRaw("PUBLISH"), redisRaw(channel), payload]), "PUBLISH"),
            "PUBLISH")
        eprintln("[cj-tauri] redis publish: channel=${channel} bytes=${payload.size} receivers=${receivers}")
        let out = JsonObject()
        out.put("channel", JsonString(channel))
        out.put("bytes", JsonInt(Int64(payload.size)))
        out.put("receivers", JsonInt(receivers))
        out
    }

    /**
     * `redis:messages { limit? }`：把缓冲里的订阅报文**取走**（取走即清，与 MQTT 的 `recent` 同款，D-015）。
     *
     * 为什么留这条拉取通道：事件可能丢（页面没在监听 / 清单没声明 `events` / 页面正在重载），
     * 而缓冲还在——页面回来一拉就能补上。`dropped` 是「上次拉取以来因缓冲满丢掉的条数」，
     * 如实报，不假装无损。
     */
    private func messagesCmd(args: JsonObject): JsonValue {
        let sess = this.session()
        let limit = redisClampInt(this.optionalInt(args, "limit", REDIS_RECENT_LIMIT), 1, REDIS_RECENT_LIMIT)
        let taken = ArrayList<JsonValue>()
        var dropped: Int64 = 0
        sess.lock.lock()
        let take = redisClampInt(Int64(sess.recent.size), 0, limit)
        var i: Int64 = 0
        while (i < take) {
            taken.add(sess.recent[i])
            i += 1
        }
        let keep = ArrayList<JsonValue>()
        i = take
        while (i < sess.recent.size) {
            keep.add(sess.recent[i])
            i += 1
        }
        sess.recent = keep
        dropped = sess.dropped
        sess.dropped = 0
        sess.lock.unlock()
        let out = JsonObject()
        out.put("count", JsonInt(Int64(taken.size)))
        out.put("dropped", JsonInt(dropped))
        out.put("messages", JsonArray(taken))
        out.put("note", JsonString("取走即清；dropped = 上次拉取以来因缓冲满丢弃的条数"))
        out
    }

    // ------------------------------------------------------------ 订阅连接与线程收尾

    /**
     * 确保订阅连接在位：没有就新建（含 AUTH，**不做 SELECT**——发布订阅与库号无关）、
     * 装进会话、起读线程。建连与握手在**调用线程**上同步做（此时还没有读线程，不会有第二个读者）。
     */
    private func ensureSubSocket(sess: RedisSession): Unit {
        sess.lock.lock()
        let has = match (sess.sub) {
            case Some(_) => true
            case None => false
        }
        sess.lock.unlock()
        if (has) {
            return
        }
        let sock = redisOpenSocket(sess, REDIS_SUB_TICK_MS)
        try {
            redisHandshake(sess, sock, sess.subReader, false)
        } catch (e: CommandException) {
            redisCloseQuiet(sock)
            redisFailSession(sess, "订阅连接握手失败：${e.message}")
            throw e
        }
        sess.lock.lock()
        sess.sub = Some(sock)
        // 新连接：解析器里可能残留上一条连接的半截字节，必须丢掉，否则第一帧就错位
        sess.subReader = RespReader()
        sess.stopSubRequested = false
        sess.subAlive = true
        sess.lock.unlock()
        eprintln("[cj-tauri] redis sub: 订阅连接已建立（读线程接管读侧）")
        spawn { => redisSubLoop(sess) }
        redisEmitState(sess)
    }

    /** 把订阅类命令写进订阅连接（**加 callLock**）：命令线程之间要串行写，否则两段帧会交错 */
    private func writeSubFrames(sess: RedisSession, frames: ArrayList<Array<UInt8>>): Unit {
        if (frames.size == 0) {
            return
        }
        sess.callLock.lock()
        var target: Option<TcpSocket> = None
        sess.lock.lock()
        target = sess.sub
        sess.lock.unlock()
        var wrote = false
        match (target) {
            case Some(sock) =>
                try {
                    for (f in frames) {
                        redisWriteFrame(sess, sock, f)
                    }
                    wrote = true
                } catch (e: Exception) {
                    sess.callLock.unlock()
                    throw e
                }
            case None => ()
        }
        sess.callLock.unlock()
        if (!wrote) {
            throw CommandException("redis: 订阅连接不在了（可能刚被断开），请重试 subscribe")
        }
    }

    /** 有界等订阅回执：返回 true 表示全齐（最多等 timeoutMs，不把命令线程挂住） */
    private func waitSubAcks(sess: RedisSession, timeoutMs: Int64): Bool {
        let started = DateTime.now()
        var ok = false
        var done = false
        // 不用 `while (true)` + `return`：仓颉不认这种发散写法（尾表达式被判 Unit），循环条件写显式布尔
        while (!done) {
            sess.lock.lock()
            let pending = sess.subPendingAcks
            sess.lock.unlock()
            if (pending <= 0) {
                ok = true
                done = true
            } else if ((DateTime.now() - started).toMilliseconds() > timeoutMs) {
                done = true
            } else {
                sleep(Duration.millisecond * 20)
            }
        }
        ok
    }

    /**
     * 有界等订阅读线程退出（上限 REDIS_SUB_EXIT_WAIT_MS）。
     *
     * 等不到就**照直继续**并打一行 stderr：命令线程不能为了收尾无限期挂住（与 MQTT 的
     * `closePrevious` 同一取舍——收尾可以慢，但不能把命令卡死）。
     */
    private func waitSubExit(sess: RedisSession): Bool {
        let started = DateTime.now()
        var exited = false
        var done = false
        while (!done) {
            sess.lock.lock()
            let alive = sess.subAlive
            sess.lock.unlock()
            if (!alive) {
                exited = true
                done = true
            } else if ((DateTime.now() - started).toMilliseconds() > REDIS_SUB_EXIT_WAIT_MS) {
                eprintln("[cj-tauri] redis sub: 读线程未在 ${REDIS_SUB_EXIT_WAIT_MS}ms 内退出，收尾继续（不无限等）")
                done = true
            } else {
                sleep(Duration.millisecond * 20)
            }
        }
        exited
    }

    /**
     * 重连前收掉旧会话：置停止旗标 → 等读线程退出 → 关两条 socket。
     *
     * **顺序不能反**：先关 socket 的话，正阻塞在 read 上的读线程会收到一次错读，
     * 那条错读若被当成真故障，就会把一次「主动重连」记成 error（还会往页面推一条 error 状态）。
     */
    private func closePrevious(): Unit {
        this.lock.lock()
        let old = this.current
        this.lock.unlock()
        old.lock.lock()
        old.stopSubRequested = true
        if (old.state == "connected" || old.state == "connecting") {
            old.state = "closed"
        }
        let subSock = old.sub
        let cmdSock = old.cmd
        old.sub = None
        old.cmd = None
        old.subAlive = false
        old.subPendingAcks = 0
        old.lock.unlock()
        let exited = this.waitSubExit(old)
        match (subSock) {
            case Some(s) => redisCloseQuiet(s)
            case None => ()
        }
        match (cmdSock) {
            case Some(s) => redisCloseQuiet(s)
            case None => ()
        }
        if (!exited) {
            eprintln("[cj-tauri] redis: 旧会话的订阅线程未按时退出，socket 已关（状态泄漏一次，好过卡死命令）")
        }
    }
}

// ------------------------------------------------------------ 订阅读线程

/**
 * 订阅读线程：只做一件事——从订阅连接收推送，翻成 `redis:message` 事件 + 缓冲。
 *
 * 它**不写**这条 socket 的业务数据（订阅 / 退订都由命令侧写），所以两个方向不会互相踩；
 * 共享的只有会话字段，一律在 `lock` 下访问。读超时是**正常的**（REDIS_SUB_TICK_MS 就是时基），
 * 借它回头查一次「要不要停」；只有真异常 / 读到 0 字节才判连接坏。
 *
 * 停止旗标由命令侧置（退订全部 / 重连收尾），异常与读零这两条路都**先查旗标**再定性：
 * 主动关闭必然让阻塞中的 read 报错，那条错读要是被记成真故障，一次「正常退订」就会在页面上显示成 error。
 */
func redisSubLoop(sess: RedisSession): Unit {
    var alive = true
    while (alive) {
        sess.lock.lock()
        let stop = sess.stopSubRequested
        let sock = sess.sub
        sess.lock.unlock()
        if (stop) {
            alive = false
        } else {
            match (sock) {
                case None => alive = false
                case Some(x) =>
                    let buf = Array<UInt8>(REDIS_READ_CHUNK, repeat: 0)
                    var got: Int64 = -1
                    var failed = false
                    try {
                        got = x.read(buf)
                    } catch (e: SocketTimeoutException) {
                        got = -1
                    } catch (e: Exception) {
                        sess.lock.lock()
                        let stopping = sess.stopSubRequested
                        sess.lock.unlock()
                        if (stopping) {
                            alive = false
                        } else {
                            failed = true
                            redisFailSession(sess, "订阅连接读取失败：${e.message}")
                        }
                    }
                    if (failed) {
                        alive = false
                    } else if (got > 0) {
                        sess.lock.lock()
                        sess.subReader.feed(buf[0..got])
                        sess.lastRxAt = DateTime.now()
                        sess.lock.unlock()
                        redisSubDrain(sess)
                    } else if (got == 0) {
                        sess.lock.lock()
                        let stopping = sess.stopSubRequested
                        sess.lock.unlock()
                        if (stopping) {
                            alive = false
                        } else {
                            redisFailSession(sess, "订阅连接被对端关闭")
                            alive = false
                        }
                    }
                    // got < 0（读超时）：没数据而已，回头查旗标
            }
        }
    }
    sess.lock.lock()
    sess.subAlive = false
    sess.subPendingAcks = 0
    sess.lock.unlock()
    eprintln("[cj-tauri] redis sub: 读线程结束（订阅连接已收）")
    redisEmitState(sess)
}

/**
 * 把读线程刚喂进解析器的字节尽量读干：每条完整回复按「回执 / 推送」分流。
 *
 * 解析器是**增量**的（`respTryRead` 三态），所以这里可以一次收多条，也可以只收半条留着等下一批。
 * 畸形只落一行 stderr 并**停掉这条连接**：RESP2 下收到不符合语法的字节说明双方已经不同步，
 * 继续猜下去只会把后面的每一帧都认错（不猜意图，与 MQTT 解码层同款）。
 */
func redisSubDrain(sess: RedisSession): Unit {
    var running = true
    while (running) {
        sess.lock.lock()
        let r = sess.subReader.respTryRead()
        sess.lock.unlock()
        match (r) {
            case RespRead.Value(v) => redisSubDispatch(sess, v)
            case RespRead.Malformed(m) =>
                redisFailSession(sess, "订阅连接收到不符合 RESP2 的内容：${m}")
                running = false
            case RespRead.Incomplete => running = false
        }
    }
}

/**
 * 一条订阅推送 / 回执的分流。RESP2 下就这几种形状：
 *   `[message, 频道, 正文]` / `[pmessage, 模式, 频道, 正文]`（推送）
 *   `[subscribe|unsubscribe|psubscribe|punsubscribe, 名字, 当前订阅数]`（回执）
 *
 * 认不出的形状**只落一行 stderr**：对端可能只是多说了句话（例如新版本的额外通知），
 * 为这个把会话判坏，代价比少显示一条消息大得多。
 */
func redisSubDispatch(sess: RedisSession, v: RespValue): Unit {
    let items = respItemsOrEmpty(v)
    if (items.size == 0) {
        eprintln("[cj-tauri] redis sub: 收到空的推送数组（未处理）")
        return
    }
    let kind = respValueText(items[0])
    if (kind == "pmessage" && items.size >= 4) {
        redisSubMessage(sess, respValueText(items[1]), respValueText(items[2]), redisPushBytes(items[3]))
    } else if (kind == "message" && items.size >= 3) {
        redisSubMessage(sess, "", respValueText(items[1]), redisPushBytes(items[2]))
    } else if (kind == "subscribe" || kind == "psubscribe" ||
        kind == "unsubscribe" || kind == "punsubscribe") {
        sess.lock.lock()
        if (sess.subPendingAcks > 0) {
            sess.subPendingAcks -= 1
        }
        let pending = sess.subPendingAcks
        sess.lock.unlock()
        var count = "?"
        var who = ""
        if (items.size >= 2) {
            who = respValueText(items[1])
        }
        if (items.size >= 3) {
            count = respValueText(items[2])
        }
        eprintln("[cj-tauri] redis sub: ${kind} ${who}（该连接当前订阅数=${count}, 待确认=${pending}）")
    } else {
        eprintln("[cj-tauri] redis sub: 收到认不出的推送形状 ${respBrief(v)}（未处理）")
    }
}

/** 推送里的正文按**字节**取（binary 安全）：bulk 给原字节，其它形状退回它的文本字节 */
func redisPushBytes(v: RespValue): Array<UInt8> {
    match (v) {
        case Bulk(Some(b)) => return b
        case _ => return respValueText(v).toArray()
    }
}

/**
 * 记一条推送：正文超上限先截断（进缓冲与进事件的是**同一份**，页面两条通道看到必须一致），
 * 再交给 `redisRecordMessage` 完成「seq → 缓冲 → 事件」。正文另附 hex 供页面原样回写。
 */
func redisSubMessage(sess: RedisSession, pattern: String, channel: String, raw: Array<UInt8>): Unit {
    let total = Int64(raw.size)
    let cut = redisClampInt(total, 0, REDIS_RECENT_BODY_LIMIT)
    let shown = raw[0..cut]
    let obj = JsonObject()
    obj.put("pattern", JsonString(pattern))
    obj.put("channel", JsonString(channel))
    obj.put("payload", JsonString(respSafeText(shown)))
    obj.put("payloadHex", JsonString(respHexOfBytes(shown)))
    obj.put("bytes", JsonInt(total))
    obj.put("truncated", JsonBool(cut < total))
    eprintln("[cj-tauri] redis message: channel=${channel} pattern=${redisClip(pattern, 32)}" +
        " bytes=${total} truncated=${cut < total}")
    redisRecordMessage(sess, obj)
}

// ------------------------------------------------------------ 顶层助手

/**
 * 在字符串里找某个 ASCII 字节的位置（返回**字节下标**，找不到回 -1）。
 *
 * 自己写而不是用现成查找：仓颉的 String 迭代得到的是 `UInt8`、下标也是字节下标（AGENTS §4 实测），
 * 用库函数一旦给的是码点下标，切字符串就会切在半个汉字上——这个不一致只能靠统一字节口径避免。
 */
func redisIndexOfByte(s: String, target: UInt8): Int64 {
    var i: Int64 = 0
    for (b in s) {
        if (b == target) {
            return i
        }
        i += 1
    }
    return -1
}

/** 去掉行尾的 `\r`（INFO 正文常见 CRLF；不剥掉的话每个值的尾巴都挂个不可见字符，页面与断言都难对） */
func redisChompCr(line: String): String {
    if (line.size > 0 && line[line.size - 1] == 0x0Du8) {
        return line[0..line.size - 1]
    }
    return line
}

/** 是不是「空白类」ASCII 字节（空格 / 制表 / CR） */
func redisIsSpaceByte(b: UInt8): Bool {
    return b == 0x20u8 || b == 0x09u8 || b == 0x0Du8
}

/** 去掉首尾空白（只认 ASCII 空白；INFO 的行首会有空格） */
func redisTrim(s: String): String {
    var start: Int64 = 0
    var end = s.size
    while (start < end && redisIsSpaceByte(s[start])) {
        start += 1
    }
    while (end > start && redisIsSpaceByte(s[end - 1])) {
        end -= 1
    }
    return s[start..end]
}

/**
 * INFO 的整段文本 → 分节结构（`# Section` 开一节，`k:v` 进当前节）。
 *
 * 为什么不让页面自己切：INFO 正文里 `\r\n` 与 `\n` 混着、还夹着空行，切法一旦散到前端，
 * 有多少个页面就有多少份实现；这里切一次，页面与 E2E 断言看**同一份**结构。
 * 认不出的行收进该节的 `other`（**不丢**）——新版本多一行就说「没有」是最难查的那种错。
 */
func redisInfoParse(text: String): JsonValue {
    let sections = ArrayList<JsonValue>()
    var fields = ArrayList<JsonValue>()
    var others = ArrayList<JsonValue>()
    var name = ""
    for (rawLine in text.split("\n")) {
        let trimmed = redisTrim(redisChompCr(rawLine))
        if (trimmed.size == 0) {
            continue
        }
        if (trimmed.startsWith("#")) {
            if (name.size > 0) {
                sections.add(redisInfoSection(name, fields, others))
            }
            name = redisTrim(trimmed[1..trimmed.size])
            fields = ArrayList<JsonValue>()
            others = ArrayList<JsonValue>()
        } else {
            let sep = redisIndexOfByte(trimmed, 0x3Au8)
            if (sep >= 0) {
                let f = JsonObject()
                f.put("key", JsonString(trimmed[0..sep]))
                f.put("value", JsonString(trimmed[sep + 1..trimmed.size]))
                fields.add(f)
            } else {
                others.add(JsonString(trimmed))
            }
        }
    }
    if (name.size > 0) {
        sections.add(redisInfoSection(name, fields, others))
    }
    JsonArray(sections)
}

/** INFO 的一节 → 对象（`# Section` 那段） */
func redisInfoSection(name: String, fields: ArrayList<JsonValue>, others: ArrayList<JsonValue>): JsonValue {
    let o = JsonObject()
    o.put("name", JsonString(name))
    o.put("count", JsonInt(Int64(fields.size)))
    o.put("fields", JsonArray(fields))
    if (others.size > 0) {
        o.put("other", JsonArray(others))
    }
    o
}

/**
 * 一条慢日志条目 → 对象：`[id, 时间戳, 耗时微秒, [参数...], 客户端地址, 客户端名]`。
 *
 * 尾部字段**按长度判着取**：不同版本的字段数不一样，直接按下标取会越界崩在这里
 * （宁可少给一个字段，也不要让「看慢日志」这条命令把整个诊断流程带崩）。
 */
func redisSlowlogEntry(it: RespValue): JsonValue {
    let items = respItemsOrEmpty(it)
    let o = JsonObject()
    var id: Int64 = -1
    var at: Int64 = 0
    var micros: Int64 = 0
    var client = ""
    if (items.size >= 1) {
        id = redisNumberOr(items[0], -1)
    }
    if (items.size >= 2) {
        at = redisNumberOr(items[1], 0)
    }
    if (items.size >= 3) {
        micros = redisNumberOr(items[2], 0)
    }
    let args = ArrayList<JsonValue>()
    if (items.size >= 4) {
        for (a in respItemsOrEmpty(items[3])) {
            args.add(JsonString(respValueText(a)))
        }
    }
    if (items.size >= 5) {
        client = respValueText(items[4])
    }
    o.put("id", JsonInt(id))
    o.put("at", JsonInt(at))
    o.put("micros", JsonInt(micros))
    o.put("args", JsonArray(args))
    o.put("client", JsonString(client))
    o
}

/** 数值回复取值，非数值（nil / 出错 / 形状不对）回兜底——用于「取不到就别显示」的统计字段 */
func redisNumberOr(v: RespValue, fallback: Int64): Int64 {
    match (v) {
        case Number(n) => return n
        case _ => return fallback
    }
}

/**
 * 一个键的「体积」：string 报**字节数**（STRLEN），容器报**元素个数**（HLEN/LLEN/SCARD/ZCARD/XLEN）。
 *
 * 两种口径混在一个字段里是有意的取舍：Redis 侧没有「按类型的字节数」这种 O(1) 回答
 * （`MEMORY USAGE` 要遍历采样，代价随键大小走），而页面这一栏要的是「这键有多大盘」。
 * 口径由 `redisKeySizeUnit` 在同一处写明（`sizeUnit` 字段），免得把元素个数当字节数读。
 */
func redisKeySize(sess: RedisSession, key: String, typeName: String): Int64 {
    if (typeName == REDIS_TYPE_STRING) {
        return redisNumberOr(redisCall(sess, ["STRLEN", key]), -1)
    }
    if (typeName == REDIS_TYPE_HASH) {
        return redisNumberOr(redisCall(sess, ["HLEN", key]), -1)
    }
    if (typeName == REDIS_TYPE_LIST) {
        return redisNumberOr(redisCall(sess, ["LLEN", key]), -1)
    }
    if (typeName == REDIS_TYPE_SET) {
        return redisNumberOr(redisCall(sess, ["SCARD", key]), -1)
    }
    if (typeName == REDIS_TYPE_ZSET) {
        return redisNumberOr(redisCall(sess, ["ZCARD", key]), -1)
    }
    if (typeName == REDIS_TYPE_STREAM) {
        return redisNumberOr(redisCall(sess, ["XLEN", key]), -1)
    }
    return -1
}

/** `redisKeySize` 的数字是什么口径（`keyInfo` 的 `sizeUnit` 字段） */
func redisKeySizeUnit(typeName: String): String {
    if (typeName == REDIS_TYPE_STRING) {
        return "bytes"
    }
    return "elements"
}

/** 字符串 → 组帧用的原始参数（Redis 的文本参数就是它的 UTF-8 字节） */
func redisRaw(s: String): Array<UInt8> {
    return s.toArray()
}

/** 表里有没有这个字符串（订阅去重用）；线性扫是有意的——这两张表向来只有几个到几十个元素 */
func redisListHas(items: ArrayList<String>, target: String): Bool {
    for (it in items) {
        if (it == target) {
            return true
        }
    }
    return false
}

/**
 * 一段值字节 → 页面可显示的形状：`text` 尽力给文本（不可打印时退化成 `0x…`），`hex` 无损给全份，
 * 超展示上限只给前缀并置 `truncated`（**原文长度照实报**，不假装键只有这么长）。
 *
 * 两个都给是有意的：页面既能直接看文本，也能把 hex 原样回写，二进制安全的值不会在往返里被改。
 */
func redisValueDisplay(raw: Array<UInt8>): JsonValue {
    let total = Int64(raw.size)
    let cut = redisClampInt(total, 0, REDIS_VALUE_TEXT_LIMIT)
    let shown = raw[0..cut]
    let o = JsonObject()
    o.put("bytes", JsonInt(total))
    o.put("truncated", JsonBool(cut < total))
    o.put("text", JsonString(respSafeText(shown)))
    o.put("hex", JsonString(respHexOfBytes(shown)))
    o
}

// ------------------------------------------------------------ 插件装配

/**
 * redis 插件：注册命令 + 声明事件与权限集。
 *
 * 命令全名 = `redis:<短名>`（与内置 `system:*` 同形，分发与能力校验零改动）；
 * 事件短名同理，框架自动加前缀 → 前端监听 `redis:message` / `redis:state`。
 * 权限集（v1.1）：`default` = 全部命令，`readonly` = 只观不控的那些（浏览 / 诊断 / 订阅，改数据的一个都不给）。
 * **集声明不等于放行**（框架铁律）：应用要在自己的 capabilities 里引用 `"redis:default"`
 * 或逐条写明文命令，缺一边就用不了。
 */
public class RedisPlugin <: Plugin {
    private let handler = RedisCommands()

    public init() {}

    public func name(): String {
        return "redis"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let map = HashMap<String, CommandHandler>()
        // 键必须是**短名**：框架的 registerPluginCommands 会补 `<插件名>:` 前缀，
        // 这里再写一次就得到 `redis:redis:connect`（实机日志一眼可见，且能力清单怎么配都对不上）
        for (c in REDIS_PLUGIN_COMMANDS) {
            map.add(c, this.handler)
        }
        map
    }

    /** 事件短名（框架加 `redis:` 前缀）；未在能力清单 `events` 声明时事件被丢弃，拉取通道仍可用 */
    public func events(): ArrayList<String> {
        let names = ArrayList<String>()
        names.add("message")
        names.add("state")
        names
    }

    public func setup(app: TauriApp): Unit {
        this.handler.attachApp(app)
    }

    /** 命名权限集：短集名 → 成员（写短名，框架自动补 `redis:` 前缀） */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let sets = HashMap<String, ArrayList<String>>()
        let all = ArrayList<String>()
        for (c in REDIS_PLUGIN_COMMANDS) {
            all.add(c)
        }
        let readonly = ArrayList<String>()
        for (c in REDIS_READONLY_COMMANDS) {
            readonly.add(c)
        }
        sets.add("default", all)
        sets.add("readonly", readonly)
        sets
    }

    public func jsShim(): String {
        return redisJsShim()
    }
}

/** shim 里要暴露的命令名（JS 数组字面量）：**从唯一那份命令表生成**，加命令时不会漏一处 */
func redisShimNamesJs(): String {
    let out = ArrayList<UInt8>()
    respAscii(out, "[")
    var i: Int64 = 0
    for (c in REDIS_PLUGIN_COMMANDS) {
        if (i > 0) {
            respAscii(out, ",")
        }
        respAscii(out, "'" + c + "'")
        i += 1
    }
    respAscii(out, "]")
    return String.fromUtf8(out.toArray())
}

/**
 * 前端 shim：`window.__CJ_TAURI__.redis.<短名>(args)` → `invoke("redis:<短名>", args)`。
 *
 * 用普通字符串拼（**不用三引号**）：三引号会处理反斜杠转义（AGENTS §4），而这里的 JS 故意一个反斜杠都不写，
 * 免得同一份 shim 在不同文件里被转义规则咬出两种行为。桥没就位时留空实现，页面自己 waitForBridge 后再用。
 */
// 做成**函数**而不是顶层 `let`：顶层 `let` 按声明顺序初始化，而 `jsShim()`（在声明之前）要读它，
// 仓颉直接判 `variable 'REDIS_JS_SHIM' is used before being defined`；函数可以前向引用，没有这个次序坑。
func redisJsShim(): String {
    return "(function(){" +
        "var cj=window.__CJ_TAURI__;if(!cj||!cj.invoke){return;}" +
        "var names=" + redisShimNamesJs() + ";" +
        "var ns={};" +
        "names.forEach(function(n){ns[n]=function(a){return cj.invoke('redis:'+n,a||{});};});" +
        "ns.help=function(){return names.slice();};" +
        "cj.redis=ns;" +
        "})();"
}
