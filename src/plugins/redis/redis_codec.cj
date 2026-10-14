package cjTauri.plugins.redis

import cjTauri.*

import std.collection.*

/**
 * Redis RESP2 协议的纯编解码层（只吃字节、只吐字节，不碰 socket）
 *
 * 为什么自己写：std / stdx 里都没有 Redis 协议，而 RESP2 的骨架很小——六种前缀（简单串 / 错误 /
 * 整数 / 批量串 / 数组，加两个 null 变体）、长度一律十进制 + CRLF，几百行足够。设计取舍见
 * `docs/设计决策记录.md` D-016。**编解码与连接状态机分开**：本文件全部无副作用、可单测；
 * socket 读写、命令通道与订阅线程放在 `plugin_redis.cj`。
 *
 * 为什么不照 MQTT 那样「畸形就返回 None」：RESP 是**增量解析**的（一条回复可能跨好几个 socket 块），
 * 「还没收全」与「协议非法」必须分开——前者接着等，后者当场拒。所以读取入口 `respTryRead()` 返回三态
 * `RespRead`（`Incomplete` / `Value` / `Malformed`），并且**解析永远不抛异常**：对端发什么都不会
 * 把宿主线程带走（畸形报文的抛异常路径只在编码侧，那是调用方自己的 bug）。
 *
 * 边界（如实）：只做 RESP2。不做 RESP3 的 map（`%`）/ set（`~`）/ push（`>`）/ bool（`#`）/
 * double（`,`）/ big number（`(`）/ verbatim string（`=`）/ attribute（`|`）——遇到这些前缀按
 * `Malformed` 拒，**不猜它想表达什么**。也不做 inline 命令解析（我们只发数组形式）。
 */

// ---------------------------------------------------------------- 常量

/** 前缀字符（RESP2 规范：`+` `-` `:` `$` `*`） */
public let RESP_SIMPLE: UInt8 = 43    // '+'
public let RESP_ERROR: UInt8 = 45     // '-'
public let RESP_INTEGER: UInt8 = 58   // ':'
public let RESP_BULK: UInt8 = 36      // '$'
public let RESP_ARRAY: UInt8 = 42     // '*'

/** 单个批量串上限 512MB（协议上限）：只用来拦「对端谎报长度」把内存吃干 */
public let RESP_MAX_BULK: Int64 = 536870912

/** 嵌套层数上限：解析是递归的，深嵌套是廉价的内存炸弹 */
public let RESP_MAX_DEPTH: Int64 = 32

/** 单个数组的元素数上限（同样为了拦谎报） */
public let RESP_MAX_ELEMENTS: Int64 = 1048576

/** 消费游标超过这个数就把已读部分搬掉：长连接下缓冲区不该只涨不缩 */
let RESP_COMPACT_THRESHOLD: Int64 = 8192

// ---------------------------------------------------------------- 值模型

/**
 * 一个 RESP2 值。null 用 `Option` 表达（`$-1` / `*-1`），不用哨兵——不然「空串」与「不存在」会撞在一起
 * （Redis 里 `GET` 一个不存在的 key 返回 null bulk，`GET` 一个空串返回 0 字节 bulk，两者必须能分开）。
 */
public enum RespValue {
    | Simple(String)                     // +OK
    | Failure(String)                    // -ERR unknown command
    | Number(Int64)                      // :123
    | Bulk(Option<Array<UInt8>>)         // $5 hello / $-1 null
    | Arr(Option<Array<RespValue>>)      // *2 ... / *-1 null
}

/**
 * 读取三态。**没有第四态**：「空缓冲」是 `Incomplete` 的特例，调用方按超时决定要不要放弃。
 * `Malformed` 里带一句人话，直接可以进 stderr 取证行（对端发坏字节时得有凭证）。
 */
public enum RespRead {
    | Incomplete
    | Value(RespValue)
    | Malformed(String)
}

// ---------------------------------------------------------------- 解析核心

/**
 * 增量读取器：`feed()` 喂 socket 收到的字节，`respTryRead()` 取下一个完整值。
 *
 * 解析成功才推进游标，否则原地不动（这是「半条报文跨块到达」能work的关键）。
 * 内部是同一条字节缓冲，不做按值切分——调试工具的报文量级用不着更花的结构。
 */
