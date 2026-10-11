package mbpoll_app

// 内置 Modbus TCP 从站模拟器（可选，CJ_MB_SLAVE=1 时启动）
//
// 为什么示例里带一个从站：调试工具最难取证的就是「没有设备」——自检没法证明读到的值是对的。
// 有了它，实机自检在同一台机器上闭环：页面连 127.0.0.1，读写往返、值逐项可断言。
// 对真实设备调试也方便：窗口开着它就在 127.0.0.1:15020 服务，随时当对照组。
//
// 行为：保持寄存器初值 = (addr * 3) % 65536（确定性，自检可断言）；写入后保持写入值。
// 支持 fc 01/05/15（线圈）、03/06/16（保持寄存器）；02/04 回异常码 01（不支持）。

import std.collection.*
import std.env.*
import std.net.*
import std.sync.*
import std.time.*
import cjTauri.*

let MB_SLAVE_DEFAULT_PORT: Int64 = 15020

func mbSlavePort(): Int64 {
    if (let Some(v) <- getVariable("CJ_MB_SLAVE_PORT")) {
        return mbSlavePortParse(v)
    }
    return MB_SLAVE_DEFAULT_PORT
}

func mbSlaveEnabled(): Bool {
    if (let Some(v) <- getVariable("CJ_MB_SLAVE")) {
        return v == "1" || v == "true"
    }
    return false
}

/** 环境变量端口解析：不是纯数字就回落默认值 */
func mbSlavePortParse(v: String): Int64 {
    var n: Int64 = 0
    var ok = v.size > 0 && v.size <= 6
    for (b in v.toArray()) {
        if (b < 0x30 || b > 0x39) {
            ok = false
            break
        }
        n = n * 10 + Int64(b - 0x30)
    }
    return if (ok) {
        n
    } else {
        MB_SLAVE_DEFAULT_PORT
    }
}

/** 从站的数据区：保持寄存器 + 线圈（写入会改，没写过的地址按公式现算） */
class MbSlaveData {
    let lock: ReentrantMutex = ReentrantMutex()
    var holding: HashMap<Int64, Int64> = HashMap<Int64, Int64>()
    var coils: HashMap<Int64, Int64> = HashMap<Int64, Int64>()

    func getHolding(addr: Int64): Int64 {
        match (this.holding.get(addr)) {
            case Some(v) => return v
            case None => return (addr * 3) % 65536
        }
    }

    func setHolding(addr: Int64, v: Int64): Unit {
        this.holding.add(addr, Int64(toU16(v)))
    }

    func getCoil(addr: Int64): Int64 {
        match (this.coils.get(addr)) {
            case Some(v) => return v
            case None => return 0
        }
    }

    func setCoil(addr: Int64, v: Int64): Unit {
        if (v != 0) {
            this.coils.add(addr, 1)
        } else {
            this.coils.add(addr, 0)
        }
    }
}

/** 从流里精确读 n 个字节；中断/超时返回 None（对端断开） */
func mbSlaveReadExact(client: TcpSocket, n: Int64): ?Array<Byte> {
    let out = Array<Byte>(n, repeat: 0)
    var got: Int64 = 0
    while (got < n) {
        let tmp = Array<Byte>(n - got, repeat: 0)
        var c: Int64 = 0
        try {
            c = client.read(tmp)
        } catch (e: Exception) {
            return None
        }
        if (c <= 0) {
            return None
        }
        var i: Int64 = 0
        while (i < c) {
            out[got + i] = tmp[i]
            i += 1
        }
        got += c
    }
    return Some(out)
}

