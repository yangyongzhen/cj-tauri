package cjTauri

import std.collection.*
import stdx.encoding.json.*

/**
 * 插件（对标 Tauri v2 的 plugin，设计见 docs/RFC-插件体系.md）
 *
 * 一个插件 = 一组命令（全名 `<插件名>:<短名>`）+ 可选事件 + 可选前端 JS 片段。
 * 权限仍由应用的 capabilities 目录里的 json 决定：插件只声明「我提供什么」，**不自动放行**，
 * 默认最小权限不被破坏（RFC §5.3 的取舍 B）。
 *
 * 装配（必须在 run() / runUrl() 之前——页面加载前命令表要定稿）：
 *   TauriApp().plugin(FsPlugin())
 *
 * 命令全名与内置的 system:* 同形，所以 IpcHub 分发与 Capability 校验零改动。
 * 接口带默认实现，插件作者通常只写 name() 与 commands()。
 */
public interface Plugin {
    /** 插件名：作为命令/事件的命名空间（如 "fs"），不得为空、不得含 ':' */
    public func name(): String

    /** 命令短名 → 处理器；框架注册为 "<插件名>:<短名>" */
    public func commands(): HashMap<String, CommandHandler>

    /** 可能推送的事件短名；框架登记为 "<插件名>:<短名>"，用于缺权限提示。默认无事件 */
    public func events(): ArrayList<String> {
        return ArrayList<String>()
    }

    /** 前端 JS 片段：定义 window.__CJ_TAURI__.<插件名>；没有就返回空串 */
    public func jsShim(): String {
        return ""
    }

    /** 初始化：记录 app 引用、做一次性准备。默认空实现 */
    public func setup(app: TauriApp): Unit {}

    /**
     * 命名权限集（v1.1）：短集名 → 成员（写短名会自动补 "<插件名>:"，写全名则原样保留）。
     * 应用在 capabilities 的 permissions 里按 "<插件名>:<短集名>" 引用，一次放行一组。
     * 默认无。**集声明不等于放行**——清单不引用它，一条也不会生效。
     */
    public func permissions(): HashMap<String, ArrayList<String>> {
        return HashMap<String, ArrayList<String>>()
    }
}

/**
 * 插件名是否合法：非空且不含全/半角冒号。
 * 冒号是命名空间分隔符，混进来会让 "<插件名>:<短名>" 无法解析、权限也写不清。
 */
public func isValidPluginName(name: String): Bool {
    if (name.size == 0) {
        return false
    }
    return !name.contains(":") && !name.contains("：")
}

/** 某插件的命令全名列表（`<插件名>:<短名>`） */
public func pluginCommandNames(p: Plugin): ArrayList<String> {
    let names = ArrayList<String>()
    for ((short, _) in p.commands()) {
        names.add("${p.name()}:${short}")
    }
    return names
}

/** 某插件的事件全名列表（`<插件名>:<短名>`） */
public func pluginEventNames(p: Plugin): ArrayList<String> {
    let names = ArrayList<String>()
    for (short in p.events()) {
        names.add("${p.name()}:${short}")
    }
    return names
}

/** 把插件的命令按 "<插件名>:<短名>" 注册进 hub（TauriApp.prepare 与测试共用） */
public func registerPluginCommands(hub: IpcHub, p: Plugin): Unit {
    for ((short, handler) in p.commands()) {
        hub.register("${p.name()}:${short}", handler)
    }
}

/** 某插件的命名权限集：`<插件名>:<短集名>` → 展开后的成员全名列表 */
public func pluginPermissionSets(p: Plugin): HashMap<String, ArrayList<String>> {
    let out = HashMap<String, ArrayList<String>>()
    for ((shortSet, members) in p.permissions()) {
        let expanded = ArrayList<String>()
        for (m in members) {
            if (m.contains(":")) {
                expanded.add(m)
            } else {
                expanded.add("${p.name()}:${m}")
            }
        }
        out.add("${p.name()}:${shortSet}", expanded)
    }
    return out
}

/** 把插件的命名权限集注册进能力注册中心（TauriApp.prepare 与测试共用） */
public func registerPluginPermissionSets(reg: CapabilityRegistry, p: Plugin): Unit {
    for ((setName, members) in pluginPermissionSets(p)) {
        reg.addPermissionSet(setName, members)
    }
}

/** 人类可读的命名权限集清单（启动日志用）；一个集都没有时返回空串 */
public func describePermissionSets(plugins: ArrayList<Plugin>): String {
    var text = ""
    for (p in plugins) {
        for ((setName, members) in pluginPermissionSets(p)) {
            var list = ""
            for (m in members) {
                if (list.size > 0) {
                    list += ", "
                }
                list += m
            }
            text += "  ${setName}  ${list}\n"
        }
    }
    return text
}

/**
 * 收集各插件的 jsShim，作为「预执行脚本」逐条返回（一个插件一段，顺序 = 装配顺序）
 *
 * v2 方案（RFC §5.4）：不再把 shim 拼成 script 标签塞进 HTML——那段字符串操作对畸形 HTML 不健壮，
 * 而且 runUrl 的页面 HTML 根本不在本进程、拼不进去。改为交给宿主的 addInitScript，两平台都以
 * document-start 注入，HTML / URL 两种来源一视同仁。
 * 一个插件一段（而不是拼成一整段）：某个插件的 shim 写坏了不会带崩其它插件的命名空间。
 */
