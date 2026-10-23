package cjTauri

import stdx.encoding.json.*

/**
 * TauriApp 的事件收发与 shell 事件分发（`src/app.cj` 的同包分片）
 *
 * 为什么拆出来：这一组函数只围绕「事件」这一个职责——后端投前端（emit 三兄弟）、
 * 前端订阅（listenEvent）、宿主 shell 事件（菜单 / 托盘 / 热键）的钩子与回投。
 * 拆分只是同包内换文件，包边界、可见性对外、API 一行未变（`extend` 补齐成员）。
 *
 * 同包拆分的代价（有意接受）：`extend` 碰不到 `private` 成员，所以被跨文件使用的字段
 * 与少数内部方法在 `app.cj` 里放宽成包内可见——对包外（应用 / 插件 / 测试子包）完全不可见。
 */
extend TauriApp {
    /**
     * 向所有窗口推送事件（对标 Tauri 的 `emit`；经 capability 校验，未声明的事件不投递）
     */
    public func emit(event: String, payload: JsonValue): Unit {
        this.hub.emitAll(event, payload)
    }

    /**
     * 向所有窗口推送「只保最新」的事件：同一帧内同名事件只投最后一次 payload，中间值丢弃
     *
     * 给进度 / 动画 / 滚动位置这类高频且「中间值没有意义」的事件用；需要每条都到达的场合继续 `emit`。
     * 能力校验与 `emit` 共用一份 `events` 白名单（不额外放行）。与 Tauri v2 的差异：它核心不做合并，
     * 高频事件要么应用层自己限流、要么改用 `Channel`——我们的选择是给一条显式的 API，
     * 理由与源码级对照见 docs/IPC-通信机制.md §6 第 5 项。
     */
    public func emitLatest(event: String, payload: JsonValue): Unit {
        this.hub.emitLatest(event, payload, "")
    }

    /**
     * 向指定窗口推送事件（对标 Tauri 的 `app.emit_to(label, event, payload)`）
     *
     * 多窗口的定向投递入口。label 未注册时**什么都不投**并打一条 stderr——不回落成广播：
     * 写错 label 的表现就该是「谁都没收到」，静默变广播比丢事件更难查（见 WindowRegistry.targets）。
     * 空串 = 广播，与 `emit` 等价。
     */
    public func emitToWindow(event: String, payload: JsonValue, window: String): Unit {
        this.hub.emitToWindow(event, payload, window)
    }

    /**
     * 注册后端事件监听器：前端 `emit(event, payload)` 会调用到这里
     * （对标 Tauri Rust 侧的 `app.listen(...)`）
     *
     * 与 `emit` 是相反方向：`emit` 是后端 → 前端，本方法收前端 → 后端。
     * 后端自己 emit 出去的事件**不**回流到监听器（否则「收到就再广播」会自激）。
     * 装配期调用（`run()` / `runUrl()` 之前，或插件的 setup() 里）；注册本身不需要能力授权——
     * 权限卡在前端那侧（emit 的事件必须在 capability 的 events 里声明）。
     */
    public func listenEvent(event: String, handler: (JsonValue) -> Unit): TauriApp {
        this.hub.listenEvent(event, handler)
        return this
    }

    /**
     * 应用层的 shell 事件钩子（对标 Tauri 的 `on_menu_event`）
     *
     * 回调参数是 `(信封 JSON, 发生事件的窗口 label)`。给原始 JSON 而不是解析后的对象：钩子多半
     * 是应用自己写的诊断 / 日志（探针就靠它断言），原样透传最不容易丢信息。label 是必需的——
     * 钩子是应用级的，一份回调要能分辨事件来自哪个窗口。
     *
     * 与前端事件**两条路都走**：先按注册顺序跑钩子（应用侧决策，例如改菜单项状态），再投前端
     * 事件（页面自己 `listen("menu:click", …)`）。钩子里抛异常只留一行 stderr，不挡后面的钩子
     * 与前端事件。
     */
    public func onShellEvent(handler: (String, String) -> Unit): TauriApp {
        this.shellHooks.add(handler)
        return this
    }

    /**
     * 装配本窗口的 shell 事件分发（应用层是唯一安装者）
     *
     * 必须在宿主 `start()` / `startUrl()` **之前**装：窗口一建出来菜单点击就可能来，装晚了会漏。
     * 宿主层的 `setShellHandler` 是**可变槽位**（后装覆盖先装），所以应用要处理 shell 事件请用
     * `onShellEvent()`（应用级钩子，可叠加多条），不要和框架抢宿主槽位——抢赢的那个会让框架的
     * 前端事件分发失效。
     */
    func wireShellEvents(host: WebViewHost, label: String): Unit {
        host.setShellHandler({ json => this.dispatchShellEvent(label, json) })
    }

    /**
     * shell 事件 → 应用层钩子 + 前端事件（按窗口投递）
     *
     * 路由靠**闭包捕获的 label**：C 侧已按宿主句柄把事件分给了本窗口的回调（见 host.cj 的
     * `ShellRoute`），这里再按 label 投前端事件，多窗口下不会串。事件放不放行由 capability 清单
     * 决定——没在清单里声明 `menu:click` 就是静默丢弃（最小权限不破）。
     *
     * 本函数跑在**宿主 UI 线程**上（C 桥的 shell 回调就在那儿），所以中途不碰 GTK / WebKit 之外
     * 的东西：投递走 `emitToWindow` → `jsSink`，与其它事件同一条路。
     */
    private func dispatchShellEvent(label: String, json: String): Unit {
        for (hook in this.shellHooks) {
            try {
                hook(json, label)
            } catch (e: Exception) {
                eprintln("[cj-tauri] shell hook 抛出异常（已忽略）：${e}")
            }
        }
        match (parseShellEnvelope(json)) {
            case None => eprintln("[cj-tauri] shell event 信封解析失败（已丢弃）：${json}")
            case Some(obj) =>
                var kind = ""
                if (let Some(k) <- shellString(obj, "kind")) {
                    kind = k
                }
                match (shellEventNameFor(kind)) {
                    case None => eprintln("[cj-tauri] shell event: 未知 kind \"${kind}\"（未投递）：${json}")
                    case Some(event) =>
                        if (kind == "menu") {
                            this.syncMenuStateFromShellObj(label, obj)
                        }
                        try {
                            this.hub.emitToWindow(event, obj, label)
                        } catch (e: Exception) {
                            eprintln("[cj-tauri] shell event 投递失败（已忽略）：${e}")
                        }
                }
        }
    }

    /**
     * 菜单事件里的平台真值 → 应用层模型：id / enabled / checked 三者齐了才写
     *
     * 缺字段不拿默认值顶（见 shellBool 的注释）——这条路径写错的表现是「勾选莫名回退」，
     * 比少同步一次难查得多。
     */
    private func syncMenuStateFromShellObj(label: String, obj: JsonObject): Unit {
        if (let Some(id) <- shellString(obj, "id")) {
            if (let Some(enabled) <- shellBool(obj, "enabled")) {
                if (let Some(checked) <- shellBool(obj, "checked")) {
                    this.syncMenuStateFromShell(label, id, enabled, checked)
                }
            }
        }
    }

    /**
     * 把一段回执 / 事件投递给目标窗口（批次 2 的 label 路由）
     *
     * @param window 目标窗口 label；空串 = 广播（按登记顺序投给每个窗口）
     *
     * 未注册的 label 打 stderr 而非静默丢弃：`emitToWindow` 写错 label 的表现是「前端什么都没
     * 收到」，只剩这条日志能定位。空注册表（清单导出模式等）到不了这里——那时没有页面能发消息。
     */
    func deliverJs(json: String, window: String): Unit {
        // 直派：JSON 本身就是合法 JS 对象字面量，直接嵌进 eval 交给桥的 _dispatch。
        // 不走 window.postMessage —— 那样每条响应要多一次结构化克隆 + 一次 message 事件派发，
        // 而且那个监听器是全页面（含 iframe / opener）都能投递的伪造入口。
        let js = "window.__CJ_TAURI__._dispatch(${json});"
        let targets = this.windows.targets(window)
        if (targets.size == 0 && window.size > 0) {
            eprintln("[cj-tauri] 未注册的窗口 label：\"${window}\"（回执 / 事件未投递）")
            return
        }
        for (rec in targets) {
            rec.host.runJs(js)
        }
    }
}
