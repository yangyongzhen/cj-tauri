package typing_poem

import std.env.*
import std.fs.*
import cjTauri.*

/**
 * 古诗词打字练习（cj-tauri 示例）
 *
 * 玩什么：屏幕上一张 3D 诗词卡片，《咏鹅》《静夜思》这些小学常背的篇目，
 * 每个字上方标拼音；小朋友照着拼音敲键盘，打对一个字就点亮一个字、冒一点星光，
 * 整首打完放礼花、结算速度与正确率，最高分由仓颉侧写在本机文件里。
 *
 * 三件套各管一段（与其他示例同一套分工）：
 *   · 仓颉侧：诗库素材（`src/poems.cj`）+ 成绩落盘 + 自检开关（`src/commands.cj`）；
 *   · 前端：`ui/index.html`，一个文件里包含样式、three.js 场景与打字逻辑（零 Node、无构建）；
 *   · three.js：`ui/vendor/three.min.js`，经 `addInitScript()` 注入（见下）。
 *
 * 为什么页面与 three.js 都要按**相对路径从项目根读**：`capabilities/` 是同一套约定，
 * 启动器（`run.bat`）负责把工作目录切到本示例目录，应用只按相对路径取。
 */

let UI_PATH = "ui/index.html"
let THREE_PATH = "ui/vendor/three.min.js"

/** 从磁盘读文本：读不到就把「请在哪个目录启动」写进异常里（工作目录是这类问题的第一嫌疑） */
func readTextFile(path: String, what: String): String {
    var bytes: Array<Byte> = []
    try {
        bytes = File.readFrom(path)
    } catch (e: Exception) {
        throw Exception("读不到${what} ${path}（${e}）——请在 examples/typing-poem 目录下启动："
            + "capabilities/、ui/ 都按项目根相对路径读")
    }
    return String.fromUtf8(bytes)
}

main(): Int64 {
    eprintln("[typing] main start")

    // 素材自检：汉字数与拼音音节数逐行对齐（写错就在启动日志里喊，别等小朋友打到那一个字）
    let bad = checkPoemData()
    if (bad > 0) {
        eprintln("[typing] 素材有 ${bad} 处对不上：游戏里会在那些字上卡住，请先修 src/poems.cj")
    }

    let html = readTextFile(UI_PATH, "前端页面")
    let three = readTextFile(THREE_PATH, "three.js")

    var app = TauriApp().window(WindowConfig("古诗词打字练习 · cj-tauri", 1180, 780))
    let store = ScoreStore(SCORES_PATH)
    app.register("poem:list", PoemListCommand())
    app.register("score:save", ScoreSaveCommand(store))
    app.register("score:list", ScoreListCommand(store))
    app.register("typing:config", TypingConfigCommand())
    app.register("report", ReportCommand())
    app.register("typing:quit", QuitCommand(app))

    // three.js 经「预执行脚本」通道注入（document-start，排在桥 JS 之后）——这是本示例唯一一处
    // 不直白的地方，理由值得记下来：页面是 run(html) 的内联来源，Windows 下由 `NavigateToString`
    // 载入，**没有真实来源**（origin 是 opaque 的），于是两种常规做法都不成立：
    //   ① 相对路径 `<script src="vendor/three.min.js">` —— 没有 base URL，取不到；
    //   ② ES module（`import ... from './three.module.js'`）—— file:// / opaque 来源下被 CORS 拦。
    // 而 `WebViewHost.addInitScript()` 是现成的 document-start 通道（插件 jsShim 走的就是它）：
    // 整份 UMD 注入后页面里 `window.THREE` 直接可用，两平台语义一致，且**离线可跑**（不走 CDN）。
    // 这也是选 r160 的原因：它是最后一个带 UMD 构建的版本（`three@0.161+` 只剩 ESM）。
    app.webviewHost().addInitScript(three)
    eprintln("[typing] three.js 已注册为预执行脚本（${three.size} 字节，r160 UMD）")
    eprintln("[typing] 前端页面已载入：${UI_PATH}（${html.size} 字节）")

    app.run(html)
    eprintln("[typing] after run")
    return 0
}
