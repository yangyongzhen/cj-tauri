package cjTauri.tests

import cjTauri.*
import cjTauri.plugins.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * MQTT 3.1.1 编解码单元测试（锁 src/plugins/mqtt_codec.cj 的纯函数）。
 *
 * 锁四件事：① 变长剩余长度的编解码边界（1..4 字节、超范围即拒、字节不够不猜）；
 * ② CONNECT / PUBLISH 的**逐字节线格式**——标志位域错一位对端就断连且通常不给原因，只能靠期望值锁死；
 * ③ 解码对畸形报文一律拒绝（长度字段与实收字节对不上、类型码非法、QoS=3 保留值）；
 * ④ 主题与过滤器校验（通配符必须独占一层、中文主题按**字节**计长）。
 *
 * 期望值一律写成十六进制字符串：字段顺序、长度、标志位一眼可见，比逐字段对象断言更能锁住线上格式。
 */

/** 十六进制文本 → 字节（测试里内联构造线上报文；不合法直接让用例失败） */
func mqttHex(hex: String): Array<UInt8> {
    return serialHexToBytes(hex).getOrThrow()
}

// ---------------------------------------------------------------- 剩余长度（变长整数）

@Test
func testRemainingLengthEncodeBoundaries(): Unit {
    @Expect(serialBytesToHex(mqttEncodeRemainingLength(0)), "00")
    @Expect(serialBytesToHex(mqttEncodeRemainingLength(127)), "7f")
    @Expect(serialBytesToHex(mqttEncodeRemainingLength(128)), "8001")
    @Expect(serialBytesToHex(mqttEncodeRemainingLength(16383)), "ff7f")
    @Expect(serialBytesToHex(mqttEncodeRemainingLength(16384)), "808001")
    @Expect(serialBytesToHex(mqttEncodeRemainingLength(2097151)), "ffff7f")
    @Expect(serialBytesToHex(mqttEncodeRemainingLength(2097152)), "80808001")
    // 协议上限 2^28-1：四字节全用满
    @Expect(serialBytesToHex(mqttEncodeRemainingLength(268435455)), "ffffff7f")
}

@Test
func testRemainingLengthRejectsOutOfRange(): Unit {
    var tooBig = false
    try {
        mqttEncodeRemainingLength(268435456)
    } catch (e: CommandException) {
        tooBig = true
        @Expect(e.message.contains("剩余长度超范围"), true)
    }
    @Expect(tooBig, true)
    var negative = false
    try {
        mqttEncodeRemainingLength(-1)
    } catch (e: CommandException) {
        negative = true
    }
    @Expect(negative, true)
}

@Test
func testRemainingLengthDecode(): Unit {
    let one = mqttDecodeRemainingLength(mqttHex("7f"), 0).getOrThrow()
    @Expect(one.value, 127)
    @Expect(one.consumed, 1)
    let two = mqttDecodeRemainingLength(mqttHex("8001"), 0).getOrThrow()
    @Expect(two.value, 128)
    @Expect(two.consumed, 2)
    // 带偏移解码：固定头占 1 字节，剩余长度从下标 1 开始
    let off = mqttDecodeRemainingLength(mqttHex("3003aabbcc"), 1).getOrThrow()
    @Expect(off.value, 3)
    @Expect(off.consumed, 1)
}

@Test
func testRemainingLengthDecodeRejectsMalformed(): Unit {
    // 只有续接位字节、还没等到收尾字节 → None（读循环要继续读，不算畸形）
    @Expect(mqttDecodeRemainingLength(mqttHex("80"), 0).isNone(), true)
    // 偏移越界 → None
    @Expect(mqttDecodeRemainingLength(mqttHex("80"), 5).isNone(), true)
    // 连续 5 个续接位字节：协议最多 4 字节，这种是畸形报文而不是「还没读完」
    @Expect(mqttDecodeRemainingLength(mqttHex("ffffffff7f"), 0).isNone(), true)
}

// ---------------------------------------------------------------- UTF-8 字段与组帧

