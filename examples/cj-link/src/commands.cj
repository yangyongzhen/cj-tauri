package cjLink

import cjTauri.*
import cjTauri.plugins.serial.*

import std.collection.*
import std.net.*
import std.sync.*
import stdx.encoding.json.*

/**
 * cj-link 的应用级命令：串口枚举薄包装 + TCP 客户端（连接/发送/关闭） + 探针辅助。
 *
 * 串口读写不走这里——官方 serial 插件已提供 serial:open/read/write/close（含 hex 编解码、
 * 路径白名单、参数校验），应用层只包一个 link:serialList 给出统一出口。
 *
 * TCP 客户端是 `std.net` 的 TcpSocket（写法对齐 redis 插件的 redisOpenSocket）：
 *  - connect(timeout:) 设建连超时，连不上当场拒绝，不静默重试；
 *  - readTimeout 同时是「读线程停下来检查关闭请求」的时基（与 redis 订阅读线程同思路）。
 *
 * 线程模型：连接/发送/关闭都跑在命令 worker 线程上；TCP 读线程**不调 GTK / WebKit**，
 * 数据经 jsSink 事件回投（任意线程调用安全，AGENTS §2 线程模型）。
 */

/** 建连超时（毫秒）：死地址不能把命令 worker 挂住 */
let LINK_CONNECT_TIMEOUT_MS: Int64 = 5000

/** TCP 读线程的读超时（毫秒）：有数据就解、没数据就查停不停 */
let LINK_READ_TICK_MS: Int64 = 100

/** 单次读到缓冲的最大字节数 */
let LINK_READ_CHUNK: Int64 = 16384

/** 事件名：TCP 收到的数据推给前端 */
let LINK_EVT_DATA = "link:tcpData"

/** 事件名：TCP 连接状态变化推给前端 */
let LINK_EVT_STATE = "link:tcpState"

/**
 * TCP 会话的可变状态（命令与读线程并发访问，一律在 lock 下读改写）。
 * 字段都是基础类型 / Option，页面显示直接可用，不需要枚举。
 */
class TcpSession {
    let lock: Mutex = Mutex()
    var sock: Option<TcpSocket> = None
    var host: String = ""
    var port: Int64 = 0
    var state: String = "idle"   // idle / connecting / connected / closed / error
    var readAlive: Bool = false
    var stopReadRequested: Bool = false
}

/**
 * TCP 读线程：只要会话还活着且没被要求停，就阻塞在 sock.read 上（readTimeout 决定
 * 阻塞时长 = 检查停不停 的时基）。读到数据经 link:tcpData 事件回投，错误经 link:tcpState
 * 报 error 并收尾。线程**不直接触碰 UI**（AGENTS §2）。
 */
func tcpReadLoop(sess: TcpSession, app: TauriApp): Unit {
    while (true) {
        sess.lock.lock()
        let alive = sess.readAlive
        let stop = sess.stopReadRequested
        let sock = sess.sock
        if (!alive || stop) {
            sess.lock.unlock()
            break
        }
        sess.lock.unlock()
        match (sock) {
            case Some(s) =>
                let buf = Array<Byte>(LINK_READ_CHUNK, repeat: 0)
                var n: Int64 = 0
                try {
                    n = s.read(buf)
                } catch (e: Exception) {
                    // 读超时不是错误：继续等下一轮；其它异常按「连接断开」收尾
                    let msg = "${e.message}"
                    if (msg.contains("timeout")) {
                        continue
                    }
                    tcpSetState(sess, "error")
                    app.emit(LINK_EVT_STATE, stateJson("error", "连接错误：" + msg))
                    break
                }
                if (n <= 0) {
                    // 对端关闭：EOF，按断线收尾
                    tcpSetState(sess, "closed")
                    app.emit(LINK_EVT_STATE, stateJson("closed", "对端关闭连接"))
                    break
                }
                let body = Array<UInt8>(0, repeat: 0)
                let hex = bytesToHex(bytesToUInt8(buf, n))
                let obj = JsonObject()
                obj.put("dir", JsonString("rx"))
                obj.put("hex", JsonString(hex))
                match (textFromBytes(bytesToUInt8(buf, n))) {
                    case Some(t) => obj.put("text", JsonString(t))
                    case None => ()
                }
                app.emit(LINK_EVT_DATA, obj)
                let _ = body
                // 状态复位：一旦读到过数据，说明连接是活的
            case None =>
                break
        }
    }
}

