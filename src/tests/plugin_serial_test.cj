package cjTauri.tests

import cjTauri.*
import std.collection.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * serial 插件单元测试：纯函数（档位 / 校验位文案 / 路径白名单 / hex / 文本）+ 命令面参数校验
 * + 命名权限集的闸门。
 *
 * 为什么这里不测真的读写：设备 I/O 在 C 桥里（native/bridge_linux.c 的 termios 层），
 * 需要真实设备节点或伪终端 —— 归实机验证（examples/plugin-serial + socat 造的虚拟串口对）。
 * 这里只锁「不碰设备就能判定的部分」，且这几条正是页面最容易踩错的入口。
 */

/** 造带路径的 open 参数 */
func serialOpenArgs(path: String): JsonObject {
    var o = JsonObject()
    o.put("path", JsonString(path))
    return o
}

/** 取一条命令处理器 */
func serialCmd(short: String): CommandHandler {
    return SerialPlugin().commands().get(short).getOrThrow()
}

/** 直接调命令，把 CommandException 的原文取出来（没抛就返回空串）*/
func serialErrOf(short: String, args: JsonObject): String {
    try {
        serialCmd(short).handle("serial:${short}", args, IpcContext("main", IpcHub()))
        return ""
    } catch (e: CommandException) {
        return e.message
    }
}

@Test
func testSerialPluginSurface(): Unit {
    let p = SerialPlugin()
    @Expect(p.name(), "serial")
    let names = pluginCommandNames(p)
    @Expect(names.size, 4)
    var found = 0
    for (n in names) {
        if (n == "serial:open" || n == "serial:read" || n == "serial:write" || n == "serial:close") {
            found++
        }
    }
    @Expect(found, 4)
}

@Test
func testSerialPluginShimTargetsItsOwnNamespace(): Unit {
    let js = SerialPlugin().jsShim()
    @Expect(js.contains("t.serial"), true)
    @Expect(js.contains("'serial:open'"), true)
    @Expect(js.contains("'serial:write'"), true)
    // shim 只挂自己的命名空间：不该动 invoke / listen / emit
    @Expect(js.contains("invoke('serial:"), true)
}

@Test
func testSerialPermissionSetsGateWrite(): Unit {
    let sets = pluginPermissionSets(SerialPlugin())
    @Expect(sets.size, 2)
    let ro = sets.get("serial:readonly").getOrThrow()
    @Expect(ro.size, 3)
    var roHasWrite = false
    for (m in ro) {
        if (m == "serial:write") {
            roHasWrite = true
        }
    }
    // 只想读设备的应用不该顺带拿到写能力
    @Expect(roHasWrite, false)
    @Expect(sets.get("serial:default").getOrThrow().size, 4)
}

@Test
func testSerialBaudTableMatchesBridge(): Unit {
    @Expect(serialBaudSupported(9600), true)
    @Expect(serialBaudSupported(115200), true)
    @Expect(serialBaudSupported(1000000), true)
    // 档位之外一律不收（C 侧 termios 也没有对应宏，收了只会变成运行期报错）
    @Expect(serialBaudSupported(12345), false)
    @Expect(serialBaudSupported(0), false)
    @Expect(serialBaudSupported(-1), false)
    let text = serialBaudListText()
    @Expect(text.contains("115200"), true)
    @Expect(text.startsWith("300/"), true)
    @Expect(text.endsWith("1000000"), true)
}

@Test
func testSerialParityTextMapping(): Unit {
    @Expect(serialParityCode("none"), 0)
    @Expect(serialParityCode("n"), 0)
    @Expect(serialParityCode("odd"), 1)
    @Expect(serialParityCode("o"), 1)
    @Expect(serialParityCode("even"), 2)
    @Expect(serialParityCode("e"), 2)
    // 大小写不敏感：前端从配置里读到的常是大写
    @Expect(serialParityCode("None"), 0)
    @Expect(serialParityCode("EVEN"), 2)
    @Expect(serialParityCode("mark"), -1)
    @Expect(serialParityCode(""), -1)
}

@Test
func testSerialPathWhitelistMirror(): Unit {
    @Expect(serialPathLooksAllowed("/dev/ttyUSB0"), true)
    @Expect(serialPathLooksAllowed("/dev/ttyACM0"), true)
    @Expect(serialPathLooksAllowed("/dev/ttyS3"), true)
    @Expect(serialPathLooksAllowed("/dev/pts/7"), true)
    @Expect(serialPathLooksAllowed("/dev/serial/by-id/usb-1a86_USB_Serial-if00-port0"), true)
    @Expect(serialPathLooksAllowed("/dev/cu.usbserial-1420"), true)
    @Expect(serialPathLooksAllowed("COM3"), true)
    @Expect(serialPathLooksAllowed("\\\\.\\COM12"), true)

    @Expect(serialPathLooksAllowed("/etc/shadow"), false)
    @Expect(serialPathLooksAllowed("/dev/tty"), false)
    @Expect(serialPathLooksAllowed("/dev/ttyS"), false)
    @Expect(serialPathLooksAllowed("/dev/ttyUSB0/../../etc/shadow"), false)
    @Expect(serialPathLooksAllowed("/dev/serial/by-id/../../etc/passwd"), false)
    @Expect(serialPathLooksAllowed("COMfoo"), false)
    @Expect(serialPathLooksAllowed("COM1234"), false)
    @Expect(serialPathLooksAllowed(""), false)
}

