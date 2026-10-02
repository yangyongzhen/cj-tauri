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
    // 后端事件监听器（对标 Tauri 的 Rust 侧 Listener）：事件名 → 处理函数。
    // 只在前端 emit 时被调用；后端自己 emit 给前端的事件**不**回流到这里（否则「后端广播 → 监听器再广播」会自激）。
    private var eventListeners: HashMap<String, ArrayList<(JsonValue) -> Unit>> =
        HashMap<String, ArrayList<(JsonValue) -> Unit>>()

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
     * 注册后端事件监听器（对标 Tauri Rust 侧的 `app.listen(...)`）
     *
     * 调用时机：装配期（插件在自己的 setup() 里注册）。同一事件可注册多个监听器，按注册顺序调用；
     * 暂时不提供注销（emit 分发是遍历快照式的短回调，注册期外再改表属于未定义用法）。
     */
    public func listenEvent(event: String, handler: (JsonValue) -> Unit): Unit {
        if (!this.eventListeners.contains(event)) {
            this.eventListeners.add(event, ArrayList<(JsonValue) -> Unit>())
        }
        this.eventListeners.get(event).getOrThrow().add(handler)
    }

    /**
     * 处理来自前端的原始消息（JSON 字符串）：invoke 与 emit 两条路径
     *
     * 全链路：解析 → capability 校验（调用线程上同步完成）→ 执行（worker 线程）→ 结果/错误回投
     */
    public func handleRawMessage(raw: String): Unit {
        if (let Some(req) <- InvokeRequest.parse(raw)) {
            this.handleInvoke(req)
            return
        }
        if (let Some(ev) <- EmitRequest.parse(raw)) {
            this.handleEmit(ev)
            return
        }
        // 两条解析都不认：只要报文里读得出 id 就回一条 reject——前端那条 promise 否则会永久 pending，
        // 比一条明确的报错难排查得多（前端 invoke 没有超时参数）。
        eprintln("[cj-tauri] invalid IPC message: ${raw}")
        if (let Some(id) <- IpcMessage.peekId(raw)) {
            this.reject(id, "invalid IPC message")
        }
    }

    /**
     * 校验与执行分两段，这是当前的线程模型（改之前想清楚，见 RFC-001 §8 第 8 条）：
     *   1/2. 「未授权」「未注册」在**调用线程上同步**拒绝——前端拿到的报错要即时、顺序确定，
     *        也免得为一条注定失败的请求白开一个线程；
     *   3.   真正执行挪到 worker 线程（spawn）。此前 handler 直接在宿主 UI 线程上跑完，
     *        慢命令（`shell:exec` 跑一个进程、等原生对话框）会把窗口钉住——不重绘、不响应事件。
     * 结果经 jsSink 回投即可：两平台桥的 runJs 都是「加锁入队 + 投递到宿主 UI 线程」
     * （bridge_linux.c 的 g_idle_add → flush_pending_js，bridge_win.c 的 PostMessageW(WM_CJT_FLUSH) → flush_js），
     * 从任意线程调用都安全。也正因如此，worker 里**不要**绕过桥直接调 GTK / WebKit：
     * 仓颉轻量线程的堆上协程栈会被 JSC 的栈边界校验 abort（AGENTS.md §4）。
     * 同一命令被并发调用**不保证执行顺序**（前端按 promise id 匹配，不会串包）。
     */
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
        // 3. 交给 worker 线程执行：调用线程立刻返回，UI 不被命令阻塞
        let _ = spawn { => this.runCommand(req) }
    }

    /** worker 线程上的实际执行：跑完（或抛错）就把 resolve / reject 回投给前端 */
    private func runCommand(req: InvokeRequest): Unit {
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
     * 前端 emit 事件：校验（同步，调用线程）→ 投给后端监听器（worker 线程）→ resolve。
     *
     * 为什么校验同步、投递异步：与命令同一套理由——未授权要在调用线程上立刻拒（报错即时、顺序确定），
     * 而回调可能慢，不能钉住宿主 UI 线程。
     * 「没有监听器」不是错误：事件是广播语义，没人听很正常（Tauri 同样不报），照常 resolve。
     * 与 Tauri 的差异（不广播回页面）见 EmitRequest 的文档注释。
     */
    private func handleEmit(req: EmitRequest): Unit {
        if (!this.capabilities.canEmit(req.event)) {
            eprintln("[cj-tauri] event not allowed: ${req.event}")
            this.reject(req.id, "event not allowed: ${req.event}")
            return
        }
        let _ = spawn { => this.dispatchEvent(req) }
    }

    /** worker 线程上把事件投给监听器，然后 resolve 发送方 */
    private func dispatchEvent(req: EmitRequest): Unit {
        match (this.eventListeners.get(req.event)) {
            case Some(handlers) =>
                for (h in handlers) {
                    // 单个监听器抛错只记 stderr：事件是广播，一个听众崩了不该牵连别的听众和发送方
                    try {
                        h(req.payload)
                    } catch (e: Exception) {
                        eprintln("[cj-tauri] event listener failed (${req.event}): ${e}")
                    }
                }
            case None => ()
        }
        this.jsSink(IpcMessage.resolve(req.id, JsonObject()))
    }

    /**
     * 广播事件到所有窗口（对标 Tauri 的 `emit`）：报文不带 window 字段，各窗口的桥自行放行。
     * 多窗口落地前 jsSink 只通向那一个窗口，与 `emitToWindow(..., "main")` 效果相同。
     */
    public func emitAll(event: String, payload: JsonValue): Unit {
        this.emitToWindow(event, payload, "")
    }

    /**
     * 推送事件到指定窗口（经 capability 校验）
     *
     * @param window 接收窗口的 label；空串 = 广播。此前这个参数被丢掉（报文里也无 window 字段），
     *               定向推送实际退化成广播——协议补上字段后，多窗口的过滤由各页面的桥完成。
     */
    public func emitToWindow(event: String, payload: JsonValue, window: String): Unit {
        if (!this.capabilities.canEmit(event)) {
            eprintln("[cj-tauri] event not allowed: ${event}")
            return
        }
        this.jsSink(IpcMessage.event(event, payload, window))
    }
}
