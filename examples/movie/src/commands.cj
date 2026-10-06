package movie_app

import stdx.encoding.json.*
import cjTauri.*

/**
 * 观影应用的命令层：前端 `invoke` 的语义入口 → 后台接口
 *
 * 为什么前端不直接 `fetch` 后台（后台确实带了 `Access-Control-Allow-Origin: *`）：
 *   1. 本框架的契约是「前端只经 `window.__CJ_TAURI__` 的 invoke / listen / emit」；
 *   2. 页面是宿主经 `start(html)` 载入的，来源是 opaque 的（`Origin: null`），
 *      靠后台的 `*` 才勉强能过——这种依赖不该写进业务代码；
 *   3. 走 invoke 才拿得到本项目的端到端取证通道：每次调用都在 stderr 留一行 `[movie]`，
 *      实机验证不用开 devtools 就能确认「页面点下去 → 仓颉发出去了 → 后台回了什么」。
 */

/** 默认每页条数（后台各接口都收 count） */
let MOVIE_PAGE_SIZE = 20

/** 榜单接口的默认城市（只有 hotmovie 需要） */
let MOVIE_DEFAULT_CITY = "北京"

// ---------------------------------------------------------------- 参数读取

/** 从 invoke 参数里读字符串，缺失/类型不对就用 fallback（不报错，前端漏传的容错在命令层做） */
func argString(args: JsonObject, key: String, fallback: String): String {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return fallback
            }
        case None => return fallback
    }
}

/** 从 invoke 参数里读整数，缺失/类型不对就用 fallback；浮点也收（JS 侧 20.0 这类） */
func argInt(args: JsonObject, key: String, fallback: Int64): Int64 {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case JsonKind.JsFloat => return Int64(v.asFloat().getValue())
                case _ => return fallback
            }
        case None => return fallback
    }
}

/**
 * 分页请求体：`{start, count}`（需要时再加 city）
 *
 * count 夹一层上限：这是页面可控的值，不夹的话一个 `count: 100000` 就能让后台去抓十万条
 * （上游是豆瓣，会拖慢甚至限流）——命令层是系统边界，校验就该在这里。
 */
func pagedBody(start: Int64, count: Int64, city: Option<String>): JsonObject {
    var body = JsonObject()
    body.put("start", JsonInt(if (start < 0) { 0 } else { start }))
    let n = if (count <= 0) { MOVIE_PAGE_SIZE } else if (count > 60) { 60 } else { count }
    body.put("count", JsonInt(n))
    match (city) {
        case Some(c) => body.put("city", JsonString(c))
        case None => ()
    }
    return body
}

/**
 * sid 只允许数字
 *
 * sid 是**页面可控**的字符串，而它要拼进 URL 路径（`/api/v1/mvsource/<sid>`）——
 * 不校验就等于给后台开了一个「任意路径」入口（`../../` 之类）。后台的 sid 就是豆瓣 id 这种
 * 纯数字，所以这里只放行数字，长度也夹一层。
 */
func isSafeSid(sid: String): Bool {
    if (sid.size == 0 || sid.size > 32) {
        return false
    }
    for (cp in sid) {  // 迭代 String 得到 UInt32 码点（AGENTS.md §4）
        if (cp < 48 || cp > 57) {
            return false
        }
    }
    return true
}

/**
 * 源名 note 只允许 `[a-z0-9_-]`，最长 32
 *
 * 与 sid 同样的道理：note 也是页面可控的串，而且它要拼进**查询串**（`?note=<note>`）。
 * 放行集是照后台的真实取值定的（uku / ffzy / jszy 这类拼音源站名）——收窄到不需要
 * 百分号转义的程度，省掉「转义写错就静默换源」这类问题。
 */
func isSafeSourceNote(note: String): Bool {
    if (note.size == 0 || note.size > 32) {
        return false
    }
    for (cp in note) {
        let lower = cp >= 97 && cp <= 122
        let digit = cp >= 48 && cp <= 57
        if (!lower && !digit && cp != 95 && cp != 45) {
            return false
        }
    }
    return true
}

/**
 * 源 id aid：允许空串，非空时只允许数字
 *
 * 空的 aid 是**合法的真实取值**——单文件源（电影）的 `items[].aid` 就是 `""`
 * （实测 阿甘正传 sid=1292720）。后台对「只有 note」的请求按集数最多的源解析，
 * 所以命令层放行空串，拼 URL 时把整个 aid 参数省掉（见 api.cj 的 movieSourceItemPath）。
 */
func isSafeSourceAid(aid: String): Bool {
    if (aid.size == 0) {
        return true
    }
    if (aid.size > 32) {
        return false
    }
    for (cp in aid) {
        if (cp < 48 || cp > 57) {
            return false
        }
    }
    return true
}

// ---------------------------------------------------------------- 命令

/**
 * `movie:list` —— 榜单：`{kind, start?, count?, city?}` → 后台 `/api/v1/<kind>movie`
 *
 * kind 取值 hot / new / soon / top / week / us（README 与页面侧同一份）。
 */
