package cjTauri

import std.collection.*

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

/** 汇总所有插件的 jsShim 成一个 script 块；没有任何 shim 时返回空串 */
public func assemblePluginJs(plugins: ArrayList<Plugin>): String {
    var body = ""
    for (p in plugins) {
        let shim = p.jsShim()
        if (shim.size > 0) {
            body += shim
            body += "\n"
        }
    }
    if (body.size == 0) {
        return ""
    }
    return "<script>\n" + body + "</script>\n"
}

/**
 * 把插件 JS 块插到第一个 head 结束标签之前——必须早于页面脚本执行，
 * 否则页面里读 window.__CJ_TAURI__.<插件名> 会拿到 undefined。
 * 没有该标签时退化插到文档最前，并在 stderr 说明（畸形 HTML 的兜底，RFC §5.4）。
 */
public func injectPluginJs(html: String, jsBlock: String): String {
    if (jsBlock.size == 0) {
        return html
    }
    if (let Some(pos) <- html.indexOf("</head>")) {
        return html[0..pos] + jsBlock + html[pos..html.size]
    }
    eprintln("[cj-tauri] HTML 里没有 </head>，插件 JS 已插到文档最前")
    return jsBlock + html
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
