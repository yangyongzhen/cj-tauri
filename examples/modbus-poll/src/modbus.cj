package mbpoll_app

// Modbus TCP 传输层：MBAP 报文编解码 + 复用 TCP 连接
//
// 为什么自己写而不是找库：仓颉生态里没有现成的 modbus 包（引入第三方仓颉包须先在 AGENTS 登记），
// 而协议本身很小——MBAP 头 7 字节 + PDU，读功能码 01/02/03/04、写功能码 05/06/15/16，
// 两个函数就够了。只用标准库 std.net，不碰 stdx。

import std.collection.*
import std.net.*
import std.sync.*
import std.time.*
import stdx.encoding.json.*
import cjTauri.*
// RTU 传输层直接用串口原语——它们自插件拆包后住在 cjTauri.plugins.serial 子包里（AGENTS §2）
import cjTauri.plugins.serial.*

/** 默认响应超时（毫秒）。Modbus Poll 的默认值是 1000ms，调试工具放宽一点更稳 */
let MB_DEFAULT_TIMEOUT_MS: Int64 = 3000

/** 全局报文监视缓冲与十六进制表（MbClient 的收发处会用到，须先定义） */
let HEX_DIGITS: Array<String> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
let MB_TRACE = MbTrace()
/** 报文时间轴起点（进程装配时定格；帧时间戳 = now - ABS_EPOCH） */
let ABS_EPOCH = DateTime.now()

// ---------------------------------------------------------------- MBAP 编解码

/** 把 Int64 转成 UInt16：先夹到 0..65535 再转，避免越界抛异常（AGENTS §4 浮点/越界那条的同类坑） */
func toU16(v: Int64): UInt16 {
    var x = v
    if (x < 0) {
        x = 0
    }
    if (x > 65535) {
        x = 65535
    }
    return UInt16(x)
}

/** 大端写一个 u16 到缓冲区（Modbus 全程大端） */
func putU16(buf: Array<Byte>, at: Int64, v: UInt16): Unit {
    buf[at] = UInt8((v >> 8) & 0xFF)
    buf[at + 1] = UInt8(v & 0xFF)
}

/** 大端读一个 u16 */
func getU16(buf: Array<Byte>, at: Int64): Int64 {
    return Int64(buf[at]) << 8 | Int64(buf[at + 1])
}

/** 拼接两段字节（报文监视要把 MBAP 和 PDU 合成一条上屏） */
func concatBytes(a: Array<Byte>, b: Array<Byte>): Array<UInt8> {
    let out = Array<UInt8>(a.size + b.size, repeat: 0)
    var i: Int64 = 0
    for (x in a) {
        out[i] = x
        i += 1
    }
    for (x in b) {
        out[i] = x
        i += 1
    }
    return out
}

/**
 * 组 PDU（功能码 + 数据）——TCP 与 RTU 共用同一套应用层组帧
 *
 * - read 类（fc 1..4）：起始地址 + 数量（qty）
 * - write 单个（fc 5/6）：地址 + 值
 * - write 多个（fc 15/16）：地址 + 数量 + 字节数 + 数据
 */
func buildPdu(fc: Int64, addr: Int64, qty: Int64, values: Array<Int64>): Array<Byte> {
    let isRead = fc >= 1 && fc <= 4
    let isWriteMulti = fc == 15 || fc == 16
    // 写多个的数据字节数：寄存器每值 2 字节；线圈按位打包，8 个 1 字节
    var dataBytes: Int64 = 0
    if (fc == 16) {
        dataBytes = values.size * 2
    } else if (fc == 15) {
        dataBytes = (values.size + 7) / 8
    }
    // PDU 长度：fc(1) + addr(2) + qty(2) + bc(1) + 数据（读=addr+qty，单写=addr+value）
    var pduLen: Int64 = 1
    if (isRead) {
        pduLen = 5
    } else if (isWriteMulti) {
        pduLen = 6 + dataBytes
    } else {
        pduLen = 5
    }
    let buf = Array<UInt8>(pduLen, repeat: 0)
    buf[0] = UInt8(fc & 0xFF)
    putU16(buf, 1, toU16(addr))
    if (isRead) {
        putU16(buf, 3, toU16(qty))
    } else if (isWriteMulti) {
        putU16(buf, 3, toU16(values.size))
        buf[5] = UInt8(dataBytes)
        if (fc == 16) {
            // 寄存器：每值 2 字节大端
            var i: Int64 = 0
            for (v in values) {
                putU16(buf, 6 + i * 2, toU16(v))
                i += 1
            }
        } else {
            // 线圈：按位打包，低位在前
            var i: Int64 = 0
            for (v in values) {
                if (v != 0) {
                    buf[6 + i / 8] = buf[6 + i / 8] | UInt8(1 << (i % 8))
                }
                i += 1
            }
        }
    } else {
        putU16(buf, 3, toU16(values[0]))
    }
    return buf
}

