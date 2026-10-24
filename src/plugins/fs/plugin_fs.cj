package cjTauri.plugins.fs

import cjTauri.*

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/**
 * 官方插件 fs：文件读写（纯仓颉，零 C 桥改动，RFC-001 §7.3）
 *
 * 命令：fs:readText / fs:writeText / fs:exists / fs:list / fs:remove
 *   / fs:mkdir / fs:rename / fs:copy / fs:stat
 *   - readText / writeText：整文件读写（writeText 是覆盖写：已存在会截断，不存在则创建）
 *   - exists：路径是否存在
 *   - list：**平铺一层**列目录，返回 [{ name, dir, size }]；不递归，顺序就是文件系统给的顺序（展示排序交给前端）
 *   - remove：只删**单个文件**，目标是目录一律拒——std.fs 的 remove 能把**空目录**也删掉，
 *     所以这层挡在调用前（不做递归删除）；文件不存在同样报错：调用方本想删的东西没删掉，
 *     静默回 true 等于把失败伪装成成功
 *   - mkdir：建目录，入参 { path, recursive? }；目标已存在报错（与 std.fs 语义一致，
 *     不静默回落成「已存在即成功」——调用方分不清建成了还是本来就有）
 *   - rename / copy：入参 { path, newPath, overwrite? }，**两个路径都过 scope 校验**
 *     （ newPath 同样是页面可控路径，漏校验等于 scope 形同虚设）；overwrite 缺省 false，
 *     覆盖既有文件必须页面显式声明
 *   - stat：单路径元信息 { name, dir, size, lastModified }（lastModified 是平台本地时区的
 *     可读字符串，比较排序交给前端）
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
        m.add("mkdir", FsCommands())
        m.add("rename", FsCommands())
        m.add("copy", FsCommands())
        m.add("stat", FsCommands())
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
        ro.add("stat")      // 元信息同样是读操作：不暴露任何写能力
        m.add("readonly", ro)
        let all = ArrayList<String>()
        all.add("readText")
        all.add("writeText")
        all.add("exists")
        all.add("list")
        all.add("remove")
        all.add("mkdir")
        all.add("rename")
        all.add("copy")
        all.add("stat")
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
            " remove: function (args) { return window.__CJ_TAURI__.invoke('fs:remove', args); }," +
            " mkdir: function (args) { return window.__CJ_TAURI__.invoke('fs:mkdir', args); }," +
            " rename: function (args) { return window.__CJ_TAURI__.invoke('fs:rename', args); }," +
            " copy: function (args) { return window.__CJ_TAURI__.invoke('fs:copy', args); }," +
            " stat: function (args) { return window.__CJ_TAURI__.invoke('fs:stat', args); }" +
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
            case "fs:mkdir" => this.mkdir(args, ipc)
            case "fs:rename" => this.doRename(args, ipc)
            case "fs:copy" => this.doCopy(args, ipc)
            case "fs:stat" => this.stat(args, ipc)
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

    /** 取可选布尔参数：缺省回 false；给了但不是布尔当场拒（写 true/false 以外的东西多半是调用方写错） */
    private func optionalBool(args: JsonObject, key: String): Bool {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsBool => return v.asBool().getValue()
                case JsonKind.JsNull => return false
                case _ => throw CommandException("fs: argument \"${key}\" must be a boolean")
            }
            case None => return false
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

    /**
     * 建目录。目标已存在是**错误**而不是成功：recursive 也一样（std.fs 的语义），
     * 静默回 true 会让调用方分不清「刚建出来」和「本来就有」，前端要幂等就先 exists 再 mkdir。
     */
    private func mkdir(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        let recursive = this.optionalBool(args, "recursive")
        try {
            Directory.create(path, recursive: recursive)
            return JsonBool(true)
        } catch (e: Exception) {
            throw CommandException("fs:mkdir failed: ${e}")
        }
    }

    /** rename/copy 共用：目标路径参数同样过 scope 校验（newPath 也是页面可控路径） */
    private func scopedNewPath(args: JsonObject, ipc: IpcContext): String {
        return ipc.resolveScopedPath("fs", this.requireString(args, "newPath"))
    }

    /**
     * 重命名（可移动到同盘另一目录）。overwrite 缺省 false：撞上既有路径即报错。
     * 方法名刻意叫 doRename：成员方法与 std.fs 的顶层 rename 同名时，
     * 方法体内的裸调用会解析回自身而不是库函数。
     */
    private func doRename(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        let newPath = this.scopedNewPath(args, ipc)
        let overwrite = this.optionalBool(args, "overwrite")
        try {
            rename(path, to: newPath, overwrite: overwrite)
            return JsonBool(true)
        } catch (e: Exception) {
            throw CommandException("fs:rename failed: ${e}")
        }
    }

    /** 复制文件或目录（std.fs 的 copy 目录语义是递归拷贝）。overwrite 缺省 false。命名理由同 doRename */
    private func doCopy(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        let newPath = this.scopedNewPath(args, ipc)
        let overwrite = this.optionalBool(args, "overwrite")
        try {
            copy(path, to: newPath, overwrite: overwrite)
            return JsonBool(true)
        } catch (e: Exception) {
            throw CommandException("fs:copy failed: ${e}")
        }
    }

    /** 单路径元信息。mtime 给可读字符串：前端只做展示，排序/比较用 size 或自己解析 */
    private func stat(args: JsonObject, ipc: IpcContext): JsonValue {
        let path = this.scopedPath(args, ipc)
        let info: FileInfo
        try {
            info = FileInfo(path)
        } catch (e: Exception) {
            throw CommandException("fs:stat failed: ${e}")
        }
        let obj = JsonObject()
        obj.put("name", JsonString(info.name))
        obj.put("dir", JsonBool(info.isDirectory()))
        obj.put("size", JsonInt(info.size))
        obj.put("lastModified", JsonString(info.lastModificationTime.toString()))
        return obj
    }
}
