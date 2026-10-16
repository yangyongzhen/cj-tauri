package aiChat

import std.env.*
// cjTauri.plugins.fs 与 std.fs 短名相同（都叫 fs）：本应用的链接命令行会**漏掉插件那个库**，
// 实测与 import 顺序无关（详见 cjpm.toml 的 link-option 注释）——靠清单显式补 -lcjTauri.plugins.fs。
import cjTauri.plugins.fs.*
import std.fs.*
import std.collection.*
import cjTauri.*
import cjTauri.plugins.http.*
import cjTauri.plugins.log.*
import cjTauri.plugins.store.*
import cjTauri.plugins.clipboard.*
import cjTauri.plugins.ws.*
import cjTauri.plugins.dialog.*
import stdx.encoding.json.*

/**
 * ai-chat：AI 对话客户端（cj-tauri 示例）
 *
 * 零新命令设计：对话全部经 **http 插件**的 `http:postStream`（SSE 流式）+ `http:get`
 * 出网，配置经 **store 插件**持久化——本应用只做「装配 + 能力清单」，没有一行
 * 自己的网络/存储代码。框架缺口（HTTP 白名单收口 + 流式）由 http 插件承担：
 * - 出网主机白名单写在本目录 `capabilities/app.json` 的 `scopes.http`（page 可控 URL
 *   的第一道闸；没写 = 全拒）；
 * - 流式回复走 `http:chunk` 事件（emitLatest），前端自己解析 SSE 帧（`data:` 行 + [DONE]）。
 *
 * 依赖方向：main.cj 只 import 插件包（子包不得反向 import 应用包）。
 */

let UI_PATH = "ui/index.html"

func envOr(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(v) => return v
        case None => return fallback
    }
}

/** 读前端页面（工作目录 = 工程根：capabilities/ 与 ui/ 按相对路径读）。
    vendor 库在装配期读盘内联进占位符——run(html) 的页面没有真实来源，
    `<script src>` 相对路径取不到文件（markdown-notes 同款机制）。 */
func loadUi(): String {
    var bytes: Array<Byte> = []
    try {
        bytes = File.readFrom(UI_PATH)
    } catch (e: Exception) {
        throw Exception("读不到前端页面 ${UI_PATH}（${e}）——请在 examples/ai-chat 目录下启动")
    }
    return inlineVendor(String.fromUtf8(bytes))
}

/** 把 vendor 库内联进页面占位符。库缺失不致命——高亮退化为无色纯文本，
    不该启动失败，每份读不到只留一行 stderr。 */
func inlineVendor(html: String): String {
    var js = ""
    try {
        js += String.fromUtf8(File.readFrom("ui/vendor/highlight.min.js")) + "\n"
    } catch (e: Exception) {
        eprintln("[cj-ai-chat] vendor 库缺失 ui/vendor/highlight.min.js（代码无高亮）：${e}")
    }
    var out = html.replace("/*__VENDOR_JS__*/", js)
    try {
        let css = String.fromUtf8(File.readFrom("ui/vendor/github-dark.min.css"))
        out = out.replace("/*__VENDOR_CSS__*/", css)
    } catch (e: Exception) {
        eprintln("[cj-ai-chat] vendor 样式缺失 ui/vendor/github-dark.min.css（高亮无配色）：${e}")
    }
    return out
}

/** 读托盘图标（可选）：仓里没有现成 png 就用主题默认（托盘照样出，无阻塞） */
func iconPath(): String {
    let cand = "ui/icon.png"
    try {
        let f = File(Path(cand), OpenMode.Read)
        f.close()
        return cand
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

/** 从 shell 事件信封里取 id（托盘点击 / 快捷键触发都带 `{"kind":…,"id":…}`）；
    解析不了按「无 id」处理，不猜（clipboard-history 同款）。 */
func shellEventId(json: String): String {
    try {
        let root = JsonValue.fromStr(json)
        // JsonKind 没有 ==（AGENTS §4）：枚举比较只能走 match
        let isObj = match (root.kind()) {
            case JsonKind.JsObject => true
            case _ => false
        }
        if (isObj) {
            match (root.asObject().get("id")) {
                case Some(v) =>
                    match (v.kind()) {
                        case JsonKind.JsString => return v.asString().getValue()
                        case _ => ()
                    }
                case None => ()
            }
        }
    } catch (e: Exception) {
        eprintln("[cj-ai-chat] shell event 不是 JSON，按无 id 处理：${e}")
    }
    return ""
}

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
        eprintln("[cj-ai-chat] quit requested by frontend")
        this.app.quit()
        return JsonBool(true)
    }
}

