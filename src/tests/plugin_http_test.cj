package cjTauri.tests

import cjTauri.*
import cjTauri.plugins.http.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * http 插件的策略层用例（RFC-003 HTTP 白名单收口）。
 *
 * 只测**纯函数**（URL → host 提取、上限常量、插件声明面）：真的发请求那一段归
 * 实机 E2E——单测进程里起真 HTTP 服务会引入对环境的依赖，不符合「渐进目标」的口径。
 */

@Test
func testHttpHostOfExtractsHostLowercased(): Unit {
    @Expect(httpHostOf("https://api.deepseek.com/v1/chat/completions"), "api.deepseek.com")
    // host 大小写不敏感：统一小写，匹配口径才收得住
    @Expect(httpHostOf("https://API.DeepSeek.COM/x"), "api.deepseek.com")
}

@Test
func testHttpHostOfStripsPortAndUserinfo(): Unit {
    // 端口不参与匹配（白名单声明「信这个主机」）
    @Expect(httpHostOf("http://localhost:2375/docker"), "localhost")
    // userinfo（user:pass@host）不许用来伪造白名单匹配
    @Expect(httpHostOf("https://user:pass@api.example.com/"), "api.example.com")
}

@Test
func testHttpHostOfRejectsNonHttpSchemes(): Unit {
    // file: 不给出网语义；空 host（ftp://）也当解析不出
    let f = match (httpHostOf("file:///etc/passwd")) {
        case Some(_) => true
        case None => false
    }
    @Expect(f, false)
    let n = match (httpHostOf("notaurl")) {
        case Some(_) => true
        case None => false
    }
    @Expect(n, false)
}

@Test
func testHttpHostOfIpv6Literal(): Unit {
    // IPv6 字面量整体当 host（不拆端口）：去端口逻辑只在非 '[' 开头时走
    @Expect(httpHostOf("http://[::1]:8080/x"), "[::1]")
}

@Test
func testHttpPluginDeclarations(): Unit {
    let p = HttpPlugin()
    @Expect(p.name(), "http")
    @Expect(p.scopeAware(), true)
    // 权限集 default = get + post + delete + postStream：集声明 != 放行，清单引用才生效
    @Expect(p.permissions().contains("default"), true)
    let cmds = p.commands()
    @Expect(cmds.contains("get"), true)
    @Expect(cmds.contains("post"), true)
    // delete 是给「带 JSON 体的 DELETE」用的（cjh 的工作区删除靠体传 path）：
    // 少了它前端只能退化成无体 DELETE，对端拿不到要删哪个
    @Expect(cmds.contains("delete"), true)
    @Expect(cmds.contains("postStream"), true)
    // 推一个事件（流式 http:chunk，短名登记）、无前端 shim
    @Expect(p.events().size == 1, true)
    @Expect(p.jsShim().size == 0, true)
}

@Test
func testHttpHostOfRejectsWsSchemes(): Unit {
    // http 插件的 host 提取转发核心 urlHostOf（ws/wss 是 ws 插件的合法目标），
    // 但协议收紧到 http(s)：ws:// 不是可抓取目标，解析不出 host 按白名单未命中拒
    let f = match (httpHostOf("ws://127.0.0.1:8765/ws")) {
        case Some(_) => true
        case None => false
    }
    @Expect(f, false)
}

@Test
func testHttpLimitsAreSane(): Unit {
    // 上限是「防撑爆」而非「功能」：8 MiB 与 60s 与既有插件（clipboard 8MiB）同量级
    @Expect(CJ_HTTP_MAX_BYTES == 8 * 1024 * 1024, true)
    @Expect(CJ_HTTP_TIMEOUT_SECONDS > 0, true)
    @Expect(CJ_HTTP_MAX_HEADERS > 0, true)
}

/*
 * 流式分块的 UTF-8 边界（2026-10-16 实机 → 回归）：`takeCompleteUtf8` 取走完整序列后
 * 必须把 pending 里的**这些字节**全移掉。曾经写成 `remove(0..(cut-1))`（Range 是右开的，
 * 这样就少移 1 字节），上一个序列的末字节留在 pending 里，下一轮拼出的字节序列非法，
 * fromUtf8 抛 IllegalArgumentException，表现是「中文回复偶发整条 postStream 请求失败」。
 * 判据就一条：整块都是完整序列时，取完 pending 必须**空**。
 */

@Test
func testHttpTakeCompleteUtf8ConsumesWholeCompleteChunk(): Unit {
    let pending = ArrayList<Byte>()
    for (b in "abc你".toArray()) {
        pending.add(b)
    }
    let cmds = HttpCommands()
    @Expect(cmds.takeCompleteUtf8(pending), "abc你")
    @Expect(pending.size, 0)
}

@Test
func testHttpTakeCompleteUtf8KeepsPartialTail(): Unit {
    // 尾巴不完整（汉字只到了前 2 字节）：留在 pending 里等下一块补齐，不能按原样解出来
    let bytes = "你".toArray()
    @Expect(bytes.size, 3)
    let pending = ArrayList<Byte>()
    pending.add(bytes[0])
    pending.add(bytes[1])
    let cmds = HttpCommands()
    @Expect(cmds.takeCompleteUtf8(pending), "")
    @Expect(pending.size, 2)
    // 第 3 字节到了：跨块的字符拼回来，pending 随之清空
    pending.add(bytes[2])
    @Expect(cmds.takeCompleteUtf8(pending), "你")
    @Expect(pending.size, 0)
}
