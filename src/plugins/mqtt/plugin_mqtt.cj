package cjTauri.plugins.mqtt

import cjTauri.*

import std.collection.*
import std.net.*
import std.sync.*
import std.time.*
import stdx.encoding.json.*

/**
 * 官方插件 mqtt：MQTT 3.1.1 客户端（调试工具用）
 *
 * 设计取舍见 `docs/设计决策记录.md` 的 **D-014**（以插件交付、协议用 `std.net` 自实现，不进 C 桥）
 * 与 **D-015**（收报文同时给事件通道与可拉取缓冲）。
 *
 * 命令：`mqtt:connect` / `subscribe` / `unsubscribe` / `publish` / `disconnect` / `status` / `recent`
 * 事件：`mqtt:message`（每条收/发报文）+ `mqtt:state`（连接状态变化）
 * 权限：**不自动放行**，应用要在 capabilities 里显式声明（明文 `"commands"` 或命名集 `"permissions": ["mqtt:debug"]`）
 * 前端：`window.__CJ_TAURI__.mqtt.connect({ host: "127.0.0.1", port: 1883 })`
 *
 * 协议编解码在 `src/plugins/mqtt_codec.cj`（纯函数 + 单测），本文件只管 socket、状态机与缓冲。
 *
 * **边界如实（D-014）**：只做 MQTT 3.1.1（协议级别 4）的明文 TCP。不做 TLS / MQTTS、不做 WebSocket
 * 传输、不做 MQTT 5.0 的属性与原因码；**连不上就给明确错误，不静默重试**——调试工具最怕
 * 「看着连上了其实没有」。
 *
 * 线程模型：socket 的**读侧由读线程独占**（`mqttReaderThread`），命令侧只写。两侧共用的状态
 * 一律在 `MqttSession.lock` 下访问；两条线程都不会调 GTK / WebKit——事件经 `app.emit()` → 桥的
 * jsSink 回投（两平台桥的 runJs 都是「加锁入队 + 投递到宿主 UI 线程」，任意线程调用都安全，
 * 见 `src/ipc_hub.cj` 的线程模型注释）。读侧用 `readTimeout` 当**时基**：每 tick 醒来一次做保活与
 * 下线检查，因此不必额外引入 select（D-014）。
 */

/** `mqtt:recent` 环形缓冲上限（条）：超限丢最旧并计入 dropped（D-015） */
let MQTT_RECENT_LIMIT: Int64 = 500

/** 单条正文进缓冲 / 事件前的截断上限：256 KiB（D-015）。超了照实报 `truncated`，不假装全量 */
let MQTT_RECENT_BODY_LIMIT: Int64 = 262144

/** 读线程的读超时（毫秒）：它就是保活与下线检查的时基（D-014） */
let MQTT_READ_TICK_MS: Int64 = 500

/** 建连超时（毫秒）：死地址不能把命令 worker 挂住 */
let MQTT_CONNECT_TIMEOUT_MS: Int64 = 5000

/** 一条报文从首字节到收齐的最长时长（毫秒）：半条报文不许进状态机（凑不齐就判连接坏） */
let MQTT_PACKET_DEADLINE_MS: Int64 = 10000

/** 默认保活（秒）；0 = 关闭保活 */
let MQTT_DEFAULT_KEEPALIVE_SEC: Int64 = 60

/** 等回执（SUBACK / PUBACK 等）的轮询步长与上限（毫秒）：命令 worker 上的**有界**等待 */
let MQTT_WAIT_STEP_MS: Int64 = 20
let MQTT_WAIT_TIMEOUT_MS: Int64 = 5000

/**
 * 插件的全部命令短名（`permissions()` 的 `debug` 集就是它，别再抄第二份）。
 *
 * 用 `let` 而不是 `const`：仓颉的 `const` 只收编译期常量表达式，`Array` 字面量编译不过（AGENTS §4）。
 */
let MQTT_PLUGIN_COMMANDS: Array<String> = [
    "connect", "disconnect", "subscribe", "unsubscribe", "publish", "status", "recent"
]

/**
 * 一条 MQTT 连接的全部可变状态（**所有字段都在 lock 下访问**——读线程与命令 worker 是两个线程）。
 *
 * 为什么不做成「每个命令各自持有 socket」：MQTT 是**有状态**的长连接协议，报文标识符、订阅表、
 * QoS 待确认表都是连接级的；拆开写等于让每条命令自己维护一半状态机。
 */
class MqttSession {
    let lock: Mutex = Mutex()

    /** 连接的 socket（None = 未连接）；读侧由读线程独占 */
    var sock: Option<TcpSocket> = None

    /** idle / connecting / connected / closed / error：页面直接显示，所以用字符串而不是枚举 */
    var state: String = "idle"
    var host: String = ""
    var port: Int64 = 1883
    var clientId: String = ""
    var keepaliveSec: Int64 = MQTT_DEFAULT_KEEPALIVE_SEC
    var cleanSession: Bool = true

    /** 读线程是否在跑；stopRequested 是「请读线程退出」的旗标 */
    var readerAlive: Bool = false
    var stopRequested: Bool = false

    /** 序号与计数：seq 给页面去重（同一条消息事件一次、recent 一次，D-015），其余供 status 对账 */
    var seq: Int64 = 0
    var rxCount: Int64 = 0
    var txCount: Int64 = 0
    var dropped: Int64 = 0
    var lastError: String = ""

    /** 最近一次收发时刻：保活判定用（「半个周期内没有任何发出」才发 PINGREQ） */
    var lastTxAt: DateTime = DateTime.now()
    var lastRxAt: DateTime = DateTime.now()

    /** 下一个报文标识符（1..65535；0 是非法值，回绕时跳过） */
    var nextPacketId: Int64 = 1

    /** 出站 QoS 1/2 的待确认表：报文标识符 → 阶段（puback / pubrec / pubcomp） */
    var pending: HashMap<Int64, String> = HashMap<Int64, String>()

    /** 已订阅的过滤器 → 授予的 QoS（SUBACK 到达时回填；-2 表示「还没回执」） */
    var subs: HashMap<String, Int64> = HashMap<String, Int64>()

    /** SUBACK 结果：报文标识符 → 授予码列表（`subscribe` 命令的有界等待读它） */
    var subacks: HashMap<Int64, ArrayList<Int64>> = HashMap<Int64, ArrayList<Int64>>()

    /** 环形缓冲（元素是给前端的 JSON）；满了丢最旧并累计 dropped */
    var recent: ArrayList<JsonValue> = ArrayList<JsonValue>()

    /** app 引用：`MqttPlugin.setup()` 装配进来，事件回投要用它 */
    var app: Option<TauriApp> = None
}

/** 取一个新的报文标识符（调用方须持锁）：0 非法，65535 之后回绕到 1 */
func mqttTakePacketIdLocked(sess: MqttSession): Int64 {
    let id = sess.nextPacketId
    sess.nextPacketId += 1
    if (sess.nextPacketId > 65535) {
        sess.nextPacketId = 1
    }
    return id
}

/**
 * 记一条报文：**赋 seq → 入缓冲（超限丢最旧并计 dropped）→ 推事件**，两条路在这里收口。
 *
 * 顺序刻意固定：先入缓冲再推事件——清单没声明 `events` 时事件会被框架丢弃（打一行 stderr），
 * 而 `recent` 照旧拿得到，这正是 D-015 要的那条兜底。
 *
 * 调用方**不要**持有 `sess.lock`（本函数自己加锁）。
 */
