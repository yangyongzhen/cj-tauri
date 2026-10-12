package cjTauri

import std.collection.*
import std.fs.*
import std.sync.*
import stdx.encoding.json.*

/**
 * 官方插件 store：持久化键值存储（纯仓颉，零 C 桥；RFC-003 第 2 期，对标 tauri-plugin-store）
 *
 * 命令：store:get / store:set / store:delete / store:keys / store:clear
 * 权限：**不自动放行**，应用要在 capabilities 里显式声明，两种写法等价：
 *   "commands": ["store:get", "store:keys"]     // 明文逐条
 *   "permissions": ["store:readonly"]           // 命名权限集（get + keys，一次放行读那组）
 * 前端：window.__CJ_TAURI__.store.set({ key: "theme", value: "dark" })
 *
 * 值是**任意 JSON**（对象/数组/标量都行）——落盘形状就是 `{ key: value, ... }` 一个 JSON 对象。
 * 落盘位置：`StorePlugin()` 默认 `<工作目录>/store.json`（与 capabilities/ 同一套项目根约定），
 * `StorePlugin(path)` 自定义。v1 一应用一个 store（插件按 name 装配，多实例会撞名）。
 *
 * 原子写：先写 `path.tmp` 再 `rename(overwrite: true)`，进程中途被杀也不会留下半个 JSON；
 * rename 失败回落直写并打 stderr（与 examples/music 的手搓存储同级兜底）。
 * 损坏文件不是致命错误：读失败一行 stderr + 从空开始，下次 save 覆盖掉坏文件。
 */
public class StorePlugin <: Plugin {
    private let store: StoreBackend

    public init() {
        this.store = StoreBackend("store.json")
    }

    public init(path: String) {
        this.store = StoreBackend(path)
    }

    public func name(): String {
        return "store"
    }

    public func commands(): HashMap<String, CommandHandler> {
        let m = HashMap<String, CommandHandler>()
        m.add("get", StoreCommands(this.store))
        m.add("set", StoreCommands(this.store))
        m.add("delete", StoreCommands(this.store))
        m.add("keys", StoreCommands(this.store))
        m.add("clear", StoreCommands(this.store))
        return m
    }

    /**
     * 命名权限集：readonly 只含「读」两条（get + keys）——只想读的应用引用它即可，
     * **写能力不会被顺带打开**；要写必须显式引用 default 或把写命令写成明文。
     */
    public func permissions(): HashMap<String, ArrayList<String>> {
        let m = HashMap<String, ArrayList<String>>()
        let ro = ArrayList<String>()
        ro.add("get")
        ro.add("keys")
        m.add("readonly", ro)
        let all = ArrayList<String>()
        all.add("get")
        all.add("set")
        all.add("delete")
        all.add("keys")
        all.add("clear")
        m.add("default", all)
        return m
    }

    /**
     * 前端 shim：只往 __CJ_TAURI__ 挂一个 store 命名空间，不动 invoke / listen / emit
     */
    public func jsShim(): String {
        return "(function () { var t = window.__CJ_TAURI__ || (window.__CJ_TAURI__ = {});" +
            " t.store = {" +
            " get: function (a) { return window.__CJ_TAURI__.invoke('store:get', a); }," +
            " set: function (a) { return window.__CJ_TAURI__.invoke('store:set', a); }," +
            " del: function (a) { return window.__CJ_TAURI__.invoke('store:delete', a); }," +
            " keys: function () { return window.__CJ_TAURI__.invoke('store:keys', {}); }," +
            " clear: function () { return window.__CJ_TAURI__.invoke('store:clear', {}); }" +
            " }; })();\n"
    }
}

/**
 * 存储本体：内存 JsonObject + 锁 + 原子落盘。
 *
 * 独立成类而不是塞进命令处理器里：五条命令共享同一份内存与文件（命令处理器是按命令各 new 的），
 * 单测也要能直接驱动它（并发写 / 损坏文件回落都不必过 IPC）。
 */
public class StoreBackend {
    private var path: String
    private var root: JsonObject
    // 命令跑在 worker 线程上：内存对象与「读-改-写盘」必须整块互斥，否则并发 set 会互相覆盖
    private let lock: Mutex = Mutex()

    public init(path: String) {
        this.path = path
        this.root = JsonObject()
        this.load()
    }

    public func pathOf(): String {
        return this.path
    }

    /** 读盘：读不到（第一次跑）与读坏都不是致命错误——后者一行 stderr 再从空开始（music 先例） */
    private func load(): Unit {
        try {
            let text = String.fromUtf8(File.readFrom(this.path))
            let parsed = JsonValue.fromStr(text)
            match (parsed.kind()) {
                case JsonKind.JsObject => this.root = parsed.asObject()
                case _ => eprintln("[cj-tauri] store 文件不是 JSON 对象，本轮从空开始：${this.path}")
            }
        } catch (e: Exception) {
            // 第一次跑就是这条路径——没有 store 文件是正常状态，不是错误
        }
    }

