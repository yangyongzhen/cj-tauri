package cjLink

import cjTauri.*
import cjTauri.plugins.serial.*

import std.collection.*
import std.net.*
import std.sync.*
import stdx.encoding.json.*

/**
 * cj-link 的应用级命令：串口枚举薄包装 + 网络会话（TCP 客户端 / TCP 服务器 / UDP 客户端） + 探针辅助。
 *
 * 串口读写不走这里——官方 serial 插件已提供 serial:open/read/write/close（含 hex 编解码、
 * 路径白名单、参数校验），应用层只包一个 link:serialList 给出统一出口。
 *
 * 网络三种模式共用一个 NetSession 会话模型（同一时刻只活一种，互斥切换）：
 *  - tcp-client：TcpSocket 主动连（connect 超时 5s），一条读线程；
 *  - tcp-server：TcpServerSocket 监听，accept 线程收客户端（上限 LINK_MAX_CLIENTS），
 *    每个客户端一条读线程；send 缺省**广播**给全部客户端，带 clientId 只发那一个；
 *  - udp-client：UdpSocket connect 到对端（send/receive 语义），一条读线程。
 *
 * 读线程**不调 GTK / WebKit**：数据经 jsSink 事件回投（任意线程调用安全，AGENTS §2 线程模型）。
 * 事件：link:tcpData（收到的数据，带 mode 与 channel 字段区分来源）、link:tcpState（连接状态变化）。
 */

/** 建连超时（毫秒）：死地址不能把命令 worker 挂住 */
let LINK_CONNECT_TIMEOUT_MS: Int64 = 5000

/** 读线程的读超时（毫秒）：有数据就解、没数据就查停不停（accept 线程同一时基） */
let LINK_READ_TICK_MS: Int64 = 100

/** 单次读到缓冲的最大字节数 */
let LINK_READ_CHUNK: Int64 = 16384

/** TCP 服务器最多同时接的客户端数（调试工具不是服务端程序，够用即可） */
let LINK_MAX_CLIENTS: Int64 = 16

/** 收发日志里单帧的最大字节数（超过截断，照实标 truncated） */
let LINK_FRAME_LIMIT: Int64 = 4096

/** 事件名：网络收到的数据推给前端 */
let LINK_EVT_DATA = "link:tcpData"

/** 事件名：网络连接状态变化推给前端 */
let LINK_EVT_STATE = "link:tcpState"

/** 会话模式：无 / TCP 客户端 / TCP 服务器 / UDP 客户端 */
let LINK_MODE_NONE = "none"
let LINK_MODE_TCP_CLIENT = "tcp-client"
let LINK_MODE_TCP_SERVER = "tcp-server"
let LINK_MODE_UDP = "udp"

/**
 * TCP 服务器已接入的一个客户端：自增 id 当「通道号」，前端按它定向发送。
 */
class NetClient {
    let id: Int64
    let sock: TcpSocket
    var readAlive: Bool = true

    init(id: Int64, sock: TcpSocket) {
        this.id = id
        this.sock = sock
    }
}

/**
 * 网络会话的可变状态（命令线程与读/accept 线程并发访问，一律在 lock 下读改写）。
 * 三种模式共用：按 mode 决定哪些字段有效（tcp-client 用 sock；tcp-server 用 server + clients；
 * udp 用 udp）。
 */
class NetSession {
    let lock: Mutex = Mutex()

    /** none / tcp-client / tcp-server / udp：页面直接显示，所以用字符串 */
    var mode: String = LINK_MODE_NONE

    /** tcp-client 的连接 */
    var sock: Option<TcpSocket> = None

    /** tcp-server 的监听 socket */
    var server: Option<TcpServerSocket> = None

    /** udp 客户端的 socket */
    var udp: Option<UdpSocket> = None

    /** tcp-server 已接入的客户端（lock 下增删；读线程只读自己的那份引用） */
    var clients: ArrayList<NetClient> = ArrayList<NetClient>()