func mqttRecord(sess: MqttSession, obj: JsonObject): Unit {
    var app: Option<TauriApp> = None
    sess.lock.lock()
    sess.seq += 1
    obj.put("seq", JsonInt(sess.seq))
    obj.put("ts", JsonString(DateTime.now().toString()))
    app = sess.app
    sess.recent.add(obj)
    // 超限：整块搬一次最旧的 N 条，代价 O(上限)，500 条量级可忽略；
    // 不用集合层的删除重载是为了让「丢的是什么」在这段代码里一眼可见（dropped 必须如实对得上）
    if (sess.recent.size > MQTT_RECENT_LIMIT) {
        let from = sess.recent.size - MQTT_RECENT_LIMIT
        let keep = ArrayList<JsonValue>()
        var i: Int64 = from
        while (i < sess.recent.size) {
            keep.add(sess.recent[i])
            i += 1
        }
        sess.dropped += from
        sess.recent = keep
        eprintln("[cj-tauri] mqtt: recent 缓冲超限，丢弃最旧 ${from} 条（累计 dropped=${sess.dropped}）")
    }
    sess.lock.unlock()
    match (app) {
        case Some(a) => a.emit("mqtt:message", obj)
        case None => ()
    }
}

/**
 * 推 `mqtt:state`：连接状态是页面最需要**立刻**知道的事（被拒 / 掉线不能只躺在缓冲里）。
 * 调用方不要持锁。
 */
func mqttEmitState(sess: MqttSession): Unit {
    var app: Option<TauriApp> = None
    let obj = JsonObject()
    var line = ""
    sess.lock.lock()
    app = sess.app
    obj.put("state", JsonString(sess.state))
    obj.put("host", JsonString(sess.host))
    obj.put("port", JsonInt(sess.port))
    obj.put("clientId", JsonString(sess.clientId))
    obj.put("keepaliveSec", JsonInt(sess.keepaliveSec))
    obj.put("error", JsonString(sess.lastError))
    obj.put("rx", JsonInt(sess.rxCount))
    obj.put("tx", JsonInt(sess.txCount))
    obj.put("dropped", JsonInt(sess.dropped))
    // 状态变迁同时落一行 stderr：事件通道页面没接住时（没声明 events / 页面在重载），
    // 「连上过没有、什么时候掉的」仍能端到端对账——这与框架其余能力的取证口径一致（AGENTS §1）
    line = "state=${sess.state} host=${sess.host}:${sess.port} rx=${sess.rxCount} tx=${sess.txCount}" +
        " dropped=${sess.dropped}"
    sess.lock.unlock()
    eprintln("[cj-tauri] mqtt: ${line}")
    match (app) {
        case Some(a) => a.emit("mqtt:state", obj)
        case None => ()
    }
}

/**
 * 置会话为错误态：停读线程、关 socket、记原因、推 `mqtt:state`。
 *
 * 读线程与命令 worker 都可能调它（读失败 / 写失败 / 握手失败），所以必须**幂等**：
 * 谁先到谁把原因写进去，后到的看到 socket 已经是 None 就只收尾。
 */
func mqttFailSession(sess: MqttSession, reason: String): Unit {
    var sock: Option<TcpSocket> = None
    var first = false
    sess.lock.lock()
    sock = sess.sock
    sess.sock = None
    if (sess.state != "error") {
        first = true
        sess.state = "error"
        sess.lastError = reason
    }
    sess.stopRequested = true
    sess.readerAlive = false
    sess.lock.unlock()
    match (sock) {
        case Some(s) =>
            try {
                s.close()
            } catch (e: Exception) {
                let _ = e
            }
        case None => ()
    }
    if (first) {
        eprintln("[cj-tauri] mqtt: ${reason}")
    }
    mqttEmitState(sess)
}

/**
 * 写一条报文（lock 内写 socket + 更新 lastTxAt / txCount），**不记日志**。
 *
 * 需要按 PUBLISH 语义记日志的调用方（发布命令）用它，再自己调 `mqttLogPublish`——
 * 一条报文只该在日志里出现一次，记两次会让页面把同一次发送看成两件事。
 *
 * 写失败一律置会话错误态并抛出 `CommandException`——调试工具宁可当场报错，也不留一个
 * 「看起来还在连」的会话（AGENTS §1 的如实交付口径）。
 */
func mqttSendBytes(sess: MqttSession, sock: TcpSocket, raw: Array<UInt8>): Unit {
    sess.lock.lock()
    try {
        sock.write(raw)
        sess.lastTxAt = DateTime.now()
        sess.txCount += 1
    } catch (e: Exception) {
        sess.lock.unlock()
        mqttFailSession(sess, "写入失败：${e.message}")
        throw CommandException("mqtt: 写入失败（${e.message}）")
    }
    sess.lock.unlock()
}

/** 写一条报文 + 记一条原始日志（控制类报文用的就是它） */
func mqttSend(sess: MqttSession, sock: TcpSocket, raw: Array<UInt8>, typeName: String,
              note: String): Unit {
    mqttSendBytes(sess, sock, raw)
    mqttLogRaw(sess, "tx", raw, typeName, note)
}

/**
 * 把一条**原始报文**拼成日志记录（tx 侧与 rx 侧共用）。
 *
 * 正文按 `MQTT_RECENT_BODY_LIMIT` 截断：超长时只发前 256 KiB 的十六进制，并置 `truncated`——
 * 页面照实显示「已截断」，不让人以为手里是完整报文（D-015 的代价一节）。
 */
func mqttLogRaw(sess: MqttSession, dir: String, raw: Array<UInt8>, typeName: String,
                note: String): Unit {
    let obj = JsonObject()
    let shown = if (raw.size > MQTT_RECENT_BODY_LIMIT) { MQTT_RECENT_BODY_LIMIT } else { raw.size }
    obj.put("dir", JsonString(dir))
    obj.put("typeName", JsonString(typeName))
    obj.put("note", JsonString(note))
    obj.put("bytes", JsonInt(raw.size))
    obj.put("truncated", JsonBool(shown < raw.size))
    obj.put("hex", JsonString(bytesToHex(raw[0..shown])))
    mqttRecord(sess, obj)
}

/**
 * 读满 n 字节。**超时不算错**：每 tick 醒来做保活与停止检查，直到凑齐或超过整包时限。
 *
 * @param startedAt 本包首字节的到达时刻（整包时限从它算起）
 * @param allowTick true（读线程）= 超时做保活；false（建连握手，读线程还没起）= 超时只对时针
 * @return None 表示连接已经不可用（已置状态、已停读线程），调用方直接收摊
 */
func mqttReadExact(sess: MqttSession, sock: TcpSocket, n: Int64, startedAt: DateTime,
                   allowTick: Bool): Option<Array<UInt8>> {
    let out = Array<UInt8>(n, repeat: 0)
    var got: Int64 = 0
    while (got < n) {
        // 临时缓冲再拷贝：socket.read 只会从缓冲区头部开始填，把 out 的切片交给它，
        // 切片若是拷贝语义就白读了（examples/modbus-poll 同款处理）
        let tmp = Array<UInt8>(n - got, repeat: 0)
        var c: Int64 = 0
        try {
            c = sock.read(tmp)
        } catch (e: SocketTimeoutException) {
            if (allowTick && !mqttKeepaliveTick(sess, sock)) {
                return None
            }
            if ((DateTime.now() - startedAt).toMilliseconds() > MQTT_PACKET_DEADLINE_MS) {
                mqttFailSession(sess, "报文收齐超时（已收 ${got}/${n} 字节，判连接不可用）")
                return None
            }
            continue
        } catch (e: Exception) {
            mqttFailSession(sess, "读取失败：${e.message}")
            return None
        }
        if (c <= 0) {
            mqttFailSession(sess, "对端关闭了连接")
            return None
        }
        var i: Int64 = 0
        while (i < c) {
            out[got + i] = tmp[i]
            i += 1
        }
        got += c
        sess.lock.lock()
        sess.lastRxAt = DateTime.now()
        sess.lock.unlock()
    }
    return Some(out)
}

