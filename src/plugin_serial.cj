package cjTauri

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/**
 * 官方插件 serial：串口（对标 Tauri 的 serialport 插件，RFC-001 §7.3）
 *
 * 命令：serial:list / serial:open / serial:read / serial:write / serial:close
 * 权限：**不自动放行**——应用要在 capabilities 里显式声明，两种写法等价：
 *   "commands": ["serial:open", "serial:read", "serial:close"]   // 明文逐条
 *   "permissions": ["serial:readonly"]                           // 命名权限集，一次放行一组
 *
 * 能力落在 C 桥（`cj_bridge_serial_*`，见 native/bridge_core.h）而不是纯仓颉：
 * std / stdx 都没有串口，也没有 termios / ioctl / fcntl 绑定，设备参数只能交给 C。
 * **路径白名单与参数校验在 C 侧 core**（原生层不是可信边界之外 —— 页面能直接 invoke，
 * 仓颉侧的检查只是为了给前端一句可读的人话，真正的边界在 native/ 那边）。
 *
 * 前端：window.__CJ_TAURI__.serial.open({ path: "/dev/ttyUSB0", baud: 115200 })
 */

// serial:list 的候选目录：/dev 顶层 + udev 稳定符号链接目录（不存在就跳过，不是错误）。
// （顶层 let 是全局不可变量；仓颉的 const 只收编译期常量表达式，Array 字面量不合法——实测 2026-10-09）
let SERIAL_LIST_DIRS: Array<String> = ["/dev", "/dev/serial/by-id", "/dev/serial/by-path"]

/** /dev 顶层只收「设备节点类」前缀（与 C 桥白名单同一套设备面，排除 /dev/pts 伪终端） */
let SERIAL_LIST_PREFIXES: Array<String> = [
    "ttyUSB", "ttyACM", "ttyS", "ttyAMA", "ttyPS", "ttyTHS", "ttyXRUSB", "ttyV",
    "tty.", "cu.",
]

/** 枚举本机串口设备节点（serial:list 的实现；拿不到 /dev 就回空数组，不抛）。
 * Windows 优先走 C 桥的 QueryDosDeviceW 枚举（返回的是「COM 名」，页面直接当 path 用，
 * C 桥 open 会自动补 \\.\\ 前缀）；C 桥返回 -4（未实现）或异常时回落到 /dev 目录扫描——
 * 后者在 Windows 下天然为空，不算错误。 */
func serialPortList(): ArrayList<String> {
    let viaC = serialListC()
    if (let Some(list) <- viaC) {
        return list
    }
    let found = ArrayList<String>()
    for (dir in SERIAL_LIST_DIRS) {
        if (!exists(dir)) {
            continue
        }
        var entries: Array<FileInfo>
        try {
            entries = Directory.readFrom(dir)
        } catch (e: Exception) {
            continue
        }
        // by-id / by-path 里全是串口设备（udev 链接名不含 ttyUSB 这类前缀），整目录收录
        let scanAll = dir != "/dev"
        for (info in entries) {
            if (info.isDirectory()) {
                continue
            }
            let name = info.path.toString()
            if (scanAll) {
                found.add(name)
                continue
            }
            for (p in SERIAL_LIST_PREFIXES) {
                if (name.contains(p)) {
                    found.add(name)
                    break
                }
            }
        }
    }
    found.sort()
    return found
}
public class SerialPlugin <: Plugin {
    public init() {}

    public func name(): String {
        return "serial"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        m.add("list", SerialCommands())
        m.add("open", SerialCommands())
        m.add("read", SerialCommands())
        m.add("write", SerialCommands())
        m.add("close", SerialCommands())
        return m
    }

    /**
     * 命名权限集：readonly 只含「列出 + 打开 + 读 + 关」——只想读设备的应用引用它即可，
     * **写能力不会被顺带打开**；要写就必须显式引用 default 或把 serial:write 写成明文。
     * list 归入 readonly：枚举端口是只读操作，且连接前的「选端口」离不开它。
     */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let ro = ArrayList<String>()
        ro.add("list")
        ro.add("open")
        ro.add("read")
        ro.add("close")
        m.add("readonly", ro)
        let all = ArrayList<String>()
        all.add("list")
        all.add("open")
        all.add("read")
        all.add("write")
        all.add("close")
        m.add("default", all)
        return m
    }

    /**
     * 前端 shim：只往 __CJ_TAURI__ 挂一个 serial 命名空间，不动 invoke / listen / emit
     */
    public func jsShim(): String {
        return "(function () { var t = window.__CJ_TAURI__ || (window.__CJ_TAURI__ = {});" +
            " t.serial = {" +
            " list: function () { return window.__CJ_TAURI__.invoke('serial:list', {}); }," +
            " open: function (args) { return window.__CJ_TAURI__.invoke('serial:open', args); }," +
            " read: function (args) { return window.__CJ_TAURI__.invoke('serial:read', args); }," +
            " write: function (args) { return window.__CJ_TAURI__.invoke('serial:write', args); }," +
            " close: function (args) { return window.__CJ_TAURI__.invoke('serial:close', args); }" +
            " }; })();\n"
    }
}

