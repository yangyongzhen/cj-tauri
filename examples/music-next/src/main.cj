package music_next

import cjTauri.*
// StoreBackend（收藏库的存储本体）定义在 store 插件子包里：`import cjTauri.*` 只给核心包，
// 子包不会随之可见——少了这一行，`StoreBackend` 会被判成未声明类型（RFC-003 第 2 期同款坑）。
import cjTauri.plugins.store.*

/**
 * 本机收藏 / 最近播放的存放文件（相对**项目根**：CLI 的 run 以项目根为工作目录启动应用）。
 * 已进 .gitignore，不进库；老用户旧 music 的收藏文件不互通（路径不同，两份各自独立）。
 */
let MUSIC_LIBRARY_PATH = "music-library.local.json"

/**
 * 业务装配点（RFC-002 §4.1）：骨架的 launcher（targets/ 下各目标的 src）调用它取 AppSpec。
 *
 * 零平台知识：不碰宿主、不知道页面文件路径、不知道能力目录——那些由清单
 * （cj-tauri.toml）决定，launcher 按清单覆盖（page/window/assets/capabilities）。
 * build() 负责业务自己的部分：命令注册、插件。
 *
 * 与旧 examples/music 的 build() 相比少了两块（都是旧形态的包袱，新形态归骨架/清单管）：
 * - `PageSource.Inline(loadMusicUi())`：页面改由 launcher 按清单 `page` 从 assets/ 读盘；
 * - `PACKED_CAPS_B64` 内嵌能力清单：能力目录改由 launcher 按清单 `[capabilities] dir` 挂载。
 * 单文件打包机制（PACKED_* 双路）未随本示例迁移，是批次 4 资产模型任务（RFC §6）。
 */
public func build(): AppSpec {
    eprintln("[music] 后台接口：${musicApiBase()}（可用环境变量 CJ_MUSIC_API 覆盖）")
    eprintln("[music] 本机收藏库：${MUSIC_LIBRARY_PATH}")

    // 收藏库在启动时读一次、之后由命令层读写（每条命令共享同一个实例）。
    // 存储本体是框架的 StoreBackend（RFC-003 第 2 期）：原子写 + 并发锁。
    let store = StoreBackend(MUSIC_LIBRARY_PATH)
    let n = storeArrayCount(store, "songs")
    let m = storeArrayCount(store, "recent")
    eprintln("[music] 收藏已载入：songs=${n} recent=${m}")

    // 播放器要并排放「列表 + 歌词 + 封面」，窗口给宽一点（尺寸与清单 [[windows]] 一致，
    // launcher 会按清单再覆盖一次——两处一致是清单为单一真相的体现，业务这里只是给人看的默认值）
    let winCfg = WindowConfig("仓颉爱音乐 · cj-tauri", 1280, 820)

    // 命令注册放在 wire 闭包里：框架把装配中的 TauriApp 传进来——
    // `music:quit` 要拿到 app 自己（无人值守自检靠它收尾），闭包参数正好补上这一环。
    // 注意：这里**不**挂 StorePlugin。旧 examples/music 的 build() 挂了它，但那是冗余装配——
    // 业务与前端走的是 fav:* 包装命令 + 直接持有的 StoreBackend 实例，从没调过 store:get/set
    // 等五条通用命令。挂着它会把这五条注册进命令表而 capabilities 又不声明（声明等于把
    // 通用存储读写权开给前端），新形态的 cj-tauri check 三方比对会如实判漂移。
    // StoreBackend（存储本体）仍在用——它在 store 插件子包，import 保留。
    let spec = AppSpec()
        .window(winCfg)
        .wire({ app =>
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
        })
    spec.name = "仓颉爱音乐 · cj-tauri"
    return spec
}
