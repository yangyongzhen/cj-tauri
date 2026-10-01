package todo_check

import cjTauri.*
import std.collection.*
import std.fs.File
import stdx.encoding.json.*

/**
 * 待办数据：三个命令共用同一份内存状态。
 * 说明：示例里所有改动都发生在处理 IPC 请求的线程上，所以没加锁；
 * 一旦你从别的线程（比如定时器）也来改它，就要自己加锁或用通道。
 */
public class TodoStore {
    private var items: ArrayList<String> = ArrayList<String>()

    /** 追加一条，返回当前条数 */
    public func add(text: String): Int64 {
        this.items.add(text)
        return this.items.size
    }

    /** 按下标删除；越界返回 false，不抛异常 */
    public func remove(index: Int64): Bool {
        if (index < 0 || index >= this.items.size) {
            return false
        }
        var next = ArrayList<String>()
        var i: Int64 = 0
        for (t in this.items) {
            if (i != index) {
                next.add(t)
            }
            i += 1
        }
        this.items = next
        return true
    }

    /** 转成 JSON 数组，直接交给前端 */
    public func toJson(): JsonValue {
        var list = ArrayList<JsonValue>()
        for (t in this.items) {
            list.add(JsonString(t))
        }
        return JsonArray(list)
    }

    public func count(): Int64 {
        return this.items.size
    }
}

/** 广播当前列表：前端 listen("todo:changed") 收到后重绘 */
func broadcast(store: TodoStore, ipc: IpcContext): Unit {
    var payload = JsonObject()
    payload.put("items", store.toJson())
    payload.put("count", JsonInt(store.count()))
    ipc.emit("todo:changed", payload)
}

/** todo:add { text } -> 新条数 */
public class TodoAddCommand <: CommandHandler {
    private let store: TodoStore

    public init(store: TodoStore) {
        this.store = store
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var text = ""
        if (let Some(v) <- args.get("text")) {
            match (v.kind()) {
                case JsonKind.JsString => text = v.asString().getValue()
                case _ => ()
            }
        }
        if (text.size == 0) {
            // 抛 CommandException：前端 .catch 里收到的 err.message 就是这句话
            throw CommandException("text 不能为空")
        }
        let n = this.store.add(text)
        broadcast(this.store, ipc)
        return JsonInt(n)
    }
}

/** todo:remove { index } -> true/false */
public class TodoRemoveCommand <: CommandHandler {
    private let store: TodoStore

    public init(store: TodoStore) {
        this.store = store
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var index: Int64 = -1
        if (let Some(v) <- args.get("index")) {
            match (v.kind()) {
                case JsonKind.JsInt => index = v.asInt().getValue()
                case _ => ()
            }
        }
        let ok = this.store.remove(index)
        broadcast(this.store, ipc)
        return JsonBool(ok)
    }
}

/** todo:list -> { items: [...], count: N } */
public class TodoListCommand <: CommandHandler {
    private let store: TodoStore

    public init(store: TodoStore) {
        this.store = store
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var obj = JsonObject()
        obj.put("items", this.store.toJson())
        obj.put("count", JsonInt(this.store.count()))
        return obj
    }
}

main(): Int64 {
    let store = TodoStore()
    let app = TauriApp()
        .window(WindowConfig("待办清单 · cj-tauri", 900, 640))
        .register("todo:add", TodoAddCommand(store))
        .register("todo:remove", TodoRemoveCommand(store))
        .register("todo:list", TodoListCommand(store))

    let html = String.fromUtf8(File.readFrom("ui/index.html"))
    app.run(html)
    return 0
}
