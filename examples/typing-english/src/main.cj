package typing_english

import std.fs.*
import stdx.encoding.json.*
import cjTauri.*

/**
 * 小学英语打字练习（cj-tauri 示例）
 *
 * 玩什么：屏幕中央一个英文单词（下方给音标），小朋友照着敲字母，打对一个亮一个；
 * **一个词打完，它的中文意思就从上边浮下来停几秒**——打完这个动作本身就成了记忆的钩子，
 * 打字练习顺带变成背单词。连续打词时中文不是盖掉前一条，而是**排队依次展示**
 * （实现见 `ui/index.html` 的 popQueue），所以手快也不会漏看任何一条释义。
 *
 * 三件套各管一段（与其他示例同一套分工）：
 *   · 仓颉侧：词库素材（`src/words.cj`）+ 成绩落盘 + 自检开关（`src/commands.cj`）；
 *   · 前端：`ui/index.html`，一个文件里包含样式与打字逻辑（零 Node、无构建、零第三方库）；
 *   · 能力清单：`capabilities/default.json`，启动时自动扫描。
 *
 * 与 typing-poem 的取舍差异（有意为之）：那个示例要 3D 场景，所以带 three.js 并经
 * `addInitScript()` 注入；这一版的重点是「中文释义浮窗」这种 DOM 层的瞬时反馈，
 * 用 CSS 动画就能做到位，于是**不引第三方库**——不开注入通道、不担 669KB 体积、
 * 也没有第三方许可证义务。两条路都验证过，选哪条只看玩法需不需要 3D。
 *
 * 唯一的例外是**单文件打包产物**（`scripts/pack-win-single.sh`）：那时页面与能力清单
 * 都由打包脚本以 base64 内嵌进二进制（见 `src/packed_assets.cj` / `src/packed_resources.cj`），
 * 产物只有一个 exe、没有任何随行文件。两条路差别只在「字节从哪来」，玩法与命令一行不改。
 */

let UI_PATH = "ui/index.html"

/** 从磁盘读文本：读不到就把「请在哪个目录启动」写进异常里（工作目录是这类问题的第一嫌疑） */
func readTextFile(path: String, what: String): String {
    var bytes: Array<Byte> = []
    try {
        bytes = File.readFrom(path)
    } catch (e: Exception) {
        let msg = "读不到${what} ${path}（${e}）——请在 examples/typing-english 目录下启动：capabilities/、ui/ 都按项目根相对路径读"
        throw Exception(msg)
    }
    return String.fromUtf8(bytes)
}

main(): Int64 {
    eprintln("[english] main start")

    // 素材自检：单词只含小写字母、中文与音标不为空、全局不重复（写错就在启动日志里喊，
    // 别等小朋友打到那个词才发现它永远打不完）
    let bad = checkWordData()
    if (bad > 0) {
        eprintln("[english] 素材有 ${bad} 处问题：游戏里会在那些词上卡住，请先修 src/words.cj")
    }

    // 字节从哪来有两条路，玩法一行不改：
    //   · 仓库内构建：`src/packed_assets.cj` 的常量为空 ⇒ 按相对路径从 ui/ 读盘（改页面刷新即可看效果）；
    //   · 单文件打包：打包脚本把它们替换成 base64 ⇒ 页面与清单都在二进制里，产物只有一个 exe。
    let html = textOrFile(PACKED_UI_B64, UI_PATH, "前端页面")

    var app = TauriApp().window(WindowConfig("小学英语打字练习 · cj-tauri", 1200, 800))
    let store = ScoreStore(SCORES_PATH)
    app.register("word:list", WordListCommand())
    app.register("score:save", ScoreSaveCommand(store))
    app.register("score:list", ScoreListCommand(store))
    app.register("typing:config", TypingConfigCommand())
    app.register("report", ReportCommand())
    app.register("typing:quit", QuitCommand(app))

    // 能力清单：内嵌优先（打包产物没有随行的 capabilities/），否则交给 run() 自动扫描目录。
    // 框架契约是「显式挂载即不自动扫描」，所以两条路互斥、不会叠加或打架。
    if (PACKED_CAPS_B64.size > 0) {
        // 打包器把每个 capabilities/*.json 各自 base64、再用 "," 拼起来（base64 表里没有逗号）；
        // 逐个挂载而不是拼成一份 json——每份清单在框架里本来就是一个独立的 Capability。
        var n: Int64 = 0
        for (part in splitBy(PACKED_CAPS_B64, 44u8)) {
            app.addCapabilityJson(JsonValue.fromStr(decodeBase64(part)))
            n += 1
        }
        eprintln("[english] 能力清单来自内嵌资源（${n} 份，共 ${PACKED_CAPS_B64.size} 字节 base64）")
    }

    eprintln("[english] 前端页面已载入：${UI_PATH}（${html.size} 字节）")
    eprintln("[english] 窗口 1200x800，词库 ${lessons().size} 课 / ${totalWords()} 个词")

    app.run(html)
    eprintln("[english] after run")
    return 0
}