/**
 * 组一帧 Modbus TCP 请求（MBAP + PDU）
 */
func buildRequest(txnId: UInt16, unit: UInt16, fc: UInt16, addr: Int64, qty: Int64, values: Array<Int64>): Array<Byte> {
    let pdu = buildPdu(Int64(fc), addr, qty, values)
    // MBAP(7) = 事务号2 + 协议号2 + 长度2 + 单元号1
    let total = 7 + pdu.size
    let buf = Array<Byte>(total, repeat: 0)
    putU16(buf, 0, txnId)
    putU16(buf, 2, 0) // 协议号恒 0
    putU16(buf, 4, toU16(pdu.size + 1)) // 长度字段含单元号
    buf[6] = UInt8(unit & 0xFF)
    var i: Int64 = 0
    for (b in pdu) {
        buf[7 + i] = b
        i += 1
    }
    return buf
}

// ---------------------------------------------------------------- 一次事务

/**
 * 解析读响应 PDU（fc, 字节数, 数据...）→ 值数组
 * 线圈/离散量按位展开（低位在前），寄存器大端取 16 位。TCP/RTU 共用。
 */
func parseReadValues(fc: Int64, qty: Int64, pdu: Array<Byte>): Array<Int64> {
    if (pdu.size < 2) {
        throw CommandException("响应缺字节数字段")
    }
    let bc = Int64(pdu[1])
    if (pdu.size - 2 < bc) {
        throw CommandException("响应数据不完整（声称 ${bc} 字节，实收 ${pdu.size - 2}）")
    }
    let vals = ArrayList<Int64>()
    if (fc == 1 || fc == 2) {
        var i: Int64 = 0
        while (i < qty && i < bc * 8) {
            vals.add((Int64(pdu[2 + i / 8]) >> (i % 8)) & 1)
            i += 1
        }
    } else {
        var i: Int64 = 0
        while (i < bc / 2) {
            vals.add(getU16(pdu, 2 + i * 2))
            i += 1
        }
    }
    return vals.toArray()
}

/** 传输层统一入口：TCP 与 RTU 各实现一份，命令层/连接池对类型无感 */
interface MbTransport {
    func request(fc: Int64, unit: Int64, addr: Int64, qty: Int64, values: Array<Int64>, timeoutMs: Int64): MbResponse
}

/** 一帧响应解析出来的东西 */
class MbResponse {
    /** 读到的值（读类）：线圈/离散量为 0/1，寄存器为 0..65535 */
    var values: Array<Int64> = Array<Int64>()
    /** 功能码（原样回显；异常时为 0x80|fc） */
    var funcCode: Int64 = 0
    /** 事务号（用来核对响应归属） */
    var txnId: Int64 = 0
    /** 从站返回的异常码（只有异常响应才有） */
    var exception: Int64 = -1
    /** 耗时（毫秒） */
    var elapsedMs: Int64 = 0
}

/**
 * 发一帧请求并等响应。**连接复用 + 互斥串行**都在 MbClient 里做，本函数只管一问一答。
 */
class MbClient <: MbTransport {
    let host: String
    let port: UInt16
    let lock: Mutex = Mutex()
    var sock: ?TcpSocket = None
    var nextTxn: Int64 = 1

    init(host: String, port: UInt16) {
        this.host = host
        this.port = port
    }