/** 读到的剩余长度：值 + 占用的字节（原样留着，拼整条报文时要用） */
class MqttReadLength {
    var value: Int64 = 0
    var raw: Array<UInt8> = Array<UInt8>()
}

/**
 * 从流里读变长剩余长度（最多 4 字节）。读不齐 / 凑不成 → None（调用方收摊）。
 * 这里**不重复实现解码规则**：拿到字节后交给 `mqttDecodeRemainingLength` 判合法。
 */
func mqttReadRemainingLength(sess: MqttSession, sock: TcpSocket,
                             startedAt: DateTime): Option<MqttReadLength> {
    let bytes = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < 4) {
        match (mqttReadExact(sess, sock, 1, startedAt, true)) {
            case None => return None
            case Some(one) => bytes.add(one[0])
        }
        let last = bytes[bytes.size - 1]
        if ((Int64(last) & 0x80) == 0) {
            let raw = Array<UInt8>(bytes.size, repeat: 0)
            var j: Int64 = 0
            while (j < bytes.size) {
                raw[j] = bytes[j]
                j += 1
            }
            match (mqttDecodeRemainingLength(raw, 0)) {
                case None => return None
                case Some(rl) =>
                    let out = MqttReadLength()
                    out.value = rl.value
                    out.raw = raw
                    return Some(out)
            }
        }
        i += 1
    }
    mqttFailSession(sess, "剩余长度超过 4 字节（畸形报文，判连接不可用）")
    return None
}

/**
 * 读线程每 tick 调一次：到点发 PINGREQ，并检查停止请求。
 * 返回 false = 读线程该退出了（收到了停止请求）。
 */
func mqttKeepaliveTick(sess: MqttSession, sock: TcpSocket): Bool {
    var keepalive: Int64 = 0
    var stopped = false
    var lastTx = DateTime.now()
    sess.lock.lock()
    keepalive = sess.keepaliveSec
    // 停止信号**只看 stopRequested**：readerAlive 是「读线程在跑」的事实描述，拿它当停止条件的话，
    // 建连握手期（读线程还没起、readerAlive 还是 false）的一次读超时会被误判成「连接完了」——
    // 于是 CONNACK 永远等不到，连接却报「握手失败」。停读线程一律走 stopRequested。
    stopped = sess.stopRequested
    lastTx = sess.lastTxAt
    sess.lock.unlock()
    if (stopped) {
        return false
    }
    if (keepalive <= 0) {
        return true
    }
    // 半个保活周期内一个字节都没发过才发心跳：协议要求「不超过 1.5 倍保活时间内必须有报文」，
    // 半个周期发一次留足余量，也避免正常发布流量下多发无用心跳
    if ((DateTime.now() - lastTx).toMilliseconds() >= (keepalive * 1000) / 2) {
        try {
            mqttSend(sess, sock, mqttEncodePingreq(), "PINGREQ", "保活心跳（${keepalive}s 周期）")
        } catch (e: CommandException) {
            let _ = e
            return false
        }
    }
    return true
}

// ---------------------------------------------------------------- 收侧：报文分派与读线程

/**
 * 清理已完结的表项（调用方持锁）：`pending` 里标了 done 的、`subacks` 里已被取走的空列表，
 * 整块搬到新表。**不做单条删除**（与环形缓冲同一套做法：用哪条路一眼可见，也少依赖集合层重载）。
 */
func mqttCompactLocked(sess: MqttSession): Unit {
    if (sess.pending.size > 256) {
        let keep = HashMap<Int64, String>()
        for ((id, stage) in sess.pending) {
            if (stage != "done") {
                keep.add(id, stage)
            }
        }
        sess.pending = keep
    }
    if (sess.subacks.size > 64) {
        let keep = HashMap<Int64, ArrayList<Int64>>()
        for ((id, granted) in sess.subacks) {
            if (granted.size > 0) {
                keep.add(id, granted)
            }
        }
        sess.subacks = keep
    }
}

/** 记一条 PUBLISH（收发两侧共用）：主题 / 位域 / 载荷全摊开，页面直接渲染 */
func mqttLogPublish(sess: MqttSession, dir: String, raw: Array<UInt8>, pub: MqttPublish,
                    note: String): Unit {
    let obj = JsonObject()
    let shown = if (raw.size > MQTT_RECENT_BODY_LIMIT) { MQTT_RECENT_BODY_LIMIT } else { raw.size }
    let payloadShown = if (pub.payload.size > MQTT_RECENT_BODY_LIMIT) {
        MQTT_RECENT_BODY_LIMIT
    } else {
        pub.payload.size
    }
    obj.put("dir", JsonString(dir))
    obj.put("typeName", JsonString("PUBLISH"))
    obj.put("topic", JsonString(pub.topic))
    obj.put("qos", JsonInt(pub.qos))
    obj.put("retain", JsonBool(pub.retain))
    obj.put("dup", JsonBool(pub.dup))
    obj.put("packetId", JsonInt(pub.packetId))
    obj.put("bytes", JsonInt(raw.size))
    obj.put("payloadBytes", JsonInt(pub.payload.size))
    obj.put("truncated", JsonBool(shown < raw.size || payloadShown < pub.payload.size))
    obj.put("hex", JsonString(bytesToHex(raw[0..shown])))
    obj.put("payloadHex", JsonString(bytesToHex(pub.payload[0..payloadShown])))
    // 载荷是任意二进制：能当文本看就给文本，不能就给 null（键始终在，页面按 null 判断改用十六进制）
    match (mqttBytesToText(pub.payload[0..payloadShown])) {
        case Some(t) => obj.put("payloadText", JsonString(t))
        case None => obj.put("payloadText", JsonNull())
    }
    obj.put("note", JsonString(note))
    mqttRecord(sess, obj)
}

/**
 * 收到的 PUBLISH 按 QoS 自动应答。**这不是可选项**：QoS 1 不回 PUBACK、QoS 2 不回 PUBREC，
 * broker 就会一直重发，页面看到的现象是「同一条消息刷屏」——协议层的自动应答在插件里做掉，
 * 页面不必自己实现协议。
 */
func mqttAckInbound(sess: MqttSession, sock: TcpSocket, pub: MqttPublish): Unit {
    if (!pub.hasPacketId) {
        return
    }
    if (pub.qos == 1) {
        mqttSend(sess, sock, mqttEncodeAck(MQTT_PKT_PUBACK, pub.packetId), "PUBACK",
            "自动应答（QoS 1：确认收到报文标识符 ${pub.packetId}）")
    } else if (pub.qos == 2) {
        mqttSend(sess, sock, mqttEncodeAck(MQTT_PKT_PUBREC, pub.packetId), "PUBREC",
            "自动应答（QoS 2 第一步：已记录报文标识符 ${pub.packetId}）")
    }
}

