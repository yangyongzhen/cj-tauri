package cjTauri

/**
 * 三段式 API 的第二段（批次 3，RFC-002 §4.2）
 *
 * 业务入口全文就这几行：
 * ```
 * import cjTauri.*
 * main(): Int64 {
 *     launch(build())
 *     return 0
 * }
 * ```
 *
 * `Platform.discover()` 是唯一「端在哪儿」的知识入口（§5.1）；
 * 桌面阻塞主循环，移动端的非 UI 线程 spawn 由宿主负责（§4.2 鸿蒙示例）。
 *
 * 与 RFC 示意写法的偏差（照实记录）：两个重载代替默认参数
 * （当前工具链不用默认参数），`launchWith` 供测试注入假上下文、
 * 鸿蒙 Ability 触发时给移动端上下文。
 */
public func launch(spec: AppSpec): Unit {
    let target = Platform.guessTarget()
    launchWith(spec, Platform.discover(spec.appId, target.arch))
}

/** 注入上下文的变体：测试给假上下文；鸿蒙侧给 Platform.mobile(filesDir) */
public func launchWith(spec: AppSpec, context: AppContext): Unit {
    eprintln("[cj-tauri] launch：${spec.name}（os=${context.target.os} display=${context.target.display}）")
    let app = assemble(spec)
    app.run(spec.pageSource)
}

/**
 * spec → TauriApp（纯装配、不 run）：launch 与单测共用
 *
 * 装配顺序即框架契约顺序：窗口配置 → 插件 → 资产解析器 → 能力目录 → 业务命令（wire）。
 */
public func assemble(spec: AppSpec): TauriApp {
    let app = TauriApp().window(spec.windowConfig)
    for (p in spec.plugins) {
        app.plugin(p)
    }
    if (spec.assetResolver.isSome()) {
        app.assets(spec.assetResolver.getOrThrow())
    }
    if (spec.capabilitiesDir.size > 0) {
        app.loadCapabilities(spec.capabilitiesDir)
    }
    if (spec.wireFn.isSome()) {
        let f = spec.wireFn.getOrThrow()
        f(app)
    }
    return app
}