    /**
     * 原子落盘：写 tmp → rename 覆盖。rename 失败回落直写（保住「能存上」这个主目标），
     * 两种失败都留 stderr——写盘失败必须可观测，不能让「本轮只在内存里」无声发生。
     */
    private func saveLocked(): Bool {
        let text = this.root.toJsonString()
        let tmp = this.path + ".tmp"
        try {
            File.writeTo(tmp, text.toArray())
            try {
                rename(tmp, to: this.path, overwrite: true)
            } catch (e: Exception) {
                // rename 失败（跨目录/被占用等）：回落直写目标文件，别让数据丢在 tmp 里
                File.writeTo(this.path, text.toArray())
                eprintln("[cj-tauri] store 原子替换失败已回落直写：${e}")
            }
            return true
        } catch (e: Exception) {
            eprintln("[cj-tauri] store 写盘失败：${e}（路径 ${this.path}，本轮改动只在内存里）")
            return false
        }
    }

    /**
     * 读一个键。缺失时：给了 default 回 default，没给回 JSON null
     * （用 fromStr("null") 构造——JsonNull 的构造契约未在仓内核实过，不猜）。
     */
    public func get(key: String, hasDefault: Bool, defaultValue: JsonValue): JsonValue {
        synchronized(this.lock) {
            match (this.root.get(key)) {
                case Some(v) => return v
                case None =>
                    if (hasDefault) {
                        return defaultValue
                    }
                    return JsonValue.fromStr("null")
            }
        }
    }

    /** 写一个键并落盘；返回落盘是否成功（false = 本轮只在内存里，页面据此提示） */
    public func set(key: String, value: JsonValue): Bool {
        synchronized(this.lock) {
            this.root.put(key, value)
            return this.saveLocked()
        }
    }

    /** 删一个键并落盘；返回 (是否存在过, 落盘是否成功)——页面据此区分「删了」与「本来就没有」 */
    public func delete(key: String): (Bool, Bool) {
        synchronized(this.lock) {
            // getFields + HashMap.remove + 重建：不管 getFields 给的是拷贝还是内部表，结果都正确
            let fields = this.root.getFields()
            let removed = fields.remove(key)
            this.root = JsonObject(fields)
            if (removed.isNone()) {
                return (false, true)
            }
            return (true, this.saveLocked())
        }
    }

    /** 全部键，按字典序（输出稳定、可断言） */
    public func keys(): ArrayList<String> {
        synchronized(this.lock) {
            let names = ArrayList<String>()
            for ((k, _) in this.root.getFields()) {
                names.add(k)
            }
            return sortedStrings(names)
        }
    }

    /** 清空并落盘；返回清掉的键数与落盘是否成功 */
    public func clear(): (Int64, Bool) {
        synchronized(this.lock) {
            let n = this.root.size()
            this.root = JsonObject()
            if (n == 0) {
                return (0, true)
            }
            return (n, this.saveLocked())
        }
    }
}

/** store 的五条命令：分发 + 参数校验，逻辑都在 StoreBackend 里 */
public class StoreCommands <: CommandHandler {
    private let store: StoreBackend

    public init(store: StoreBackend) {
        this.store = store
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = ipc // store 的命令都是纯本地读写，不回头投事件，用不上上下文
        match (cmd) {
            case "store:get" => this.getCmd(args)
            case "store:set" => this.setCmd(args)
            case "store:delete" => this.deleteCmd(args)
            case "store:keys" => this.keysCmd()
            case "store:clear" => this.clearCmd()
            case _ => throw CommandException("unknown store command: ${cmd}")
        }
    }

    private func requireKey(args: JsonObject): String {
        match (args.get("key")) {
            case Some(v) =>
                match (v.kind()) {
                    case JsonKind.JsString =>
                        let k = v.asString().getValue()
                        if (k.isEmpty()) {
                            throw CommandException("store: key 不能为空字符串")
                        }
                        return k
                    case _ => throw CommandException("store: 参数 \"key\" 必须是字符串")
                }
            case None => throw CommandException("store: 缺少参数 \"key\"")
        }
    }

    private func getCmd(args: JsonObject): JsonValue {
        let key = this.requireKey(args)
        match (args.get("default")) {
            case Some(d) => return this.store.get(key, true, d)
            case None => return this.store.get(key, false, JsonBool(false))
        }
    }

    private func setCmd(args: JsonObject): JsonValue {
        let key = this.requireKey(args)
        // 值是任意 JSON；没传 value 视为编程错误直接拒（想存 null 就显式传 value: null）
        match (args.get("value")) {
            case Some(v) => return JsonBool(this.store.set(key, v))
            case None => throw CommandException("store: 缺少参数 \"value\"（想存 null 就显式传 value: null）")
        }
    }

    private func deleteCmd(args: JsonObject): JsonValue {
        let key = this.requireKey(args)
        let (existed, saved) = this.store.delete(key)
        let out = JsonObject()
        out.put("existed", JsonBool(existed))
        out.put("saved", JsonBool(saved))
        return out
    }

    private func keysCmd(): JsonValue {
        let names = this.store.keys()
        let arr = ArrayList<JsonValue>()
        for (k in names) {
            arr.add(JsonString(k))
        }
        return JsonArray(arr)
    }

    private func clearCmd(): JsonValue {
        let (cleared, saved) = this.store.clear()
        let out = JsonObject()
        out.put("cleared", JsonInt(cleared))
        out.put("saved", JsonBool(saved))
        return out
    }
}