    /** 下一个客户端通道号（从 1 起，0 保留给「广播/无通道」） */
    var nextClientId: Int64 = 1

    var host: String = ""
    var port: Int64 = 0

    /** 线程旗标：读线程 / accept 线程据此退出 */
    var stopReadRequested: Bool = false
    var mainAlive: Bool = false
    var acceptAlive: Bool = false
}

/** 在会话锁下取「活跃客户端快照」（send 广播 / 收尾遍历用，避免持锁做 IO） */
func netClientSnapshot(sess: NetSession): ArrayList<NetClient> {
    let out = ArrayList<NetClient>()
    sess.lock.lock()
    for (c in sess.clients) {
        out.add(c)
    }
    sess.lock.unlock()
    return out
}

/** 数据事件报文：mode 区分链路，channel 区分 TCP 服务器的客户端通道（0 = 服务器自身/广播） */
func netDataJson(mode: String, channel: Int64, dir: String, bytes: Array<UInt8>): JsonObject {
    let obj = JsonObject()
    obj.put("mode", JsonString(mode))
    obj.put("channel", JsonInt(channel))
    obj.put("dir", JsonString(dir))
    obj.put("hex", JsonString(bytesToHex(bytes)))
    match (textFromBytes(bytes)) {
        case Some(t) => obj.put("text", JsonString(t))
        case None => ()
    }
    return obj
}

/** 状态事件报文 */
func netStateJson(mode: String, state: String, detail: String): JsonObject {
    let obj = JsonObject()
    obj.put("mode", JsonString(mode))
    obj.put("state", JsonString(state))
    obj.put("detail", JsonString(detail))
    return obj
}

/** 字节 → 文本：不是合法 UTF-8 回 None（前端保留 hex 即可） */
func textFromBytes(bytes: Array<UInt8>): Option<String> {
    try {
        return Some(String.fromUtf8(bytes))
    } catch (e: Exception) {
        return None
    }
}

/**
 * 单条 TCP 连接的读循环（tcp-client 的主连接与 tcp-server 的每个客户端共用）：
 * 阻塞在 read 上（readTimeout = 查停不停的时基），读到数据按方向回投事件。
 */
func netTcpReadLoop(sess: NetSession, app: TauriApp, sock: TcpSocket, channel: Int64,
                    isAlive: () -> Bool): Unit {
    while (true) {
        if (!isAlive()) {
            break
        }
        let buf = Array<Byte>(LINK_READ_CHUNK, repeat: 0)
        var n: Int64 = 0
        try {
            n = sock.read(buf)
        } catch (e: Exception) {
            // 读超时不是错误：继续等下一轮；其它异常按「连接断开」收尾
            let msg = "${e.message}"
            if (msg.contains("timeout") || msg.contains("timed out")) {
                continue
            }
            app.emit(LINK_EVT_STATE, netStateJson(sess.mode, "error", "通道 ${channel} 连接错误：" + msg))
            break
        }
        if (n <= 0) {
            app.emit(LINK_EVT_STATE, netStateJson(sess.mode, "closed", "通道 ${channel} 对端关闭连接"))
            break
        }
        let bytes = Array<UInt8>(n, repeat: 0)
        var i: Int64 = 0
        while (i < n) {
            bytes[i] = UInt8(buf[i])
            i++
        }
        app.emit(LINK_EVT_DATA, netDataJson(sess.mode, channel, "rx", bytes))
    }
}

/* ===== 会话级循环（tcp-server 的 accept 线程 / udp 的读线程）===== */

/**
 * TCP 服务器的 accept 循环：阻塞在 accept 上（timeout 即查停不停的时基），
 * 每来一个客户端就登记 + 起一条读线程；客户端上限到了就拒（收下再立刻关，回一行提示事件）。
 */
