package mbpoll_app

// 命令层：前端 invoke 的语义入口
//
// mb:read  —— 按面板定义读一轮（fc 01/02/03/04）
// mb:write —— 写单个/多个（fc 05/06/15/16）
// mb:config —— 给页面报自检环境（内置从站端口等）
// mb:quit  —— 页面请求退出
// report   —— 页面自检结果回投（stderr 取证，与 music / typing-poem 同款）

import std.collection.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*
import cjTauri.*

/** 参数值夹取 + 汇总：面板定义统一在这一层过一遍（系统边界，页面传什么都不能带歪协议层） */
class MbDef {
    var mode: String = "tcp"
    var host: String = "127.0.0.1"
    var port: Int64 = 502
    var serialPath: String = "COM1"
    var baud: Int32 = 9600
    var dataBits: Int32 = 8
    var parity: Int32 = 0
    var stopBits: Int32 = 1
    var unit: Int64 = 1
    var fc: Int64 = 3
    var addr: Int64 = 0
    var qty: Int64 = 10
    var timeoutMs: Int64 = MB_DEFAULT_TIMEOUT_MS
    var values: Array<Int64> = Array<Int64>()

    /** 按模式取传输层（TCP / RTU 串口各一桶连接池） */
    func transport(): MbTransport {
        if (this.mode == "rtu") {
            return MB_POOL.clientOfRtu(this.serialPath, this.baud, this.dataBits, this.parity, this.stopBits)
        }
        return MB_POOL.clientOfTcp(this.host, UInt16(this.port))
    }

    /** 日志/监视里的人类可读目标 */
    func target(): String {
        if (this.mode == "rtu") {
            return "rtu ${this.serialPath}@${this.baud}"
        }
        return "${this.host}:${this.port}"
    }
}

/** 串口路径前缀粗校验（最终白名单在 C 桥侧兜底；这里只给前端一句可读的人话） */
func mbValidSerialPath(p: String): Bool {
    return p.startsWith("COM") || p.startsWith("\\\\.\\COM") ||
        p.startsWith("/dev/tty") || p.startsWith("/dev/serial/by-id/") || p.startsWith("/dev/serial/by-path/")
}