/** 收到的确认类报文（PUBACK / PUBREC / PUBREL / PUBCOMP）：更新待确认表，QoS 2 按协议续下一步 */
func mqttHandleAck(sess: MqttSession, sock: TcpSocket, p: MqttPacket, raw: Array<UInt8>): Unit {
    let typeName = mqttPacketTypeName(p.typeCode)
    let id = mqttParsePacketId(p)
    if (id < 0) {
        mqttLogRaw(sess, "rx", raw, typeName, "缺报文标识符，已忽略")
        return
    }
    var note = ""
    var needPubrel = false
    var needPubcomp = false
    sess.lock.lock()
    match (sess.pending.get(id)) {
        case Some(stage) =>
            if (p.typeCode == MQTT_PKT_PUBACK) {
                sess.pending.add(id, "done")
                note = "QoS 1 投递完成（${stage} → done）"
            } else if (p.typeCode == MQTT_PKT_PUBREC) {
                sess.pending.add(id, "pubcomp")
                note = "QoS 2 第一步回执，正发 PUBREL"
                needPubrel = true
            } else if (p.typeCode == MQTT_PKT_PUBREL) {
                note = "QoS 2 对端释放（我方回 PUBCOMP）"
                needPubcomp = true
            } else {
                sess.pending.add(id, "done")
                note = "QoS 2 投递完成（${stage} → done）"
            }
        case None =>
            // 没登记过的标识符：不猜它是谁的，如实记一条（可能是上一轮连接的残留 / 对端重发）
            if (p.typeCode == MQTT_PKT_PUBREL) {
                note = "未登记的 PUBREL（无上下文，仍按协议回 PUBCOMP）"
                needPubcomp = true
            } else {
                note = "未登记的确认报文（报文标识符 ${id}），已忽略"
            }
    }
    sess.lock.unlock()
    mqttLogRaw(sess, "rx", raw, typeName, note)
    if (needPubrel) {
        mqttSend(sess, sock, mqttEncodeAck(MQTT_PKT_PUBREL, id), "PUBREL",
            "QoS 2 第二步：释放报文标识符 ${id}")
    }
    if (needPubcomp) {
        mqttSend(sess, sock, mqttEncodeAck(MQTT_PKT_PUBCOMP, id), "PUBCOMP",
            "QoS 2 收官：报文标识符 ${id} 已完成")
    }
}

/**
 * 收到的 SUBACK / UNSUBACK：SUBACK 的授予码列表回填 `subacks`（`subscribe` 命令的有界等待读它），
 * 返回给日志用的一句说明。**UNSUBACK 在协议里不带原因**，记一条即止。
 */
func mqttHandleSuback(sess: MqttSession, p: MqttPacket, raw: Array<UInt8>): Unit {
    let typeName = mqttPacketTypeName(p.typeCode)
    if (p.typeCode == MQTT_PKT_UNSUBACK) {
        let id = mqttParsePacketId(p)
        mqttLogRaw(sess, "rx", raw, typeName, "退订回执（报文标识符 ${id}）")
        return
    }
    match (mqttParseSuback(p)) {
        case None =>
            mqttLogRaw(sess, "rx", raw, typeName, "SUBACK 结构非法（缺报文标识符或授予码），已忽略")
        case Some(granted) =>
            let id = mqttParsePacketId(p)
            var text = ""
            var i: Int64 = 0
            while (i < granted.size) {
                if (text.size > 0) {
                    text += ", "
                }
                if (granted[i] == 0x80) {
                    text += "订阅失败(0x80)"
                } else {
                    text += "QoS ${granted[i]}"
                }
                i += 1
            }
            sess.lock.lock()
            sess.subacks.add(id, granted)
            sess.lock.unlock()
            mqttLogRaw(sess, "rx", raw, typeName, "订阅回执（报文标识符 ${id}，授予 ${text}）")
    }
}

/** 其余报文的日志说明：只有少数几种会在本插件的状态机里出现 */
func mqttPlainNote(p: MqttPacket): String {
    if (p.typeCode == MQTT_PKT_PINGRESP) {
        return "心跳应答"
    }
    if (p.typeCode == MQTT_PKT_CONNACK) {
        return "重复 CONNACK（握手期间已处理，这里只记日志）"
    }
    return ""
}

/**
 * 处理一条收到的报文（读线程上调用）。**先记日志再动作**——顺序固定，日志里就是线上顺序，
 * 排查时不会出现「响应排在了请求前面」这种自相矛盾的时间线。
 */
func mqttHandlePacket(sess: MqttSession, sock: TcpSocket, p: MqttPacket, raw: Array<UInt8>): Unit {
    sess.lock.lock()
    sess.rxCount += 1
    sess.lock.unlock()
    if (p.typeCode == MQTT_PKT_PUBLISH) {
        match (mqttParsePublish(p)) {
            case None =>
                // 位域非法（QoS=3 这种保留值）：记一条「拒收」，不让脏报文进页面冒充数据
                mqttLogRaw(sess, "rx", raw, "PUBLISH", "非法 PUBLISH（QoS 保留值或缺字段），已丢弃")
            case Some(pub) =>
                var note = "收到消息（QoS ${pub.qos}）"
                if (pub.retain) {
                    note += " · retain"
                }
                if (pub.dup) {
                    note += " · dup"
                }
                mqttLogPublish(sess, "rx", raw, pub, note)
                mqttAckInbound(sess, sock, pub)
        }
        return
    }
    if (p.typeCode == MQTT_PKT_SUBACK || p.typeCode == MQTT_PKT_UNSUBACK) {
        mqttHandleSuback(sess, p, raw)
        return
    }
    if (p.typeCode == MQTT_PKT_PUBACK || p.typeCode == MQTT_PKT_PUBREC ||
        p.typeCode == MQTT_PKT_PUBREL || p.typeCode == MQTT_PKT_PUBCOMP) {
        mqttHandleAck(sess, sock, p, raw)
        return
    }
    mqttLogRaw(sess, "rx", raw, mqttPacketTypeName(p.typeCode), mqttPlainNote(p))
}

/** 把已读到的三段（固定头首字节 / 剩余长度字节 / body）拼回整条报文：decode 要的是完整字节 */
func mqttConcatFrame(head: Array<UInt8>, lenBytes: Array<UInt8>, body: Array<UInt8>): Array<UInt8> {
    let out = Array<UInt8>(1 + lenBytes.size + body.size, repeat: 0)
    out[0] = head[0]
    var i: Int64 = 0
    while (i < lenBytes.size) {
        out[1 + i] = lenBytes[i]
        i += 1
    }
    var j: Int64 = 0
    while (j < body.size) {
        out[1 + lenBytes.size + j] = body[j]
        j += 1
    }
    return out
}

/**
 * 读回来的「一条报文」：raw 是拼好的整条帧（含长度字段），packet 是解码结果。
 * 解码失败时 `packet` 为 None 而 `raw` 仍然留着——畸形报文也是证据，不能因为解不出就丢字节。
 */
class MqttReadPacket {
    var raw: Array<UInt8> = Array<UInt8>()
    var packet: Option<MqttPacket> = None
}

/**
 * 从流里读齐一条完整报文并解码：固定头首字节 → 变长剩余长度 → body → 拼回整帧 → `mqttDecodePacket`。
 * 返回 None = 连接已不可用（读错 / 收齐超时 / 对端关闭，状态已置好），调用方直接收摊。
 *
 * 握手（等 CONNACK）与读线程用**同一个**函数：读一条报文的规则只该有一份。
 */
func mqttReadOne(sess: MqttSession, sock: TcpSocket): Option<MqttReadPacket> {
    let started = DateTime.now()
    var head = Array<UInt8>()
    match (mqttReadExact(sess, sock, 1, started, true)) {
        case None => return None
        case Some(h) => head = h
    }
    var rlRaw = Array<UInt8>()
    var rlValue: Int64 = 0
    match (mqttReadRemainingLength(sess, sock, started)) {
        case None => return None
        case Some(rl) =>
            rlRaw = rl.raw
            rlValue = rl.value
    }
    var body = Array<UInt8>()
    if (rlValue > 0) {
        match (mqttReadExact(sess, sock, rlValue, started, true)) {
            case None => return None
            case Some(b) => body = b
        }
    }
    let out = MqttReadPacket()
    out.raw = mqttConcatFrame(head, rlRaw, body)
    out.packet = mqttDecodePacket(out.raw)
    return Some(out)
}

/**
 * 读线程主体：独占 socket 读侧，直到连接结束（对端关闭 / 读错 / 命令要求停止）。
 *
 * **所有出口都走同一个收口**（置状态、关 socket、推 `mqtt:state`）：分开写的话迟早漏一条，
 * 页面就会停在一个「已经死了但状态还写着 connected」的会话上。停止信号只看 `stopRequested`。
 */
