package cjTauri.plugins.serial

/**
 * ohos 侧 serial 真实现（批次 4，issue #5）：NDK FFI 直连 musl libc 的 POSIX 串口面。
 * 前身是 P-1 桩（serial_ohos_stub.cj，已删）；写法照剪贴板那次的「NDK FFI 直连」模式
 * （`src/clipboard_bridge.cj`），不经 C 桥、不加能力位。
 *
 * 为什么不引 serialport 式的现成库：std / stdx 都没有串口与 termios 绑定；同类项目 sscom
 * 实测 serialport 依赖 nix/libudev 在 OHOS target 编不过，只能手写 POSIX——本文件同理，
 * termios 结构体按 musl（aarch64 linux）布局手工按字节偏移读写，不依赖 @C 结构体映射。
 *
 * 边界与桌面两端的差异（对齐 RFC §4.6.4 P-2 的口径）：
 * - 桌面侧「真正的白名单在 C 桥 core」；ohos 没有 C 桥，本文件**就是**安全边界，
 *   open 前必须再过一次 `serialPathLooksAllowed`（仓颉侧镜像，plugin_serial.cj）——
 *   页面可控字符串绝不能只靠上层命令层的校验。
 * - 错误明细是包级共享槽（仓颉没有线程局部），Mutex 守着；并发失败时可能被覆盖，
 *   代价只是错误文案不准，与桌面「线程局部」的语义差异如实记在这里。
 * - 读超时用 poll（有数据才 read，与桌面 Linux 桥同口径）；写按预算轮转。
 * - 设备节点访问在真机上可能要 DDK/USB 权限甚至系统签名（sscom 同款风险），装不上 /
 *   打不开时本实现如实报错，不伪装成功。
 */

@When[env == "ohos"]
import std.collection.*

// std.sync 只被 ohos 门禁代码用（Mutex 状态槽），import 随之门禁——桌面侧整段摘除
@When[env == "ohos"]
import std.sync.*

@When[env == "ohos"]
import std.time.*

@When[env == "ohos"]
import std.fs.*

@When[env == "ohos"]
import std.sort.*

// ---- musl libc 的 POSIX 串口面（@C foreign 直连；符号都在 libc，无需 [links] 追加） ----

/** open 只按双参声明：aarch64（AAPCS64）上可变参与固定参的整型传参相同， musl 的 open 直接可用 */
@When[env == "ohos"]
@C
foreign func open(path: CString, flags: Int32): Int32

@When[env == "ohos"]
@C
foreign func close(fd: Int32): Int32

@When[env == "ohos"]
@C
foreign func read(fd: Int32, buf: CPointer<UInt8>, count: UInt64): Int64

@When[env == "ohos"]
@C
foreign func write(fd: Int32, buf: CPointer<UInt8>, count: UInt64): Int64

/** termios 按 64 字节裸缓冲传递（musl aarch64 布局，实际 60 字节） */
@When[env == "ohos"]
@C
foreign func tcgetattr(fd: Int32, termios: CPointer<UInt8>): Int32

@When[env == "ohos"]
@C
foreign func tcsetattr(fd: Int32, actions: Int32, termios: CPointer<UInt8>): Int32

@When[env == "ohos"]
@C
foreign func cfsetispeed(termios: CPointer<UInt8>, speed: UInt32): Int32

@When[env == "ohos"]
@C
foreign func cfsetospeed(termios: CPointer<UInt8>, speed: UInt32): Int32

/** pollfd 按 8 字节裸缓冲：fd(Int32) | events(Int16) | revents(Int16) */
@When[env == "ohos"]
@C
foreign func poll(fds: CPointer<UInt8>, nfds: UInt64, timeout: Int32): Int32

/** errno 与 strerror：给 serialLastError 一句人话（strerror 返回静态串，不释放） */
@When[env == "ohos"]
@C
foreign func __errno_location(): CPointer<Int32>

@When[env == "ohos"]
@C
foreign func strerror(errnum: Int32): CString

// ---- Linux/asm-generic 常量（与 sscom 的取值一字不差） ----

