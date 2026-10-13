package cjTauri.plugins

import cjTauri.*

import std.collection.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*

/**
 * 官方插件 sqlite：SQLite 浏览与查询（只看本地库文件，FFI 直连系统 sqlite3）
 *
 * 设计取舍见 `docs/设计决策记录.md` 的 **D-018**（以插件交付 + FFI 直连第三方库 + 任意 SQL 的边界）。
 * FFI 声明与护栏在 `sqlite_ffi.cj`（同目录：判据仍是 AGENTS §2 的「谁调用谁包内」）。
 *
 * 命令：`sqlite:info` / `tables` / `schema` / `page` / `query` / `exec` / `env`
 * 权限：**不自动放行**。浏览与改库是两件事，所以两个命名集：
 *   `"permissions": ["sqlite:readonly"]` —— info / tables / schema / page / query / env
 *   `"permissions": ["sqlite:default"]`  —— 再多一条 exec（写路径）
 * 路径：`scopeAware()` 为真——页面给的 `path` 一律经 `IpcContext.resolveScopedPath("sqlite", …)` 校验
 *   （命令放行 ≠ 路径放行）；清单没为 sqlite 写 scopes 时框架按旧行为全量放行并提示。
 * 前端：`window.__CJ_TAURI__.sqlite.tables({ path: "sample.db" })`
 *
 * **边界如实（D-018）**：
 *   - 任意 SQL 只对「已授权的那一个库文件」生效；`ATTACH` / `DETACH` / `load_extension()` 按语句拒
 *     （authorizer + 关掉扩展加载），拒了在桥 stderr 留一行 `sqlite denied: …`，不静默。
 *   - 只读命令用 `SQLITE_OPEN_READONLY` 打开（内核级只读，不是我们写的检查）；`exec` 才给写入标志。
 *   - 每命令短连接（开→干活→关），不做连接池 / 会话保持。
 *   - **Windows 侧未验证**：本插件链系统 sqlite3，mingw 侧要自带 DLL，本轮不落地（D-018 第 8 条）。
 */

/** 插件全部命令短名（`permissions()` 的两个集都从这里派生，别再抄第二份） */
public let SQLITE_PLUGIN_COMMANDS: Array<String> = ["info", "tables", "schema", "page", "query",
    "exec", "env"]

/** 只观不控的那些（`readonly` 集）：能跑 SELECT，但拿不到 exec */
let SQLITE_READONLY_COMMANDS: Array<String> = ["info", "tables", "schema", "page", "query", "env"]

/** 单页 / 单次查询最多回投的行数：页面要的是「看一眼」，不是导库 */
let SQLITE_PAGE_MAX: Int64 = 500

/** 单元格文本上限（字节）：超了只给前段并标 truncated——截断要说，同 ② 的口径 */
let SQLITE_TEXT_CELL_LIMIT: Int64 = 65536

/** `tables` 一次最多列多少个对象（正常库远小于这个数，超了如实置 truncated） */
let SQLITE_TABLE_LIMIT: Int64 = 1000

/** 自检 / 夹具库路径交给页面的环境变量名（页面读不到进程环境，只能由宿主转交） */
let SQLITE_ENV_SELFCHECK: String = "CJ_SQLITE_SELFCHECK"
let SQLITE_ENV_FIXTURE: String = "CJ_SQLITE_FIXTURE"

/**
 * `sqlite` 插件：只声明「我提供什么」，放行由应用的 capabilities 决定（RFC §5.3）
 */
public class SqlitePlugin <: Plugin {
    public init() {}

    public func name(): String {
        return "sqlite"
    }

    /** 本插件的 path 参数吃 scope 校验（D-018 第 3 条）：库文件是页面可控路径 */
    public func scopeAware(): Bool {
        return true
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        for (short in SQLITE_PLUGIN_COMMANDS) {
            m.add(short, SqliteCommands())
        }
        return m
    }