public class RespReader {
    private var data: ArrayList<UInt8> = ArrayList<UInt8>()
    private var cursor: Int64 = 0

    public init() {}

    /** 追加一块 socket 收到的字节（就地追加，不换缓冲） */
    public func feed(chunk: Array<UInt8>): Unit {
        for (b in chunk) {
            data.add(b)
        }
    }

    /** 还没被消费的字节数（调用方用它判断「读完没有」与打日志） */
    public func buffered(): Int64 {
        return Int64(data.size) - cursor
    }

    /** 断开 / 重连时清干净：残留半条报文会让下一次连接从错位的字节开始解 */
    public func reset(): Unit {
        data = ArrayList<UInt8>()
        cursor = 0
    }

    /** 取下一个完整值；不够则原地返回 `Incomplete`，协议非法返回 `Malformed`（游标都不动） */
    public func respTryRead(): RespRead {
        let (status, next) = parseValue(cursor, 0)
        match (status) {
            case RespRead.Value(v) =>
                cursor = next
                compact()
                return RespRead.Value(v)
            case RespRead.Malformed(m) =>
                return RespRead.Malformed(m)
            case RespRead.Incomplete =>
                return RespRead.Incomplete
        }
    }

    /** 已读部分攒够阈值就搬掉，避免长连接下缓冲线性增长 */
    private func compact(): Unit {
        if (cursor < RESP_COMPACT_THRESHOLD) {
            return
        }
        let kept = ArrayList<UInt8>()
        var i = cursor
        while (i < Int64(data.size)) {
            kept.add(data[i])
            i += 1
        }
        data = kept
        cursor = 0
    }

    /**
     * 从 `off` 处解析一个值，返回 (状态, 下一个位置)。
     * 递归下降；`depth` 超限直接判 Malformed——对端不能用一个深嵌套回复把递归栈打爆。
     */
    private func parseValue(off: Int64, depth: Int64): (RespRead, Int64) {
        if (depth > RESP_MAX_DEPTH) {
            return (RespRead.Malformed("嵌套层数超过上限 ${RESP_MAX_DEPTH}"), off)
        }
        if (off >= Int64(data.size)) {
            return (RespRead.Incomplete, off)
        }
        let marker = data[off]
        if (marker == RESP_SIMPLE || marker == RESP_ERROR) {
            match (findCrlf(off + 1)) {
                case Some(eol) =>
                    let text = respSafeText(sliceOf(off + 1, eol))
                    let v = if (marker == RESP_SIMPLE) {
                        RespValue.Simple(text)
                    } else {
                        RespValue.Failure(text)
                    }
                    return (RespRead.Value(v), eol + 2)
                case None =>
                    return (RespRead.Incomplete, off)
            }
        }
        if (marker == RESP_INTEGER) {
            match (findCrlf(off + 1)) {
                case Some(eol) =>
                    match (respParseInt(respSafeText(sliceOf(off + 1, eol)))) {
                        case Some(n) => return (RespRead.Value(RespValue.Number(n)), eol + 2)
                        case None => return (RespRead.Malformed("整数不是合法数字"), off)
                    }
                case None =>
                    return (RespRead.Incomplete, off)
            }
        }
        if (marker == RESP_BULK) {
            match (findCrlf(off + 1)) {
                case Some(eol) =>
                    match (parseLength(off + 1, eol)) {
                        case Some(-1) => return (RespRead.Value(RespValue.Bulk(None)), eol + 2)
                        case Some(n) =>
                            // 长度行 + CRLF + n 字节 + CRLF，少一个字节都还在「没收全」
                            let bodyStart = eol + 2
                            let bodyEnd = bodyStart + n
                            if (bodyEnd + 2 > Int64(data.size)) {
                                return (RespRead.Incomplete, off)
                            }
                            if (data[bodyEnd] != 13 || data[bodyEnd + 1] != 10) {
                                return (RespRead.Malformed("批量串结尾不是 CRLF"), off)
                            }
                            return (RespRead.Value(RespValue.Bulk(Some(sliceOf(bodyStart, bodyEnd)))), bodyEnd + 2)
                        case None => return (RespRead.Malformed("批量串长度非法"), off)
                    }
                case None =>
                    return (RespRead.Incomplete, off)
            }
        }
        if (marker == RESP_ARRAY) {
            match (findCrlf(off + 1)) {
                case Some(eol) =>
                    match (parseLength(off + 1, eol)) {
                        case Some(-1) => return (RespRead.Value(RespValue.Arr(None)), eol + 2)
                        case Some(n) =>
                            if (n > RESP_MAX_ELEMENTS) {
                                return (RespRead.Malformed("数组元素数超过上限 ${RESP_MAX_ELEMENTS}"), off)
                            }
                            let items = ArrayList<RespValue>()
                            var at = eol + 2
                            var i: Int64 = 0
                            while (i < n) {
                                let (subStatus, subNext) = parseValue(at, depth + 1)
                                match (subStatus) {
                                    case RespRead.Value(sv) =>
                                        items.add(sv)
                                        at = subNext
                                    case RespRead.Malformed(m) => return (RespRead.Malformed(m), off)
                                    case RespRead.Incomplete => return (RespRead.Incomplete, off)
                                }
                                i += 1
                            }
                            return (RespRead.Value(RespValue.Arr(Some(items.toArray()))), at)
                        case None => return (RespRead.Malformed("数组长度非法"), off)
                    }
                case None =>
                    return (RespRead.Incomplete, off)
            }
        }
        return (RespRead.Malformed("不认识的 RESP 前缀 0x${respHexByte(marker)}（只做 RESP2）"), off)
    }

