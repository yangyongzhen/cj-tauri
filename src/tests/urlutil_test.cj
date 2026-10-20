package cjTauri.tests

import cjTauri.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * SNI 的目标怎么定：`urlHostOf` 取主机名，`isIpLiteralHost` 判「是不是 IP 字面量」——
 * 域名才带 `serverName`（stdx 默认不发 SNI，多租户 HTTPS 边缘会当场以 handshake failure 拒掉，
 * 实测 Cloudflare 后面的 api 域名，见 D-022）；IP 字面量不带（RFC 6066 不许，且直连 IP 原本可用）。
 */

@Test
func testIpLiteralHostRecognizesIpv4AndIpv6(): Unit {
    @Expect(isIpLiteralHost("127.0.0.1"), true)
    @Expect(isIpLiteralHost("192.168.1.10"), true)
    @Expect(isIpLiteralHost("255.255.255.255"), true)
    @Expect(isIpLiteralHost("[::1]"), true)
    @Expect(isIpLiteralHost("::1"), true)
    @Expect(isIpLiteralHost("2606:4700:681a:e1a::1"), true)
}

@Test
func testIpLiteralHostRejectsHostnames(): Unit {
    @Expect(isIpLiteralHost("ai.novacode.top"), false)
    @Expect(isIpLiteralHost("localhost"), false)
    // 全是十六进制字母的域名（含点）**不是** IP——按「四段十进制」判就不会误伤
    @Expect(isIpLiteralHost("dead.beef"), false)
    @Expect(isIpLiteralHost("127.0.0.1.evil.com"), false)
    @Expect(isIpLiteralHost("1.2.3"), false)
    @Expect(isIpLiteralHost("999.1.1.1"), false)
    @Expect(isIpLiteralHost("1.2.3.4.5"), false)
    @Expect(isIpLiteralHost(""), false)
}

@Test
func testSniTargetDecisionFromUrl(): Unit {
    // 域名 → 带 SNI（这一条正是 ai.novacode.top 那轮修掉的东西）
    let named = match (urlHostOf("https://ai.novacode.top/v1/models")) {
        case Some(h) => h
        case None => ""
    }
    @Expect(named, "ai.novacode.top")
    @Expect(isIpLiteralHost(named), false)

    // 直连 IP（带端口）→ 不带 SNI，连接与验证照旧
    let byIp = match (urlHostOf("https://127.0.0.1:8765/api/health")) {
        case Some(h) => h
        case None => ""
    }
    @Expect(byIp, "127.0.0.1")
    @Expect(isIpLiteralHost(byIp), true)
}