/** 算一帧请求的响应 PDU（fc + 数据；异常时首字节 = 0x80|fc + 异常码） */
func mbSlaveHandle(data: MbSlaveData, fc: Int64, addr: Int64, qty: Int64, payload: Array<Byte>): Array<Byte> {
    data.lock.lock()
    try {
        // 读线圈 / 读离散量
        if (fc == 1 || fc == 2) {
            if (fc == 2) {
                return [UInt8(0x80 + fc), UInt8(1)] // 模拟器不区分只读区：直接回不支持
            }
            var bytes = Array<Byte>((qty + 7) / 8, repeat: 0)
            var i: Int64 = 0
            while (i < qty) {
                if (data.getCoil(addr + i) != 0) {
                    bytes[i / 8] = bytes[i / 8] | UInt8(1 << (i % 8))
                }
                i += 1
            }
            var out = Array<Byte>(2 + bytes.size, repeat: 0)
            out[0] = UInt8(fc)
            out[1] = UInt8(bytes.size)
            var j: Int64 = 0
            for (b in bytes) {
                out[2 + j] = b
                j += 1
            }
            return out
        }
        // 读保持寄存器
        if (fc == 3) {
            var out = Array<Byte>(2 + qty * 2, repeat: 0)
            out[0] = UInt8(fc)
            out[1] = UInt8(qty * 2)
            var i: Int64 = 0
            while (i < qty) {
                putU16(out, 2 + i * 2, toU16(data.getHolding(addr + i)))
                i += 1
            }
            return out
        }
        // 写单个线圈 / 写单个寄存器
        if (fc == 5 || fc == 6) {
            if (payload.size < 2) {
                return [UInt8(0x80 + fc), UInt8(3)]
            }
            let v = getU16(payload, 0)
            if (fc == 5) {
                data.setCoil(addr, v)
            } else {
                data.setHolding(addr, v)
            }
            // 应答 = 功能码 + 原样回显地址 + 值（PDU 首字节是功能码，客户端按它对齐）
            var out = Array<Byte>(5, repeat: 0)
            out[0] = UInt8(fc)
            putU16(out, 1, toU16(addr))
            putU16(out, 3, toU16(v))
            return out
        }
        // 写多个线圈 / 写多个寄存器
        if (fc == 15 || fc == 16) {
            if (payload.size < 3) {
                return [UInt8(0x80 + fc), UInt8(3)]
            }
            let bc = Int64(payload[2])
            var i: Int64 = 0
            while (i < qty) {
                if (fc == 15) {
                    data.setCoil(addr + i, (Int64(payload[3 + i / 8]) >> (i % 8)) & 1)
                } else {
                    // payload = [qty_hi, qty_lo, bc, data...]：数据末尾 = 2 + bc，越界就停
                    if (3 + i * 2 + 1 > 2 + bc) {
                        break
                    }
                    data.setHolding(addr + i, getU16(payload, 3 + i * 2))
                }
                i += 1
            }
            var out = Array<Byte>(5, repeat: 0)
            out[0] = UInt8(fc)
            putU16(out, 1, toU16(addr))
            putU16(out, 3, toU16(qty))
            return out
        }
        // 其余功能码一律回异常 01（不支持的旋钮要在面板上看得见）
        return [UInt8(0x80 + fc), UInt8(1)]
    } finally {
        data.lock.unlock()
    }
}

/** 一个客户端连接的会话：循环 读请求帧 → 算响应 → 回写，直到对端断开 */
func mbSlaveSession(data: MbSlaveData, client: TcpSocket): Unit {
    while (true) {
        let head = match (mbSlaveReadExact(client, 7)) {
            case Some(h) => h
            case None => return
        }
        let len = getU16(head, 4)
        if (len < 2 || len > 260) {
            return
        }
        let rest = match (mbSlaveReadExact(client, len - 1)) {
            case Some(r) => r
            case None => return
        }
        let fc = Int64(rest[0])
        var addr: Int64 = 0
        var qty: Int64 = 0
        var payload = Array<Byte>()
        if (rest.size >= 5) {
            addr = getU16(rest, 1)
            if (fc == 5 || fc == 6) {
                qty = 1
                payload = rest[3..5]
            } else if (fc == 15 || fc == 16) {
                qty = 0
                if (rest.size >= 5) {
                    qty = getU16(rest, 3)
                }
                payload = rest[3..rest.size]
            } else {
                qty = getU16(rest, 3)
            }
        }
        let pdu = mbSlaveHandle(data, fc, addr, qty, payload)
        // 回包：MBAP(事务号/协议号原样) + 长度 + 单元号 + PDU
        let total = 7 + pdu.size
        let resp = Array<Byte>(total, repeat: 0)
        resp[0] = head[0]
        resp[1] = head[1]
        resp[2] = 0
        resp[3] = 0
        putU16(resp, 4, toU16(pdu.size + 1))
        resp[6] = head[6]
        var j: Int64 = 0
        for (b in pdu) {
            resp[7 + j] = b
            j += 1
        }
        try {
            client.write(resp)
        } catch (e: Exception) {
            return
        }
    }
}

/** 启动从站监听（后台线程，accept 循环；每个连接一个会话） */
func mbSlaveStart(port: Int64, data: MbSlaveData): Unit {
    spawn {
        try {
            let server = TcpServerSocket(bindAt: UInt16(port))
            server.bind()
            eprintln("[mbpoll] 内置从站已监听 127.0.0.1:${port}")
            while (true) {
                let client = server.accept()
                spawn {
                    try {
                        mbSlaveSession(data, client)
                    } catch (e: Exception) {
                        // 单个会话出错不影响监听：调试工具的从站要能扛住乱序请求
                    }
                }
            }
        } catch (e: Exception) {
            eprintln("[mbpoll] 内置从站启动失败（端口 ${port}）：${e.message}")
        }
    }
}
