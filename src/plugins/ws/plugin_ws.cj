package cjTauri.plugins.ws

import cjTauri.*

import std.collection.*
import std.sync.*
import stdx.encoding.json.*
import stdx.encoding.url.*
import stdx.net.http.*
import stdx.net.tls.*
// 缺它 TLS 握手时拿不到默认实现：连 ws:// 也会报
// "Global crypto kit is not set. If you want to use the default implementation,
//  make sure that package `stdx.crypto.kit` is imported."（2026-10-20 cjh 接线实测）
import stdx.crypto.kit.*

/** 单帧（含分帧重组累计）上限：8 MiB——一条超长帧直接断连，防内存被撑爆 */
public let CJ_WS_MAX_FRAME: Int64 = 8 * 1024 * 1024

/** 连接状态字面量（ws:state 事件的 state 字段） */
public let CJ_WS_STATE_CONNECTED: String = "connected"
public let CJ_WS_STATE_CLOSED: String = "closed"

/**
 * 官方插件 ws：WebSocket 客户端（stdx.net.http 自带 RFC6455 实现——升级握手与帧
 * 编解码都是库的事，本插件只做治理与并发，与 http 插件的取舍同一结论：用成熟库）
 *
 * 命令：ws:connect（{url}）/ ws:send（{text}）/ ws:close（）
 * 事件：ws:frame（对端帧——cjh 这类 JSON 帧原样透传，前端按 type 分发；解不动的包
 * 一层 `{"type":"raw"}`）/ ws:state（connected / closed）
 * 权限：**不自动放行**——"permissions": ["ws:default"] 或在 commands 里明文写。
 *
 * 安全语义与 http 插件同构：
 * - 主机白名单在清单 scopes.ws（判定复用共享层 scopeAllows/globMatch，host 提取用核心
 *   urlHostOf——http/https/ws/wss 同一套解析）；**没写 scopes.ws = 一律拒绝**；
 * - 只认 host 不认端口（「我信这个主机」）；连接目标必须是 ws:// 或 wss://。
 *
 * 并发模型（mqtt 插件同款）：读线程独占 read()（stdx WebSocket 不支持多线程读）；
 * 写全部在 sess.lock 内串行（不支持多线程写）；读 + 写并发是全双工本身的语义
 * （cjh 服务端同款用法：读循环线程 + 持锁写）。
 */
public class WsPlugin <: Plugin {
    public init() {}

    // 单活动连接：cjh 客户端同一时刻只连一个后端；重连须先 close（确定性优先，
    // 不在命令里做隐式替换——旧读线程还没退出时隐式重连会制造两套 gen 竞态）
    private let sess: WsSession = WsSession()
    // 引用一下 DefaultCryptoKit：stdx.crypto.kit 的**包初始化**负责注册全局加密套件，
    // 但零警告门禁要求 import 必须有符号使用——这个字段就是干这个的（不参与逻辑）
    private let kitMarker = DefaultCryptoKit()

    public func name(): String {
        return "ws"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        // 键写**短名**：前缀由框架补（写全名会得到 ws:ws:connect，且所有命令都成未注册）
        m.add("connect", WsCommands(this.sess))
        m.add("send", WsCommands(this.sess))
        m.add("close", WsCommands(this.sess))
        return m
    }

    /** 命名权限集（v1.1）：default = 连接 + 发送 + 关闭 */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let all = ArrayList<String>()
        all.add("connect")
        all.add("send")
        all.add("close")
        m.add("default", all)
        return m
    }

    /** 推事件：对端帧经 ws:frame、连接状态经 ws:state（应用要在清单 events 里放行短名） */
    public func events(): ArrayList<String> {
        let ev = ArrayList<String>()
        ev.add("frame")
        ev.add("state")
        return ev
    }

    /** 吃 scope：主机白名单的判定在清单 scopes.ws（没写 = 全拒，见类注释） */
    public func scopeAware(): Bool {
        return true
    }

    public func setup(app: TauriApp): Unit {
        this.sess.setApp(app)
    }
}

/**
 * ws 会话：单活动连接。所有字段都在 lock 内访问（除 setApp 的写也持锁）；
 * app 是读线程回投事件的通道（mqtt 同款：命令线程装配、读线程只读引用）。
 */