/** 面板参数解析：所有页面可控值都在这里校验/夹取 */
func mbParseDef(args: JsonObject, needValues: Bool): MbDef {
    let d = MbDef()
    d.mode = mbArgString(args, "mode", "tcp").trimAscii()
    if (d.mode != "tcp" && d.mode != "rtu") {
        throw CommandException("不支持的连接模式：\"${d.mode}\"（可选 tcp / rtu）")
    }
    let host = mbArgString(args, "host", "127.0.0.1").trimAscii()
    if (!mbValidHost(host)) {
        throw CommandException("非法的主机名：\"${host}\"（只接受字母数字与 . - _）")
    }
    d.host = host
    d.port = mbArgInt(args, "port", 502)
    if (d.port < 1 || d.port > 65535) {
        throw CommandException("端口超出范围（${d.port}，须 1..65535）")
    }
    if (d.mode == "rtu") {
        d.serialPath = mbArgString(args, "serialPath", "COM1").trimAscii()
        if (!mbValidSerialPath(d.serialPath)) {
            throw CommandException("非法的串口路径：\"${d.serialPath}\"（Windows 收 COM*，Linux 收 /dev/tty* / /dev/serial/*）")
        }
        let baud = mbArgInt(args, "baud", 9600)
        // 档位与框架 serial 插件一致（C 侧「有宏才收」）
        var baudOk = false
        let bauds: Array<Int64> = [300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 500000, 921600, 1000000]
        var bi: Int64 = 0
        while (bi < bauds.size) {
            if (bauds[bi] == baud) {
                baudOk = true
            }
            bi += 1
        }
        if (!baudOk) {
            throw CommandException("不支持的波特率 ${baud}（可选 300..1000000 标准档位）")
        }
        d.baud = Int32(baud)
        d.dataBits = Int32(mbArgInt(args, "dataBits", 8))
        if (d.dataBits < 5 || d.dataBits > 8) {
            throw CommandException("dataBits 只收 5..8（拿到 ${d.dataBits}）")
        }
        // 校验位：0=无 1=奇 2=偶（与框架 serial 插件同一编码）
        d.parity = Int32(mbArgInt(args, "parity", 0))
        if (d.parity < 0 || d.parity > 2) {
            throw CommandException("parity 只收 0(无)/1(奇)/2(偶)（拿到 ${d.parity}）")
        }
        d.stopBits = Int32(mbArgInt(args, "stopBits", 1))
        if (d.stopBits != 1 && d.stopBits != 2) {
            throw CommandException("stopBits 只收 1|2（拿到 ${d.stopBits}）")
        }
    }
    d.unit = mbArgInt(args, "unit", 1)
    if (d.unit < 0 || d.unit > 255) {
        throw CommandException("从站 ID 超出范围（${d.unit}，须 0..255）")
    }
    d.fc = mbArgInt(args, "fc", 3)
    let isRead = d.fc >= 1 && d.fc <= 4
    let isWrite = d.fc == 5 || d.fc == 6 || d.fc == 15 || d.fc == 16
    if (!isRead && !isWrite) {
        throw CommandException("不支持的功能码：${d.fc}（读 01/02/03/04，写 05/06/15/16）")
    }
    d.addr = mbArgInt(args, "addr", 0)
    if (d.addr < 0 || d.addr > 65535) {
        throw CommandException("地址超出范围（${d.addr}，须 0..65535）")
    }
    d.timeoutMs = mbArgInt(args, "timeoutMs", MB_DEFAULT_TIMEOUT_MS)
    if (d.timeoutMs < 100) {
        d.timeoutMs = 100
    }
    if (d.timeoutMs > 60000) {
        d.timeoutMs = 60000
    }
    if (isRead) {
        d.qty = mbReadQty(d.fc, mbArgInt(args, "qty", 10))
    } else if (d.fc == 5 || d.fc == 6) {
        d.qty = 1
    } else {
        d.qty = mbReadQty(3, mbArgInt(args, "qty", 1))
    }
    // 写的值：从 values 数组收，数量与 qty 对齐
    if (needValues) {
        let vals = ArrayList<Int64>()
        if (let Some(v) <- args.get("values")) {
            match (v.kind()) {
                case JsonKind.JsArray =>
                    let arr = v.asArray()
                    for (i in 0..arr.size()) {
                        let item = arr.get(i).getOrThrow()
                        match (item.kind()) {
                            case JsonKind.JsInt => vals.add(item.asInt().getValue())
                            case JsonKind.JsFloat => vals.add(Int64(item.asFloat().getValue()))
                            case JsonKind.JsBool =>
                                if (item.asBool().getValue()) {
                                    vals.add(1)
                                } else {
                                    vals.add(0)
                                }
                            case _ => vals.add(0)
                        }
                    }
                case _ => ()
            }
        }
        if (vals.size == 0 && (d.fc == 5 || d.fc == 6)) {
            // 单写允许直接传 value 字段（省去数组包一层）
            vals.add(mbArgInt(args, "value", 0))
        }
        if (vals.size < d.qty) {
            throw CommandException("写操作需要 ${d.qty} 个值，只收到 ${vals.size} 个")
        }
        while (vals.size > d.qty) {
            vals.remove(vals.size - 1..vals.size)
        }
        // 线圈只收 0/1；寄存器夹到 u16
        var i: Int64 = 0
        while (i < vals.size) {
            if (d.fc == 5 || d.fc == 15) {
                if (vals[i] != 0) {
                    vals[i] = 1
                } else {
                    vals[i] = 0
                }
            } else {
                vals[i] = Int64(toU16(vals[i]))
            }
            i += 1
        }
        d.values = vals.toArray()
    }
    return d
}

/** 读/写结果 → JSON（页面按它渲染表格与状态行） */
func mbResultJson(def: MbDef, r: MbResponse, op: String): JsonObject {
    let out = JsonObject()
    out.put("op", JsonString(op))
    out.put("fc", JsonInt(def.fc))
    out.put("unit", JsonInt(def.unit))
    out.put("addr", JsonInt(def.addr))
    out.put("qty", JsonInt(def.qty))
    out.put("elapsedMs", JsonInt(r.elapsedMs))
    var vals = ArrayList<JsonValue>()
    for (v in r.values) {
        vals.add(JsonInt(v))
    }
    out.put("values", JsonArray(vals))
    out.put("exception", JsonInt(r.exception))
    if (r.exception >= 0) {
        out.put("error", JsonString(modbusExceptionText(r.exception)))
    }
    return out
}