    /** 长度行（批量串 / 数组共用）：十进制整数，别的都算非法 */
    private func parseLength(from: Int64, to: Int64): Option<Int64> {
        match (respParseInt(respSafeText(sliceOf(from, to)))) {
            case Some(n) =>
                if (n < -1) {
                    return None
                }
                if (n > RESP_MAX_BULK) {
                    return None
                }
                return Some(n)
            case None => return None
        }
    }

    /** 从 `from` 处找 CRLF，返回 CR 的下标；没找着说明这行还没收全 */
    private func findCrlf(from: Int64): Option<Int64> {
        var i = from
        while (i + 1 < Int64(data.size)) {
            if (data[i] == 13 && data[i + 1] == 10) {
                return Some(i)
            }
            i += 1
        }
        return None
    }

    /** 切一段字节出来（越界自动夹住，调用方都已判过长度） */
    private func sliceOf(from: Int64, to: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        var i = from
        while (i < to && i < Int64(data.size)) {
            out.add(data[i])
            i += 1
        }
        return out.toArray()
    }
}

// ---------------------------------------------------------------- 文本与十六进制

/** 一个 nibble（0..15）的 hex 字符字节（大写）：48='0'、65='A' */
func respHexDigit(v: UInt8): UInt8 {
    if (v < 10u8) {
        return 48u8 + v
    }
    return 65u8 + (v - 10u8)
}

/** 一个字节的两位大写 hex */
public func respHexByte(b: UInt8): String {
    let out = ArrayList<UInt8>()
    out.add(respHexDigit((b >> 4) & 0x0F))
    out.add(respHexDigit(b & 0x0F))
    return String.fromUtf8(out.toArray())
}

/** 一段字节的 hex 串（无分隔符，长度翻倍——调用方自己决定要不要截断） */
public func respHexOfBytes(raw: Array<UInt8>): String {
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < Int64(raw.size)) {
        let b = raw[i]
        out.add(respHexDigit((b >> 4) & 0x0F))
        out.add(respHexDigit(b & 0x0F))
        i += 1
    }
    return String.fromUtf8(out.toArray())
}

/**
 * 把一段字节按文本取出来，取不到就给 hex 兜底。
 *
 * 为什么不直接 `String.fromUtf8`：对端（或中间设备）发坏字节时它会抛，而这段代码正在**解析协议**——
 * 解析路径一律不抛（本文件顶部契约）。全 ASCII 的快路径直接转（绝大多数情况走这里）。
 */
public func respSafeText(raw: Array<UInt8>): String {
    var ascii = true
    for (b in raw) {
        if (b >= 128u8) {
            ascii = false
            break
        }
    }
    if (ascii) {
        return String.fromUtf8(raw)
    }
    try {
        return String.fromUtf8(raw)
    } catch (e: Exception) {
        return "0x" + respHexOfBytes(raw)
    }
}

