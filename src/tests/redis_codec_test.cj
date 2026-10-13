package cjTauri.tests

import cjTauri.*
import cjTauri.plugins.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * Redis RESP2 编解码单元测试（锁 src/plugins/redis_codec.cj 的纯函数）。
 *
 * 锁四件事：① 命令组帧的**逐字节线格式**（长度按字节、二进制安全、空命令即拒）；
 * ② 增量解析的三态语义——「还没收全」必须原地不动，「协议非法」必须当场拒，且两者不能混；
 * ③ 畸形输入一律不抛异常（未知前缀 / 长度非数字 / 结尾不是 CRLF / 深嵌套 / 谎报长度）；
 * ④ 取值助手（null 与空串能分开、扁平数组能当键值对、二进制有 hex 兜底）。
 *
 * 期望值一律写成十六进制字符串：CRLF 与长度字段一眼可见——这类地方错一个字节，对端只会「不响应」。
 * 注意 `@Expect` 对 enum 实参推不出泛型（AGENTS §4），所以断言一律走取值助手 + 布尔/字符串比较。
 */

/** 十六进制文本 → 字节（测试里内联构造线上报文；不合法直接让用例失败） */
func redisHex(hex: String): Array<UInt8> {
    return serialHexToBytes(hex).getOrThrow()
}

/** `Option` 是不是 None（不用 isNone()：不想在单测里引入没在本仓出现过的 API） */
func redisIsNone<T>(v: Option<T>): Bool {
    match (v) {
        case None => return true
        case _ => return false
    }
}

/** 喂一段字节并取一个值；顺便把「三态」拆成好断言的形式 */
func redisReadOne(hex: String): RespRead {
    let reader = RespReader()
    reader.feed(redisHex(hex))
    return reader.respTryRead()
}

/** 读取结果的分类名（断言里比字符串更直观，也避开 enum 实参的泛型推断问题） */
func redisReadKind(r: RespRead): String {
    match (r) {
        case RespRead.Incomplete => return "incomplete"
        case RespRead.Value(_) => return "value"
        case RespRead.Malformed(m) => return "malformed"
    }
}

/** 读取结果里的值；不是 Value 就给一个空 simple（用例会先断言 kind，这里只做搬运） */
func redisReadValue(r: RespRead): RespValue {
    match (r) {
        case RespRead.Value(v) => return v
        case _ => return RespValue.Simple("<not-a-value>")
    }
}

/** Malformed 的说明文字；不是 Malformed 就给空串 */
func redisReadMessage(r: RespRead): String {
    match (r) {
        case RespRead.Malformed(m) => return m
        case _ => return ""
    }
}

// ---------------------------------------------------------------- 命令组帧

@Test
func testEncodeCommandWireFormat(): Unit {
    // *3 CRLF $3 SET CRLF $3 key CRLF $5 value CRLF
    @Expect(serialBytesToHex(respEncodeCommand(["SET", "key", "value"])),
        "2a330d0a24330d0a5345540d0a24330d0a6b65790d0a24350d0a76616c75650d0a")
}

@Test
func testEncodeCommandLengthCountsBytesNotRunes(): Unit {
    // 「键」「值」各 3 字节（UTF-8）：长度字段写 3 而不是 1——按码点算会让对端解析错位
    @Expect(serialBytesToHex(respEncodeCommand(["SET", "键", "值"])),
        "2a330d0a24330d0a5345540d0a24330d0ae994ae0d0a24330d0ae580bc0d0a")
}

@Test
func testEncodeCommandBinarySafe(): Unit {
    // 值里带 NUL 与 0xFF：长度按字节算，内容原样穿过（调试工具会拿它看二进制 value）
    @Expect(serialBytesToHex(respCmdRaw3("SET", "blob", redisHex("0001fffe"))),
        "2a330d0a24330d0a5345540d0a24340d0a626c6f620d0a24340d0a0001fffe0d0a")
}

@Test
func testEncodeCommandBuilders(): Unit {
    @Expect(serialBytesToHex(respCmd1("PING")), "2a310d0a24340d0a50494e470d0a")
    @Expect(serialBytesToHex(respCmd2("GET", "user:1")), "2a320d0a24330d0a4745540d0a24360d0a757365723a310d0a")
    @Expect(serialBytesToHex(respCmdRaw2("GET", redisHex("00ff"))), "2a320d0a24330d0a4745540d0a24320d0a00ff0d0a")
}

@Test
func testEncodeCommandRejectsEmpty(): Unit {
    // *0 是非法命令（对端只会回一个协议错误，比当场报错难查），所以组帧层直接拒
    var threw = false
    try {
        respEncodeCommand(Array<String>())
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("至少要有一个参数"), true)
    }
    @Expect(threw, true)
}