// open flags
const OHOS_O_RDWR: Int32 = 0x2
const OHOS_O_NOCTTY: Int32 = 0x100

// tcsetattr actions：TCSANOW
const OHOS_TCSANOW: Int32 = 0

// cflag 位
const OHOS_CSIZE: UInt32 = 0x30
const OHOS_CS8: UInt32 = 0x30
const OHOS_CSTOPB: UInt32 = 0x40
const OHOS_CREAD: UInt32 = 0x80
const OHOS_PARENB: UInt32 = 0x100
const OHOS_PARODD: UInt32 = 0x200
const OHOS_CLOCAL: UInt32 = 0x800

// iflag 原始位（cfmakeraw 要清的）：IGNBRK|BRKINT|PARMRK|ISTRIP|INLCR|IGNCR|ICRNL|IXON
const OHOS_IFLAG_RAW: UInt32 = 0x5eb

// lflag 原始位：ECHO|ICANON|ISIG|IEXTEN
const OHOS_LFLAG_RAW: UInt32 = 0x800b

// poll 事件
const OHOS_POLLIN: Int16 = 0x1
const OHOS_POLLOUT: Int16 = 0x4
// errno：EAGAIN
const OHOS_EAGAIN: Int32 = 11

/** termios 结构体里 speed 字段的字节偏移（musl aarch64：c_ispeed@52 / c_ospeed@56） */
const OHOS_TERMIOS_ISPEED: Int64 = 52
const OHOS_TERMIOS_OSPEED: Int64 = 56

/** c_cc 里 VTIME / VMIN 的下标（Linux 布局）；poll+read 模式下两个都置 0 */
const OHOS_VTIME: Int64 = 5
const OHOS_VMIN: Int64 = 6

/** 波特率 → termios 速度常量（asm-generic：B38400 以下连续，往上 0x1000+n）；
 * 档位与 plugin_serial.cj 的 SERIAL_BAUDS 对齐（那层已拦过一次，这里兜底）。
 * public：单测要直接构造（跨包可见性，AGENTS §2） */
public func serialOhosBaudConst(baud: Int32): Option<UInt32> {
    let low: Option<UInt32> = match (baud) {
        case 300 => Some(0x7)
        case 600 => Some(0x8)
        case 1200 => Some(0x9)
        case 2400 => Some(0xb)
        case 4800 => Some(0xc)
        case 9600 => Some(0xd)
        case 19200 => Some(0xe)
        case 38400 => Some(0xf)
        case _ => None
    }
    if (let Some(v) <- low) {
        return low
    }
    match (baud) {
        case 57600 => Some(0x1001)
        case 115200 => Some(0x1002)
        case 230400 => Some(0x1003)
        case 460800 => Some(0x1004)
        case 500000 => Some(0x1005)
        case 921600 => Some(0x1006)
        case 1000000 => Some(0x1008)
        case _ => None
    }
}

// ---- 错误明细（包级共享槽，Mutex 守护；见文件头与桌面线程局部语义的差异说明） ----
// 引用 ohos 专属 foreign（strerror / __errno_location / poll）的辅助一律带门禁，
// 否则桌面构建在链接期找不到符号（AGENTS §4：跨平台文件别按单平台的 warning 清 import）

@When[env == "ohos"]
let OHOS_SERIAL_ERR_MUTEX = Mutex()

@When[env == "ohos"]
var ohosSerialLastError = ""

@When[env == "ohos"]
func serialOhosSetError(msg: String): Unit {
    OHOS_SERIAL_ERR_MUTEX.lock()
    ohosSerialLastError = msg
    OHOS_SERIAL_ERR_MUTEX.unlock()
}

@When[env == "ohos"]
func serialOhosErrno(): Int32 {
    unsafe {
        let p = __errno_location()
        if (p.isNull()) {
            return 0
        }
        return p.read(0)
    }
}

/** 最近一次 errno 的人话（strerror 返回静态串，不释放）；调用处无需 unsafe */
@When[env == "ohos"]
func serialOhosErrnoText(): String {
    unsafe {
        return strerror(serialOhosErrno()).toString()
    }
}

