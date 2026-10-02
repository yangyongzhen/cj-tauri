package cjTauri

import std.collection.*

/**
 * 一个窗口的记录：label 唯一，config 是它创建时的窗口配置快照
 *
 * label 是窗口对外的**唯一身份**（Tauri 同样按 label 寻址）：前端页面只认 label，
 * C 侧句柄是跨 FFI 的不透明指针，留在宿主实现内部、不越过 IPC 协议（见
 * docs/架构演进-多平台与多窗口.md §7.2）。
 */
public class WindowRecord {
    public let label: String
    public let host: WebViewHost
    public let config: WindowConfig

    public init(label: String, host: WebViewHost, config: WindowConfig) {
        this.label = label
        this.host = host
        this.config = config
    }
}

/**
 * label → 窗口记录（批次 2 的地基）
 *
 * 单窗口阶段只登记一条 "main"——与桥 JS 的 windowLabel 缺省值、旧代码里写死的 "main"
 * 是同一个约定（**默认值不能变**，否则现有示例与探针会静默收不到事件，见架构文档 §6.4）。
 * 多窗口落地后它是「label → 宿主」的唯一权威来源：事件定向投递（emitToWindow）与
 * 命令上下文（IpcContext.window）都从这里查。
 *
 * 为什么重复 label 直接抛而不是覆盖：覆盖会让「一个 label 后面挂着两个宿主」静默成立，
 * 而这类 bug 的表现是「事件忽而收得到、忽而收不到」，是最难查的一类。
 */
class WindowRegistry {
    private var windows: HashMap<String, WindowRecord> = HashMap<String, WindowRecord>()
    // 为什么另存一份插入顺序：HashMap 不承诺迭代顺序，而广播要按确定顺序投递——
    // 否则多窗口下事件的到达顺序随机，测试也没法断言（labels() 直接给这张表）。
    private var order: ArrayList<String> = ArrayList<String>()

    /**
     * 登记一个窗口：label 非空且未被占用
     */
    func add(record: WindowRecord): Unit {
        if (record.label.size == 0) {
            throw Exception("window label 不能为空")
        }
        if (this.windows.contains(record.label)) {
            throw Exception("duplicate window label: \"${record.label}\"")
        }
        this.windows.add(record.label, record)
        this.order.add(record.label)
    }

    /**
     * 按 label 取窗口；未登记返回 None（调用方决定是降级还是报错）
     */
    func get(label: String): Option<WindowRecord> {
        return this.windows.get(label)
    }

    /**
     * 全部 label，**按登记顺序**（广播路径据此保持确定顺序）
     */
    func labels(): ArrayList<String> {
        let out = ArrayList<String>()
        for (l in this.order) {
            out.add(l)
        }
        return out
    }

    /**
     * 解析投递目标：空串 = 广播（按登记顺序给出全部窗口），非空 = 命中则单元素、否则空表
     *
     * 路由决策放在这里而不是调用方：它是纯函数（不碰宿主）因而能单测，调用方只剩
     * 「投给谁」与「一个都没命中时怎么报」两件事。**未注册的 label 不回落成广播**——
     * 写错 label 就该什么都收不到（由调用方打一条 stderr），静默变成广播比丢事件更难查。
     */
    func targets(window: String): ArrayList<WindowRecord> {
        let out = ArrayList<WindowRecord>()
        if (window.size == 0) {
            for (l in this.order) {
                out.add(this.windows.get(l).getOrThrow())
            }
            return out
        }
        match (this.windows.get(window)) {
            case Some(rec) => out.add(rec)
            case None => ()
        }
        return out
    }

    /**
     * 注销窗口；label 不存在时为空操作（关窗路径可能重复触发，不该被异常打断）
     */
    func remove(label: String): Unit {
        if (!this.windows.contains(label)) {
            return
        }
        let _ = this.windows.remove(label)
        // 顺序表同步：重建一遍（窗口数以个位计，不值得为它引一个索引表）
        let kept = ArrayList<String>()
        for (l in this.order) {
            if (l != label) {
                kept.add(l)
            }
        }
        this.order = kept
    }

    func size(): Int64 {
        return this.windows.size
    }
}
