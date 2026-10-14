package cjTauri.plugins.mqtt

import cjTauri.*

import std.collection.*

/**
 * MQTT 3.1.1 报文的纯编解码层（只吃字节、只吐字节，不碰 socket）
 *
 * 为什么自己写：std / stdx 都没有 MQTT，协议本身也只是「固定头 + 变长剩余长度 + 变长头 + 载荷」
 * 的字节拼装，几个纯函数足够（设计取舍见 docs/设计决策记录.md D-014）。**编解码与连接状态机
 * 分开**：本文件的函数一律无副作用、可单测；socket 读写与保活放在 plugin_mqtt.cj。
 *
 * 边界（如实）：只做 MQTT 3.1.1（协议级别 4）的明文 TCP 报文；不做 MQTT 5.0 的属性/原因码，
 * 不做 MQTT over WebSocket。解码遇到「剩余长度与实际字节数对不上」「类型码非法」一律返回 None
 * ——宁可拒绝一条畸形报文，也不猜它想干什么（畸形报文进到状态机里，表现只会更难查）。
 */

// ---------------------------------------------------------------- 常量

// 控制报文类型（MQTT 3.1.1 §2.2.1）
public const MQTT_PKT_CONNECT: UInt8 = 1
public const MQTT_PKT_CONNACK: UInt8 = 2
public const MQTT_PKT_PUBLISH: UInt8 = 3
public const MQTT_PKT_PUBACK: UInt8 = 4
public const MQTT_PKT_PUBREC: UInt8 = 5
public const MQTT_PKT_PUBREL: UInt8 = 6
public const MQTT_PKT_PUBCOMP: UInt8 = 7
public const MQTT_PKT_SUBSCRIBE: UInt8 = 8
public const MQTT_PKT_SUBACK: UInt8 = 9
public const MQTT_PKT_UNSUBSCRIBE: UInt8 = 10
public const MQTT_PKT_UNSUBACK: UInt8 = 11
public const MQTT_PKT_PINGREQ: UInt8 = 12
public const MQTT_PKT_PINGRESP: UInt8 = 13
public const MQTT_PKT_DISCONNECT: UInt8 = 14

/** 协议名与级别：CONNECT 的变长头里写死这两个值（3.1.1 = 级别 4） */
public let MQTT_PROTOCOL_NAME: String = "MQTT"
public let MQTT_PROTOCOL_LEVEL: UInt8 = 4

/** 剩余长度是 4 个 7 位字节，协议上限 256MB-1 */
public let MQTT_MAX_REMAINING_LENGTH: Int64 = 268435455

/** 单条发布载荷上限 256 KiB：调试工具不做大文件搬运工，超了直接拒（前端也能一眼看懂） */
public let MQTT_MAX_PAYLOAD: Int64 = 262144

/** MQTT 的 UTF-8 字符串（主题/客户端标识/用户名）都以 2 字节长度打头，上限 65535 字节 */
public let MQTT_MAX_UTF8_FIELD: Int64 = 65535

// ---------------------------------------------------------------- 底层读写

/** 夹到 [lo, hi]：所有「算出来再编码」的整数都先过这里（越界转换会抛异常，AGENTS §4 有先例） */
func mqttClampInt(v: Int64, lo: Int64, hi: Int64): Int64 {
    if (v < lo) {
        return lo
    }
    if (v > hi) {
        return hi
    }
    return v
}

/** QoS 夹到 0..2：页面传 3/负数/缺省都按最近合法值处理，不抛（协议层拒绝发生在编码处） */
public func mqttClampQos(q: Int64): Int64 {
    return mqttClampInt(q, 0, 2)
}

/** 大端写一个 u16（MQTT 全程大端） */
func mqttPutU16(buf: ArrayList<UInt8>, v: Int64): Unit {
    let x = mqttClampInt(v, 0, 65535)
    buf.add(UInt8((x >> 8) & 0xFF))
    buf.add(UInt8(x & 0xFF))
}

/** 大端读一个 u16；越界读回 -1（调用方先判 body 长度，这里只兜底） */
func mqttGetU16(buf: Array<UInt8>, at: Int64): Int64 {
    if (at < 0 || at + 1 >= buf.size) {
        return -1
    }
    return (Int64(buf[at]) << 8) | Int64(buf[at + 1])
}

/** 固定头第 1 字节：类型码（高 4 位）+ 标志（低 4 位） */
func mqttTypeFlags(typeCode: UInt8, flags: Int64): UInt8 {
    return UInt8((Int64(typeCode) << 4) | (flags & 0x0F))
}