// ---- termios 裸缓冲的读写辅助（aarch64 是小端；public 供单测直接构造，AGENTS §2） ----

public func serialOhosGetU32(t: CPointer<UInt8>, off: Int64): UInt32 {
    unsafe {
        let b0 = UInt32(t.read(off))
        let b1 = UInt32(t.read(off + 1)) << 8
        let b2 = UInt32(t.read(off + 2)) << 16
        let b3 = UInt32(t.read(off + 3)) << 24
        return b0 | b1 | b2 | b3
    }
}

public func serialOhosPutU32(t: CPointer<UInt8>, off: Int64, v: UInt32): Unit {
    unsafe {
        t.write(off, UInt8(v & 0xff))
        t.write(off + 1, UInt8((v >> 8) & 0xff))
        t.write(off + 2, UInt8((v >> 16) & 0xff))
        t.write(off + 3, UInt8((v >> 24) & 0xff))
    }
}

/** poll 单 fd 单事件：>0 就绪，0 超时，<0 出错（errno 已置） */
@When[env == "ohos"]
func serialOhosPollOne(fd: Int32, events: Int16, timeoutMs: Int32): Int32 {
    let pfd = LibC.malloc<UInt8>(count: 8)
    unsafe {
        // fd 低 4 字节小端写入；events 高位偏移 4；revents（偏移 6）由内核填，预清零
        pfd.write(0, UInt8(Int32(fd) & 0xff))
        pfd.write(1, UInt8((fd >> 8) & 0xff))
        pfd.write(2, UInt8((fd >> 16) & 0xff))
        pfd.write(3, UInt8((fd >> 24) & 0xff))
        pfd.write(4, UInt8(UInt16(events) & 0xff))
        pfd.write(5, UInt8((UInt16(events) >> 8) & 0xff))
        pfd.write(6, UInt8(0))
        pfd.write(7, UInt8(0))
    }
    var r: Int32 = 0
    unsafe {
        r = poll(pfd, 1, timeoutMs)
    }
    unsafe {
        LibC.free(pfd)
    }
    return r
}

/**
 * 打开并配置串口：成功返回 >0 句柄（fd+1，保证恒 >0），失败负码：
 * -1 参数 / 白名单、-3 open 或 termios 配置失败（明细在 serialLastError()）。
 * 线程安全：fd 由调用方独占使用；重复 open 同一路径是两次独立连接（与桌面同形）。
 */