@Test
func testUtf8FieldLengthCountsBytes(): Unit {
    // 「通知」是 6 字节 → 长度字段 0006。按**码点**数写成 0002 的话对端整条解析错位
    @Expect(serialBytesToHex(mqttUtf8Field("通知")), "0006e9809ae79fa5")
    @Expect(serialBytesToHex(mqttUtf8Field("")), "0000")
    // 二进制字段同形：内容原样、长度同样按字节（含 NUL 也不截断）
    @Expect(serialBytesToHex(mqttBinaryField(mqttHex("00ff10"))), "000300ff10")
}

@Test
func testFrameUsesVariableLengthHeader(): Unit {
    // body 128 字节跨过 127 边界 → 剩余长度是两字节 8001，整条 = 1 + 2 + 128
    let body = Array<UInt8>(128, repeat: 0x41)
    let framed = mqttFrame(MQTT_PKT_PUBLISH, 0, body)
    @Expect(framed.size, 131)
    @Expect(serialBytesToHex(framed[0..3]), "308001")
}

// ---------------------------------------------------------------- CONNECT

@Test
func testEncodeConnectMinimal(): Unit {
    let o = MqttConnectOptions()
    o.clientId = "cj1"
    // 10(类型) | 0f(剩余长度 15) | 0004 "MQTT" | 04(级别) | 02(cleanSession) | 003c(保活 60) | 0003 "cj1"
    @Expect(serialBytesToHex(mqttEncodeConnect(o)), "100f00044d5154540402003c0003636a31")
}

@Test
func testEncodeConnectFlagsWithWillUserPassword(): Unit {
    let o = MqttConnectOptions()
    o.clientId = "c"
    o.username = Some("u")
    o.password = Some("p")
    o.willTopic = Some("t")
    o.willPayload = "bye".toArray()
    o.willQos = 1
    o.willRetain = true
    o.keepaliveSec = 10
    o.cleanSession = true
    // 标志位：clean 0x02 | will 0x04 | willQos1 0x08 | willRetain 0x20 | pass 0x40 | user 0x80 = 0xee
    // body 27 字节 = 0x1b；顺序是 遗嘱主题 → 遗嘱载荷 → 用户名 → 密码（协议定死，不可换序）
    let expected = "10" + "1b" + "0004" + "4d515454" + "04" + "ee" + "000a" +
        "000163" + "000174" + "0003627965" + "000175" + "000170"
    @Expect(serialBytesToHex(mqttEncodeConnect(o)), expected)
}

@Test
func testEncodeConnectWithoutCleanSession(): Unit {
    let o = MqttConnectOptions()
    o.clientId = "c"
    o.cleanSession = false
    // body 13 字节 = 0x0d；不带 clean 时该位为 0（持久会话：broker 要留着订阅）
    @Expect(serialBytesToHex(mqttEncodeConnect(o)), "100d00044d5154540400003c000163")
}

@Test
func testEncodeConnectRejectsPasswordWithoutUsername(): Unit {
    // 密码标志只能在用户名标志为 1 时置位（§3.1.2.9）：只给密码是非法组合，当场拒
    let o = MqttConnectOptions()
    o.clientId = "c"
    o.password = Some("p")
    var threw = false
    try {
        mqttEncodeConnect(o)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("必须同时给 username"), true)
    }
    @Expect(threw, true)
}

@Test
func testDefaultClientIdIsStable(): Unit {
    @Expect(mqttDefaultClientId(7), "cj-tauri-7")
}

// ---------------------------------------------------------------- PUBLISH / SUBSCRIBE / 确认与心跳

@Test
func testEncodePublishQos0(): Unit {
    // 30 | 07 | 0003 "a/b" | "hi"（QoS 0 不带报文标识符，body = 主题字段 5 + 载荷 2）
    @Expect(serialBytesToHex(mqttEncodePublish("a/b", "hi".toArray(), 0, false, false, 0)),
        "30070003612f626869")
}

@Test
func testEncodePublishQos1RetainDup(): Unit {
    // 标志位：QoS1 0x02 | retain 0x01 | dup 0x08 = 0x0b → 固定头 0x3b
    // body = 主题字段 3 + 报文标识符 2 + 载荷 1 = 6 = 0x06
    @Expect(serialBytesToHex(mqttEncodePublish("t", "x".toArray(), 1, true, true, 7)),
        "3b06000174000778")
}

