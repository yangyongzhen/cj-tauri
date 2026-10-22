package ohos_app_cangjie_entry

import cjTauri.*
import stdx.encoding.json.*
import kit.PerformanceAnalysisKit.Hilog

/*
 * {{PROJECT_NAME}} 的框架装配（鸿蒙侧）
 *
 * 桌面的 `main()` 在鸿蒙上不成立——鸿蒙应用没有「自己起进程跑一个 main」这回事，
 * 窗口属于 ArkUI、页面由 ArkWeb 组件承载。所以装配被拆成三段：
 *   ① `MainAbility.onCreate`：定沙箱目录（`run(html)` 要把页面落到沙箱再 file:// 加载）
 *   ② `MainAbility.onCreate` 里 `spawn { startTauriApp(...) }`：**必须非 UI 线程**，
 *      `run()` 会阻塞到 quit()，而 UI 线程要留给 ArkUI 建树
 *   ③ `onWindowStageCreate`：等宿主登记 → `loadContent` → 组件里建 `Web`
 *
 * 页面与能力清单的来路：都来自 hap 的 `resources/rawfile/`，由 Ability 读成字符串传进来
 * （设备上没有 `ui/` 与 `capabilities/` 目录，这两份是构建期打进 hap 的）。
 */

/** greet 命令（对标 tauri command）：前端 `tauri.invoke("greet", { name: "..." })` */
public class GreetCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var name = "world"
        if (let Some(n) <- args.get("name")) {
            match (n.kind()) {
                case JsonKind.JsString => name = n.asString().getValue()
                case _ => ()
            }
        }
        return JsonString("Hello, ${name}! 来自仓颉后端（鸿蒙 ArkWeb 宿主）")
    }
}

/**
 * 定时器命令：起一个后台线程，每秒向后端推一个 tick 事件（验证 仓颉 → JS 通道）
 *
 * 鸿蒙侧的 `emit` 同样只入队，真正的投递在 `onProxyPost` 里由页面心跳带出去——
 * 所以页面必须一直在跑（`setInterval` 的心跳由框架的桥脚本负责，业务代码不用管）。
 */
public class TimerCommand <: CommandHandler {
    private var counter: Int64 = 0
    private var started: Bool = false

    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        if (!this.started) {
            this.started = true
            spawn {
                while (true) {
                    sleep(Duration.second)
                    this.counter += 1
                    var payload = JsonObject()
                    payload.put("n", JsonInt(this.counter))
                    ipc.emit("tick", payload)
                }
            }
        }
        return JsonString("timer started")
    }
}

/**
 * 装配并运行框架应用（**必须在非 UI 线程调用**：`run()` 阻塞到 `quit()`）
 *
 * @param windowTitle 窗口标题（ArkUI 侧不起作用，留着与桌面版对齐）
 * @param pageHtml 页面原文（rawfile/index.html）
 * @param capsJson 能力清单原文（rawfile/capabilities.json）；空串表示不挂清单
 */
public func startTauriApp(windowTitle: String, pageHtml: String, capsJson: String): Unit {
    Hilog.info(1, "CjTauri", "startTauriApp begin page=${pageHtml.size}B caps=${capsJson.size}B")

    let app = TauriApp()
        .window(WindowConfig(windowTitle, 1280, 820))
        .register("greet", GreetCommand())
        .register("timer", TimerCommand())

    // 显式挂载能力清单即不自动扫描目录——hap 里本来也没有 capabilities/ 这个目录。
    if (capsJson.size > 0) {
        app.addCapabilityJson(JsonValue.fromStr(capsJson))
        Hilog.info(1, "CjTauri", "capability embedded bytes=${capsJson.size}")
    } else {
        // 空清单 = 一条命令都不放行（含 system:*），页面会看到「command not allowed」。
        // 这比静默放行安全，也比假装成功好排查。
        Hilog.info(1, "CjTauri", "capability missing: rawfile/capabilities.json 没打进 hap，所有命令都会被拒")
    }

    // 阻塞到 quit()：Ability 的生命周期仍归系统管，`run()` 返回不代表进程退出。
    app.run(pageHtml)
    Hilog.info(1, "CjTauri", "after run")
}