/**
 * 十进制整数安全解析（协议解析路径不许抛，所以不直接用 `Int64.parse`）。
 * 只认可选的符号 + 纯数字；超过 2^53 判 None（协议里的长度与计数都不该这么大，判非法比悄悄溢出安全）。
 */
public func respParseInt(s: String): Option<Int64> {
    let bytes = s.toArray()
    if (bytes.size == 0) {
        return None
    }
    var i: Int64 = 0
    var negative = false
    if (bytes[0] == 45) {       // '-'
        negative = true
        i = 1
    } else if (bytes[0] == 43) { // '+'
        i = 1
    }
    if (i >= Int64(bytes.size)) {
        return None
    }
    var value: Int64 = 0
    while (i < Int64(bytes.size)) {
        let b = bytes[i]
        if (b < 48u8 || b > 57u8) {
            return None
        }
        value = value * 10 + Int64(b - 48u8)
        if (value > 9007199254740991) {
            return None
        }
        i += 1
    }
    if (negative) {
        value = -value
    }
    return Some(value)
}

// ---------------------------------------------------------------- 命令组帧

/** 追加 ASCII 文本（命令名与十进制长度都是 ASCII） */
func respAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

func respCrlf(out: ArrayList<UInt8>): Unit {
    out.add(13)
    out.add(10)
}

/**
 * 组一条命令：RESP2 只有数组形式——`*N\r\n` + 每个参数一个 `$len\r\n<字节>\r\n`。
 *
 * 参数个数为 0 直接抛：那是调用方的 bug（对端收到 `*0` 只会回一个协议错误，比当场报错难查）。
 */
public func respEncodeCommandRaw(parts: Array<Array<UInt8>>): Array<UInt8> {
    if (parts.size == 0) {
        throw CommandException("Redis 命令至少要有一个参数")
    }
    let out = ArrayList<UInt8>()
    out.add(RESP_ARRAY)
    respAscii(out, "${parts.size}")
    respCrlf(out)
    for (p in parts) {
        if (Int64(p.size) > RESP_MAX_BULK) {
            throw CommandException("Redis 参数太长（${p.size} 字节，上限 ${RESP_MAX_BULK}）")
        }
        out.add(RESP_BULK)
        respAscii(out, "${p.size}")
        respCrlf(out)
        for (b in p) {
            out.add(b)
        }
        respCrlf(out)
    }
    return out.toArray()
}

/** 文本参数的组帧（`SET key value` 这类） */
public func respEncodeCommand(parts: Array<String>): Array<UInt8> {
    let raws = ArrayList<Array<UInt8>>()
    for (p in parts) {
        raws.add(p.toArray())
    }
    return respEncodeCommandRaw(raws.toArray())
}

/** 1 / 2 / 3 个文本参数的常用形状（省掉到处写字面量数组） */
public func respCmd1(a: String): Array<UInt8> {
    return respEncodeCommand([a])
}

public func respCmd2(a: String, b: String): Array<UInt8> {
    return respEncodeCommand([a, b])
}

public func respCmd3(a: String, b: String, c: String): Array<UInt8> {
    return respEncodeCommand([a, b, c])
}

/** 带二进制尾参的形状：`SET key <bytes>` / `XADD key * field <bytes>` —— 值必须二进制安全 */
public func respCmdRaw2(a: String, b: Array<UInt8>): Array<UInt8> {
    return respEncodeCommandRaw([a.toArray(), b])
}

public func respCmdRaw3(a: String, b: String, c: Array<UInt8>): Array<UInt8> {
    return respEncodeCommandRaw([a.toArray(), b.toArray(), c])
}

// ---------------------------------------------------------------- 取值助手

/** 错误回复的文字；不是错误给 None（插件拿它决定要不要抛） */
public func respErrorOf(v: RespValue): Option<String> {
    match (v) {
        case Failure(m) => return Some(m)
        case _ => return None
    }
}

/** 整数回复（`:` 形式） */
public func respNumber(v: RespValue): Option<Int64> {
    match (v) {
        case Number(n) => return Some(n)
        case _ => return None
    }
}