/** 把 ArrayList 的字节追加到另一个 ArrayList（组帧用，避免到处写 for 循环） */
func mqttAppend(dst: ArrayList<UInt8>, src: Array<UInt8>): Unit {
    for (b in src) {
        dst.add(b)
    }
}

// ---------------------------------------------------------------- 剩余长度（变长整数）

/**
 * 剩余长度编码：每字节 7 位有效、最高位表示「后面还有」（1..4 字节）
 *
 * 超范围直接抛：这类错来自调用方的长度计算，静默截断会让对端收到一条长度对不上的报文，
 * 表现是「broker 无响应」——比当场报错难查得多。
 */
public func mqttEncodeRemainingLength(n: Int64): Array<UInt8> {
    if (n < 0 || n > MQTT_MAX_REMAINING_LENGTH) {
        throw CommandException("MQTT 剩余长度超范围（${n}，上限 ${MQTT_MAX_REMAINING_LENGTH}）")
    }
    let out = ArrayList<UInt8>()
    var x = n
    var more = true
    while (more) {
        let digit = x % 128
        x = x / 128
        if (x > 0) {
            out.add(UInt8(digit | 0x80))
        } else {
            out.add(UInt8(digit))
            more = false
        }
    }
    return out.toArray()
}

/** 剩余长度解码结果（用类而不是元组：单测断言写起来更直白，也省掉 Option<元组> 的匹配） */
public class MqttRemainingLength {
    /** 解出来的值 */
    public var value: Int64 = 0
    /** 占用了几个字节（1..4） */
    public var consumed: Int64 = 0
}

/**
 * 从 `at` 处解码剩余长度。字节不够 → None；连续 4 个字节都带续接位 → None（协议非法）。
 * 只解码、不判总长：够不够由读循环负责（它才知道 socket 上还有没有字节）。
 */
public func mqttDecodeRemainingLength(buf: Array<UInt8>, at: Int64): Option<MqttRemainingLength> {
    var value: Int64 = 0
    var multiplier: Int64 = 1
    var i: Int64 = 0
    while (i < 4) {
        let pos = at + i
        if (pos >= buf.size) {
            return None
        }
        let b = Int64(buf[pos])
        value += (b & 0x7F) * multiplier
        if ((b & 0x80) == 0) {
            let rl = MqttRemainingLength()
            rl.value = value
            rl.consumed = i + 1
            return Some(rl)
        }
        multiplier *= 128
        i += 1
    }
    return None
}

// ---------------------------------------------------------------- 组帧与 UTF-8 字段

/**
 * MQTT 的 UTF-8 字符串：2 字节长度 + UTF-8 字节
 *
 * 长度按**字节数**算（`String.toArray()` 给的就是 UTF-8 字节），中文主题因此是 3 字节/字——
 * 按码点数算会导致长度字段偏小、对端解析错位（AGENTS §4 那条「迭代 String 得到的是字节」同源）。
 */
public func mqttUtf8Field(s: String): Array<UInt8> {
    let raw = s.toArray()
    if (Int64(raw.size) > MQTT_MAX_UTF8_FIELD) {
        throw CommandException("MQTT 字段太长（${raw.size} 字节，上限 ${MQTT_MAX_UTF8_FIELD}）")
    }
    let out = ArrayList<UInt8>()
    mqttPutU16(out, Int64(raw.size))
    mqttAppend(out, raw)
    return out.toArray()
}

/** 二进制字段（遗嘱载荷/发布载荷）：同样 2 字节长度打头，内容原样 */
public func mqttBinaryField(data: Array<UInt8>): Array<UInt8> {
    if (Int64(data.size) > MQTT_MAX_UTF8_FIELD) {
        throw CommandException("MQTT 二进制字段太长（${data.size} 字节，上限 ${MQTT_MAX_UTF8_FIELD}）")
    }
    let out = ArrayList<UInt8>()
    mqttPutU16(out, Int64(data.size))
    mqttAppend(out, data)
    return out.toArray()
}

/** 组一条控制报文：类型+标志 | 剩余长度 | 变长头+载荷 */
public func mqttFrame(typeCode: UInt8, flags: Int64, body: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    out.add(mqttTypeFlags(typeCode, flags))
    mqttAppend(out, mqttEncodeRemainingLength(Int64(body.size)))
    mqttAppend(out, body)
    return out.toArray()
}

