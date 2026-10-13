package cjTauri.plugins

import cjTauri.*

/**
 * SQLite C API 的 FFI 声明与最小包装（`sqlite` 插件的地基）
 *
 * **为什么直连系统库而不进 C 桥**（docs/设计决策记录.md D-018 第 2 条）：现有 `cj_bridge_*` 之所以存在，
 * 是因为平台差异集中在 C 桥里；SQLite 相反——三平台同一套 C API、没有平台分支，再包一层只是多一份要
 * 维护的转发代码。代价是「链接谁」从「桥提供」变成「消费方各自提供」：Linux 链发行版系统库
 * （`-lsqlite3`，本机 3.45.1），Windows 侧未落地（见 D-018 第 8 条）。
 *
 * **FFI 语法是实测出来的**（三条都进 AGENTS §4）：
 *   1. 仓颉**没有** `&x` 取地址（写它会报 `expected expression after ','`）；C 出参在**调用处**写
 *      `inout <var>`，自动取址成 `CPointer<T>`——修饰对象只能是 `var`，且指针仅在本次调用期间有效。
 *   2. 「可选传 NULL 的 C 字符串」（这里的 `zVfs`）声明成 `CPointer<UInt8>` 并传 `CPointer<UInt8>()`；
 *      传空 `CString` 会被 SQLite 当成「名字为空的 VFS」，报的是 `no such vfs`（实测踩过）。
 *   3. C 回调声明成 `CFunc<(...) -> 返回类型>`，回调本体是顶层 `@C func`（本仓 `cj_bridge_init` 先例）。
 */

/** SQLite 返回码（sqlite3.h 的子集，只列我们判过的） */
let SQLITE_OK: Int32 = 0
let SQLITE_ROW: Int32 = 100
let SQLITE_DONE: Int32 = 101
/** sqlite3_exec 在授权回调拒绝时给的是 SQLITE_AUTH（列出来便于断言时看明白） */
let SQLITE_AUTH: Int32 = 23

/** 列类型（sqlite3_column_type）：界面要能说清「这格是数字还是文本」，所以逐格判 */
let SQLITE_INTEGER: Int32 = 1
let SQLITE_FLOAT: Int32 = 2
let SQLITE_TEXT: Int32 = 3
let SQLITE_BLOB: Int32 = 4
let SQLITE_NULL: Int32 = 5

/** 打开标志（sqlite3_open_v2）：只读走 READONLY，写路径要显式给 READWRITE */
let SQLITE_OPEN_READONLY: Int32 = 1
let SQLITE_OPEN_READWRITE: Int32 = 2
let SQLITE_OPEN_CREATE: Int32 = 4

/** 授权动作码（sqlite3_set_authorizer）：只列我们要拒的三类 */
let SQLITE_ATTACH: Int32 = 24
let SQLITE_DETACH: Int32 = 25
let SQLITE_FUNCTION: Int32 = 31

/** 授权回调返回值 */
let SQLITE_DENY: Int32 = 1

/** busy 等待上限（毫秒）：另一个进程正写这个库时等着，而不是当场报 SQLITE_BUSY */
let SQLITE_BUSY_TIMEOUT_MS: Int32 = 3000

@C
foreign func sqlite3_libversion(): CString

@C
foreign func sqlite3_open_v2(filename: CString, ppDb: CPointer<CPointer<Unit>>, flags: Int32,
                             zVfs: CPointer<UInt8>): Int32

@C
foreign func sqlite3_close(db: CPointer<Unit>): Int32

@C
foreign func sqlite3_errmsg(db: CPointer<Unit>): CString

@C
foreign func sqlite3_exec(db: CPointer<Unit>, sql: CString, cb: CPointer<Unit>, arg: CPointer<Unit>,
                          errmsg: CPointer<Unit>): Int32

@C
foreign func sqlite3_changes(db: CPointer<Unit>): Int32

@C
foreign func sqlite3_last_insert_rowid(db: CPointer<Unit>): Int64

@C
foreign func sqlite3_busy_timeout(db: CPointer<Unit>, ms: Int32): Int32

@C
foreign func sqlite3_prepare_v2(db: CPointer<Unit>, sql: CString, nByte: Int32,
                                ppStmt: CPointer<CPointer<Unit>>, pzTail: CPointer<Unit>): Int32

@C
foreign func sqlite3_step(stmt: CPointer<Unit>): Int32

@C
foreign func sqlite3_finalize(stmt: CPointer<Unit>): Int32

@C
foreign func sqlite3_column_count(stmt: CPointer<Unit>): Int32

@C
foreign func sqlite3_column_name(stmt: CPointer<Unit>, i: Int32): CString

@C
foreign func sqlite3_column_type(stmt: CPointer<Unit>, i: Int32): Int32

@C
foreign func sqlite3_column_int64(stmt: CPointer<Unit>, i: Int32): Int64

