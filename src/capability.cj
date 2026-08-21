package cjTauri

import std.collection.*
import stdx.encoding.json.*

/**
 * 能力安全模型（对标 Tauri capability）
 *
 * capabilities/default.json 示例：
 * {
 *   "identifier": "default",
 *   "windows": ["main"],
 *   "commands": ["greet", "system:version", "system:ping"],
 *   "events": ["tick"]
 * }
 *
 * 默认最小权限：未声明的命令一律拒绝，未声明的事件不投递。
 */
public class Capability {
    public let identifier: String
    public let windows: ArrayList<String>
    public let commands: HashSet<String>
    public let events: HashSet<String>

    public init(identifier: String) {
        this.identifier = identifier
        this.windows = ArrayList<String>()
        this.commands = HashSet<String>()
        this.events = HashSet<String>()
    }

    public func allowCommand(cmd: String): Unit {
        this.commands.add(cmd)
    }

    public func allowEvent(event: String): Unit {
        this.events.add(event)
    }

    public func allowWindow(win: String): Unit {
        this.windows.add(win)
    }

    public func canInvoke(cmd: String): Bool {
        return this.commands.contains(cmd)
    }

    public func canEmit(event: String): Bool {
        return this.events.contains(event)
    }

    /**
     * 从 JSON 解析 capability 清单
     */
    public static func fromJson(json: JsonValue): Option<Capability> {
        try {
            match (json.kind()) {
                case JsonKind.JsObject => ()
                case _ => return None
            }
            let obj = json.asObject()
            let idV = obj.get("identifier")
            if (idV.isNone()) {
                return None
            }
            match (idV.getOrThrow().kind()) {
                case JsonKind.JsString => ()
                case _ => return None
            }
            let cap = Capability(idV.getOrThrow().asString().getValue())

            // commands
            if (let Some(cmds) <- obj.get("commands")) {
                match (cmds.kind()) {
                    case JsonKind.JsArray =>
                        let arr = cmds.asArray()
                        for (i in 0..arr.size()) {
                            if (let Some(c) <- arr.get(i)) {
                                match (c.kind()) {
                                    case JsonKind.JsString => cap.allowCommand(c.asString().getValue())
                                    case _ => ()
                                }
                            }
                        }
                    case _ => ()
                }
            }
            // events
            if (let Some(evts) <- obj.get("events")) {
                match (evts.kind()) {
                    case JsonKind.JsArray =>
                        let arr = evts.asArray()
                        for (i in 0..arr.size()) {
                            if (let Some(e) <- arr.get(i)) {
                                match (e.kind()) {
                                    case JsonKind.JsString => cap.allowEvent(e.asString().getValue())
                                    case _ => ()
                                }
                            }
                        }
                    case _ => ()
                }
            }
            // windows
            if (let Some(wins) <- obj.get("windows")) {
                match (wins.kind()) {
                    case JsonKind.JsArray =>
                        let arr = wins.asArray()
                        for (i in 0..arr.size()) {
                            if (let Some(w) <- arr.get(i)) {
                                match (w.kind()) {
                                    case JsonKind.JsString => cap.allowWindow(w.asString().getValue())
                                    case _ => ()
                                }
                            }
                        }
                    case _ => ()
                }
            }
            return Some(cap)
        } catch (e: Exception) {
            return None
        }
    }
}

/**
 * 能力注册中心：聚合多个 capability 清单，提供统一校验
 */
public class CapabilityRegistry {
    private var caps: ArrayList<Capability> = ArrayList<Capability>()

    public init() {}

    public func add(cap: Capability): Unit {
        this.caps.add(cap)
    }

    public func addFromJson(json: JsonValue): Bool {
        if (let Some(cap) <- Capability.fromJson(json)) {
            this.add(cap)
            return true
        }
        return false
    }

    public func canInvoke(cmd: String): Bool {
        for (c in this.caps) {
            if (c.canInvoke(cmd)) {
                return true
            }
        }
        return false
    }

    public func canEmit(event: String): Bool {
        for (c in this.caps) {
            if (c.canEmit(event)) {
                return true
            }
        }
        return false
    }

    public func size(): Int64 {
        return this.caps.size
    }
}
