package ohosCapabilities

import cjTauri.*
import cjTauri.plugins.menu.*
import cjTauri.plugins.clipboard.*
import cjTauri.plugins.http.*
import cjTauri.plugins.fs.*
import cjTauri.plugins.mqtt.*
import cjTauri.plugins.redis.*
import cjTauri.plugins.ws.*
import cjTauri.plugins.log.*
import cjTauri.plugins.sqlite.*
import cjTauri.plugins.store.*
import stdx.encoding.json.*
import std.collection.*
@When[env == "ohos"]
import kit.PerformanceAnalysisKit.Hilog

/*
 * 探针回执通道
 *
 * 为什么必须由应用侧写日志：鸿蒙设备上 `eprintln` 不进 hilog（框架 stderr 全不可见，
 * 见 AGENTS §4），而能力位取证又只有「页面断言 → 有人把它打进设备日志」这一条路。
 * 于是探针页把每一条断言经 `probeLog` 命令送进来，这里原样写进 hilog（tag `CjProbe`），
 * `hdc shell hilog` 一抓就能逐条对账。桌面端没有 hilog，退回 stdout。
 */
@When[env == "ohos"]
public func probeLog(text: String): Unit {
    Hilog.info(1, "CjProbe", text)
}

@When[env != "ohos"]
public func probeLog(text: String): Unit {
    println("[CjProbe] ${text}")
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
 * 定时器命令：启动后台线程，每秒向前端推一个 tick 事件（验证 仓颉 → JS 通道）
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

/**
 * 演示菜单：一个普通项 + 一个带勾选项的子菜单
 *
 * 两个方向都在页面上看得到：
 *   菜单 → 页面：点「打个招呼」，宿主把事件推给前端（页面 listen("menu:click") 显示 id）
 *   页面 → 菜单：勾选页面上的复选框，走 menu 插件改「侧边栏」这一项的勾选状态
 */
func demoMenu(): MenuModel {
    var view = ArrayList<MenuItem>()
    view.add(MenuItem.checkbox("view.sidebar", "侧边栏", true))
    var items = ArrayList<MenuItem>()
    items.add(MenuItem.normal("file.hello", "打个招呼"))
    items.add(MenuItem.submenu("视图", view))
    return MenuModel(items)
}

/**
 * 业务装配点（RFC-002 §4.1）：骨架的 launcher（targets/ 下各目标的 src）调用它取 AppSpec。
 *
 * 零平台知识：不碰宿主、不知道页面文件路径、不知道能力目录——那些由清单
 * （cj-tauri.toml）决定，launcher 按清单覆盖（page/window/assets/capabilities）。
 * build() 负责业务自己的部分：命令注册、菜单、插件。
 */
public func build(): AppSpec {
    return AppSpec()
        .window(WindowConfig("ohos-capabilities", 1000, 700))
        // menu 插件：给前端挂 window.__CJ_TAURI__.menu.setEnabled / setChecked
        // （插件只声明「我提供什么」，**不自动放行**——要能调，就在 capabilities 里引用
        //   permissions: ["menu:state"]，或逐条写 commands）
        .plugin(MenuPlugin())
        // clipboard 插件：鸿蒙侧走原生 pasteboard（宿主实现见 host_arkweb.cj），
        // 命令是 clipboard:write / clipboard:read，能力清单里逐条声明才放行
        .plugin(ClipboardPlugin())
        // http 插件：鸿蒙侧走系统网络栈 ohos.net.http（http_ohos.cj）——真机核验
        // RequestMethod.Post/Delete 成员名、extraData 承载 POST 体、https 走 OS 的 TLS、
        // postStream 如实拒绝；主机白名单在 assets/capabilities/default.json 的 scopes.http
        .plugin(HttpPlugin())
        // fs 插件：鸿蒙沙箱内读写——真机核验 scope 相对路径口径与九条命令；
        // 主机白名单在 assets/capabilities/default.json 的 scopes.fs（allow: probe-fs/**）
        .plugin(FsPlugin())
        // mqtt 插件：真机核验明文 TCP 出网（stdx socket 不碰 TLS，预期设备上可用）；
        // 对端用公网明文 broker test.mosquitto.org:1883，自收回环对账（SUBACK + 收到自己的 PUBLISH）
        .plugin(MqttPlugin())
        // redis 插件：真机核验 RESP2 明文 TCP——对端是 PC 上的本仓 mock-redis，
        // 经 `hdc rport tcp:6380 tcp:6379` 反向转发（设备连自己的 127.0.0.1:6380）
        .plugin(RedisPlugin())
        // ws 插件：真机核验 RFC6455 明文握手（stdx WebSocket.upgradeFromClient）——
        // 对端是 PC 上的 python websockets echo，经 `hdc rport tcp:8765 tcp:8765` 反向转发；
        // 主机白名单在 default.json 的 scopes.ws（没写 = 全拒）
        .plugin(WsPlugin())
        // log 插件：真机核验鸿蒙降级契约——writeLogLine 返 false、logFile 回空串
        .plugin(LogPlugin())
        // sqlite 插件：真机核验 FFI 直连——设备与 NDK 都没有 sqlite 库，走 amalgamation
        // （public domain）随包编 so：libsqlite3.so 放 entry/libs/arm64-v8a/ 随 hap 分发，
        // entry link-option 加 -L/-lsqlite3 生成 DT_NEEDED（缺了模块加载期 U 解析失败）
        .plugin(SqlitePlugin())
        // store 插件：真机核验持久化 KV——落盘 <cwd>/store.json（鸿蒙 cwd = el2 files 目录，可写）
        .plugin(StorePlugin())
        .wire({ app =>
            app.register("greet", GreetCommand())
            app.register("timer", TimerCommand())
            // 页面断言写设备日志：能力位取证靠它（见 probeLog 的注释）
            app.register("probeLog", ProbeLogCommand())
            // 菜单栏必须在 run 之前挂：预置类宿主能力要赶在页面加载前定稿
            app.setMenu(demoMenu())
        })
}