    /**
     * 命名权限集：`readonly` 只含只读命令，`default` 是全集。
     * 只浏览库的应用引用 readonly 即可，**写能力不会被顺带打开**；要写必须显式引用 default。
     * 集内写短名，框架自动补成 `sqlite:<短名>`。
     */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let ro = ArrayList<String>()
        for (short in SQLITE_READONLY_COMMANDS) {
            ro.add(short)
        }
        m.add("readonly", ro)
        let all = ArrayList<String>()
        for (short in SQLITE_PLUGIN_COMMANDS) {
            all.add(short)
        }
        m.add("default", all)
        return m
    }

    /** 前端 shim：只挂 `__CJ_TAURI__.sqlite` 一个命名空间，不碰 invoke / listen / emit */
    public func jsShim(): String {
        return "(function () { var t = window.__CJ_TAURI__ || (window.__CJ_TAURI__ = {});" +
            " t.sqlite = {" +
            " info: function (args) { return window.__CJ_TAURI__.invoke('sqlite:info', args); }," +
            " tables: function (args) { return window.__CJ_TAURI__.invoke('sqlite:tables', args); }," +
            " schema: function (args) { return window.__CJ_TAURI__.invoke('sqlite:schema', args); }," +
            " page: function (args) { return window.__CJ_TAURI__.invoke('sqlite:page', args); }," +
            " query: function (args) { return window.__CJ_TAURI__.invoke('sqlite:query', args); }," +
            " exec: function (args) { return window.__CJ_TAURI__.invoke('sqlite:exec', args); }," +
            " env: function (args) { return window.__CJ_TAURI__.invoke('sqlite:env', args); }" +
            " }; })();\n"
    }
}

/**
 * 一次查询的结果。
 *
 * `rows` 是**按类型逐格**的 JSON（D-018 第 7 条：界面要能说清「这格是数字还是文本」），
 * `plain` 是同一批数据的纯文本渲染——插件内部（列名、表名、计数）用它，省得到处拆单元格对象。
 */
class SqliteRows {
    let columns = ArrayList<String>()
    let rows = ArrayList<ArrayList<JsonValue>>()
    let plain = ArrayList<ArrayList<String>>()
    var truncated = false

    func columnIndex(name: String): Int64 {
        for (i in 0..this.columns.size) {
            if (this.columns[i] == name) {
                return i
            }
        }
        return -1
    }

    /** 取某格文本；越界给空串（调用方按位置取值时自己保证下标） */
    func textAt(row: Int64, col: Int64): String {
        if (row < 0 || row >= this.plain.size) {
            return ""
        }
        let r = this.plain[row]
        if (col < 0 || col >= r.size) {
            return ""
        }
        return r[col]
    }
}

/** 表名 / 列名做标识符引用：内部的双引号翻倍（SQL 标准的引用方式），不做字符串插值 */
func sqliteQuoteIdent(name: String): String {
    return "\"" + name.replace("\"", "\"\"") + "\""
}

/**
 * 按 UTF-8 字符边界截到 limit 字节以内。
 * AGENTS §4 的坑：仓颉迭代 String 拿到的是**字节**，直接按字节切会把汉字的 3 字节切一半
 * （切出非法 UTF-8，页面显示成乱码）。所以回退到「不是续字节」的位置再切。
 */
func sqliteClampUtf8(s: String, limit: Int64): String {
    let bytes = s.toArray()
    if (Int64(bytes.size) <= limit) {
        return s
    }
    var end = limit
    while (end > 0 && (bytes[end] & 0xC0u8) == 0x80u8) {
        end = end - 1
    }
    return String.fromUtf8(bytes[0..end])
}

/**
 * 取一格的「按类型」JSON 与纯文本渲染。
 * NULL 不给 value（前端显示成 NULL 而不是空串）；BLOB 只给字节数（同 ②「二进制不往 IPC 里塞」）。
 */
