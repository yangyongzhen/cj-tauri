package cookieExport

import std.collection.*
import std.convert.*    // Int64.parse：JSON 数字转数值
import std.env.*
import std.fs.*
import std.process.*    // executeWithOutput：落盘后 chmod 600
import stdx.encoding.json.*

/**
 * cookie 的「取值 → 域过滤 → 校验 → 落盘」纯逻辑层。
 *
 * 刻意不碰 WebView、不碰命令分发：这一层只吃 JSON 字符串，能被单元测试直接喂样例
 * （`cjpm test` 里那条 `{"ok":true,"cookies":[…]}` 就是 C 桥真实回包的样子）。
 */

/** 单条 cookie：只留工具有用的字段（path/secure/sameSite 导出用不上） */
public class CookieEntry {
    public let name: String
    public let value: String
    public let domain: String
    public let httpOnly: Bool
    /** 过期秒级时间戳；0 = 会话 cookie（关窗即失效） */
    public let expires: Int64
    public let isSession: Bool

    public init(name: String, value: String, domain: String, httpOnly: Bool, expires: Int64,
                isSession: Bool) {
        this.name = name
        this.value = value
        this.domain = domain
        this.httpOnly = httpOnly
        this.expires = expires
        this.isSession = isSession
    }
}

/** 解析结果：ok=false 时 error 非空，entries 为空 */
public class CookieSet {
    public let ok: Bool
    public let error: String
    public let entries: ArrayList<CookieEntry>

    public init(ok: Bool, error: String, entries: ArrayList<CookieEntry>) {
        this.ok = ok
        this.error = error
        this.entries = entries
    }
}

// ── JSON 取值：按 Kind 分派 ───────────────────────────────────────────────
// 只认字符串的取法会把数字/布尔取成空串（cspub 踩过一次：isAudit 是数字，取成空串后
// 发出去的是「HTTP 200 + 0 字节」的空图，查了半天）。这里逐字段按 Kind 取。

func strOf(o: JsonObject, key: String): String {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
        case None => return ""
    }
}

func boolOf(o: JsonObject, key: String): Bool {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsBool => return v.asBool().getValue()
                case _ => return false
            }
        case None => return false
    }
}

func intOf(o: JsonObject, key: String): Int64 {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                // stdx 的 JsonKind 没有 JsNumber：整数是 JsInt、带小数是 JsFloat
                case JsonKind.JsInt =>
                    try {
                        return Int64.parse(v.toString())
                    } catch (e: Exception) {
                        return 0
                    }
                case JsonKind.JsFloat =>
                    try {
                        return Int64.parse(v.toString())
                    } catch (e: Exception) {
                        return 0
                    }
                case _ => return 0
            }
        case None => return 0
    }
}

/** 解析 C 桥回包。桥的两条失败路径（ok=false / 压根不是对象）都在这里收口 */
public func parseCookieJson(json: String): CookieSet {
    let none = ArrayList<CookieEntry>()
    if (json.size == 0) {
        return CookieSet(false, "桥返回空串（平台层没拿到结果？）", none)
    }
    try {
        let root = JsonValue.fromStr(json)
        match (root.kind()) {
            case JsonKind.JsObject => ()
            case _ => return CookieSet(false, "cookie 桥返回的不是 JSON 对象", none)
        }
        let obj = root.asObject()
        if (!boolOf(obj, "ok")) {
            var err = strOf(obj, "error")
            if (err.size == 0) {
                err = "桥未给出原因（ok=false）"
            }
            return CookieSet(false, err, none)
        }
        let entries = ArrayList<CookieEntry>()
        match (obj.get("cookies")) {
            case Some(cv) =>
                match (cv.kind()) {
                    case JsonKind.JsArray =>
                        let arr = cv.asArray()
                        for (i in 0..arr.size()) {
                            match (arr.get(i)) {
                                case Some(item) =>
                                    match (item.kind()) {
                                        case JsonKind.JsObject =>
                                            let o = item.asObject()
                                            entries.add(CookieEntry(strOf(o, "name"),
                                                                     strOf(o, "value"),
                                                                     strOf(o, "domain"),
                                                                     boolOf(o, "httpOnly"),
                                                                     intOf(o, "expires"),
                                                                     boolOf(o, "session")))
                                        case _ => ()
                                    }
                                case None => ()
                            }
                        }
                    case _ => ()
                }
            case None => ()
        }
        return CookieSet(true, "", entries)
    } catch (e: Exception) {
        return CookieSet(false, "cookie JSON 解析失败: ${e}", none)
    }
}

