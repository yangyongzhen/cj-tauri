package cjTauri.plugins.fs

import cjTauri.*

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/**
 * 官方插件 fs：文件读写（纯仓颉，零 C 桥改动，RFC-001 §7.3）
 *
 * 命令：fs:readText / fs:writeText / fs:exists / fs:list / fs:remove
 *   - readText / writeText：整文件读写（writeText 是覆盖写：已存在会截断，不存在则创建）
 *   - exists：路径是否存在
 *   - list：**平铺一层**列目录，返回 [{ name, dir, size }]；不递归，顺序就是文件系统给的顺序（展示排序交给前端）
 *   - remove：只删**单个文件**，目标是目录一律拒——std.fs 的 remove 能把**空目录**也删掉，
 *     所以这层挡在调用前（不做递归删除）；文件不存在同样报错：调用方本想删的东西没删掉，
 *     静默回 true 等于把失败伪装成成功
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
        m.add("list", FsCommands())
        m.add("remove", FsCommands())
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
        ro.add("list")      // 列目录也是读操作：只读应用（如文件浏览）要能拿它，但拿不到 remove
        m.add("readonly", ro)
        let all = ArrayList<String>()
        all.add("readText")
        all.add("writeText")
        all.add("exists")
        all.add("list")
        all.add("remove")
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
            " exists: function (args) { return window.__CJ_TAURI__.invoke('fs:exists', args); }," +
            " list: function (args) { return window.__CJ_TAURI__.invoke('fs:list', args); }," +
            " remove: function (args) { return window.__CJ_TAURI__.invoke('fs:remove', args); }" +
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
            case "fs:list" => this.listEntries(args, ipc)
            case "fs:remove" => this.removeFile(args, ipc)
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

    /**
     * 列目录：**平铺一层**、不递归——递归遍历是应用层的事，插件契约越薄越不容易被绕过。
     * name 直接取 FileInfo.name（等价于 path.fileName），目录项也照报（dir=true），显不显示由页面定。
     * 顺序不做保证：仓颉侧不排序（`ArrayList.sort` 已废弃），要稳定顺序在前端排。
     */
    private func listEntries(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        var entries: Array<FileInfo>
        try {
            entries = Directory.readFrom(path)
        } catch (e: Exception) {
            throw CommandException("fs:list failed: ${e}")
        }
        let items = ArrayList<JsonValue>()
        for (info in entries) {
            let obj = JsonObject()
            obj.put("name", JsonString(info.name))
            obj.put("dir", JsonBool(info.isDirectory()))
            obj.put("size", JsonInt(info.size))
            items.add(obj)
        }
        return JsonArray(items)
    }

    /**
     * 删单个文件。判定顺序不能反：**先确认存在、再挡住目录、最后才 remove**。
     * 漏掉中间那步，一个空目录会被 std.fs 的 remove 静默删掉（它同时管文件和目录）。
     */
    private func removeFile(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        if (!exists(path)) {
            throw CommandException("fs:remove failed: no such file: ${path}")
        }
        if (FileInfo(path).isDirectory()) {
            throw CommandException("fs:remove refused: is a directory: ${path}")
        }
        try {
            remove(path)
            return JsonBool(true)
        } catch (e: Exception) {
            throw CommandException("fs:remove failed: ${e}")
        }
    }
}