/** Modbus 异常码的官方含义（调试工具的职责之一：把 01/02/03 直接翻成人话） */
func modbusExceptionText(code: Int64): String {
    match (code) {
        case 1 => return "ILLEGAL FUNCTION（从站不支持该功能码）"
        case 2 => return "ILLEGAL DATA ADDRESS（地址不存在）"
        case 3 => return "ILLEGAL DATA VALUE（参数值非法）"
        case 4 => return "SLAVE DEVICE FAILURE（从站执行出错）"
        case 5 => return "ACKNOWLEDGE（从站已受理，稍后完成）"
        case 6 => return "SLAVE DEVICE BUSY（从站忙）"
        case 8 => return "MEMORY PARITY ERROR"
        case 10 => return "GATEWAY PATH UNAVAILABLE"
        case 11 => return "GATEWAY TARGET FAILED"
        case _ => return "EXCEPTION ${code}"
    }
}

// ---------------------------------------------------------------- 命令实现

/** mb:read —— 按面板定义读一轮 */
class MbReadCommand <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let def = mbParseDef(args, false)
        let r = def.transport().request(def.fc, def.unit, def.addr, def.qty, Array<Int64>(), def.timeoutMs)
        if (r.exception >= 0) {
            eprintln("[mbpoll] read ${def.target()} unit=${def.unit} fc=${def.fc} addr=${def.addr} qty=${def.qty} -> EXCEPTION ${r.exception}")
        } else {
            eprintln("[mbpoll] read ${def.target()} unit=${def.unit} fc=${def.fc} addr=${def.addr} qty=${def.qty} -> ${r.values.size} 值 ${r.elapsedMs}ms")
        }
        return mbResultJson(def, r, "read")
    }
}

/** mb:write —— 写单个/多个线圈或寄存器 */
class MbWriteCommand <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let def = mbParseDef(args, true)
        let r = def.transport().request(def.fc, def.unit, def.addr, def.qty, def.values, def.timeoutMs)
        if (r.exception >= 0) {
            eprintln("[mbpoll] write ${def.target()} unit=${def.unit} fc=${def.fc} addr=${def.addr} -> EXCEPTION ${r.exception}")
        } else {
            eprintln("[mbpoll] write ${def.target()} unit=${def.unit} fc=${def.fc} addr=${def.addr} values=${def.values.size} -> ok ${r.elapsedMs}ms")
        }
        return mbResultJson(def, r, "write")
    }
}

/** mb:trace —— 拉走报文监视缓冲（前端轮询取走即清，不产生额外流量） */
class MbTraceCommand <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let _ = ipc
        let frames = MB_TRACE.drain()
        var arr = ArrayList<JsonValue>()
        for (f in frames) {
            arr.add(JsonString(f))
        }
        let out = JsonObject()
        out.put("frames", JsonArray(arr))
        return out
    }
}

/** 导出目录（相对项目根；工作目录 = 项目根是所有示例的约定） */
let MB_EXPORT_DIR = "logs"
/** 单次导出内容上限：CSV / 点位表 / 报文都远够，防一次坏调用写爆磁盘 */
let MB_EXPORT_MAX_BYTES: Int64 = 8 * 1024 * 1024

/** 导出文件名白名单：字母数字 . _ -（禁 ..，禁路径分隔符），扩展名只收 .csv / .json / .txt */
func mbValidExportName(name: String): Bool {
    if (name.size == 0 || name.size > 96) {
        return false
    }
    if (name.contains("..") || name.contains("/") || name.contains("\\")) {
        return false
    }
    let exts = [".csv", ".json", ".txt"]
    var ok = false
    for (e in exts) {
        if (name.endsWith(e)) {
            ok = true
        }
    }
    if (!ok) {
        return false
    }
    for (b in name.toArray()) {
        let c = Int64(b)
        let okChar = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) ||
            (c >= 0x61 && c <= 0x7A) || c == 0x2E || c == 0x2D || c == 0x5F
        if (!okChar) {
            return false
        }
    }
    return true
}