@Test
func testEncodePublishRejectsOversizePayload(): Unit {
    // 上限 256 KiB：超了直接拒——静默切分会让对端收到多条「看不出是一批」的消息
    var threw = false
    try {
        mqttEncodePublish("t", Array<UInt8>(262145, repeat: 0), 0, false, false, 0)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("载荷太大"), true)
    }
    @Expect(threw, true)
    // 正好在上限上则放行：剩余长度升到 3 字节（262147 = 0x83 0x80 0x10）
    let atLimit = mqttEncodePublish("t", Array<UInt8>(262144, repeat: 0), 0, false, false, 0)
    @Expect(atLimit.size, 262151)
    @Expect(serialBytesToHex(atLimit[0..4]), "30838010")
}

@Test
func testEncodePublishRejectsQosWithoutPacketId(): Unit {
    var threw = false
    try {
        mqttEncodePublish("t", "x".toArray(), 1, false, false, 0)
    } catch (e: CommandException) {
        threw = true
        @Expect(e.message.contains("缺少报文标识符"), true)
    }
    @Expect(threw, true)
}

@Test
func testEncodeSubscribeAndUnsubscribe(): Unit {
    // SUBSCRIBE 标志位协议固定 0b0010 → 固定头 0x82；body = 标识符 2 + 过滤器字段 5 + QoS 1
    @Expect(serialBytesToHex(mqttEncodeSubscribe(1, "a/b", 1)), "820800010003612f6201")
    // UNSUBSCRIBE 同形但不带 QoS 字节；固定头 0xa2
    @Expect(serialBytesToHex(mqttEncodeUnsubscribe(2, "a/b")), "a20700020003612f62")
    // 缺报文标识符当场拒（0 是非法值）
    var threw = false
    try {
        mqttEncodeSubscribe(0, "a/b", 0)
    } catch (e: CommandException) {
        threw = true
    }
    @Expect(threw, true)
}

@Test
func testEncodeAckFlags(): Unit {
    // PUBACK / PUBREC / PUBCOMP 标志为 0；PUBREL 标志协议固定 0b0010（错了对端当非法报文丢弃，QoS 2 卡住）
    @Expect(serialBytesToHex(mqttEncodeAck(MQTT_PKT_PUBACK, 9)), "40020009")
    @Expect(serialBytesToHex(mqttEncodeAck(MQTT_PKT_PUBREC, 9)), "50020009")
    @Expect(serialBytesToHex(mqttEncodeAck(MQTT_PKT_PUBREL, 9)), "62020009")
    @Expect(serialBytesToHex(mqttEncodeAck(MQTT_PKT_PUBCOMP, 9)), "70020009")
}

@Test
func testEncodeKeepaliveAndDisconnect(): Unit {
    @Expect(serialBytesToHex(mqttEncodePingreq()), "c000")
    @Expect(serialBytesToHex(mqttEncodeDisconnect()), "e000")
}

// ---------------------------------------------------------------- 解码与解析

@Test
func testDecodePacketRoundTrip(): Unit {
    let raw = mqttEncodePublish("a/b", "hi".toArray(), 0, false, false, 0)
    let p = mqttDecodePacket(raw).getOrThrow()
    @Expect(Int64(p.typeCode), 3)
    @Expect(Int64(p.flags), 0)
    @Expect(serialBytesToHex(p.body), "0003612f626869")
    let pub = mqttParsePublish(p).getOrThrow()
    @Expect(pub.topic, "a/b")
    @Expect(serialBytesToHex(pub.payload), "6869")
    @Expect(pub.qos, 0)
    @Expect(pub.hasPacketId, false)
}

