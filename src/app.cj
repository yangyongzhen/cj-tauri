package cjTauri

import stdx.encoding.json.*

/**
 * TauriApp 装配（对标 tauri::Builder / App）
 *
 * 用法：
 *   let app = TauriApp()
 *   app.register("greet", GreetCommand())
 *   app.addCapabilityJson(...)   // 或 addCapability(cap)
 *   app.run(html)                // 启动宿主并阻塞
 */
public class TauriApp {
    private var hub: IpcHub = IpcHub()
    private var capabilities: CapabilityRegistry = CapabilityRegistry()
    private var host: WebViewHost = createHost()
    private var started: Bool = false

    public init() {}

    /**
     * 注册命令处理器
     */
    public func register(cmd: String, handler: CommandHandler): TauriApp {
        this.hub.register(cmd, handler)
        return this
    }

    /**
     * 从 JSON 添加 capability 清单
     */
    public func addCapabilityJson(json: JsonValue): TauriApp {
        this.capabilities.addFromJson(json)
        return this
    }

    /**
     * 直接添加 capability
     */
    public func addCapability(cap: Capability): TauriApp {
        this.capabilities.add(cap)
        return this
    }

    /**
     * 向所有窗口推送事件（经 capability 校验）
     */
    public func emit(event: String, payload: JsonValue): Unit {
        this.hub.emitToWindow(event, payload, "main")
    }

    /**
     * 启动应用：装配 IPC → 启动 WebView 宿主 → 阻塞运行
     */
    public func run(html: String): Unit {
        if (this.started) {
            throw CommandException("app already started")
        }
        this.started = true

        // 注入内置系统命令
        this.hub.register("system:version", SystemCommands())
        this.hub.register("system:ping", SystemCommands())
        this.hub.register("system:echo", SystemCommands())
        this.hub.setCapabilities(this.capabilities)

        // 装配：宿主消息 → IPC hub；hub 输出 → 宿主 JS
        this.host.setMessageHandler({ raw =>
            this.hub.handleRawMessage(raw)
        })
        this.hub.jsSink = { json =>
            // JSON 本身就是合法 JS 对象字面量，直接嵌入（toJsonString 已转义字符串内特殊字符）
            let js = "window.postMessage(${json}, '*');"
            this.host.runJs(js)
        }

        this.host.start(html)

        // 阻塞等待：宿主事件循环退出（窗口关闭 / quit）后返回
        var spins: Int64 = 0
        while (!this.host.shouldQuit() && spins < 360_000) {  // 最长 ~1 小时（10ms 步进）
            sleep(Duration.millisecond * 10)
            spins += 1
        }
    }
}