func mqttReaderThread(sess: MqttSession, sock: TcpSocket): Unit {
    while (true) {
        sess.lock.lock()
        let stop = sess.stopRequested
        sess.lock.unlock()
        if (stop) {
            break
        }
        var rp = MqttReadPacket()
        var exit = false
        match (mqttReadOne(sess, sock)) {
            case None => exit = true
            case Some(v) => rp = v
        }
        if (exit) {
            break
        }
        match (rp.packet) {
            case None =>
                // 老实按字节读回来的帧也过一遍解码器：长度对不上就当畸形报文记一条，不猜它的意图
                mqttLogRaw(sess, "rx", rp.raw, "MALFORMED", "长度字段与实收字节对不上，已丢弃")
            case Some(p) => mqttHandlePacket(sess, sock, p, rp.raw)
        }
        // 表项清理搭在收包计数上（每 64 条一次）：不另起定时器，也不让两张表随长连接无限长大
        sess.lock.lock()
        let rx = sess.rxCount
        if (rx > 0 && rx % 64 == 0) {
            mqttCompactLocked(sess)
        }
        sess.lock.unlock()
    }
    // 收口：先判「是被要求停（disconnect）还是自己死的（error / 对端断开）」，再统一推状态
    var sockOpt: Option<TcpSocket> = None
    sess.lock.lock()
    sess.readerAlive = false
    if (sess.state == "connected") {
        sess.state = "closed"
    }
    sockOpt = sess.sock
    sess.sock = None
    sess.lock.unlock()
    match (sockOpt) {
        case Some(s) =>
            try {
                s.close()
            } catch (e: Exception) {
                let _ = e
            }
        case None => ()
    }
    mqttEmitState(sess)
}

// ---------------------------------------------------------------- 命令侧：参数解析与各命令实现

/** 重连前等旧读线程收尾的上限（毫秒）：等不到就照直打一行 stderr 再继续，不无限期挂在命令里 */
let MQTT_READER_EXIT_WAIT_MS: Int64 = 1000

/**
 * mqtt 插件的命令处理器：七个命令共用一份，按全名分派（与 SerialCommands 同形）。
 *
 * **每次 connect 都换一份新会话**，不复用上一份状态：旧连接的读线程只会碰它自己那份会话，
 * 于是永远不会误关新连接的 socket、也不会覆盖新连接的状态。重连路径额外做一件事——
 * 先让旧读线程收尾（`closePrevious`），否则它退出时推的那条「closed」可能落在新连接的
 * 「connected」之后，页面就莫名其妙显成断线。改这块时别把这两条拆掉。
 */
class MqttCommands <: CommandHandler {
    /** 保护 current 指针：命令在 worker 线程上执行，页面连点 / 多条命令同时飞都是常态 */
    private let lock: Mutex = Mutex()
    private var current: MqttSession = MqttSession()
    private var app: Option<TauriApp> = None

    public init() {}

    /** 由 MqttPlugin.setup() 调用：拿 app 才能推事件（mqtt:message / mqtt:state） */
    public func attachApp(a: TauriApp): Unit {
        this.app = Some(a)
        this.lock.lock()
        this.current.app = this.app
        this.lock.unlock()
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = ipc
        match (cmd) {
            case "mqtt:connect" => this.connectCmd(args)
            case "mqtt:disconnect" => this.disconnectCmd(args)
            case "mqtt:subscribe" => this.subscribeCmd(args)
            case "mqtt:unsubscribe" => this.unsubscribeCmd(args)
            case "mqtt:publish" => this.publishCmd(args)
            case "mqtt:status" => this.statusCmd(args)
            case "mqtt:recent" => this.recentCmd(args)
            case _ => throw CommandException("unknown mqtt command: ${cmd}")
        }
    }

    /** 取当前会话（拿的是引用；字段读写由调用方自己加锁） */
    private func session(): MqttSession {
        this.lock.lock()
        let s = this.current
        this.lock.unlock()
        return s
    }

    /**
     * 就绪检查：没连上就明确报错，不进后续流程。
     * 调试工具最怕「命令看着发出去了，其实没连」——所以 publish/subscribe 一律先过这道门。
     */
    private func requireSocket(sess: MqttSession): TcpSocket {
        sess.lock.lock()
        let st = sess.state
        let sock = sess.sock
        sess.lock.unlock()
        if (st != "connected") {
            throw CommandException("mqtt: 未连接（当前状态 ${st}），请先 mqtt:connect")
        }
        match (sock) {
            case Some(s) => s
            case None => throw CommandException("mqtt: 连接已断开（socket 已回收），请重新 connect")
        }
    }

    /**
     * 重连之前先收掉上一条连接：不先收，页面上反复点「连接」会攒下一堆没人管的连接。
     *
     * 顺序是刻意的：**先置停止旗标 → 发 DISCONNECT（尽力而为）→ 有界等旧读线程退出 → 再关 socket**。
     * 旧读线程退出时必然会推一条状态事件，等它落定之后再建新连接，页面就不会被那条旧事件
     * 覆盖成「断线」（这一条比省 100~500ms 重要）。
     */
    private func closePrevious(): Unit {
        let old = this.session()
        var sockOpt: Option<TcpSocket> = None
        old.lock.lock()
        sockOpt = old.sock
        old.stopRequested = true
        if (old.state == "connected" || old.state == "connecting") {
            old.state = "closed"
        }
        old.lock.unlock()
        match (sockOpt) {
            case Some(sock) =>
                // 协议层面的正常下线：broker 收到 DISCONNECT 就不会替我们代发遗嘱，也会主动关连接
                // （对端一关，旧读线程立刻从 read 回来，不必等满一个读超时）
                try {
                    sock.write(mqttEncodeDisconnect())
                } catch (e: Exception) {
                    let _ = e
                }
            case None => ()
        }
        this.waitReaderExit(old)
        match (sockOpt) {
            case Some(sock) =>
                try {
                    sock.close()
                } catch (e: Exception) {
                    let _ = e
                }
            case None => ()
        }
    }

    /** 有界等旧读线程收尾：等不到就如实打一行 stderr 再继续（不把命令无限期挂住） */
    private func waitReaderExit(sess: MqttSession): Unit {
        var waited: Int64 = 0
        while (waited < MQTT_READER_EXIT_WAIT_MS) {
            sess.lock.lock()
            let alive = sess.readerAlive
            sess.lock.unlock()
            if (!alive) {
                return
            }
            sleep(Duration.millisecond * MQTT_WAIT_STEP_MS)
            waited += MQTT_WAIT_STEP_MS
        }
        eprintln("[cj-tauri] mqtt: 上一条连接的读线程未在 ${MQTT_READER_EXIT_WAIT_MS}ms 内收尾，继续建新连接")
    }

    /** 取会话记下的失败原因（没有就用 fallback）——失败原因只有会话知道，别让页面去猜 */
    private func errorOf(sess: MqttSession, fallback: String): String {
        sess.lock.lock()
        let e = sess.lastError
        sess.lock.unlock()
        if (e.size == 0) {
            return fallback
        }
        return e
    }

