/**
 * HTTP API 客户端示例（零 Node、零构建）
 *
 * 页面是**独立的 ui/index.html**（理由同 markdown-notes：仓颉三引号会先吃掉反斜杠转义，
 * 内联进去等于让整段 `<script>` 静默语法错误；独立文件还能被 `node --check` 验语法），
 * 所以页面上**一次 fetch 都没有**——能拿到的数据全走 IPC。
 *
 * 分层：网络那一层在 `src/http_client.cj`（不认识 IPC，见该文件头注释），
 * 这里只做「入参搬运 → 发一次 → 结果拼 JSON → 回投」。
 *
 * 能力面（capabilities/default.json）：
 *  - `http:send` / `http:allow`——示例**自己注册**的命令，不是插件：HTTP 客户端的能力面就是
 *    「任意 URL」，做成插件等于给所有应用开一条通用出网通道（docs/设计决策记录.md D-017）；
 *  - `fs:default`——集合 / 历史 / 环境变量集落 `data/`。**命令放行 ≠ 路径放行**：
 *    scope 只允许 `$CWD/data` 及其下；
 *  - `report`——页内自检逐条回投（E2E 靠这些行取证）。
 *
 * 白名单来自环境变量 `CJ_HTTP_ALLOW`，缺省**只放本机**；页面读不到进程环境，
 * 所以「现在放行谁」由 `http:allow` 交给页面显示。
 */
package http_client

import cjTauri.*
import cjTauri.plugins.fs.*
import std.collection.*
// Int64.parse 来自 std.convert 的 parsable 扩展，不导入就是「undeclared identifier 'parse'」
import std.convert.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*

/** 自检回投：每条断言一行，与 markdown-notes 同款（页面侧拼好文案，宿主侧只负责打） */
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
 * `http:allow`：把宿主侧的白名单与自检参数交给页面
 *
 * 页面没有进程环境，而「放行谁」「跑不跑自检」「mock 在哪」都必须由**启动它的脚本**决定
 * （这也是 E2E 能无人值守的原因：对端地址由环境给，不写死在页面里）。
 */
public class AllowCommand <: CommandHandler {
    private let allow: HostAllowList
    private let selfCheck: Bool
    private let mockBase: String
    private let bodyLimit: Int64

    public init(allow: HostAllowList, selfCheck: Bool, mockBase: String, bodyLimit: Int64) {
        this.allow = allow
        this.selfCheck = selfCheck
        this.mockBase = mockBase
        this.bodyLimit = bodyLimit
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let _ = ipc
        let out = JsonObject()
        let arr = JsonArray()
        for (h in this.allow.items()) {
            arr.add(JsonString(h))
        }
        out.put("allow", arr)
        out.put("describe", JsonString(this.allow.describe()))
        out.put("allowAny", JsonBool(this.allow.allowAny()))
        out.put("selfcheck", JsonBool(this.selfCheck))
        out.put("mockBase", JsonString(this.mockBase))
        out.put("bodyLimit", JsonInt(this.bodyLimit))
        out.put("defaultTimeoutMs", JsonInt(HTTP_DEFAULT_TIMEOUT_MS))
        return out
    }
}

/** 从 JSON 入参取字符串（类型不对就当没给，不在这一层报错——校验交给网络层统一出文案） */
func argString(args: JsonObject, key: String, fallback: String): String {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return fallback
            }
        case None => return fallback
    }
}

/** 从 JSON 入参取整数，并夹到 [min, max]：页面能传的东西都要当不可信输入（越界值会让转换抛异常） */
func argIntClamped(args: JsonObject, key: String, fallback: Int64, min: Int64, max: Int64): Int64 {
    var v = fallback
    match (args.get(key)) {
        case Some(raw) =>
            match (raw.kind()) {
                case JsonKind.JsInt => v = raw.asInt().getValue()
                case _ => ()
            }
        case None => ()
    }
    if (v < min) {
        return min
    }
    if (v > max) {
        return max
    }
    return v
}

/**
 * 请求头入参：`[{ "name": "...", "value": "..." }, ...]`
 *
 * 用数组而不是对象：同名头可以合法地出现多次（`Cookie` 之类），对象键会静默吞掉重复项，
 * 而调试工具的职责恰恰是「把用户写的东西原样发出去」。空名直接丢（发了也没意义）。
 */
