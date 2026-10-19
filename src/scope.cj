package cjTauri

import std.collection.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*

/**
 * 路径 scope：把「某插件的路径参数能落在哪里」写成白名单（RFC-003 第 4 期）。
 *
 * 为什么放在框架共享层、而不是留给插件自己写：展开变量、规范化、glob 匹配、deny 优先
 * 这几件事只要有第二份实现，就一定会有一份是错的——安全校验不吃「各插件各写一套」。
 * 插件只调 `IpcContext.resolveScopedPath("<插件名>", 页面给的路径)` 取值。
 *
 * 清单写法（capabilities 目录的 json，键是插件名）：
 *     "scopes": { "fs": { "allow": ["$HOME/notes/**"], "deny": ["**/id_rsa"] } }
 *
 * 语义：完全没有该插件的条目 = 旧行为（全量放行，启动时由 warnUnscopedPlugins 提示）；
 * 有条目就按「先 deny 后 allow」判定——allow 必须显式命中，写了空 allow 等于该插件路径全拒。
 */
public class ScopeRule {
    public let allow: ArrayList<String>
    public let deny: ArrayList<String>

    public init() {
        this.allow = ArrayList<String>()
        this.deny = ArrayList<String>()
    }

    public func isEmpty(): Bool {
        return this.allow.size == 0 && this.deny.size == 0
    }
}

/**
 * 解析一条 scope 规则：`{ "allow": [...], "deny": [...] }`。
 * 数组里非字符串的元素忽略；模式在解析时就展开路径变量（此后只管匹配）。
 */
public func parseScopeRule(json: JsonValue): Option<ScopeRule> {
    match (json.kind()) {
        case JsonKind.JsObject => ()
        case _ => return None
    }
    let obj = json.asObject()
    let rule = ScopeRule()
    // 模式与页面路径走同一套分隔符口径：$HOME 在 Windows 展开出的是 USERPROFILE 原值
    // （C:\Users\...，反斜杠），不归一的话拿它匹配 normalizeScopePath 的正斜杠结果永远不中
    // ——`$HOME/**` 在 Windows 上形同虚设（实测 Desktop 文件被拒）。
    if (let Some(a) <- obj.get("allow")) {
        collectScopePatterns(a, rule.allow)
    }
    if (let Some(d) <- obj.get("deny")) {
        collectScopePatterns(d, rule.deny)
    }
    return Some(rule)
}

private func collectScopePatterns(v: JsonValue, out: ArrayList<String>): Unit {
    match (v.kind()) {
        case JsonKind.JsArray =>
            let arr = v.asArray()
            for (i in 0..arr.size()) {
                if (let Some(x) <- arr.get(i)) {
                    match (x.kind()) {
                        case JsonKind.JsString =>
                            out.add(toScopeSlashes(expandScopeVars(x.asString().getValue())))
                        case _ => ()
                    }
                }
            }
        // 单条字符串也收：写 "fs": { "allow": "$HOME/**" } 与写成数组等价，少一处踩坑
        case JsonKind.JsString =>
            out.add(toScopeSlashes(expandScopeVars(v.asString().getValue())))
        case _ => ()
    }
}

/**
 * 判定：路径是否被这条 scope 放行。
 * 顺序是先 deny 后 allow——命中 deny 一律拒（哪怕同时命中 allow）；allow 必须显式命中。
 */
public func scopeAllows(rule: ScopeRule, normalizedPath: String): Bool {
    for (d in rule.deny) {
        if (globMatch(d, normalizedPath)) {
            return false
        }
    }
    for (a in rule.allow) {
        if (globMatch(a, normalizedPath)) {
            return true
        }
    }
    return false
}

/**
 * glob 匹配：`*` 不跨路径分隔符、`**` 跨分隔符、`?` 匹配**一个码点**（不是一字节——
 * 汉字是 3 字节，按字节吃掉一个会把它切碎）。
 *
 * 按 UTF-8 字节比较（非 ASCII 字节 >= 0x80，与所有 ASCII 元字符都不撞），
 * 所以 `?` 要多吃掉后续的续接字节（0x80-0xBF）才算一个码点。
 */
public func globMatch(pattern: String, target: String): Bool {
    return globMatchAt(foldCase(pattern).toArray(), 0, foldCase(target).toArray(), 0)
}

