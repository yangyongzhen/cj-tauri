package cjTauri

import std.collection.*
import std.fs.*
import std.process.*
import stdx.encoding.json.*

/**
 * 官方插件 shell：把文件 / URL 交给系统默认程序打开；执行子进程并取回输出（对标 Tauri 的 shell 插件）
 *
 * 命令：shell:open / shell:exec
 * 权限：**不自动放行**，应用要在 capabilities 里显式声明，两种写法等价：
 *   "commands": ["shell:open"]              // 明文逐条
 *   "permissions": ["shell:allow-open"]     // 命名权限集（v1.1，只放行「打开」）
 * 前端：window.__CJ_TAURI__.shell.exec({ program: "git", args: ["rev-parse", "HEAD"] })
 *
 * 安全边界（改代码时不要放松）：本插件**不经过 shell**——program 与每个参数都作为独立 argv 元素直接
 * 交给子进程，没有 `cmd /c` / `bash -c` 的字符串拼接，所以参数里带空格、引号、`&&`、`>` 都只是普通字符，
 * 不构成命令注入。但「放行 shell:exec」这件事本身就等于把「执行任意程序」交给页面：能力清单是唯一的闸门，
 * 页面拿到什么命令就等于能跑什么程序。只想让用户打开链接 / 文件的应用请引用 `shell:allow-open`。
 *
 * 限制：`shell:exec` 是同步调用（子进程不退出就不返回），且**没有**流式输出 / 超时 / 取消——但它跑在命令
 * worker 线程上（命令分发已异步化，见 AGENTS.md §2 的线程模型），所以不会冻住窗口。长驻 / 交互式程序
 * （编辑器、REPL、npm run dev）仍不要走这里。
 */
public class ShellPlugin <: Plugin {
    public init() {}

    public func name(): String {
        return "shell"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        let handler = ShellCommands()
        m.add("open", handler)
        m.add("exec", handler)
        return m
    }

    /**
     * 命名权限集（v1.1）：allow-open 只含「交给系统默认程序打开」这条，exec（执行任意程序）不在其中。
     * 只想打开链接 / 文件的应用引用 allow-open 即可，不必顺带拿到执行能力；集内写短名，框架自动补 `shell:`。
     */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let openOnly = ArrayList<String>()
        openOnly.add("open")
        m.add("allow-open", openOnly)
        let all = ArrayList<String>()
        all.add("open")
        all.add("exec")
        m.add("default", all)
        return m
    }

    /**
     * 前端 shim：往桥对象上挂一个 shell 命名空间（与 fs / dialog 同款，不碰 invoke / listen / emit）
     */
    public func jsShim(): String {
        return "(function () { var t = window.__CJ_TAURI__ || (window.__CJ_TAURI__ = {});" +
            " t.shell = {" +
            " open: function (args) { return window.__CJ_TAURI__.invoke('shell:open', args); }," +
            " exec: function (args) { return window.__CJ_TAURI__.invoke('shell:exec', args); }" +
            " }; })();\n"
    }
}

/**
 * 单条命令最多回传多少字节（每个流各算）：超出部分截断并标注。
 * executeWithOutput 已经把输出全量收进内存，这里挡的是「再把它整个塞进一条 IPC 消息」——
 * 一条命令把几十 MB 灌进 WebView 没有意义，只会把窗口卡住。
 */
let SHELL_MAX_CAPTURE_BYTES: Int64 = 262144

/**
 * 把捕获到的字节解成字符串：非 UTF-8 时退化成摘要而不是抛异常（子进程往 stdout 写什么我们管不着），
 * 超出上限的截断并加一行标注，让前端知道「这不是全部」。
 */
func decodeCaptured(bytes: Array<Byte>): String {
    let limit = if (bytes.size > SHELL_MAX_CAPTURE_BYTES) {
        SHELL_MAX_CAPTURE_BYTES
    } else {
        Int64(bytes.size)
    }
    // 显式逐字节拷贝：Array 的区间切片在仓颉里语义较绕，这里只用到「下标读写」这一条确定的行为
    let limited = Array<Byte>(limit, repeat: 0)
    for (i in 0..limit) {
        limited[i] = bytes[Int64(i)]
    }
    var text = ""
    try {
        text = String.fromUtf8(limited)
    } catch (e: Exception) {
        text = "<输出不是合法 UTF-8，${bytes.size} 字节>"
    }
    if (bytes.size > SHELL_MAX_CAPTURE_BYTES) {
        text = text + "\n[已截断：本次输出 ${bytes.size} 字节，只回传前 ${SHELL_MAX_CAPTURE_BYTES} 字节]"
    }
    return text
}

