// NoteStore：cjnote 自研笔记存取（M2）
//
// 取代 fs 插件的三个原因：
//  1. 安全面收口——页面永远不传路径，只传文件名；路径全部由本类内部拼
//     （notes/ + 净化后的名字），路径穿越在入口处就被挡掉，fs scope 降为兜底；
//  2. front-matter 是一等公民——list 直接给 title（列表显示标题而不是文件名），
//     open 把正文与元数据拆开给，save 回写时保留原有 front-matter；
//  3. 命令面是业务语义（note:open 而不是 fs:readText）——前端代码可读，将来
//     加锁定/历史/同步都在这一层长，不动 fs 插件。

package cjnote

import cjTauri.*
import std.collection.*
import std.fs.*
import std.time.*
import stdx.encoding.json.*

/** 绝对路径：给 AI 的「当前笔记」指针必须是**绝对**的——cjh 的 read_file 对它自己的相对路径是按
    **它当时的工作区**解析的，而那个工作区可能是别的应用设的（实测：ai-chat 先起的 cjh 指向
    examples/ai-chat/target），相对路径会静默指到别的目录去。canonicalize 顺带解析软链（与框架
    scope 同口径）；失败原样返回，不假装成功。 */
func absOf(rel: String): String {
    try {
        return canonicalize(rel).toString()
    } catch (e: Exception) {
        let _ = e
        return rel
    }
}

/** 仓颉 trimAscii 是 cjh 自有（std 没有）：自写一个（AGENTS §4 知识库结论） */
func trimMd(s: String): String {
    let b = s.toArray()
    var start: Int64 = 0
    var end = b.size
    while (start < end && (b[start] == UInt8(32) || b[start] == UInt8(9) || b[start] == UInt8(13) || b[start] == UInt8(10))) {
        start++
    }
    while (end > start && (b[end - 1] == UInt8(32) || b[end - 1] == UInt8(9) || b[end - 1] == UInt8(13) || b[end - 1] == UInt8(10))) {
        end--
    }
    if (start >= end) {
        return ""
    }
    return String.fromUtf8(b[start..end])
}

public class NoteStore {
    private let dir: String

    public init(dir: String) {
        this.dir = dir
    }

    // ── 文件名净化：唯一入口，所有路径经这里 ──

    /** 净化文件名：只留白名单字符（中文/字母/数字/空格/._-），掐掉路径分隔与穿越，
        强制 .md 后缀。返回 None = 名字非法。 */
    func sanitizeName(raw: String): Option<String> {
        let name = trimMd(raw)
        if (name.size == 0 || name.size > 120) {
            return Option<String>.None
        }
        let b = name.toArray()
        var out = ArrayList<Byte>()
        var i: Int64 = 0
        while (i < b.size) {
            let c = b[i]
            // 白名单：数字 / 大写 / 小写 / 空格 / . _ -；UTF-8 多字节（>= 0x80，中文名）原样过
            if ((c >= UInt8(48) && c <= UInt8(57)) || (c >= UInt8(65) && c <= UInt8(90)) ||
                (c >= UInt8(97) && c <= UInt8(122)) || c == UInt8(32) || c == UInt8(46) ||
                c == UInt8(95) || c == UInt8(45) || c >= UInt8(128)) {
                out.add(c)
            } else {
                return Option<String>.None  // / \ : 等——直接拒，不做替换（替换会误导用户）
            }
            i++
        }
        var clean = String.fromUtf8(out.toArray())
        // 掐路径片段与穿越：任何形式的路径分隔都不该到了这一步还活着（上面已拒 / \），
        // 这里再兜两道：不落在 .md 后缀、整名是点（"." / ".."）
        if (clean == "." || clean == ".." || !clean.endsWith(".md")) {
            return Option<String>.None
        }
        // ".md" ".hidden.md" 这类以点开头的隐藏文件也不给
        if (clean.startsWith(".")) {
            return Option<String>.None
        }
        return Option<String>.Some(clean)
    }

    func notePath(name: String): String {
        return this.dir + "/" + name
    }

    // ── front-matter 解析（轻量：只认 title/tags/desc 三键 + --- 围栏） ──