public class MovieListCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let kind = argString(args, "kind", "hot")
        var path = ""
        match (movieListPathOf(kind)) {
            case Some(p) => path = p
            case None => throw CommandException("未知榜单 kind=\"${kind}\"（可选 hot/new/soon/top/week/us）")
        }
        let start = argInt(args, "start", 0)
        let count = argInt(args, "count", MOVIE_PAGE_SIZE)
        let city: Option<String> = if (movieListNeedsCity(kind)) {
            Some(argString(args, "city", MOVIE_DEFAULT_CITY))
        } else {
            None
        }
        return movieApiCall(path, Some(pagedBody(start, count, city)))
    }
}

/**
 * `movie:search` —— 搜索：`{q, start?, count?}` → 后台 `/api/v1/searchmovie`
 *
 * 后端目前对中文关键词一律回 `total: 0`（上游搜索接口不通），页面把空结果当正常态显示，
 * 不当错误——命令层因此不做特殊处理，后台回什么就回什么。
 */
public class MovieSearchCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let q = argString(args, "q", "")
        if (q.size == 0) {
            throw CommandException("请输入搜索关键词")
        }
        var body = pagedBody(argInt(args, "start", 0), argInt(args, "count", MOVIE_PAGE_SIZE), None)
        body.put("q", JsonString(q))
        return movieApiCall("/api/v1/searchmovie", Some(body))
    }
}

/**
 * `movie:detail` —— 详情：`{id}` → 后台 `/api/v1/detailmovie`
 *
 * 返回里的 `images` 是一张封面 URL（字符串，不是数组），`cast` 是演员数组，页面按此渲染。
 */
public class MovieDetailCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let id = argString(args, "id", "")
        if (id.size == 0) {
            throw CommandException("缺少影视 id")
        }
        var body = JsonObject()
        body.put("id", JsonString(id))
        return movieApiCall("/api/v1/detailmovie", Some(body))
    }
}

/**
 * `movie:source` —— 播放资源：`{sid}` → 后台 `GET /api/v1/mvsource/<sid>`
 *
 * 这个接口后台是「现抓上游解析」的，上游不通时它自己回 503（实测：3 秒后返回纯文本
 * `Request Timeout`）。所以页面必须把这里当**可能失败**的通路：失败就显示提示 + 源地址，
 * 而不是把播放器停在一个转圈的 loading 上。
 */
public class MovieSourceCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let sid = argString(args, "sid", "")
        if (!isSafeSid(sid)) {
            throw CommandException("非法的播放源 id：\"${sid}\"（只接受数字）")
        }
        return movieApiCall("/api/v1/mvsource/${sid}", None)
    }
}

/**
 * `movie:sourceitem` —— 切播放源：`{sid, note, aid?}` → 后台 `/api/v1/mvsourceitem/<sid>?note=<note>&aid=<aid>`
 *
 * 后台 2026-10-06 改版把「一个片子的全部播放源」与「某个源的剧集」拆成两个接口：
 *   - `mvsource/<sid>`：只带**主源**（`sources[].primary = true`）的 `tvurls`，另有 20 条源的元信息
 *     （`items[]` 含 note/name/type/aid/count/cover，`sources[]` 是它的精简版）；
 *   - `mvsourceitem/<sid>?note=&aid=`：某个具体源的完整 `tvurls`（按源 1–13KB）。
 * 于是页面上的「播放源」切换必须走这条命令——主源的剧集靠 `movie:source` 就够，别的源只能这么取。
 *
 * 失败形状：源不存在时后台回 **HTTP 200 + `code: 404` + `message: "source not found"`**
 * （实测两次），与「403 业务失败」同类——原样交给页面显示，不在这里抛
 * （理由见 api.cj 的 movieApiCall 注释）。
 */
public class MovieSourceItemCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let sid = argString(args, "sid", "")
        if (!isSafeSid(sid)) {
            throw CommandException("非法的播放源 id：\"${sid}\"（只接受数字）")
        }
        let note = argString(args, "note", "")
        if (!isSafeSourceNote(note)) {
            throw CommandException("非法的源名 note：\"${note}\"（只接受 a-z 0-9 _ -，最长 32）")
        }
        let aid = argString(args, "aid", "")
        if (!isSafeSourceAid(aid)) {
            throw CommandException("非法的源 id aid：\"${aid}\"（只接受数字；单文件源可留空）")
        }
        return movieApiCall(movieSourceItemPath(sid, note, aid), None)
    }
}

/**
 * `movie:image` —— 取封面：`{url}` → `data:image/...;base64,...`
 *
 * 封面**不能**由页面直连：后台给的图源是防盗链的，页面发不出图源要的 Referer
 * （详见 src/api.cj 的 fetchImageDataUrl 注释）。仓颉侧取回来转 base64 交给页面，
 * 顺带把「前端只走 invoke」贯彻到图片上。
 */
public class MovieImageCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let url = argString(args, "url", "")
        if (url.size == 0) {
            throw CommandException("缺少封面地址")
        }
        return JsonString(fetchImageDataUrl(url))
    }
}

/**
 * `report` —— 前端把页面侧的验证结果回传仓颉侧 stderr
 *
 * 与其他示例（hello / menu）同名同形：本项目的实机取证以 stderr 为准，页面跑在 WebView 里，
 * 不开 devtools 就看不见它的结论，这条命令就是那个出口。
 */
public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        eprintln("[frontend] " + argString(args, "line", "(空)"))
        return JsonBool(true)
    }
}
