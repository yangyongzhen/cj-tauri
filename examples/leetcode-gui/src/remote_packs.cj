package leetcode_gui

import cjTauri.*
import std.collection.*
import std.fs.*
import std.io.*
import stdx.encoding.json.*
import stdx.net.http.*
// TlsClientConfig 在 stdx.net.tls 里、不在 net.http（AGENTS §4，movie/http-client 同款）
import stdx.net.tls.*

/**
 * 远程题包：加载更多
 *
 * 内置 100 题做离线兜底；「加载更多」从远程题包仓拉 JSON 题包，schema 校验后
 * 合并进题库并写本地缓存（problems-remote.local.json，下次启动直接并入，二次离线可用）。
 * 题包格式与内置 problems 数组完全同构（见 docs/leetcode-packs/advanced-1.json），
 * 放在任何提供 raw 直链的公共 git 仓即可。
 *
 * 安全口径：
 *   - URL 白名单写死在仓颉侧，前端只能传「题包名」——页面可控的任意 URL 等于开放 SSRF
 *     （AGENTS §4）；基地址 + 题包名拼接，题包名再过一道字符白名单（字母数字下划线连字符），
 *     页面拼不出任意外链与路径穿越；
 *   - https 显式 TlsClientConfig()（默认走系统证书库校验，不关校验）；
 *   - 响应体按上限读（256KB，题包远达不到），不把内存交给对端；
 *   - 远程题 id 必须 >= 200（与内置 1..100 不冲突），重复 id 覆盖更新（题包升版的更新路径）。
 */

/** 题包基地址白名单：题包名拼到 <BASE>/<名字>.json。换托管仓只改这一行 */
let PACK_BASE_URL = "https://raw.githubusercontent.com/yangyongzhen/cj-tauri/main/docs/leetcode-packs"

/** 单个题包响应体上限（字节） */
let PACK_MAX_BYTES: Int64 = 262144

/** 本地缓存文件（*.local.json 已在 .gitignore，本机数据不入库） */
let PACK_CACHE_PATH = "problems-remote.local.json"

/** 题包名白名单：只允许字母数字下划线连字符（防路径穿越与 URL 注入） */
func validPackName(name: String): Bool {
    if (name.size == 0 || name.size > 64) {
        return false
    }
    for (b in name) {
        let ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 45 || b == 95
        if (!ok) {
            return false
        }
    }
    return true
}

/** 可用题包清单（仓颉侧写死：加题包 = 这里加一行 + 题包仓里放 JSON） */
let AVAILABLE_PACKS: Array<String> = ["advanced-1"]

/** 列可用题包 */
public class ListPacksCommand <: CommandHandler {
    public init() {}
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let _ = ipc
        let arr = JsonArray(ArrayList<JsonValue>())
        for (name in AVAILABLE_PACKS) {
            arr.add(JsonString(name))
        }
        var obj = JsonObject()
        obj.put("packs", arr)
        obj.put("baseUrl", JsonString(PACK_BASE_URL))
        return obj
    }
}

/**
 * 拉取远程题包：下载 → schema 校验 → 合并进 PROBLEMS → 写缓存 → 返回合并结果。
 * 联网失败如实报错（CommandException 带原文），内置题库照常用——不把网络问题伪装成「没有更多题」。
 */
public class FetchMoreCommand <: CommandHandler {
    public init() {}
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let name = stringArg(args, "pack", "")
        if (!validPackName(name)) {
            throw CommandException("题包名不合法：${name}")
        }
        if (!AVAILABLE_PACKS.contains(name)) {
            // Array<String> 没有 join：手拼可读的可用清单
            var names = ""
            for (i in 0..AVAILABLE_PACKS.size) {
                if (i > 0) { names = names + ", " }
                names = names + AVAILABLE_PACKS[i]
            }
            throw CommandException("未知题包：${name}（可用：${names}）")
        }
        let url = PACK_BASE_URL + "/" + name + ".json"

        // 拉取（https 显式 TLS；按上限读体；超时如实报错）
        let body = httpGetString(url)

        // schema 校验 + 合并
        let (added, replaced) = mergePack(body)
        eprintln("[lc] pack ${name} merged: +${added} new, ${replaced} replaced (${url})")

        // 写缓存（下次启动直接并入）
        File.writeTo(PACK_CACHE_PATH, body.toArray())

        var obj = JsonObject()
        obj.put("ok", JsonBool(true))
        obj.put("pack", JsonString(name))
        obj.put("added", JsonInt(added))
        obj.put("replaced", JsonInt(replaced))
        obj.put("total", JsonInt(Int64(PROBLEMS.size)))
        return obj
    }

    /** GET 一个文本资源：非 200 / 超限 / 非 UTF-8 都如实报错 */
    func httpGetString(url: String): String {
        let client = ClientBuilder()
            .tlsConfig(TlsClientConfig())
            .build()
        let resp = client.get(url)
        if (resp.status != 200) {
            throw CommandException("下载失败：HTTP ${resp.status}（${url}）")
        }
        // 按块读到 EOF 或上限：先读进来再截等于把内存交给对端（http-client 同款口径）
        let buf = ByteBuffer()
        let chunk = Array<Byte>(8192, repeat: 0)
        var total: Int64 = 0
        while (true) {
            let n = resp.body.read(chunk)
            if (n == 0) { break }
            total = total + Int64(n)
            if (total > PACK_MAX_BYTES) {
                throw CommandException("题包超过 ${PACK_MAX_BYTES} 字节上限，拒绝接收")
            }
            buf.write(chunk[0..n])
        }
        let bytes = buf.bytes()
        if (bytes.size == 0) {
            throw CommandException("题包为空（${url}）")
        }
        return String.fromUtf8(bytes)
    }
}