public class WsSession {
    public let lock: Mutex = Mutex()
    public var connected: Bool = false
    public var url: String = ""
    public var host: String = ""
    public var lastError: String = ""
    public var rxCount: Int64 = 0
    public var txCount: Int64 = 0
    // 每次连接自增：读线程带出自己的 gen，回来发现不等 = 会话已被 close/替换，静默退出
    public var gen: Int64 = 0
    public var app: Option<TauriApp> = None
    // 连接本体只在 lock 内触碰
    public var ws: Option<WebSocket> = None
    public var client: Option<Client> = None

    public func setApp(app: TauriApp): Unit {
        this.lock.lock()
        this.app = Some(app)
        this.lock.unlock()
    }
}

/** ws 命令处理器：connect 收 {url}，send 收 {text}，close 无参 */
public class WsCommands <: CommandHandler {
    private let sess: WsSession

    public init(sess: WsSession) {
        this.sess = sess
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "ws:connect" => return this.connect(args, ipc)
            case "ws:send" => return this.send(args)
            case "ws:close" => return this.close()
            case _ => throw CommandException("unknown ws command: ${cmd}")
        }
    }

    private func connect(args: JsonObject, ipc: IpcContext): JsonValue {
        let url = this.requireString(args, "url")
        // 协议收紧：只认 ws/wss（urlHostOf 放行 http(s) 是给 http 插件用的）
        let lower = url.toAsciiLower()
        if (!lower.startsWith("ws://") && !lower.startsWith("wss://")) {
            throw CommandException("ws: url must start with ws:// or wss://")
        }
        let host = match (urlHostOf(url)) {
            case Some(h) => h
            case None => throw CommandException("ws: host is outside the authorized scope")
        }
        this.checkHostScope(url, host, ipc)
        return this.doConnect(url, host)
    }

    private func doConnect(url: String, host: String): JsonValue {
        this.sess.lock.lock()
        let busy = this.sess.connected
        this.sess.lock.unlock()
        if (busy) {
            throw CommandException("ws: already connected; call ws:close first")
        }
        // stdx 的升级函数**本来就要求 ws/wss scheme**（报错原文 "the scheme must be
        // ws or wss"）——最初把 ws:// 转成 http:// 再传是画蛇添足，反而被库拒（实测踩过）
        let client = ClientBuilder()
            .tlsConfig(tlsConfigForHost(host))
            .build()
        var sockOpt: Option<WebSocket> = None
        try {
            let parsed = URL.parse(url)
            let pair = WebSocket.upgradeFromClient(client, parsed)
            sockOpt = Some(pair[0])
        } catch (e: Exception) {
            client.close()
            eprintln("[cj-tauri] ws: connect failed: ${e}")
            throw CommandException("ws: connect failed: ${e.message}")
        }
        // 登记会话并起读线程
        this.sess.lock.lock()
        this.sess.ws = sockOpt
        this.sess.client = Some(client)
        this.sess.connected = true
        this.sess.url = url
        this.sess.host = host
        this.sess.lastError = ""
        this.sess.gen += 1
        let gen = this.sess.gen
        this.sess.lock.unlock()
        // 走到这里的 sockOpt 必为 Some（catch 分支已经 throw），match 里再写 None 分支会被
        // 编译器判 unreachable pattern——零警告门禁下直接取用
        let sock = sockOpt.getOrThrow()
        spawn { => wsReaderThread(this.sess, sock, client, gen) }
        eprintln("[cj-tauri] ws: connected ${url} (host=${host})")
        wsEmitState(this.sess, CJ_WS_STATE_CONNECTED, "")
        let obj = JsonObject()
        obj.put("connected", JsonBool(true))
        obj.put("url", JsonString(url))
        return obj
    }

    private func send(args: JsonObject): JsonValue {
        let text = this.requireString(args, "text")
        this.sess.lock.lock()
        let ok = this.sendLocked(text)
        let err = this.sess.lastError
        this.sess.lock.unlock()
        if (!ok) {
            throw CommandException("ws: send failed（未连接或对端已断）: ${err}")
        }
        let obj = JsonObject()
        obj.put("sent", JsonBool(true))
        return obj
    }

    /** 仅在持有 sess.lock 时调用（stdx WebSocket 不支持多线程写） */
    private func sendLocked(text: String): Bool {
        if (!this.sess.connected) {
            return false
        }
        match (this.sess.ws) {
            case Some(w) => return this.writeText(w, text)
            case None => return false
        }
    }

    private func writeText(w: WebSocket, text: String): Bool {
        try {
            w.write(WebSocketFrameType.TextWebFrame, text.toArray())
            this.sess.txCount += 1
            return true
        } catch (e: Exception) {
            this.sess.lastError = "${e}"
            return false
        }
    }

    private func close(): JsonValue {
        this.sess.lock.lock()
        let was = this.sess.connected
        let sockOpt = this.sess.ws
        let clientOpt = this.sess.client
        this.sess.connected = false
        this.sess.ws = None
        this.sess.client = None
        this.sess.gen += 1
        this.sess.lock.unlock()
        // 关连接放在锁外：closeConn 可能让阻塞中的 read() 抛错，读线程随后发现 gen
        // 变了会自行退出并兜底收资源——锁内不做任何可能阻塞的 IO
        if (was) {
            match (sockOpt) {
                case Some(w) => this.closeSock(w)
                case None => ()
            }
        }
        match (clientOpt) {
            case Some(c) => c.close()
            case None => ()
        }
        if (was) {
            eprintln("[cj-tauri] ws: closed by command")
            wsEmitState(this.sess, CJ_WS_STATE_CLOSED, "")
        }
        let obj = JsonObject()
        obj.put("closed", JsonBool(was))
        return obj
    }

    private func closeSock(w: WebSocket): Unit {
        try {
            // 先走协议关（发 Close 帧）再硬关底层；客户端场景不必等对端回关
            let empty = Array<UInt8>(0, repeat: 0)
            w.write(WebSocketFrameType.CloseWebFrame, empty)
        } catch (e: Exception) {
            let _ = e
        }
        try {
            w.closeConn()
        } catch (e: Exception) {
            let _ = e
        }
    }

    /** 主机白名单判定（共享层语义：先 deny 后 allow，allow 必须显式命中） */
    private func checkHostScope(url: String, host: String, ipc: IpcContext): Unit {
        // 分支体保持单语句（块体会被解析器当 lambda——AGENTS §4 实测过）
        match (ipc.scopeRuleFor("ws")) {
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
        eprintln("[cj-tauri] scope denied (ws): ${url} -> ${why}")
        throw CommandException("ws: host is outside the authorized scope")
    }

    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => throw CommandException("ws: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("ws: missing argument \"${key}\"")
        }
    }
}

