package music_app

import std.collection.*
import std.env.*
import stdx.encoding.json.*
import cjTauri.*

/**
 * 音乐播放器的命令层：前端 `invoke` 的语义入口 → 后台接口 / 本机收藏库
 *
 * 为什么前端不直接 `fetch` 后台：① 本框架的契约是「前端只经 `window.__CJ_TAURI__` 的
 * invoke / listen / emit」；② 页面是宿主经 `run(html)` 从字符串载入的，来源 opaque
 * （`Origin: null`），靠后台的 CORS 放行属于不该写进业务代码的依赖；③ 走 invoke 才拿得到
 * 本项目的端到端取证通道——每次调用都在 stderr 留一行 `[music]`，实机验证不用开 devtools。
 *
 * 所有**页面可控**的字符串都在这里校验（系统边界）：它们要么拼进 URL、要么落盘、
 * 要么原样提交给后台，不校验就等于把后端变成跳板。
 */

/** 默认每页条数（后台的这三个接口都收 count） */
let MUSIC_PAGE_SIZE = 20

/** 热门榜的 kind：实测后台的 mongo 里**只有这一个**有数据（其余 kind 一律 400 + `mongo: no documents in result`） */
let MUSIC_HOT_KIND = "topWyMusic"

/** 收藏 / 最近播放两个数组的条数上限（页面可控，防一次写入把文件撑爆） */
let MUSIC_FAVORITE_LIMIT = 500
let MUSIC_RECENT_LIMIT = 100

// ---------------------------------------------------------------- 参数读取

/** 从 invoke 参数里读字符串，缺失/类型不对就用 fallback（前端漏传的容错在命令层做） */
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

/** 从 JSON 对象里读字符串字段；缺失 / 类型不对给空串 */
func jsonStringOf(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
        case None => return ""
    }
}

/** 从 JSON 对象里读整数字段；缺失 / 类型不对给 0 */
func jsonIntOf(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case JsonKind.JsFloat => return Int64(v.asFloat().getValue())
                case _ => return 0
            }
        case None => return 0
    }
}

/**
 * 后台响应的业务码 / 提示语
 *
 * 后台（go-zero）的成功/失败都在 HTTP 200 里：`{code, message, data}`。code != 0 是业务失败
 * （实测歌单 kind 不存在时是 400 + `mongo: no documents in result`），响应不是对象则按协议错处理。
 */
func apiCodeOf(resp: JsonValue): Int64 {
    match (resp.kind()) {
        case JsonKind.JsObject => return jsonIntOf(resp.asObject(), "code")
        case _ => throw CommandException("后台响应的格式不对（不是 JSON 对象）")
    }
}

func apiMessageOf(resp: JsonValue): String {
    match (resp.kind()) {
        case JsonKind.JsObject => return jsonStringOf(resp.asObject(), "message")
        case _ => return ""
    }
}

/** 分页：start 夹到 [0, 1000]，count 夹到 [1, max]（页面可控值，命令层是系统边界） */
func pagedArgs(start: Int64, count: Int64, max: Int64): (Int64, Int64) {
    var s = start
    if (s < 0) {
        s = 0
    }
    if (s > 1000) {
        s = 1000
    }
    var c = count
    if (c <= 0) {
        c = MUSIC_PAGE_SIZE
    }
    if (c > max) {
        c = max
    }
    return (s, c)
}

/**
 * sid（网易云歌曲 id）只允许数字
 *
 * sid 是**页面可控**的字符串，而它要拼进查询串（`?id=<sid>`）——不校验就等于给后台开了一个
 * 「任意参数」入口。后台给的 sid 就是纯数字（实测 478671080 / 3397958994），所以只放行数字。
 */
func isSafeSid(sid: String): Bool {
    if (sid.size == 0 || sid.size > 32) {
        return false
    }
    for (b in sid) {   // 迭代 String 得到 UInt8 字节（AGENTS §4）
        if (b < 48u8 || b > 57u8) {
            return false
        }
    }
    return true
}

/** 歌词接口的 kind：后台实测**忽略**该值，但签名要求必填，故只放行字母并给默认 "wy" */
func isSafeLyricKind(kind: String): Bool {
    if (kind.size == 0 || kind.size > 12) {
        return false
    }
    for (b in kind) {
        let lower = b >= 97u8 && b <= 122u8
        let upper = b >= 65u8 && b <= 90u8
        if (!lower && !upper) {
            return false
        }
    }
    return true
}