    /** 拆 front-matter：返回 (metaJson, body)。无围栏时 meta 为空对象、body 原文。 */
    func splitFrontMatter(text: String): (JsonObject, String) {
        let meta = JsonObject()
        let b = text.toArray()
        // 第一行必须是 ---（允许 BOM 后跟 ---）
        var p: Int64 = 0
        if (b.size >= 3 && b[0] == UInt8(0xEF) && b[1] == UInt8(0xBB) && b[2] == UInt8(0xBF)) {
            p = 3
        }
        var lineEnd = p
        while (lineEnd < b.size && b[lineEnd] != UInt8(10)) {
            lineEnd++
        }
        let firstLine = trimMd(String.fromUtf8(b[p..lineEnd]))
        if (firstLine != "---") {
            return (meta, text)
        }
        // 找收尾 ---（逐行扫）
        var q = lineEnd + 1
        var closeLine = -1
        while (q < b.size) {
            var e2 = q
            while (e2 < b.size && b[e2] != UInt8(10)) {
                e2++
            }
            let line = trimMd(String.fromUtf8(b[q..e2]))
            if (line == "---") {
                closeLine = q
                break
            }
            q = e2 + 1
        }
        if (closeLine < 0) {
            return (meta, text)  // 只有开头围栏没有收尾：当无 front-matter（正文原样）
        }
        // 逐键解析围栏内
        var r = lineEnd + 1
        while (r < closeLine) {
            var e2 = r
            while (e2 < b.size && b[e2] != UInt8(10)) {
                e2++
            }
            let line = String.fromUtf8(b[r..e2])
            let idxOpt = line.indexOf(":")
            if (let Some(idx) <- idxOpt) {
                let key = trimMd(line[0..idx])
                let value = trimMd(line[idx + 1..line.size])
                if (key == "title") {
                    meta.put("title", JsonString(value))
                } else if (key == "tags") {
                    meta.put("tags", JsonString(value))
                } else if (key == "desc") {
                    meta.put("desc", JsonString(value))
                }
            }
            r = e2 + 1
        }
        // body = 收尾 --- 之后的全部（去一个紧跟的换行）
        var bodyStart = closeLine
        while (bodyStart < b.size && b[bodyStart] != UInt8(10)) {
            bodyStart++
        }
        bodyStart++  // 吃掉收尾行自己的换行
        if (bodyStart < b.size && b[bodyStart] == UInt8(10)) {
            bodyStart++  // 围栏后空行吃一个
        }
        return (meta, String.fromUtf8(b[bodyStart..b.size]))
    }

    /** 序列化回 front-matter（meta 有 title 才写围栏；tags/desc 空则跳过） */
    func joinFrontMatter(meta: JsonObject, body: String): String {
        var hasAny = false
        var sb = StringBuilder("---\n")
        if (let Some(v) <- meta.get("title")) {
            match (v.kind()) {
                case JsonKind.JsString =>
                    let s = v.asString().getValue()
                    if (s.size > 0) {
                        sb.append("title: " + s + "\n")
                        hasAny = true
                    }
                case _ => ()
            }
        }
        if (let Some(v) <- meta.get("tags")) {
            match (v.kind()) {
                case JsonKind.JsString =>
                    let s = v.asString().getValue()
                    if (s.size > 0) {
                        sb.append("tags: " + s + "\n")
                        hasAny = true
                    }
                case _ => ()
            }
        }
        if (let Some(v) <- meta.get("desc")) {
            match (v.kind()) {
                case JsonKind.JsString =>
                    let s = v.asString().getValue()
                    if (s.size > 0) {
                        sb.append("desc: " + s + "\n")
                        hasAny = true
                    }
                case _ => ()
            }
        }
        sb.append("---\n\n")
        if (!hasAny) {
            return body  // 三个键全空：不写围栏，正文原样
        }
        sb.append(body)
        return sb.toString()
    }

    /** 从正文首行抽 title 兜底（# 开头）：list/open 无 front-matter title 时用 */
    func titleFromBody(body: String): String {
        let lines = body.split("\n", -1)
        for (line in lines) {
            let t = trimMd(line)
            if (t.size == 0) {
                continue
            }
            if (t.startsWith("# ")) {
                return trimMd(t[2..t.size])
            }
            return t  // 第一个非空行（不管 #）：截断当标题
        }
        return ""
    }

