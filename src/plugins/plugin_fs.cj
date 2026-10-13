package cjTauri.plugins

import cjTauri.*

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/**
 * 官方插件 fs：文件读写（纯仓颉，零 C 桥改动，RFC-001 §7.3）
 *
 * 命令：fs:readText / fs:writeText / fs:exists
 * 权限：**不自动放行**，应用要在 capabilities 里显式声明，两种写法等价：
 *   "commands": ["fs:readText", "fs:exists"]        // 明文逐条（旧写法，一直支持）
 *   "permissions": ["fs:readonly"]                  // 命名权限集（v1.1，一次放行一组）
 * 路径：`scopeAware()` 为真——页面给的 path 一律经 IpcContext.resolveScopedPath 校验；
 *   清单里写了 "scopes": { "fs": { "allow": [...], "deny": [...] } } 就按白名单判定（越界即拒），
 *   没写就维持旧行为（全量放行，启动时打一行 stderr 提示）。见 docs/RFC-插件路线图.md 第 4 期。
 * 前端：window.__CJ_TAURI__.fs.readText({ path: "notes.txt" })
 */
public class FsPlugin <: Plugin {
    public init() {}

    public func name(): String {
        return "fs"
    }

    /** 本插件的路径参数吃 scope 校验（RFC-003 第 4 期）：唯一带任意路径的官方插件 */
    public func scopeAware(): Bool {
        return true
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        m.add("readText", FsCommands())
        m.add("writeText", FsCommands())
        m.add("exists", FsCommands())
        return m
    }

    /**
     * 命名权限集（v1.1，对标 Tauri v2 的 fs:default / fs:allow-read-text-file）。
     *
     * readonly 只含读相关两条：只想读文件的应用引用它即可，**写能力不会被顺带打开**；
     * 要写文件必须显式引用 default（或把 fs:writeText 写成明文）——最小权限不打折。
     * 集内写短名（readText），框架自动补成 fs:readText。
     */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let ro = ArrayList<String>()
        ro.add("readText")
        ro.add("exists")
        m.add("readonly", ro)
        let all = ArrayList<String>()
        all.add("readText")
        all.add("writeText")
        all.add("exists")
        m.add("default", all)
        return m
    }

    /**
     * 前端 shim：往桥对象上挂一个 fs 命名空间。
     * 只动 __CJ_TAURI__ 的一个命名空间，不碰 invoke / listen / emit，也不注册全局变量。
     */
    public func jsShim(): String {
        return "(function () { var t = window.__CJ_TAURI__ || (window.__CJ_TAURI__ = {});" +
            " t.fs = {" +
            " readText: function (args) { return window.__CJ_TAURI__.invoke('fs:readText', args); }," +
            " writeText: function (args) { return window.__CJ_TAURI__.invoke('fs:writeText', args); }," +
            " exists: function (args) { return window.__CJ_TAURI__.invoke('fs:exists', args); }" +
            " }; })();\n"
    }
}

/**
 * fs 插件的命令处理器（三个命令共用一份，按全名分派，与内置 SystemCommands 同形）
 */
class FsCommands <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        match (cmd) {
            case "fs:readText" => this.readText(args, ipc)
            case "fs:writeText" => this.writeText(args, ipc)
            case "fs:exists" => this.exists(args, ipc)
            case _ => throw CommandException("unknown fs command: ${cmd}")
        }
    }

    /**
     * 取路径参数并过 scope 校验：越界在**这里**就抛（前端拿到可读错误），
     * 命令体拿到的一定是已经规范化、且落在白名单里的路径。
     */
    private func scopedPath(args: JsonObject, ipc: IpcContext): String {
        return ipc.resolveScopedPath("fs", this.requireString(args, "path"))
    }

    /** 取必需的字符串参数；缺失或类型不对时抛业务错误，前端拿到的是可读原文 */
    private func requireString(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => throw CommandException("fs: argument \"${key}\" must be a string")
            }
            case None => throw CommandException("fs: missing argument \"${key}\"")
        }
    }

    private func readText(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        try {
            return JsonString(String.fromUtf8(File.readFrom(path)))
        } catch (e: Exception) {
            throw CommandException("fs:readText failed: ${e}")
        }
    }

    private func writeText(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        let contents = this.requireString(args, "contents")
        try {
            // File.writeTo 是覆盖写：文件已存在会截断，不存在则创建——不需要先删（与 File.create 不同）
            File.writeTo(path, contents.toArray())
            return JsonBool(true)
        } catch (e: Exception) {
            throw CommandException("fs:writeText failed: ${e}")
        }
    }

    private func exists(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        return JsonBool(exists(path))
    }
}