/** 推事件给页面（读线程 / 命令线程都可能调）：mqtt 同款，app 引用只读 */
func wsEmit(sess: WsSession, event: String, obj: JsonObject): Unit {
    var app: Option<TauriApp> = None
    sess.lock.lock()
    app = sess.app
    sess.lock.unlock()
    match (app) {
        case Some(a) => a.emit(event, obj)
        case None => ()
    }
}

/** 推连接状态；同时落一行 stderr（页面没接住事件时 stderr 仍可对账——AGENTS §1） */
func wsEmitState(sess: WsSession, state: String, err: String): Unit {
    let obj = JsonObject()
    obj.put("state", JsonString(state))
    sess.lock.lock()
    obj.put("url", JsonString(sess.url))
    obj.put("host", JsonString(sess.host))
    obj.put("rx", JsonInt(sess.rxCount))
    obj.put("tx", JsonInt(sess.txCount))
    sess.lock.unlock()
    obj.put("error", JsonString(err))
    eprintln("[cj-tauri] ws: state=${state} error=${err}")
    wsEmit(sess, "ws:state", obj)
}

/** 把一帧文本投给页面：cjh 的帧是 JSON 对象——能解就原样透传（前端按 type 分发），
    解不动的包一层 raw（原文不丢，前端自己看着办） */
func wsDeliver(sess: WsSession, bytes: Array<UInt8>): Unit {
    let text = String.fromUtf8(bytes)
    var obj = JsonObject()
    var wrapped = false
    try {
        let v = JsonValue.fromStr(text)
        match (jsonAsObject(v)) {
            case Some(o) => obj = o
            case None => wrapped = true
        }
    } catch (e: Exception) {
        let _ = e
        wrapped = true
    }
    if (wrapped) {
        let raw = JsonObject()
        raw.put("type", JsonString("raw"))
        raw.put("text", JsonString(text))
        obj = raw
    }
    wsEmit(sess, "ws:frame", obj)
}

