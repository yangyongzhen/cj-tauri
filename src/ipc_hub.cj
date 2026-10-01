package cjTauri

import std.collection.*
import stdx.encoding.json.*

/**
 * 命令处理器接口（对标 Tauri command）
 * 实现方注册到 IpcHub，前端 invoke 时经 capability 校验后调用。
 */
public interface CommandHandler {
    /**
     * 处理命令并返回结果 JSON 值。
     * @param cmd   命令名
     * @param args  前端传入的参数对象
     * @param ipc   IPC 上下文（可发事件、取窗口信息）
     * @return 成功返回值；如需失败可在实现中抛 CommandException
     */
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue
}

/**
 * 命令执行异常：message 将作为 error 返回给前端
 */
public class CommandException <: Exception {
    public init(msg: String) {
        super(msg)
    }
}

/**
 * IPC 上下文：命令执行时可访问
 */
public class IpcContext {
    public let window: String
    private let hub: IpcHub

    public init(window: String, hub: IpcHub) {
        this.window = window
        this.hub = hub
    }

    /**
     * 向当前窗口推送事件
     */
    public func emit(event: String, payload: JsonValue): Unit {
        this.hub.emitToWindow(event, payload, this.window)
    }

    /**
     * 打开开发者工具（宿主实现），供内置 system:devtools 与应用自定义命令使用
     */
    public func openDevTools(): Unit {
        this.hub.openDevTools()
    }
}

/**
 * IPC 中心：命令注册、能力校验、消息分发、事件推送
 */
public class IpcHub {
    private var commands: HashMap<String, CommandHandler> = HashMap<String, CommandHandler>()
    private var capabilities: CapabilityRegistry = CapabilityRegistry()
    // 事件投递通道：由宿主层注入（把 JSON 字符串投递给前端 JS）
    public var jsSink: (String) -> Unit = { _ => }
    // 开发者工具通道：由 TauriApp 注入宿主实现
    public var devToolsSink: () -> Unit = { => }

    public init() {}

    public func setCapabilities(reg: CapabilityRegistry): Unit {
        this.capabilities = reg
    }

    /**
     * 打开开发者工具（宿主注入的实现；未注入时空操作）
     */
    public func openDevTools(): Unit {
        this.devToolsSink()
    }

    public func register(cmd: String, handler: CommandHandler): Unit {
        this.commands.add(cmd, handler)
    }

    public func hasCommand(cmd: String): Bool {
        return this.commands.contains(cmd)
    }

    /**
     * 处理来自前端的原始 invoke 消息（JSON 字符串）
     * 全链路：解析 → capability 校验 → 命令分发 → 结果/错误回写
     */
    public func handleRawMessage(raw: String): Unit {
        if (let Some(req) <- InvokeRequest.parse(raw)) {
            this.handleInvoke(req)
        } else {
            eprintln("[cj-tauri] invalid IPC message: ${raw}")
        }
    }

    private func handleInvoke(req: InvokeRequest): Unit {
        // 1. 能力校验（默认最小权限）
        if (!this.capabilities.canInvoke(req.cmd)) {
            this.reject(req.id, "command not allowed: ${req.cmd}")
            return
        }
        // 2. 命令是否存在
        if (!this.commands.contains(req.cmd)) {
            this.reject(req.id, "command not registered: ${req.cmd}")
            return
        }
        // 3. 执行
        try {
            let handler = this.commands.get(req.cmd).getOrThrow()
            let ctx = IpcContext("main", this)
            let result = handler.handle(req.cmd, req.args, ctx)
            this.jsSink(IpcMessage.resolve(req.id, result))
        } catch (e: CommandException) {
            this.reject(req.id, e.message)
        } catch (e: Exception) {
            this.reject(req.id, "command failed: ${e}")
        }
    }

    private func reject(id: Int64, error: String): Unit {
        this.jsSink(IpcMessage.reject(id, error))
    }

    /**
     * 推送事件到指定窗口（经 capability 校验）
     */
    public func emitToWindow(event: String, payload: JsonValue, window: String): Unit {
        if (!this.capabilities.canEmit(event)) {
            eprintln("[cj-tauri] event not allowed: ${event}")
            return
        }
        this.jsSink(IpcMessage.event(event, payload))
    }
}
