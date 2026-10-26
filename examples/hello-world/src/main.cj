package helloWorld

import cjTauri.*
import stdx.encoding.json.*

/**
 * 后端命令：对标 tauri 的 command。前端用 window.__CJ_TAURI__.invoke("greet", {...}) 调它。
 */
public class GreetCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
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
 * 业务装配点：骨架的 launcher（targets/ 下各目标的 src）调用它取 AppSpec。
 * 只写业务自己的部分——命令注册；页面路径、窗口、能力目录都由 cj-tauri.toml 决定。
 */
public func build(): AppSpec {
    return AppSpec()
        .window(WindowConfig("hello-world", 800, 560))
        .wire({ app =>
            // 新命令在这里 register；别忘了去 assets/capabilities/default.json 放行
            app.register("greet", GreetCommand())
        })
}
