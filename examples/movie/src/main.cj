package movie_app

import std.fs.*
import cjTauri.*

/**
 * 前端页面路径（相对**项目根**）
 *
 * 与 `capabilities/` 是同一套约定：启动器负责把工作目录切到项目根（examples/movie），
 * 应用只按相对路径读。README 与 run.bat 都写明了这一条。
 */
let MOVIE_UI_PATH = "ui/index.html"

/**
 * 把前端页面读成 HTML 字符串交给 `run()`
 *
 * 为什么页面放在 `ui/index.html` 里、而不是内联成仓颉的三引号字符串（框架其他示例的写法）：
 * 这个应用的前端是一整页 UI（首页 / 搜索 / 详情 / 播放四个视图 + 样式），内联进 `"""`
 * 会同时踩两个坑——① 三引号字符串会处理反斜杠转义，JS 里的 `\n`、正则会被先吃掉，
 * 整段 `<script>` 静默变语法错误（AGENTS.md §4 实测踩过）；② 字符串插值 `${...}` 与
 * JS 的模板字面量同形，写模板串就等于往仓颉的插值里塞代码。
 * 独立成文件后两个坑都不存在，编辑器也才认得出语法。
 */
func loadMovieUi(): String {
    var bytes: Array<Byte> = []
    try {
        bytes = File.readFrom(MOVIE_UI_PATH)
    } catch (e: Exception) {
        throw Exception("读不到前端页面 ${MOVIE_UI_PATH}（${e}）——请在 examples/movie 目录下启动：" +
            "capabilities/ 与 ui/ 都按项目根相对路径读")
    }
    return String.fromUtf8(bytes)
}

main(): Int64 {
    eprintln("[movie] main start")
    eprintln("[movie] 后台接口：${movieApiBase()}（可用环境变量 CJ_MOVIE_API 覆盖）")

    // 影院片单页要横向排得开，窗口给宽一点；能力清单由框架在 run() 时自动扫 capabilities/
    var winCfg = WindowConfig("仓颉观影 · cj-tauri", 1280, 820)

    let app = TauriApp()
        .window(winCfg)
        .register("movie:list", MovieListCommand())
        .register("movie:search", MovieSearchCommand())
        .register("movie:detail", MovieDetailCommand())
        .register("movie:source", MovieSourceCommand())
        .register("movie:sourceitem", MovieSourceItemCommand())
        .register("movie:image", MovieImageCommand())
        .register("report", ReportCommand())

    let html = loadMovieUi()
    eprintln("[movie] 前端页面已载入：${MOVIE_UI_PATH}（${html.size} 字节）")
    app.run(html)
    eprintln("[movie] after run")
    return 0
}