    /** 断开（出错后调用，下一次请求会重新连） */
    func dropConn(): Unit {
        match (this.sock) {
            case Some(s) =>
                try {
                    s.close()
                } catch (e: Exception) {
                    // 关闭失败不影响主流程：socket 已经不可用了
                }
                this.sock = None
            case None => ()
        }
    }

    /** 从流里精确读 n 个字节；读不到/超时一律抛 CommandException（并断开这条连接） */
    func readExact(s: TcpSocket, n: Int64): Array<Byte> {
        let out = Array<Byte>(n, repeat: 0)
        var got: Int64 = 0
        while (got < n) {
            // 临时缓冲再拷贝：socket.read 只会从缓冲区头部开始填，
            // 直接把 out 的切片交给它，切片若是拷贝语义就白读了
            let tmp = Array<Byte>(n - got, repeat: 0)
            var c: Int64 = 0
            try {
                c = s.read(tmp)
            } catch (e: Exception) {
                this.dropConn()
                var part = ""
                if (got > 0) {
                    part = "（已收 ${got}/${n} 字节）"
                }
                throw CommandException("读响应${part}超时或出错：${e.message}")
            }
            if (c <= 0) {
                this.dropConn()
                throw CommandException("从站断开连接（读响应中断，已收 ${got}/${n} 字节）")
            }
            var i: Int64 = 0
            while (i < c) {
                out[got + i] = tmp[i]
                i += 1
            }
            got += c
        }
        return out
    }

    /**
     * 执行一次 Modbus 事务（同一连接上的多路调用在这里串行化——
     * 多个面板共享一条 TCP 连接，并发调用交错报文就全乱了）
     * qty：读类的数量（写类忽略，用 values.size）
     */
    public func request(fc: Int64, unit: Int64, addr: Int64, qty: Int64, values: Array<Int64>, timeoutMs: Int64): MbResponse {
        lock.lock()
        let req = buildRequest(toU16(this.nextTxn), toU16(unit), toU16(fc), addr, qty, values)
        this.nextTxn = (this.nextTxn + 1) & 0xFFFF
        let start = DateTime.now()
        try {
            // 需要的连接：没有或已断就重连；connect 带超时，死地址不会挂住 worker
            var s: TcpSocket
            match (this.sock) {
                case Some(existing) => s = existing
                case None =>
                    let fresh = TcpSocket(this.host, this.port)
                    fresh.connect(timeout: Duration.millisecond * MB_DEFAULT_TIMEOUT_MS)
                    this.sock = Some(fresh)
                    s = fresh
            }
            s.readTimeout = Duration.millisecond * timeoutMs
            s.writeTimeout = Duration.millisecond * timeoutMs
            s.noDelay = true
            s.write(req)
            MB_TRACE.add("Tx", req, "${this.host}:${this.port} unit=${unit} fc=${fc}")

            let head = this.readExact(s, 7)
            let txn = getU16(head, 0)
            let proto = getU16(head, 2)
            let len = getU16(head, 4)
            if (proto != 0) {
                this.dropConn()
                throw CommandException("MBAP 协议号不是 0（收到 ${proto}）——对端不是 Modbus TCP 服务")
            }
            if (len < 2 || len > 260) {
                this.dropConn()
                throw CommandException("MBAP 长度字段非法（${len}）")
            }
            let rest = this.readExact(s, len - 1)
            // Rx 帧落监视缓冲：MBAP + PDU 拼一起（超时/断连在这里之前就抛了，帧不完整不上屏）
            MB_TRACE.add("Rx", concatBytes(head, rest), "${this.host}:${this.port} unit=${unit} fc=${fc}")
            let respUnit = Int64(head[6])
            if (respUnit != unit) {
                this.dropConn()
                throw CommandException("响应单元号不匹配（要 ${unit} 收到 ${respUnit}）")
            }
            let respFc = Int64(rest[0])
            let r = MbResponse()
            r.txnId = txn
            r.funcCode = respFc
            r.elapsedMs = (DateTime.now() - start).toMilliseconds()
            if (respFc == (fc | 0x80)) {
                if (rest.size < 2) {
                    this.dropConn()
                    throw CommandException("异常响应缺异常码")
                }
                r.exception = Int64(rest[1])
                return r
            }
            if (respFc != fc) {
                this.dropConn()
                throw CommandException("响应功能码不匹配（要 ${fc} 收到 ${respFc}）")
            }
            if (fc >= 1 && fc <= 4) {
                if (rest.size < 2) {
                    this.dropConn()
                    throw CommandException("响应缺字节数字段")
                }
                let bc = Int64(rest[1])
                if (rest.size - 2 < bc) {
                    this.dropConn()
                    throw CommandException("响应数据不完整（声称 ${bc} 字节，实收 ${rest.size - 2}）")
                }
                r.values = parseReadValues(fc, qty, rest)
            }
            return r
        } catch (e: CommandException) {
            throw e
        } catch (e: Exception) {
            // 连接层的错（连不上/被拒）：连接保留为 None 状态，下一次自动重试
            this.dropConn()
            throw CommandException("Modbus 事务失败（${this.host}:${this.port}）：${e.message}")
        } finally {
            lock.unlock()
        }
    }
}