// ---------------------------------------------------------------- CONNECT

/** CONNECT 的可选项：编码函数只吃这个对象（单测可直接构造，不必绕 JSON 参数） */
public class MqttConnectOptions {
    public var host: String = "127.0.0.1"
    public var port: Int64 = 1883
    public var clientId: String = ""
    public var username: Option<String> = None
    public var password: Option<String> = None
    public var keepaliveSec: Int64 = 60
    public var cleanSession: Bool = true
    public var willTopic: Option<String> = None
    public var willPayload: Array<UInt8> = Array<UInt8>()
    public var willQos: Int64 = 0
    public var willRetain: Bool = false
}

/** 客户端标识为空时的兜底 id：broker 对空 id 各家处理不同，给个稳定前缀更好对账 */
public func mqttDefaultClientId(seed: Int64): String {
    return "cj-tauri-" + seed.toString()
}

/**
 * 组 CONNECT：协议名/级别 → 连接标志位域 → 保活 → 客户端标识 → 遗嘱 → 用户名 → 密码
 *
 * 连接标志是协议定死的位域，错一位对端就断连且通常不给原因，所以这里按位拼、**不吃页面传来的
 * 任何原始标志值**。密码标志只能在用户名标志为 1 时置位（§3.1.2.9），非法组合当场拒。
 */
public func mqttEncodeConnect(o: MqttConnectOptions): Array<UInt8> {
    var user = ""
    if (let Some(u) <- o.username) {
        user = u
    }
    var pass = ""
    if (let Some(p) <- o.password) {
        pass = p
    }
    var willTopic = ""
    if (let Some(w) <- o.willTopic) {
        willTopic = w
    }
    if (user.size == 0 && pass.size > 0) {
        throw CommandException("MQTT 连接参数非法：给了 password 就必须同时给 username")
    }
    let hasWill = willTopic.size > 0
    var flags: Int64 = 0
    if (o.cleanSession) {
        flags = flags | 0x02
    }
    if (hasWill) {
        flags = flags | 0x04
        flags = flags | (mqttClampQos(o.willQos) << 3)
        if (o.willRetain) {
            flags = flags | 0x20
        }
    }
    if (pass.size > 0) {
        flags = flags | 0x40
    }
    if (user.size > 0) {
        flags = flags | 0x80
    }

    let body = ArrayList<UInt8>()
    mqttAppend(body, mqttUtf8Field(MQTT_PROTOCOL_NAME))
    body.add(MQTT_PROTOCOL_LEVEL)
    body.add(UInt8(flags & 0xFF))
    mqttPutU16(body, mqttClampInt(o.keepaliveSec, 0, 65535))
    mqttAppend(body, mqttUtf8Field(o.clientId))
    if (hasWill) {
        mqttAppend(body, mqttUtf8Field(willTopic))
        mqttAppend(body, mqttBinaryField(o.willPayload))
    }
    if (user.size > 0) {
        mqttAppend(body, mqttUtf8Field(user))
    }
    if (pass.size > 0) {
        mqttAppend(body, mqttUtf8Field(pass))
    }
    return mqttFrame(MQTT_PKT_CONNECT, 0, body.toArray())
}

// ---------------------------------------------------------------- PUBLISH / SUBSCRIBE / 确认

/** 组 PUBLISH。QoS>0 必须带非零报文标识符；载荷超上限直接拒（不切分，免得静默丢内容） */
public func mqttEncodePublish(topic: String, payload: Array<UInt8>, qos: Int64, retain: Bool, dup: Bool,
    packetId: Int64): Array<UInt8> {
    let q = mqttClampQos(qos)
    if (Int64(payload.size) > MQTT_MAX_PAYLOAD) {
        throw CommandException("MQTT 载荷太大（${payload.size} 字节，上限 ${MQTT_MAX_PAYLOAD}）")
    }
    var flags: Int64 = q << 1
    if (retain) {
        flags = flags | 0x01
    }
    if (dup) {
        flags = flags | 0x08
    }
    let body = ArrayList<UInt8>()
    mqttAppend(body, mqttUtf8Field(topic))
    if (q > 0) {
        if (packetId <= 0) {
            throw CommandException("MQTT QoS ${q} 的发布缺少报文标识符")
        }
        mqttPutU16(body, packetId)
    }
    mqttAppend(body, payload)
    return mqttFrame(MQTT_PKT_PUBLISH, flags, body.toArray())
}