func netAcceptLoop(sess: NetSession, app: TauriApp): Unit {
    while (true) {
        sess.lock.lock()
        let stop = sess.stopReadRequested
        let server = sess.server
        sess.lock.unlock()
        if (stop) {
            break
        }
        match (server) {
            case Some(s) =>
                var client0: TcpSocket
                try {
                    client0 = s.accept(timeout: Duration.millisecond * LINK_READ_TICK_MS)
                } catch (e: Exception) {
                    let msg = "${e.message}"
                    if (msg.contains("timeout") || msg.contains("timed out")) {
                        continue
                    }
                    sess.lock.lock()
                    let stopping = sess.stopReadRequested
                    sess.lock.unlock()
                    // 关监听引发的异常是正常收尾；其余如实报
                    if (!stopping) {
                        app.emit(LINK_EVT_STATE, netStateJson(sess.mode, "error", "accept 失败：" + msg))
                    }
                    break
                }
                sess.lock.lock()
                let full = sess.clients.size >= LINK_MAX_CLIENTS
                if (!full) {
                    let id = sess.nextClientId
                    sess.nextClientId += 1
                    let nc = NetClient(id, client0)
                    sess.clients.add(nc)
                    sess.lock.unlock()
                    app.emit(LINK_EVT_STATE, netStateJson(sess.mode, "client", "客户端 #${id} 已接入"))
                    // lambda 不能捕获可变局部变量（AGENTS §4）：accept 出来的 client0 先落成 let
                    let client = client0
                    let alive = { =>
                        var r = false
                        sess.lock.lock()
                        r = !sess.stopReadRequested && nc.readAlive
                        sess.lock.unlock()
                        r
                    }
                    spawn { => netTcpReadLoop(sess, app, client, id, alive) }
                } else {
                    sess.lock.unlock()
                    try {
                        client0.close()
                    } catch (e: Exception) {
                        let _ = e
                    }
                    app.emit(LINK_EVT_STATE, netStateJson(sess.mode, "error", "客户端数已达上限（${LINK_MAX_CLIENTS}），拒绝新接入"))
                }
            case None => break
        }
    }
}

/** UDP 读循环：receiveFrom 阻塞（receiveTimeout = 查停不停的时基），来源地址随事件带回 */
func netUdpReadLoop(sess: NetSession, app: TauriApp): Unit {
    while (true) {
        sess.lock.lock()
        let stop = sess.stopReadRequested
        let udp = sess.udp
        sess.lock.unlock()
        if (stop) {
            break
        }
        match (udp) {
            case Some(u) =>
                let buf = Array<Byte>(LINK_READ_CHUNK, repeat: 0)
                var from: SocketAddress
                var n: Int64 = 0
                try {
                    let r = u.receiveFrom(buf)
                    from = r[0]
                    n = r[1]
                } catch (e: Exception) {
                    let msg = "${e.message}"
                    if (msg.contains("timeout") || msg.contains("timed out")) {
                        continue
                    }
                    sess.lock.lock()
                    let stopping = sess.stopReadRequested
                    sess.lock.unlock()
                    if (!stopping) {
                        app.emit(LINK_EVT_STATE, netStateJson(sess.mode, "error", "UDP 接收失败：" + msg))
                    }
                    break
                }
                if (n <= 0) {
                    continue
                }
                let bytes = Array<UInt8>(n, repeat: 0)
                var i: Int64 = 0
                while (i < n) {
                    bytes[i] = UInt8(buf[i])
                    i++
                }
                let obj = netDataJson(sess.mode, 0, "rx", bytes)
                obj.put("from", JsonString("${from}"))
                app.emit(LINK_EVT_DATA, obj)
            case None => break
        }
    }
}

/**
 * 让会话安静收尾：置停旗标、关监听 / 所有连接、等线程退（有界）、清状态。幂等。
 * 线程收尾靠「读超时后查旗标」+「关 socket 让阻塞读抛错」双保险，等不到就打 stderr 继续。
 */
