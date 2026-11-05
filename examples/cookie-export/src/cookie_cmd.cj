package cookieExport

import cjTauri.*
import std.collection.*
import stdx.encoding.json.*

/**
 * 三组命令：
 *   - `cookie:platforms` 平台清单（前端按清单逐张渲染卡片，数量由平台表决定）
 *   - `cookie:probe`     读 cookie 并校验字段（不发文，只看「够不够用」）
 *   - `cookie:export`    双格式落盘：`~/.cspub/config.json` + `~/.cspub/cookie_<平台>`
 *
 * 读 cookie 一律走**宿主原生 cookie store**（`WebViewHost.cookiesJson`），不是 `document.cookie`：
 * 会话令牌基本都带 httpOnly，JS 侧根本看不见（详见 `src/cookies_bridge.cj` 的说明）。
 */

/** 取字符串参数（类型不对按空串处理，不猜） */
func argStr(args: JsonObject, key: String): String {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
        case None => return ""
    }
}

func errJson(msg: String): JsonValue {
    let o = JsonObject()
    o.put("ok", JsonBool(false))
    o.put("error", JsonString(msg))
    return o
}

func strArray(items: ArrayList<String>): JsonArray {
    let arr = JsonArray()
    for (i in items) {
        arr.add(JsonString(i))
    }
    return arr
}

/** 平台 id 清单文案（报错用）：加平台时自动跟上，不再手抄一份容易漏 */
func platformIdList(): String {
    var out = ""
    for (p in allPlatforms()) {
        if (out.size > 0) {
            out = out + " / "
        }
        out = out + p.id
    }
    return out
}

func requirePlatform(id: String): PlatformDef {
    if (id.size == 0) {
        throw CommandException("需要参数 \"platform\"（${platformIdList()}）")
    }
    match (findPlatform(id)) {
        case Some(p) => return p
        case None => throw CommandException("未知平台: ${id}")
    }
}

/**
 * cspub `~/.cspub/config.json` 的全部已知键（键名逐条来自 cspub 源码里的 loadConfigString 调用，
 * 不是猜的）。它同时是「合并写」的保留清单：stdx 的 JsonObject 不能迭代，只能按已知键取回。
 */
let KNOWN_CONFIG_KEYS: Array<String> = ["csdnCookie", "zhihuCookie", "juejinCookie", "oschinaCookie",
    "baijiahaoCookie", "baijiahaoAppId", "baijiahaoAppToken", "cnblogsBlogId", "cnblogsUsername",
    "cnblogsToken", "juejinCategoryId", "juejinTagIds", "juejinUuid", "oschinaCatalog",
    "oschinaPrivacy", "oschinaUserId", "atomgitRepo", "atomgitDir", "atomgitBranch", "atomgitToken",
    // 待支持平台的键：先占位，避免合并写把这些平台已导出的凭证当未知键丢掉
    "tencentCookie", "toutiaoCookie", "xiaohongshuCookie", "yuqueCookie"]

/**
 * 合并写 config.json：**保留文件里其它平台的键**。
 * 直接整文件覆盖是最容易犯的错——用户可能已经在里面配了博客园令牌或另一个平台的 cookie，
 * 覆盖一次就全没了，而且不会有任何报错提醒他。
 */
func mergeConfig(path: String, key: String, value: String): Unit {
    var obj = JsonObject()
    let old = readTextFile(path)
    if (old.size > 0) {
        try {
            let v = JsonValue.fromStr(old)
            match (v.kind()) {
                case JsonKind.JsObject =>
                    let o = v.asObject()
                    // stdx 1.2.0 的 JsonObject **没有** keys()（编译期实测），迭代不了；
                    // 于是按 cspub 的已知键逐项保留（键集合固定，见 KNOWN_CONFIG_KEYS）。
                    // 代价：用户自己塞的未知键会丢——所以这里只放行「cspub 认得的键」，
                    // 反过来说也保证了写出去的 config.json 一定被 cspub 读懂。
                    for (k in KNOWN_CONFIG_KEYS) {
                        match (o.get(k)) {
                            case Some(item) => obj.put(k, item)
                            case None => ()
                        }
                    }
                case _ => () // 顶层不是对象：当作没有旧配置，重建
            }
        } catch (e: Exception) {
            () // 旧文件坏了不阻断导出：本次写的键在新文件里完整存在
        }
    }
    obj.put(key, JsonString(value))
    writeTextFile(path, obj.toString())
}

/** 「当前账号」：优先取身份类字段（CSDN 的 UserNick/UserName），没有就留空 */
func accountOf(def: PlatformDef, list: ArrayList<CookieEntry>): String {
    for (want in def.extra) {
        let v = valueOf(list, want)
        if (v.size > 0) {
            return v
        }
    }
    return ""
}

public class PlatformCommands <: CommandHandler {
    /** 按发起命令的窗口解析宿主：写死主窗会让多窗口串台 */
    private let hostResolver: (String) -> Option<WebViewHost>

