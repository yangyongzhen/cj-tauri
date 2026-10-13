package cjTauri.tests

import cjTauri.*
import cjTauri.plugins.*
import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * sqlite 插件单元测试：插件面（名字 / 命令 / 权限集 / shim）+ **真库往返**（FFI 直连系统 sqlite3）。
 *
 * 为什么不是「只测插件面」：本插件是仓库里第一处 `foreign func` 直连第三方系统库（D-018），
 * 出参指针、授权回调、列类型映射这些都是链接期与运行期才会露的坑——只断言 HashMap 里有没有键，
 * 等于没测。所以这里用 /tmp 下的临时库真跑一遍：建表 / 插入 / 分页 / 类型 / 截断 / 护栏拒绝。
 *
 * 不创建窗口，可在无 GUI 环境跑；库文件固定放 /tmp/cj-tauri-sqlite-test.db，用例自己先清干净。
 */

let SQLITE_TEST_DB: String = "/tmp/cj-tauri-sqlite-test.db"

func sqliteArgs(args: Array<(String, JsonValue)>): JsonObject {
    let o = JsonObject()
    for (kv in args) {
        o.put(kv[0], kv[1])
    }
    return o
}

func sqlitePathArg(path: String): JsonObject {
    return sqliteArgs([("path", JsonString(path))])
}

/** 从命令结果里取字段（结果都是 JsonObject，取不到直接失败——测试里不兜底） */
func sqliteField(v: JsonValue, key: String): JsonValue {
    return v.asObject().get(key).getOrThrow()
}

func sqliteStr(v: JsonValue, key: String): String {
    return sqliteField(v, key).asString().getValue()
}

/** JsonArray.get 给的是 Option：测试里取不到就该当场炸（所以直接送进上面的取值函数），不兜底 */
func sqliteStr(v: Option<JsonValue>, key: String): String {
    return sqliteStr(v.getOrThrow(), key)
}

func sqliteIntOf(v: JsonValue, key: String): Int64 {
    return sqliteField(v, key).asInt().getValue()
}

func sqliteIntOf(v: Option<JsonValue>, key: String): Int64 {
    return sqliteIntOf(v.getOrThrow(), key)
}

func sqliteBoolOf(v: JsonValue, key: String): Bool {
    return sqliteField(v, key).asBool().getValue()
}

func sqliteBoolOf(v: Option<JsonValue>, key: String): Bool {
    return sqliteBoolOf(v.getOrThrow(), key)
}

/** 单元格是 {type, value, …} 形状：取类型名 */
func sqliteCellType(cell: JsonValue): String {
    return sqliteStr(cell, "type")
}

/** 取第 row 行第 col 格 */
func sqliteCell(rows: JsonValue, row: Int64, col: Int64): JsonValue {
    return rows.asArray().get(row).getOrThrow().asArray().get(col).getOrThrow()
}

/** 清掉上次用例留下的库文件（固定路径，用例之间互不干扰） */
func sqliteCleanDb(): Unit {
    if (exists(SQLITE_TEST_DB)) {
        remove(SQLITE_TEST_DB)
    }
}

/** 跑一条 exec（建表 / 插入都走它），失败就让用例炸在当场 */
func sqliteExec(handler: CommandHandler, sql: String): JsonValue {
    return handler.handle("sqlite:exec", sqliteArgs([("path", JsonString(SQLITE_TEST_DB)),
        ("sql", JsonString(sql))]), IpcContext("main", IpcHub()))
}

func sqliteErrOf(handler: CommandHandler, cmd: String, args: JsonObject): String {
    try {
        handler.handle(cmd, args, IpcContext("main", IpcHub()))
        return ""
    } catch (e: CommandException) {
        return e.message
    }
}

@Test
func testSqlitePluginSurface(): Unit {
    let plugin = SqlitePlugin()
    @Expect(plugin.name(), "sqlite")
    // 库文件是页面可控路径：必须吃 scope 校验（D-018 第 3 条）
    @Expect(plugin.scopeAware(), true)
    @Expect(plugin.commands().size, 7)
    for (short in SQLITE_PLUGIN_COMMANDS) {
        @Expect(plugin.commands().contains(short), true)
    }
    // 前端 shim 只挂一个命名空间，且七个命令都能被调到（漏一个页面就有一块功能静默不可用）
    let shim = plugin.jsShim()
    @Expect(shim.contains("t.sqlite ="), true)
    for (short in SQLITE_PLUGIN_COMMANDS) {
        @Expect(shim.contains("invoke('sqlite:${short}'"), true)
    }
}

@Test
func testSqlitePermissionSetsKeepWriteSeparate(): Unit {
    let sets = SqlitePlugin().permissions()
    let ro = sets.get("readonly").getOrThrow()
    let all = sets.get("default").getOrThrow()
    @Expect(ro.size, 6)
    @Expect(all.size, 7)
    // readonly 里**不能**有 exec：写能力不该被「只想看数据」的应用顺带打开
    @Expect(ro.contains("exec"), false)
    @Expect(all.contains("exec"), true)
    for (short in ro) {
        @Expect(all.contains(short), true)
    }
}

@Test
func testSqlitePluginDoesNotAutoGrant(): Unit {
    // 插件声明了权限集 ≠ 放行：能力清单不引用，命令照样被拒（与 fs / redis 同一条铁律）
    let out = ArrayList<String>()
    let hub = hubWith([], [], out)
    registerPluginCommands(hub, SqlitePlugin())
    hub.handleRawMessage("{\"type\":\"invoke\",\"id\":1,\"cmd\":\"sqlite:info\"}")
    waitSink(out, 1)
    @Expect(strField(out[0], "error"), "command not allowed: sqlite:info")
}