    /** CONNACK 的日志说明：返回码翻成人话，页面不必自己攒一张表 */
    private func connackNote(p: MqttPacket): String {
        match (mqttParseConnack(p)) {
            case Some(c) =>
                "返回码 ${c.returnCode}（${mqttReturnCodeText(c.returnCode)}），sessionPresent=${c.sessionPresent}"
            case None => "结构非法（不是 2 字节的变长头）"
        }
    }

    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => v.asString().getValue()
                case _ => throw CommandException("mqtt: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("mqtt: missing argument \"${key}\"")
        }
    }

    /** 可选字符串参数：缺失 / null 都按空串 */
    private func optionalString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => v.asString().getValue()
                case JsonKind.JsNull => ""
                case _ => throw CommandException("mqtt: argument \"${key}\" must be a string")
            }
            case None => ""
        }
    }

    /** 可选字符串参数（要区分「没给」与「给了空串」时用它，例如 username / password） */
    private func optionalStringValue(args: JsonObject, key: String): Option<String> {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => Some(v.asString().getValue())
                case JsonKind.JsNull => None
                case _ => throw CommandException("mqtt: argument \"${key}\" must be a string")
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
                    mqttClampInt(Int64(v.asFloat().getValue()), -65536, 65536)
                case JsonKind.JsNull => fallback
                case _ => throw CommandException("mqtt: argument \"${key}\" must be a number")
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
                case _ => throw CommandException("mqtt: argument \"${key}\" must be a boolean")
            }
            case None => fallback
        }
    }

    /**
     * `mqtt:connect { host, port?, clientId?, keepaliveSec?, cleanSession?, username?, password? }`
     *
     * 握手在**本命令线程上同步做**（发 CONNECT → 等 CONNACK → 起读线程）：CONNACK 的结果随命令结果
     * 直接回给前端，页面不用猜「到底连上没有」；读线程晚一步启动，两侧永远不会同时读同一个 socket。
     *
     * 不支持的（如实报错，不假装支持）：TLS / WebSocket 传输、遗嘱报文、MQTT 5.0。
     */
    private func connectCmd(args: JsonObject): JsonValue {
        let host = this.requireString(args, "host")
        let port = this.optionalInt(args, "port", 1883)
        let clientIdRaw = this.optionalString(args, "clientId")
        let keepalive = this.optionalInt(args, "keepaliveSec", MQTT_DEFAULT_KEEPALIVE_SEC)
        let clean = this.optionalBool(args, "cleanSession", true)
        let username = this.optionalStringValue(args, "username")
        let password = this.optionalStringValue(args, "password")
        if (!mqttValidHost(host)) {
            throw CommandException("mqtt: host 非法（只收 IP / 主机名的安全字符 [A-Za-z0-9._-]，长度 1..253）")
        }
        if (!mqttValidPort(port)) {
            throw CommandException("mqtt: port 非法（须在 1..65535）")
        }
        if (keepalive < 0 || keepalive > 65535) {
            throw CommandException("mqtt: keepaliveSec 非法（0..65535；0 表示关闭保活）")
        }
        this.closePrevious()
        // 新会话（不复用旧状态）：旧读线程只碰它自己那份，见类注释
        let sess = MqttSession()
        sess.host = host
        sess.port = port
        sess.clientId = if (clientIdRaw.size > 0) { clientIdRaw } else { mqttDefaultClientId(port) }
        sess.keepaliveSec = keepalive
        sess.cleanSession = clean
        sess.state = "connecting"
        this.lock.lock()
        this.current = sess
        sess.app = this.app
        this.lock.unlock()

        let sock = TcpSocket(host, UInt16(port))
        try {
            sock.connect(timeout: Duration.millisecond * MQTT_CONNECT_TIMEOUT_MS)
        } catch (e: Exception) {
            mqttFailSession(sess, "连接 ${host}:${port} 失败：${e.message}")
            throw CommandException("mqtt: 连接 ${host}:${port} 失败（${e.message}）")
        }
        sock.noDelay = true
        sock.writeTimeout = Duration.millisecond * MQTT_CONNECT_TIMEOUT_MS
        // 读超时就是读线程的时基（每 tick 醒来做保活与停止检查）——别改成「不超时」，那会让保活失效
        sock.readTimeout = Duration.millisecond * MQTT_READ_TICK_MS
        sess.lock.lock()
        sess.sock = Some(sock)
        sess.lock.unlock()

        let opts = MqttConnectOptions()
        opts.host = host
        opts.port = port
        opts.clientId = sess.clientId
        opts.username = username
        opts.password = password
        opts.keepaliveSec = keepalive
        opts.cleanSession = clean
        mqttSend(sess, sock, mqttEncodeConnect(opts), "CONNECT",
            "建立连接（clientId=${sess.clientId}，keepalive=${keepalive}s，cleanSession=${clean}）")

        // 等 CONNACK：`mqttReadOne` 失败时自己已经置好错误态与原因，这里把它搬给页面
        var ack: Option<MqttConnack> = None
        match (mqttReadOne(sess, sock)) {
            case None => throw CommandException("mqtt: 握手失败（${this.errorOf(sess, "未收到 CONNACK")}）")
            case Some(rp) => match (rp.packet) {
                case None =>
                    mqttFailSession(sess, "握手期间收到畸形报文（长度字段与实收字节对不上）")
                    throw CommandException("mqtt: 握手失败（对端第一帧畸形）")
                case Some(p) =>
                    if (p.typeCode != MQTT_PKT_CONNACK) {
                        let name = mqttPacketTypeName(p.typeCode)
                        mqttFailSession(sess, "握手期间收到的第一帧不是 CONNACK（是 ${name}）")
                        throw CommandException("mqtt: 握手失败（对端第一帧是 ${name}，不是 CONNACK）")
                    }
                    mqttLogRaw(sess, "rx", rp.raw, "CONNACK", "连接应答（${this.connackNote(p)}）")
                    ack = mqttParseConnack(p)
            }
        }
        match (ack) {
            case None =>
                mqttFailSession(sess, "CONNACK 结构非法（不是 2 字节的变长头）")
                throw CommandException("mqtt: 握手失败（CONNACK 结构非法）")
            case Some(c) =>
                if (c.returnCode != 0) {
                    let text = mqttReturnCodeText(c.returnCode)
                    mqttFailSession(sess, "连接被拒：${text}（返回码 ${c.returnCode}）")
                    throw CommandException("mqtt: ${host}:${port} 拒绝连接——${text}（返回码 ${c.returnCode}）")
                }
                sess.lock.lock()
                sess.state = "connected"
                sess.readerAlive = true
                sess.stopRequested = false
                sess.lock.unlock()
                // 先推状态再起读线程：事件顺序「connected → 之后的报文」与页面看到的时序一致
                mqttEmitState(sess)
                spawn { => mqttReaderThread(sess, sock) }
                let out = JsonObject()
                out.put("state", JsonString("connected"))
                out.put("host", JsonString(host))
                out.put("port", JsonInt(port))
                out.put("clientId", JsonString(sess.clientId))
                out.put("sessionPresent", JsonBool(c.sessionPresent))
                out.put("keepaliveSec", JsonInt(keepalive))
                out.put("cleanSession", JsonBool(clean))
                out.put("note", JsonString("已连上；收到的报文推 mqtt:message 事件，也可用 mqtt:recent 拉取"))
                out
        }
    }

    /**
     * `mqtt:disconnect`：发 DISCONNECT（协议上的正常下线，broker 不会替我们代发遗嘱）后收掉连接。
     * **没有连接时不报错**——页面收尾时无脑调一次是常态，如实回「本来就是断的」即可。
     */
    private func disconnectCmd(args: JsonObject): JsonValue {
        let _ = args
        let sess = this.session()
        var sockOpt: Option<TcpSocket> = None
        var wasConnected = false
        sess.lock.lock()
        sockOpt = sess.sock
        wasConnected = sess.state == "connected" || sess.state == "connecting"
        sess.stopRequested = true
        sess.state = "closed"
        sess.lock.unlock()
        var sent = false
        match (sockOpt) {
            case Some(sock) =>
                if (wasConnected) {
                    try {
                        mqttSend(sess, sock, mqttEncodeDisconnect(), "DISCONNECT",
                            "主动断开（不让 broker 代发遗嘱）")
                        sent = true
                    } catch (e: CommandException) {
                        // 发不出去就照直说，不把「关掉了」讲成「好好告别了」
                        let _ = e
                    }
                }
                try {
                    sock.close()
                } catch (e: Exception) {
                    let _ = e
                }
            case None => ()
        }
        mqttEmitState(sess)
        let out = JsonObject()
        out.put("state", JsonString("closed"))
        out.put("wasConnected", JsonBool(wasConnected))
        out.put("sentDisconnect", JsonBool(sent))
        sess.lock.lock()
        out.put("rx", JsonInt(sess.rxCount))
        out.put("tx", JsonInt(sess.txCount))
        out.put("dropped", JsonInt(sess.dropped))
        sess.lock.unlock()
        out
    }

    /**
     * 有界等 SUBACK（命令 worker 上的轮询）：超时返回 None，**不假装成功**。
     * 取到的授予码列表非空才算数；取走后放一个空列表占位（`mqttCompactLocked` 会把它整块搬走）。
     */
    private func waitSuback(sess: MqttSession, packetId: Int64,
                            timeoutMs: Int64): Option<ArrayList<Int64>> {
        var waited: Int64 = 0
        while (waited <= timeoutMs) {
            var hit: Option<ArrayList<Int64>> = None
            sess.lock.lock()
            hit = sess.subacks.get(packetId)
            match (hit) {
                case Some(granted) =>
                    if (granted.size > 0) {
                        sess.subacks.add(packetId, ArrayList<Int64>())
                    }
                case None => ()
            }
            sess.lock.unlock()
            match (hit) {
                case Some(granted) =>
                    if (granted.size > 0) {
                        return Some(granted)
                    }
                case None => ()
            }
            sleep(Duration.millisecond * MQTT_WAIT_STEP_MS)
            waited += MQTT_WAIT_STEP_MS
        }
        return None
    }

    /**
     * `mqtt:subscribe { filter, qos?, waitMs? }`
     *
     * 有界等 SUBACK：拿到就把授予的 QoS 回给页面；等不到如实回 `pending`（已发出、回执未到），
     * 不假装订阅成功——SUBACK 到达时会作为一条 `mqtt:message` 事件出现，页面照样看得到。
     */
    private func subscribeCmd(args: JsonObject): JsonValue {
        let filter = this.requireString(args, "filter")
        let qos = mqttClampQos(this.optionalInt(args, "qos", 0))
        let waitMs = this.optionalInt(args, "waitMs", MQTT_WAIT_TIMEOUT_MS)
        if (!mqttValidTopicFilter(filter)) {
            throw CommandException("mqtt: 订阅过滤器非法（通配符必须独占一整层：sensor/+/temp、sensor/#）")
        }
        if (waitMs < 0 || waitMs > 60000) {
            throw CommandException("mqtt: waitMs 非法（0..60000）")
        }
        let sess = this.session()
        let sock = this.requireSocket(sess)
        sess.lock.lock()
        let packetId = mqttTakePacketIdLocked(sess)
        sess.lock.unlock()
        mqttSend(sess, sock, mqttEncodeSubscribe(packetId, filter, qos), "SUBSCRIBE",
            "订阅 ${filter}（请求 QoS ${qos}）")
        let out = JsonObject()
        out.put("filter", JsonString(filter))
        out.put("requestedQos", JsonInt(qos))
        out.put("packetId", JsonInt(packetId))
        match (this.waitSuback(sess, packetId, waitMs)) {
            case Some(granted) =>
                var first: Int64 = -2
                var text = ""
                let grantedJson = JsonArray()
                var i: Int64 = 0
                while (i < granted.size) {
                    if (text.size > 0) {
                        text += ", "
                    }
                    if (granted[i] == 0x80) {
                        text += "订阅失败(0x80)"
                    } else {
                        text += "QoS ${granted[i]}"
                    }
                    grantedJson.add(JsonInt(granted[i]))
                    i += 1
                }
                if (granted.size > 0) {
                    first = granted[0]
                }
                sess.lock.lock()
                sess.subs.add(filter, first)
                sess.lock.unlock()
                let rejected = first == 0x80
                out.put("state", JsonString(if (rejected) { "rejected" } else { "subscribed" }))
                out.put("granted", grantedJson)
                out.put("grantedText", JsonString(text))
                out.put("note", JsonString(if (rejected) {
                    "broker 拒绝了这次订阅（授予码 0x80）"
                } else {
                    "订阅已生效"
                }))
            case None =>
                out.put("state", JsonString("pending"))
                out.put("note", JsonString(
                    "SUBSCRIBE 已发出，SUBACK 未在 ${waitMs}ms 内到达；回执到达时会作为 mqtt:message 事件出现"))
        }
        out
    }

    /**
     * `mqtt:unsubscribe { filter }`：发 UNSUBSCRIBE 后把订阅表里这一条标成「已退订」(-1)。
     * UNSUBACK 在协议里只有报文标识符、不带原因，所以这里不等回执——它到了会作为一条事件出现。
     */
    private func unsubscribeCmd(args: JsonObject): JsonValue {
        let filter = this.requireString(args, "filter")
        if (!mqttValidTopicFilter(filter)) {
            throw CommandException("mqtt: 过滤器非法（通配符必须独占一整层）")
        }
        let sess = this.session()
        let sock = this.requireSocket(sess)
        sess.lock.lock()
        let packetId = mqttTakePacketIdLocked(sess)
        sess.lock.unlock()
        mqttSend(sess, sock, mqttEncodeUnsubscribe(packetId, filter), "UNSUBSCRIBE", "退订 ${filter}")
        sess.lock.lock()
        let was = sess.subs.get(filter)
        // -1 语义是「已退订」：state 事件与 status 都会照直带出去，页面想过滤就自己过滤
        sess.subs.add(filter, -1)
        sess.lock.unlock()
        let out = JsonObject()
        out.put("filter", JsonString(filter))
        out.put("packetId", JsonInt(packetId))
        out.put("state", JsonString("unsubscribed"))
        match (was) {
            case Some(q) => out.put("previousQos", JsonInt(q))
            case None => out.put("previousQos", JsonNull())
        }
        out
    }

    /**
     * `mqtt:publish { topic, text? | hex?, qos?, retain? }`
     *
     * 载荷两种给法：`text`（按 UTF-8 编码）或 `hex`（二进制）。**不做隐式优先级**：两个都给就报错；
     * 都不给是合法调用（空载荷——主题上的「事件通知」常见）。
     * QoS > 0 时登记待确认表，回执（PUBACK，或 PUBREC + PUBCOMP）会在日志里逐条可见。
     */
    private func publishCmd(args: JsonObject): JsonValue {
        let topic = this.requireString(args, "topic")
        let qos = mqttClampQos(this.optionalInt(args, "qos", 0))
        let retain = this.optionalBool(args, "retain", false)
        let text = this.optionalString(args, "text")
        let hex = this.optionalString(args, "hex")
        if (!mqttValidPublishTopic(topic)) {
            throw CommandException("mqtt: 发布主题非法（非空、不超过 65535 字节、不含 + 与 #）")
        }
        var payload = Array<UInt8>()
        if (hex.size > 0) {
            if (text.size > 0) {
                throw CommandException("mqtt: 载荷只能给 text 或 hex 之一（含糊比报错更糟）")
            }
            match (hexToBytes(hex)) {
                case Some(b) => payload = b
                case None => throw CommandException("mqtt: hex 载荷非法（须为偶数长度的十六进制串）")
            }
        } else if (text.size > 0) {
            payload = text.toArray()
        }
        let sess = this.session()
        let sock = this.requireSocket(sess)
        var packetId: Int64 = 0
        if (qos > 0) {
            sess.lock.lock()
            packetId = mqttTakePacketIdLocked(sess)
            sess.pending.add(packetId, if (qos == 1) { "puback" } else { "pubrec" })
            sess.lock.unlock()
        }
        let raw = mqttEncodePublish(topic, payload, qos, retain, false, packetId)
        mqttSendBytes(sess, sock, raw)
        // 发布的日志走 PUBLISH 语义（带主题与载荷文本），与收到的报文在页面里同形
        let pub = MqttPublish()
        pub.topic = topic
        pub.payload = payload
        pub.qos = qos
        pub.retain = retain
        pub.packetId = packetId
        pub.hasPacketId = qos > 0
        mqttLogPublish(sess, "tx", raw, pub, if (qos == 0) {
            "发布到 ${topic}（QoS 0，发后即忘）"
        } else {
            "发布到 ${topic}（QoS ${qos}，等回执：报文标识符 ${packetId}）"
        })
        let out = JsonObject()
        out.put("topic", JsonString(topic))
        out.put("qos", JsonInt(qos))
        out.put("retain", JsonBool(retain))
        out.put("bytes", JsonInt(raw.size))
        out.put("payloadBytes", JsonInt(payload.size))
        out.put("packetId", JsonInt(packetId))
        out
    }

    /**
     * `mqtt:status`：一份可对账的连接快照（页面顶栏就是它）。
     * subscriptions 的取值语义写进返回体里，免得页面猜：0..2 = 已授予，-1 = 已退订，-2 = 已发出、回执未到。
     */
    private func statusCmd(args: JsonObject): JsonValue {
        let _ = args
        let sess = this.session()
        let out = JsonObject()
        sess.lock.lock()
        out.put("state", JsonString(sess.state))
        out.put("host", JsonString(sess.host))
        out.put("port", JsonInt(sess.port))
        out.put("clientId", JsonString(sess.clientId))
        out.put("keepaliveSec", JsonInt(sess.keepaliveSec))
        out.put("cleanSession", JsonBool(sess.cleanSession))
        out.put("readerAlive", JsonBool(sess.readerAlive))
        out.put("rx", JsonInt(sess.rxCount))
        out.put("tx", JsonInt(sess.txCount))
        out.put("dropped", JsonInt(sess.dropped))
        out.put("buffered", JsonInt(sess.recent.size))
        out.put("pendingAcks", JsonInt(sess.pending.size))
        out.put("lastError", JsonString(sess.lastError))
        out.put("lastTxAt", JsonString(sess.lastTxAt.toString()))
        out.put("lastRxAt", JsonString(sess.lastRxAt.toString()))
        let subsObj = JsonObject()
        for ((filter, q) in sess.subs) {
            subsObj.put(filter, JsonInt(q))
        }
        sess.lock.unlock()
        out.put("subscriptions", subsObj)
        out.put("note", JsonString(
            "subscriptions 的 qos：0..2 已授予 / -1 已退订 / -2 已发出、回执未到；dropped = 缓冲满被丢弃的报文数"))
        out
    }

    /**
     * `mqtt:recent { limit? }`：把缓冲里的报文**取走**（读后即清，D-015 的第二条通道）。
     *
     * 为什么读后即清：这是一条「拉取」通道而不是无限日志——同一条报文本来就已经走过 `mqtt:message`
     * 事件（页面按报文里的 `seq` 去重即可），不清的话每次轮询都要页面自己算增量。
     */
    private func recentCmd(args: JsonObject): JsonValue {
        let limit = this.optionalInt(args, "limit", MQTT_RECENT_LIMIT)
        let sess = this.session()
        let items = JsonArray()
        var total: Int64 = 0
        var dropped: Int64 = 0
        sess.lock.lock()
        total = sess.recent.size
        dropped = sess.dropped
        let take = mqttClampInt(limit, 0, total)
        var i: Int64 = 0
        while (i < take) {
            items.add(sess.recent[i])
            i += 1
        }
        // 取走前 take 条：剩下的整块搬进新表（与环形缓冲同一套做法，不做逐条删除）
        let keep = ArrayList<JsonValue>()
        var j: Int64 = take
        while (j < sess.recent.size) {
            keep.add(sess.recent[j])
            j += 1
        }
        sess.recent = keep
        sess.lock.unlock()
        let out = JsonObject()
        out.put("messages", items)
        out.put("count", JsonInt(items.size()))
        out.put("bufferedBefore", JsonInt(total))
        out.put("droppedTotal", JsonInt(dropped))
        out.put("note", JsonString("取走即清；同一条报文也会走 mqtt:message 事件，按 seq 去重"))
        out
    }
}

