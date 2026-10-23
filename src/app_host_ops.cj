package cjTauri

/**
 * TauriApp 的宿主能力预置 API（`src/app.cj` 的同包分片）
 *
 * 这一组方法的共同点：都是「必须赶在页面加载前定稿」的预置类能力（RFC-002 §5.2），
 * 或者是对它们做运行期微调（菜单项状态、窗口可见性）。
 *
 * 为什么拆出来：模型（`src/menu.cj` / `tray.cj` / `hotkey.cj` / `dragdrop.cj`）已经各自成文件，
 * 而 TauriApp 里这些「把模型交给宿主」的薄方法原本和启动、事件、IPC 装配挤在同一个文件里。
 * 拆开只是同包换文件：包边界与对外 API 一行未变（`extend` 补齐成员）。
 *
 * 同包拆分的代价（有意接受）：`extend` 碰不到 `private` 成员，所以被跨文件使用的字段与少数
 * 内部方法在 `app.cj` 里放宽成包内可见——对包外（应用 / 插件 / 测试子包）完全不可见。
 */
extend TauriApp {
    /**
     * 设置**默认窗口**的菜单栏（对标 Tauri 的 `Menu::set_as_app_menu` / `Window::set_menu`）
     *
     * 建议在 `run()` / `runUrl()` **之前**调用：预置类宿主能力要赶在页面加载前定稿
     * （RFC-002 §5.2）。之后调用也能用（宿主会把整棵树重建到 UI 线程上），只是页面上会看到
     * 菜单「晚一步」出现。
     *
     * 应用层会把模型留一份（见 `setMenuTo`），这样「只改某一维状态」的 API 才有
     * 「另一维现在是什么」可查——平台侧一次调用会同时写 enabled 与 checked。
     */
    public func setMenu(menu: MenuModel): TauriApp {
        return this.setMenuTo(DEFAULT_WINDOW_LABEL, menu)
    }

    /**
     * 设置**指定窗口**的菜单栏（多窗口）
     *
     * 同一个 `MenuModel` 实例给多个窗口时，两窗留存的「模型状态」是**同一个对象**——运行期改
     * 一个窗口的勾选会顺带改到另一个窗口的模型（平台上两份菜单仍是独立的）。要各自独立，
     * 就每个窗口各建一份模型。
     */
    public func setMenuTo(label: String, menu: MenuModel): TauriApp {
        match (this.hostOf(label)) {
            case Some(host) =>
                this.menus.add(label, menu)
                host.setMenu(menu.toWire())
            case None =>
                eprintln("[cj-tauri] setMenu: 未注册的窗口 label \"${label}\"（菜单未设置）")
        }
        return this
    }

    /**
     * 运行期改默认窗口某个菜单项的状态（enabled 与 checked 一起写）
     *
     * 只想改其中一维就用 `setMenuItemEnabled` / `setMenuItemChecked`——它们会拿模型里的
     * 另一维补齐，免得把用户刚点出来的勾选抹掉。
     */
    public func setMenuItemState(id: String, enabled: Bool, checked: Bool): TauriApp {
        return this.setMenuItemStateTo(DEFAULT_WINDOW_LABEL, id, enabled, checked)
    }

    /** 指定窗口版本（多窗口）：语义同 `setMenuItemState`，作用于 `label` 那个窗口 */
    public func setMenuItemStateTo(label: String, id: String, enabled: Bool, checked: Bool): TauriApp {
        this.applyMenuState(label, id, enabled, checked)
        return this
    }

    /**
     * 只改默认窗口某个菜单项的**启用**状态；勾选态取自应用层留存的模型
     *
     * 模型里没有这个 id 时抛 `CommandException`（**不**静默拿 false 顶上）：静默写会抹掉
     * 用户看到的勾选，报错至少说得清「哪个 id 在哪个窗口找不到」。
     */
    public func setMenuItemEnabled(id: String, enabled: Bool): TauriApp {
        return this.setMenuItemEnabledTo(DEFAULT_WINDOW_LABEL, id, enabled)
    }

    /** 指定窗口版本（多窗口）：语义同 `setMenuItemEnabled` */
    public func setMenuItemEnabledTo(label: String, id: String, enabled: Bool): TauriApp {
        let cur = this.requireMenuItem(label, id)
        this.applyMenuState(label, id, enabled, cur.checked)
        return this
    }

    /** 只改默认窗口某个菜单项的**勾选**状态；启用态取自应用层留存的模型 */
    public func setMenuItemChecked(id: String, checked: Bool): TauriApp {
        return this.setMenuItemCheckedTo(DEFAULT_WINDOW_LABEL, id, checked)
    }

    /** 指定窗口版本（多窗口）：语义同 `setMenuItemChecked` */
    public func setMenuItemCheckedTo(label: String, id: String, checked: Bool): TauriApp {
        let cur = this.requireMenuItem(label, id)
        this.applyMenuState(label, id, cur.enabled, checked)
        return this
    }

    /**
     * 取「另一维状态」的当前值（从应用层留存的模型里查）
     *
     * 模型不存在通常意味着应用用 `WebViewHost.setMenu()` 直设了菜单、绕过了应用层——
     * 报错里点名这条出路，比让人对着「状态怎么被抹了」猜要好。
     */
    private func requireMenuItem(label: String, id: String): MenuItem {
        match (this.menus.get(label)) {
            case None =>
                throw CommandException(
                    "菜单模型不存在：窗口 \"${label}\" 的菜单是用 app.setMenu() 设的吗？" +
                    "（用 WebViewHost.setMenu 直设的菜单应用层没有模型，改单项状态请用 setMenuItemStateTo）"
                )
            case Some(model) =>
                match (model.findById(id)) {
                    case Some(item) => return item
                    case None => throw CommandException("菜单项不存在：\"${id}\"（窗口 \"${label}\"）")
                }
        }
    }

    /**
     * 写菜单项状态：平台侧 + 应用层模型同步（模型里的 item 是可变对象，见 src/menu.cj）
     *
     * 模型不跟上会出错：勾选项在平台上一被点就自己翻了 checked，模型若还记旧值，
     * 下一次「只改启用」就会拿旧值去写，把刚点出来的勾选抹回去。
     * 模型缺失只提示、不拦——平台侧照写（与 `WebViewHost.setMenuItemState` 的「找不到静默忽略」一致）。
     */
    private func applyMenuState(label: String, id: String, enabled: Bool, checked: Bool): Unit {
        match (this.menus.get(label)) {
            case Some(model) =>
                match (model.findById(id)) {
                    case Some(item) =>
                        item.enabled = enabled
                        item.checked = checked
                    case None => eprintln("[cj-tauri] setMenuItemState: 模型里没有 \"${id}\"（只改平台侧）")
                }
            case None => eprintln("[cj-tauri] setMenuItemState: 窗口 \"${label}\" 无应用层菜单模型（只改平台侧）")
        }
        match (this.hostOf(label)) {
            case Some(host) => host.setMenuItemState(id, enabled, checked)
            case None => eprintln("[cj-tauri] setMenuItemState: 未注册的窗口 label \"${label}\"（未生效）")
        }
    }

    /**
     * 把 shell 事件里的**平台真值**回写到应用层模型（kind=menu、id 命中时）
     *
     * 为什么必须做：勾选项在平台上一被点就自己翻了 checked，模型还记着旧值——之后一次
     * 「只改启用」拿着旧值去写，就把用户刚点出来的勾选抹回去了。
     * 模型 / 项不存在时静默：事件也可能来自没用应用层菜单的窗口（宿主层直设菜单的老路径）。
     *
     * 从 `app_events.cj` 的 shell 分发调用，所以不写 `private`（同包跨文件可见）。
     */
    func syncMenuStateFromShell(label: String, id: String, enabled: Bool, checked: Bool): Unit {
        match (this.menus.get(label)) {
            case Some(model) =>
                match (model.findById(id)) {
                    case Some(item) =>
                        item.enabled = enabled
                        item.checked = checked
                    case None => ()
                }
            case None => ()
        }
    }
}

