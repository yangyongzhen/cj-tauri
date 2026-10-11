package mbpoll_app

// cj-tauri 示例：Modbus Poll 调试工具（Modbus TCP）
//
// 页面为什么独立成 ui/index.html 而不是内联三引号字符串（与 examples/music 同一个取舍）：
// ① 三引号字符串会处理反斜杠转义，JS 里的 \n、正则会先被仓颉吃掉，整段 <script> 静默变语法错误；
// ② 字符串插值 ${...} 与 JS 模板字面量同形。这两条都在 AGENTS §4。
//
// 内置从站：CJ_MB_SLAVE=1 时在本进程里起一个 Modbus TCP 从站（127.0.0.1，默认 15020），
// 页面自检连它做读写往返闭环；调真实设备时它也可以当对照组。

import std.fs.*
import stdx.encoding.json.*
import cjTauri.*

let MB_UI_PATH = "ui/index.html"

main(): Int64 {
    eprintln("[mbpoll] main start")
    let slaveOn = mbSlaveEnabled()
    if (slaveOn) {
        mbSlaveStart(mbSlavePort(), MbSlaveData())
        eprintln("[mbpoll] 内置从站已启用（CJ_MB_SLAVE=1，端口 ${mbSlavePort()}）")
    } else {
        eprintln("[mbpoll] 内置从站未启用（设 CJ_MB_SLAVE=1 开启，用于自检/对照）")
    }

    // 多面板平铺的调试界面要够宽：1280 起步，两个面板并排不挤
    let winCfg = WindowConfig("Modbus Poll (cj-tauri) · Modbus TCP 调试", 1320, 860)

    var app = TauriApp().window(winCfg)
    app.register("mb:read", MbReadCommand())
    app.register("mb:write", MbWriteCommand())
    app.register("mb:trace", MbTraceCommand())
    app.register("mb:export", MbExportCommand())
    app.register("mb:import", MbImportCommand())
    app.register("mb:config", MbConfigCommand())
    app.register("report", MbReportCommand())
    app.register("mb:quit", MbQuitCommand(app))
    // 能力清单：内嵌优先（单文件产物没有随行的 capabilities/），否则交给 run() 自动扫描目录。
    // 框架契约是「显式挂载即不自动扫描」，所以两条路互斥、不会叠加或打架。
    if (PACKED_CAPS_B64.size > 0) {
        // 打包器把每个 capabilities/*.json 各自 base64、再用 "," 拼起来（base64 表里没有逗号）；
        // 逐个挂载而不是拼成一份 json——每份清单在框架里本来就是一个独立的 Capability。
        var n: Int64 = 0
        for (part in splitBy(PACKED_CAPS_B64, 44u8)) {
            app.addCapabilityJson(JsonValue.fromStr(decodeBase64(part)))
            n += 1
        }
        eprintln("[mbpoll] 能力清单来自内嵌资源（${n} 份，共 ${PACKED_CAPS_B64.size} 字节 base64）")
    }

    // 页面同样内嵌优先：仓库内构建从 ui/ 读盘（改页面刷新即见效），单文件产物从二进制里解
    let html = textOrFile(PACKED_UI_B64, MB_UI_PATH, "前端页面")
    if (html.size == 0) {
        eprintln("[mbpoll] 前端页面读不到：${MB_UI_PATH}（必须从项目根 examples/modbus-poll 启动）")
        return 2
    }
    eprintln("[mbpoll] 前端页面已载入：${MB_UI_PATH}（${html.size} 字节）")
    app.run(html)
    eprintln("[mbpoll] after run")
    return 0
}