    public init(hostResolver: (String) -> Option<WebViewHost>) {
        this.hostResolver = hostResolver
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "cookie:platforms" => return this.platforms()
            case "cookie:probe" => return this.probe(args, ipc)
            case "cookie:export" => return this.export(args, ipc)
            case _ => throw CommandException("unknown cookie command: ${cmd}")
        }
    }

    private func hostOf(ipc: IpcContext): WebViewHost {
        match (this.hostResolver(ipc.window)) {
            case Some(h) => return h
            case None => throw CommandException("cookie: 窗口未登记: ${ipc.window}")
        }
    }

    /** 平台清单：前端据此画卡片，字段需求也一并下发（缺字段提示直接用） */
    private func platforms(): JsonValue {
        let arr = JsonArray()
        for (p in allPlatforms()) {
            let o = JsonObject()
            o.put("id", JsonString(p.id))
            o.put("name", JsonString(p.name))
            o.put("filter", JsonString(p.filter))
            o.put("loginUrl", JsonString(p.loginUrl))
            o.put("configKey", JsonString(p.configKey))
            o.put("required", strArray(p.required))
            o.put("extra", strArray(p.extra))
            o.put("note", JsonString(p.note))
            arr.add(o)
        }
        let root = JsonObject()
        root.put("ok", JsonBool(true))
        root.put("platforms", arr)
        return root
    }

    /** 读 + 过滤。filter 传空串给桥、在仓颉侧统一过滤：两处只留一套规则，免得桥和页面各判一次 */
    private func readPlatform(def: PlatformDef, ipc: IpcContext): (CookieSet, ArrayList<CookieEntry>) {
        let host = this.hostOf(ipc)
        let json = host.cookiesJson("")
        let set = parseCookieJson(json)
        if (!set.ok) {
            return (set, ArrayList<CookieEntry>())
        }
        return (set, selectedOf(set.entries, def.filter))
    }

    private func probe(args: JsonObject, ipc: IpcContext): JsonValue {
        let def = requirePlatform(argStr(args, "platform"))
        let (set, list) = this.readPlatform(def, ipc)
        if (!set.ok) {
            return errJson(set.error)
        }
        let missing = missingFields(def, list)
        let extra = presentFields(def.extra, list)
        var httpOnly = 0
        for (e in list) {
            if (e.httpOnly) {
                httpOnly = httpOnly + 1
            }
        }
        let o = JsonObject()
        // 「够用」= 有 cookie 且必需字段齐；缺字段仍回 ok=false 但带着 missing，前端好逐项标红
        o.put("ok", JsonBool(list.size > 0 && missing.size == 0))
        o.put("count", JsonInt(Int64(list.size)))
        o.put("httpOnlyCount", JsonInt(Int64(httpOnly)))
        o.put("missing", strArray(missing))
        o.put("extra", strArray(extra))
        o.put("account", JsonString(accountOf(def, list)))
        o.put("raw", JsonString(rawCookieHeader(list)))
        if (list.size == 0) {
            o.put("error", JsonString("该平台还没有 cookie：先点「登录」在窗口里完成登录"))
        }
        return o
    }

    private func export(args: JsonObject, ipc: IpcContext): JsonValue {
        let def = requirePlatform(argStr(args, "platform"))
        let (set, list) = this.readPlatform(def, ipc)
        if (!set.ok) {
            return errJson(set.error)
        }
        let raw = rawCookieHeader(list)
        if (raw.size == 0) {
            return errJson("没有取到 ${def.name} 的 cookie：先在「登录」里打开并完成登录，再回来提取")
        }
        let home = homeDir()
        if (home.size == 0) {
            return errJson("取不到用户主目录（USERPROFILE / HOME 都是空的），不知道往哪写凭证")
        }
        let dir = home + "/.cspub"
        ensureDirPath(dir)
        let cfgPath = dir + "/config.json"
        mergeConfig(cfgPath, def.configKey, raw)
        let cookiePath = dir + "/cookie_" + def.id
        writeTextFile(cookiePath, raw)
        let missing = missingFields(def, list)
        let o = JsonObject()
        // 字段缺失时 ok=false：文件写了，但**不能用**——这比「导出了、发文 401」早一步说出来
        o.put("ok", JsonBool(missing.size == 0))
        o.put("configPath", JsonString(cfgPath))
        o.put("cookiePath", JsonString(cookiePath))
        o.put("configKey", JsonString(def.configKey))
        o.put("missing", strArray(missing))
        o.put("count", JsonInt(Int64(list.size)))
        if (missing.size > 0) {
            o.put("error", JsonString("已写出文件，但缺必需字段（发文会失败）：${joinNames(missing)}"))
        }
        return o
    }
}

func joinNames(items: ArrayList<String>): String {
    var out = ""
    for (i in items) {
        if (out.size > 0) {
            out = out + "、"
        }
        out = out + i
    }
    return out
}