func argHeaders(args: JsonObject): ArrayList<(String, String)> {
    let out = ArrayList<(String, String)>()
    match (args.get("headers")) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsArray =>
                    let arr = v.asArray()
                    var i: Int64 = 0
                    while (i < arr.size()) {
                        // JsonArray.get(i) 给的是 Option（越界就是 None），得先拆开再取 kind
                        match (arr.get(i)) {
                            case Some(item) =>
                                match (item.kind()) {
                                    case JsonKind.JsObject =>
                                        let o = item.asObject()
                                        let name = argString(o, "name", "").trimAscii()
                                        if (name.size > 0) {
                                            // 先落成局部元组再 add：直接写 add((a, b)) 会被当成两个实参
                                            let pair = (name, argString(o, "value", ""))
                                            out.add(pair)
                                        }
                                    case _ => ()
                                }
                            case None => ()
                        }
                        i += 1
                    }
                case _ => ()
            }
        case None => ()
    }
    return out
}

/**
 * `http:send`：发一次请求
 *
 * 返回的是**响应本身**（状态码 / 头 / 体 / 耗时 / 截断标记），4xx-5xx 也照常返回而不是当异常
 * ——调试工具必须把错误响应当作结果（D-017 第 6 条）。只有三类会抛（页面看到 reject）：
 * scheme 不支持 / host 不在白名单 / 传输层失败（连不上、超时）。
 */
public class SendCommand <: CommandHandler {
    private let allow: HostAllowList
    private let bodyLimit: Int64

    public init(allow: HostAllowList, bodyLimit: Int64) {
        this.allow = allow
        this.bodyLimit = bodyLimit
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        // HTTP 方法名大小写敏感：页面传 get 也得按 GET 发，否则对端多半回 501
        let method = argString(args, "method", "GET").trimAscii().toAsciiUpper()
        if (method.size == 0) {
            throw CommandException("HTTP 方法为空")
        }
        let url = argString(args, "url", "").trimAscii()
        if (url.size == 0) {
            throw CommandException("请求地址为空")
        }
        var body: Option<String> = None
        if (args.containsKey("body")) {
            body = Some(argString(args, "body", ""))
        }
        // 超时 1ms - 120s，体上限 1B - 64MiB：都在这里夹死，别让页面传个负数或天文数字
        let timeout = argIntClamped(args, "timeoutMs", HTTP_DEFAULT_TIMEOUT_MS, 1, 120000)
        let limit = argIntClamped(args, "bodyLimit", this.bodyLimit, 1, 64 * 1024 * 1024)

        match (sendHttp(method, url, argHeaders(args), body, timeout, limit, this.allow)) {
            case Exchange(x) => return x.toJson()
            case Refused(reason) => throw CommandException(reason)
            case Failed(msg) => throw CommandException("请求失败：${msg}")
        }
    }
}

/** 读前端页面；读不到要说清「在哪启动」，否则报错只有一个找不到的路径 */
func readUi(path: String): String {
    try {
        return String.fromUtf8(File.readFrom(path))
    } catch (e: Exception) {
        eprintln("[http-client] 读不到前端页面 ${path}：${e}")
        eprintln("[http-client] 请在示例根目录启动（ui/ 与 capabilities/ 都按相对路径解析）")
        return ""
    }
}

main(): Int64 {
    var selfCheck = false
    if (let Some(v) <- getVariable("CJ_HTTP_SELFCHECK")) {
        if (v == "1") {
            selfCheck = true
        }
    }
    var mockBase = ""
    if (let Some(v) <- getVariable("CJ_HTTP_MOCK_BASE")) {
        mockBase = v
    }
    // 体上限可调，但只在合理范围内认：环境是启动者给的，仍不该让一个 typo 变成 0 字节上限
    var bodyLimit = HTTP_DEFAULT_BODY_LIMIT
    if (let Some(v) <- getVariable("CJ_HTTP_BODY_LIMIT")) {
        try {
            let n = Int64.parse(v)
            if (n >= 1 && n <= 64 * 1024 * 1024) {
                bodyLimit = n
            }
        } catch (e: Exception) {
            bodyLimit = HTTP_DEFAULT_BODY_LIMIT
        }
    }

    let html = readUi("ui/index.html")
    if (html.size == 0) {
        return 1
    }

    let allow = HostAllowList.fromEnv()
    eprintln("[http-client] main start (selfcheck=${selfCheck}, allow=${allow.describe()}, bodyLimit=${bodyLimit})")

    let app = TauriApp()
        .window(WindowConfig("cj-tauri HTTP 客户端", 1240, 780))
        .plugin(FsPlugin())
        .register("report", ReportCommand())
        .register("http:allow", AllowCommand(allow, selfCheck, mockBase, bodyLimit))
        .register("http:send", SendCommand(allow, bodyLimit))

    app.run(html)
    eprintln("[http-client] after run")
    return 0
}