/** 批量串的原始字节。**不收** Simple / Number：它们不是 bulk，混用会让调用方以为拿到了二进制 */
public func respBytes(v: RespValue): Option<Array<UInt8>> {
    match (v) {
        case Bulk(Some(raw)) => return Some(raw)
        case _ => return None
    }
}

/** 批量串当文本（坏字节 → hex 兜底） */
public func respText(v: RespValue): Option<String> {
    match (v) {
        case Bulk(Some(raw)) => return Some(respSafeText(raw))
        case _ => return None
    }
}

/** 数组元素；null 数组（`*-1`）给 None */
public func respItems(v: RespValue): Option<Array<RespValue>> {
    match (v) {
        case Arr(Some(items)) => return Some(items)
        case _ => return None
    }
}

/** 数组元素，null / 非数组都当空数组——查询类命令的调用方几乎总是这个语义 */
public func respItemsOrEmpty(v: RespValue): Array<RespValue> {
    match (v) {
        case Arr(Some(items)) => return items
        case _ => return Array<RespValue>()
    }
}

/**
 * 扁平数组当「文本对」列表：`HGETALL` 与 `ZRANGE ... WITHSCORES` 都是 `[a, b, c, d]` 的形状。
 * 奇数个元素就丢掉最后一个（回复本身已经不对了，但没必要为它抛）。
 */
public func respPairs(v: RespValue): Array<(String, String)> {
    let items = respItemsOrEmpty(v)
    let out = ArrayList<(String, String)>()
    var i: Int64 = 0
    while (i + 1 < Int64(items.size)) {
        out.add((respValueText(items[i]), respValueText(items[i + 1])))
        i += 2
    }
    return out.toArray()
}

/** 单个值当文本：Simple 与 Number 也收（键名 / TTL / 分值常以这两种形式回来） */
public func respValueText(v: RespValue): String {
    match (v) {
        case Simple(s) => return s
        case Number(n) => return n.toString()
        case Bulk(Some(raw)) => return respSafeText(raw)
        case Bulk(None) => return ""
        case Failure(m) => return m
        case Arr(None) => return ""
        case Arr(Some(items)) => return "${items.size} items"
    }
}

/**
 * 一行摘要：**只说类型与规模，不打内容**——stderr 取证行要短，把整条 INFO 打出来会把日志淹掉。
 * 这是「日志里有没有」之外还能一眼看出「收了多少」的那个口径。
 */
public func respBrief(v: RespValue): String {
    match (v) {
        case Simple(s) => return "simple(${s})"
        case Failure(m) => return "error(${m})"
        case Number(n) => return "number(${n})"
        case Bulk(Some(raw)) => return "bulk(${raw.size}B)"
        case Bulk(None) => return "null"
        case Arr(Some(items)) => return "array(${items.size})"
        case Arr(None) => return "null"
    }
}

/**
 * 人看的完整渲染（前端展示与单测断言用）：数组按缩排多行，二进制走 hex。
 * 不用 JSON 序列化：这里的值可能是非 UTF-8 字节，JSON 化要在中途转一次文本，反而丢掉「这是二进制」这件事。
 */
public func respRender(v: RespValue): String {
    return respRenderAt(v, 0)
}

func respRenderAt(v: RespValue, depth: Int64): String {
    match (v) {
        case Simple(s) => return s
        case Failure(m) => return "(error) ${m}"
        case Number(n) => return "(integer) ${n}"
        case Bulk(None) => return "(nil)"
        case Bulk(Some(raw)) => return "(bulk ${raw.size}B) ${respSafeText(raw)}"
        case Arr(None) => return "(nil array)"
        case Arr(Some(items)) =>
            let out = ArrayList<UInt8>()
            respAscii(out, "(array ${items.size})")
            var i: Int64 = 0
            while (i < Int64(items.size)) {
                out.add(10u8)   // '\n'
                var k: Int64 = 0
                while (k < (depth + 1) * 2) {
                    out.add(32u8)
                    k += 1
                }
                respAscii(out, "${i}) ")
                respAscii(out, respRenderAt(items[i], depth + 1))
                i += 1
            }
            return String.fromUtf8(out.toArray())
    }
}