func netShutdown(sess: NetSession): Unit {
    sess.lock.lock()
    sess.stopReadRequested = true
    let hadMain = sess.mainAlive || sess.acceptAlive
    let server = sess.server
    let sock = sess.sock
    let udp = sess.udp
    let mode = sess.mode
    sess.lock.unlock()

    // 先关监听 / 连接：阻塞中的读会立刻抛错走人
    match (server) {
        case Some(s) =>
            try {
                s.close()
            } catch (e: Exception) {
                let _ = e
            }
        case None => ()
    }
    match (sock) {
        case Some(s) =>
            try {
                s.close()
            } catch (e: Exception) {
                let _ = e
            }
        case None => ()
    }
    match (udp) {
        case Some(u) =>
            try {
                u.close()
            } catch (e: Exception) {
                let _ = e
            }
        case None => ()
    }
    // TCP 服务器的每个客户端也要关
    for (c in netClientSnapshot(sess)) {
        try {
            c.sock.close()
        } catch (e: Exception) {
            let _ = e
        }
    }

    if (hadMain) {
        var waited: Int64 = 0
        while (waited < 1000) {
            sess.lock.lock()
            let busy = sess.mainAlive || sess.acceptAlive
            sess.lock.unlock()
            if (!busy) {
                break
            }
            sleep(Duration.millisecond * 10)
            waited += 10
        }
        if (waited >= 1000) {
            eprintln("[cj-link] netShutdown(${mode}): 线程收尾超时，继续")
        }
    }

    sess.lock.lock()
    sess.server = None
    sess.sock = None
    sess.udp = None
    sess.clients = ArrayList<NetClient>()
    sess.mode = LINK_MODE_NONE
    sess.mainAlive = false
    sess.acceptAlive = false
    sess.lock.unlock()
}

/** 应用级命令处理器：按全名分派（link:serialList / link:net* / link:ping） */
public class LinkCommands <: CommandHandler {
    private let lock: Mutex = Mutex()
    private var sess: NetSession = NetSession()
    private var app: Option<TauriApp> = None

    public init() {}

    public func attachApp(app: TauriApp): Unit {
        this.lock.lock()
        this.app = Some(app)
        this.lock.unlock()
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = ipc
        match (cmd) {
            case "link:serialList" => return this.serialListCmd()
            case "link:netConnect" => return this.netConnectCmd(args)
            case "link:netSend" => return this.netSendCmd(args)
            case "link:netClose" => return this.netCloseCmd(args)
            case "link:netStatus" => return this.netStatusCmd()
            case "link:ping" => return this.pingCmd(args)
            case _ => throw CommandException("unknown link command: ${cmd}")
        }
    }

    /* ---- 参数解析辅助 ---- */