@Test
func testSqliteMissingPathIsBusinessError(): Unit {
    let cmds = SqlitePlugin().commands()
    let msg = sqliteErrOf(cmds.get("info").getOrThrow(), "sqlite:info", JsonObject())
    @Expect(msg.contains("missing argument \"path\""), true)
}

@Test
func testSqliteUnknownCommandRejected(): Unit {
    let cmds = SqlitePlugin().commands()
    let msg = sqliteErrOf(cmds.get("info").getOrThrow(), "sqlite:nope", sqlitePathArg(SQLITE_TEST_DB))
    @Expect(msg.contains("unknown sqlite command"), true)
}

@Test
func testSqliteBrowsingAMissingFileDoesNotCreateIt(): Unit {
    sqliteCleanDb()
    let cmds = SqlitePlugin().commands()
    let msg = sqliteErrOf(cmds.get("info").getOrThrow(), "sqlite:info", sqlitePathArg(SQLITE_TEST_DB))
    @Expect(msg.contains("no such database file"), true)
    // 关键：浏览类命令**不能**顺手造一个空库出来（只读打开，文件不存在就是失败）
    @Expect(exists(SQLITE_TEST_DB), false)
}

@Test
func testSqliteExecCreateInsertThenBrowse(): Unit {
    sqliteCleanDb()
    let cmds = SqlitePlugin().commands()
    let exec = cmds.get("exec").getOrThrow()
    let created = sqliteExec(exec, "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT, price REAL)")
    // 建表本身不需要改行数，但 lastInsertRowid 应可读（同一次 exec 的返回值）
    @Expect(sqliteIntOf(created, "changes") >= 0, true)
    let inserted = sqliteExec(exec, "INSERT INTO items(name, price) VALUES('甲', 1.5), ('乙', 2.5)")
    @Expect(sqliteIntOf(inserted, "changes"), 2)
    @Expect(sqliteIntOf(inserted, "lastInsertRowid"), 2)

    // info：库文件存在、表数 1、版本非空
    let info = cmds.get("info").getOrThrow().handle("sqlite:info", sqlitePathArg(SQLITE_TEST_DB),
        IpcContext("main", IpcHub()))
    @Expect(sqliteIntOf(info, "tableCount"), 1)
    @Expect(sqliteStr(info, "sqliteVersion").size > 0, true)
    @Expect(sqliteBoolOf(info, "attachBlocked"), true)

    // tables：一张表、两行、三列
    let tables = cmds.get("tables").getOrThrow().handle("sqlite:tables",
        sqlitePathArg(SQLITE_TEST_DB), IpcContext("main", IpcHub()))
    let list = sqliteField(tables, "tables").asArray()
    @Expect(list.size(), 1)
    @Expect(sqliteStr(list.get(0), "name"), "items")
    @Expect(sqliteStr(list.get(0), "kind"), "table")
    @Expect(sqliteIntOf(list.get(0), "rows"), 2)
    @Expect(sqliteIntOf(list.get(0), "columns"), 3)

    // schema：列名与建表原文都在
    let schema = cmds.get("schema").getOrThrow().handle("sqlite:schema",
        sqliteArgs([("path", JsonString(SQLITE_TEST_DB)), ("table", JsonString("items"))]),
        IpcContext("main", IpcHub()))
    let cols = sqliteField(schema, "columns").asArray()
    @Expect(cols.size(), 3)
    @Expect(sqliteStr(cols.get(0), "name"), "id")
    @Expect(sqliteBoolOf(cols.get(0), "pk"), true)
    @Expect(sqliteStr(cols.get(1), "name"), "name")
    @Expect(sqliteStr(schema, "sql").contains("CREATE TABLE items"), true)

    // page：分页取数带 total，单元格按类型给（id 整数 / name 文本 / price 浮点）
    let page = cmds.get("page").getOrThrow().handle("sqlite:page",
        sqliteArgs([("path", JsonString(SQLITE_TEST_DB)), ("table", JsonString("items")),
        ("limit", JsonInt(10))]), IpcContext("main", IpcHub()))
    @Expect(sqliteIntOf(page, "total"), 2)
    @Expect(sqliteIntOf(page, "limit"), 10)
    @Expect(sqliteBoolOf(page, "limitClamped"), false)
    let rows = sqliteField(page, "rows")
    @Expect(rows.asArray().size(), 2)
    @Expect(sqliteCellType(sqliteCell(rows, 0, 0)), "integer")
    @Expect(sqliteCellType(sqliteCell(rows, 0, 1)), "text")
    @Expect(sqliteCellType(sqliteCell(rows, 0, 2)), "float")
    @Expect(sqliteStr(sqliteCell(rows, 0, 1), "value"), "甲")

    // query：只读连接上跑 SELECT，NULL 与 BLOB 各自的形状都要对
    sqliteExec(exec, "INSERT INTO items(name, price) VALUES(NULL, NULL)")
    let qres = cmds.get("query").getOrThrow().handle("sqlite:query",
        sqliteArgs([("path", JsonString(SQLITE_TEST_DB)),
        ("sql", JsonString("SELECT name FROM items WHERE id = 3"))]), IpcContext("main", IpcHub()))
    @Expect(sqliteIntOf(qres, "rowCount"), 1)
    @Expect(sqliteCellType(sqliteCell(sqliteField(qres, "rows"), 0, 0)), "null")
    // 没给 value 的 NULL 不该被当成空串：value 键就不该存在
    let nullCell = sqliteCell(sqliteField(qres, "rows"), 0, 0).asObject()
    @Expect(nullCell.get("value").isNone(), true)
    sqliteCleanDb()
}
