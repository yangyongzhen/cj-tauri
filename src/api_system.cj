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
            case "system:devtools" => this.devTools(ipc)
            case "system:host" => this.hostCapabilities(ipc)
            case _ => throw CommandException("unknown system command: ${cmd}")
        }
    }

    private func version(): JsonValue {
        var obj = JsonObject()
        obj.put("name", JsonString("cj-tauri"))
        obj.put("version", JsonString(CJ_TAURI_VERSION))
        obj.put("cangjie", JsonString("1.0.5"))
        obj.put("platform", JsonString(currentPlatform()))
        return obj
    }

    private func ping(args: JsonObject): JsonValue {
        return JsonString("pong")
    }

    private func echo(args: JsonObject): JsonValue {
        // 原样返回 args（作为 JsonValue 包装）
        return args
    }

    /** 打开开发者工具（需在 capability 中声明 system:devtools 才可调用） */
    private func devTools(ipc: IpcContext): JsonValue {
        ipc.openDevTools()
        return JsonBool(true)
    }

    /**
     * 宿主能力位（RFC-002 §5.3）：平台**有没有**菜单 / 托盘 / 文件拖入
     *
     * 与「应用放不放行」是两回事：能力位说「这台机器上的框架支不支持」，capability 清单说
     * 「这个应用准不准」，两者都要过才叫真能用——放行了但平台没有，事件永远不会出现。
     * 取**调用方那个窗口**的位域（多窗口下可能不同，如 Linux 托盘取决于桥怎么编的）。
     * 与 `system:*` 的其它命令一样，需在清单里声明 `system:host` 才可调用（三处联动）。
     */
    private func hostCapabilities(ipc: IpcContext): JsonValue {
        return HostCapabilities.fromBits(currentPlatform(), ipc.hostCapabilities()).toJson()
    }
}
