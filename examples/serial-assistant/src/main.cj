package serialAssistant

import cjTauri.*
import cjTauri.plugins.serial.*
import stdx.encoding.json.*
import std.env.*
@When[env == "ohos"]
import kit.PerformanceAnalysisKit.Hilog

/**
 * 串口调试助手（examples/serial-assistant）—— 新形态（RFC-002 §7）
 *
 * 参数面板（设备 / 波特率 / 数据位 / 校验 / 停止位）+ 收发日志（TX/RX、hex 与文本双视图）+
 * 计数器，一个「真的能用」的小工具，也是 serial 插件第一个业务向样板。
 *
 * ## 这个文件只放业务
 *
 * 旧形态把页面路径（`ui/index.html`）、窗口尺寸、能力目录（`capabilities/`）都写在这里，
 * 新形态一律交给清单 `cj-tauri.toml` 决定，由 `cj-tauri sync` 派生的骨架 launcher 落实：
 *   - 页面 → `[assets] page = "ui/index.html"`（资产根是 `assets/`）
 *   - 尺寸 / 标题 → `[[windows]]`
 *   - 能力清单 → `[capabilities] dir = "assets/capabilities"`
 * 所以下面 `build()` 里没有一处平台知识，桌面与鸿蒙共用这一份（RFC §7.3）。
 *
 * ## 两种探针（真机取证的唯一自动通道）
 *
 * 页面读 `window.__SERIAL_PROBE__` 决定跑不跑自动流程，这份配置由 `build()` 里的
 * `installProbeScript` 经 `addInitScript` 注入（早于页面脚本执行）：
 *   - **回环探针**（桌面）：设 `CJ_SERIAL_PROBE_PATH` 指向对端 pty / COM 口，页面自动跑
 *     收 → 发 → 收一轮并经 `report` 回投 stderr（Linux 见 run.sh，Windows 见 run.bat）。
 *   - **设备自检**（鸿蒙）：设备上没有环境变量，于是由 `deviceProbeEnabled()` 注入
 *     `deviceProbe: true`，页面改为「枚举候选节点 → 逐个尝试 open → 如实报 errno」，
 *     每条经 `probeLog` 写进 hilog（tag `CjSerialProbe`）——**设备上 eprintln 不进 hilog**
 *     （AGENTS §4），这是唯一能在 `hdc shell hilog` 里逐条对账的通道。
 *
 * 权限：能力清单引用命名集 `serial:default`（open/read/write/close 一次放行）——
 * 调试助手天生要双向收发，所以用 default 而不是 readonly。
 */

/** 前端主动退应用（探针跑完一轮就走，自动化脚本才好收尾） */
public class QuitCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let _ = ipc
        eprintln("[serial-assistant] quit requested by frontend")
        this.app.quit()
        return JsonBool(true)
    }
}

/** 把前端每一行回投到 stderr（桌面取证靠它；鸿蒙侧走 probeLog 进 hilog） */
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
 * 探针回执通道（鸿蒙取证用）：页面 `invoke("probeLog", { text })` → 设备日志
 *
 * 为什么不能只靠 `report`：设备上 `eprintln` 不进 hilog，框架与业务的 stderr 全都看不见，
 * 于是「页面断言 → 有人在设备日志里记下来」是唯一可对账的链路。
 */
@When[env == "ohos"]
public func probeLog(text: String): Unit {
    Hilog.info(1, "CjSerialProbe", text)
}

@When[env != "ohos"]
public func probeLog(text: String): Unit {
    eprintln("[CjSerialProbe] " + text)
}

/** 页面断言落日志：`tauri.invoke("probeLog", { text })` */
public class ProbeLogCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        var text = ""
        if (let Some(t) <- args.get("text")) {
            match (t.kind()) {
                case JsonKind.JsString => text = t.asString().getValue()
                case _ => ()
            }
        }
        probeLog(text)
        return JsonBool(true)
    }
}

/** 设备自检开关：只有鸿蒙侧默认开（桌面由 `CJ_SERIAL_PROBE_PATH` 显式开启回环探针） */
@When[env == "ohos"]
func deviceProbeEnabled(): Bool {
    return true
}

@When[env != "ohos"]
func deviceProbeEnabled(): Bool {
    return false
}

func envOr(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(v) => return v
        case None => return fallback
    }
}

/**
 * 把探针配置注入页面（document-start，早于页面脚本）
 *
 * 字面量用 JSON 编码器拼：Windows 的 `\\.\COM3` 这种路径里的反斜杠自动转义，不必手写。
 * 注入时机：`wire` 闭包拿到装配中的 app，默认窗经 `hostOf(DEFAULT_WINDOW_LABEL)` 有回落，
 * `run()` 之前也拿得到（AGENTS §2「预置类宿主能力」那条的口径）。
 */
func installProbeScript(app: TauriApp): Unit {
    let probePath = envOr("CJ_SERIAL_PROBE_PATH", "")
    let baud = envOr("CJ_SERIAL_PROBE_BAUD", "115200")
    let data = envOr("CJ_SERIAL_PROBE_DATA", "cj-tauri-ping")
    let readMs = envOr("CJ_SERIAL_PROBE_READ_MS", "500")
    let quit = envOr("CJ_SERIAL_PROBE_QUIT", "1")
    let devProbe = deviceProbeEnabled()
    // 桌面既没给对端路径、又不是鸿蒙：什么都不注入，页面就是普通的手动模式
    if (probePath.size == 0 && !devProbe) {
        return
    }
    let js = "window.__SERIAL_PROBE__ = { path: " + JsonString(probePath).toJsonString() +
        ", baud: " + JsonString(baud).toJsonString() +
        ", data: " + JsonString(data).toJsonString() +
        ", readMs: " + JsonString(readMs).toJsonString() +
        ", quit: " + JsonString(quit).toJsonString() +
        ", deviceProbe: " + (if (devProbe) { "true" } else { "false" }) + " };\n"
    match (app.hostOf("main")) {
        case Some(host) =>
            host.addInitScript(js)
            eprintln("[serial-assistant] 探针配置已注入：path=\"${probePath}\" baud=${baud}" +
                " deviceProbe=${devProbe}")
        case None => eprintln("[serial-assistant] 探针配置没注入：主窗未登记")
    }
}

/**
 * 业务装配点（RFC-002 §4.1）：骨架的 launcher（targets/ 下各目标的 src）调用它取 AppSpec。
 *
 * 零平台知识：不碰宿主、不知道页面文件路径、不知道能力目录——那些由清单
 * （cj-tauri.toml）决定，launcher 按清单覆盖（page/window/assets/capabilities）。
 * build() 负责业务自己的部分：命令注册、插件。
 */
public func build(): AppSpec {
    eprintln("[serial-assistant] build start（业务包 serialAssistant）")
    // 尺寸与清单 [[windows]] 一致：launcher 会按清单再覆盖一次，两处一致是「清单为单一真相」
    // 的体现，这里只是给人看的默认值
    let spec = AppSpec()
        .window(WindowConfig("串口调试助手 · cj-tauri", 1180, 780))
        .plugin(SerialPlugin())                    // 串口能力：一行接入
        .wire({ app =>
            app.register("report", ReportCommand())
            app.register("probeLog", ProbeLogCommand())
            app.register("quit", QuitCommand(app)) // 要引用 app 本身，所以在闭包里注册
            installProbeScript(app)
        })
    return spec
}