// ---------------------------------------------------------------- 增量解析：基本类型

@Test
func testParseSimpleAndError(): Unit {
    let ok = redisReadValue(redisReadOne("2b4f4b0d0a"))                       // +OK
    @Expect(redisReadKind(redisReadOne("2b4f4b0d0a")), "value")
    match (ok) {
        case Simple(s) => @Expect(s, "OK")
        case _ => @Expect("simple 期望", "别拿到了")
    }
    let err = redisReadValue(redisReadOne("2d455252206261640d0a"))           // -ERR bad
    match (err) {
        case Failure(m) =>
            @Expect(m, "ERR bad")
            @Expect(respErrorOf(err).getOrThrow(), "ERR bad")
            @Expect(redisIsNone(respNumber(err)), true)
        case _ => @Expect("failure 期望", "别拿到了")
    }
}

@Test
func testParseNumber(): Unit {
    let v = redisReadValue(redisReadOne("3a3132330d0a"))                     // :123
    @Expect(respNumber(v).getOrThrow(), 123)
    @Expect(redisIsNone(respBytes(v)), true)                                 // 整数不是 bulk
}

@Test
func testParseNullBulkAndNullArray(): Unit {
    // $-1 与 *-1：都是 null，但类型不同；null 必须与「空串」分得开
    let nullBulk = redisReadValue(redisReadOne("242d310d0a"))
    @Expect(redisReadKind(redisReadOne("242d310d0a")), "value")
    @Expect(redisIsNone(respBytes(nullBulk)), true)
    @Expect(respBrief(nullBulk), "null")
    let nullArr = redisReadValue(redisReadOne("2a2d310d0a"))
    @Expect(redisIsNone(respItems(nullArr)), true)
    @Expect(respBrief(nullArr), "null")
    // 空串是 0 字节 bulk（尾部 CRLF 仍要在）：Some(空数组)，不是 null
    let emptyBulk = redisReadValue(redisReadOne("24300d0a0d0a"))
    @Expect(respBytes(emptyBulk).getOrThrow().size, 0)
}

@Test
func testParseBulkBinary(): Unit {
    // $4 00 01 FF FE CRLF：二进制值原样出来（不是 UTF-8 就得能拿到字节）
    let v = redisReadValue(redisReadOne("24340d0a0001fffe0d0a"))
    @Expect(respBrief(v), "bulk(4B)")
    @Expect(respHexOfBytes(respBytes(v).getOrThrow()), "0001FFFE")
    @Expect(respSafeText(respBytes(v).getOrThrow()), "0x0001FFFE")
}

@Test
func testParseNestedArray(): Unit {
    // *2 CRLF *2 CRLF :1 CRLF :2 CRLF +OK CRLF
    let v = redisReadValue(redisReadOne("2a320d0a2a320d0a3a310d0a3a320d0a2b4f4b0d0a"))
    @Expect(respBrief(v), "array(2)")
    let items = respItemsOrEmpty(v)
    @Expect(items.size, 2)
    @Expect(respBrief(items[0]), "array(2)")
    @Expect(respNumber(respItemsOrEmpty(items[0])[0]).getOrThrow(), 1)
    @Expect(respNumber(respItemsOrEmpty(items[0])[1]).getOrThrow(), 2)
    match (items[1]) {
        case Simple(s) => @Expect(s, "OK")
        case _ => @Expect("尾部 simple 期望", "别拿到了")
    }
}

@Test
func testParseFlatArrayAsPairs(): Unit {
    // HGETALL 的形状：*4 name alice city Beijing → 两对
    let v = redisReadValue(redisReadOne(
        "2a340d0a24340d0a6e616d650d0a24350d0a616c6963650d0a24340d0a636974790d0a24370d0a4265696a696e670d0a"))
    let pairs = respPairs(v)
    @Expect(pairs.size, 2)
    @Expect(pairs[0][0], "name")
    @Expect(pairs[0][1], "alice")
    @Expect(pairs[1][0], "city")
    @Expect(pairs[1][1], "Beijing")
}

// ---------------------------------------------------------------- 增量解析：跨块与游标

