package clipboardHistory

import std.env.*
import std.fs.*
import std.collection.*
import cjTauri.*
import cjTauri.plugins.clipboard.*
import cjTauri.plugins.store.*
import stdx.encoding.json.*

/**
 * clipboard-history：剪贴板历史管理器（工具计划④）
 *
 * 框架两个新能力位的首个消费者：**托盘**（TrayModel；Linux 走 libayatana-appindicator3、
 * Windows 走 Shell_NotifyIconW）+ **全局快捷键**（HotkeyModel；Linux 走 X11 grab、
 * Windows 走 RegisterHotKey）。历史捕获与回写**零新命令**——
 * 前端 500ms 轮询 `clipboard:read` 去重入历史，回写 `clipboard:write`；托盘点击与快捷键
 * 由框架自动投前端事件 `tray:click` / `hotkey:press`（capability events 已声明）。
 *
 * 仓颉侧只做装配（§2 架构契约：IPC/分发/校验共用，平台差异只在桥）：
 *  - 托盘：图标 + 菜单（显示面板、清空、退出）——`start()` 之前定稿；
 *  - 全局快捷键：Ctrl+Alt+V 唤出面板——同在 `start()` 之前；
 *  - 最小化到托盘：`WindowConfig.minimizeToTray`（点最小化 = 藏进托盘，还原走托盘菜单/快捷键）；
 *  - shell 事件：**窗口级动作走原生**（窗口藏起来之后页面还在跑，却没有办法把自己显出来，
 *    只有 `setWindowVisible` 做得到）；页面级动作（清空 / 聚焦搜索框）交给框架投的前端事件。
 *
 * 探针模式（CJ_CLIP_PROBE=1）：预执行脚本注入配置，页面自动跑「写剪贴板→轮询捕获→
 * 历史断言→点击回写→外部回读」并逐项 report 回投 stderr；对端由 E2E 脚本用 xclip 扮演。
 */
let UI_PATH = "ui/index.html"

/** 读前端页面（工作目录 = 工程根：capabilities/ 与 ui/ 按相对路径读） */
func loadUi(): String {
    var bytes: Array<Byte> = []
    try {
        bytes = File.readFrom(UI_PATH)
    } catch (e: Exception) {
        throw Exception("读不到前端页面 ${UI_PATH}（${e}）——请在 examples/clipboard-history 目录下启动")
    }
    return String.fromUtf8(bytes)
}

/** 页面逐行回投 stderr（诊断一律走 stderr，AGENTS §4）——E2E 取证靠这一条 */
public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        if (let Some(line) <- args.get("line")) {
            match (line.kind()) {
                case JsonKind.JsString => eprintln("[frontend] " + line.asString().getValue())
                case _ => ()
            }
        }
        return JsonBool(true)
    }
}

/** 前端主动退应用（探针跑完一轮就走；quit 在平台层投 GUI 线程，命令里调是安全的） */
public class QuitCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let _ = ipc
        eprintln("[cj-clip] quit requested by frontend")
        this.app.quit()
        return JsonBool(true)
    }
}

func envOr(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(v) => return v
        case None => return fallback
    }
}

func iconPath(): String {
    // 图标可选：仓里没有现成 png 就用主题默认（托盘照样出，无阻塞）。
    // File 没有 exists 静态方法：开一下就知道（打不开当没有）。
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

/** 从 shell 事件信封里取 id（托盘点击 / 快捷键触发都带 `{"kind":…,"id":…}`）。
    解析不了按「无 id」处理——与 core 侧「没有 id 的点击无法路由」同一口径，不猜。 */
func shellEventId(json: String): String {
    try {
        let root = JsonValue.fromStr(json)
        match (root.kind()) {
            case JsonKind.JsObject =>
                match (root.asObject().get("id")) {
                    case Some(v) =>
                        match (v.kind()) {
                            case JsonKind.JsString => return v.asString().getValue()
                            case _ => ()
                        }
                    case None => ()
                }
            case _ => ()
        }
    } catch (e: Exception) {
        eprintln("[cj-clip] shell event 不是 JSON，按无 id 处理：${e}")
    }
    return ""
}

main(): Int64 {
    eprintln("[cj-clip] main start")

    // 最小化到托盘：点标题栏「最小化」不再缩到任务栏，而是把窗口**藏起来**（还原走托盘菜单
    // 「显示面板」或 Ctrl+Alt+V）。必须与 setTray 配套——真到最小化那一刻，平台会复核托盘是否
    // 真的装上了，没装就如实降级为普通最小化 + 一行 stderr（契约见 WindowConfig.minimizeToTray）。
    let win = WindowConfig("剪贴板历史 · cj-tauri", 1080, 760)
    win.minimizeToTray = true

    let app = TauriApp()
        .window(win)
        .plugin(ClipboardPlugin())                 // 剪贴板读写（clipboard:read/write）
        .plugin(StorePlugin())                     // 历史与偏好持久化（store.json）
        .register("report", ReportCommand())

    // 托盘必须在 start() 之前定稿（RFC-002 §7.C：赶在页面加载前；默认窗经 hostOf 回落拿得到）。
    // 「显示面板」放在第一项：窗口藏进托盘之后，用户只有从这里或快捷键回得来。
    let trayMenu = ArrayList<MenuItem>()
    trayMenu.add(MenuItem.normal("show", "显示面板"))
    trayMenu.add(MenuItem.normal("clear", "清空历史"))
    trayMenu.add(MenuItem.separator())
    trayMenu.add(MenuItem.normal("quit", "退出"))
    app.setTray(TrayModel(iconPath(), "剪贴板历史", trayMenu))

    // 全局快捷键同在 start() 之前：Ctrl+Alt+V 唤出面板
    let hotkeys = HotkeyModel().add("Ctrl+Alt+V", "show-panel")
    app.setGlobalHotkeys(hotkeys)

    // 应用侧 shell 钩子（可叠加）：框架已把 tray/hotkey 自动投前端，这里补**窗口级**动作。
    // 窗口藏起来之后页面照样在跑，但它没有任何办法把自己显出来（没有 window.show——那正是
    // 本能力位存在的理由），所以「还原可见性」只能在原生侧做；「清空历史 / 聚焦搜索框」这类
    // 页面级动作由前端事件处理器做（见 ui/index.html 的 listen）。
    app.onShellEvent({ json: String, label: String =>
        let _ = label
        eprintln("[cj-clip] shell event: ${json}")
        let id = shellEventId(json)
        if (id == "show" || id == "show-panel") {
            app.setWindowVisible(true)
            eprintln("[cj-clip] panel restored by ${id}")
        }
    })

    app.register("quit", QuitCommand(app))

    // 探针配置注入（document-start，与页面脚本约定 __CLIP_PROBE__）
    if (envOr("CJ_CLIP_PROBE", "") == "1") {
        let quit = envOr("CJ_CLIP_PROBE_QUIT", "1")
        let js = "window.__CLIP_PROBE__ = { quit: " + JsonString(quit).toJsonString() + " };\n"
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[cj-clip] 探针模式已注入（quit=${quit}）")
            case None => eprintln("[cj-clip] 探针模式：主窗未登记，配置没注入")
        }
    }

    let html = loadUi()
    eprintln("[cj-clip] 前端页面已载入：${UI_PATH}（${html.size} 字节）")
    app.run(html)
    eprintln("[cj-clip] after run")
    return 0
}