main(): Int64 {
    let win = WindowConfig("AI 对话", 1080, 760)
    win.devTools = true
    win.minimizeToTray = true

    let app = TauriApp()
        .window(win)
        .plugin(HttpPlugin())
        .plugin(LogPlugin())
        .plugin(StorePlugin())
        .plugin(ClipboardPlugin())   // 复制按钮的后端：clipboard:write（消息/代码块一键复制）
        .plugin(WsPlugin())          // cjh 后端通道：ws:frame 事件回投聊天流（cjh web /ws）
        // 工作区「浏览…」：原生目录选择框（dialog:pickFolder）——手输绝对路径的替代路；
        // 不装配会得到 command not registered（新增能力三处联动，漏一处就用不了，见 AGENTS §2）
        .plugin(DialogPlugin())
        // 文件预览：cjh **没有** /api/fs/read，所以内容读自家 fs 插件（fs:readText）。
        // 该插件 scopeAware——能读的范围由 capabilities 的 scopes.fs 决定，不是全放行。
        .plugin(FsPlugin())
        // 日志落盘：GUI 产物双击没控制台，报障时一个文件看全（C 桥 + 仓颉 + 页面 log:write）
        .setLogToDefaultFile("ai-chat")

    // 托盘必须在 start() 之前定稿（RFC-002 §7.C）。对话工具常驻托盘是刚需：
    // 「显示面板」放第一项——窗口藏起来之后只有这里或快捷键回得来。
    let trayMenu = ArrayList<MenuItem>()
    trayMenu.add(MenuItem.normal("show", "显示对话"))
    trayMenu.add(MenuItem.separator())
    trayMenu.add(MenuItem.normal("quit", "退出"))
    app.setTray(TrayModel(iconPath(), "AI 对话", trayMenu))

    // 全局快捷键：Ctrl+Alt+A 唤出面板（对话工具的肌肉记忆位）
    app.setGlobalHotkeys(HotkeyModel().add("Ctrl+Alt+A", "show-panel"))

    // 窗口级 shell 动作：还原可见性只能在原生侧做（页面没有 window.show）；
    // quit 经命令层收口（与 clipboard-history 同款：run 之后框架收尾，不能直接 exit）。
    app.onShellEvent({ json: String, label: String =>
        let _ = label
        eprintln("[cj-ai-chat] shell event: ${json}")
        if (shellEventId(json) == "show" || shellEventId(json) == "show-panel") {
            app.setWindowVisible(true)
        }
    })

    app.register("quit", QuitCommand(app))

    // cjh web 托管：run 之前确保后端就绪（复用已运行的，或按 CJ_AICHAT_CJH spawn）。
    // 数据面不在这层——页面经 ws 插件连 ws://127.0.0.1:<port>/ws、经 http 插件打 /api/…。
    let cjhUp = ensureCjhWeb()
    if (cjhUp) {
        // 托管成功：把 ws 端点告诉页面（document-start，早于页面脚本，见 AGENTS §2）
        let js = "window.__CJH_WS__ = 'ws://127.0.0.1:" + cjhPort().toString() + "/ws';" +
            "window.__CJH_API__ = 'http://127.0.0.1:" + cjhPort().toString() + "';\n"
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[cj-ai-chat] cjh 端点已注入页面")
            case None => eprintln("[cj-ai-chat] 主窗未登记，cjh 端点没注入")
        }
    }

    // 探针模式（CJ_AICHAT_PROBE=1）：注入自检开关，页面跑完一轮经 log:write 回投 stderr
    if (envOr("CJ_AICHAT_PROBE", "") == "1") {
        let js = "window.__CJ_TAURI_SELF_CHECK__ = true;\n"
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[cj-ai-chat] 探针模式已注入")
            case None => eprintln("[cj-ai-chat] 探针模式：主窗未登记，配置没注入")
        }
    }

    // 页面用 run(html) 内联（clipboard-history 同款）：runUrl 的相对路径 WebKit 解析不了
    // （实机踩过：页面显示 The URL can't be shown），file:// 绝对路径可用但内联更省事——
    // 本页面零外部资源（无图片/无 vendor），内联无副作用。
    let html = loadUi()
    app.run(html)
    // run 返回 = 窗口已收尾：只终止**自己拉起的** cjh（复用的不动）
    shutdownCjh()
    return 0
}