/* ===== 可与 C 侧对齐的纯函数（无副作用，便于单测）===== */

/**
 * 支持的波特率档位：与 native/bridge_linux.c 的 serial_speed_of 一字不差地对齐——
 * 档位在那边是「有宏才收」，这里提前给前端一句可读原因，而不是让 C 返回一个数字码。
 */
let SERIAL_BAUDS: Array<Int32> = [300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200,
    230400, 460800, 500000, 921600, 1000000]

/**
 * 设备路径前缀白名单：与 native/bridge_core.c 的 CJ_SERIAL_PREFIXES 对齐
 */
let SERIAL_PATH_PREFIXES: Array<String> = ["/dev/ttyUSB", "/dev/ttyACM", "/dev/ttyS", "/dev/ttyAMA",
    "/dev/ttyPS", "/dev/ttyTHS", "/dev/ttyXRUSB", "/dev/ttyV", "/dev/tty.", "/dev/cu.",
    "/dev/serial/by-id/", "/dev/serial/by-path/", "/dev/pts/", "COM", "\\\\.\\COM"]

let SERIAL_HEX_DIGITS: String = "0123456789abcdef"

public func serialBaudSupported(baud: Int32): Bool {
    for (b in SERIAL_BAUDS) {
        if (b == baud) {
            return true
        }
    }
    return false
}

/** 支持档位的一句话列表（报错信息里用；从 SERIAL_BAUDS 现拼，避免两处维护） */
public func serialBaudListText(): String {
    var s = ""
    var i = 0
    while (i < SERIAL_BAUDS.size) {
        if (i > 0) {
            s = s + "/"
        }
        s = s + SERIAL_BAUDS[i].toString()
        i++
    }
    return s
}

/** 校验位文案 → 数值（0=无 1=奇 2=偶）；无法识别返回 -1，由调用方报错 */
public func serialParityCode(text: String): Int32 {
    let t = serialAsciiLower(text)
    if (t == "none" || t == "n") {
        return 0
    }
    if (t == "odd" || t == "o") {
        return 1
    }
    if (t == "even" || t == "e") {
        return 2
    }
    return -1
}

/**
 * 设备路径白名单的**仓颉侧镜像**：只为给前端一句可读提示，**不是安全边界**
 * （边界在 C 侧 core：JS 绕过这个函数直接 invoke 也一样会被拒）。
 * 与 C 侧同样两条硬规则：不得含 ".."、前缀本身不算设备名；COM 名要求前缀后是 1..3 位数字。
 * 路径按字节比较——串口设备名是 ASCII，非 ASCII 路径本就到不了这里。
 */
public func serialPathLooksAllowed(path: String): Bool {
    let bytes = path.toArray()
    if (bytes.size == 0 || bytes.size > 255) {
        return false
    }
    if (path.contains("..")) {
        return false
    }
    for (p in SERIAL_PATH_PREFIXES) {
        let pb = p.toArray()
        if (bytes.size <= pb.size) {
            continue
        }
        var same = true
        var i = 0
        while (i < pb.size) {
            if (bytes[i] != pb[i]) {
                same = false
                break
            }
            i++
        }
        if (!same) {
            continue
        }
        if (p != "COM" && p != "\\\\.\\COM") {
            return true
        }
        if (bytes.size - pb.size > 3) {
            return false
        }
        var j = pb.size
        while (j < bytes.size) {
            let c = bytes[j]
            if (c < 48 || c > 57) {
                return false
            }
            j++
        }
        return true
    }
    return false
}

/** 字节 → 小写十六进制（二进制帧给前端看的就是它） */
public func serialBytesToHex(bytes: Array<UInt8>): String {
    let digits = SERIAL_HEX_DIGITS.toArray()
    let out = Array<UInt8>(bytes.size * 2, repeat: 0)
    var i = 0
    while (i < bytes.size) {
        let b = bytes[i]
        out[i * 2] = digits[Int64((b >> 4) & UInt8(0x0F))]
        out[i * 2 + 1] = digits[Int64(b & UInt8(0x0F))]
        i++
    }
    return String.fromUtf8(out)
}