/** 组 SUBSCRIBE（一次一个过滤器：调试工具逐条订阅，回执与请求一一对应更好对账） */
public func mqttEncodeSubscribe(packetId: Int64, topicFilter: String, qos: Int64): Array<UInt8> {
    if (packetId <= 0) {
        throw CommandException("MQTT 订阅缺少报文标识符")
    }
    let body = ArrayList<UInt8>()
    mqttPutU16(body, packetId)
    mqttAppend(body, mqttUtf8Field(topicFilter))
    body.add(UInt8(mqttClampQos(qos)))
    return mqttFrame(MQTT_PKT_SUBSCRIBE, 0x02, body.toArray())   // 标志位协议固定 0b0010
}

/** 组 UNSUBSCRIBE（同样一次一个过滤器） */
public func mqttEncodeUnsubscribe(packetId: Int64, topicFilter: String): Array<UInt8> {
    if (packetId <= 0) {
        throw CommandException("MQTT 退订缺少报文标识符")
    }
    let body = ArrayList<UInt8>()
    mqttPutU16(body, packetId)
    mqttAppend(body, mqttUtf8Field(topicFilter))
    return mqttFrame(MQTT_PKT_UNSUBSCRIBE, 0x02, body.toArray())
}

/**
 * 组「只带报文标识符」的确认：PUBACK / PUBREC / PUBCOMP 标志为 0，
 * PUBREL 的标志协议固定为 0b0010（QoS 2 的来回每一步都得按这条来，标志错了对端会当非法报文丢弃）。
 */
public func mqttEncodeAck(typeCode: UInt8, packetId: Int64): Array<UInt8> {
    let body = ArrayList<UInt8>()
    mqttPutU16(body, mqttClampInt(packetId, 1, 65535))
    var flags: Int64 = 0
    if (typeCode == MQTT_PKT_PUBREL) {
        flags = 0x02
    }
    return mqttFrame(typeCode, flags, body.toArray())
}

/** 组 PINGREQ：保活心跳，剩余长度为 0 */
public func mqttEncodePingreq(): Array<UInt8> {
    return mqttFrame(MQTT_PKT_PINGREQ, 0, Array<UInt8>())
}

/** 组 DISCONNECT：正常下线（broker 收到后不会代发遗嘱） */
public func mqttEncodeDisconnect(): Array<UInt8> {
    return mqttFrame(MQTT_PKT_DISCONNECT, 0, Array<UInt8>())
}

// ---------------------------------------------------------------- 解码

/** 解出来的一条控制报文：类型/标志 + 变长头与载荷（具体语义交给下面的 parseXxx） */
public class MqttPacket {
    public var typeCode: UInt8 = 0
    public var flags: Int64 = 0
    public var body: Array<UInt8> = Array<UInt8>()
}

/**
 * 解一条完整报文（固定头 + 剩余长度 + body 都已凑齐；凑字节是读循环的活）
 *
 * 长度字段与实收字节数对不上、类型码不在 1..14 → None。**宁可拒一条畸形报文也不猜它的意图**：
 * 猜出来的「半条报文」进了状态机，现象只会是更难查的错位。
 */
public func mqttDecodePacket(raw: Array<UInt8>): Option<MqttPacket> {
    if (raw.size < 2) {
        return None
    }
    let typeCode = UInt8(Int64(raw[0]) >> 4)
    let flags = Int64(raw[0]) & 0x0F
    if (typeCode < MQTT_PKT_CONNECT || typeCode > MQTT_PKT_DISCONNECT) {
        return None
    }
    match (mqttDecodeRemainingLength(raw, 1)) {
        case None => return None
        case Some(rl) =>
            let start = 1 + rl.consumed
            if (rl.value != Int64(raw.size) - start) {
                return None
            }
            let p = MqttPacket()
            p.typeCode = typeCode
            p.flags = flags
            p.body = raw[start..raw.size]
            return Some(p)
    }
}

/** CONNACK 的内容：会话是否还挂在 broker 上 + 返回码（0 = 接受） */
public class MqttConnack {
    public var sessionPresent: Bool = false
    public var returnCode: Int64 = -1
}

/** 解 CONNACK（协议里它是 2 字节定长：会话标志 + 返回码） */
public func mqttParseConnack(p: MqttPacket): Option<MqttConnack> {
    if (p.typeCode != MQTT_PKT_CONNACK || p.body.size < 2) {
        return None
    }
    let c = MqttConnack()
    c.sessionPresent = (Int64(p.body[0]) & 0x01) != 0
    c.returnCode = Int64(p.body[1])
    return Some(c)
}

