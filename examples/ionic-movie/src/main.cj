package ionic_movie_app

import cjTauri.*

/**
 * 业务装配点（RFC-002 §4.1）：骨架的 launcher（targets/ 下各目标的 src）调用它取 AppSpec。
 *
 * 零平台知识：不碰宿主、不知道页面文件路径、不知道能力目录——那些由清单
 * （cj-tauri.toml）决定，launcher 按清单覆盖（page/window/assets/capabilities）。
 * build() 负责业务自己的部分：命令注册。
 *
 * 与旧 examples/movie 的 main() 相比少了两块（都是旧形态的包袱，新形态归骨架/清单管）：
 * - `app.run(html)`：页面改由 launcher 按清单 `page`（ui/dist/index.html）从 assets/ 读盘；
 * - `PACKED_CAPS_B64` 内嵌能力清单：能力目录改由 launcher 按清单 `[capabilities] dir` 挂载。
 */
public func build(): AppSpec {
    eprintln("[movie] 后台接口：${movieApiBase()}（可用环境变量 CJ_MOVIE_API 覆盖）")

    // 窗口默认值只是给人看的；launcher 会按清单 [[windows]]（400×820 竖屏）再覆盖一次
    let winCfg = WindowConfig("仓颉观影 Ionic · cj-tauri", 400, 820)

    let spec = AppSpec()
        .window(winCfg)
        .wire({ app =>
            app.register("movie:list", MovieListCommand())
            app.register("movie:search", MovieSearchCommand())
            app.register("movie:detail", MovieDetailCommand())
            app.register("movie:source", MovieSourceCommand())
            app.register("movie:sourceitem", MovieSourceItemCommand())
            app.register("movie:image", MovieImageCommand())
            app.register("report", ReportCommand())
        })
    spec.name = "仓颉观影 Ionic · cj-tauri"
    return spec
}