public func pluginInitScripts(plugins: ArrayList<Plugin>): ArrayList<String> {
    let out = ArrayList<String>()
    for (p in plugins) {
        let shim = p.jsShim()
        if (shim.size > 0) {
            out.add(shim)
        }
    }
    return out
}

/** 人类可读的插件清单（启动日志用，对齐 RFC §5.5 的打印形态） */
public func describePlugins(plugins: ArrayList<Plugin>): String {
    var text = ""
    for (p in plugins) {
        var cmds = ""
        for (n in pluginCommandNames(p)) {
            if (cmds.size > 0) {
                cmds += ", "
            }
            cmds += n
        }
        text += "  ${p.name()}  ${cmds}"
        let evts = pluginEventNames(p)
        if (evts.size > 0) {
            text += "  events: "
            var first = true
            for (n in evts) {
                if (!first) {
                    text += ", "
                }
                text += n
                first = false
            }
        }
        text += "\n"
    }
    return text
}

/**
 * 机器可读的插件清单（RFC §8 第 7 条的答案 C：给工具/CI 用，**不动 Plugin 接口**）
 *
 * 形态 `[{name, commands, events, permissions, hasShim}, ...]`：
 *   - `commands` / `events`：全名数组（`<插件名>:<短名>`，与 IPC 注册名、能力清单里写的名字一致）
 *   - `permissions`：集全名 → 成员全名数组（**框架展开后**的样子，也就是清单里能引用的名字）
 *   - `hasShim`：是否带前端 JS 片段（工具据此判断要不要等 `__CJ_TAURI__.<插件名>`）
 * 数组与权限键都按字典序排：HashMap 迭代顺序不定，工具的输出 / diff 需要稳定。
 *
 * 为什么不放进 `Plugin` 接口（RFC §7 的 v1 结论）：这些数据框架本就能从 `commands()` /
 * `events()` / `permissions()` 推出来，多一个接口方法只是给插件作者加负担；消费方要的是函数。
 */
public func describePluginsJson(plugins: ArrayList<Plugin>): JsonValue {
    let arr = ArrayList<JsonValue>()
    for (p in plugins) {
        var obj = JsonObject()
        obj.put("name", JsonString(p.name()))
        obj.put("commands", jsonStringArray(pluginCommandNames(p)))
        obj.put("events", jsonStringArray(pluginEventNames(p)))
        obj.put("permissions", jsonPermissionSets(p))
        obj.put("hasShim", JsonBool(p.jsShim().size > 0))
        arr.add(obj)
    }
    return JsonArray(arr)
}

/** 字符串数组 → JSON 数组，元素按字典序（HashMap 来的一律先排序，保证输出稳定） */
func jsonStringArray(items: ArrayList<String>): JsonValue {
    let sorted = sortedStrings(items)
    let arr = ArrayList<JsonValue>()
    for (s in sorted) {
        arr.add(JsonString(s))
    }
    return JsonArray(arr)
}

/** 命名权限集 → JSON 对象（键 = 集全名，值 = 成员全名数组）；键也按字典序 */
func jsonPermissionSets(p: Plugin): JsonValue {
    let sets = pluginPermissionSets(p)
    let keys = ArrayList<String>()
    for ((setName, _) in sets) {
        keys.add(setName)
    }
    var obj = JsonObject()
    for (setName in sortedStrings(keys)) {
        match (sets.get(setName)) {
            case Some(members) => obj.put(setName, jsonStringArray(members))
            case None => ()
        }
    }
    return obj
}

/** 复制一份并按字典序排序（不改动入参；元素量级只有每插件的几条命令，开销可忽略） */
func sortedStrings(items: ArrayList<String>): ArrayList<String> {
    let out = ArrayList<String>()
    for (s in items) {
        out.add(s)
    }
    out.sort()
    return out
}

/**
 * 未授权提示：插件声明了、但应用的能力清单没放行时，说清缺哪条、加到哪去。
 * 只提示、不改权限——放行与否仍由 capabilities 决定（RFC §5.3 的取舍 B）。
 * 调用时机：能力清单加载完成之后、页面加载之前（TauriApp.prepare）。
 */
public func warnUnauthorizedPlugins(plugins: ArrayList<Plugin>, caps: CapabilityRegistry): Unit {
    for (p in plugins) {
        for (name in pluginCommandNames(p)) {
            if (!caps.canInvoke(name)) {
                eprintln("[cj-tauri] 插件 ${p.name()} 的命令 ${name} 尚未授权，前端调用会被拒绝")
                eprintln("[cj-tauri]   请在 capabilities 目录的 json 里把 \"${name}\" 加进 commands")
            }
        }
        for (name in pluginEventNames(p)) {
            if (!caps.canEmit(name)) {
                eprintln("[cj-tauri] 插件 ${p.name()} 的事件 ${name} 尚未授权，推送会被丢弃")
                eprintln("[cj-tauri]   请在 capabilities 目录的 json 里把 \"${name}\" 加进 events")
            }
        }
    }
}