@When[env == "ohos"]
public func serialOpen(path: String, baud: Int32, dataBits: Int32, parity: Int32,
                       stopBits: Int32): Int64 {
    // ohos 没有桌面 C 桥那层白名单，本函数就是边界：页面可控路径必须在这里再拦一次
    if (!serialPathLooksAllowed(path)) {
        serialOhosSetError("path \"${path}\" 不在允许的设备名单内（serialPathLooksAllowed）")
        return -1
    }
    if (serialOhosBaudConst(baud).isNone()) {
        serialOhosSetError("不支持的波特率 ${baud}")
        return -1
    }
    if (dataBits < 5 || dataBits > 8) {
        serialOhosSetError("dataBits 只收 5..8（拿到 ${dataBits}）")
        return -1
    }
    if (parity < 0 || parity > 2) {
        serialOhosSetError("parity 只收 0|1|2（拿到 ${parity}）")
        return -1
    }
    if (stopBits != 1 && stopBits != 2) {
        serialOhosSetError("stopBits 只收 1|2（拿到 ${stopBits}）")
        return -1
    }

    var fd: Int32 = 0
    unsafe {
        let cpath = LibC.mallocCString(path)
        fd = open(cpath, OHOS_O_RDWR | OHOS_O_NOCTTY)
        LibC.free(cpath)
    }
    if (fd < 0) {
        serialOhosSetError("open failed: ${serialOhosErrnoText()}（真机上设备节点可能要 DDK 权限 / 系统签名）")
        return -3
    }

    let t = LibC.malloc<UInt8>(count: 64)
    unsafe {
        for (i in 0..64) {
            t.write(i, 0)
        }
    }
    var rc: Int32 = 0
    unsafe {
        rc = tcgetattr(fd, t)
    }
    if (rc != 0) {
        serialOhosSetError("tcgetattr failed: ${serialOhosErrnoText()}")
        unsafe {
            close(fd)
            LibC.free(t)
        }
        return -3
    }

    // cfmakeraw 等价：清 iflag/lflag 原始位，oflag/lflag 归零，cflag 重设数据位/校验/停止位
    // （取反用「异或全 1 掩码」：仓颉没有 ~ 运算符，2026-10-24 编译实测）
    let iflag = serialOhosGetU32(t, 0) & (OHOS_IFLAG_RAW ^ 0xFFFF_FFFF)
    serialOhosPutU32(t, 0, iflag)
    serialOhosPutU32(t, 4, 0)
    var cflag = serialOhosGetU32(t, 8) & ((OHOS_CSIZE | OHOS_PARENB | OHOS_PARODD | OHOS_CSTOPB) ^ 0xFFFF_FFFF)
    cflag |= OHOS_CREAD | OHOS_CLOCAL
    // dataBits：CS5..CS8 = 0x00/0x10/0x20/0x30
    cflag |= UInt32(dataBits - 5) << 4
    if (parity == 1) {
        cflag |= OHOS_PARODD | OHOS_PARENB
    } else if (parity == 2) {
        cflag |= OHOS_PARENB
    }
    if (stopBits == 2) {
        cflag |= OHOS_CSTOPB
    }
    serialOhosPutU32(t, 8, cflag)
    // lflag 清原始位（c_line@16 与 c_cc 其余位保留，buffer 已按 tcgetattr 的返回初始化）
    serialOhosPutU32(t, 12, serialOhosGetU32(t, 12) & (OHOS_LFLAG_RAW ^ 0xFFFF_FFFF))
    // VTIME / VMIN 置 0：read 不自带阻塞预算，超时由 poll 负责（与桌面 Linux 桥同口径）
    unsafe {
        t.write(17 + OHOS_VTIME, UInt8(0))
        t.write(17 + OHOS_VMIN, UInt8(0))
    }

    match (serialOhosBaudConst(baud)) {
        case Some(speed) =>
            unsafe {
                cfsetispeed(t, speed)
                cfsetospeed(t, speed)
            }
        case None => () // 上面已拦，不可能走到
    }
    unsafe {
        rc = tcsetattr(fd, OHOS_TCSANOW, t)
    }
    if (rc != 0) {
        serialOhosSetError("tcsetattr failed: ${serialOhosErrnoText()}")
        unsafe {
            close(fd)
            LibC.free(t)
        }
        return -3
    }
    unsafe {
        LibC.free(t)
    }
    return Int64(fd) + 1
}

/** 最近一次失败的明细（包级共享槽；见文件头与桌面线程局部语义的差异说明） */
@When[env == "ohos"]
public func serialLastError(): String {
    OHOS_SERIAL_ERR_MUTEX.lock()
    let msg = ohosSerialLastError
    OHOS_SERIAL_ERR_MUTEX.unlock()
    return msg
}

/** ohos 不走桌面 C 桥的枚举（返回 None，list 命令走下面的 serialPortList 目录扫描） */
@When[env == "ohos"]
public func serialListC(): Option<ArrayList<String>> {
    return None
}

/**
 * 读：最多 maxBytes 字节、最多等 timeoutMs 毫秒（0 = 立即返回）。
 * 返回实际读到的字节（空数组 = 超时无数据）。poll 有数据才 read 一次——
 * 与桌面 Linux 桥「poll + read」同口径，不会在没数据时白等。
 */
