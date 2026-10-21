package cjTauri.tests

import cjTauri.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 静默启动的参数线格式（`joinHiddenArgs`）单测。
 *
 * 真正难的**不是拼接**，是「拼出来还能原样切开」这条不变量：C 桥按 0x1F 把这条串切成 argv，
 * 一旦某个参数自身带着 0x1F，它就在桥那边变成两个参数——而调用方拿到的是「启动成功」，
 * 错误要到目标进程抱怨「未知选项」时才现身。所以这里有两条硬要求：
 * ① 参数**逐字**进线格式（空格 / 引号 / 中文都不在这里转义，转义是平台侧的事）；
 * ② 参数里出现 0x1F 就当场拒绝，不许拼接。
 *
 * 起真进程 / 判可见窗口的部分不在这里（需要桌面与平台桥），归实机取证。
 */

/** 线格式分隔符：0x1F（单元分隔符），与 C 桥 `CJ_ARG_SEP` 同值 */
let hiddenSep: String = "\u{1F}"

/** 拼装成功取回线格式；被拒绝时回一个可比较的哨兵值（避免在断言里直接比 Option） */
func hiddenWireOf(args: Array<String>): String {
    let parsed = joinHiddenArgs(args)
    var wire = "<rejected>"
    match (parsed) {
        case Some(w) => wire = w
        case None => wire = "<rejected>"
    }
    return wire
}

/** 是否被拒绝（0x1F 出现在参数里） */
func hiddenArgsRejected(args: Array<String>): Bool {
    let parsed = joinHiddenArgs(args)
    var rejected = false
    match (parsed) {
        case Some(_) => rejected = false
        case None => rejected = true
    }
    return rejected
}

@Test
func testJoinHiddenArgsKeepsOrderAndUsesUnitSeparator(): Unit {
    // 顺序必须与传入一致（桥按位取 argv），分隔符只有一个 0x1F
    let wire = hiddenWireOf(["web", "--port", "8765", "--bind", "127.0.0.1"])
    @Expect(wire, "web" + hiddenSep + "--port" + hiddenSep + "8765" + hiddenSep + "--bind" +
        hiddenSep + "127.0.0.1")
}

@Test
func testJoinHiddenArgsSingleArgHasNoSeparator(): Unit {
    // 只有一个参数时线格式里不该留下尾随分隔符（否则桥会切出一个空 argv）
    let wire = hiddenWireOf(["web"])
    @Expect(wire, "web")
    // indexOf 回 Option<Int64>，这里只关心「有没有」，拆开再断言（@Expect 对不同泛型的 Option 实参推不出类型）
    let found = wire.indexOf(hiddenSep)
    var hasSep = true
    match (found) {
        case Some(_) => hasSep = true
        case None => hasSep = false
    }
    @Expect(hasSep, false)
}

@Test
func testJoinHiddenArgsEmptyArgListIsEmptyWire(): Unit {
    // 没参数的启动（如 cjh 只用默认端口）走这条：空线格式，桥侧切成零个 argv
    let wire = hiddenWireOf([])
    @Expect(wire, "")
}

@Test
func testJoinHiddenArgsKeepsSpacesQuotesAndChineseVerbatim(): Unit {
    // 参数原样上线：不在这里加引号、不转义——那些是平台侧（CreateProcessW / posix_spawn）的事。
    // 中文按 UTF-8 逐字节过桥，不做任何改写。
    let wire = hiddenWireOf(["hello world", "\"quoted\"", "中文参数", "--path=C:/a b/c"])
    @Expect(wire, "hello world" + hiddenSep + "\"quoted\"" + hiddenSep + "中文参数" + hiddenSep +
        "--path=C:/a b/c")
}

@Test
func testJoinHiddenArgsKeepsEmptyArgSlot(): Unit {
    // 中间那个空串参数不能被吞：它占一个 argv 位，桥那边必须收到一个空参数
    let wire = hiddenWireOf(["a", "", "b"])
    @Expect(wire, "a" + hiddenSep + hiddenSep + "b")
}

@Test
func testJoinHiddenArgsRoundTripsThroughSplit(): Unit {
    // 不变量：拼出来还能按同一个分隔符切回去，条数不变、逐条相等
    let args = ["web", "--port", "8765", "--bind", "127.0.0.1"]
    let back = hiddenWireOf(args).split(hiddenSep)
    @Expect(back.size, args.size)
    var same = true
    for (i in 0..args.size) {
        if (back[i] != args[i]) {
            same = false
        }
    }
    @Expect(same, true)
}

@Test
func testJoinHiddenArgsRejectsUnitSeparatorInArg(): Unit {
    // 0x1F 混在参数里 → 必须拒绝（拼接成功等于把参数悄悄劈成两个）
    @Expect(hiddenArgsRejected(["plain" + hiddenSep + "injected"]), true)
    // 位置无关：开头 / 中间 / 末尾都要拒
    @Expect(hiddenArgsRejected([hiddenSep + "lead"]), true)
    @Expect(hiddenArgsRejected(["--port", "1" + hiddenSep + "2"]), true)
    @Expect(hiddenArgsRejected(["trail" + hiddenSep]), true)
    // 整个参数就是一个分隔符
    @Expect(hiddenArgsRejected([hiddenSep]), true)
    // 对照：正常参数不被拒（否则上面的「拒绝」可能只是恒 true）
    @Expect(hiddenArgsRejected(["web", "--port", "8765"]), false)
}

@Test
func testLaunchHiddenRejectsEmptyPathWithoutTouchingBridge(): Unit {
    // 空路径在**进桥之前**就返回 None：不需要任何平台产物，也不会留下 pid
    let started = launchHidden("", ["web"])
    var isNone = false
    match (started) {
        case Some(_) => isNone = false
        case None => isNone = true
    }
    @Expect(isNone, true)
}
