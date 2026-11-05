package cookieExport

import std.collection.*

/**
 * 平台定义表：**cspub 的字段硬需求就写在这里**，是工具与发文端之间的唯一契约。
 *
 * 每一条都来自 cspub 源码核对（不是猜的）：
 *   - csdn      `src/main.cj` 载入时校验整串非空；签名要 `UserToken`，身份读 `UserName`/`UserNick`
 *   - zhihu     `src/main.cj:237` 要 `z_c0`，`src/zhihu.cj:95` 还要 `XSRF-TOKEN`
 *   - juejin    `src/juejin.cj:809` 要 `sessionid`
 *   - oschina   `src/oschina.cj:29` 要 `oscid`
 *   - baijiahao `src/main.cj:315` 要 `BDUSS`
 *
 * 在这些字段缺失时就报出来，比「发文时 401 再回头查」省几十分钟——这正是本工具存在的理由。
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
 * 五个 cookie 平台（博客园不在此列：它用 MetaWeblog 令牌，没有登录态 cookie 可提）
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
