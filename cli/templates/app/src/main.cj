package {{PACKAGE_NAME}}

import cjTauri.*
import stdx.encoding.json.*
import std.fs.File
import std.collection.*

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

main(): Int64 {
    // 1) 装配应用（对标 tauri::Builder）：窗口配置 + 注册命令
    //    能力清单由框架在 run() 时自动扫描 capabilities/ 目录（对标 Tauri 的 capabilities 目录）
    let app = TauriApp()
        .window(WindowConfig("cj-tauri 应用", 1000, 700))
        .register("greet", GreetCommand())
        .register("timer", TimerCommand())
        // menu 插件：给前端挂 window.__CJ_TAURI__.menu.setEnabled / setChecked
        // （插件只声明「我提供什么」，**不自动放行**——要能调，就在 capabilities 里引用
        //   permissions: ["menu:state"]，或逐条写 commands）
        .plugin(MenuPlugin())
        // 菜单栏必须在 run() 之前挂：预置类宿主能力要赶在页面加载前定稿
        .setMenu(demoMenu())

    // 2) 载入前端页面并启动（阻塞至窗口关闭）
    let html = String.fromUtf8(File.readFrom("ui/index.html"))
    app.run(html)
    return 0
}
