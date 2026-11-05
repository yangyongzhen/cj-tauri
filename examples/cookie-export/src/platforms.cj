package cookieExport

import std.collection.*

/**
 * 平台定义表：**cspub 的字段硬需求就写在这里**，是工具与发文端之间的唯一契约。
 *
 * 字段来源分两类，都不是猜的：
 *
 * 一、cspub 已支持的 5 家（对着 cspub 源码逐条核对）：
 *   - csdn      `src/main.cj` 载入时校验整串非空；签名要 `UserToken`，身份读 `UserName`/`UserNick`
 *   - zhihu     `src/main.cj:237` 要 `z_c0`，`src/zhihu.cj:95` 还要 `XSRF-TOKEN`
 *   - juejin    `src/juejin.cj:809` 要 `sessionid`
 *   - oschina   `src/oschina.cj:29` 要 `oscid`
 *   - baijiahao `src/main.cj:315` 要 `BDUSS`
 *
 * 二、cspub 待支持的 4 家（2026-11 实测接口 + 可用实现核对，见 cspub `docs/多平台发文调研.md`）：
 *   - tencent       `addArticle` 纯 Cookie 鉴权，登录态要 `skey` + `qcommunity_session`；
 *                   `qcommunity_identify_id` 实测出现在未登录的 Set-Cookie 里，属身份类
 *   - toutiao       `mp/agw/article/publish` 要 `sessionid`；写请求须把 `csrftoken` 回写 `X-CSRFToken`
 *   - xiaohongshu   `web_session` 是会话；`a1` 是设备指纹——签名直接用它的前 16/后 16 字节做 AES key/iv
 *   - yuque         `_yuque_session` 是登录会话，`yuque_ctoken` 作 `x-csrf-token`（实测在 Set-Cookie 里）
 *
 * 在这些字段缺失时就报出来，比「发文时 401 再回头查」省几十分钟——这正是本工具存在的理由。
 *
 * 为什么没有 SegmentFault / 51CTO：这两家的发文 token 不是某个固定 cookie，
 * 而是当场从页面 HTML 里刮（SegmentFault 刮 `/write` 的 `serverData.Token`，51CTO 刮
 * `<meta name="csrf-token">`）。写不出「必需字段名」就别硬编一个，字段判错比不判更误导人。
 */
public class PlatformDef {
    /** 平台标识（命令参数用）：csdn / zhihu / juejin / oschina / baijiahao */
    public let id: String
    /** 展示名 */
    public let name: String
    /** cookie 域过滤后缀：命中 `example.com`、`.example.com`、`www.example.com` */
    public let filter: String
    /** 登录入口（内嵌视图直接打开它） */
    public let loginUrl: String
    /** cspub `~/.cspub/config.json` 里的键名（小驼峰） */
    public let configKey: String
    /** 必需 cookie 名：缺一个就是「导出了也不能用」 */
    public let required: ArrayList<String>
    /** 有则更好（身份/展示用），缺了只提示 */
    public let extra: ArrayList<String>
    /** 给用户看的一句话说明 */
    public let note: String

    public init(id: String, name: String, filter: String, loginUrl: String, configKey: String,
                required: ArrayList<String>, extra: ArrayList<String>, note: String) {
        this.id = id
        this.name = name
        this.filter = filter
        this.loginUrl = loginUrl
        this.configKey = configKey
        this.required = required
        this.extra = extra
        this.note = note
    }
}

func toList(items: Array<String>): ArrayList<String> {
    let out = ArrayList<String>()
    for (i in items) {
        out.add(i)
    }
    return out
}

/**
 * cookie 平台清单（博客园不在此列：它用 MetaWeblog 令牌，没有登录态 cookie 可提）
 *
 * 前 5 家 cspub 已支持；后 4 家是待支持平台——登录口先备好，凭证导出到位后，
 * 发文端补上就能直接跑，不必再让用户走一遍「F12 → Network → 抄 Cookie」。
 */
public func allPlatforms(): ArrayList<PlatformDef> {
    let list = ArrayList<PlatformDef>()
    list.add(PlatformDef("csdn", "CSDN", "csdn.net", "https://passport.csdn.net/login",
                          "csdnCookie", toList(["UserToken"]), toList(["UserName", "UserNick"]),
                          "签名要 UserToken；身份读 UserName/UserNick（整串导出）"))
    list.add(PlatformDef("zhihu", "知乎", "zhihu.com", "https://www.zhihu.com/signin",
                          "zhihuCookie", toList(["z_c0", "XSRF-TOKEN"]), toList(["d_c0"]),
                          "z_c0 是 httpOnly 会话（JS 读不到）；XSRF-TOKEN 供请求头"))
    list.add(PlatformDef("juejin", "掘金", "juejin.cn", "https://juejin.cn/login",
                          "juejinCookie", toList(["sessionid"]), toList([]),
                          "sessionid 多为 httpOnly，必须走原生 cookie store"))
    list.add(PlatformDef("oschina", "开源中国", "oschina.net", "https://www.oschina.net/home/login",
                          "oschinaCookie", toList(["oscid"]), toList([]),
                          "oscid 即会话标识"))
    list.add(PlatformDef("baijiahao", "百家号", "baidu.com", "https://baijiahao.baidu.com/",
                          "baijiahaoCookie", toList(["BDUSS"]), toList(["STOKEN"]),
                          "BDUSS 是百度账号会话；App 通道另需 appId/appToken"))
    list.add(PlatformDef("tencent", "腾讯云开发者社区", "tencent.com", "https://cloud.tencent.com/login",
                          "tencentCookie", toList(["skey", "qcommunity_session"]),
                          toList(["qcommunity_identify_id", "qcloud_uid"]),
                          "addArticle 纯 Cookie 鉴权、无请求签名；skey 里的 * 不要 URL 编码"))
    list.add(PlatformDef("toutiao", "今日头条", "toutiao.com", "https://mp.toutiao.com/auth/page/login",
                          "toutiaoCookie", toList(["sessionid", "csrftoken"]), toList([]),
                          "写请求必须把 csrftoken 原值回写到 X-CSRFToken 头，否则判跨站"))
    list.add(PlatformDef("xiaohongshu", "小红书", "xiaohongshu.com",
                          "https://creator.xiaohongshu.com/login",
                          "xiaohongshuCookie", toList(["web_session", "a1"]),
                          toList(["galaxy_creator_session_id"]),
                          "a1 是设备指纹：签名取它前 16/后 16 字节做 AES key/iv，必须与 UA 成对保存"))
    list.add(PlatformDef("yuque", "语雀", "yuque.com", "https://www.yuque.com/login",
                          "yuqueCookie", toList(["_yuque_session", "yuque_ctoken"]), toList([]),
                          "yuque_ctoken 作 x-csrf-token 头；也可改用官方 OpenAPI 的 Token"))
    return list
}

/** 按 id 查平台；找不到回 None（命令层据此报错，不静默落到某一家） */
public func findPlatform(id: String): Option<PlatformDef> {
    for (p in allPlatforms()) {
        if (p.id == id) {
            return Some(p)
        }
    }
    return None<PlatformDef>
}