    // ── 命令实现 ──

    /** note:search：全库关键词检索（标题+正文，大小写敏感的朴素 contains——
        中文场景大小写折叠意义有限，先朴素实现，索引/分词留给 M5 的 sqlite FTS）。
        返回前 8 条命中：{notes:[{name,title,snippet}]}，snippet 截命中处前后各 40 字。 */
    public func search(query: String): JsonValue {
        let out = JsonObject()
        let arr = JsonArray()
        let q = trimMd(query)
        if (q.size == 0) {
            out.put("notes", arr)
            return out
        }
        try {
            let entries = Directory.readFrom(this.dir)
            var names = ArrayList<String>()
            for (info in entries) {
                if (!info.isDirectory() && info.name.endsWith(".md") && !info.name.startsWith(".")) {
                    names.add(info.name)
                }
            }
            // 插入排序（同 list()：本机 cjc 不支持 std.sort 限定名，sortBy 已弃用）
            var si: Int64 = 1
            while (si < names.size) {
                var sj = si
                let cur = names[si]
                while (sj > 0 && names[sj - 1] > cur) {
                    names[sj] = names[sj - 1]
                    sj--
                }
                names[sj] = cur
                si++
            }
            for (name in names) {
                var text = ""
                try {
                    text = String.fromUtf8(File.readFrom(this.notePath(name)))
                } catch (e: Exception) {
                    let _ = e
                    continue  // 读不了的单个文件跳过，不拖垮整个检索
                }
                let (meta, body) = this.splitFrontMatter(text)
                var title = ""
                if (let Some(t) <- meta.get("title")) {
                    match (t.kind()) {
                        case JsonKind.JsString =>
                            let s = t.asString().getValue()
                            if (s.size > 0) {
                                title = s
                            }
                        case _ => ()
                    }
                }
                if (title.size == 0) {
                    title = this.titleFromBody(body)
                }
                if (title.size == 0) {
                    title = name
                }
                // 标题或正文命中都算；正文里找第一处，截前后文各 40 字
                var snippet = ""
                let idxOpt = body.indexOf(q)
                if (let Some(idx) <- idxOpt) {
                    let bb = body.toArray()
                    var st = idx - 40
                    if (st < 0) {
                        st = 0
                    }
                    var en = idx + q.size + 40
                    if (en > bb.size) {
                        en = bb.size
                    }
                    snippet = String.fromUtf8(bb[st..en])
                } else if (title.contains(q)) {
                    snippet = body  // 标题命中：正文开头当片段
                    if (snippet.size > 80) {
                        snippet = String.fromUtf8(snippet.toArray()[0..80])
                    }
                } else {
                    continue  // 两处都不中：不进结果
                }
                let item = JsonObject()
                item.put("name", JsonString(name))
                item.put("title", JsonString(title))
                item.put("snippet", JsonString(snippet))
                arr.add(item)
                if (arr.size() >= 8) {
                    break
                }
            }
        } catch (e: Exception) {
            eprintln("[cjnote] note:search 读目录失败：${e}")
        }
        out.put("notes", arr)
        return out
    }