/** 解 SUBACK：授予的 QoS 列表（0x80 = 该过滤器订阅失败）；首 2 字节是报文标识符 */
public func mqttParseSuback(p: MqttPacket): Option<ArrayList<Int64>> {
    if (p.typeCode != MQTT_PKT_SUBACK || p.body.size < 3) {
        return None
    }
    let granted = ArrayList<Int64>()
    var i: Int64 = 2
    while (i < p.body.size) {
        granted.add(Int64(p.body[i]))
        i += 1
    }
    return Some(granted)
}

/** 解出来的 PUBLISH */
public class MqttPublish {
    public var topic: String = ""
    public var payload: Array<UInt8> = Array<UInt8>()
    public var qos: Int64 = 0
    public var retain: Bool = false
    public var dup: Bool = false
    public var packetId: Int64 = 0
    public var hasPacketId: Bool = false
}

/**
 * 解 PUBLISH：主题是 UTF-8 字符串（2 字节长度 + 字节内容），QoS>0 时随后跟 2 字节报文标识符，
 * 余下的全是载荷（二进制，可能是图/结构体，所以这里不试解码文本）。
 * 标志位里的 QoS 若是 3（协议保留值）→ None：这条报文按协议就是非法的。
 */
public func mqttParsePublish(p: MqttPacket): Option<MqttPublish> {
    if (p.typeCode != MQTT_PKT_PUBLISH || p.body.size < 2) {
        return None
    }
    let qosRaw = (p.flags >> 1) & 0x03
    if (qosRaw > 2) {
        return None
    }
    let tlen = mqttGetU16(p.body, 0)
    if (tlen < 0 || 2 + tlen > p.body.size) {
        return None
    }
    let out = MqttPublish()
    out.topic = String.fromUtf8(p.body[2..2 + tlen])
    out.qos = qosRaw
    out.retain = (p.flags & 0x01) != 0
    out.dup = (p.flags & 0x08) != 0
    var at = 2 + tlen
    if (out.qos > 0) {
        if (at + 2 > p.body.size) {
            return None
        }
        out.packetId = mqttGetU16(p.body, at)
        out.hasPacketId = true
        at += 2
    }
    out.payload = p.body[at..p.body.size]
    return Some(out)
}

/** 取「只带报文标识符」的确认报文里的标识符（PUBACK/PUBREC/PUBREL/PUBCOMP/UNSUBACK 同形）；不足 2 字节回 -1 */
public func mqttParsePacketId(p: MqttPacket): Int64 {
    if (p.body.size < 2) {
        return -1
    }
    return mqttGetU16(p.body, 0)
}

// ---------------------------------------------------------------- 参数校验与展示助手

/** 主机名校验：只收 IP / 主机名的安全字符（页面可控字符串要进 socket，先在这儿挡一道） */
public func mqttValidHost(h: String): Bool {
    if (h.size == 0 || h.size > 253) {
        return false
    }
    for (b in h.toArray()) {
        let c = Int64(b)
        let digit = c >= 0x30 && c <= 0x39
        let upper = c >= 0x41 && c <= 0x5A
        let lower = c >= 0x61 && c <= 0x7A
        let punct = c == 0x2E || c == 0x2D || c == 0x5F   // 点 / 连字符 / 下划线
        if (!digit && !upper && !lower && !punct) {
            return false
        }
    }
    return true
}

/** 端口校验：1..65535（页面可能传 0 / 负数 / 超大值） */
public func mqttValidPort(p: Int64): Bool {
    return p >= 1 && p <= 65535
}

/** 发布主题：非空、不超过 65535 字节、不含通配符（`+` 与 `#` 在 PUBLISH 里是非法字符） */
public func mqttValidPublishTopic(t: String): Bool {
    if (t.size == 0 || Int64(t.size) > MQTT_MAX_UTF8_FIELD) {
        return false
    }
    if (t.contains("+") || t.contains("#")) {
        return false
    }
    return true
}

/**
 * 订阅过滤器：通配符必须**独占一整层**——`sensor/+/temp` 合法，`sensor+/temp` 非法；
 * `#` 只能独占最后一层（`sensor/#` 合法，`sensor/#/x` 与 `sensor/#suffix` 都非法）。
 *
 * 逐层扫字节而不是 `split('/')`：层级内容可能含多字节 UTF-8，按字节扫能一眼看清「本层有几个字节、
 * 里面有没有通配符」，也避开「分层后还要回头判断是不是最后一层」。**不校验的代价很实在**：非法过滤器
 * 会被 broker 直接断连，现场表现是「一订阅就掉线」，很难往参数上想。
 */