// ---------------------------------------------------------------- 报文监视

/**
 * 通信报文环形缓冲（Modbus Poll 的 Communication 窗口）
 *
 * 抓在 MbClient 的一问一答处：所有面板的流量都会进这里（自检的内置从站流量不走主站，
 * 不会混进来）。mb:trace 取走并清空——前端轮询拉取，比事件通道少一层能力声明，
 * 而且 trace 请求本身不经过 MbClient，不会自我污染。
 */
class MbTrace {
    let lock: Mutex = Mutex()
    var frames: ArrayList<String> = ArrayList<String>()
    var seq: Int64 = 0
    var startMs: Int64 = -1
    let cap: Int64 = 400

    func add(dir: String, bytes: Array<UInt8>, note: String): Unit {
        lock.lock()
        try {
            this.seq += 1
            // 相对时间戳（首帧起算）：排查时序问题用；第一帧同时记下起点
            var delta: Int64 = 0
            let absMs = (DateTime.now() - ABS_EPOCH).toMilliseconds()
            if (this.startMs < 0) {
                this.startMs = absMs
            } else {
                delta = absMs - this.startMs
            }
            var hex = ""
            var i: Int64 = 0
            while (i < bytes.size) {
                let b = Int64(bytes[i])
                hex += HEX_DIGITS[(b >> 4) & 0xF]
                hex += HEX_DIGITS[b & 0xF]
                hex += " "   // 每字节一组，逐字节隔开（读帧时一眼对齐 MBAP/PDU）
                i += 1
            }
            this.frames.add("${this.seq} +${delta}ms ${dir} ${bytes.size}B ${note} ${hex}")
            while (this.frames.size > this.cap) {
                this.frames.remove(0..1)
            }
        } finally {
            lock.unlock()
        }
    }

    /** 取走全部缓冲（原子清空，前端轮询一次拉一段） */
    func drain(): ArrayList<String> {
        lock.lock()
        try {
            let out = this.frames
            this.frames = ArrayList<String>()
            return out
        } finally {
            lock.unlock()
        }
    }
}

// ---------------------------------------------------------------- RTU（串口）

/**
 * Modbus CRC16：多项式 0xA001（反转的 0x8005），初值 0xFFFF，低字节在前发送。
 * 自检向量："123456789" → 0x4B37（自检里逐轮校验，帧层坏了第一时间知道）。
 */
func crc16(data: Array<Byte>): Int64 {
    var crc: Int64 = 0xFFFF
    var i: Int64 = 0
    while (i < data.size) {
        crc = crc ^ Int64(data[i])
        var j: Int64 = 0
        while (j < 8) {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ 0xA001
            } else {
                crc = crc >> 1
            }
            j += 1
        }
        i += 1
    }
    return crc & 0xFFFF
}

/**
 * Modbus RTU 串口客户端：与 MbClient 同一个 request() 契约
 *
 * - 帧形：从站地址 + PDU + CRC16（低字节在前）；复用 buildPdu 的应用层组帧
 * - 响应无长度头：按功能码推算总长（读=3+bc+2，写回显=8，异常=5）
 * - 串口复用与互斥同 TCP：一条串口上的多路轮询在这里串行化
 * - 串口走框架的 serial 桥（路径白名单 / 参数校验最终在 C 侧兜底）
 */
