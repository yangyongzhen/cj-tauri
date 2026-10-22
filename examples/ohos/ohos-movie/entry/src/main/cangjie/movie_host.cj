package ohos_app_cangjie_entry

import kit.PerformanceAnalysisKit.Hilog
import stdx.encoding.json.JsonValue
import cjTauri.*
import ohos_app_cangjie_entry.movielib.*

/*
 * 鸿蒙侧的观影应用装配（examples/ohos/ohos-movie）
 *
 * ## 业务层从哪来
 *
 * `movielib/` 是**生成物、不入库**：build-hap.sh 把 `examples/movie/src/` 的命令层
 * （api / commands / 打包辅助）逐字复制过来，只把 `package movie_app` 改成
 * `package ohos_app_cangjie_entry.movielib`。业务逻辑只有一份（在 examples/movie），
 * 鸿蒙侧不重写、也不同步维护两套——`examples/movie` 改了，重跑一次 build-hap.sh 就跟着走。
 *
 * ## 页面从哪来
 *
 * 设备上没有 `ui/` 目录（hap 是打包后的产物），所以页面在构建期被 base64 编进
 * `movielib/ohos_assets.cj`，运行时 `run(html)` 把它落进沙箱再以 file:// 加载
 * ——与桌面单文件包同一套「内嵌优先」取舍。
 *
 * ## 与 ohos-music 的差别
 *
 * movie 没有本地存储（不装 store 插件、不写文件），所以这里没有「沙箱路径注入」那一步；
 * 片单与封面全部来自后台接口，宿主侧只负责把命令表与能力清单装配起来。
 */

/**
 * 装配并运行框架应用（**必须在非 UI 线程调用**：`run()` 会阻塞到 `quit()`）
 *
 * 装配顺序与 `examples/movie/src/main.cj` 一一对应，差别只有三处：
 * ① 窗口标签用框架默认的 `DEFAULT_WINDOW_LABEL`（鸿蒙侧一扇窗）；
 * ② 能力清单只能内嵌（hap 里没有 capabilities/ 目录）；
 * ③ 桌面版 `main()` 里那句「env CJ_MOVIE_API 覆盖后台地址」在设备上没意义（进程环境由系统给），
 *    用的是 api.cj 里的默认基址。
 */
public func startTauriMovie(): Unit {
    Hilog.info(1, "CjMovie", "startTauriMovie begin")

    var app = TauriApp().window(WindowConfig("仓颉观影 · cj-tauri", 1280, 820))
    app.register("movie:list", MovieListCommand())
    app.register("movie:search", MovieSearchCommand())
    app.register("movie:detail", MovieDetailCommand())
    app.register("movie:source", MovieSourceCommand())
    app.register("movie:sourceitem", MovieSourceItemCommand())
    app.register("movie:image", OhosMovieImageCommand())
    app.register("report", ReportCommand())

    // 能力清单来自内嵌资源（构建期由 examples/movie/capabilities/*.json 生成）。
    // 显式挂载即不自动扫描目录——hap 里本来也没有 capabilities/ 这个目录。
    let capsJson = ohosMovieCapsJson()
    app.addCapabilityJson(JsonValue.fromStr(capsJson))
    Hilog.info(1, "CjMovie", "capability embedded bytes=${capsJson.size}")

    let html = ohosMoviePageHtml()
    Hilog.info(1, "CjMovie", "page loaded bytes=${html.size}")
    // 阻塞到 quit()：鸿蒙侧没有 quit 命令（movie 不带退出入口），
    // 进程生命周期归系统管，要退出用 `aa force-stop`。
    app.run(html)
    Hilog.info(1, "CjMovie", "after run")
}
