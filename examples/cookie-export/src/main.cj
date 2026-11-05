package cookieExport

import cjTauri.*
import std.fs.*
import stdx.encoding.json.*

/**
 * cookie-export 启动器。
 *
 * 这个工具只解决一件事：**把「浏览器里已经登录」变成「cspub 能用的凭证文件」**。
 * 在此之前的流程是 F12 → Network → 复制 Cookie 头 → 手工拼 JSON，慢且容易漏字段；
 * 而现在登录、提取、校验、落盘在一个窗口里完成，字段缺不缺在导出前就知道。
 *
 * 装配只有三段：命令（cookie:* / login:*）、能力清单（assets/capabilities/app.json）、
 * 页面（assets/ui/index.html）。三者缺一前端就调不通——新增命令时三处联动。
 */

/** 前端主动退应用（quit 在平台层投 GUI 线程，命令里调是安全的） */
public class QuitCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let _ = ipc
        this.app.quit()
        return JsonBool(true)
    }
}

/** 页面路径（工程根相对）：单文件产物里这条只在读盘兜底时用到 */
let UI_PATH = "assets/ui/index.html"

/**
 * 读页面：内嵌优先（单文件产物），否则按相对路径读盘（工作目录 = 工程根，与 ai-chat 同款约定）。
 *
 * 读不到时给一页能看懂的提示而不是抛异常——「从哪个目录启动」是这类问题的第一嫌疑，
 * 让人在窗口里就看到原因，比在没控制台的 exe 里静默退出强。
 */
func loadUi(): String {
    // 两条都没东西可读才给提示页：内嵌资源（单文件产物）与随行文件（仓库内构建）各占一条
    if (PACKED_UI_B64.size == 0 && !exists(UI_PATH)) {
        return "<html><body style='font-family:sans-serif;padding:2em'>" +
            "<h2>assets/ui/index.html 缺失</h2>" +
            "<p>请从工程根目录启动（<code>cjpm run</code>），页面按相对路径读取。</p></body></html>"
    }
    return textOrFile(PACKED_UI_B64, UI_PATH, "前端页面")
}

main(): Int64 {
    let win = WindowConfig("Cookie 导出 · cspub 凭证助手", 1120, 800)
    // 登录页是外部站点，出问题时 devTools 是唯一能看的手；预览版默认开着
    win.devTools = true

    let app = TauriApp()
        .window(win)
        // GUI 产物双击没控制台，报障时一个文件看全（C 桥 + 仓颉 + 页面）
        .setLogToDefaultFile("cookie-export")

    // 单文件产物没有随行的 capabilities/：清单编在二进制里，逐个挂载（每份清单在框架里
    // 是一个独立的 Capability）。一旦调用 addCapabilityJson 就不再自动扫描（框架约定），
    // 所以这条分支只在打包产物里生效，仓库内构建照旧按工作目录扫描。
    if (PACKED_CAPS_B64.size > 0) {
        var capsN: Int64 = 0
        for (part in splitBy(PACKED_CAPS_B64, 44u8)) {
            if (part.size == 0) {
                continue
            }
            let _ = app.addCapabilityJson(JsonValue.fromStr(decodeBase64(part)))
            capsN += 1
        }
        eprintln("[cookie-export] 能力清单来自内嵌资源（${capsN} 份，共 ${PACKED_CAPS_B64.size} 字节 base64）")
    }

    let cookies = PlatformCommands({ label => app.hostOf(label) })
    app.register("cookie:platforms", cookies)
    app.register("cookie:probe", cookies)
    app.register("cookie:export", cookies)

    // 登录视图共享一份原生视图状态：连点「登录」会让原生视图与 DOM 错位，
    // 走框架串行组按到达序执行（同 ai-chat webtab 的教训）
    let login = LoginCommands({ label => app.hostOf(label) })
    app.registerSerial("login:show", login, "login")
    app.registerSerial("login:bounds", login, "login")
    app.registerSerial("login:hide", login, "login")
    app.registerSerial("login:close", login, "login")

    app.register("quit", QuitCommand(app))

    app.run(loadUi())
    return 0
}
