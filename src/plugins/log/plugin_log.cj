package cjTauri.plugins.log

import cjTauri.*

import std.collection.*
import stdx.encoding.json.*

/**
 * 官方插件 log：把**前端**的诊断并进宿主日志（RFC-003 第 5 期）
 *
 * 命令：log:write（追加一行）/ log:path（回读生效中的日志文件，空串＝没开）
 * 权限：**不自动放行**，应用在 capabilities 里显式声明，两种写法等价：
 *   "commands": ["log:write", "log:path"]   // 明文逐条
 *   "permissions": ["log:default"]          // 命名权限集（两条都放行）
 * 前端：window.__CJ_TAURI__.log.write("...") / log.path()
 *
 * 为什么需要它：框架的落盘接管的是 **C 桥与仓颉侧**的 stderr，而页面里的 JS 报错在交付给
 * 用户的单文件产物里同样无处可去（GUI 子系统、双击没有控制台）。插件把页面诊断经命令
 * 送回宿主，落进**同一份**文件——报障时只看一个文件，不用两台机器对着时间戳拼。
 *
 * shim 顺带装上 `error` / `unhandledrejection` 两个钩子：页面自己没写日志也能留下异常。
 * 钩子里**必须吞掉** invoke 的失败（命令未放行时它会 reject），否则钩子自己又造出一轮
 * 未捕获拒绝，转成停不下来的自激。
 */
public class LogPlugin <: Plugin {
    public init() {}

    public func name(): String {
        return "log"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        // 键写**短名**：前缀由框架补（写全名会得到 log:log:write，且所有命令都成未注册）
        m.add("write", LogCommands())
        m.add("path", LogCommands())
        return m
    }

    /** 命名权限集（v1.1）：default = 写 + 回读路径（回读能问到本机目录布局，不该默认放宽） */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let all = ArrayList<String>()
        all.add("write")
        all.add("path")
        m.add("default", all)
        return m
    }

    /**
     * 前端 shim：`__CJ_TAURI__.log` + 两个全局异常钩子（都在 document-start 装，早于页面脚本）
     *
     * 内联 JS 里**不出现反斜杠**（转义会先被仓颉吃掉，AGENTS §4）；拼接用 `+`，
     * 不用模板串，免得 `${}` 撞上仓颉的字符串插值。
     */
    public func jsShim(): String {
        return "(function () { var t = window.__CJ_TAURI__ || (window.__CJ_TAURI__ = {});" +
            " t.log = {" +
            " write: function (line) { return window.__CJ_TAURI__.invoke('log:write', { line: String(line) }); }," +
            " path: function () { return window.__CJ_TAURI__.invoke('log:path', {}); }" +
            " };" +
            " var push = function (line) { try { var p = t.log.write(line);" +
            " if (p && p.catch) { p.catch(function () {}); } } catch (e) {} };" +
            " window.addEventListener('error', function (ev) {" +
            " var where = ev.filename ? (ev.filename + ':' + ev.lineno + ':' + ev.colno) : 'unknown';" +
            " push('[frontend] error: ' + (ev.message || 'unknown') + ' @ ' + where); });" +
            " window.addEventListener('unhandledrejection', function (ev) {" +
            " push('[frontend] unhandled rejection: ' + String(ev.reason)); });" +
            " })();\n"
    }
}

/** 日志命令处理器：write 收 { line }，path 无参 */
public class LogCommands <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = ipc
        match (cmd) {
            case "log:write" =>
                let line = this.requireString(args, "line")
                if (line.size > CJ_LOG_MAX_LINE) {
                    // 不按字节切字符串（会把汉字切碎）：超长就只记一条说明，
                    // 免得页面用一行天文数字把内存和日志文件一起撑爆
                    let note = "[frontend] log line dropped: ${line.size} bytes exceeds ${CJ_LOG_MAX_LINE}"
                    return JsonBool(writeLogLine(note))
                }
                // false = 没开日志（这一轮没落盘），不是错误：页面照常跑，别让它变成 reject
                return JsonBool(writeLogLine(line))
            case "log:path" =>
                return JsonString(currentLogFilePath()) // 空串 = 没开
            case _ => throw CommandException("unknown log command: ${cmd}")
        }
    }

    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => throw CommandException("log: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("log: missing argument \"${key}\"")
        }
    }
}
