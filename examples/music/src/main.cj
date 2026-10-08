package music_app

import stdx.encoding.json.*
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
 *
 * 字节从哪来有两条路，玩法一行不改（与 examples/typing-poem 同款）：
 *   · 仓库内构建：`src/packed_assets.cj` 的两个常量为空 ⇒ 按相对路径从 ui/ 读盘（改页面刷新即可看效果）；
 *   · 单文件打包：打包脚本把常量换成 base64 ⇒ 页面在二进制里，产物只有一个 exe、没有随行 ui/。
 */
func loadMusicUi(): String {
    return textOrFile(PACKED_UI_B64, MUSIC_UI_PATH, "前端页面")
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
        eprintln("[music] 能力清单来自内嵌资源（${n} 份，共 ${PACKED_CAPS_B64.size} 字节 base64）")
    }

    let html = loadMusicUi()
    eprintln("[music] 前端页面已载入：${MUSIC_UI_PATH}（${html.size} 字节）")
    app.run(html)
    eprintln("[music] after run")
    return 0
}