// ---------------------------------------------------------------- 命令：后台数据

/**
 * `music:hot` —— 热门歌曲：`{start?, count?}` → POST `/api/v1/musicmenus`
 *
 * 后台的 kind 只认 `topWyMusic`（网易热歌榜，实测 `total: 100`），所以命令层不暴露 kind——
 * 让页面能传 kind 只会传出一堆 400。要加别的榜，先确认后台 mongo 里有那个 kind。
 * 返回**原样**交给页面（`data[]` 里就是 `{sid, song, sing, url, cover}`）。
 */
public class MusicHotCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let (start, count) = pagedArgs(argInt(args, "start", 0), argInt(args, "count", MUSIC_PAGE_SIZE), 50)
        var body = JsonObject()
        body.put("kind", JsonString(MUSIC_HOT_KIND))
        body.put("start", JsonInt(start))
        body.put("count", JsonInt(count))
        return musicApiCall("/api/v1/musicmenus", Some(body))
    }
}

/**
 * `music:search` —— 搜索：`{q, start?, count?}` → POST `/api/v1/musicsearch`
 *
 * 实测中文关键词能搜到（`q=周杰伦` → `total: 61`），但**结果里的 `title` 是后台自己的乱码**
 * （后端把查询串按 GBK 解的，回给我们的 `title` 长这样：`�ܽ���的搜索结果`）——
 * 页面因此不显示后台的 title，自己拼「“关键词” 的搜索结果」。这一条已写进 README。
 */
public class MusicSearchCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let q = argString(args, "q", "")
        if (q.size == 0) {
            throw CommandException("请输入搜索关键词")
        }
        if (q.size > 120) {
            throw CommandException("搜索关键词太长（上限 120 字节）")
        }
        let (start, count) = pagedArgs(argInt(args, "start", 0), argInt(args, "count", MUSIC_PAGE_SIZE), 50)
        var body = JsonObject()
        body.put("q", JsonString(q))
        body.put("start", JsonInt(start))
        body.put("count", JsonInt(count))
        return musicApiCall("/api/v1/musicsearch", Some(body))
    }
}

/**
 * `music:menus` —— 后台歌单合集：`{start?, count?}` → GET `/api/v1/getsongmenu`
 *
 * 返回的每个歌单自带 `songs[]`（完整歌曲对象），页面点进去就能直接播——不需要第二条命令。
 */
public class MusicMenusCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let (start, count) = pagedArgs(argInt(args, "start", 0), argInt(args, "count", 10), 30)
        return musicApiCall("/api/v1/getsongmenu?start=${start}&count=${count}", None)
    }
}

/**
 * `music:lyric` —— 同步歌词：`{sid, kind?}` → GET `/api/v1/musicsearchlrc`
 *
 * 与其他命令「原样回后台 JSON」不同，这条**在仓颉侧归一化**：
 *   `{sid, ver, lyric, lines: [{at, text}…], found, message}`
 * 理由是页面只该做「按播放进度高亮」这一件事，而 LRC 的语法边角（`[by:]` 元信息、
 * 一行多时间戳、1/2/3 位小数）在仓颉侧解析一次即可（src/lrc.cj，纯函数），
 * 顺带把 `lines` 的条数打进 stderr，实机验证不必开 devtools 就知道歌词解出几行。
 *
 * **没有歌词不是错误**：后台对没歌词的歌回 `code: 0` + 空 `lyric`
 * （或 `code != 0` + message），两者都返回 `found: false` 让页面显示「暂无歌词」，
 * 不抛异常——抛了页面只能弹一个失败提示，而「这首歌没有歌词」是正常状态。
 */
