package redis_client

import std.env.*
import std.fs.*
import cjTauri.*
import cjTauri.plugins.redis.*
import stdx.encoding.json.*

/**
 * Redis 客户端调试台（examples/redis-client）
 *
 * 为什么单独做一个：框架的 `redis` 插件是**库**，库的价值要靠一个对着真服务器可用的界面来体现——
 * 键空间浏览要能一眼看出「这键什么类型、多大、还有多久过期」，取值要能**按类型**给出对的形状
 * （hash 看字段、zset 看分值、stream 看条目），而发布订阅那条线是**另一条连接**，掉线原因也得能看。
 *
 * 页面放 `ui/index.html` 而不是内联三引号字符串：这一页有键列表、值面板与消息流，内联进 `"""` 会踩两个坑——
 * ① 三引号字符串会处理反斜杠转义（AGENTS §4 实测），② 字符串插值 `${...}` 与 JS 模板字面量同形。
 *
 * 权限：清单引用命名集 `redis:default`（十九条命令一次放行）；事件 `redis:message` / `redis:state`
 * 也必须在清单里声明，否则页面收不到（框架会打一行 stderr 提示）。
 *
 * 两种跑法：
 *   手动：起窗口，填 host/port（默认 127.0.0.1:6379）→ 连接 → 浏览键空间 / 取值改值 / 发布订阅。
 *   探针：设 CJ_REDIS_PROBE_HOST 后启动，应用把配置经 **document-start 预执行脚本**注入页面，
 *        页面自动 连接 → 查服务器信息与键空间 → 取值改值 → 建键删键 → 发布订阅收发 → 拉缓冲 → 重连
 *        → 打统计并（默认）自退，证据全在 stderr（`[frontend]` 与 `[cj-tauri] redis` 两条前缀）。
 *        其它环境变量：CJ_REDIS_PROBE_PORT / DB / MS / QUIT(0|1)。
 *        Linux 一键跑通见 run.sh（自带 python3 mock 对端，不需要装 redis-server）。
 *
 * 运行目录 = 本示例根（capabilities/ 与 ui/ 都按项目根相对路径读）。
 */
let UI_PATH = "ui/index.html"

/** 读前端页面（未做单文件打包，所以直接读盘；读不到就把「在哪启动」讲清楚，别让人猜） */
func loadUi(): String {
    try {
        return String.fromUtf8(File.readFrom(UI_PATH))
    } catch (e: Exception) {
        eprintln("[redis-client] 读不到 ${UI_PATH}（${e.message}）——工作目录必须是本示例根目录")
        return "<html><body><h1>ui/index.html 未找到</h1>" +
            "<p>请在 examples/redis-client 目录下启动本示例。</p></body></html>"
    }
}

/** 把前端每一行回投到 stderr（诊断一律走 stderr，AGENTS §4）——探针取证靠的就是这一条 */
public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        if (let Some(line) <- args.get("line")) {
            match (line.kind()) {
                case JsonKind.JsString => eprintln("[frontend] " + line.asString().getValue())
                case _ => ()
            }
        }
        return JsonBool(true)
    }
}

/**
 * 前端主动退应用（探针跑完一轮就走，自动化脚本才好收尾）
 *
 * 命令跑在 worker 线程上，而 quit 在平台层是「投到 GUI 线程」的（Linux 走 g_idle_add），
 * 所以从命令里退是安全的——GTK / WebView2 的调用仍留在宿主那条线程上。
 */
public class QuitCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let _ = ipc
        eprintln("[redis-client] quit requested by frontend")
        this.app.quit()
        return JsonBool(true)
    }
}

func envOr(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(v) => return v
        case None => return fallback
    }
}

main(): Int64 {
    eprintln("[redis-client] main start")

    let app = TauriApp()
        .window(WindowConfig("Redis 调试台 · cj-tauri", 1280, 820))
        .plugin(RedisPlugin())                     // Redis 能力：一行接入
        .register("report", ReportCommand())
    app.register("quit", QuitCommand(app))         // 要引用 app 本身，所以这条不串在链上

    // 探针模式：给了 host 就把配置注入页面（document-start，早于页面脚本）。
    // 字面量用 JSON 编码器拼——省掉手写转义，也避免三引号字符串吃反斜杠（AGENTS §4）。
    let probeHost = envOr("CJ_REDIS_PROBE_HOST", "")
    if (probeHost.size > 0) {
        let port = envOr("CJ_REDIS_PROBE_PORT", "6379")
        let db = envOr("CJ_REDIS_PROBE_DB", "0")
        let ms = envOr("CJ_REDIS_PROBE_MS", "8000")
        let quit = envOr("CJ_REDIS_PROBE_QUIT", "1")
        let js = "window.__REDIS_PROBE__ = { host: " + JsonString(probeHost).toJsonString() +
            ", port: " + JsonString(port).toJsonString() +
            ", db: " + JsonString(db).toJsonString() +
            ", ms: " + JsonString(ms).toJsonString() +
            ", quit: " + JsonString(quit).toJsonString() + " };\n"
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[redis-client] 探针模式：host=${probeHost} port=${port} db=${db} ms=${ms} quit=${quit}")
            case None => eprintln("[redis-client] 探针模式：主窗未登记，配置没注入")
        }
    }

    // 能力清单交给 run() 自动扫描 capabilities/（显式挂载即不自动扫描，两条路互斥）。
    let html = loadUi()
    eprintln("[redis-client] 前端页面已载入：${UI_PATH}（${html.size} 字节）")
    app.run(html)
    eprintln("[redis-client] after run")
    return 0
}