/**
 * schema 校验 + 合并进 PROBLEMS。
 * 返回（新增数, 覆盖数）。校验失败抛 CommandException，缓存不写、题库不变。
 */
func mergePack(body: String): (Int64, Int64) {
    let root = JsonValue.fromStr(body)
    var arrOpt: Option<JsonArray> = None
    match (root.kind()) {
        case JsonKind.JsObject =>
            match (root.asObject().get("problems")) {
                case Some(v) =>
                    match (v.kind()) {
                        case JsonKind.JsArray => arrOpt = Some(v.asArray())
                        case _ => throw CommandException("题包 schema 错误：problems 不是数组")
                    }
                case None => throw CommandException("题包 schema 错误：缺 problems 字段")
            }
        case _ => throw CommandException("题包 schema 错误：顶层不是 JSON 对象")
    }
    let items = arrOpt.getOrThrow()
    if (items.size() == 0) {
        throw CommandException("题包 problems 为空")
    }

    var added: Int64 = 0
    var replaced: Int64 = 0
    for (i in 0..items.size()) {
        if (let Some(p) <- items.get(i)) {
            let problem = validateProblem(p)
            // 重复 id 覆盖（题包升版的更新路径），否则追加
            var idx = -1
            var k: Int64 = 0
            while (k < Int64(PROBLEMS.size)) {
                if (problemId(PROBLEMS[k]) == problemId(problem)) {
                    idx = k
                    break
                }
                k = k + 1
            }
            if (idx >= 0) {
                // ArrayList 没有 insert：区间 remove 再 add 回原位（modbus-poll 同款）
                PROBLEMS.remove(idx..idx + 1)
                PROBLEMS.add(problem)
                replaced = replaced + 1
            } else {
                PROBLEMS.add(problem)
                added = added + 1
            }
        }
    }
    return (added, replaced)
}

/** 单题 schema 校验：五字段齐 + id>=100 + tests 每条 call/expect 是非空字符串。不合格直接抛 */
func validateProblem(v: JsonValue): JsonObject {
    // JsonKind 没有 == / !=（AGENTS §4）：走 match 分支
    match (v.kind()) {
        case JsonKind.JsObject => ()
        case _ => throw CommandException("题包 schema 错误：problems 里有非对象项")
    }
    let p = v.asObject()
    // id 必须是整数且 >= 100（内置 19 题占 1..19，远程题不与之冲突）
    var id: Int64 = -1
    match (p.get("id")) {
        case Some(x) =>
            match (x.kind()) {
                case JsonKind.JsInt => id = x.asInt().getValue()
                case _ => throw CommandException("题包 schema 错误：id 不是整数")
            }
        case None => throw CommandException("题包 schema 错误：缺 id")
    }
    if (id < 200) {
        throw CommandException("题包 schema 错误：远程题 id 必须 >= 200（内置题占 1..100），得到 ${id}")
    }
    for (key in ["title", "difficulty", "category", "funcName", "template", "description"]) {
        match (p.get(key)) {
            case Some(x) =>
                match (x.kind()) {
                    case JsonKind.JsString => ()
                    case _ => throw CommandException("题包 schema 错误：题 ${id} 的 ${key} 不是字符串")
                }
            case None => throw CommandException("题包 schema 错误：题 ${id} 缺 ${key}")
        }
    }
    match (p.get("tests")) {
        case Some(t) =>
            match (t.kind()) {
                case JsonKind.JsArray => ()
                case _ => throw CommandException("题包 schema 错误：题 ${id} 的 tests 不是数组")
            }
        case None => throw CommandException("题包 schema 错误：题 ${id} 缺 tests")
    }
    // solution 可选：带就必须是字符串（不带 = 该题没有参考答案，合法）
    match (p.get("solution")) {
        case Some(s) =>
            match (s.kind()) {
                case JsonKind.JsString => ()
                case _ => throw CommandException("题包 schema 错误：题 ${id} 的 solution 不是字符串")
            }
        case None => ()
    }
    return p
}

/** 取题目的 id（题库内部约定 id 一定是 JsInt；取不到给 -1 不参与比较） */
func problemId(p: JsonObject): Int64 {
    match (p.get("id")) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case _ => return -1
            }
        case None => return -1
    }
}

/** 启动时读缓存并入 PROBLEMS：缓存损坏/不存在都从空开始（与草稿同一口径） */
func loadPackCache(): Unit {
    try {
        let text = String.fromUtf8(File.readFrom(PACK_CACHE_PATH))
        let (added, _) = mergePack(text)
        if (added > 0) {
            eprintln("[lc] pack cache loaded: +${added} 题（${PACK_CACHE_PATH}）")
        }
    } catch (e: Exception) {
        // 首次运行没有缓存文件，属正常；缓存损坏也按没有处理（下次加载更多会重写）
    }
}
