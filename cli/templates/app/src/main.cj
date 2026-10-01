package {{PACKAGE_NAME}}

import cjTauri.*
import stdx.encoding.json.*
import std.fs.File

/**
 * greet 命令（对标 tauri command）
 * 前端：tauri.invoke("greet", { name: "..." })
 */
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
        return JsonString("Hello, ${name}! 来自仓颉后端")
    }
}

/**
 * 定时器命令：启动后台线程，每秒向后端推一个 tick 事件（验证 仓颉 → JS 通道）
 * 前端：tauri.listen("tick", cb) + tauri.invoke("timer")
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

main(): Int64 {
    // 1) 载入能力清单（对标 capabilities/*.json，默认最小权限）
    let capJson = JsonValue.fromStr(String.fromUtf8(File.readFrom("capabilities/default.json")))

    // 2) 装配应用（对标 tauri::Builder）：注册命令 + 挂载能力
    let app = TauriApp()
        .register("greet", GreetCommand())
        .register("timer", TimerCommand())
        .addCapabilityJson(capJson)

    // 3) 载入前端页面并启动（阻塞至窗口关闭）
    let html = String.fromUtf8(File.readFrom("ui/index.html"))
    app.run(html)
    return 0
}