public class MusicLyricCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let sid = argString(args, "sid", "")
        if (!isSafeSid(sid)) {
            throw CommandException("非法的歌曲 id：\"${sid}\"（只接受数字）")
        }
        let kind = argString(args, "kind", "wy")
        if (!isSafeLyricKind(kind)) {
            throw CommandException("非法的歌词源 kind：\"${kind}\"（只接受字母）")
        }
        let resp = musicApiCall("/api/v1/musicsearchlrc?id=${sid}&kind=${kind}", None)

        var lyricText = ""
        var ver: Int64 = 0
        var message = apiMessageOf(resp)
        var found = false
        let code = apiCodeOf(resp)
        if (code == 0) {
            match (resp.asObject().get("data")) {
                case Some(d) =>
                    match (d.kind()) {
                        case JsonKind.JsObject =>
                            let data = d.asObject()
                            lyricText = jsonStringOf(data, "lyric")
                            ver = jsonIntOf(data, "ver")
                            found = lyricText.size > 0
                        case _ => ()
                    }
                case None => ()
            }
        }

        let lines = ArrayList<JsonValue>()
        if (found) {
            for (line in parseLrc(lyricText)) {
                var item = JsonObject()
                item.put("at", JsonInt(line.at))
                item.put("text", JsonString(line.text))
                lines.add(item)
            }
        }
        var out = JsonObject()
        out.put("sid", JsonString(sid))
        out.put("ver", JsonInt(ver))
        out.put("found", JsonBool(found))
        out.put("message", JsonString(message))
        out.put("lyric", JsonString(lyricText))
        out.put("lines", JsonArray(lines))
        eprintln("[music] lyric sid=${sid} code=${code} found=${found} lines=${lines.size} 原始 ${lyricText.size} 字节")
        return out
    }
}

/**
 * `music:image` —— 取封面：`{url, size?}` → `data:image/…;base64,…`
 *
 * 封面**不能**由页面直连：后台给的图源是防盗链的（详见 src/cover.cj 的实测数据）。
 * `size` 是要的边长（省略或 0 = 原图）：列表缩略图一张 4 KB，原图一张 700 KB，
 * 30 首的榜单按原图取就是 ~21 MB base64——所以列表传 200、大图传 500。
 */
public class MusicImageCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let url = argString(args, "url", "")
        if (url.size == 0) {
            throw CommandException("缺少封面地址")
        }
        let size = clampImageSize(argInt(args, "size", 0))
        return JsonString(fetchCoverDataUrl(url, size))
    }
}

// ---------------------------------------------------------------- 命令：分享与收藏

/**
 * 按字节截断，且**不切断汉字**
 *
 * 给页面可控的字符串做长度夹取时不能直接按字节硬切：UTF-8 的汉字占 3 字节，
 * 从中间切开就得到非法序列。这里从切点往回退掉续接字节（0x80–0xBF）——判据与
 * examples/typing-poem 数汉字用的是同一个（AGENTS §4）。
 */
func clipText(s: String, maxBytes: Int64): String {
    if (s.size <= maxBytes) {
        return s
    }
    let b = bytesOfString(s)
    var end = maxBytes
    while (end > 0 && (b[end] & 0xC0u8) == 0x80u8) {
        end -= 1
    }
    return String.fromUtf8(b[0..end])
}

/**
 * 数组里的一首歌 → 只留后台声明需要的五个字段
 *
 * 页面可控 → 后台，必须先过边界；sid 必须纯数字，不是对象或缺 sid 的条目返回 None
 * （调用方按场景决定「跳过」还是「整单失败」）。
 */
func sanitizedSong(v: JsonValue): Option<JsonObject> {
    match (v.kind()) {
        case JsonKind.JsObject =>
            let o = v.asObject()
            let sid = jsonStringOf(o, "sid")
            if (!isSafeSid(sid)) {
                return None
            }
            var item = JsonObject()
            item.put("sid", JsonString(sid))
            item.put("song", JsonString(clipText(jsonStringOf(o, "song"), 100)))
            item.put("sing", JsonString(clipText(jsonStringOf(o, "sing"), 100)))
            item.put("url", JsonString(clipText(jsonStringOf(o, "url"), 300)))
            item.put("cover", JsonString(clipText(jsonStringOf(o, "cover"), 400)))
            return Some(item)
        case _ => return None
    }
}

/** 是否是 JSON 数组 */
func isArrayValue(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsArray => return true
        case _ => return false
    }
}

/** 数组取前 limit 项、逐项过 sanitizedSong（脏条目直接跳过，别让它带坏整份收藏） */
func clippedSongs(arr: JsonArray, limit: Int64): JsonValue {
    let out = ArrayList<JsonValue>()
    for (i in 0..arr.size()) {
        match (arr.get(i)) {
            case Some(item) =>
                match (sanitizedSong(item)) {
                    case Some(clean) => out.add(clean)
                    case None => ()
                }
            case None => ()
        }
        if (out.size >= limit) {
            break
        }
    }
    return JsonArray(out)
}

