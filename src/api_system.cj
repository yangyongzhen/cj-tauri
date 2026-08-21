package cjTauri

import stdx.encoding.json.*

/**
 * 内置系统命令（对标 Tauri core 命令）
 * 命令命名空间：system:*
 */
public class SystemCommands <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "system:version" => this.version()
            case "system:ping" => this.ping(args)
            case "system:echo" => this.echo(args)
            case _ => throw CommandException("unknown system command: ${cmd}")
        }
    }

    private func version(): JsonValue {
        var obj = JsonObject()
        obj.put("name", JsonString("cj-tauri"))
        obj.put("version", JsonString("0.1.0"))
        obj.put("cangjie", JsonString("1.0.5"))
        obj.put("platform", JsonString("linux"))
        return obj
    }

    private func ping(args: JsonObject): JsonValue {
        return JsonString("pong")
    }

    private func echo(args: JsonObject): JsonValue {
        // 原样返回 args（作为 JsonValue 包装）
        return args
    }
}