/** 十六进制 → 字节；奇数长度或含非十六进制字符返回 None（调用方报可读错误） */
public func serialHexToBytes(text: String): Option<Array<UInt8>> {
    let src = text.toArray()
    if (src.size % 2 != 0) {
        return None
    }
    let out = Array<UInt8>(src.size / 2, repeat: 0)
    var i = 0
    while (i < out.size) {
        let hi = serialHexDigit(src[i * 2])
        let lo = serialHexDigit(src[i * 2 + 1])
        if (hi < 0 || lo < 0) {
            return None
        }
        out[i] = UInt8(hi * 16 + lo)
        i++
    }
    return Some(out)
}

/** 字节 → 文本（无 BOM 假设）：不是合法 UTF-8 就返回 None，调用方保留 hex 即可 */
public func serialBytesToText(bytes: Array<UInt8>): Option<String> {
    try {
        return Some(String.fromUtf8(bytes))
    } catch (e: Exception) {
        return None
    }
}

/** ASCII 小写（不引 toAsciiLower：只处理选项文案，自己转就够，行为一目了然） */
func serialAsciiLower(s: String): String {
    let bytes = s.toArray()
    let out = Array<UInt8>(bytes.size, repeat: 0)
    var i = 0
    while (i < bytes.size) {
        let b = bytes[i]
        if (b >= UInt8(65) && b <= UInt8(90)) {
            out[i] = b + UInt8(32)
        } else {
            out[i] = b
        }
        i++
    }
    return String.fromUtf8(out)
}

private func serialHexDigit(b: UInt8): Int64 {
    if (b >= UInt8(48) && b <= UInt8(57)) {
        return Int64(b - UInt8(48))
    }
    if (b >= UInt8(97) && b <= UInt8(102)) {
        return Int64(b - UInt8(87))
    }
    if (b >= UInt8(65) && b <= UInt8(70)) {
        return Int64(b - UInt8(55))
    }
    return -1
}

/**
 * serial 插件的命令处理器（四个命令共用一份，按全名分派，与内置 SystemCommands 同形）
 */