/**
 * 官方插件 mqtt：MQTT 3.1.1 客户端调试工具（形态与实现层的取舍见 `docs/设计决策记录.md` D-014）
 *
 * 命令 `mqtt:connect/disconnect/subscribe/unsubscribe/publish/status/recent`，事件 `mqtt:message` /
 * `mqtt:state`；**只声明「我提供什么」，不自动放行**——应用要在 `capabilities` 目录的 json 里
 * 明文声明命令，或引用命名集 `"permissions": ["mqtt:debug"]`（只观不控用 `mqtt:readonly`）。
 */
public class MqttPlugin <: Plugin {
    private let handler: MqttCommands = MqttCommands()

    public init() {}

    public func name(): String {
        return "mqtt"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        m.add("connect", this.handler)
        m.add("disconnect", this.handler)
        m.add("subscribe", this.handler)
        m.add("unsubscribe", this.handler)
        m.add("publish", this.handler)
        m.add("status", this.handler)
        m.add("recent", this.handler)
        return m
    }

    /**
     * 命名权限集：`debug` = 调试台需要的全部；`readonly` = 只看不发（状态 + 拉取），
     * 想在别人的 broker 上「只观不控」时用它。
     */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let debug = ArrayList<String>()
        for (name in MQTT_PLUGIN_COMMANDS) {
            debug.add(name)
        }
        m.add("debug", debug)
        let readonly = ArrayList<String>()
        readonly.add("status")
        readonly.add("recent")
        m.add("readonly", readonly)
        return m
    }

    /** 事件只声明短名（框架拼成 `mqtt:message` / `mqtt:state`），投递的落点在 mqttRecord / mqttEmitState */
    public func events(): ArrayList<String> {
        let e = ArrayList<String>()
        e.add("message")
        e.add("state")
        return e
    }

    /**
     * 前端 shim：往桥对象上挂一个 mqtt 命名空间（与 dialog / notification 同款）。
     * 由框架经 `addInitScript` 在 document-start 注入，因此页面脚本执行时它已经在。
     */
    public func jsShim(): String {
        return "(function () { var t = window.__CJ_TAURI__ || (window.__CJ_TAURI__ = {});" +
            " t.mqtt = {" +
            " connect: function (o) { return window.__CJ_TAURI__.invoke('mqtt:connect', o || {}); }," +
            " disconnect: function (o) { return window.__CJ_TAURI__.invoke('mqtt:disconnect', o || {}); }," +
            " subscribe: function (o) { return window.__CJ_TAURI__.invoke('mqtt:subscribe', o || {}); }," +
            " unsubscribe: function (o) { return window.__CJ_TAURI__.invoke('mqtt:unsubscribe', o || {}); }," +
            " publish: function (o) { return window.__CJ_TAURI__.invoke('mqtt:publish', o || {}); }," +
            " status: function (o) { return window.__CJ_TAURI__.invoke('mqtt:status', o || {}); }," +
            " recent: function (o) { return window.__CJ_TAURI__.invoke('mqtt:recent', o || {}); }" +
            " }; })();\n"
    }

    public func setup(app: TauriApp): Unit {
        this.handler.attachApp(app)
    }
}
