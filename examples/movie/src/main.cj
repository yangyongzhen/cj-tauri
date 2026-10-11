package movie_app

import stdx.encoding.json.*
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
    return textOrFile(PACKED_UI_B64, MOVIE_UI_PATH, "前端页面")
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

    // 能力清单：内嵌优先（单文件产物没有随行的 capabilities/），否则交给 run() 自动扫描目录。
    // 框架契约是「显式挂载即不自动扫描」，所以两条路互斥、不会叠加或打架。
    if (PACKED_CAPS_B64.size > 0) {
        // 打包器把每个 capabilities/*.json 各自 base64、再用 "," 拼起来（base64 表里没有逗号）；
        // 逐个挂载而不是拼成一份 json——每份清单在框架里本来就是一个独立的 Capability。
        var n: Int64 = 0
        for (part in splitBy(PACKED_CAPS_B64, 44u8)) {
            app.addCapabilityJson(JsonValue.fromStr(decodeBase64(part)))
            n += 1
        }
        eprintln("[movie] 能力清单来自内嵌资源（${n} 份，共 ${PACKED_CAPS_B64.size} 字节 base64）")
    }

    let html = loadMovieUi()
    eprintln("[movie] 前端页面已载入：${MOVIE_UI_PATH}（${html.size} 字节）")
    app.run(html)
    eprintln("[movie] after run")
    return 0
}