    /** note:list：扫目录 .md，标题 = front-matter title > 正文首行 # > 文件名 */
    public func list(): JsonValue {
        let out = JsonObject()
        let arr = JsonArray()
        try {
            let entries = Directory.readFrom(this.dir)
            // 排序后再输出（Directory.readFrom 顺序不保证）
            var names = ArrayList<String>()
            var mtimes = HashMap<String, String>()
            for (info in entries) {
                if (!info.isDirectory()) {
                    names.add(info.name)
                    // mtime 给 ISO 字符串（DateTime.toString）：前端 Date.parse 转数值排序；
                    // 单个文件 stat 失败不拖垮整个列表（缺失 = 按最旧处理）
                    try {
                        mtimes.add(info.name, info.lastModificationTime.toString())
                    } catch (e: Exception) {
                        let _ = e
                    }
                }
            }
            // 简单插入排序（数量小）
            var i: Int64 = 1
            while (i < names.size) {
                var j = i
                let cur = names[i]
                while (j > 0 && names[j - 1] > cur) {
                    names[j] = names[j - 1]
                    j--
                }
                names[j] = cur
                i++
            }
            for (name in names) {
                if (!name.endsWith(".md") || name.startsWith(".")) {
                    continue
                }
                let item = JsonObject()
                item.put("name", JsonString(name))
                if (let Some(m) <- mtimes.get(name)) {
                    item.put("mtime", JsonString(m))
                }
                var title = ""
                try {
                    let text = String.fromUtf8(File.readFrom(this.notePath(name)))
                    let (meta, body) = this.splitFrontMatter(text)
                    if (let Some(t) <- meta.get("title")) {
                        match (t.kind()) {
                            case JsonKind.JsString =>
                                let s = t.asString().getValue()
                                if (s.size > 0) {
                                    title = s
                                }
                            case _ => ()
                        }
                    }
                    if (title.size == 0) {
                        title = this.titleFromBody(body)
                    }
                } catch (e: Exception) {
                    let _ = e  // 读不了的单个文件：标题留空，不拖垮整个列表
                }
                if (title.size == 0) {
                    title = name
                }
                item.put("title", JsonString(title))
                arr.add(item)
            }
        } catch (e: Exception) {
            eprintln("[cjnote] note:list 读目录失败（${this.dir}）：${e}")
        }
        out.put("notes", arr)
        // 笔记库根目录（绝对）：页面的 AI 指针要用它——AI 要自己在库里找东西时得知道库在哪，
        // 而 cjh 的相对路径按它自己的工作区解析，只有绝对路径靠得住（见 absOf 注释）
        out.put("root", JsonString(absOf(this.dir)))
        return out
    }

    /** note:open：按名读，拆 front-matter 给 {name,title,body,tags,desc} */
    public func open(rawName: String): JsonValue {
        let name = match (this.sanitizeName(rawName)) {
            case Some(n) => n
            case None => throw CommandException("note: 文件名不合法（只允许中文/字母/数字/空格/._-，且以 .md 结尾）")
        }
        let text = String.fromUtf8(File.readFrom(this.notePath(name)))
        let (meta, body) = this.splitFrontMatter(text)
        let out = JsonObject()
        out.put("name", JsonString(name))
        var title = ""
        if (let Some(t) <- meta.get("title")) {
            match (t.kind()) {
                case JsonKind.JsString =>
                    let s = t.asString().getValue()
                    if (s.size > 0) {
                        title = s
                    }
                case _ => ()
            }
        }
        if (title.size == 0) {
            title = this.titleFromBody(body)
        }
        out.put("title", JsonString(title))
        out.put("body", JsonString(body))
        if (let Some(t) <- meta.get("tags")) {
            out.put("tags", t)
        }
        if (let Some(t) <- meta.get("desc")) {
            out.put("desc", t)
        }
        // 本笔记的绝对路径：页面随问题附给 AI 当「我正在看哪篇」，正文由 AI 自己 read_file 取
        out.put("path", JsonString(absOf(this.notePath(name))))
        return out
    }

    /** note:save：净化名字 + 保留 front-matter 回写（meta 来自旧文件，title 可被参数覆盖） */
    public func save(rawName: String, body: String, newTitle: Option<String>): JsonValue {
        let name = match (this.sanitizeName(rawName)) {
            case Some(n) => n
            case None => throw CommandException("note: 文件名不合法")
        }
        let path = this.notePath(name)
        // 旧文件的 front-matter 先读出来（保留 tags/desc）；title 按参数决定是否覆盖
        var meta = JsonObject()
        if (exists(path)) {
            let old = String.fromUtf8(File.readFrom(path))
            let (m, _) = this.splitFrontMatter(old)
            meta = m
        }
        if (let Some(t) <- newTitle) {
            if (t.size > 0) {
                meta.put("title", JsonString(t))
            }
        }
        let full = this.joinFrontMatter(meta, body)
        File.writeTo(path, full.toArray())
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("name", JsonString(name))
        return out
    }