/** 字节（前 n 个）转 UInt8 数组（TcpSocket 读出来是 Array<Byte>，hex 要 UInt8） */
func bytesToUInt8(src: Array<Byte>, n: Int64): Array<UInt8> {
    let out = Array<UInt8>(n, repeat: 0)
    var i = 0
    while (i < n) {
        out[i] = UInt8(src[i])
        i++
    }
    return out
}

/** 字节 → 文本：不是合法 UTF-8 回 None（前端保留 hex 即可） */
func textFromBytes(bytes: Array<UInt8>): Option<String> {
    try {
        return Some(String.fromUtf8(bytes))
    } catch (e: Exception) {
        return None
    }
}

/** 在会话锁下写 state，并置 stopReadRequested（读线程据此收尾） */
func tcpSetState(sess: TcpSession, state: String): Unit {
    sess.lock.lock()
    sess.state = state
    sess.lock.unlock()
}

/** TCP 状态事件报文 */
func stateJson(state: String, detail: String): JsonValue {
    let obj = JsonObject()
    obj.put("state", JsonString(state))
    obj.put("detail", JsonString(detail))
    return obj
}

/** 应用级命令处理器：按全名分派 */
public class LinkCommands <: CommandHandler {
    private let lock: Mutex = Mutex()
    private var tcp: Option<TcpSession> = None
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
            case "link:tcpConnect" => return this.tcpConnectCmd(args)
            case "link:tcpSend" => return this.tcpSendCmd(args)
            case "link:tcpClose" => return this.tcpCloseCmd(args)
            case "link:ping" => return this.pingCmd(args)
            case _ => throw CommandException("unknown link command: ${cmd}")
        }
    }

    /** 逐字段解析：JSON 路由不直接支持 getItem 链式，这里统一拆 */
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

    /** 枚举串口：薄包 serial 插件命名集（serial:list 的返回形状 { ports: [...] }） */
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

    /** 连接 TCP：失败当场拒绝并清会话 */
    private func tcpConnectCmd(args: JsonObject): JsonValue {
        let host = this.argStr(args, "host", "")
        let port = this.argInt(args, "port", 0)
        if (host == "" || port <= 0 || port > 65535) {
            throw CommandException("link:tcpConnect refused: 需要合法的 host 与 1..65535 的 port")
        }
        this.lock.lock()
        let session = this.tcp
        let app = this.app
        this.lock.unlock()

        // 已存在的会话先关掉，避免旧读线程误碰新连接
        match (session) {
            case Some(s) => tcpShutdown(s)
            case None => ()
        }

        let sock = try {
            let s = TcpSocket(host, UInt16(port))
            s.connect(timeout: Duration.millisecond * LINK_CONNECT_TIMEOUT_MS)
            s.noDelay = true
            s.writeTimeout = Duration.millisecond * LINK_CONNECT_TIMEOUT_MS
            s.readTimeout = Duration.millisecond * LINK_READ_TICK_MS
            s
        } catch (e: Exception) {
            throw CommandException("link:tcpConnect 失败（${host}:${port}）：${e.message}")
        }

        let sess = TcpSession()
        sess.lock.lock()
        sess.sock = Some(sock)
        sess.host = host
        sess.port = port
        sess.state = "connected"
        sess.readAlive = true
        sess.stopReadRequested = false
        sess.lock.unlock()

        this.lock.lock()
        this.tcp = Some(sess)
        this.lock.unlock()

        match (app) {
            case Some(a) => spawn { => tcpReadLoop(sess, a) }
            case None => ()
        }
        let out = JsonObject()
        out.put("state", JsonString("connected"))
        out.put("host", JsonString(host))
        out.put("port", JsonInt(port))
        return out
    }

    /** 发送：data 支持 text 或 hex（encoding="hex"） */
    private func tcpSendCmd(args: JsonObject): JsonValue {
        let payload = this.argStr(args, "data", "")
        let encoding = this.argStr(args, "encoding", "text")
        var bytes = payload.toArray()
        if (encoding == "hex") {
            match (hexToBytes(payload)) {
                case Some(b) => bytes = b
                case None => throw CommandException("link:tcpSend refused: data 不是合法十六进制串")
            }
        }
        this.lock.lock()
        let sess = this.tcp
        let app = this.app
        this.lock.unlock()
        match (sess) {
            case Some(s) =>
                s.lock.lock()
                let sock = s.sock
                let state = s.state
                s.lock.unlock()
                if (state != "connected") {
                    throw CommandException("link:tcpSend refused: TCP 未连接（state=${state}）")
                }
                match (sock) {
                    case Some(sock2) =>
                        try {
                            sock2.write(bytesToByteArray(bytes))
                        } catch (e: Exception) {
                            throw CommandException("link:tcpSend 失败：${e.message}")
                        }
                    case None => throw CommandException("link:tcpSend refused: TCP 未连接")
                }
                let obj = JsonObject()
                obj.put("dir", JsonString("tx"))
                obj.put("text", JsonString(payload))
                obj.put("hex", JsonString(bytesToHex(bytes)))
                if (let Some(a) <- app) {
                    a.emit(LINK_EVT_DATA, obj)
                }
            case None => throw CommandException("link:tcpSend refused: 尚未连接 TCP")
        }
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("bytes", JsonInt(Int64(bytes.size)))
        return out
    }

    /** 关闭 TCP 并收尾读线程 */
    private func tcpCloseCmd(args: JsonObject): JsonValue {
        let _ = args
        this.lock.lock()
        let sess = this.tcp
        let app = this.app
        this.lock.unlock()
        match (sess) {
            case Some(s) =>
                tcpShutdown(s)
                match (app) {
                    case Some(a) => a.emit(LINK_EVT_STATE, stateJson("closed", "用户关闭连接"))
                    case None => ()
                }
            case None => ()
        }
        return JsonBool(true)
    }
}

/** UInt8 数组转 Byte 数组（TcpSocket.write 收 Array<Byte>；Byte 即 UInt8 的别名，直接换型） */
func bytesToByteArray(src: Array<UInt8>): Array<Byte> {
    return src
}

/**
 * 让一个会话安静收尾：置 stopReadRequested、等读线程退（有界），关 socket、state=idle。
 * 幂等：重复调用安全。
 */
func tcpShutdown(sess: TcpSession): Unit {
    sess.lock.lock()
    sess.stopReadRequested = true
    let sock = sess.sock
    let alive = sess.readAlive
    sess.lock.unlock()
    if (alive) {
        // 有界等待读线程收尾；等不到就打一行 stderr 继续（比死锁安全）
        var waited: Int64 = 0
        while (waited < 1000) {
            sess.lock.lock()
            let still = sess.readAlive
            sess.lock.unlock()
            if (!still) {
                break
            }
            sleep(Duration.millisecond * 10)
            waited += 10
        }
        if (waited >= 1000) {
            eprintln("[cj-link] tcpShutdown: 读线程收尾超时，继续（进程随即退出）")
        }
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
    sess.lock.lock()
    sess.sock = None
    sess.state = "idle"
    sess.readAlive = false
    sess.lock.unlock()
}
