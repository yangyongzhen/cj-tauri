package todo_check

import cjTauri.*

import stdx.encoding.json.*


/**
 * add 命令：把前端传来的两个数相加
 * 前端：tauri.invoke("add", { a: 2, b: 3 }) -> 5
 */
public class AddCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var a: Int64 = 0
        var b: Int64 = 0
        if (let Some(x) <- args.get("a")) {
            match (x.kind()) {
                case JsonKind.JsInt => a = x.asInt().getValue()
                case _ => ()
            }
        }
        if (let Some(y) <- args.get("b")) {
            match (y.kind()) {
                case JsonKind.JsInt => b = y.asInt().getValue()
                case _ => ()
            }
        }
        return JsonInt(a + b)
    }
}

public class TimerCommand <: CommandHandler {
    private var counter: Int64 = 0
    private var started: Bool = false

    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        if (!this.started) {
            this.started = true
            spawn {                                  // 起一个后台线程持续推事件
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