/** 仅 Windows 折叠大小写（文件系统不区分大小写）；Linux 保持敏感 */
@When[os == "Windows"]
func foldCase(s: String): String {
    return s.toAsciiLower()
}

@When[os == "Linux"]
func foldCase(s: String): String {
    return s
}

private func isContinuationByte(b: UInt8): Bool {
    return (b & 0xC0u8) == 0x80u8
}

private func globMatchAt(p: Array<UInt8>, pi: Int64, t: Array<UInt8>, ti: Int64): Bool {
    var i = pi
    var j = ti
    while (i < p.size) {
        let pc = p[i]
        if (pc == 42u8) {
            // 星号（可能连写 = 跨分隔符的 `**`）
            var k = i
            while (k < p.size && p[k] == 42u8) {
                k++
            }
            let crossSlash = (k - i) >= 2
            if (k >= p.size) {
                // 模式尾部是星号
                if (crossSlash) {
                    return true
                }
                var m = j
                while (m < t.size) {
                    if (t[m] == 47u8) {
                        return false
                    }
                    m++
                }
                return true
            }
            var m = j
            while (m <= t.size) {
                if (globMatchAt(p, k, t, m)) {
                    return true
                }
                if (m >= t.size) {
                    break
                }
                if (!crossSlash && t[m] == 47u8) {
                    break
                }
                m++
            }
            // `**/` 之后那个斜杠是可选的：`/a/**/b` 要能匹配 `/a/b`（零个目录）
            if (crossSlash && p[k] == 47u8) {
                return globMatchAt(p, k + 1, t, j)
            }
            return false
        }
        if (pc == 63u8) {
            // '?'：一个码点，且不吃分隔符
            if (j >= t.size || t[j] == 47u8) {
                return false
            }
            j++
            while (j < t.size && isContinuationByte(t[j])) {
                j++
            }
            i++
            continue
        }
        if (j >= t.size || t[j] != pc) {
            return false
        }
        i++
        j++
    }
    return j == t.size
}

/* ===== 路径处理 ===== */

/**
 * 工作目录的惰性缓存（顶层只放一个 `None` 常量，真正的解析推迟到首次用到 `$CWD`）
 *
 * **为什么不能写成 `let cache = ScopeCwdCache()`**：鸿蒙上框架包由 `InitCJLibrary`
 * 在动态库加载期执行包全局初始化（`cjTauri::package_global_init`），那一刻仓颉堆还没起来；
 * 任何在初始化期做分配的顶层构造器都会让应用当场 SEGV——实测 2026-10-19：
 * 崩溃落在 `[anon:cangjie_heap]`（SEGV_ACCERR / SEGV_MAPERR），调用链是
 * `InitCJLibrary → cangjie_entry::package_global_init → cjTauri::package_global_init`，
 * 窗口起不来、hilog 里连一行我方日志都没有。桌面两平台是静态全链、初始化期建对象没事，
 * 所以这个坑只在鸿蒙的多动态库形态下暴露。
 */
var scopeCwdCache: Option<String> = None

/** 进程工作目录（项目根；`canonicalize(".")` 顺带解决绝对化与软链接） */
public func scopeCwdPath(): String {
    match (scopeCwdCache) {
        case Some(v) => return v
        case None => ()
    }
    var value = "."
    try {
        value = toScopeSlashes(canonicalize(".").toString())
    } catch (e: Exception) {
        let _ = e
    }
    scopeCwdCache = Some(value)
    return value
}

/**
 * 清单模式与目标路径**统一**的反斜杠归一（两平台同一口径，d8014ad 的回归用例锁定）：
 * Windows 的 $HOME 展开出反斜杠路径，不归一就拿它匹配不上正斜杠目标；
 * Linux 侧同样归一——清单是应用作者写的（可能照 Windows 风格写 $CWD\notes），
 * 模式与目标走同一个函数才不会「一边归一了一边没归」造成永远匹配不上。
 * Linux 文件名里真含反斜杠属于 exotic 场景，模式与目标同函数归一后行为仍一致。
 */
func toScopeSlashes(s: String): String {
    return s.replace("\\", "/")
}

/**
 * 展开路径变量：`$HOME` / `$TEMP` / `$CWD`。
 *
 * 认不出的变量**原样保留**（连 `$` 一起留在结果里）——于是模式匹配不上 = 拒。
 * 这是有意的失败方向：拼错变量名只会让规则变严，不会偷偷放行。
 */