func sqliteReadCell(stmt: CPointer<Unit>, i: Int32): (JsonValue, String) {
    let cell = JsonObject()
    let kind = unsafe { sqlite3_column_type(stmt, i) }
    if (kind == SQLITE_NULL) {
        cell.put("type", JsonString("null"))
        return (cell, "")
    }
    if (kind == SQLITE_INTEGER) {
        let v = unsafe { sqlite3_column_int64(stmt, i) }
        cell.put("type", JsonString("integer"))
        cell.put("value", JsonInt(v))
        return (cell, "${v}")
    }
    if (kind == SQLITE_FLOAT) {
        let v = unsafe { sqlite3_column_double(stmt, i) }
        cell.put("type", JsonString("float"))
        cell.put("value", JsonFloat(v))
        return (cell, "${v}")
    }
    if (kind == SQLITE_BLOB) {
        let n = Int64(unsafe { sqlite3_column_bytes(stmt, i) })
        cell.put("type", JsonString("blob"))
        cell.put("bytes", JsonInt(n))
        return (cell, "<blob ${n} bytes>")
    }
    if (kind != SQLITE_TEXT) {
        // 兜底：SQLite 只有这几种列类型，走到这里说明是将来才有的形态——如实报 unknown，不冒充文本
        cell.put("type", JsonString("unknown"))
        return (cell, "")
    }
    // TEXT：超上限只给前段并标 truncated + 原始字节数
    let text = sqliteCString(unsafe { sqlite3_column_text(stmt, i) })
    let n = Int64(unsafe { sqlite3_column_bytes(stmt, i) })
    cell.put("type", JsonString("text"))
    if (n > SQLITE_TEXT_CELL_LIMIT) {
        cell.put("value", JsonString(sqliteClampUtf8(text, SQLITE_TEXT_CELL_LIMIT)))
        cell.put("bytes", JsonInt(n))
        cell.put("truncated", JsonBool(true))
        return (cell, sqliteClampUtf8(text, SQLITE_TEXT_CELL_LIMIT))
    }
    cell.put("value", JsonString(text))
    return (cell, text)
}

/**
 * 跑一条 SQL 并把结果收下来（最多 maxRows 行，超出置 truncated）。
 *
 * 只预编译**第一条**语句：调试台里写多条时，后面的靠页面再发一次（sqlite3_prepare_v2 就是这个语义）。
 * 语句与 SQL 缓冲的生命周期都在本函数内：缓冲在 prepare 之前分配、finalize 之后才出作用域。
 * 出错抛 `CommandException`（前端拿到可读文案），`finally` 保证语句被 finalize。
 */
func sqliteRunQuery(db: CPointer<Unit>, sql: String, maxRows: Int64): SqliteRows {
    let result = SqliteRows()
    let sqlC = unsafe { LibC.mallocCString(sql) }
    var stmt: CPointer<Unit> = CPointer<Unit>()
    let rc = unsafe { sqlite3_prepare_v2(db, sqlC, -1, inout stmt, CPointer<Unit>()) }
    if (rc != SQLITE_OK) {
        throw CommandException("sqlite: prepare failed: ${sqliteLastError(db)} (rc=${rc})")
    }
    if (stmt.isNull()) {
        throw CommandException("sqlite: empty statement")
    }
    try {
        let nCols = unsafe { sqlite3_column_count(stmt) }
        for (i in 0..nCols) {
            result.columns.add(sqliteCString(unsafe { sqlite3_column_name(stmt, i) }))
        }
        while (true) {
            let stepRc = unsafe { sqlite3_step(stmt) }
            if (stepRc == SQLITE_ROW) {
                if (Int64(result.rows.size) >= maxRows) {
                    result.truncated = true
                    break
                }
                let rowCells = ArrayList<JsonValue>()
                let rowPlain = ArrayList<String>()
                for (i in 0..nCols) {
                    let (cell, plain) = sqliteReadCell(stmt, i)
                    rowCells.add(cell)
                    rowPlain.add(plain)
                }
                result.rows.add(rowCells)
                result.plain.add(rowPlain)
            } else if (stepRc == SQLITE_DONE) {
                break
            } else {
                throw CommandException("sqlite: step failed: ${sqliteLastError(db)} (rc=${stepRc})")
            }
        }
    } finally {
        let _ = unsafe { sqlite3_finalize(stmt) }
    }
    return result
}

/** 取一个整数值（COUNT / PRAGMA 这类单值查询）；不是整数就给 fallback，不猜 */
func sqliteScalarInt(db: CPointer<Unit>, sql: String, fallback: Int64): Int64 {
    let sqlC = unsafe { LibC.mallocCString(sql) }
    var stmt: CPointer<Unit> = CPointer<Unit>()
    let rc = unsafe { sqlite3_prepare_v2(db, sqlC, -1, inout stmt, CPointer<Unit>()) }
    if (rc != SQLITE_OK || stmt.isNull()) {
        return fallback
    }
    var out = fallback
    try {
        if (unsafe { sqlite3_step(stmt) } == SQLITE_ROW) {
            if (unsafe { sqlite3_column_type(stmt, 0) } == SQLITE_INTEGER) {
                out = unsafe { sqlite3_column_int64(stmt, 0) }
            }
        }
    } finally {
        let _ = unsafe { sqlite3_finalize(stmt) }
    }
    return out
}

