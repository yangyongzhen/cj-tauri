package e2efixture

import cjTauri.*
import cjTauri.plugins.*
import std.fs.*
import stdx.encoding.json.*

/**
 * probe:echo —— 把页面传来的字符串**打一行到 stderr**。
 *
 * 为什么必须有这条命令：桥自己的 `js -> native (N bytes)` 只能证明「页面说了话」，
 * 证明不了报文被解析、命令被路由、结果回了页面。探针页把一轮往返的结果整体传进来，
 * 这一行就是端到端闭环的凭证——E2E 断言按它取证据，而不是按「看起来跑起来了」。
 */
public class ProbeEcho <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        var line = ""
        if (let Some(v) <- args.get("line")) {
            match (v.kind()) {
                case JsonKind.JsString => line = v.asString().getValue()
                case _ => ()
            }
        }
        eprintln("[e2e] probe:echo 收到: " + line)
        return JsonString("echo:" + line)
    }
}

main(): Int64 {
    eprintln("[e2e] fixture-app start")
    // 探针页从磁盘读：改页面不用重编译。路径按**本工程根**解析，启动器会先切到本目录
    // （与 capabilities/、ui/ 全按相对路径读的约定一致）。
    let html = String.fromUtf8(File.readFrom("ui/index.html"))
    let winCfg = WindowConfig("cj-tauri e2e fixture", 900, 640)
    let app = TauriApp()
        .window(winCfg)
        .register("probe:echo", ProbeEcho())
        // 三个插件探针：clipboard（Windows 真实现）/ notification（Windows 桩，如实报失败）/
        // serial（Windows 真实现：QueryDosDeviceW 枚举 + Win32 API 读写）。
        // 探针页对每一位各调一次，把「真实现能通 / 桩如实拒绝」都落到证据日志里。
        .plugin(ClipboardPlugin())
        .plugin(NotificationPlugin())
        .plugin(SerialPlugin())
        // 拖放策略在 start 前定稿（RFC-002 §5）：Linux 实机已取证挂载/落地全链；
        // Windows 走 OLE IDropTarget 真实现——挂载日志与能力位随 E2E 对账。
        .setDragDrop(DragDropPolicy(true, true))
    eprintln("[e2e] fixture-app before run")
    app.run(html)
    eprintln("[e2e] fixture-app after run")
    return 0
}