@C
foreign func sqlite3_column_double(stmt: CPointer<Unit>, i: Int32): Float64

@C
foreign func sqlite3_column_text(stmt: CPointer<Unit>, i: Int32): CString

@C
foreign func sqlite3_column_bytes(stmt: CPointer<Unit>, i: Int32): Int32

@C
foreign func sqlite3_set_authorizer(
    db: CPointer<Unit>,
    cb: CFunc<(CPointer<Unit>, Int32, CString, CString, CString, CString) -> Int32>,
    userdata: CPointer<Unit>): Int32

@C
foreign func sqlite3_enable_load_extension(db: CPointer<Unit>, onoff: Int32): Int32

/**
 * 授权回调：拒掉「跑到别的文件去」的动作——`ATTACH` / `DETACH` 换库文件、
 * `load_extension()` 加载任意原生库。**必须按语句判**：路径 scope 只管得住本次命令收到的那个路径，
 * 管不住 SQL 里写死的另一个路径（D-018 第 4 条）。被拒时留一行 stderr，取证时能对上账。
 */
@C
func sqliteAuthorizer(app: CPointer<Unit>, code: Int32, arg1: CString, arg2: CString,
                      dbName: CString, triggerName: CString): Int32 {
    let _ = app
    let _ = arg2
    let _ = dbName
    let _ = triggerName
    if (code == SQLITE_ATTACH || code == SQLITE_DETACH) {
        eprintln("[cj-tauri] sqlite denied: attach/detach is not allowed (code=${code})")
        return SQLITE_DENY
    }
    if (code == SQLITE_FUNCTION) {
        // arg1 是被调用的函数名：只拒能加载原生代码的那个，其余内置函数照常放行
        let fnName = sqliteCString(arg1)
        if (fnName == "load_extension") {
            eprintln("[cj-tauri] sqlite denied: load_extension() is not allowed")
            return SQLITE_DENY
        }
    }
    return SQLITE_OK
}

/** C 字符串 → 仓颉字符串；NULL 给空串（调用方要区分 NULL 与空串时另判归属） */
func sqliteCString(s: CString): String {
    if (s.isNull()) {
        return ""
    }
    return s.toString()
}

/** 取最近一次错误文案；db 为空时给固定文案，避免收尾路径上再炸一次 */
func sqliteLastError(db: CPointer<Unit>): String {
    if (db.isNull()) {
        return "unknown error (null db handle)"
    }
    return sqliteCString(unsafe { sqlite3_errmsg(db) })
}

/** 关掉句柄：对空指针安全（出错路径也要能收尾），关不掉只记一行 stderr 不抛 */
func sqliteCloseQuietly(db: CPointer<Unit>): Unit {
    if (db.isNull()) {
        return
    }
    let rc = unsafe { sqlite3_close(db) }
    if (rc != SQLITE_OK) {
        eprintln("[cj-tauri] sqlite close returned ${rc}")
    }
}

/**
 * 打开数据库并装上护栏（每次命令短连接，见 D-018 第 9 条）。
 *
 * `readonly=true` 走 `SQLITE_OPEN_READONLY`——只读是**内核级**的，不是我们写的检查；
 * 不存在的文件 + 只读 = 打开失败（不会顺手造一个空库）。
 * 打开失败与护栏装不上都抛 `CommandException`（前端拿到可读文案）。
 */
func sqliteOpenGuarded(path: String, readonly: Bool): CPointer<Unit> {
    var db: CPointer<Unit> = CPointer<Unit>()
    let flags = if (readonly) {
        SQLITE_OPEN_READONLY
    } else {
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    }
    // inout db 取的是「栈上那个指针变量」的地址：C 侧写入的 handle 直接落到 db 上
    let rc = unsafe { sqlite3_open_v2(LibC.mallocCString(path), inout db, flags, CPointer<UInt8>()) }
    if (rc != SQLITE_OK) {
        let msg = sqliteLastError(db)
        sqliteCloseQuietly(db)
        throw CommandException("sqlite: cannot open ${path}: ${msg}")
    }
    // 双保险之一：先关掉扩展加载（authorizer 之外再加一道）
    let _ = unsafe { sqlite3_enable_load_extension(db, 0) }
    let rcAuthorizer = unsafe { sqlite3_set_authorizer(db, sqliteAuthorizer, CPointer<Unit>()) }
    if (rcAuthorizer != SQLITE_OK) {
        sqliteCloseQuietly(db)
        throw CommandException("sqlite: cannot install authorizer (rc=${rcAuthorizer})")
    }
    let _ = unsafe { sqlite3_busy_timeout(db, SQLITE_BUSY_TIMEOUT_MS) }
    return db
}

/** 本机链接的 SQLite 版本（`sqlite:info` 回投给页面，对账时也用它） */
func sqliteLibVersion(): String {
    return sqliteCString(unsafe { sqlite3_libversion() })
}
