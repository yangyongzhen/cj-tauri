package mqtt_client

import std.env.*
import std.fs.*
import cjTauri.*
import cjTauri.plugins.mqtt.*
import stdx.encoding.json.*

/**
 * MQTT 3.1.1 调试台（examples/mqtt-client）
 *
 * 为什么单独做一个：框架的 `mqtt` 插件是**库**，库的价值要靠一个能对着真实 broker 用的界面体现出来——
 * 而调试工具最需要的三件事恰好插件都给了：① 报文流（哪个方向上、什么时候、什么主题、什么载荷）；
 * ② 连接状态（连上没、为什么掉）；③ 可对账的计数（收发条数、丢弃条数）。
 *
 * 页面放 `ui/index.html` 而不是内联三引号字符串：这一页有报文列表与表单，内联进 `"""` 会踩两个坑——
 * ① 三引号字符串会处理反斜杠转义（AGENTS §4 实测），② 字符串插值 `${...}` 与 JS 模板字面量同形。
 *
 * 权限：清单引用命名集 `mqtt:debug`（七个命令一次放行）；事件 `mqtt:message` / `mqtt:state`
 * 也必须在清单里声明，否则页面收不到（框架会打一行 stderr 提示）。
 *
 * 两种跑法：
 *   手动：起窗口，填 host/port（默认 127.0.0.1:1883）→ 连接 → 订阅 / 发布。
 *   探针：设 CJ_MQTT_PROBE_HOST 后启动，应用把配置经 **document-start 预执行脚本**注入页面，
 *        页面自动 连接 → 订阅 → 发布 → 等回推 → 取 recent → 重连 → 打统计并（默认）自退，
 *        证据全在 stderr（`[frontend]` 与 `[cj-tauri] mqtt:` 两条前缀）。
 *        其它环境变量：CJ_MQTT_PROBE_PORT / MS / QUIT(0|1)。
 *        Linux 一键跑通见 run.sh（自带 python3 mock broker，不需要装 broker）。
 *
 * 运行目录 = 本示例根（capabilities/ 与 ui/ 都按项目根相对路径读）。
 */
let UI_PATH = "ui/index.html"

/** 读前端页面（未做单文件打包，所以直接读盘；读不到就把「在哪启动」讲清楚，别让人猜） */
func loadUi(): String {
    try {
        return String.fromUtf8(File.readFrom(UI_PATH))
    } catch (e: Exception) {
        eprintln("[mqtt-client] 读不到 ${UI_PATH}（${e.message}）——工作目录必须是本示例根目录")
        return "<html><body><h1>ui/index.html 未找到</h1>" +
            "<p>请在 examples/mqtt-client 目录下启动本示例。</p></body></html>"
    }
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
 * 前端主动退应用（探针跑完一轮就走，自动化脚本才好收尾）
 *
 * 命令跑在 worker 线程上，而 quit 在平台层是「投到 GUI 线程」的（Linux 走 g_idle_add），
 * 所以从命令里退是安全的——GTK / WebView2 的调用仍留在宿主那条线程上。
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
        eprintln("[mqtt-client] quit requested by frontend")
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
    eprintln("[mqtt-client] main start")

    let app = TauriApp()
        .window(WindowConfig("MQTT 调试台 · cj-tauri", 1180, 780))
        .plugin(MqttPlugin())                      // MQTT 能力：一行接入
        .register("report", ReportCommand())
    app.register("quit", QuitCommand(app))         // 要引用 app 本身，所以这条不串在链上

    // 探针模式：给了 host 就把配置注入页面（document-start，早于页面脚本）。
    // 字面量用 JSON 编码器拼——省掉手写转义，也避免三引号字符串吃反斜杠（AGENTS §4）。
    let probeHost = envOr("CJ_MQTT_PROBE_HOST", "")
    if (probeHost.size > 0) {
        let port = envOr("CJ_MQTT_PROBE_PORT", "1883")
        let ms = envOr("CJ_MQTT_PROBE_MS", "6000")
        let quit = envOr("CJ_MQTT_PROBE_QUIT", "1")
        let js = "window.__MQTT_PROBE__ = { host: " + JsonString(probeHost).toJsonString() +
            ", port: " + JsonString(port).toJsonString() +
            ", ms: " + JsonString(ms).toJsonString() +
            ", quit: " + JsonString(quit).toJsonString() + " };\n"
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[mqtt-client] 探针模式：host=${probeHost} port=${port} ms=${ms} quit=${quit}")
            case None => eprintln("[mqtt-client] 探针模式：主窗未登记，配置没注入")
        }
    }

    // 能力清单交给 run() 自动扫描 capabilities/（显式挂载即不自动扫描，两条路互斥）。
    let html = loadUi()
    eprintln("[mqtt-client] 前端页面已载入：${UI_PATH}（${html.size} 字节）")
    app.run(html)
    eprintln("[mqtt-client] after run")
    return 0
}