@Test
func testDecodePacketRejectsMalformed(): Unit {
    // 剩余长度说 7，body 实际只有 5 字节 → None（不许按「前 5 字节先解析」猜）
    @Expect(mqttDecodePacket(mqttHex("30070003616263")).isNone(), true)
    // 类型码 0 与 15 都不是合法控制报文
    @Expect(mqttDecodePacket(mqttHex("0000")).isNone(), true)
    @Expect(mqttDecodePacket(mqttHex("f000")).isNone(), true)
    // 连固定头都不够
    @Expect(mqttDecodePacket(mqttHex("30")).isNone(), true)
    // 剩余长度字节不完整
    @Expect(mqttDecodePacket(mqttHex("3080")).isNone(), true)
}

@Test
func testParseConnack(): Unit {
    let c = mqttParseConnack(mqttDecodePacket(mqttHex("20020000")).getOrThrow()).getOrThrow()
    @Expect(c.sessionPresent, false)
    @Expect(c.returnCode, 0)
    // 会话标志只看最低位：0x01 → true；返回码 5 = 未授权
    let m = mqttParseConnack(mqttDecodePacket(mqttHex("20020105")).getOrThrow()).getOrThrow()
    @Expect(m.sessionPresent, true)
    @Expect(m.returnCode, 5)
    // 类型不对 → None（拿 SUBACK 的字节喂它）
    @Expect(mqttParseConnack(mqttDecodePacket(mqttHex("9003000100")).getOrThrow()).isNone(), true)
}

@Test
func testParseSuback(): Unit {
    // 报文标识符 0001，授予 [qos1, 0x80(该过滤器订阅失败)]
    let granted = mqttParseSuback(mqttDecodePacket(mqttHex("900400010180")).getOrThrow()).getOrThrow()
    @Expect(granted.size, 2)
    @Expect(granted[0], 1)
    @Expect(granted[1], 128)
    // body 不足 3 字节（只有标识符、没有授予码）→ None
    @Expect(mqttParseSuback(mqttDecodePacket(mqttHex("90020001")).getOrThrow()).isNone(), true)
}

@Test
func testParsePublishChineseTopicByBytes(): Unit {
    // 中文主题「通知」= 6 字节：整条 = 30 | 0a | 0006 通知 | "ok"
    let raw = mqttEncodePublish("通知", "ok".toArray(), 0, false, false, 0)
    @Expect(serialBytesToHex(raw), "300a0006e9809ae79fa56f6b")
    let pub = mqttParsePublish(mqttDecodePacket(raw).getOrThrow()).getOrThrow()
    @Expect(pub.topic, "通知")
    @Expect(serialBytesToHex(pub.payload), "6f6b")
}

@Test
func testParsePublishQos1CarriesPacketId(): Unit {
    let raw = mqttEncodePublish("t", "x".toArray(), 1, false, false, 42)
    let pub = mqttParsePublish(mqttDecodePacket(raw).getOrThrow()).getOrThrow()
    @Expect(pub.qos, 1)
    @Expect(pub.hasPacketId, true)
    @Expect(pub.packetId, 42)
    @Expect(pub.topic, "t")
    @Expect(serialBytesToHex(pub.payload), "78")
}

@Test
func testParsePublishRejectsReservedQos3(): Unit {
    // 标志位 QoS=3 是协议保留值 → 37 行以内的位域解析必须拒（36 = 类型 3 + 标志 6 = QoS 3）
    let p = mqttDecodePacket(mqttHex("3603000174")).getOrThrow()
    @Expect(Int64(p.flags), 6)
    @Expect(mqttParsePublish(p).isNone(), true)
    // 主题长度字段比 body 还长 → None
    @Expect(mqttParsePublish(mqttDecodePacket(mqttHex("300300ff61")).getOrThrow()).isNone(), true)
}

@Test
func testParsePacketId(): Unit {
    @Expect(mqttParsePacketId(mqttDecodePacket(mqttHex("40020009")).getOrThrow()), 9)
    // PINGRESP 没有 body → -1（调用方按 <0 判「这条不带标识符」）
    @Expect(mqttParsePacketId(mqttDecodePacket(mqttHex("d000")).getOrThrow()), -1)
}

// ---------------------------------------------------------------- 参数校验