@Test
func testIncrementalAcrossChunks(): Unit {
    // 一条回复跨两个 socket 块到达：第一块必须判「没收全」且不动游标，第二块补齐后才出值
    let reader = RespReader()
    reader.feed(redisHex("2a320d0a24330d0a666f6f"))                          // *2 $3 foo（还差 CRLF 与第二个参数）
    @Expect(redisReadKind(reader.respTryRead()), "incomplete")
    @Expect(reader.buffered(), 11)
    reader.feed(redisHex("0d0a24330d0a6261720d0a"))                          // CRLF $3 bar CRLF
    let v = redisReadValue(reader.respTryRead())
    @Expect(respBrief(v), "array(2)")
    let items = respItemsOrEmpty(v)
    @Expect(respValueText(items[0]), "foo")
    @Expect(respValueText(items[1]), "bar")
    // 读干净了：缓冲见底，再读还是「没收全」（而不是把旧值再吐一遍）
    @Expect(reader.buffered(), 0)
    @Expect(redisReadKind(reader.respTryRead()), "incomplete")
}

@Test
func testTwoValuesInOneBuffer(): Unit {
    // 粘包：一次读到两条回复，必须一条一条吐，且顺序不变
    let reader = RespReader()
    reader.feed(redisHex("2b4f4b0d0a3a370d0a"))
    match (redisReadValue(reader.respTryRead())) {
        case Simple(s) => @Expect(s, "OK")
        case _ => @Expect("第一条应为 simple", "别拿到了")
    }
    @Expect(respNumber(redisReadValue(reader.respTryRead())).getOrThrow(), 7)
    @Expect(redisReadKind(reader.respTryRead()), "incomplete")
}

@Test
func testResetClearsPendingBytes(): Unit {
    // 断开重连时必须能清干净：残留半条报文会让下一次连接从错位字节开始解
    let reader = RespReader()
    reader.feed(redisHex("24330d0a61"))
    @Expect(reader.buffered(), 5)
    reader.reset()
    @Expect(reader.buffered(), 0)
    reader.feed(redisHex("2b4f4b0d0a"))
    match (redisReadValue(reader.respTryRead())) {
        case Simple(s) => @Expect(s, "OK")
        case _ => @Expect("reset 后应能正常读", "别拿到了")
    }
}

// ---------------------------------------------------------------- 畸形输入：一律 Malformed，不抛

@Test
func testMalformedUnknownPrefix(): Unit {
    // '%'（RESP3 map）与 '>'（RESP3 push）都在边界外：不猜它想表达什么，直接拒
    let map = redisReadOne("25320d0a")
    @Expect(redisReadKind(map), "malformed")
    @Expect(redisReadMessage(map).contains("只做 RESP2"), true)
    let push = redisReadOne("3e0d0a")
    @Expect(redisReadKind(push), "malformed")
}

@Test
func testMalformedBadInteger(): Unit {
    let r = redisReadOne("3a3132610d0a")                                     // :12a
    @Expect(redisReadKind(r), "malformed")
    @Expect(redisReadMessage(r).contains("整数不是合法数字"), true)
}

@Test
func testMalformedBulkLengthNotNumber(): Unit {
    let r = redisReadOne("246162630d0a")                                     // $abc
    @Expect(redisReadKind(r), "malformed")
    @Expect(redisReadMessage(r).contains("批量串长度非法"), true)
}

@Test
func testMalformedBulkLengthBeyondCap(): Unit {
    // 谎报 1e16 字节：按协议上限拒（也顺带盖住「整数超 2^53 判非法」那条路），而不是等它把内存吃干
    let r = redisReadOne("2431303030303030303030303030303030300d0a")
    @Expect(redisReadKind(r), "malformed")
}

@Test
func testMalformedBulkMissingTrailingCrlf(): Unit {
    // 长度声明 3、后面有 3 字节但收尾不是 CRLF：判非法，而不是「再等等」（否则会一直等下去）
    let r = redisReadOne("24330d0a6162635858")
    @Expect(redisReadKind(r), "malformed")
    @Expect(redisReadMessage(r).contains("CRLF"), true)
}

@Test
func testMalformedNegativeArrayLength(): Unit {
    // *-2：只有 *-1 是合法的 null 数组
    @Expect(redisReadKind(redisReadOne("2a2d320d0a")), "malformed")
    @Expect(redisReadKind(redisReadOne("2a6162630d0a")), "malformed")        // *abc
}

@Test
func testMalformedDepthLimit(): Unit {
    // 40 层嵌套（每层 *1）：超上限即判非法——对端不能用一个回复把递归栈打爆
    let raw = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < 40) {
        for (b in redisHex("2a310d0a")) {
            raw.add(b)
        }
        i += 1
    }
    for (b in redisHex("2b4f4b0d0a")) {
        raw.add(b)
    }
    let reader = RespReader()
    reader.feed(raw.toArray())
    let r = reader.respTryRead()
    @Expect(redisReadKind(r), "malformed")
    @Expect(redisReadMessage(r).contains("嵌套层数超过上限"), true)
}