class SerialCommands <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "serial:list" => this.listCmd()
            case "serial:open" => this.openCmd(args)
            case "serial:read" => this.readCmd(args)
            case "serial:write" => this.writeCmd(args)
            case "serial:close" => this.closeCmd(args)
            case _ => throw CommandException("unknown serial command: ${cmd}")
        }
    }

    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => throw CommandException("serial: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("serial: missing argument \"${key}\"")
        }
    }

    private func optionalString(args: JsonObject, key: String, fallback: String): String {
        match (args.get(key)) {
            case Some(_) => return this.requireString(args, key)
            case None => return fallback
        }
    }

    private func optionalInt(args: JsonObject, key: String, fallback: Int64): Int64 {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case _ => throw CommandException("serial: argument \"${key}\" must be an integer")
            }
            case None => return fallback
        }
    }

    /** 句柄必须由 serial:open 给出（>0）；拿别的数字来只会得到一句可读拒绝 */
    private func requireHandle(args: JsonObject): Int64 {
        match (args.get("handle")) {
            case Some(_) => ()
            case None => throw CommandException("serial: missing argument \"handle\"")
        }
        let h = this.optionalInt(args, "handle", 0)
        if (h <= 0) {
            throw CommandException("serial: argument \"handle\" must be a handle returned by serial:open")
        }
        return h
    }

    private func clamp(v: Int64, lo: Int64, hi: Int64): Int64 {
        if (v < lo) {
            return lo
        }
        if (v > hi) {
            return hi
        }
        return v
    }

    /**
     * 枚举本机串口：页面拿它填「端口」下拉（连接前就要用，故归 readonly 集）。
     * 返回 { ports: ["…"] }——没有设备就给空数组，页面据此显示「未发现端口」。
     */
    private func listCmd(): JsonValue {
        let out = JsonObject()
        let ports = ArrayList<JsonValue>()
        for (p in serialPortList()) {
            ports.add(JsonString(p))
        }
        out.put("ports", JsonArray(ports))
        return out
    }

    private func openCmd(args: JsonObject): JsonValue {
        let path = this.requireString(args, "path")
        if (!serialPathLooksAllowed(path)) {
            throw CommandException("serial:open refused: \"${path}\" 不在允许的设备名单内" +
                "（只收串口设备节点 / 伪终端，且不得含 ..；最终以 C 桥白名单为准）")
        }
        let baud = this.optionalInt(args, "baud", 115200)
        if (baud <= 0 || baud > 4000000) {
            throw CommandException("serial:open refused: baud 超出范围（1..4000000，拿到 ${baud}）")
        }
        let baud32 = Int32(baud)
        if (!serialBaudSupported(baud32)) {
            throw CommandException("serial:open refused: 不支持的波特率 ${baud}" +
                "（可选档位：${serialBaudListText()}）")
        }
        let dataBits = Int32(this.optionalInt(args, "dataBits", 8))
        if (dataBits < 5 || dataBits > 8) {
            throw CommandException("serial:open refused: dataBits 只收 5..8（拿到 ${dataBits}）")
        }
        let parity = serialParityCode(this.optionalString(args, "parity", "none"))
        if (parity < 0) {
            throw CommandException("serial:open refused: parity 只认 none|odd|even（拿到 " +
                this.optionalString(args, "parity", "none") + "）")
        }
        let stopBits = Int32(this.optionalInt(args, "stopBits", 1))
        if (stopBits != 1 && stopBits != 2) {
            throw CommandException("serial:open refused: stopBits 只收 1|2（拿到 ${stopBits}）")
        }

        let h = serialOpen(path, baud32, dataBits, parity, stopBits)
        if (h <= 0) {
            throw CommandException("serial:open failed (code ${h}): ${serialLastError()}")
        }
        let out = JsonObject()
        out.put("handle", JsonInt(h))
        out.put("path", JsonString(path))
        out.put("baud", JsonInt(Int64(baud32)))
        out.put("dataBits", JsonInt(Int64(dataBits)))
        out.put("parity", JsonInt(Int64(parity)))
        out.put("stopBits", JsonInt(Int64(stopBits)))
        return out
    }

    private func readCmd(args: JsonObject): JsonValue {
        let h = this.requireHandle(args)
        let maxBytes = this.clamp(this.optionalInt(args, "maxBytes", 256), 1, 4096)
        let timeoutMs = this.clamp(this.optionalInt(args, "timeoutMs", 200), 0, 60000)

        let bytes = serialRead(h, Int32(maxBytes), Int32(timeoutMs))
        let out = JsonObject()
        // 超时没数据不是错误：前端按 count == 0 判断即可，不必拿 rejected 当「空」
        out.put("count", JsonInt(Int64(bytes.size)))
        out.put("hex", JsonString(serialBytesToHex(bytes)))
        match (serialBytesToText(bytes)) {
            case Some(t) => out.put("text", JsonString(t))
            // 二进制帧：给 hex 就够，不硬塞一个坏字符串
            case None => ()
        }
        return out
    }

    private func writeCmd(args: JsonObject): JsonValue {
        let h = this.requireHandle(args)
        let payload = this.requireString(args, "data")
        let encoding = serialAsciiLower(this.optionalString(args, "encoding", "utf8"))
        var bytes = payload.toArray()
        if (encoding == "hex") {
            match (serialHexToBytes(payload)) {
                case Some(b) => bytes = b
                case None => throw CommandException("serial:write refused: data 不是合法十六进制串" +
                    "（应偶数长度、只含 0-9a-f）")
            }
        } else if (encoding != "utf8" && encoding != "text") {
            throw CommandException("serial:write refused: encoding 只认 \"utf8\" 或 \"hex\"")
        }
        if (bytes.size > 4096) {
            throw CommandException("serial:write refused: 单次最多 4096 字节（拿到 ${bytes.size}）")
        }
        let timeoutMs = this.clamp(this.optionalInt(args, "timeoutMs", 1000), 0, 60000)
        let written = serialWrite(h, bytes, Int32(timeoutMs))
        if (written < 0) {
            throw CommandException("serial:write failed (code ${written}): ${serialLastError()}")
        }
        let out = JsonObject()
        out.put("written", JsonInt(Int64(written)))
        out.put("bytes", JsonInt(Int64(bytes.size)))
        return out
    }

    private func closeCmd(args: JsonObject): JsonValue {
        let h = this.requireHandle(args)
        let rc = serialClose(h)
        if (rc != 0) {
            throw CommandException("serial:close failed (code ${rc}): ${serialLastError()}")
        }
        return JsonBool(true)
    }
}