class MbRtuClient <: MbTransport {
    let path: String
    let baud: Int32
    let dataBits: Int32
    let parity: Int32
    let stopBits: Int32
    let lock: Mutex = Mutex()
    var handle: Int64 = -1

    init(path: String, baud: Int32, dataBits: Int32, parity: Int32, stopBits: Int32) {
        this.path = path
        this.baud = baud
        this.dataBits = dataBits
        this.parity = parity
        this.stopBits = stopBits
    }

    func dropConn(): Unit {
        if (this.handle > 0) {
            let _ = serialClose(this.handle)
            this.handle = -1
        }
    }

    func ensureOpen(): Unit {
        if (this.handle > 0) {
            return
        }
        let h = serialOpen(this.path, this.baud, this.dataBits, this.parity, this.stopBits)
        if (h <= 0) {
            throw CommandException("打开串口 ${this.path} 失败（code ${h}）：${serialLastError()}")
        }
        this.handle = h
    }

    /** 从串口凑满 n 个字节：serialRead 是「有多少给多少」，按 50ms 切片轮询到截止时刻 */
    func rtuReadExact(n: Int64, start: DateTime, timeoutMs: Int64): Array<Byte> {
        let out = ArrayList<Byte>()
        while (out.size < n) {
            let left = timeoutMs - (DateTime.now() - start).toMilliseconds()
            if (left <= 0) {
                this.dropConn()
                throw CommandException("RTU 响应超时（要 ${n} 字节实收 ${out.size}）——检查从站地址 / 波特率 / 接线")
            }
            let chunk = serialRead(this.handle, Int32(n - out.size), 50)
            if (chunk.size > 0) {
                for (b in chunk) {
                    out.add(b)
                }
            }
        }
        return out.toArray()
    }

    public func request(fc: Int64, unit: Int64, addr: Int64, qty: Int64, values: Array<Int64>, timeoutMs: Int64): MbResponse {
        lock.lock()
        try {
            this.ensureOpen()
            let pdu = buildPdu(fc, addr, qty, values)
            // ADU = 从站地址 + PDU + CRC16（低字节在前）
            let aduLen = 1 + pdu.size + 2
            let frame = Array<UInt8>(aduLen, repeat: 0)
            frame[0] = UInt8(unit & 0xFF)
            var i: Int64 = 0
            for (b in pdu) {
                frame[1 + i] = b
                i += 1
            }
            let crc = crc16(frame[0..pdu.size + 1])
            frame[aduLen - 2] = UInt8(crc & 0xFF)
            frame[aduLen - 1] = UInt8((crc >> 8) & 0xFF)

            let start = DateTime.now()
            let wrote = serialWrite(this.handle, frame, Int32(timeoutMs))
            if (Int64(wrote) != frame.size) {
                this.dropConn()
                throw CommandException("RTU 写串口不完整（${wrote}/${frame.size} 字节）")
            }
            MB_TRACE.add("Tx", frame, "rtu ${this.path} unit=${unit} fc=${fc}")

            // 帧头（地址 + 功能码）→ 按功能码推算响应总长 → 凑满
            let head = this.rtuReadExact(2, start, timeoutMs)
            let respUnit = Int64(head[0])
            let respFc = Int64(head[1])
            if (respUnit != unit) {
                this.dropConn()
                throw CommandException("RTU 响应地址不匹配（要 ${unit} 收到 ${respUnit}）——总线上有别的从站在应答")
            }
            var rest: Array<Byte>
            if (respFc == (fc | 0x80)) {
                let tail = this.rtuReadExact(3, start, timeoutMs) // 异常码 + CRC
                rest = concatBytes(head, tail)
            } else if (fc >= 1 && fc <= 4) {
                let bcTail = this.rtuReadExact(1, start, timeoutMs)
                let bc = Int64(bcTail[0])
                let data = this.rtuReadExact(bc + 2, start, timeoutMs)
                rest = concatBytes(concatBytes(head, bcTail), data)
            } else {
                let tail = this.rtuReadExact(6, start, timeoutMs) // 写回显：addr2+值/数量2+CRC2
                rest = concatBytes(head, tail)
            }
            MB_TRACE.add("Rx", rest, "rtu ${this.path} unit=${unit} fc=${fc}")

            let r = MbResponse()
            r.funcCode = respFc
            r.elapsedMs = (DateTime.now() - start).toMilliseconds()
            let crcGot = Int64(rest[rest.size - 2]) | Int64(rest[rest.size - 1]) << 8
            let crcWant = crc16(rest[0..rest.size - 2])
            if (crcGot != crcWant) {
                this.dropConn()
                throw CommandException("RTU CRC 校验失败（算出 ${crcWant} 收到 ${crcGot}）——线路噪声或波特率不匹配")
            }
            if (respFc == (fc | 0x80)) {
                r.exception = Int64(rest[2])
                return r
            }
            if (respFc != fc) {
                this.dropConn()
                throw CommandException("响应功能码不匹配（要 ${fc} 收到 ${respFc}）")
            }
            if (fc >= 1 && fc <= 4) {
                r.values = parseReadValues(fc, qty, rest[1..rest.size - 2])
            }
            return r
        } catch (e: CommandException) {
            throw e
        } catch (e: Exception) {
            this.dropConn()
            throw CommandException("RTU 事务失败（${this.path}）：${e.message}")
        } finally {
            lock.unlock()
        }
    }
}