    /** note:create：服务端起名（时间戳 + 查重），返回净化后的名字 */
    public func create(title: String): JsonValue {
        var base = ""
        if (title.size > 0) {
            // 标题当文件名基底：净化后去 .md 再用；非法就退时间戳
            match (this.sanitizeName(title + ".md")) {
                case Some(n) => base = n[0..n.size - 3]
                case None => base = ""
            }
        }
        if (base.size == 0) {
            // ISO 形如 2026-10-18T…，取前 10 位当日期（绕开 monthValue 弃用警告）
            let iso = DateTime.now().toString()
            base = "笔记-" + iso[0..10]
        }
        var name = base + ".md"
        var i: Int64 = 2
        while (exists(this.notePath(name))) {
            name = base + "-" + i.toString() + ".md"
            i++
        }
        // 初始内容：标题行（title 参数有值就用它，否则用文件名去后缀）
        var head = title
        if (head.size == 0) {
            head = base
        }
        let content = "# " + head + "\n\n"
        File.writeTo(this.notePath(name), content.toArray())
        let out = JsonObject()
        out.put("name", JsonString(name))
        return out
    }

    /** note:delete：删除前确认由前端做；这里只管净化 + 删 */
    public func delete(rawName: String): JsonValue {
        let name = match (this.sanitizeName(rawName)) {
            case Some(n) => n
            case None => throw CommandException("note: 文件名不合法")
        }
        let path = this.notePath(name)
        if (!exists(path)) {
            throw CommandException("note: 文件不存在：${name}")
        }
        remove(path)
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        return out
    }

    /** note:rename：真重命名（std.fs.rename 保留 mtime，「按修改时间」排序不跳位）；
        目标名已存在直接拒（overwrite 不开）——静默覆盖另一篇笔记是笔记应用最不可饶恕的错 */
    public func renameNote(rawName: String, newNameRaw: String): JsonValue {
        let name = match (this.sanitizeName(rawName)) {
            case Some(n) => n
            case None => throw CommandException("note: 文件名不合法")
        }
        let newName = match (this.sanitizeName(newNameRaw)) {
            case Some(n) => n
            case None => throw CommandException("note: 新文件名不合法（只允许中文/字母/数字/空格/._-，且以 .md 结尾）")
        }
        let oldPath = this.notePath(name)
        let newPath = this.notePath(newName)
        if (!exists(oldPath)) {
            throw CommandException("note: 文件不存在：${name}")
        }
        if (exists(newPath)) {
            throw CommandException("note: 目标文件名已存在：${newName}")
        }
        try {
            rename(oldPath, to: newPath)
        } catch (e: Exception) {
            throw CommandException("note: 重命名失败：${e}")
        }
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("name", JsonString(newName))
        return out
    }
}

// ── CommandHandler 适配（5 个命令共用一个 handler 类，按 cmd 名分流） ──

public class NoteCommands <: CommandHandler {
    private let store: NoteStore

    public init(store: NoteStore) {
        this.store = store
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = ipc
        if (cmd == "note:list") {
            return this.store.list()
        }
        if (cmd == "note:search") {
            return this.store.search(this.requireStr(args, "query"))
        }
        if (cmd == "note:open") {
            return this.store.open(this.requireStr(args, "name"))
        }
        if (cmd == "note:save") {
            var titleOpt = Option<String>.None
            if (let Some(t) <- args.get("title")) {
                match (t.kind()) {
                    case JsonKind.JsString =>
                        let s = t.asString().getValue()
                        if (s.size > 0) {
                            titleOpt = Option<String>.Some(s)
                        }
                    case _ => ()
                }
            }
            return this.store.save(this.requireStr(args, "name"), this.requireStr(args, "body"), titleOpt)
        }
        if (cmd == "note:create") {
            var title = ""
            if (let Some(t) <- args.get("title")) {
                match (t.kind()) {
                    case JsonKind.JsString => title = t.asString().getValue()
                    case _ => ()
                }
            }
            return this.store.create(title)
        }
        if (cmd == "note:delete") {
            return this.store.delete(this.requireStr(args, "name"))
        }
        if (cmd == "note:rename") {
            return this.store.renameNote(this.requireStr(args, "name"), this.requireStr(args, "newName"))
        }
        throw CommandException("note: unknown command ${cmd}")
    }

    func requireStr(args: JsonObject, key: String): String {
        if (let Some(v) <- args.get(key)) {
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => throw CommandException("note: 参数 ${key} 必须是字符串")
            }
        }
        throw CommandException("note: 缺参数 \"${key}\"")
    }
}