/**
 * 域匹配。桥给的是 cookie 自己的 domain（`.csdn.net` / `www.zhihu.com` 都见过），
 * 所以要吃三种形态：相等、带点子域、父域带点——用后缀判定一次覆盖。
 * 不做「去掉前导点再比」那套字符串裁剪：仓颉的切片语义犯错过，后缀判定更省心。
 */
public func domainMatches(domain: String, filter: String): Bool {
    if (filter.size == 0) {
        return true
    }
    if (domain == filter) {
        return true
    }
    return domain.endsWith("." + filter)
}

/** 按域挑出本平台的 cookie（丢掉别的站点的） */
public func selectedOf(entries: ArrayList<CookieEntry>, filter: String): ArrayList<CookieEntry> {
    let out = ArrayList<CookieEntry>()
    for (e in entries) {
        if (e.name.size > 0 && domainMatches(e.domain, filter)) {
            out.add(e)
        }
    }
    return out
}

/**
 * 拼成浏览器里那条 `Cookie:` 请求头的等价物：`a=1; b=2`。
 * cspub 的 `cookieValue` 按 `name=` 找值，所以顺序无所谓；但**空值条目要保留**——
 * 有些平台把开关塞在空值 cookie 里，丢掉会让服务端少认一个标志位。
 */
public func rawCookieHeader(list: ArrayList<CookieEntry>): String {
    var out = ""
    for (e in list) {
        if (out.size > 0) {
            out = out + "; "
        }
        out = out + e.name + "=" + e.value
    }
    return out
}

/** 本平台必需字段里缺了哪些（cspub 发文时会 401 的那些名字，提前报出来） */
public func missingFields(def: PlatformDef, list: ArrayList<CookieEntry>): ArrayList<String> {
    let out = ArrayList<String>()
    for (req in def.required) {
        var found = false
        for (e in list) {
            if (e.name == req && e.value.size > 0) {
                found = true
                break
            }
        }
        if (!found) {
            out.add(req)
        }
    }
    return out
}

/** 已具备的可选字段（身份/展示用），前端拿来显示「当前账号」 */
public func presentFields(names: ArrayList<String>, list: ArrayList<CookieEntry>): ArrayList<String> {
    let out = ArrayList<String>()
    for (want in names) {
        for (e in list) {
            if (e.name == want && e.value.size > 0) {
                out.add(want)
                break
            }
        }
    }
    return out
}

/** 取单字段值（CSDN 的 UserName 这类身份字段要从 cookie 里翻出来） */
public func valueOf(list: ArrayList<CookieEntry>, name: String): String {
    for (e in list) {
        if (e.name == name) {
            return e.value
        }
    }
    return ""
}

// ── 落盘工具 ─────────────────────────────────────────────────────────────

/** 用户主目录（HOME / USERPROFILE）；取不到回空串，调用方据此报错而不是写到相对路径 */
public func homeDir(): String {
    try {
        return getVariable("HOME").getOrThrow()
    } catch (e: Exception) {
        return ""
    }
}

public func ensureDirPath(p: String): Unit {
    if (p.size == 0 || exists(p)) {
        return
    }
    try {
        Directory.create(p, recursive: true)
    } catch (e: Exception) {
        () // 并发建目录时可能已存在；后续写入会给出真实错误
    }
}

public func readTextFile(p: String): String {
    if (!exists(p)) {
        return ""
    }
    try {
        return String.fromUtf8(File.readFrom(p))
    } catch (e: Exception) {
        return ""
    }
}

public func writeTextFile(p: String, text: String): Unit {
    if (exists(p)) {
        remove(p) // File.create 对已存在文件抛异常（仓颉实测），先删再建
    }
    let f = File.create(p)
    f.write(text.toArray())
    f.close()
    restrictPerm(p)
}

/**
 * 凭证落盘收紧到 600（仅本人的读写）。
 * Windows 侧跳过：用户目录默认 ACL 已限本人，仓库里也不存这些文件。
 */
@When[os == "Linux"]
public func restrictPerm(p: String): Unit {
    try {
        let _ = executeWithOutput("chmod", ["600", p])
    } catch (e: Exception) {
        () // 权限收紧是加固不是前置条件，失败不阻断导出
    }
}

@When[os != "Linux"]
public func restrictPerm(p: String): Unit {
    ()
}