// ---------------------------------------------------------------- 连接池

/** 按「目标」复用连接；面板再多的轮询也只是每目标一条 TCP / 一个串口句柄 */
class MbPool {
    var map: HashMap<String, MbTransport> = HashMap<String, MbTransport>()

    func clientOfTcp(host: String, port: UInt16): MbTransport {
        let key = "tcp://${host}:${port}"
        match (this.map.get(key)) {
            case Some(c) => return c
            case None =>
                let c = MbClient(host, port)
                this.map.add(key, c)
                return c
        }
    }

    func clientOfRtu(path: String, baud: Int32, dataBits: Int32, parity: Int32, stopBits: Int32): MbTransport {
        let key = "rtu://${path}:${baud}:${dataBits}:${parity}:${stopBits}"
        match (this.map.get(key)) {
            case Some(c) => return c
            case None =>
                let c = MbRtuClient(path, baud, dataBits, parity, stopBits)
                this.map.add(key, c)
                return c
        }
    }
}

/** 全局唯一连接池（命令层共享） */
let MB_POOL = MbPool()

// ---------------------------------------------------------------- 参数与校验

/** 从 invoke 参数里读字符串，缺失/类型不对就用 fallback */
func mbArgString(args: JsonObject, key: String, fallback: String): String {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return fallback
            }
        case None => return fallback
    }
}

/** 从 invoke 参数里读整数，缺失/类型不对就用 fallback；浮点也收（JS 侧 20.0 这类） */
func mbArgInt(args: JsonObject, key: String, fallback: Int64): Int64 {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case JsonKind.JsFloat => return Int64(v.asFloat().getValue())
                case _ => return fallback
            }
        case None => return fallback
    }
}

/** 读功能码里的「数量」：读类每类上限不同（线圈 2000、寄存器 125），全夹到协议边界 */
func mbReadQty(fc: Int64, raw: Int64): Int64 {
    var q = raw
    if (q < 1) {
        q = 1
    }
    var max: Int64 = 125
    if (fc == 1 || fc == 2) {
        max = 2000
    }
    if (q > max) {
        q = max
    }
    return q
}

/** 主机名校验：只接受 IP / 主机名里的安全字符（页面可控字符串，不校验就丢给 socket 了） */
func mbValidHost(h: String): Bool {
    if (h.size == 0 || h.size > 253) {
        return false
    }
    for (b in h.toArray()) {
        let c = Int64(b)
        let ok = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) ||
            (c >= 0x61 && c <= 0x7A) || c == 0x2E || c == 0x2D || c == 0x5F
        if (!ok) {
            return false
        }
    }
    return true
}