/**
 * 跑子进程并返回 (退出码, stdout, stderr)。
 * 程序不存在 / 没有执行权限等情况统一转成 CommandException，前端拿到的是可读原文。
 */
func runCaptured(program: String, argv: Array<String>, cwd: String): (Int64, Array<Byte>, Array<Byte>) {
    try {
        if (cwd.size == 0) {
            return executeWithOutput(program, argv)
        }
        return executeWithOutput(program, argv, workingDirectory: Path(cwd))
    } catch (e: Exception) {
        throw CommandException("shell:exec failed: ${e}")
    }
}

/**
 * 把 target 交给系统默认程序打开。
 *
 * 平台差异按 AGENTS.md §2 的规矩只出现在 @When 条件编译里：
 *   - Linux 用 `xdg-open`（XDG 标准，桌面环境缺省都有）；
 *   - Windows 用 `rundll32` 的 `FileProtocolHandler`（等价于 ShellExecute：URL 与本地文件都能开，
 *     且**不必**经过 `cmd /c start`，省掉一层引号解析与注入面）。
 * 只启动、不等待：用户关不关那个程序与本应用无关，所以用 launch 而不是 execute（后者会阻塞 UI 线程）。
 */
@When[os == "Linux"]
func launchOpenTarget(target: String): Unit {
    let _ = launch("xdg-open", [target])
}

@When[os == "Windows"]
func launchOpenTarget(target: String): Unit {
    let _ = launch("rundll32.exe", ["url.dll,FileProtocolHandler", target])
}

/**
 * shell 插件的命令处理器（两个命令共用一份，按全名分派，与内置 SystemCommands 同形）
 */
class ShellCommands <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "shell:open" => JsonBool(this.open(args))
            case "shell:exec" => this.exec(args)
            case _ => throw CommandException("unknown shell command: ${cmd}")
        }
    }

    /** 取必需的字符串参数；缺失或类型不对时抛业务错误，前端拿到的是可读原文 */
    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => throw CommandException("shell: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("shell: missing argument \"${key}\"")
        }
    }

    /** 取可选字符串参数：缺失或类型不对都退回默认值（cwd 不是必需的） */
    private func optionalString(args: JsonObject, key: String, fallback: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => fallback
            }
            case None => fallback
        }
    }

    /** 取可选字符串数组参数（args）：缺省为空数组，元素不是字符串时报错而不是悄悄丢掉 */
    private func optionalStringArray(args: JsonObject, key: String): Array<String> {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsArray =>
                    let arr = v.asArray()
                    if (arr.size() == 0) {
                        return []
                    }
                    let out = Array<String>(Int64(arr.size()), repeat: "")
                    for (i in 0..arr.size()) {
                        let item = arr.get(i).getOrThrow()
                        match (item.kind()) {
                            case JsonKind.JsString => out[Int64(i)] = item.asString().getValue()
                            case _ => throw CommandException(
                                "shell: argument \"${key}\" must contain only strings")
                        }
                    }
                    return out
                case _ => throw CommandException("shell: argument \"${key}\" must be an array")
            }
            case None => return []
        }
    }

    /** shell:open：把 target（URL 或本地路径）交给系统默认程序 */
    private func open(args: JsonObject): Bool {
        let target = this.requireString(args, "target")
        if (target.size == 0) {
            throw CommandException("shell:open: argument \"target\" must not be empty")
        }
        try {
            launchOpenTarget(target)
            return true
        } catch (e: Exception) {
            throw CommandException("shell:open failed: ${e}")
        }
    }

    /** shell:exec：跑一个程序并回收 (退出码, stdout, stderr)；argv 直传，不经过 shell */
    private func exec(args: JsonObject): JsonValue {
        let program = this.requireString(args, "program")
        if (program.size == 0) {
            throw CommandException("shell:exec: argument \"program\" must not be empty")
        }
        let argv = this.optionalStringArray(args, "args")
        let cwd = this.optionalString(args, "cwd", "")
        let r = runCaptured(program, argv, cwd)
        var obj = JsonObject()
        obj.put("code", JsonInt(r[0]))
        obj.put("stdout", JsonString(decodeCaptured(r[1])))
        obj.put("stderr", JsonString(decodeCaptured(r[2])))
        return obj
    }
}
