package cjLink

import std.env.*
import std.fs.*
import cjTauri.*
import cjTauri.plugins.serial.*
import cjTauri.plugins.store.*
import stdx.encoding.json.*

/**
 * cj-link：串口/网络二合一调试助手（examples/cj-link）
 *
 * 由 `cj-tauri create cj-link --template app` 起骨架，接入三个官方插件/命令面：
 *  - serial 插件：serial:open/read/write/close（串口链路，hex/utf8 双编码）；
 *  - store 插件：store:get/set（面板配置持久化，store.json，重启恢复）；
 *  - 应用级 link:* 命令：TCP 客户端（connect/send/close）+ 串口枚举薄包装 + 探针 ping。
 *
 * 页面在 `ui/index.html`（不内联三引号字符串，AGENTS §4 反斜杠坑），收发日志、
 * HEX/ASCII 双显、连接面板与自动读循环都在前端；串口读走前端轮询（serial:read），
 * TCP 收走宿主事件推送（link:tcpData）——两条链路的时序特征不同，各自按需取。
 *
 * 探针模式（自动化取证）：CJ_LINK_PROBE=1 时注入预执行脚本，页面自动跑
 * 「串口 open→write→read→close + TCP connect→send→recv→close」并逐项 report 回投 stderr。
 * 其余变量：CJ_LINK_PROBE_SERIAL_PATH / CJ_LINK_PROBE_TCP_HOST / CJ_LINK_PROBE_TCP_PORT / CJ_LINK_PROBE_QUIT。
 *
 * 运行目录 = 本示例根（capabilities/ 与 ui/ 都按项目根相对路径读）。
 */
let UI_PATH = "ui/index.html"

/** 把前端页面读成 HTML 字符串交给 run()（读不到就把「在哪启动」讲清楚，别让人猜） */
func loadUi(): String {
    var bytes: Array<Byte> = []
    try {
        bytes = File.readFrom(UI_PATH)
    } catch (e: Exception) {
        throw Exception("读不到前端页面 ${UI_PATH}（${e}）——请在 examples/cj-link 目录下启动：" +
            "capabilities/ 与 ui/ 都按项目根相对路径读")
    }
    return String.fromUtf8(bytes)
}

/** 把前端每一行回投到 stderr（诊断一律走 stderr，AGENTS §4）——探针取证靠的就是这一条 */
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

/**
 * 前端主动退应用（探针跑完一轮就走）。命令跑在 worker 线程上，quit 在平台层是
 * 「投到 GUI 线程」（Linux 走 g_idle_add），所以从命令里退是安全的。
 */
public class QuitCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let _ = ipc
        eprintln("[cj-link] quit requested by frontend")
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

main(): Int64 {
    eprintln("[cj-link] main start")

    let link = LinkCommands()
    let app = TauriApp()
        .window(WindowConfig("cj-Link · 串口/网络调试助手", 1180, 780))
        .plugin(SerialPlugin())                    // 串口能力
        .plugin(StorePlugin())                     // 配置持久化（store.json）
        .register("link:serialList", link)         // link:* 全部共用一个处理器
        .register("link:tcpConnect", link)
        .register("link:tcpSend", link)
        .register("link:tcpClose", link)
        .register("link:ping", link)
        .register("report", ReportCommand())
    link.attachApp(app)                            // TCP 读线程要 emit 事件，装配后注入
    app.register("quit", QuitCommand(app))         // 要引用 app 本身，这条不串在链上

    // 探针模式：把配置经 document-start 预执行脚本注入页面（JSON 编码器拼字面量，反斜杠自动转义）
    if (envOr("CJ_LINK_PROBE", "") == "1") {
        let serialPath = envOr("CJ_LINK_PROBE_SERIAL_PATH", "")
        let tcpHost = envOr("CJ_LINK_PROBE_TCP_HOST", "127.0.0.1")
        let tcpPort = envOr("CJ_LINK_PROBE_TCP_PORT", "15021")
        let quit = envOr("CJ_LINK_PROBE_QUIT", "1")
        let js = "window.__LINK_PROBE__ = { serialPath: " + JsonString(serialPath).toJsonString() +
            ", tcpHost: " + JsonString(tcpHost).toJsonString() +
            ", tcpPort: " + JsonString(tcpPort).toJsonString() +
            ", quit: " + JsonString(quit).toJsonString() + " };\n"
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[cj-link] 探针模式：serialPath=${serialPath} tcp=${tcpHost}:${tcpPort} quit=${quit}")
            case None => eprintln("[cj-link] 探针模式：主窗未登记，配置没注入")
        }
    }

    let html = loadUi()
    eprintln("[cj-link] 前端页面已载入：${UI_PATH}（${html.size} 字节）")
    app.run(html)
    eprintln("[cj-link] after run")
    return 0
}