@Test
func testSerialHexAndTextConversions(): Unit {
    let bytes = [UInt8(0), UInt8(15), UInt8(165), UInt8(255)]
    @Expect(serialBytesToHex(bytes), "000fa5ff")

    let back = serialHexToBytes("000fa5ff").getOrThrow()
    @Expect(back.size, 4)
    @Expect(serialBytesToHex(back), "000fa5ff")
    // 大写十六进制也认
    @Expect(serialBytesToHex(serialHexToBytes("A5").getOrThrow()), "a5")
    // 奇数长度 / 非十六进制字符一律拒绝，不猜
    @Expect(serialHexToBytes("0ff").isNone(), true)
    @Expect(serialHexToBytes("zz").isNone(), true)
    @Expect(serialHexToBytes("").getOrThrow().size, 0)

    @Expect(serialBytesToText("hi".toArray()).getOrThrow(), "hi")
    // 二进制帧（不是合法 UTF-8）不该硬塞成一个坏字符串
    @Expect(serialBytesToText([UInt8(255), UInt8(254)]).isNone(), true)
}

@Test
func testSerialOpenRejectsBadArgumentsBeforeTouchingDevice(): Unit {
    // 白名单在仓颉侧先给一句人话；真正的边界在 C 桥，但错误文案要能定位
    @Expect(serialErrOf("open", serialOpenArgs("/etc/shadow")).contains("不在允许的设备名单内"), true)
    // 缺参数
    @Expect(serialErrOf("open", JsonObject()).contains("missing argument \"path\""), true)

    var args = serialOpenArgs("/dev/ttyUSB0")
    args.put("baud", JsonInt(12345))
    @Expect(serialErrOf("open", args).contains("不支持的波特率"), true)

    args = serialOpenArgs("/dev/ttyUSB0")
    args.put("dataBits", JsonInt(9))
    @Expect(serialErrOf("open", args).contains("dataBits"), true)

    args = serialOpenArgs("/dev/ttyUSB0")
    args.put("parity", JsonString("mark"))
    @Expect(serialErrOf("open", args).contains("parity"), true)

    args = serialOpenArgs("/dev/ttyUSB0")
    args.put("stopBits", JsonInt(3))
    @Expect(serialErrOf("open", args).contains("stopBits"), true)
}

@Test
func testSerialHandleAndPayloadValidation(): Unit {
    // 句柄缺失 / 不是 open 给的
    @Expect(serialErrOf("read", JsonObject()).contains("missing argument \"handle\""), true)
    var args = JsonObject()
    args.put("handle", JsonInt(0))
    @Expect(serialErrOf("read", args).contains("must be a handle returned by serial:open"), true)
    @Expect(serialErrOf("close", args).contains("must be a handle returned by serial:open"), true)

    args = JsonObject()
    args.put("handle", JsonInt(1))
    @Expect(serialErrOf("write", args).contains("missing argument \"data\""), true)

    args.put("data", JsonString("hi"))
    args.put("encoding", JsonString("base64"))
    @Expect(serialErrOf("write", args).contains("encoding 只认"), true)

    args = JsonObject()
    args.put("handle", JsonInt(1))
    args.put("data", JsonString("abc"))
    args.put("encoding", JsonString("hex"))
    @Expect(serialErrOf("write", args).contains("不是合法十六进制串"), true)

    // 超长写入在仓颉侧就挡住（单次上限与 read 的 maxBytes 同量级）
    var big = ""
    var i = 0
    while (i < 4097) {
        big = big + "a"
        i++
    }
    args = JsonObject()
    args.put("handle", JsonInt(1))
    args.put("data", JsonString(big))
    @Expect(serialErrOf("write", args).contains("单次最多 4096 字节"), true)
}

@Test
func testSerialRejectsUnknownCommand(): Unit {
    var threw = false
    try {
        serialCmd("open").handle("serial:nope", JsonObject(), IpcContext("main", IpcHub()))
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("unknown serial command"), true)
    }
    @Expect(threw, true)
}

@Test
func testSerialPermissionSetGatesCommands(): Unit {
    let out = ArrayList<String>()
    let reg = CapabilityRegistry()
    reg.addFromJson(JsonValue.fromStr("{\"identifier\":\"s\",\"permissions\":[\"serial:readonly\"]}"))
    let hub = hubWithRegistry(reg, out)
    registerPluginCommands(hub, SerialPlugin())
    registerPluginPermissionSets(reg, SerialPlugin())

    // 集内命令放行：没有参数 → 报的是业务错误（缺 handle），不是「未授权」
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":41,\"cmd\":\"serial:read\"}")
    waitSink(out, 1)
    @Expect(out.size, 1)
    @Expect(strField(out[0], "error").contains("command not allowed"), false)

    // 写命令不在 readonly 集内：仍然拒
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":42,\"cmd\":\"serial:write\"}")
    @Expect(out.size, 2)
    @Expect(strField(out[1], "error"), "command not allowed: serial:write")
}
