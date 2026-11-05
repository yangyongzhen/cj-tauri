package cookieExport

import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 解析 / 合并写 / 落盘的单元测试。
 *
 * 挑这三块测，是因为它们是导出链路里唯一「不点开界面也能测、且出错不会报错只会静默毁数据」的部分：
 * 合并写覆盖掉用户已有的其他平台凭证、或者写出一个 cspub 读不懂的 config.json，界面上都看不出来。
 * 样例 JSON 直接抄 C 桥的真实回包形状（见 native/platforms/linux/bridge_linux.c 的 cookie_json_escaped）。
 *
 * 注意仓颉的三引号字符串必须以换行开头，所以这里一律用普通字符串 + 转义。
 */
@Test
class CookieStoreTest {

    /** 桥回包 → 条目：字段按 Kind 取，httpOnly 会话标记都要落到对象上 */
    @TestCase
    func parseBridgeReply(): Unit {
        let json = "{\"ok\":true,\"cookies\":[{\"name\":\"UserToken\",\"value\":\"tok123\",\"domain\":\".csdn.net\",\"httpOnly\":true,\"expires\":1767225600,\"session\":false},{\"name\":\"UserName\",\"value\":\"m0_1\",\"domain\":\".csdn.net\",\"httpOnly\":false,\"expires\":0,\"session\":true}]}"
        let set = parseCookieJson(json)
        @Expect(set.ok, true)
        @Expect(set.entries.size, 2)
        if (set.entries.size != 2) {
            return
        }
        @Expect(valueOf(set.entries, "UserToken"), "tok123")
        var httpOnlyCount = 0
        for (e in set.entries) {
            if (e.httpOnly) {
                httpOnlyCount = httpOnlyCount + 1
            }
        }
        @Expect(httpOnlyCount, 1)
    }

    /** 桥的几条失败路径都要报出原因，不能静默返回空条目 */
    @TestCase
    func parseFailurePaths(): Unit {
        @Expect(parseCookieJson("").ok, false)
        @Expect(parseCookieJson("{\"ok\":false,\"error\":\"busy\"}").error, "busy")
        @Expect(parseCookieJson("{\"ok\":false}").ok, false)
        @Expect(parseCookieJson("[1,2,3]").ok, false)
    }

    /** 域过滤：cookie 的 domain 有 `.csdn.net` 和 `blog.csdn.net` 两种形态，后缀判定要都吃住 */
    @TestCase
    func domainFilter(): Unit {
        @Expect(domainMatches(".csdn.net", "csdn.net"), true)
        @Expect(domainMatches("blog.csdn.net", "csdn.net"), true)
        @Expect(domainMatches("csdn.net", "csdn.net"), true)
        @Expect(domainMatches("notcsdn.net", "csdn.net"), false)
        @Expect(domainMatches("zhihu.com", "csdn.net"), false)
    }

    /** 拼 Cookie 头：空值条目要保留（有的平台把开关塞在空值 cookie 里） */
    @TestCase
    func rawHeaderKeepsEmptyValues(): Unit {
        let list = ArrayList<CookieEntry>()
        list.add(CookieEntry("a", "1", ".csdn.net", false, 0, true))
        list.add(CookieEntry("flag", "", ".csdn.net", false, 0, true))
        list.add(CookieEntry("b", "2", ".csdn.net", false, 0, true))
        @Expect(rawCookieHeader(list), "a=1; flag=; b=2")
    }

    /**
     * 必需字段判定：CSDN 的硬需求只有 `UserToken`（签名用），`UserName`/`UserNick` 属 extra——
     * 有则显示账号，缺了不算「不能发文」。空值也按缺处理：值为空串等于没登录取不到。
     */
    @TestCase
    func missingRequiredFields(): Unit {
        let def = requirePlatform("csdn")
        let def2 = requirePlatform("csdn")
        let onlyIdentity = ArrayList<CookieEntry>()
        onlyIdentity.add(CookieEntry("UserName", "m0_1", ".csdn.net", false, 0, true))
        let missing = missingFields(def, onlyIdentity)
        @Expect(missing.size, 1)
        var joined = ""
        for (m in missing) {
            joined = joined + m + ","
        }
        @Expect(joined.contains("UserToken"), true)

        // 空值同样算缺（导出空值等于没登录，cspub 那边会 401）
        let blankToken = ArrayList<CookieEntry>()
        blankToken.add(CookieEntry("UserToken", "", ".csdn.net", true, 0, true))
        @Expect(missingFields(def2, blankToken).size, 1)

        // extra 里的字段缺失不进入 missing 列表
        @Expect(presentFields(def.extra, onlyIdentity).size, 1)
    }

    /**
     * 合并写：已有 config.json 里别的平台的键必须留下。
     * 这一条挂了就意味着用户配的博客园令牌/AtomGit token 会被一次导出抹掉。
     */
    @TestCase
    func mergeConfigKeepsKnownKeys(): Unit {
        let dir = testDir()
        ensureDirPath(dir)
        let p = dir + "/config.json"
        writeTextFile(p,
            "{\"csdnCookie\":\"old-csdn\",\"cnblogsToken\":\"blog-token\",\"atomgitToken\":\"gh-token\"}")
        mergeConfig(p, "zhihuCookie", "z_c0=abc")
        let txt = readTextFile(p)
        @Expect(txt.contains("old-csdn"), true)
        @Expect(txt.contains("blog-token"), true)
        @Expect(txt.contains("gh-token"), true)
        @Expect(txt.contains("z_c0=abc"), true)
    }

    /** 旧 config.json 是坏 JSON 时：不阻断导出，本次写的键仍然完整落盘 */
    @TestCase
    func mergeConfigSurvivesBrokenFile(): Unit {
        let dir = testDir()
        ensureDirPath(dir)
        let p = dir + "/broken.json"
        writeTextFile(p, "{ this is not json")
        mergeConfig(p, "juejinCookie", "sessionid=xyz")
        @Expect(readTextFile(p).contains("sessionid=xyz"), true)
    }

    /** 落盘内容原样、可被再次读回（writeTextFile 对已存在文件先删再建） */
    @TestCase
    func writeOverwritesExisting(): Unit {
        let dir = testDir()
        ensureDirPath(dir)
        let p = dir + "/cookie_oschina"
        writeTextFile(p, "oscid=one")
        writeTextFile(p, "oscid=two")
        @Expect(readTextFile(p), "oscid=two")
    }

    /** 测试专用目录：不碰用户真实的 ~/.cspub */
    func testDir(): String {
        "/tmp/cookie-export-ut"
    }
}