/**
 * 同上：拖放 / 全局快捷键 / 托盘 / 窗口可见性 / 日志落盘
 *
 * 分成两个 `extend` 块只为控制单块长度，语义上同属「宿主能力预置」这一组。
 */
extend TauriApp {
    /**
     * 设置默认窗口的拖放策略（RFC-002 §5；必须在 `start()` / `startUrl()` 之前调）
     *
     * 打开后页面经 `dragdrop:files` 事件收到拖入的文件路径数组（`paths: [...]`），
     * 该事件需在能力清单 `events` 里声明；不设 = 不注册 drop target（默认关）。
     * 平台没有该能力（如 Windows 桩阶段）时宿主只记日志，不报错——能力位经 `system:host` 如实上报。
     */
    public func setDragDrop(policy: DragDropPolicy): TauriApp {
        return this.setDragDropTo(DEFAULT_WINDOW_LABEL, policy)
    }

    /** 指定窗口版本（多窗口）：语义同 `setDragDrop`，作用于 `label` 那个窗口 */
    public func setDragDropTo(label: String, policy: DragDropPolicy): TauriApp {
        match (this.hostOf(label)) {
            case Some(host) =>
                host.setDragDropPolicy(policy.enabled, policy.files)
            case None =>
                eprintln("[cj-tauri] setDragDrop: 未注册的窗口 label \"${label}\"（策略未设置）")
        }
        return this
    }

    /**
     * 注册**默认窗口**的全局快捷键（RFC-003 第 5 期）
     *
     * 全局 = 焦点不在本应用时也生效（Linux = X11 grab，能力位 `hotkey` 如实上报）。
     * 触发时页面收 `hotkey:press` 事件（载荷 `{"id":…}`，需在能力清单 `events` 声明）；
     * 应用侧钩子挂 `onShellEvent`（信封 `kind == "hotkey"`）。运行期再调 = 整表替换。
     */
    public func setGlobalHotkeys(keys: HotkeyModel): TauriApp {
        return this.setGlobalHotkeysTo(DEFAULT_WINDOW_LABEL, keys)
    }

    /** 指定窗口版本（多窗口）：语义同 `setGlobalHotkeys`，作用于 `label` 那个窗口 */
    public func setGlobalHotkeysTo(label: String, keys: HotkeyModel): TauriApp {
        match (this.hostOf(label)) {
            case Some(host) =>
                host.setGlobalHotkeys(keys.toWire())
            case None =>
                eprintln("[cj-tauri] setGlobalHotkeys: 未注册的窗口 label \"${label}\"（快捷键未设置）")
        }
        return this
    }

    /**
     * 设置**托盘**（RFC-002 §7.C；托盘是应用级资源，走默认窗口的宿主）
     *
     * 图标 + 提示 + 右键菜单一次给定；重复调用 = 整体重建，`TrayModel("")` = 移除。
     * 菜单项被点时页面收 `tray:click` 事件（载荷 `{"id":…}`，需在能力清单 `events` 声明）；
     * 应用侧钩子挂 `onShellEvent`（信封 `kind == "tray"`）。平台不支持时桥如实打日志、托盘不出现。
     */
    public func setTray(tray: TrayModel): TauriApp {
        match (this.hostOf(DEFAULT_WINDOW_LABEL)) {
            case Some(host) =>
                host.setTray(tray.toWire())
            case None =>
                eprintln("[cj-tauri] setTray: 默认窗口未注册（托盘未设置）")
        }
        return this
    }

    /**
     * 开启日志落盘（RFC-003 第 5 期）
     *
     * 单文件产物是 Windows 的 GUI 子系统、双击时没有控制台，stderr 无处可去——开了它，C 桥与
     * 仓颉侧**两侧**的诊断都落到这一个文件（`system:host` 的 `logFile` 回读生效路径）。
     * **越早调越好**（宿主的装配期日志比 `run()` 还早）：最晚在 `run()` / `runUrl()` 之前。
     * 超预算按份轮转（`log.1` … `log.keep`）；不调用 = 不落盘，行为与之前完全一致。
     * `CJ_TAURI_LOG_MAX_KB` / `CJ_TAURI_LOG_KEEP` 可覆盖这里的预算——报障时让用户改环境变量，
     * 不必动代码。被拒（路径打不开 / 已激活）时桥打一行 stderr 并**保持不落盘**，这里不假装成功。
     */
    public func setLogFile(path: String): TauriApp {
        return this.setLogFile(path, CJ_LOG_DEFAULT_MAX_KB, CJ_LOG_DEFAULT_KEEP)
    }

    /** 显式给预算的版本（仓颉没有默认参数值，所以拆成两个重载） */
    public func setLogFile(path: String, maxKB: Int64, keep: Int64): TauriApp {
        let kb = logBudgetFromEnv("CJ_TAURI_LOG_MAX_KB", maxKB)
        let kp = logBudgetFromEnv("CJ_TAURI_LOG_KEEP", keep)
        let _ = enableLogFile(path, kb, kp) // 成败都由桥出声：成功落文件、被拒落 stderr
        return this
    }

    /**
     * 落到平台惯例目录的日志文件（`appName` 作文件名）
     *
     * Linux `$XDG_STATE_HOME/cj-tauri/<app>.log`（缺省 `~/.local/state/…`）、
     * Windows `%LOCALAPPDATA%\cj-tauri\logs\<app>.log`；`CJ_TAURI_LOG` 给了路径时优先用它——
     * 报障的人只需带一个环境变量启动，不必知道平台目录在哪（也不受应用是否设过名字影响）。
     */
    public func setLogToDefaultFile(appName: String): TauriApp {
        return this.setLogToDefaultFile(appName, CJ_LOG_DEFAULT_MAX_KB, CJ_LOG_DEFAULT_KEEP)
    }

    /** 显式给预算的版本（同上，重载而非默认参数） */
    public func setLogToDefaultFile(appName: String, maxKB: Int64, keep: Int64): TauriApp {
        return this.setLogFile(logPathOrDefault(logEnvOr("CJ_TAURI_LOG", ""), appName), maxKB, keep)
    }

    /**
     * 显示 / 隐藏**默认窗口**（对标 Tauri 2 的 `window.show()` / `window.hide()`）
     *
     * 典型用途是「最小化到托盘」的还原路径：托盘菜单项或全局快捷键触发时 `setWindowVisible(true)`。
     * `run()` / `runUrl()` 之前调用同样有效（宿主记下，建窗时定稿）。
     */
    public func setWindowVisible(visible: Bool): TauriApp {
        return this.setWindowVisibleTo(DEFAULT_WINDOW_LABEL, visible)
    }

    /** 指定窗口版本（多窗口）：语义同 `setWindowVisible`，作用于 `label` 那个窗口 */
    public func setWindowVisibleTo(label: String, visible: Bool): TauriApp {
        match (this.hostOf(label)) {
            case Some(host) =>
                host.setWindowVisible(visible)
            case None =>
                eprintln("[cj-tauri] setWindowVisible: 未注册的窗口 label \"${label}\"（窗口未改可见性）")
        }
        return this
    }
}
