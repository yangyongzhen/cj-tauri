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
 *   "events": ["tick"],
 *   "permissions": ["fs:readonly"]
 * }
 *
 * 默认最小权限：未声明的命令一律拒绝，未声明的事件不投递。
 *
 * permissions（v1.1）：命名权限集——插件声明「集名 → 成员」，应用按集名引用；
 * 集名形如 `<插件名>:<短集名>`（如 fs:readonly）。成员展开后与 commands/events 里的明文名字同权，
 * 所以旧清单（全写明文）行为完全不变。集名没被任何插件提供时只是不生效、不报错，
 * 启动时由 warnUnknownPermissionSets 提示（多半是拼错或忘了装配插件）。
 */
public class Capability {
    public let identifier: String
    public let windows: ArrayList<String>
    public let commands: HashSet<String>
    public let events: HashSet<String>
    /** 引用到的命名权限集（原始名，如 "fs:readonly"）；展开规则见 CapabilityRegistry */
    public let permissions: HashSet<String>
    /**
     * 路径 scope（RFC-003 第 4 期）：插件名 → 路径白名单规则。
     * 没有某插件的条目 = 该插件按旧行为全量放行（启动时有 stderr 提示）；
     * 有条目就走「先 deny 后 allow」的二次校验，见 src/scope.cj。
     */
    public let scopes: HashMap<String, ScopeRule>

    public init(identifier: String) {
        this.identifier = identifier
        this.windows = ArrayList<String>()
        this.commands = HashSet<String>()
        this.events = HashSet<String>()
        this.permissions = HashSet<String>()
        this.scopes = HashMap<String, ScopeRule>()
    }

    public func allowCommand(cmd: String): Unit {
        this.commands.add(cmd)
    }

    /** 引用一个命名权限集（集由插件在装配时注册，见 plugin.cj 的 permissions()） */
    public func allowPermissionSet(name: String): Unit {
        this.permissions.add(name)
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
            // permissions：命名权限集（v1.1）——集名由插件提供，成员展开后与 commands/events 同权
            if (let Some(perms) <- obj.get("permissions")) {
                match (perms.kind()) {
                    case JsonKind.JsArray =>
                        let arr = perms.asArray()
                        for (i in 0..arr.size()) {
                            if (let Some(x) <- arr.get(i)) {
                                match (x.kind()) {
                                    case JsonKind.JsString => cap.allowPermissionSet(x.asString().getValue())
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
            // scopes：插件名 → 路径白名单（RFC-003 第 4 期）。键不认识也照收——
            // 判定只在「插件真的来问」时发生，写错的键不会放行任何东西，只会让本该严的规则不生效
            if (let Some(scopes) <- obj.get("scopes")) {
                match (scopes.kind()) {
                    case JsonKind.JsObject =>
                        // JsonObject 没有 keys()，取 fields 这张表来遍历（plugin_store.cj 同样写法）
                        for ((k, v) in scopes.asObject().getFields()) {
                            if (let Some(rule) <- parseScopeRule(v)) {
                                cap.scopes.add(k, rule)
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
    // 命名权限集：集名（"fs:readonly"）→ 成员全名。由插件装配时注册（plugin.cj 的 registerPluginPermissionSets）
    private var permissionSets: HashMap<String, HashSet<String>> = HashMap<String, HashSet<String>>()

    public init() {}

    /**
     * 注册一个命名权限集（同集名可多次注册，成员取并集）
     */
    public func addPermissionSet(name: String, members: ArrayList<String>): Unit {
        if (!this.permissionSets.contains(name)) {
            this.permissionSets.add(name, HashSet<String>())
        }
        let set = this.permissionSets.get(name).getOrThrow()
        for (m in members) {
            set.add(m)
        }
    }

    public func hasPermissionSet(name: String): Bool {
        return this.permissionSets.contains(name)
    }

    /**
     * 清单里引用过、但可能没被任何插件提供的集名（去重）。
     * 供启动提示用：未知集名只是不生效，不是错误——但多半是拼错了。
     */
    public func declaredPermissionSets(): ArrayList<String> {
        let seen = HashSet<String>()
        let names = ArrayList<String>()
        for (c in this.caps) {
            for (n in c.permissions) {
                if (!seen.contains(n)) {
                    seen.add(n)
                    names.add(n)
                }
            }
        }
        return names
    }

    /**
     * name 是否被「某条清单引用的某个集」覆盖。
     * 单层展开：集成员若又写成别的集名，不会被继续展开（避免环）。
     */
    private func coveredByPermissionSet(name: String): Bool {
        for (c in this.caps) {
            for (setName in c.permissions) {
                match (this.permissionSets.get(setName)) {
                    case Some(members) =>
                        if (members.contains(name)) {
                            return true
                        }
                    case None => ()
                }
            }
        }
        return false
    }

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
        // 命名权限集算放行：集内成员与写明文同权（v1.1）
        return this.coveredByPermissionSet(cmd)
    }

    public func canEmit(event: String): Bool {
        for (c in this.caps) {
            if (c.canEmit(event)) {
                return true
            }
        }
        return this.coveredByPermissionSet(event)
    }

    /**
     * 某个插件的路径 scope（RFC-003 第 4 期）：把所有清单里给它的规则**并集**起来。
     * 返回 None = 没有任何清单为它写 scope → 调用方按旧行为全量放行。
     *
     * 为什么是并集而不是「逐清单分别判定」：与 canInvoke / canEmit 的口径一致——
     * 现有能力模型就是「任一清单放行即放行」，scope 跟着同一条口径走才解释得清。
     * （列级 + 窗口级 scopes 是 Tauri v2 更细的模型，本轮不做，见 RFC-003 第 4 期。）
     */
    public func scopeForPlugin(plugin: String): Option<ScopeRule> {
        var found = false
        let merged = ScopeRule()
        for (c in this.caps) {
            match (c.scopes.get(plugin)) {
                case Some(rule) =>
                    found = true
                    for (a in rule.allow) {
                        merged.allow.add(a)
                    }
                    for (d in rule.deny) {
                        merged.deny.add(d)
                    }
                case None => ()
            }
        }
        if (!found) {
            return None
        }
        return Some(merged)
    }

    /** 是否有任何清单为某插件声明过 scope（启动提示与判定分支共用这一个口径） */
    public func hasScopeForPlugin(plugin: String): Bool {
        for (c in this.caps) {
            if (c.scopes.contains(plugin)) {
                return true
            }
        }
        return false
    }

    public func size(): Int64 {
        return this.caps.size
    }
}

/**
 * 提示清单里引用了、但没有任何插件提供的命名权限集。
 * 只提示不改行为：未知集名不生效（默认最小权限照旧），其它命令与事件不受影响。
 * 调用时机：插件装配完成之后（那时能提供的集才都注册完）。
 */
public func warnUnknownPermissionSets(reg: CapabilityRegistry): Unit {
    for (name in reg.declaredPermissionSets()) {
        if (!reg.hasPermissionSet(name)) {
            eprintln("[cj-tauri] 未知的命名权限集 \"${name}\"：没有插件提供它，这一条不生效")
            eprintln("[cj-tauri]   检查拼写；若它来自插件，确认提供它的插件已 .plugin(...) 装配")
        }
    }
}