func mbExportPath(name: String): String {
    return "${MB_EXPORT_DIR}/${name}"
}

/** mb:export —— 把页面生成的 CSV / 点位表 / 报文文本落盘到 logs/（跨机器的交接物都在这） */
class MbExportCommand <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let name = mbArgString(args, "name", "").trimAscii()
        if (!mbValidExportName(name)) {
            throw CommandException("非法的导出文件名：\"${name}\"（只接受字母数字 . _ -，扩展名 .csv/.json/.txt）")
        }
        let content = mbArgString(args, "content", "")
        if (Int64(content.toArray().size) > MB_EXPORT_MAX_BYTES) {
            throw CommandException("导出内容太大（上限 ${MB_EXPORT_MAX_BYTES} 字节）")
        }
        try {
            Directory.create(Path(MB_EXPORT_DIR))
        } catch (e: Exception) {
            // 目录已存在等情况不算失败：能写进去就行
        }
        let path = mbExportPath(name)
        try {
            File.writeTo(path, content.toArray())
        } catch (e: Exception) {
            throw CommandException("写导出文件失败（${path}）：${e}")
        }
        eprintln("[mbpoll] export ${path}（${content.toArray().size} 字节）")
        let out = JsonObject()
        out.put("path", JsonString(path))
        out.put("bytes", JsonInt(Int64(content.toArray().size)))
        return out
    }
}

/** mb:import —— 读回 logs/ 里之前导出的文件（点位表导入 / 记录回看），只读不写 */
class MbImportCommand <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let name = mbArgString(args, "name", "").trimAscii()
        if (!mbValidExportName(name)) {
            throw CommandException("非法的导入文件名：\"${name}\"（只接受字母数字 . _ -，扩展名 .csv/.json/.txt）")
        }
        let path = mbExportPath(name)
        var text = ""
        try {
            text = String.fromUtf8(File.readFrom(path))
        } catch (e: Exception) {
            throw CommandException("读导入文件失败（${path}）：${e}")
        }
        if (Int64(text.toArray().size) > MB_EXPORT_MAX_BYTES) {
            throw CommandException("导入文件太大（上限 ${MB_EXPORT_MAX_BYTES} 字节）")
        }
        eprintln("[mbpoll] import ${path}（${text.toArray().size} 字节）")
        let out = JsonObject()
        out.put("path", JsonString(path))
        out.put("content", JsonString(text))
        return out
    }
}

/** mb:config —— 告诉页面自检环境（内置从站有没有、端口多少） */
class MbConfigCommand <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let _ = args
        let out = JsonObject()
        out.put("slaveEnabled", JsonBool(mbSlaveEnabled()))
        out.put("slavePort", JsonInt(mbSlavePort()))
        // 自检开关：run.bat selfcheck 会设 CJ_MB_SELFCHECK=1，页面见到它才自动跑检查
        var selfCheck = false
        if (let Some(v) <- getVariable("CJ_MB_SELFCHECK")) {
            selfCheck = v == "1" || v == "true"
        }
        out.put("selfCheck", JsonBool(selfCheck))
        out.put("version", JsonString(CJ_TAURI_VERSION))
        // RTU 帧层自检向量：CRC16("123456789") 必须是 0x4B37（标准校验向量）
        var probe = Array<Byte>(9, repeat: 0)
        var pi: Int64 = 0
        while (pi < 9) {
            probe[pi] = UInt8(0x31 + pi)   // '1'..'9'
            pi += 1
        }
        out.put("crcOk", JsonBool(crc16(probe) == 0x4B37))
        return out
    }
}

/** report —— 页面自检结果回投（stderr 即时落盘，是实机取证的凭证） */
class MbReportCommand <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        eprintln("[frontend] " + mbArgString(args, "line", "(空)"))
        return JsonBool(true)
    }
}

/** mb:quit —— 页面请求退出 */
class MbQuitCommand <: CommandHandler {
    let app: TauriApp
    init(app: TauriApp) {
        this.app = app
    }
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        eprintln("[mbpoll] 页面请求退出（window=${ipc.window}）")
        this.app.quit()
        return JsonBool(true)
    }
}
