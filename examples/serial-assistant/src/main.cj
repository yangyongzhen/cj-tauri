package serialAssistant

import std.fs.*
import std.env.*
import cjTauri.*
import stdx.encoding.json.*

/**
 * 串口调试助手（examples/serial-assistant）
 *
 * 由 `cj-tauri create serial-assistant --template app` 起骨架，再接入官方 serial 插件：
 * 参数面板（设备 / 波特率 / 数据位 / 校验 / 停止位）+ 收发日志（TX/RX、hex 与文本双视图）+
 * 计数器，一个「真的能用」的小工具，也是 serial 插件第一个业务向样板。
 *
 * 页面放在 `ui/index.html`（与 movie 同一套做法）而不内联三引号字符串：
 * 这个前端是一整页 UI（样式 + 收发日志 + 自动读循环），内联进 `"""`
 * 会踩两个坑——① 三引号字符串处理反斜杠转义，JS 的 `\n` 会被先吃掉把 `<script>` 拆断
 * （AGENTS.md §4 实测踩过）；② 字符串插值 `${...}` 与 JS 模板字面量同形。
 * 独立成文件后两个坑都不存在。
 *
 * 权限：清单引用命名集 serial:default（open/read/write/close 一次放行）——
 * 调试助手天生要双向收发，所以用 default 而不是 readonly。
 *
 * 两种跑法：
 *   手动：起窗口，填设备路径点「连接」，在发送区敲数据收发。
 *   探针：设 CJ_SERIAL_PROBE_PATH 后启动，应用把配置经 document-start 预执行脚本注入页面，
 *        页面自动连上虚拟串口跑一轮 收 → 发 → 收 并把每步经 report 回投 stderr
 *        （Linux 一键跑通见 run.sh：python3 pty 造虚拟串口对，不需要真设备）。
 *        其它环境变量：CJ_SERIAL_PROBE_BAUD / DATA / READ_MS / QUIT(0|1)。
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
        throw Exception("读不到前端页面 ${UI_PATH}（${e}）——请在 examples/serial-assistant 目录下启动：" +
            "capabilities/ 与 ui/ 都按项目根相对路径读")
    }
    return String.fromUtf8(bytes)
}

/** 把前端每一行回投到 stderr（诊断一律走 stderr，AGENTS §4）——探针取证靠的就是这一条 */
public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
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
 * 前端主动退应用（探针跑完一轮就走，自动化脚本才好收尾）
 *
 * 命令跑在 worker 线程上，而 quit 在平台层是「投到 GUI 线程」的（Linux 走 g_idle_add），
 * 所以从命令里退是安全的——GTK 的调用仍留在宿主那条线程上。
 */
public class QuitCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        eprintln("[serial-assistant] quit requested by frontend")
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
    eprintln("[serial-assistant] main start")

    let app = TauriApp()
        .window(WindowConfig("串口调试助手 · cj-tauri", 1180, 780))
        .plugin(SerialPlugin())                    // 串口能力：一行接入
        .register("report", ReportCommand())
    app.register("quit", QuitCommand(app))         // 要引用 app 本身，所以这条不串在链上

    // 探针模式：给了设备路径就把配置注入页面（document-start，早于页面脚本）。
    // 字面量用 JSON 编码器拼——Windows 的 \\.\COM3 这种路径里的反斜杠自动转义，不必手写。
    let probePath = envOr("CJ_SERIAL_PROBE_PATH", "")
    if (probePath.size > 0) {
        let baud = envOr("CJ_SERIAL_PROBE_BAUD", "115200")
        let data = envOr("CJ_SERIAL_PROBE_DATA", "cj-tauri-ping")
        let readMs = envOr("CJ_SERIAL_PROBE_READ_MS", "500")
        let quit = envOr("CJ_SERIAL_PROBE_QUIT", "1")
        let js = "window.__SERIAL_PROBE__ = { path: " + JsonString(probePath).toJsonString() +
            ", baud: " + JsonString(baud).toJsonString() +
            ", data: " + JsonString(data).toJsonString() +
            ", readMs: " + JsonString(readMs).toJsonString() +
            ", quit: " + JsonString(quit).toJsonString() + " };\n"
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[serial-assistant] 探针模式：path=${probePath} baud=${baud} data=${data}" +
                    " readMs=${readMs} quit=${quit}")
            case None => eprintln("[serial-assistant] 探针模式：主窗未登记，配置没注入")
        }
    }

    let html = loadUi()
    eprintln("[serial-assistant] 前端页面已载入：${UI_PATH}（${html.size} 字节）")
    app.run(html)
    eprintln("[serial-assistant] after run")
    return 0
}