    private func argStr(args: JsonObject, key: String, fallback: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return fallback
            }
            case None => return fallback
        }
    }

    private func argInt(args: JsonObject, key: String, fallback: Int64): Int64 {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case _ => return fallback
            }
            case None => return fallback
        }
    }

    /* ---- 命令实现 ---- */

    /** 枚举串口：薄包 serial 插件的 serialPortList（与 serial:list 同一份数据源） */
    private func serialListCmd(): JsonValue {
        let list = serialPortList()
        let arr = ArrayList<JsonValue>()
        for (p in list) {
            arr.add(JsonString(p))
        }
        let out = JsonObject()
        out.put("ports", JsonArray(arr))
        return out
    }

    private func pingCmd(args: JsonObject): JsonValue {
        let echo = this.argStr(args, "echo", "pong")
        let out = JsonObject()
        out.put("echo", JsonString(echo))
        out.put("version", JsonString(CJ_TAURI_VERSION))
        return out
    }

    /**
     * `link:netConnect { mode, host?, port }`：按模式建会话。已有会话先收尾（互斥切换）。
     * tcp-client 连 host:port；tcp-server 只用 port（本机监听）；udp connect 到 host:port
     * （此后 send/receive；不带对端地址的纯 bind 场景二期）。
     */
    private func netConnectCmd(args: JsonObject): JsonValue {
        let mode = this.argStr(args, "mode", LINK_MODE_TCP_CLIENT)
        let host = this.argStr(args, "host", "127.0.0.1")
        let port = this.argInt(args, "port", 0)
        if (port <= 0 || port > 65535) {
            throw CommandException("link:netConnect refused: port 需要 1..65535（拿到 ${port}）")
        }
        if (mode != LINK_MODE_TCP_CLIENT && mode != LINK_MODE_TCP_SERVER && mode != LINK_MODE_UDP) {
            throw CommandException("link:netConnect refused: mode 只认 tcp-client / tcp-server / udp（拿到 ${mode}）")
        }
        this.lock.lock()
        let app = this.app
        let sess = this.sess
        this.lock.unlock()

        // 已存在的会话先关掉（互斥：同一时刻只活一种模式）
        netShutdown(sess)

        match (app) {
            case Some(a) =>
                if (mode == LINK_MODE_TCP_CLIENT) {
                    this.netConnectClient(sess, a, host, port)
                    return this.netStatusBrief(sess)
                } else if (mode == LINK_MODE_TCP_SERVER) {
                    this.netListenServer(sess, a, port)
                    return this.netStatusBrief(sess)
                } else {
                    this.netConnectUdp(sess, a, host, port)
                    return this.netStatusBrief(sess)
                }
            case None => throw CommandException("link:netConnect failed: 应用未装配完成")
        }
    }

    /** 连接成功后的简报（mode/host/port/channels） */
    private func netStatusBrief(sess: NetSession): JsonValue {
        sess.lock.lock()
        let mode = sess.mode
        let host = sess.host
        let port = sess.port
        sess.lock.unlock()
        let out = JsonObject()
        out.put("mode", JsonString(mode))
        out.put("host", JsonString(host))
        out.put("port", JsonInt(port))
        let stateText = if (mode == LINK_MODE_TCP_SERVER) { "listening" } else { "connected" }
        out.put("state", JsonString(stateText))
        return out
    }

    /** TCP 客户端：连接后起一条读线程（与旧版 tcpConnect 同形） */
    private func netConnectClient(sess: NetSession, app: TauriApp, host: String, port: Int64): Unit {
        let sock = try {
            let s = TcpSocket(host, UInt16(port))
            s.connect(timeout: Duration.millisecond * LINK_CONNECT_TIMEOUT_MS)
            s.noDelay = true
            s.writeTimeout = Duration.millisecond * LINK_CONNECT_TIMEOUT_MS
            s.readTimeout = Duration.millisecond * LINK_READ_TICK_MS
            s
        } catch (e: Exception) {
            throw CommandException("link:netConnect 失败（tcp-client ${host}:${port}）：${e.message}")
        }
        sess.lock.lock()
        sess.mode = LINK_MODE_TCP_CLIENT
        sess.sock = Some(sock)
        sess.host = host
        sess.port = port
        sess.stopReadRequested = false
        sess.mainAlive = true
        sess.lock.unlock()
        let alive = { =>
            var r = false
            sess.lock.lock()
            r = !sess.stopReadRequested && sess.mainAlive
            sess.lock.unlock()
            r
        }
        spawn { => netTcpReadLoop(sess, app, sock, 0, alive) }
        let out = JsonObject()
        out.put("mode", JsonString(LINK_MODE_TCP_CLIENT))
        out.put("host", JsonString(host))
        out.put("port", JsonInt(port))
        out.put("state", JsonString("connected"))
        app.emit(LINK_EVT_STATE, netStateJson(LINK_MODE_TCP_CLIENT, "connected", "${host}:${port}"))
        eprintln("[cj-link] tcp-client connected: ${host}:${port}")
    }

    /** TCP 服务器：本机监听 port，起 accept 线程 */
    private func netListenServer(sess: NetSession, app: TauriApp, port: Int64): Unit {
        let server = try {
            let s = TcpServerSocket(bindAt: UInt16(port))
            s.bind()
            s
        } catch (e: Exception) {
            throw CommandException("link:netConnect 失败（tcp-server 监听 ${port}）：${e.message}")
        }
        sess.lock.lock()
        sess.mode = LINK_MODE_TCP_SERVER
        sess.server = Some(server)
        sess.port = port
        sess.stopReadRequested = false
        sess.acceptAlive = true
        sess.lock.unlock()
        spawn { => netAcceptLoop(sess, app) }
        let out = JsonObject()
        out.put("mode", JsonString(LINK_MODE_TCP_SERVER))
        out.put("port", JsonInt(port))
        out.put("state", JsonString("listening"))
        app.emit(LINK_EVT_STATE, netStateJson(LINK_MODE_TCP_SERVER, "listening", "本机 ${port}"))
        eprintln("[cj-link] tcp-server listening on port ${port}")
    }

    /** UDP 客户端：connect 到 host:port（send/receive 语义），起一条读线程 */
    private func netConnectUdp(sess: NetSession, app: TauriApp, host: String, port: Int64): Unit {
        let udp = try {
            let u = UdpSocket(bindAt: UInt16(0))
            u.bind()
            u.connect(IPSocketAddress(host, UInt16(port)))
            u.receiveTimeout = Duration.millisecond * LINK_READ_TICK_MS
            u.sendTimeout = Duration.millisecond * LINK_CONNECT_TIMEOUT_MS
            u
        } catch (e: Exception) {
            throw CommandException("link:netConnect 失败（udp ${host}:${port}）：${e.message}")
        }
        sess.lock.lock()
        sess.mode = LINK_MODE_UDP
        sess.udp = Some(udp)
        sess.host = host
        sess.port = port
        sess.stopReadRequested = false
        sess.mainAlive = true
        sess.lock.unlock()
        spawn { => netUdpReadLoop(sess, app) }
        let out = JsonObject()
        out.put("mode", JsonString(LINK_MODE_UDP))
        out.put("host", JsonString(host))
        out.put("port", JsonInt(port))
        out.put("state", JsonString("connected"))
        app.emit(LINK_EVT_STATE, netStateJson(LINK_MODE_UDP, "connected", "${host}:${port}"))
        eprintln("[cj-link] udp connected: ${host}:${port}")
    }

    /**
     * `link:netSend { data, encoding?, channel? }`：按当前模式发。
     * tcp-client/udp 直发；tcp-server 带 channel>0 定向发那个客户端，缺省广播给全部。
     */
    private func netSendCmd(args: JsonObject): JsonValue {
        let payload = this.argStr(args, "data", "")
        let encoding = this.argStr(args, "encoding", "text")
        let channel = this.argInt(args, "channel", 0)
        var bytes = payload.toArray()
        if (encoding == "hex") {
            match (hexToBytes(payload)) {
                case Some(b) => bytes = b
                case None => throw CommandException("link:netSend refused: data 不是合法十六进制串")
            }
        }
        if (bytes.size == 0) {
            throw CommandException("link:netSend refused: 负载为空")
        }
        if (bytes.size > LINK_FRAME_LIMIT) {
            throw CommandException("link:netSend refused: 单次最多 ${LINK_FRAME_LIMIT} 字节（拿到 ${bytes.size}）")
        }
        this.lock.lock()
        let sess = this.sess
        let app = this.app
        let mode = sess.mode
        this.lock.unlock()

        let sent = try {
            if (mode == LINK_MODE_TCP_CLIENT) {
                this.sendTcpClient(sess, bytes)
            } else if (mode == LINK_MODE_TCP_SERVER) {
                this.sendTcpServer(sess, bytes, channel)
            } else if (mode == LINK_MODE_UDP) {
                this.sendUdp(sess, bytes)
            } else {
                throw CommandException("link:netSend refused: 网络未连接（mode=${mode}）")
            }
        } catch (e: CommandException) {
            throw e
        } catch (e: Exception) {
            throw CommandException("link:netSend 失败：${e.message}")
        }

        match (app) {
            case Some(a) => a.emit(LINK_EVT_DATA, netDataJson(mode, channel, "tx", bytes))
            case None => ()
        }
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("bytes", JsonInt(Int64(bytes.size)))
        out.put("targets", JsonInt(sent))
        return out
    }

    /** tcp-client 发送：返回 1（对端数） */
    private func sendTcpClient(sess: NetSession, bytes: Array<UInt8>): Int64 {
        sess.lock.lock()
        let sock = sess.sock
        let mode = sess.mode
        sess.lock.unlock()
        if (mode != LINK_MODE_TCP_CLIENT) {
            throw CommandException("link:netSend refused: TCP 未连接（mode=${mode}）")
        }
        match (sock) {
            case Some(s) =>
                s.write(bytesToByteArray(bytes))
                return 1
            case None => throw CommandException("link:netSend refused: TCP 未连接")
        }
    }

    /** tcp-server 发送：channel>0 定向，缺省广播；返回实际发出的对端数 */
    private func sendTcpServer(sess: NetSession, bytes: Array<UInt8>, channel: Int64): Int64 {
        var sent: Int64 = 0
        var lastErr = ""
        for (c in netClientSnapshot(sess)) {
            if (channel > 0 && c.id != channel) {
                continue
            }
            try {
                c.sock.write(bytesToByteArray(bytes))
                sent += 1
            } catch (e: Exception) {
                lastErr = "${e.message}"
            }
        }
        if (channel > 0 && sent == 0) {
            var detail = ""
            if (lastErr != "") {
                detail = "（${lastErr}）"
            }
            throw CommandException("link:netSend failed: 通道 ${channel} 发送失败${detail}")
        }
        return sent
    }

    /** udp 发送：返回 1 */
    private func sendUdp(sess: NetSession, bytes: Array<UInt8>): Int64 {
        sess.lock.lock()
        let udp = sess.udp
        let mode = sess.mode
        sess.lock.unlock()
        if (mode != LINK_MODE_UDP) {
            throw CommandException("link:netSend refused: UDP 未连接（mode=${mode}）")
        }
        match (udp) {
            case Some(u) =>
                u.send(bytesToByteArray(bytes))
                return 1
            case None => throw CommandException("link:netSend refused: UDP 未连接")
        }
    }

    /** `link:netClose`：收尾会话并回状态事件 */
    private func netCloseCmd(args: JsonObject): JsonValue {
        let _ = args
        this.lock.lock()
        let sess = this.sess
        let app = this.app
        let mode = sess.mode
        this.lock.unlock()
        if (mode == LINK_MODE_NONE) {
            return JsonBool(true)
        }
        netShutdown(sess)
        match (app) {
            case Some(a) => a.emit(LINK_EVT_STATE, netStateJson(mode, "closed", "用户关闭"))
            case None => ()
        }
        return JsonBool(true)
    }

    /** `link:netStatus`：前端恢复现场 / 探针用（模式、通道列表） */
    private func netStatusCmd(): JsonValue {
        this.lock.lock()
        let sess = this.sess
        let mode = sess.mode
        let host = sess.host
        let port = sess.port
        var channels = ArrayList<JsonValue>()
        for (c in sess.clients) {
            channels.add(JsonInt(c.id))
        }
        sess.lock.unlock()
        let out = JsonObject()
        out.put("mode", JsonString(mode))
        out.put("host", JsonString(host))
        out.put("port", JsonInt(port))
        out.put("channels", JsonArray(channels))
        return out
    }
}

/** UInt8 数组转 Byte 数组（TcpSocket/UdpSocket 收发用 Array<Byte>；Byte 即 UInt8 别名） */
func bytesToByteArray(src: Array<UInt8>): Array<Byte> {
    return src
}