/**
 * `music:share` —— 把收藏当歌单提交到后台：`{title, user, email, note?, cover?, songs[]}`
 * → POST `/api/v1/createsongmenu`
 *
 * 本示例里**唯一会写后台数据**的命令，所以校验最严：标题/昵称/邮箱必填且限长，
 * 邮箱必须含 `@`（后台不校验，填错了得当场告诉用户），歌曲数组非空、逐条过 sanitizedSong。
 * 业务失败（`code != 0`）**抛异常**而不是原样返回：提交失败必须让页面的 catch 看见，
 * 同时框架会在 stderr 打一行 `command rejected (music:share): …`（AGENTS §4 那条）。
 */
public class MusicShareCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let title = clipText(trimAsciiText(argString(args, "title", "")), 60)
        if (title.size == 0) {
            throw CommandException("请填写歌单标题")
        }
        let user = clipText(trimAsciiText(argString(args, "user", "")), 40)
        if (user.size == 0) {
            throw CommandException("请填写你的昵称")
        }
        let email = clipText(trimAsciiText(argString(args, "email", "")), 80)
        if (email.size == 0 || !email.contains("@") || email.startsWith("@") || email.endsWith("@")) {
            throw CommandException("请填写正确的邮箱（后台按它归属歌单）")
        }
        let note = clipText(trimAsciiText(argString(args, "note", "")), 200)
        let cover = clipText(argString(args, "cover", ""), 400)

        let rawSongs = match (args.get("songs")) {
            case Some(v) => v
            case None => throw CommandException("收藏是空的，先去收藏几首歌吧")
        }
        if (!isArrayValue(rawSongs)) {
            throw CommandException("songs 必须是数组")
        }
        let arr = rawSongs.asArray()
        let songs = ArrayList<JsonValue>()
        var skipped: Int64 = 0
        for (i in 0..arr.size()) {
            match (arr.get(i)) {
                case Some(item) =>
                    match (sanitizedSong(item)) {
                        case Some(clean) => songs.add(clean)
                        case None => skipped += 1
                    }
                case None => skipped += 1
            }
            if (songs.size >= 100) {
                break
            }
        }
        if (songs.size == 0) {
            throw CommandException("收藏里没有可提交的歌曲（每条都要有合法的 sid）")
        }

        var body = JsonObject()
        body.put("title", JsonString(title))
        body.put("cover", JsonString(cover))
        body.put("user", JsonString(user))
        body.put("email", JsonString(email))
        body.put("note", JsonString(note))
        body.put("songs", JsonArray(songs))

        let resp = musicApiCall("/api/v1/createsongmenu", Some(body))
        let code = apiCodeOf(resp)
        let message = apiMessageOf(resp)
        eprintln("[music] share title=${title} songs=${songs.size} skipped=${skipped} -> code=${code} message=${message}")
        if (code != 0) {
            throw CommandException("分享失败：${message}（后台 code=${code}）")
        }
        return resp
    }
}

/**
 * `fav:get` —— 读本机收藏：`{}` → `{songs, recent, path}`
 *
 * 页面启动时调一次。`path` 一并回给页面，是**取证**用的：收藏明明写盘了却「重启就没了」时，
 * 第一件事是对一下路径（工作目录必须切到项目根，否则写到了别处）。
 */
public class FavGetCommand <: CommandHandler {
    private let store: MusicStore

    public init(store: MusicStore) {
        this.store = store
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let n = this.store.countOf("songs")
        let m = this.store.countOf("recent")
        let p = this.store.pathOf()
        eprintln("[music] fav get: songs=${n} recent=${m} -> ${p}")
        var out = JsonObject()
        out.put("songs", this.store.songs())
        out.put("recent", this.store.recent())
        out.put("path", JsonString(p))
        return out
    }
}

/**
 * `fav:set` —— 写本机收藏：`{songs?, recent?}` → 覆盖对应字段并落盘
 *
 * 只覆盖**传了的**字段（收藏变化时只传 songs、播完一首时只传 recent），省掉「读-改-写」的竞态；
 * 数组超长会被截到上限（页面可控值，命令层是系统边界）。
 */
public class FavSetCommand <: CommandHandler {
    private let store: MusicStore