public func mqttValidTopicFilter(t: String): Bool {
    let raw = t.toArray()
    if (raw.size == 0 || Int64(raw.size) > MQTT_MAX_UTF8_FIELD) {
        return false
    }
    let slash = 0x2F
    let hash = 0x23
    let plus = 0x2B
    var start: Int64 = 0
    while (start <= Int64(raw.size)) {
        var end = start
        var hasHash = false
        var hasPlus = false
        while (end < Int64(raw.size) && Int64(raw[end]) != slash) {
            let c = Int64(raw[end])
            if (c == hash) {
                hasHash = true
            }
            if (c == plus) {
                hasPlus = true
            }
            end += 1
        }
        let levelLen = end - start
        let isLast = end == Int64(raw.size)
        if (hasHash) {
            if (levelLen != 1 || !isLast) {
                return false
            }
        } else if (hasPlus) {
            if (levelLen != 1) {
                return false
            }
        }
        if (isLast) {
            return true
        }
        start = end + 1
    }
    return true
}

/** CONNACK 返回码 → 人话（页面直接把这段文案显示出来，不用自己攒一张表） */
public func mqttReturnCodeText(code: Int64): String {
    if (code == 0) {
        return "连接已接受"
    }
    if (code == 1) {
        return "协议级别不被支持（对端不是 MQTT 3.1.1 服务端？）"
    }
    if (code == 2) {
        return "客户端标识符被拒绝"
    }
    if (code == 3) {
        return "服务端不可用"
    }
    if (code == 4) {
        return "用户名或密码错误"
    }
    if (code == 5) {
        return "未授权"
    }
    return "未知返回码（${code}）"
}

/**
 * 控制报文类型名（日志行与页面「方向/类型」列用的都是它）
 *
 * 用 if 链而不是 match：类型码是 UInt8，拿常量当 match 模式对不上时编译器不会提醒，
 * if 链至少能一眼看出每个分支的取值范围。
 */
public func mqttPacketTypeName(typeCode: UInt8): String {
    if (typeCode == MQTT_PKT_CONNECT) {
        return "CONNECT"
    }
    if (typeCode == MQTT_PKT_CONNACK) {
        return "CONNACK"
    }
    if (typeCode == MQTT_PKT_PUBLISH) {
        return "PUBLISH"
    }
    if (typeCode == MQTT_PKT_PUBACK) {
        return "PUBACK"
    }
    if (typeCode == MQTT_PKT_PUBREC) {
        return "PUBREC"
    }
    if (typeCode == MQTT_PKT_PUBREL) {
        return "PUBREL"
    }
    if (typeCode == MQTT_PKT_PUBCOMP) {
        return "PUBCOMP"
    }
    if (typeCode == MQTT_PKT_SUBSCRIBE) {
        return "SUBSCRIBE"
    }
    if (typeCode == MQTT_PKT_SUBACK) {
        return "SUBACK"
    }
    if (typeCode == MQTT_PKT_UNSUBSCRIBE) {
        return "UNSUBSCRIBE"
    }
    if (typeCode == MQTT_PKT_UNSUBACK) {
        return "UNSUBACK"
    }
    if (typeCode == MQTT_PKT_PINGREQ) {
        return "PINGREQ"
    }
    if (typeCode == MQTT_PKT_PINGRESP) {
        return "PINGRESP"
    }
    if (typeCode == MQTT_PKT_DISCONNECT) {
        return "DISCONNECT"
    }
    return "UNKNOWN(${typeCode})"
}

/**
 * 载荷是不是「能直接看的文本」：不是合法 UTF-8、或含 NUL/控制字符（制表/换行/回车除外）→ None，
 * 页面据此改用十六进制显示。**不做「猜编码」**——MQTT 的载荷可能是任意二进制，猜错比不猜更误导人。
 */
public func mqttBytesToText(bytes: Array<UInt8>): Option<String> {
    if (bytes.size == 0) {
        return Some("")
    }
    var text = ""
    try {
        text = String.fromUtf8(bytes)
    } catch (e: Exception) {
        return None
    }
    for (b in bytes) {
        let c = Int64(b)
        let control = c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D
        if (c == 0 || control || c == 0x7F) {
            return None
        }
    }
    return Some(text)
}