@Test
func testMalformedDoesNotAdvanceCursor(): Unit {
    // 非法输入不消费字节：同一读取器再读还是同一条 malformed（上层报一次错就断开，不必自己清）
    let reader = RespReader()
    reader.feed(redisHex("25310d0a"))
    @Expect(redisReadKind(reader.respTryRead()), "malformed")
    @Expect(redisReadKind(reader.respTryRead()), "malformed")
    @Expect(reader.buffered(), 4)
}

@Test
func testIncompleteKeepsEveryByte(): Unit {
    // 半条批量串：一个字节都不能丢（丢了就会从错位处继续解析，后面全乱）
    let reader = RespReader()
    reader.feed(redisHex("24350d0a6865"))
    @Expect(reader.buffered(), 6)
    @Expect(redisReadKind(reader.respTryRead()), "incomplete")
    @Expect(reader.buffered(), 6)
    reader.feed(redisHex("6c6c6f0d0a"))
    @Expect(respValueText(redisReadValue(reader.respTryRead())), "hello")
}

// ---------------------------------------------------------------- 取值助手

@Test
func testParseIntHelper(): Unit {
    @Expect(respParseInt("0").getOrThrow(), 0)
    @Expect(respParseInt("123").getOrThrow(), 123)
    @Expect(respParseInt("-1").getOrThrow(), -1)
    @Expect(respParseInt("+7").getOrThrow(), 7)
    @Expect(redisIsNone(respParseInt("")), true)
    @Expect(redisIsNone(respParseInt("-")), true)
    @Expect(redisIsNone(respParseInt("12a")), true)
    @Expect(redisIsNone(respParseInt("1.5")), true)
    @Expect(redisIsNone(respParseInt("10000000000000000")), true)             // 超 2^53 判非法
}

@Test
func testHexHelpers(): Unit {
    @Expect(respHexByte(0), "00")
    @Expect(respHexByte(255), "FF")
    @Expect(respHexByte(171), "AB")
    @Expect(respHexOfBytes(redisHex("00ff10")), "00FF10")
    @Expect(respHexOfBytes(Array<UInt8>()), "")
}

@Test
func testSafeTextFallback(): Unit {
    @Expect(respSafeText("OK".toArray()), "OK")
    @Expect(respSafeText(Array<UInt8>()), "")
    @Expect(respSafeText(redisHex("ff")), "0xFF")                            // 坏字节 → hex 兜底
    @Expect(respSafeText(redisHex("e994ae")), "键")                          // 合法 UTF-8 照常转
}

@Test
func testBriefSummaries(): Unit {
    // 取证行用的摘要：只说类型与规模，不打内容（把整条 INFO 打进日志会把凭证淹掉）
    @Expect(respBrief(RespValue.Simple("OK")), "simple(OK)")
    @Expect(respBrief(RespValue.Failure("ERR x")), "error(ERR x)")
    @Expect(respBrief(RespValue.Number(-2)), "number(-2)")
    @Expect(respBrief(RespValue.Bulk(Some(redisHex("6162")))), "bulk(2B)")
    @Expect(respBrief(RespValue.Bulk(Option<Array<UInt8>>.None)), "null")
    @Expect(respBrief(RespValue.Arr(Option<Array<RespValue>>.None)), "null")
}

@Test
func testRenderArray(): Unit {
    // 人看的渲染：数组缩排多行，二进制走 hex（页面里也是这个口径）
    let v = redisReadValue(redisReadOne("2a320d0a24310d0a610d0a24310d0a620d0a"))
    let text = respRender(v)
    @Expect(text.contains("(array 2)"), true)
    @Expect(text.contains("0) (bulk 1B) a"), true)
    @Expect(text.contains("1) (bulk 1B) b"), true)
}

@Test
func testValueTextShapes(): Unit {
    // 键名 / TTL / 分值常以 simple 或整数形式回来：取值不能只认 bulk
    @Expect(respValueText(RespValue.Simple("OK")), "OK")
    @Expect(respValueText(RespValue.Number(-2)), "-2")
    @Expect(respValueText(RespValue.Bulk(Option<Array<UInt8>>.None)), "")
    @Expect(respValueText(redisReadValue(redisReadOne("2a320d0a3a310d0a3a320d0a"))), "2 items")
}

@Test
func testItemsOrEmptyToleratesNonArray(): Unit {
    @Expect(respItemsOrEmpty(RespValue.Simple("OK")).size, 0)
    @Expect(redisIsNone(respItems(RespValue.Simple("OK"))), true)
    @Expect(respPairs(RespValue.Simple("OK")).size, 0)
}

