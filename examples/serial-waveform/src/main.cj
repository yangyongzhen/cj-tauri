package serial_waveform

import std.env.*
import cjTauri.*
import cjTauri.plugins.serial.*
import stdx.encoding.json.*

/**
 * 串口实时波形示波器（examples/serial-waveform）
 *
 * 为什么单独做一个：`serial-assistant` 是收发日志工具、`modbus-poll` 是轮询取值，
 * 两个示例的页面都**没有画过图**（0 处 canvas）——「采集到的东西实时变成波形」这一档是空白，
 * 而它恰好是串口类桌面应用最直观、也最适合当门面的形态：一眼看懂，且是别的 Web 框架
 * 碰不到的活（浏览器打不开串口）。
 *
 * 页面放 `ui/index.html` 而不是内联三引号字符串：这一页有 canvas 绘制、控制面板与统计，
 * 内联进 `"""` 会踩两个坑——① 三引号字符串会处理反斜杠转义（AGENTS §4 实测），
 * ② 字符串插值 `${...}` 与 JS 模板字面量同形。独立文件后两个坑都不存在。
 *
 * 数据协议（ASCII 行协议，真实仪器里最常见的那一种）：
 *   应用 → 设备:  "SCAN" 开始连续输出 / "STOP" 暂停
 *   设备 → 应用:  每行 "<序号>,<值>"，值域 -1.0..1.0
 * 页面把 `serial:read` 拿到的文本按行切分、逐行解析成样本点——**不预设设备型号**，
 * 只要按这个行协议说话就能画（换成真实传感器只需改解析函数）。
 *
 * 权限：清单引用命名集 serial:default（open/read/write/close 一次放行）——
 * 示波器要发 SCAN 指令（写）再连续读，readonly 不够。
 *
 * 两种跑法：
 *   手动：起窗口，填设备路径点「连接」→ 页面发 SCAN，波形开始滚。
 *   探针：设 CJ_SERIAL_PROBE_PATH 后启动，应用把配置经 **document-start 预执行脚本**注入页面，
 *        页面自动 连接 → 发 SCAN → 收 N 毫秒 → 打一行统计并（默认）自退，证据全在 stderr。
 *        其它环境变量：CJ_SERIAL_PROBE_BAUD / MS / QUIT(0|1)。
 *        Linux 一键跑通见 run.sh（python3 pty 造虚拟示波器对端，不需要真设备，也不需要 socat）。
 *
 * 运行目录 = 本示例根（capabilities/ 与 ui/ 都按项目根相对路径读）。
 */
let UI_PATH = "ui/index.html"

/** 把前端页面读成 HTML 字符串交给 run()（内嵌优先；读盘失败就把「在哪启动」讲清楚，别让人猜） */
func loadUi(): String {
    return textOrFile(PACKED_UI_B64, UI_PATH, "前端页面")
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
        eprintln("[serial-waveform] quit requested by frontend")
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
    eprintln("[serial-waveform] main start")

    let app = TauriApp()
        .window(WindowConfig("串口实时波形 · cj-tauri", 1180, 760))
        .plugin(SerialPlugin())                    // 串口能力：一行接入
        .register("report", ReportCommand())
    app.register("quit", QuitCommand(app))         // 要引用 app 本身，所以这条不串在链上

    // 探针模式：给了设备路径就把配置注入页面（document-start，早于页面脚本）。
    // 字面量用 JSON 编码器拼——Windows 的 \\.\COM3 这种路径里的反斜杠自动转义，不必手写。
    let probePath = envOr("CJ_SERIAL_PROBE_PATH", "")
    if (probePath.size > 0) {
        let baud = envOr("CJ_SERIAL_PROBE_BAUD", "115200")
        let ms = envOr("CJ_SERIAL_PROBE_MS", "2500")
        let quit = envOr("CJ_SERIAL_PROBE_QUIT", "1")
        let js = "window.__WAVE_PROBE__ = { path: " + JsonString(probePath).toJsonString() +
            ", baud: " + JsonString(baud).toJsonString() +
            ", ms: " + JsonString(ms).toJsonString() +
            ", quit: " + JsonString(quit).toJsonString() + " };\n"
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[serial-waveform] 探针模式：path=${probePath} baud=${baud} ms=${ms} quit=${quit}")
            case None => eprintln("[serial-waveform] 探针模式：主窗未登记，配置没注入")
        }
    }

    // 能力清单：内嵌优先（单文件产物没有随行的 capabilities/），否则交给 run() 自动扫描目录。
    // 框架契约是「显式挂载即不自动扫描」，所以两条路互斥、不会叠加或打架。
    if (PACKED_CAPS_B64.size > 0) {
        // 打包器把每个 capabilities/*.json 各自 base64、再用 "," 拼起来（base64 表里没有逗号）；
        // 逐个挂载而不是拼成一份 json——每份清单在框架里本来就是一个独立的 Capability。
        var n: Int64 = 0
        for (part in splitBy(PACKED_CAPS_B64, 44u8)) {
            app.addCapabilityJson(JsonValue.fromStr(decodeBase64(part)))
            n += 1
        }
        eprintln("[serial-waveform] 能力清单来自内嵌资源（${n} 份，共 ${PACKED_CAPS_B64.size} 字节 base64）")
    }

    let html = loadUi()
    eprintln("[serial-waveform] 前端页面已载入：${UI_PATH}（${html.size} 字节）")
    app.run(html)
    eprintln("[serial-waveform] after run")
    return 0
}
