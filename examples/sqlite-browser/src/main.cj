/**
 * SQLite 浏览器示例（零 Node、零构建）
 *
 * 页面是**独立的 ui/index.html**（理由同 markdown-notes / http-client：仓颉三引号会先吃掉反斜杠转义，
 * 内联进去等于让整段 `<script>` 静默语法错误；独立文件还能被 `node --check` 验语法）。
 *
 * 与别的示例相比这里特别薄，因为**能力全在插件里**：`SqlitePlugin()` 自带 7 条命令、
 * 前端 shim（`__CJ_TAURI__.sqlite`）与两条命名权限集。示例只做三件事：
 *   1. 装配插件；
 *   2. 注册 `report`（页内自检逐条回投，E2E 靠这些行取证）；
 *   3. 读页面、开窗口。
 *
 * 能力面（capabilities/default.json）——**故意用命名权限集**：
 *   `"permissions": ["sqlite:default"]` 等价于 7 条命令全放行；想只要「看数据」的应用
 *   把这一行换成 `"sqlite:readonly"` 就没了解释器（写能力不会被顺带打开，见 D-018 第 6 条）。
 *   scope 只允许 `$CWD` 与 `$TEMP` **各自的下级路径**（多层通配的原文在 capabilities/default.json 里；
 *   注释里不能照抄那种写法——`/` 紧跟星号会开一个嵌套块注释，正文从此永不闭合，AGENTS §4 第一条）。
 *   **命令放行 ≠ 路径放行**，库文件是页面可控路径。
 *
 * Windows 侧未落地（mingw 要自带 sqlite3 DLL，见 D-018 第 8 条），本文件不做平台分支。
 */
package sqlite_browser

import cjTauri.*
import cjTauri.plugins.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*

/** 自检回投：每条断言一行，与 markdown-notes / http-client 同款（页面侧拼好文案，宿主侧只负责打） */
public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        match (args.get("line")) {
            case Some(line) =>
                match (line.kind()) {
                    case JsonKind.JsString => eprintln("[frontend] " + line.asString().getValue())
                    case _ => ()
                }
            case None => ()
        }
        return JsonBool(true)
    }
}

/** 读前端页面；读不到要说清「在哪启动」，否则报错只有一个找不到的路径 */
func readUi(path: String): String {
    try {
        return String.fromUtf8(File.readFrom(path))
    } catch (e: Exception) {
        eprintln("[sqlite-browser] 读不到前端页面 ${path}：${e}")
        eprintln("[sqlite-browser] 请在示例根目录启动（ui/ 与 capabilities/ 都按相对路径解析）")
        return ""
    }
}

/** 取环境变量，空串当没设 */
func envOr(name: String): String {
    if (let Some(v) <- getVariable(name)) {
        if (v.size > 0) {
            return v
        }
    }
    return ""
}

main(): Int64 {
    let html = readUi("ui/index.html")
    if (html.size == 0) {
        return 1
    }

    // 启动行是 E2E 的第一条证据：把「这一轮到底跑的是哪份夹具」写在同一行里（单行，好 grep）
    eprintln("[sqlite-browser] main start (selfcheck=${envOr("CJ_SQLITE_SELFCHECK")}, " +
        "fixture=${envOr("CJ_SQLITE_FIXTURE")})")

    let app = TauriApp()
        .window(WindowConfig("cj-tauri SQLite 浏览器", 1320, 840))
        .plugin(SqlitePlugin())
        .register("report", ReportCommand())

    app.run(html)
    eprintln("[sqlite-browser] after run")
    return 0
}