@When[env == "ohos"]
public func serialRead(h: Int64, maxBytes: Int32, timeoutMs: Int32): Array<UInt8> {
    let fd = Int32(h - 1)
    let ready = serialOhosPollOne(fd, OHOS_POLLIN, timeoutMs)
    if (ready <= 0) {
        if (ready < 0) {
            serialOhosSetError("poll failed: ${serialOhosErrnoText()}")
        }
        return Array<UInt8>(0, repeat: 0)
    }
    let cap = Int64(maxBytes)
    let buf = LibC.malloc<UInt8>(count: cap)
    var n: Int64 = 0
    unsafe {
        n = read(fd, buf, UInt64(cap))
    }
    var out = Array<UInt8>(0, repeat: 0)
    if (n > 0) {
        out = Array<UInt8>(n, repeat: 0)
        unsafe {
            for (i in 0..n) {
                out[i] = buf.read(i)
            }
        }
    } else if (n < 0) {
        serialOhosSetError("read failed: ${serialOhosErrnoText()}")
    }
    unsafe {
        LibC.free(buf)
    }
    return out
}

/**
 * 写：在 timeoutMs 预算内尽量写完，返回实际写入字节数（可能 < data.size；负码 = 失败）。
 * EAGAIN 时 poll(POLLOUT) 等剩余预算，与桌面「预算内尽量写完」的口径一致。
 */
@When[env == "ohos"]
public func serialWrite(h: Int64, data: Array<UInt8>, timeoutMs: Int32): Int32 {
    if (data.size == 0) {
        return 0
    }
    let fd = Int32(h - 1)
    let n = data.size
    let buf = LibC.malloc<UInt8>(count: Int64(n))
    unsafe {
        for (i in 0..n) {
            buf.write(i, data[i])
        }
    }
    let deadline = MonoTime.now() + Duration.millisecond * Int64(timeoutMs)
    var total: Int64 = 0
    while (total < n) {
        var w: Int64 = 0
        unsafe {
            w = write(fd, buf + total, UInt64(n - total))
        }
        if (w > 0) {
            total += w
            continue
        }
        if (w < 0 && serialOhosErrno() != OHOS_EAGAIN) {
            serialOhosSetError("write failed: ${serialOhosErrnoText()}")
            unsafe {
                LibC.free(buf)
            }
            return -1
        }
        let remainMs = (deadline - MonoTime.now()).toMilliseconds()
        if (remainMs <= 0) {
            break
        }
        let pr = serialOhosPollOne(fd, OHOS_POLLOUT, Int32(remainMs))
        if (pr < 0) {
            serialOhosSetError("poll failed: ${serialOhosErrnoText()}")
            unsafe {
                LibC.free(buf)
            }
            return -1
        }
    }
    unsafe {
        LibC.free(buf)
    }
    return Int32(total)
}

/** 关闭：0 = 成功；fd 已关（EBADF）按桌面口径返回 -4（幂等拒绝重复关） */
@When[env == "ohos"]
public func serialClose(h: Int64): Int32 {
    let fd = Int32(h - 1)
    let rc = unsafe {
        close(fd)
    }
    if (rc == 0) {
        return 0
    }
    serialOhosSetError("close failed: ${serialOhosErrnoText()}")
    return -4
}

/**
 * 枚举本机串口（ohos 版）：扫 /dev 顶层 + /dev/bus（鸿蒙特有的 USB 串口落点，sscom 同款），
 * 按前缀过滤。拿不到目录就跳过；没有设备回空数组——空数组在页面侧语义就是「未发现端口」。
 */
@When[env == "ohos"]
public func serialPortList(): ArrayList<String> {
    let prefixes = ["ttyUSB", "ttyACM", "ttyS", "ttyAMA", "ttyGS", "ttySC", "ttyPS", "ttyTHS", "tty.", "cu."]
    let found = ArrayList<String>()
    for (dir in ["/dev", "/dev/bus"]) {
        if (!exists(dir)) {
            continue
        }
        var entries: Array<FileInfo>
        try {
            entries = Directory.readFrom(dir)
        } catch (e: Exception) {
            continue
        }
        for (info in entries) {
            if (info.isDirectory()) {
                continue
            }
            let name = info.path.toString()
            for (p in prefixes) {
                if (name.contains(p)) {
                    found.add(name)
                    break
                }
            }
        }
    }
    sort(found)
    return found
}