@Test
func testValidHostAndPort(): Unit {
    @Expect(mqttValidHost("127.0.0.1"), true)
    @Expect(mqttValidHost("broker.example.com"), true)
    @Expect(mqttValidHost("mqtt-broker_1"), true)
    @Expect(mqttValidHost(""), false)
    @Expect(mqttValidHost("broker:1883"), false)   // 端口必须单独给
    @Expect(mqttValidHost("a b"), false)
    @Expect(mqttValidHost("测试"), false)           // 非 ASCII 域名不收（国际化域名要先转 punycode）
    @Expect(mqttValidPort(1), true)
    @Expect(mqttValidPort(1883), true)
    @Expect(mqttValidPort(65535), true)
    @Expect(mqttValidPort(0), false)
    @Expect(mqttValidPort(65536), false)
    @Expect(mqttValidPort(-1), false)
}

@Test
func testValidPublishTopic(): Unit {
    @Expect(mqttValidPublishTopic("sensor/temp"), true)
    @Expect(mqttValidPublishTopic("通知/温度"), true)
    // PUBLISH 的主题里通配符是非法字符（那是订阅侧的东西）
    @Expect(mqttValidPublishTopic(""), false)
    @Expect(mqttValidPublishTopic("sensor/+"), false)
    @Expect(mqttValidPublishTopic("sensor/#"), false)
}

@Test
func testValidTopicFilter(): Unit {
    @Expect(mqttValidTopicFilter("sensor/temp"), true)
    @Expect(mqttValidTopicFilter("#"), true)
    @Expect(mqttValidTopicFilter("sensor/#"), true)
    @Expect(mqttValidTopicFilter("sensor/+/temp"), true)
    @Expect(mqttValidTopicFilter("+/+"), true)
    // 空层级是合法的（`a//b` 就是三层）
    @Expect(mqttValidTopicFilter("a//b"), true)
    @Expect(mqttValidTopicFilter("a/"), true)
    // 通配符必须独占一整层：粘着别的字符就非法
    @Expect(mqttValidTopicFilter("sensor+/temp"), false)
    @Expect(mqttValidTopicFilter("sensor/temp+"), false)
    @Expect(mqttValidTopicFilter("sensor/#/temp"), false)
    @Expect(mqttValidTopicFilter("sensor/#suffix"), false)
    @Expect(mqttValidTopicFilter(""), false)
}

// ---------------------------------------------------------------- 展示助手

@Test
func testBytesToText(): Unit {
    @Expect(mqttBytesToText("hello".toArray()).getOrThrow(), "hello")
    @Expect(mqttBytesToText(Array<UInt8>()).getOrThrow(), "")
    @Expect(mqttBytesToText("温度=26".toArray()).getOrThrow(), "温度=26")
    // 制表/换行/回车算文本
    @Expect(mqttBytesToText("a\tb\n".toArray()).getOrThrow(), "a\tb\n")
    // NUL / 控制字符 / 非法 UTF-8 → None（页面据此改用十六进制显示，不猜编码）
    @Expect(mqttBytesToText(mqttHex("686900")).isNone(), true)
    @Expect(mqttBytesToText(mqttHex("01ff")).isNone(), true)
    @Expect(mqttBytesToText(mqttHex("e980")).isNone(), true)
}

@Test
func testClampQosAndDisplayNames(): Unit {
    @Expect(mqttClampQos(-3), 0)
    @Expect(mqttClampQos(0), 0)
    @Expect(mqttClampQos(2), 2)
    @Expect(mqttClampQos(9), 2)
    @Expect(mqttReturnCodeText(0), "连接已接受")
    @Expect(mqttReturnCodeText(4).contains("用户名或密码错误"), true)
    @Expect(mqttReturnCodeText(99).contains("未知返回码"), true)
    @Expect(mqttPacketTypeName(MQTT_PKT_CONNECT), "CONNECT")
    @Expect(mqttPacketTypeName(MQTT_PKT_PUBLISH), "PUBLISH")
    @Expect(mqttPacketTypeName(MQTT_PKT_PINGRESP), "PINGRESP")
    @Expect(mqttPacketTypeName(UInt8(15)), "UNKNOWN(15)")
}
