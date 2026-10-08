package music_app

import std.fs.*
import cjTauri.*

/**
 * 前端页面路径（相对**项目根**）
 *
 * 与 `capabilities/` 是同一套约定：启动器负责把工作目录切到项目根（examples/music），
 * 应用只按相对路径读。README 与 run.bat 都写明了这一条。
 */
let MUSIC_UI_PATH = "ui/index.html"

/** 本机收藏 / 最近播放的存放文件（同样相对项目根；已进 .gitignore，不进库） */
let MUSIC_LIBRARY_PATH = "music-library.local.json"

/**
 * 把前端页面读成 HTML 字符串交给 `run()`
 *
 * 为什么页面独立成 `ui/index.html` 而不是内联进仓颉的三引号字符串（框架其他示例的写法）：
 * 这个应用的前端是一整页 UI（四个视图 + 播放器 + 歌词 + 弹窗 + 样式），内联会同时踩两个坑——
 * ① 三引号字符串会处理反斜杠转义，JS 里的 `\n`、正则会被先吃掉，整段 `<script>` 静默变语法错误；
 * ② 字符串插值 `${...}` 与 JS 的模板字面量同形，写模板串就等于往仓颉的插值里塞代码
 * （两条都在 AGENTS §4 里，examples/movie 已在注释里记过同样的取舍）。
 */
func loadMusicUi(): String {
    var bytes: Array<Byte> = []
    try {
        bytes = File.readFrom(MUSIC_UI_PATH)
    } catch (e: Exception) {
        throw Exception("读不到前端页面 ${MUSIC_UI_PATH}（${e}）——请在 examples/music 目录下启动：" +
            "capabilities/ 与 ui/ 都按项目根相对路径读")
    }
    return String.fromUtf8(bytes)
}

main(): Int64 {
    eprintln("[music] main start")
    eprintln("[music] 后台接口：${musicApiBase()}（可用环境变量 CJ_MUSIC_API 覆盖）")
    eprintln("[music] 本机收藏库：${MUSIC_LIBRARY_PATH}")

    // 收藏库在启动时读一次、之后由命令层读写（每条命令共享同一个实例）
    let store = MusicStore(MUSIC_LIBRARY_PATH)
    let n = store.countOf("songs")
    let m = store.countOf("recent")
    eprintln("[music] 收藏已载入：songs=${n} recent=${m}")

    // 播放器要并排放「列表 + 歌词 + 封面」，窗口给宽一点；能力清单由框架在 run() 时自动扫 capabilities/
    // 1280×820：三栏（导航 212 / 内容自适应 / 正在播放 320）在这个宽度下不用折行，与 examples/movie 同尺寸
    let winCfg = WindowConfig("仓颉爱音乐 · cj-tauri", 1280, 820)

    // 这里刻意不用链式写法：`music:quit` 要拿到 app 自己（无人值守自检靠它收尾）——
    // 与 examples/typing-poem 的 `typing:quit` 同一套装配顺序。
    var app = TauriApp().window(winCfg)
    app.register("music:hot", MusicHotCommand())
    app.register("music:search", MusicSearchCommand())
    app.register("music:menus", MusicMenusCommand())
    app.register("music:lyric", MusicLyricCommand())
    app.register("music:image", MusicImageCommand())
    app.register("music:share", MusicShareCommand())
    app.register("fav:get", FavGetCommand(store))
    app.register("fav:set", FavSetCommand(store))
    app.register("music:config", MusicConfigCommand(store))
    app.register("music:quit", MusicQuitCommand(app))
    app.register("report", ReportCommand())

    let html = loadMusicUi()
    eprintln("[music] 前端页面已载入：${MUSIC_UI_PATH}（${html.size} 字节）")
    app.run(html)
    eprintln("[music] after run")
    return 0
}