/** SQL 字符串字面量：单引号翻倍。表名虽已过白名单，仍按字面量正规转义，不靠「反正它安全」 */
func sqliteQuoteLiteral(s: String): String {
    return "'" + s.replace("'", "''") + "'"
}

/**
 * sqlite 插件的命令处理器（七个命令共用一份，按全名分派，与 FsCommands / SystemCommands 同形）
 */
class SqliteCommands <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "sqlite:info" => this.info(args, ipc)
            case "sqlite:tables" => this.tables(args, ipc)
            case "sqlite:schema" => this.schema(args, ipc)
            case "sqlite:page" => this.page(args, ipc)
            case "sqlite:query" => this.query(args, ipc)
            case "sqlite:exec" => this.exec(args, ipc)
            case "sqlite:env" => this.env(args, ipc)
            case _ => throw CommandException("unknown sqlite command: ${cmd}")
        }
    }

    /**
     * 取路径参数并过 scope 校验：越界在**这里**就抛（前端拿到可读错误），
     * 命令体拿到的一定是已经规范化、且落在白名单里的路径。
     */
    private func scopedPath(args: JsonObject, ipc: IpcContext): String {
        return ipc.resolveScopedPath("sqlite", this.requireString(args, "path"))
    }

    /** 取必需的字符串参数；缺失或类型不对时抛业务错误，前端拿到的是可读原文 */
    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => throw CommandException("sqlite: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("sqlite: missing argument \"${key}\"")
        }
    }

    /**
     * 可选整数参数：缺省给 fallback。
     * **给了但不是整数就抛**——静默当缺省会把「页面写错」伪装成「参数没给」，越界分页就白限了。
     */
    private func optionalInt(args: JsonObject, key: String, fallback: Int64): Int64 {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case JsonKind.JsNull => return fallback
                case _ => throw CommandException("sqlite: argument \"${key}\" must be an integer")
            }
            case None => return fallback
        }
    }

    /** 可选字符串参数：缺省给 fallback（空串表示「没写」；给了非字符串就抛） */
    private func optionalString(args: JsonObject, key: String, fallback: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case JsonKind.JsNull => return fallback
                case _ => throw CommandException("sqlite: argument \"${key}\" must be a string")
            }
            case None => return fallback
        }
    }

    /** 可选布尔参数：缺省给 fallback（页面少传一个 desc 不该报错） */
    private func optionalBool(args: JsonObject, key: String, fallback: Bool): Bool {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsBool => return v.asBool().getValue()
                case JsonKind.JsNull => return fallback
                case _ => throw CommandException("sqlite: argument \"${key}\" must be a boolean")
            }
            case None => return fallback
        }
    }

    /**
     * 打开一个**只读**连接（浏览类命令统一走这里）：文件不存在给可读错误，不顺手造一个空库——
     * 「浏览一个不存在的库」和「新建一个空库」是两件事，后者该由 exec 显式做。
     * 只读是内核级的（SQLITE_OPEN_READONLY），不是我们写的检查。
     */
    private func openReadOnly(path: String): CPointer<Unit> {
        if (!exists(path)) {
            throw CommandException("sqlite: no such database file: ${path}")
        }
        return sqliteOpenGuarded(path, true)
    }

    /** 本库里全部表 / 视图名：**表名白名单**——页面给的表名必须在其中，之后一律按标识符引用 */
    private func tableNames(db: CPointer<Unit>): ArrayList<String> {
        let res = sqliteRunQuery(db, "SELECT name FROM sqlite_master WHERE type IN ('table','view') " +
            "AND name NOT LIKE 'sqlite_%' ORDER BY name", SQLITE_TABLE_LIMIT)
        let names = ArrayList<String>()
        for (i in 0..res.rows.size) {
            names.add(res.textAt(i, 0))
        }
        return names
    }

    /** 表名校验：不在白名单里就拒（不把页面给的字符串拼进 SQL） */
    private func requireKnownTable(db: CPointer<Unit>, table: String): String {
        for (name in this.tableNames(db)) {
            if (name == table) {
                return name
            }
        }
        throw CommandException("sqlite: no such table: ${table}")
    }

    /**
     * 一次 PRAGMA table_info 同时给出「页面要的列定义」和「内部用的列名」——
     * page 命令两样都要，查两遍纯属浪费（同一个句柄上再来一轮 prepare/step）。
     */
    private func tableInfo(db: CPointer<Unit>, table: String): (ArrayList<JsonValue>, ArrayList<String>) {
        let res = sqliteRunQuery(db, "PRAGMA table_info(" + sqliteQuoteIdent(table) + ")",
            SQLITE_TABLE_LIMIT)
        let names = ArrayList<String>()
        let cols = ArrayList<JsonValue>()
        let iName = res.columnIndex("name")
        let iType = res.columnIndex("type")
        let iNotNull = res.columnIndex("notnull")
        let iPk = res.columnIndex("pk")
        let iDefault = res.columnIndex("dflt_value")
        for (i in 0..res.rows.size) {
            let o = JsonObject()
            o.put("name", JsonString(res.textAt(i, iName)))
            names.add(res.textAt(i, iName))
            o.put("declType", JsonString(res.textAt(i, iType)))
            o.put("notNull", JsonBool(res.textAt(i, iNotNull) == "1"))
            o.put("pk", JsonBool(res.textAt(i, iPk) != "0"))
            o.put("default", JsonString(res.textAt(i, iDefault)))
            cols.add(o)
        }
        return (cols, names)
    }

    /** 列定义（页面那一面）：只取 JsonArray 用得到的部分 */
    private func columnDefs(db: CPointer<Unit>, table: String): ArrayList<JsonValue> {
        let (cols, _) = this.tableInfo(db, table)
        return cols
    }

    /** 建表原文（sqlite_master.sql）：调试台常要「把结构抄走」，没有就给空串 */
    private func tableSql(db: CPointer<Unit>, table: String): String {
        let res = sqliteRunQuery(db, "SELECT sql FROM sqlite_master WHERE name = " +
            sqliteQuoteLiteral(table), 1)
        return res.textAt(0, 0)
    }

    /** `sqlite:info`：这个库是什么、多大、有几个对象——打开一个库后的第一眼 */
    private func info(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        let db = this.openReadOnly(path)
        try {
            let o = JsonObject()
            o.put("path", JsonString(path))
            o.put("sqliteVersion", JsonString(sqliteLibVersion()))
            o.put("fileBytes", JsonInt(FileInfo(path).size))
            o.put("pageSize", JsonInt(sqliteScalarInt(db, "PRAGMA page_size", -1)))
            o.put("tableCount", JsonInt(sqliteScalarInt(db, "SELECT COUNT(*) FROM sqlite_master " +
                "WHERE type='table' AND name NOT LIKE 'sqlite_%'", -1)))
            o.put("readonly", JsonBool(true))
            o.put("pageMax", JsonInt(SQLITE_PAGE_MAX))
            o.put("cellTextLimit", JsonInt(SQLITE_TEXT_CELL_LIMIT))
            o.put("attachBlocked", JsonBool(true))
            return o
        } finally {
            sqliteCloseQuietly(db)
        }
    }

    /** `sqlite:tables`：表 / 视图清单，附行数与列数（视图行数报 -1：它没有独立行存储，不拿 0 冒充） */
    private func tables(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        let db = this.openReadOnly(path)
        try {
            let res = sqliteRunQuery(db, "SELECT name, type FROM sqlite_master " +
                "WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name",
                SQLITE_TABLE_LIMIT)
            let items = ArrayList<JsonValue>()
            for (i in 0..res.rows.size) {
                let name = res.textAt(i, 0)
                let kind = res.textAt(i, 1)
                let o = JsonObject()
                o.put("name", JsonString(name))
                o.put("kind", JsonString(kind))
                if (kind == "table") {
                    o.put("rows", JsonInt(sqliteScalarInt(db, "SELECT COUNT(*) FROM " +
                        sqliteQuoteIdent(name), -1)))
                } else {
                    o.put("rows", JsonInt(-1))
                }
                o.put("columns", JsonInt(this.columnDefs(db, name).size))
                items.add(o)
            }
            let out = JsonObject()
            out.put("tables", JsonArray(items))
            out.put("truncated", JsonBool(res.truncated))
            return out
        } finally {
            sqliteCloseQuietly(db)
        }
    }

    /** `sqlite:schema`：某张表的列定义 + 索引 + 建表原文（「这张表长什么样」一屏说清） */
    private func schema(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        let want = this.requireString(args, "table")
        let db = this.openReadOnly(path)
        try {
            let table = this.requireKnownTable(db, want)
            let o = JsonObject()
            o.put("table", JsonString(table))
            o.put("columns", JsonArray(this.columnDefs(db, table)))
            o.put("rowCount", JsonInt(sqliteScalarInt(db, "SELECT COUNT(*) FROM " +
                sqliteQuoteIdent(table), -1)))
            let idxRes = sqliteRunQuery(db, "PRAGMA index_list(" + sqliteQuoteIdent(table) + ")",
                SQLITE_TABLE_LIMIT)
            let iName = idxRes.columnIndex("name")
            let iUnique = idxRes.columnIndex("unique")
            let iOrigin = idxRes.columnIndex("origin")
            let idx = ArrayList<JsonValue>()
            for (i in 0..idxRes.rows.size) {
                let io = JsonObject()
                io.put("name", JsonString(idxRes.textAt(i, iName)))
                io.put("unique", JsonBool(idxRes.textAt(i, iUnique) == "1"))
                io.put("origin", JsonString(idxRes.textAt(i, iOrigin)))
                idx.add(io)
            }
            o.put("indexes", JsonArray(idx))
            o.put("sql", JsonString(this.tableSql(db, table)))
            return o
        } finally {
            sqliteCloseQuietly(db)
        }
    }

    /** 单页行数夹紧：页面要多了就夹到上限，回投里带 limitClamped 如实说明（不静默改数） */
    private func clampLimit(want: Int64): Int64 {
        if (want <= 0 || want > SQLITE_PAGE_MAX) {
            return SQLITE_PAGE_MAX
        }
        return want
    }

    /** 名字在不在白名单里（表名 / 列名共用一个判定） */
    private func containsName(names: ArrayList<String>, want: String): Bool {
        for (n in names) {
            if (n == want) {
                return true
            }
        }
        return false
    }

    /** 把行摊平成 JSON 二维数组：行序就是 SQL 给的顺序，不重排（要稳定顺序自己带 ORDER BY） */
    private func rowsToJson(res: SqliteRows): ArrayList<JsonValue> {
        let rows = ArrayList<JsonValue>()
        for (r in res.rows) {
            let arr = ArrayList<JsonValue>()
            for (cell in r) {
                arr.add(cell)
            }
            rows.add(JsonArray(arr))
        }
        return rows
    }

    /**
     * `sqlite:page`：分页取数（浏览表格的正路）。
     * 表名过白名单、排序列过列名白名单、offset / limit 是整数——**页面给的字符串一个都不拼进 SQL**。
     * 没写 ORDER BY 时按 SQLite 给的顺序回，不做「稳定排序」的假承诺（要稳定自己带列名）。
     */
    private func page(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        let want = this.requireString(args, "table")
        let offset = this.optionalInt(args, "offset", 0)
        let wantLimit = this.optionalInt(args, "limit", SQLITE_PAGE_MAX)
        let limit = this.clampLimit(wantLimit)
        let orderBy = this.optionalString(args, "orderBy", "")
        let desc = this.optionalBool(args, "desc", false)
        if (offset < 0) {
            throw CommandException("sqlite: argument \"offset\" must not be negative")
        }
        let db = this.openReadOnly(path)
        try {
            let table = this.requireKnownTable(db, want)
            let (cols, colNames) = this.tableInfo(db, table)
            var sql = "SELECT * FROM " + sqliteQuoteIdent(table)
            if (orderBy != "") {
                if (!this.containsName(colNames, orderBy)) {
                    throw CommandException("sqlite: no such column in ${table}: ${orderBy}")
                }
                sql = sql + " ORDER BY " + sqliteQuoteIdent(orderBy)
                if (desc) {
                    sql = sql + " DESC"
                }
            }
            sql = sql + " LIMIT ${limit} OFFSET ${offset}"
            let res = sqliteRunQuery(db, sql, limit)
            let o = JsonObject()
            o.put("table", JsonString(table))
            o.put("offset", JsonInt(offset))
            o.put("limit", JsonInt(limit))
            o.put("limitClamped", JsonBool(wantLimit != limit))
            o.put("total", JsonInt(sqliteScalarInt(db, "SELECT COUNT(*) FROM " +
                sqliteQuoteIdent(table), -1)))
            o.put("columns", JsonArray(cols))
            o.put("rows", JsonArray(this.rowsToJson(res)))
            o.put("truncated", JsonBool(res.truncated))
            return o
        } finally {
            sqliteCloseQuietly(db)
        }
    }

    /**
     * `sqlite:query`：手写 SQL（调试台的正路）。连接是**只读**的——写语句在这里会以只读错误失败，
     * 要写走 exec：「手滑跑了一条 DELETE」不该发生在一个看数据的界面上（D-018 第 5 条）。
     * 只跑第一条语句（sqlite3_prepare_v2 的语义），多条要分次发。
     */
    private func query(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        let sql = this.requireString(args, "sql")
        let wantLimit = this.optionalInt(args, "limit", SQLITE_PAGE_MAX)
        let limit = this.clampLimit(wantLimit)
        let db = this.openReadOnly(path)
        try {
            let res = sqliteRunQuery(db, sql, limit)
            let cols = ArrayList<JsonValue>()
            for (name in res.columns) {
                let co = JsonObject()
                co.put("name", JsonString(name))
                cols.add(co)
            }
            let o = JsonObject()
            o.put("columns", JsonArray(cols))
            o.put("rows", JsonArray(this.rowsToJson(res)))
            o.put("rowCount", JsonInt(res.rows.size))
            o.put("truncated", JsonBool(res.truncated))
            o.put("limit", JsonInt(limit))
            o.put("limitClamped", JsonBool(wantLimit != limit))
            return o
        } finally {
            sqliteCloseQuietly(db)
        }
    }

    /**
     * `sqlite:exec`：唯一有写能力的一条（`readonly` 权限集里没有它，这也正是分两个集的原因）。
     * 走 sqlite3_exec：库文件不存在时**在这里**显式建（浏览类命令不会顺手造库）。
     * `ATTACH` / `load_extension()` 会被 authorizer 挡下，报错文案是 `not authorized`，
     * 同时桥 stderr 上留一行 `sqlite denied: …`——拒绝必须留痕。
     */
    private func exec(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        let sql = this.requireString(args, "sql")
        let db = sqliteOpenGuarded(path, false)
        try {
            let sqlC = unsafe { LibC.mallocCString(sql) }
            let rc = unsafe {
                sqlite3_exec(db, sqlC, CPointer<Unit>(), CPointer<Unit>(), CPointer<Unit>())
            }
            if (rc != SQLITE_OK) {
                // 被插件护栏挡下的语句给可读文案：页面看到的该是「这条不许跑」而不是一串返回码
                if (rc == SQLITE_AUTH) {
                    throw CommandException("sqlite: exec refused by plugin guard " +
                        "(attach / detach / load_extension are not allowed)")
                }
                throw CommandException("sqlite: exec failed (rc=${rc}): ${sqliteLastError(db)}")
            }
            let o = JsonObject()
            o.put("changes", JsonInt(Int64(unsafe { sqlite3_changes(db) })))
            o.put("lastInsertRowid", JsonInt(unsafe { sqlite3_last_insert_rowid(db) }))
            return o
        } finally {
            sqliteCloseQuietly(db)
        }
    }

    /**
     * `sqlite:env`：把自检开关与本轮夹具库路径交给页面（内联页在 WebView 里，读不到进程环境）。
     * **不绕过 scope**：页面拿到路径后仍要把它当普通 `path` 参数发给别的命令，该过的校验一次不少。
     */
    private func env(args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = args
        let _ = ipc
        let o = JsonObject()
        o.put("selfCheck", JsonBool(this.envOr(SQLITE_ENV_SELFCHECK, "") == "1"))
        o.put("fixture", JsonString(this.envOr(SQLITE_ENV_FIXTURE, "")))
        o.put("cwd", JsonString(scopeCwdPath()))
        o.put("pageMax", JsonInt(SQLITE_PAGE_MAX))
        o.put("cellTextLimit", JsonInt(SQLITE_TEXT_CELL_LIMIT))
        return o
    }

    /** 读环境变量，空串当没设（与 src/app.cj 的 manifestDumpMode 同一口径） */
    private func envOr(name: String, fallback: String): String {
        if (let Some(v) <- getVariable(name)) {
            if (v.size > 0) {
                return v
            }
        }
        return fallback
    }
}