    public init(store: MusicStore) {
        this.store = store
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var touched: Int64 = 0
        match (args.get("songs")) {
            case Some(v) =>
                if (!isArrayValue(v)) {
                    throw CommandException("songs 必须是数组")
                }
                this.store.setField("songs", clippedSongs(v.asArray(), MUSIC_FAVORITE_LIMIT))
                touched += 1
            case None => ()
        }
        match (args.get("recent")) {
            case Some(v) =>
                if (!isArrayValue(v)) {
                    throw CommandException("recent 必须是数组")
                }
                this.store.setField("recent", clippedSongs(v.asArray(), MUSIC_RECENT_LIMIT))
                touched += 1
            case None => ()
        }
        if (touched == 0) {
            throw CommandException("fav:set 至少要给 songs 或 recent 之一")
        }
        let ok = this.store.save()
        let n = this.store.countOf("songs")
        let m = this.store.countOf("recent")
        let p = this.store.pathOf()
        eprintln("[music] fav set: songs=${n} recent=${m} saved=${ok} -> ${p}")
        var out = JsonObject()
        out.put("ok", JsonBool(ok))
        out.put("songs", JsonInt(n))
        out.put("recent", JsonInt(m))
        out.put("path", JsonString(p))
        return out
    }
}

/**
 * `music:config` —— 运行期配置与自检开关：`{}` → `{apiBase, libraryPath, selfCheck, hotKind, pageSize}`
 *
 * 页面启动时调一次：把「这台机器连的是哪个后台、收藏文件在哪」显示在侧栏底部（截图即可取证），
 * 并按 `selfCheck` 决定要不要跑自动自检。开关走环境变量 `CJ_MUSIC_SELFCHECK=1`，
 * 与 examples/typing-poem 的 `CJ_TYPING_SELFCHECK` 同一套路——自检代码常驻页面里，
 * 但只有带上环境变量才跑（否则每次启动都会自己点一遍界面）。
 */
public class MusicConfigCommand <: CommandHandler {
    private let store: MusicStore

    public init(store: MusicStore) {
        this.store = store
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        /*
         * 自检等级走 `CJ_MUSIC_SELFCHECK`：
         *   0 / 未设 —— 不自检（默认）
         *   1        —— 只读 + 本地写（拉榜单、取封面、播放、歌词同步、收藏落盘）
         *   2        —— 再加一步「分享歌单到后台」（**会往后台写一条数据**，所以不放在 1 里）
         * 这里不引 `Int64.parse`（没在别处用过就不赌它的签名），按字面量认这两档即可。
         */
        var selfCheck = false
        var level: Int64 = 0
        if (let Some(v) <- getVariable("CJ_MUSIC_SELFCHECK")) {
            if (v == "2") {
                level = 2
            } else if (v == "0") {
                level = 0
            } else {
                level = 1
            }
            selfCheck = level >= 1
        }
        var out = JsonObject()
        out.put("apiBase", JsonString(musicApiBase()))
        out.put("libraryPath", JsonString(this.store.pathOf()))
        out.put("selfCheck", JsonBool(selfCheck))
        out.put("selfCheckLevel", JsonInt(level))
        out.put("hotKind", JsonString(MUSIC_HOT_KIND))
        out.put("pageSize", JsonInt(MUSIC_PAGE_SIZE))
        return out
    }
}

/**
 * `music:quit` —— 退出应用：`{}` → true
 *
 * 出面的是**无人值守自检**：页面跑完那一串断言得让应用自己收尾，否则 `run.bat selfcheck`
 * 会一直挂在窗口上（协议与 examples/typing-poem 的 `typing:quit` 同形）。
 * 有人值守时不需要它——关窗口走系统标题栏那条路。
 */
public class MusicQuitCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        eprintln("[music] 页面请求退出（window=${ipc.window}）")
        this.app.quit()
        return JsonBool(true)
    }
}

/**
 * `report` —— 前端把页面侧的结论回传仓颉侧 stderr
 *
 * 与其他示例（hello / movie / typing-poem）同名同形：本项目的实机取证以 stderr 为准，
 * 页面跑在 WebView 里，不开 devtools 就看不见它的结论，这条命令就是那个出口。
 */
public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        eprintln("[frontend] " + argString(args, "line", "(空)"))
        return JsonBool(true)
    }
}