func jsonAsObject(v: JsonValue): Option<JsonObject> {
    match (v.kind()) {
        case JsonKind.JsObject => return Some(v.asObject())
        case _ => return None
    }
}

func wsAppend(buf: ArrayList<UInt8>, payload: Array<UInt8>): Unit {
    for (i in 0..payload.size) {
        buf.add(payload[i])
    }
}

/**
 * 读线程：独占 sock.read()（stdx 不支持多线程读）。
 * gen 不匹配 = 会话已被 close/替换 → 旧连接的残余帧直接丢弃退出，绝不投给页面。
 * 分段帧（fin == false 的首帧 + ContinuationWebFrame 续帧）攒齐再投。
 */
func wsReaderThread(sess: WsSession, sock: WebSocket, client: Client, gen: Int64): Unit {
    var buf = ArrayList<UInt8>()
    while (true) {
        try {
            let frame = sock.read()
            sess.lock.lock()
            let stale = (sess.gen != gen) || (!sess.connected)
            if (!stale) {
                sess.rxCount += 1
            }
            sess.lock.unlock()
            if (stale) {
                break
            }
            let ft = frame.frameType
            if (ft == WebSocketFrameType.CloseWebFrame) {
                break
            }
            if (ft == WebSocketFrameType.PingWebFrame || ft == WebSocketFrameType.PongWebFrame) {
                // 控制帧：心跳由库管，这里出现了就忽略（cjh 服务端不主动发——实测再校）
                continue
            }
            let payload = frame.payload   // prop 不是函数（stdx 文档确认，写 () 编译不过）
            if (payload.size <= 0) {
                continue
            }
            if (buf.size + payload.size > CJ_WS_MAX_FRAME) {
                eprintln("[cj-tauri] ws: 分帧重组超限（>${CJ_WS_MAX_FRAME} 字节），断开连接")
                break
            }
            if (ft == WebSocketFrameType.ContinuationWebFrame) {
                wsAppend(buf, payload)
                if (frame.fin) {
                    wsDeliver(sess, buf.toArray())
                    buf = ArrayList<UInt8>()
                }
                continue
            }
            if (frame.fin) {
                wsDeliver(sess, payload)
                continue
            }
            // 分段帧首帧：攒着等续帧
            wsAppend(buf, payload)
        } catch (e: Exception) {
            // 正常退出路径：close / 对端断开都会让阻塞中的 read 抛错
            let _ = e
            break
        }
    }
    sess.lock.lock()
    let mine = (sess.gen == gen) && sess.connected
    if (mine) {
        sess.connected = false
        sess.ws = None
        sess.client = None
        sess.gen += 1
        sess.lastError = "connection closed by peer"
    }
    sess.lock.unlock()
    if (mine) {
        eprintln("[cj-tauri] ws: connection closed by peer")
        wsEmitState(sess, CJ_WS_STATE_CLOSED, "connection closed by peer")
    }
    // 资源兜底：连接已断或已被替换，double-close 的错吞掉即可
    try {
        sock.closeConn()
    } catch (e: Exception) {
        let _ = e
    }
    try {
        client.close()
    } catch (e: Exception) {
        let _ = e
    }
}

/**
 * 建 TLS 客户端配置：**域名必须显式写 `serverName`（SNI）**（与 http 插件里那份同源、同口径）。
 *
 * stdx 的 `TlsClientConfig()` 默认不发 SNI，多租户 HTTPS 边缘（实测 Cloudflare 后面的 api 域名）
 * 收不到 SNI 就以 `handshake failure`(40) 拒掉握手——wss 同样中招（错误发生在 TLS 层，与
 * WebSocket 升级无关）。IP 字面量不带 SNI（RFC 6066 不许，且直连 IP 原本可用）。
 * 不放核心共享层的原因见 http 插件里那份的注释（核心一引用 stdx.net.tls 就会给所有应用拉上 OpenSSL）。
 */
private func tlsConfigForHost(host: String): TlsClientConfig {
    var cfg = TlsClientConfig()
    if (!isIpLiteralHost(host)) {
        cfg.serverName = host
    }
    return cfg
}