public func expandScopeVars(raw: String): String {
    let bytes = raw.toArray()
    var out = ""
    var seg: Int64 = 0
    var i: Int64 = 0
    while (i < bytes.size) {
        if (bytes[i] != 36u8) { // '$'
            i++
            continue
        }
        var j = i + 1
        while (j < bytes.size && isVarNameByte(bytes[j])) {
            j++
        }
        if (j == i + 1) {
            i++
            continue
        }
        out += raw[seg..i]
        let name = raw[(i + 1)..j]
        match (scopeVarValue(name)) {
            case Some(v) => out += v
            case None => out += raw[i..j]
        }
        seg = j
        i = j
    }
    out += raw[seg..raw.size]
    return out
}

private func isVarNameByte(b: UInt8): Bool {
    if (b >= 97u8 && b <= 122u8) {
        return true
    }
    if (b >= 65u8 && b <= 90u8) {
        return true
    }
    if (b >= 48u8 && b <= 57u8) {
        return true
    }
    return b == 95u8
}

func scopeVarValue(name: String): Option<String> {
    if (name == "HOME") {
        return firstEnvOf(["HOME", "USERPROFILE"])
    }
    if (name == "TEMP") {
        return firstEnvOf(["TEMP", "TMPDIR"])
    }
    if (name == "CWD") {
        return Some(scopeCwdPath())
    }
    return None
}

func firstEnvOf(names: Array<String>): Option<String> {
    for (n in names) {
        if (let Some(v) <- getVariable(n)) {
            if (v.size > 0) {
                return Some(v)
            }
        }
    }
    return None
}

/**
 * 规范化路径（scope 模式与页面给的路径走同一个函数，保证两侧口径一致）：
 *  1) 展开变量、统一分隔符；
 *  2) 路径存在 → `std.fs.canonicalize`（绝对化 + 解析软链接；白名单目录里一条指向
 *     别处的软链接也会被照出真身）；
 *  3) 不存在（写新文件、或带星号的模式）→ 词法规范化：绝对化 + 折叠 `.` 与 `..`。
 */
public func normalizeScopePath(raw: String): String {
    let expanded = toScopeSlashes(expandScopeVars(raw))
    try {
        return toScopeSlashes(canonicalize(expanded).toString())
    } catch (e: Exception) {
        let _ = e
        ()
    }
    return lexicalScopePath(expanded)
}

func isScopeAbsolute(p: String): Bool {
    let b = p.toArray()
    if (b.size == 0) {
        return false
    }
    if (b[0] == 47u8) { // '/'
        return true
    }
    // Windows 盘符："X:/"
    if (b.size >= 3 && b[1] == 58u8 && b[2] == 47u8) {
        return isAsciiAlpha(b[0])
    }
    return false
}

private func isAsciiAlpha(b: UInt8): Bool {
    return (b >= 97u8 && b <= 122u8) || (b >= 65u8 && b <= 90u8)
}

/** 文本层面的规范化：不碰文件系统，因此对「还不存在的路径」也成立 */
func lexicalScopePath(p: String): String {
    let abs = if (isScopeAbsolute(p)) {
        p
    } else {
        scopeCwdPath() + "/" + p
    }
    let bytes = abs.toArray()
    var root = ""
    var body = abs
    if (bytes.size > 0 && bytes[0] == 47u8) {
        root = "/"
        body = abs[1..abs.size]
    } else if (bytes.size >= 3 && bytes[1] == 58u8 && isAsciiAlpha(bytes[0])) {
        root = abs[0..2] // "X:"
        body = abs[2..abs.size]
    }
    let b2 = body.toArray()
    let segs = ArrayList<String>()
    var start: Int64 = 0
    var i: Int64 = 0
    while (i <= b2.size) {
        if (i == b2.size || b2[i] == 47u8) {
            let seg = body[start..i]
            if (seg == "..") {
                if (segs.size > 0) {
                    segs.remove(at: segs.size - 1)
                }
            } else if (seg != "." && seg.size > 0) {
                segs.add(seg)
            }
            start = i + 1
        }
        i++
    }
    var out = root
    for (s in segs) {
        if (out.size == 0 || out == "/") {
            out += s
        } else {
            out += "/" + s
        }
    }
    if (out.size == 0) {
        if (root.size > 0) {
            return root
        }
        return "/"
    }
    return out
}
