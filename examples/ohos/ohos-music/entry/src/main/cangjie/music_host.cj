package ohos_app_cangjie_entry

import kit.PerformanceAnalysisKit.Hilog
import stdx.encoding.json.JsonValue
import cjTauri.*
import cjTauri.plugins.store.*
import ohos_app_cangjie_entry.musiclib.*

/*
 * 鸿蒙侧的音乐应用装配（examples/ohos/ohos-music）
 *
 * ## 业务层从哪来
 *
 * `musiclib/` 是**生成物、不入库**：build-hap.sh 把 `examples/music/src/` 的命令层
 * （api / commands / cover / lrc / 打包辅助）逐字复制过来，只把 `package music_app` 改成
 * `package ohos_app_cangjie_entry.musiclib`。这样业务逻辑只有一份（在 examples/music），
 * 鸿蒙侧不重写、也不同步维护两套——`examples/music` 改了，重跑一次 build-hap.sh 就跟着走。
 *
 * 之所以不用 cjpm 源码依赖（`music = { path = "../../../../music" }`）：music 的模块是
 * `output-type = "executable"`、带自己的 `main()`，作为依赖编进动态模块属于没验证过的形态；
 * 而生成物这条路与探针工程已跑通的构建链完全一致（entry 只依赖 cjTauri），风险最低。
 *
 * ## 页面从哪来
 *
 * 设备上没有 `ui/` 目录（hap 是打包后的产物），所以页面在构建期被 base64 编进
 * `musiclib/ohos_assets.cj`，运行时 `run(html)` 把它落进沙箱再以 file:// 加载
 * ——与桌面单文件包同一套「内嵌优先」取舍。
 */

/**
 * 收藏库（songs / recent）在沙箱里的落点
 *
 * 桌面示例用的是相对 cwd 的 `music-library.local.json`；鸿蒙应用没有「项目根」这个概念，
 * 相对路径会落到不确定的目录（读写还可能被拒），所以由 Ability 在 `onCreate` 里定成
 * `<filesDir>/music-library.local.json`。
 */
var musicLibraryPath: String = "music-library.local.json"

/** 由 `MainAbility.onCreate` 调用：把沙箱目录落成收藏库的绝对路径 */
public func configureMusicRuntime(filesDir: String): Unit {
    musicLibraryPath = "${filesDir}/music-library.local.json"
}

/**
 * 装配并运行框架应用（**必须在非 UI 线程调用**：`run()` 会阻塞到 `quit()`）
 *
 * 装配顺序与 `examples/music/src/main.cj` 一一对应，差别只有三处：
 * ① 窗口标签用框架默认的 `DEFAULT_WINDOW_LABEL`（鸿蒙侧一扇窗）；
 * ② 收藏库路径来自沙箱；
 * ③ 能力清单只能内嵌（hap 里没有 capabilities/ 目录）。
 */
public func startTauriMusic(): Unit {
    Hilog.info(1, "CjMusic", "startTauriMusic begin lib=${musicLibraryPath}")

    let store = StoreBackend(musicLibraryPath)
    var app = TauriApp().window(WindowConfig("仓颉爱音乐 · cj-tauri", 1280, 820))
    // 存储插件：StoreBackend 由它提供（上面那行直接 new 它）。装配必须在 run() 之前——
    // 页面前命令表要定稿；前端不直连 store:* 命令，所以能力清单里不必声明。
    app.plugin(StorePlugin())
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

    // 能力清单来自内嵌资源（构建期由 examples/music/capabilities/*.json 生成）。
    // 显式挂载即不自动扫描目录——hap 里本来也没有 capabilities/ 这个目录。
    let capsJson = ohosMusicCapsJson()
    app.addCapabilityJson(JsonValue.fromStr(capsJson))
    Hilog.info(1, "CjMusic", "capability embedded bytes=${capsJson.size}")

    let html = ohosMusicPageHtml()
    Hilog.info(1, "CjMusic", "page loaded bytes=${html.size}")
    // 阻塞到 quit()：鸿蒙侧 `music:quit` 只置退出意图，Ability 的生命周期仍归系统管，
    // 所以这条命令在设备上表现为「页面侧生效、进程不退出」，如实记在 README 里。
    app.run(html)
    Hilog.info(1, "CjMusic", "after run")
}
