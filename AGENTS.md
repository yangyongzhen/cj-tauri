# cj-tauri 项目开发规范（AGENTS.md）

> 本文件是本项目的**开发契约**：人类开发者与 AI 助手共同遵守，由 agent 自动加载注入。
> 改代码前先读 §1 门禁与 §2 架构契约。适用版本：**1.0.0**（2026-10-17），与 `CHANGELOG.md` 同步维护。
> 当前进度、未完成项与本机环境坑见 `docs/进度记录.md`；会话上下文导出（含换到 Linux 机器怎么接）见 `docs/会话交接.md`。

## 0. 项目定位

**仓颉语言的 Tauri 2**：用华为仓颉语言实现的混合开发框架——**仓颉后端（静态编译）+ 系统 WebView 前端（HTML/CSS/JS）**。

三件套对应关系：WebView 宿主（对应 tao/wry）、IPC 双向桥（invoke/resolve/event）、能力安全模型（capability 白名单）。
配套仓颉原生脚手架 CLI 与工程模板：`cli/templates/app/`（内联 HTML 的零 Node 样板，`create` 缺省用它）、
`cli/templates/app-vue/`（Vue 3）、`cli/templates/app-react/`（React 18）——后两者带 `ui/` 前端工程，
`cj-tauri dev` 会接管它们的 Vite dev server（`CJ_TAURI_DEV_URL`）。
平台状态：**Windows（WebView2）已实机跑通**、**Linux（WebKitGTK）已跑通**、
**鸿蒙（ArkWeb）宿主已真机闭环**（宿主写在仓颉侧、不走 C 桥；**多窗口 label 路由已取证**，
宿主能力位仍全 0，判据见 `native/platforms/harmonyos/README.md`）。

## 1. 交付门禁

1. `cjpm build` 通过（框架根目录）；改动涉及 CLI 时再跑 `cd cli && cjpm build`，涉及示例时再跑 `cd examples/hello && cjpm build`。
2. **实机跑一轮**：Windows 用 `run_win.bat`（仓内示例）或 `cli\cj-tauri.bat run`；交付凭证是**桥的 stderr 日志**——
   窗口创建成功、`set window:` 行、`js -> native` 与实际调用次数吻合、`ExecuteScript -> hr=0x00000000`。
3. 行为变更必须给出**可观测证据**（日志行、`system:version` 返回值、窗口标题等），不允许「先交付后补证据」。
4. 跑不起来就如实说明（含「哪些平台未验证」），禁止把未验证说成通过。
5. 单元测试为**渐进目标**：新增纯函数/解析器优先补 `cjpm test`；框架整体端到端仍以实机为准。
   仓颉侧测试放在 `src/tests/` 子包（`package cjTauri.tests`，可访问父包符号），入口是 `scripts/test.sh`；
   当前 294 个用例。C 桥的公共核心（`native/bridge_core.c`）另有一份**桩平台自检**
   （`native/tests/test_bridge_core.c`，228 项断言，不依赖 SDK / 图形栈），入口是
   `scripts/test-bridge-core.sh`——`test.sh` 与 `check-static.sh` 都会跑它。
   `src/` 根只留框架源码——`cjpm` 不扫描顶层 `tests/` 目录，挪出去会静默变成 0 个用例。
   实机结论用 `scripts/e2e-evidence.sh` 落成 `dist/e2e-evidence/<平台>-<名字>.json`（平台 / runtime
   版本 / 每条断言的命中次数），`check-static.sh` 会校验它的结构——矩阵里的 `supported` 指证据时指这份。

## 2. 架构契约（改哪里、怎么改）

- **平台差异只允许出现在两处**：仓颉侧 `@When` 条件编译、C 桥 `native/bridge_*.c`。
  IPC、能力校验、命令分发必须跨平台共用，禁止在上层散落运行期平台分支。
- **新增宿主能力**：先扩 `WebViewHost` 接口（`src/host.cj`），再改各平台实现，最后在 C 桥加**同名同签名**的导出函数
  （`cj_bridge_*`）。两平台导出名必须一致，避免上层出现平台分叉的调用点。
- **预置类宿主能力**（窗口菜单、拖放策略这类「必须赶在页面加载前定稿」的）：一律在 `start()` / `startUrl()`
  之前调；默认窗经 `app.hostOf(DEFAULT_WINDOW_LABEL)` 拿宿主——实现对默认 label 有回落，`run()` 之前
  也拿得到（注册表里的正式登记发生在 `prepare()`）。运行期再改菜单状态走 `setMenuItemState`（按 id 找，
  找不到静默忽略）。**宿主级回调一律在仓颉侧按句柄路由**（`HostGlobals.hostRoutes` +
  `registerHostRoute` / `hostRouteOf` + `cj_bridge_host_eq`），不要用静态单槽——多窗口下后装配的窗口
  会覆盖先装配的，先装配的窗口从此收不到自己的事件。按句柄认领的三类是 shell 事件 / 窗口销毁 /
  对话框结果；**唯一例外是消息回调**（报文自带 window label，框架给所有窗装同一只派发器，有意保留单槽）。
  当前能力位：菜单已完成（应用层 API + `menu` 插件 + 前端事件回投，Windows 实机点选通过），
  **文件拖入已完成**（`DragDropPolicy` + `setDragDrop`，start 前定稿；URI 解析在 C 桥 core，
  报文 `drop` → 前端 `dragdrop:files`，Linux 实机取证、Windows 同名桩），
  **托盘已解禁**（2026-10-15 用户裁定：剪贴板历史管理器驱动，Linux 走 libayatana-appindicator3、
  RFC-002 §6.3 的可选编译约定不变——无依赖机器编译照过、`tray=0` 如实；**Windows 走
  `Shell_NotifyIconW` 已落地**，菜单用 `CreatePopupMenu`、点击回投 `{"kind":"tray","id":…}`），
  **全局快捷键两平台齐了**（Linux X11 grab / Windows `RegisterHotKey`，同一套 accel 词法：
  注册失败如实在 stderr 说明、不致命），
  **开窗尺寸随屏幕自适应已撤除**（用户裁定，2026-10-16：实测不如固定尺寸舒服）——
  `WindowConfig.autoSize` / `WindowAutoSize` / `cj_bridge_set_window_auto` / core 的 `cj_core_window_size`
  与两平台建窗换算（GTK 的 `screen_workarea` / Win32 的 `SPI_GETWORKAREA`）全数删除，桩自检对应 10 项一并取消；
  `WindowConfig(title, width, height)` 给的就是最终尺寸。页面侧的等比缩放（`zoom` + 视口单位补偿）
  仍是**应用自定、框架不插手**（做法与坑见 `docs/使用文档.md`）。
  **窗口可见性 + 最小化到托盘是宿主基元**（`setWindowVisible` / `setMinimizeToTray`，不占能力位——
  没有平台只有一半）：隐藏态页面照常跑，还原入口由应用给（托盘菜单 / 全局快捷键），
  最小化那一刻平台复核托盘是否**真的**装上了，没装就如实降级为普通最小化 + 一行 stderr。
  事件分发的落法：宿主层 `setShellHandler` 是**单槽**（框架装一次做分发），
  应用侧一律挂**可叠加**的 `app.onShellEvent((json, label) => …)`，并自动投前端事件
  （`menu`→`menu:click`、`tray`→`tray:click`、`drop`→`dragdrop:files`，需在能力清单 `events` 声明）；
  菜单/状态改动走应用层 API（`setMenu(To)` / `setMenuItemState*`），别再直接调宿主——应用层要用
  留存的模型补齐「另一维状态」。
- **宿主无关的进程工具：后台静默子进程 `launchHidden()`（`src/process_hidden.cj`）**——应用产物是 GUI
  子系统、父进程没有控制台，用 `std.process.launch` 起**控制台程序**（cjh / ffmpeg 这类 CLI）会让 Windows
  给子进程配一个控制台窗口；这条走 C 桥（Windows = `CreateProcessW` + `DETACHED_PROCESS` + 三个标准句柄
  指 NUL；**不要用 `CREATE_NO_WINDOW`**——它只是不显示，子进程仍持有一个隐藏 console、conhost 照样挂，
  Linux = `posix_spawn` + 自成会话 + `/dev/null`），只留 pid 凭据（`isAlive()` / `stop()` 按 pid 走，
  Windows 的进程句柄当场关掉不占句柄表）。代价是**拿不到子进程的 stdout / stderr**，要读输出得另走管道。
  分工照老规矩：导出在 core（`cj_bridge_spawn_hidden` / `cj_bridge_kill_pid` / `cj_bridge_pid_alive`，
  两平台同名同签名），分叉只在 `cj_plat_*` 原语里（原语清单 24 个）。
- **插件 JS 的注入通道**：`Plugin.jsShim()` 由 `pluginInitScripts()` 收成「一个插件一段」，
  经 `WebViewHost.addInitScript()` 交给宿主，桥在 document-start 注入（排在 `BRIDGE_JS` 之后）。
  必须在 `start()` / `startUrl()` 之前注册；**不要再往 HTML 字符串里拼 `<script>` 注入 shim**——
  `runUrl()` 的页面 HTML 不在本进程，那样永远拿不到（RFC-插件体系 §5.4 的 v2）。
- **新增命令三处联动**（漏一处就用不了）：
  1. 实现 `CommandHandler`；
  2. `TauriApp.register("cmd", Handler())`；
  3. 在能力清单的 `commands` 里声明。
  只做 1+3 会得到 `command not registered`；只做 1+2 会得到 `command not allowed`。
- **新增插件三处联动**（同命令，漏一处就用不了）：
  1. 实现 `Plugin`（`src/plugin.cj`）——必写 `name()` + `commands()`，要推事件 / 前端 shim 再写 `events()` / `jsShim()`；
  2. 装配：`TauriApp().plugin(XxxPlugin())`（框架自动把命令注册成 `"<插件名>:<短名>"`）；
     **`commands()` 返回的 map 键必须写「短名」**——前缀由框架补，你在键里再写一次就得到
     `redis:redis:connect`：日志只显示前缀重复，而所有命令都以「未注册」告终（`command not registered`，
     Redis 插件实机第一轮就是这么被挡下的）。
  3. 在能力清单的 `commands` 里声明 `"<插件名>:<短名>"`。
  插件**只声明「我提供什么」，不自动放行**（默认最小权限不破）；`jsShim()` 返回的前端片段由框架
  汇总插到第一个 `</head>` 之前（早于页面脚本），`runUrl()` 下无法并入需在 stderr 提示。
  实现文件放 `src/plugins/<名字>/`（**一个插件一个子包**，`package cjTauri.plugins.<名字>`，如
  `src/plugins/fs/plugin_fs.cj`；FFI 声明也随插件放同目录（如 `src/plugins/sqlite/sqlite_ffi.cj`）——
  但**核心宿主消费**的 FFI 例外，如
  `src/clipboard_bridge.cj` 属核心包，判定标准是「谁调用谁包内」），可跑样板 `examples/plugin-fs/`，
  设计见 `docs/RFC-插件体系.md`。子包可见父包全部 `public` 符号，反向（核心 import 插件）禁止；
  单测要直接构造的命令 handler / 辅助函数须 `public`（跨包不再同包可见）。
  **为什么一个插件一个子包**：仓颉的链接粒度是「包 = 静态库」，全挤在一个 `cjTauri.plugins` 包里时，
  应用用任何一个插件就会把整包对象拉进链接——只用 fs 的示例被 sqlite FFI 连坐、Windows 构建也要链
  `-lsqlite3`（2026-10-14 实测）。拆开后各插件独立成 `libcjTauri.plugins.<名字>.a`，没引用就不链接。
  `src/plugins/plugins.cj` 是 cjpm 的**扫描锚点**（空占位，只有 package 声明）——目录里没有 `.cj` 文件
  时 cjpm 不递归扫子目录，删了它所有插件子包会静默消失（`check-static` 6b-2 白名单它）。
  插件间**不得互相引用**（会重新引入连坐）；三插件共用的工具进核心共享层
  （如 `src/hexutil.cj` 的 `hexToBytes`/`bytesToHex`，从 serial 插件迁出）。
- **命名权限集（v1.1）**：插件用 `Plugin.permissions()` 声明「短集名 → 成员」，框架装配时注册成 `<插件名>:<短集名>`；
  应用的 `capabilities/*.json` 用 `"permissions": ["fs:readonly"]` 引用，成员展开后与 `commands`/`events`
  里的明文名字**同权**（`CapabilityRegistry.coveredByPermissionSet`，单层展开、不递归）。
  与插件的铁律一致：**集声明 ≠ 放行**，清单不引用就不生效；引用了没有插件提供的集名只提示不报错
  （`warnUnknownPermissionSets`，在插件装配完之后才可能判定）。旧清单全写明文的行为不变，两者可混用。
- **路径 scope（RFC-003 第 4 期）**：**命令放行 ≠ 参数放行**。清单可给某插件写 `scopes`
  （`"scopes": { "fs": { "allow": ["$HOME/notes/**"], "deny": ["**/id_rsa"] } }`），`Capability` 解析成
  `HashMap<String, ScopeRule>`（`src/scope.cj` 的 `parseScopeRule` / `scopeAllows`；注册中心按插件名查
  `CapabilityRegistry.scopeForPlugin`）。插件是否吃这层限制由 `Plugin.scopeAware()` 声明（默认 false）；
  声明的插件在自己 handler 里对**页面可控的路径参数**调 `IpcContext.resolveScopedPath(插件名, 原文)`，
  拿它替换自己拼路径——判定逻辑只在共享层（`src/scope.cj`），**别在平台实现里另判一份**。
  语义：**先 deny 后 allow**（deny 命中即拒）、allow 必须显式命中（空 allow = 该插件路径全拒）、模式
  `*` / `**` / `?` 与变量 `$HOME` / `$TEMP` / `$CWD`（`$CWD` 取自 `scopeCwdPath()`，认不出的变量原样保留）；
  匹配前规范化（存在走 `std.fs.canonicalize` 顺带解析软链接，不存在走词法折叠 `.` / `..`）。
  **没写 scope 的旧清单行为不变**（全量放行 + 启动打一行 stderr 提示，`warnUnscopedPlugins`）；
  越界被拒打 `[cj-tauri] scope denied (<插件名>): <原文> -> <规范化路径>`，回给前端的是业务错误
  `"<插件名>: path is outside the authorized scope"`。
  **运行期加白**：`TauriApp.allowScopePattern(plugin, pattern)` / `isScopeAllowed(plugin, value)`
  （`src/capability.cj` 的 `runtimeScopeAllow` 叠加层，`Mutex` 守着——命令分发是异步的，worker 线程在读），
  给「编译期不知道、用户当场要用」的端点留出口，**只应在取得用户明确确认之后调**（框架不做确认交互，
  它不理解你的 UI 语义；推荐落法是仓颉侧弹原生确认框——**页面点不了原生对话框**，被注入的脚本也就无法自行加白）。
  注册中心侧**只收具体值**：模式里出现 `*` / `?` 或制表/换行当场拒并回 `false`（一个通配透传进来就等于全放行，
  这条不变量由注册中心强制，任何应用绕不过去），应用侧仍该按自己的取值规则再校一遍。叠加只在内存里、重启即空，
  持久化与启动重放归应用（样板：`examples/ai-chat` 的 `app:allowHost` → 记进
  `~/.local/share/cj-ai-chat/allowed-hosts.txt`，`run()` 之前重放）。两条口径不破：
  **先 deny 后 allow**（加白掀不掉 `deny`）、清单没写 `scopes` 的插件不叠加（那时本就全量放行）。
- **内置命令**统一 `system:` 前缀，集中在 `src/api_system.cj`，并在 `TauriApp.run()` 里注册（`system:version/ping/echo/devtools`）。
- **CLI 取应用装配结果**（插件清单）：走环境变量 `CJ_TAURI_MANIFEST`（`json` / `text`）——`run()` / `runUrl()`
  在 `prepare()` 之后若见它，就把清单打到 stdout 并**直接返回、不创建窗口**（`src/app.cj` 的模式解析 + 渲染），
  消费方是 `cj-tauri info [--json]`（CLI 用 `executeWithOutput` 收 stdout）。CLI 侧**必须先过两道守卫**再启动应用：
  框架 `src/app.cj` 里有这个变量名、且应用产物不比它旧；缺一个就跳过——旧框架 / 陈旧产物认不出该变量，
  跑起来就是真开窗口，会把 `info` 卡死。
- **命令执行线程模型（异步分发）**：`IpcHub.handleInvoke` 只做校验——「未授权 / 未注册」在调用线程上**同步拒绝**，
  通过校验的命令 `spawn` 到 worker 线程执行（`runCommand`），结果经 `jsSink` 回投。**不要**把 `handler.handle`
  挪回调用线程（那会退化成「慢命令钉住宿主 UI 线程」，`shell:exec` / 原生对话框最先遭殃）；worker 里也**只能**经
  `jsSink` 回投，不要直接调 GTK / WebKit（仓颉轻量线程的堆上协程栈会被 JSC 的栈边界校验 abort，见 §4）。
  同一命令被并发调用**不保证执行顺序**，前端按 promise id 匹配；异步契约的用例在 `src/tests/ipc_hub_test.cj`。
- **能力清单加载**：默认在 `run()` 时自动扫描工作目录下 `capabilities/` 的所有 json；
  显式 `loadCapabilities(dir)` 或 `addCapabilityJson(json)` 优先，且一旦调用即不自动扫描。
- **依赖方向单向**：`app.cj` → `host.cj` / `ipc_hub.cj` → `capability.cj`；禁止反向依赖与循环依赖
  （需要跨层协作时用回调注入，不要引入双向引用）。
- 新增文件按单一职责拆分（例：`src/window.cj` 只放窗口配置模型，`src/capability_loader.cj` 只放清单加载/扫描）。
- **native/ 目录契约**：`native/core/`（`bridge_core.c/.h` + `bridge_js.h`，跨平台共享层，GTK-free，
  桩平台自检就编它）、`native/platforms/linux|windows|harmonyos/`（平台实现，一个平台一个目录；
  harmonyos 的宿主**已在仓颉侧落地**（2026-10-19 真机闭环：页面 `system:version` 往返成功、
  回投 `platform=ohos`、同轮 `SIGSEGV` 0；同日第二轮又把**多窗口 label 路由**取证完——两窗各认自己的
  宿主、跨窗定向投递双向成立、报文 `window=` 与页面自认 `me=` 逐条恒等，判据见 §4 与
  `docs/鸿蒙ArkWeb接入踩坑.md` §8.1 / §8.2），
  但 **C 桥（`cj_core_*`）仍未落地**、宿主能力位仍全 0（菜单 / 托盘 / 快捷键 / 拖放 / 对话框
  一律如实拒绝，`hostCapabilities()` 返回 0）。**`@Component` / `Web` / `javaScriptProxy` 属应用侧**——
  框架包只要引用 ArkUI，鸿蒙包初始化链就会跳坏地址、启动即 SIGSEGV，详见 §4）、`native/tests/`（桩自检）。
  **FFI/源文件归属判据「谁调用谁包内」**；新平台从照抄 Windows 桩的同名导出开始。构建脚本
  `native/build_linux.sh` / `build_win.bat` 留在 native/ 根作入口（源文件路径已指子目录），
  **产物必须落在 `native/` 根**（`cjpm.toml` 的 `-Lnative -lcjtbridge`、CLI 模板、打包脚本都按这个路径找）。
  平台需求与验收矩阵见 `docs/需求追踪.md`（行为变更同轮更新对应行）；
  **架构/工程决策的「为什么」见 `docs/设计决策记录.md`（ADR）**——做出或推翻一个长期决策（架构形态、
  安全语义、状态门槛、文档组织）时同轮更新对应条目，别把理由只留在会话里。
  该文件的口径：标题写结论不写话题、代价必须写真实成本（含已踩的坑）、只写本仓判断依据不点名外部项目。

## 3. 编码规范

- 语言与工具链：仓颉 SDK 1.2.0 + stdx（1.2.0.1）；`cjc-version` 写**最低要求** `1.0.5`；C 桥用 mingw-w64 gcc 构建。
  引入新的第三方仓颉包必须先在本文件登记。
- 命名：函数/变量 `camelCase`，类型/接口 `PascalCase`，常量/全局 `UPPER_SNAKE_CASE`（如 `CJ_TAURI_VERSION`）；
  标识符用英文，**注释用中文**（与既有代码一致，不要中英混写同一句）。
- **编译零警告**：交付前 `cjpm build` 必须零警告（框架与示例同标准）。未使用的参数不改接口签名、
  就地 `let _ = <参数>` 显式弃用；未使用的 import 直接删；接口成员不写冗余 `public`（隐式公开）；
  废弃 API（如 `ArrayList.sort` → `std.sort.sort`）按提示迁移。不允许带着警告交付，也不允许用
  `-Woff` 全局压警告了事。
- 注释写「为什么」和坑，不逐行复述代码；公开 API 用 `/** */` 文档注释说明契约与调用时机。
- JSON 统一用 stdx 的 `stdx.encoding.json`（标准库无 `std.json`）。
- 前端只经 `window.__CJ_TAURI__` 的 `invoke` / `listen` / `emit`；业务代码里不要自己 `postMessage`。
- 文件重写要克制：改动既有长文件用定点替换，大段重写前先确认 git 里有可回退的副本。

## 4. 已踩坑清单（禁止重踩）

**仓颉语言**

- 块注释里出现 `/*` 会开启**嵌套注释**：正文/注释里写路径通配（如能力 json 的星号通配）必须改写，否则注释永不闭合、编译报莫名错误。
- **三引号字符串会处理反斜杠转义**：示例/模板把 HTML+JS 内联在 `"""` 里时，JS 的反斜杠转义会**先被仓颉吃掉**——
  写 `\n` 会变成真换行，把 JS 字符串或单行注释拆断 → 整段 `<script>` 语法错误 → 页面里一行都不执行，
  而 stderr 毫无提示（实测踩坑：`examples/plugin-fs` 的验证脚本静默全灭，靠对照 `examples/hello` 才定位）。
  内联 JS 里避免出现反斜杠（换行用 `String.fromCharCode(10)`，正则改用 `indexOf`），改完用 `node --check` 验一遍。
- **三引号字符串的「首个换行」与「两层转义」是两个独立坑**（2026-10-15 实测，`examples/leetcode-gui` 题库）：
  ① `"""` 之后**第一个换行会被吞掉**——想让字符串以换行开头就得再写一个换行，把内容写在 `"""` 同一行的
  第一个字符位置会丢；② 把整份 JSON 内嵌进 `"""` 时源码里的转义是**两层**（先 JSON 转义、再三引号转义）：
  JSON 的 `\n` 在源码里写 `\\n`、字符串字面量的引号写 `\\\"`；反解义后 JSON 文本里带**裸换行**
  （合法 JSON 允许），拿 python `json.loads()` 做批量自检必须 `strict=False`，否则报
  `Invalid control character`；③ 题库里的二叉树用例按**文件头声明的**「下标 i 的孩子在 2i+1 / 2i+2」
  写，别照 LeetCode 的压缩层序写期望值——两套约定下同一串数组是不同的树（实测就是这么红了一条）；
  ④ 题库本体是**仓颉源码里的三引号字符串**，里面的 `${…}` 是**活的插值**：题面/模板/答案写了
  `${x}` 会被当变量引用，应用一编译就报 `undeclared identifier 'x'`（要拼字符串就写 `x.toString()`）。
  **逐题单编的批量自检看不出来**（那时代码是独立源码、变量在作用域内），必须另加一条「题库文本不许含
  `${`」的守卫——`examples/leetcode-gui` 的自检脚本里有这条。
- `@When` 的平台取值**首字母大写**：`@When[os == "Windows"]` / `"Linux"`，不是 `windows`。
- 迭代 `String` 得到的是 **`UInt8` 字节**（不是码点、也不是 `Rune`，本条 2026-10-07 实测更正）：
  按码点数汉字得自己判 UTF-8 首字节（`(b & 0xC0u8) != 0x80u8` 才算一个），`String.size` 同样是**字节数**。
  把字节当码点数，ASCII 的检查（空格、制表符）照样对，只有汉字会错成 3 倍——
  实测 `examples/typing-poem` 的素材自检把「鹅鹅鹅」数成 9，汉字/拼音对齐检查整条失效。
- `cjc-version` 是最低要求而非精确版本：写 `1.0.5` 时用 1.2.0 的 cjc 也能编译。
- 条件编译函数按平台各写一份时，**不要发明未验证的平台标识**（例如未用过 macOS 就别加 `@When[os == "macOS"]`）。
- 字符串插值 `${名字}` 会撞同名函数：局部变量叫 `main` 时写 `"${main}"` 会报
  `unexpected main function in string interpolation`（`main` 被当函数解析）——换个变量名即可（实测：多窗口探针）。
- **lambda 不能捕获可变的局部变量**：`var x = ""` 后写 `sink = { _ => x = "y" }` 编译不过
  （提示无法捕获可变局部变量）。要在闭包里把数据带出来就用容器装——`let seen = ArrayList<String>()` 再
  `seen.add(...)`（实测：`system:host` 的单测想记下询问过的窗口 label）。
- **子包（单测）调不了框架的 `foreign func`**：`foreign func` 没有函数体、也就没有跨包符号，`src/tests/`
  的 `cjTauri.tests` 直接调 `cj_bridge_create()` 会在**链接期**炸
  （`ld.lld: error: undefined symbol: cjTauri:cj_bridge_create`，编译期不报）。办法是**框架包内包一层**
  （如 `host.cj` 的 `createBareHostHandle()`——子包可见、不算对外 API）；`@C` 函数相反，有函数体就能跨包调。

- **跨平台文件别按单平台的 warning 清 import**：`@When` 分支只在其中一个平台编译，另一平台看这个 import
  就是「未使用」。实测 2026-10-08：`host_webkit.cj` 的 `ArrayList` import 被 Windows 侧按 zero-warning
  清掉，Linux 侧当场编炸。清理前先想「这个符号是不是只有对面平台的分支在用」；拿不准就留一行注释说明。
  **漏 import 的另一种形状**（2026-10-13 实测）：文件里一个 import 都没有、正文直接写限定名
  `std.collection.ArrayList`——**本机 cjc 不支持这种限定名写法**，报的是 `error: undeclared identifier 'std'`
  （指向正文那个标识符，看着像「std 没导入」）。正确落法是给 import 加同款门禁
  （`@When[os == "Linux"]` + `import std.collection.*`）**并用短名**，镜像 `host_webview2.cj` 的 Windows 版；
  只补 import 不改正文不行——限定名仍报未声明，而那条 import 反过来被判 `unused import`。
- **`@Expect` 宏对 enum 实参推不出泛型**：单测断言里直接 `@Expect(x == SomeEnum.A)` 会报泛型推断失败；
  `JsonKind` 则**没有 `==`**（比较要走 match 分支）。这类断言改成显式 match / 布尔表达式再断言。
- **并发原语比想象中少**：`SyncCounter` **没有 `inc()`**（加一用 `add(1)`，另有 `dec()`），等待并发任务
  **不要去 `Thread` 上找 `join`/`wait`**——`Thread` 只有取消与异常处理相关成员，`spawn { => ... }` 返回的是
  `Future<T>`，等它做完 / 取结果用 `future.get()`（2026-10-16 实测：`let fu = spawn {...}` + `fu.get()` 编译运行均通）。
  并发测试用 `SyncCounter` 计数（`add(1)`），异步开线程用 `spawn { => ... }`（`src/ipc_hub.cj` 有先例）。
- **`stdx.net.http` 的 `ClientBuilder` 不带默认 TLS**：发 https 请求直接抛
  `HttpException: TLS must be configured when HTTPS requests are sent.`，必须显式
  `ClientBuilder().tlsConfig(TlsClientConfig())`（默认走系统证书库校验，不要图省事关校验）。
  只跑 http 的代码完全看不出来，一旦加个 https 调用就全灭（实测 2026-10-05：`examples/movie` 封面
  是 https，54 次取图全败，而后台 `http://` 接口一直正常）。
- `stdx.net.http` 的两个签名坑（都在 `examples/movie` 里实测）：① `readToEnd(resp.body)` **编译不过**——
  它要求 `T <: InputStream & Seekable`，而 `resp.body` 的静态类型只有 `InputStream`，得自己按块读到
  EOF（`ByteBuffer.write` + `body.read(chunk)`）；② 取响应头用 `resp.headers.getFirst("Content-Type")`
  （**没有 `get`**，写成 `get` 会得到「enum pattern is not matched」这种指向不明的报错）。
- **`stdx.net.http` 的第三个坑是 import，不是用法**（2026-10-13 实测，`examples/http-client`）：
  `TlsClientConfig` 在 `stdx.net.tls` 里、**不在 `net.http`**，少一行 `import stdx.net.tls.*` 报的是
  `undeclared identifier 'TlsClientConfig'`（看着像「这个类型不存在」，其实是没导包）；
  同理 **`Int64.parse` 要 `import std.convert.*`**（`parsable` 扩展），漏了同样是
  `undeclared identifier 'parse'`。两处都是「编译器指向的名字不是真原因」。
- **`HttpHeaders.add` 不收元组**：写 `hs.add((name, value))` 报 `parameters and arguments mismatch`
  （元组被当成两个实参）。先落成局部变量（`let pair = (name, value)`）再 `add(pair)`。
- **`match` 不能对 `Option<JsonValue>` 直接取 `.kind()`**：报
  `'kind' is not a member of enum 'Option<Class-JsonValue>'`——先 `match` 拆 `Some` / `None`，
  再对里面的值取 `kind()` / `asString()`。JSON 入参解析几乎处处要写这一跳。
- **`private let` 字段在构造之外不可赋值**：需要「解析时就地置位」的字段（如白名单里碰到 `*` 就置 `anyHost`）
  必须声明成 `private var`——仓颉的 `let` 字段构造后即只读，写入报 `variable 'x' is immutable`。
- 在**注解或注释**里写 MIME 通配（`text/*`、`image/*`）会撞本清单第一条的**块注释嵌套**——
  正文里要表达通配就换个写法（如 `text` 后面单写一个星号、或写 `text/…`），别让 `/*` 出现在注释文本里。
- **防盗链图片只能在宿主侧取**：图源常按 `Referer` 放行，失败形状是「**HTTP 200 + 0 字节**」——
  页面侧 `<img src>` 直连必然全灭，且**没有页面侧解法**（`Referrer-Policy` 只能减少 Referer、
  不能替换，何况内联页来源是 opaque）。办法是把地址交给一个宿主命令，由仓颉侧带正确 `Referer`
  取回再以 `data:` URL 交还（`examples/movie` 的 `movie:image`）；这类命令的参数是页面可控字符串，
  必须对地址做白名单，否则等于开放 SSRF。
- **`Int64(x * 10.0)` 这类浮点转整数会因越界抛异常**，不像 C 那样静默截断：一个已经脏掉的数
  （实测成绩文件里 `bestAccuracy` 涨到 `9630000000000000`）能把整条命令带走。凡是「算出来再落盘 / 回投」的量，
  **读与写必须同一口径**（同一字段一边按百分比、一边按分数，就会每轮 ×100 复利式发散），
  并且转换前**先夹范围**（`round1()` 现在有兜底），别指望异常会告诉你——见下一条。
- **命令 handler 抛异常要留一行 stderr，别让失败无声**（`3de499d` 已补，2026-10-07）：`IpcHub.runCommand`
  的两个 catch 此前**只回 `reject`、仓颉侧 stderr 一行都不打**（事件监听器那条路反而有 `event listener failed`，
  两者不对称），于是命令「没反应」时端到端日志里毫无凭证。现在分别打
  `[cj-tauri] command rejected (<命令>): <message>`（应用级拒绝）与 `command failed (<命令>): <异常>`
  （非预期失败），**前缀不同便于 `grep` 分流**，**回投给前端的报文一字未变**。
  注意教训仍在：**「日志里没有错误行」不等于「命令成功了」**——页面没接 `catch` 时失败只在页面上可见，
  示例/插件仍应把 reject 也回投（`report`），别把「没抓到 reject」读成「成功」
  （打字练习的 `score:save` 全废十几轮就是这么被抓到的）。
- **仓颉 `const` 只收「编译期常量表达式」：`const X: Array<String> = ["a","b"]` 编译不过**
  （`expressions of type 'Array' are not constant`；实测 2026-10-09，`serial:list` 那轮）。
  顶层不可变集合一律用 `let`（全局 `let` 就是不可变量）；真要编译期常量得上 `VArray<T, N>`（值数组）。
- **`#` 不是注释符**：Cangjie 的 `#` 是 raw string 前缀（`#"..."#`），拿它写行内注释会让词法分析器
  去找 raw string 的收尾，报的是 `error: expected '#' or '"' in raw string, found ' '`——**报错位置指向
  注释正文的第一个字符**，看着像语法错误、其实是注释写法错。行注释一律用 `//`。
  （实测 2026-10-08：脚手架 `cli/src/scaffold.cj` 想给生成出来的 `link-option` 附一句行内说明，
  被这条挡下；最后把说明写成源码里的 `//`、生成文件那一行只放开关——顺带保住了行数。）

**平台与工具链**

- Windows 脚本编码：`.bat` 由 cmd.exe 按 OEM 码页读取、`.ps1` 被 PowerShell 5.1 按 ANSI 读取——
  **保持纯 ASCII**，UTF-8 中文注释会吞掉后续行/导致解析崩溃（本项目已实际踩过）。
- **`.bat` 里别用 `find` 做计数或判断**：从 Git Bash 起 `cmd //c run.bat` 时，`PATH` 里 MSYS 的
  **GNU find** 排在 Windows `find.exe` 前面，`find /c /v ""` 会被它当成路径去遍历整个盘（实测把脚本
  挂到 300s 超时，输出满屏 `Permission denied`）。计数用 `findstr` + `for /f`，判断同样用 `findstr`。
- **`MSYS_NO_PATHCONV=1` 与 `cmd //c` 不能同时用（会出现「假成功」）**：`//c → /c` 这个改写本身就是 MSYS
  路径转换的一部分，被 `MSYS_NO_PATHCONV=1` 关掉之后 cmd 收到的是字面量 `//c`——它不认，于是只打印
  banner + 提示符就 EOF 退出，**批处理一行都没跑、退出码却是 0**（2026-10-07 实测：`run.bat selfcheck`
  的日志文件 mtime 没变、`grep PASS` 计到 0 才露馅）。二选一：`cmd //c xxx.bat`（靠 MSYS 改写）
  或 `MSYS_NO_PATHCONV=1 cmd.exe /c "xxx.bat"`。**判真假一律看副作用**（日志 mtime / 行数 / 断言计数），
  别只看退出码——退出码 0 在这里什么都不证明。
- **cmd.exe 不执行「没有后缀」的可执行文件**（2026-10-15 实测，`examples/leetcode-gui` 的判题）：
  仓颉 `cjc main.cj -o judge` 在 Windows 上产出的文件就叫 `judge`（**不补 `.exe`**），而 cmd 的命令
  解析只认「名字 + PATHEXT」——裸名 `judge` 与带路径的 `.\judge` **两种写法都报「不是内部或外部命令」**
  （与文件权限无关，那个 PE 拷到别处改名 `.exe` 立刻能跑）。表象极具误导性：编译成功、耗时照常报出，
  只有「执行产物」那一步空跑（stdout 0 字节），上层读成「程序没输出」→ 整条链路静默全灭，
  页面只显示「(程序输出，无判定行)」，stderr 里连一行失败都没有。修法是**产物名按平台分叉**
  （`@When` 一平台一份，Windows 带 `.exe`）并让**编译 `-o`、缓存路径、shell 调用行三处同源**，
  漏任一处即回归静默失败。**同类风险面**：任何「先自己编译、再执行产物」的链路（脚手架、插件、
  E2E 探针的自建二进制）——Windows 上都要认这个名字后缀，且失败要留 stderr 凭证。
- **随包分发双平台二进制的应用，候选表必须按平台分**（2026-10-21 实测，`examples/cjnote` 的 Windows 首验）：
  `vendor/cjh/bin/` 里 linux-x64（ELF）与 windows-x64（PE）两份并排躺着，而发现逻辑只问「这个文件打不打得开」
  ——`fileReadable` 在 Windows 上对 ELF 同样回 true，于是候选表里排在前面的 Linux 那份被选中。报错是
  `ProcessException: Created process failed … The system cannot find the file specified`：**`CreateProcess` 对
  不带扩展名的名字会自动补 `.exe`**，它去找的是 `linux-x64/cjh.exe`，与「文件真的不存在」长得一模一样，
  极易误判成权限 / 杀软 / 路径问题（与上一条「cmd.exe 不执行无后缀文件」同源）。落法：候选表按
  `@When[os == …]` 各列一份（平台差异只在条件编译里，§2），并**把实际选中的那个 bin 打进失败日志**——
  排查时正是 `启动 cjh web 失败（vendor/cjh/bin/linux-x64/cjh）：…` 这一行定死的，原先的日志只打异常。
  同族风险面：任何「按目录找现成二进制」的发现逻辑（`vendor/`、`.extract/`、插件自带的工具链）。
  顺带一条排查手法：**先写三个探针把「看起来像」的嫌疑排掉**（同一段代码分别在 console 子系统、
  GUI 子系统、`spawn` 轻量线程里各跑一次），三个都成功就说明问题不在调用形态、而在挑错了对象。
- Git Bash 下 `PATH` 里的 SDK 路径必须是 POSIX 形式（`/d/Program Files (x86)/Cangjie/...`）；
  盘符形式（`D:/...`）会被 MSYS 破坏，导致依赖仓颉运行时 DLL 的原生进程退出码 127 且无输出。
- **反过来：应用自己从 `HOME` 拼路径时，POSIX 形式会被原生 Win32 API 吃掉**（2026-10-21 实测，`cjnote`）。
  Git Bash 的 `HOME` 是 `/c/Users/yang`，原生 API 把它当「当前盘根目录下的 `c/Users/yang`」——
  `~/.cjh/settings.json` 于是**静默读不到**：配置页一片空白、自检里 `cjh:config returns model from
  settings.json` 恒红，而**同一份 exe 从 cmd 里起就正常**（79 PASS / 0 FAIL），清理 `HOME` 后也正常。
  判据：把环境变量摘掉再跑一次，结果反转 ⇒ 是启动环境而非代码/构建。修法是把 `/<盘符>/…` 与
  `/cygdrive/<盘符>/…` 规范成原生路径（`examples/cjnote/src/cjh_host.cj` 的 `nativePathOf`，
  平台差异走 `@When[os == "Windows"]`、非 Windows 分支恒等）。**凡是读 `HOME` / `XDG_*` 拼路径的
  宿主代码都该过这一层**——`$HOME` 在 Git Bash / MSYS 下与原生进程看到的不是同一个字符串。
- **`CANGJIE_STDX` 要指 stdx 的 `dynamic/stdx`（DLL 目录），不是 stdx 包根**：`cli/src/resolve.cj`
  把它**逐字**写进生成工程的 `[target.<triple>.bin-dependencies]`，给错了照样 `create` 成功——一直要到
  在那个新工程里 `cjpm build` 才炸：`root package '<名>' imports package 'stdx.encoding.json' in its
  source code, but the dependency info is missing`。CLI 自己的报错文案里就写着「指向 stdx 动态库目录」，
  按它给即可（实测 2026-10-08；本机是 `D:/cangjie-stdx/windows_x86_64_cjnative/dynamic/stdx`）。
- **框架的 `${CANGJIE_STDX}` 靠进程环境变量展开：打包脚本不会替你设，漏了就报成「框架缺依赖」**
  （2026-10-16 实测）：仓库根 `cjpm.toml` 的 `bin-dependencies` 写 `${CANGJIE_STDX}`，而
  `scripts/pack-win-single.sh` 是在 `dist-single/work/` 里自建副本编译——它把**应用副本**的 stdx 路径
  写死成绝对路径，但**框架包**（`path = ../..` 指回仓库根）仍按自己的 `cjpm.toml` 展开那个变量。
  没导出时的报错是 `root package 'cjTauri' imports package 'stdx.encoding.json' in its source code,
  but the dependency info is missing`——指向框架、看着像「框架忘了声明依赖」，其实是环境变量没进进程。
  跑打包器前先 `export CANGJIE_STDX=<stdx>/<三元组>/dynamic/stdx`（POSIX 形式，MSYS 负责转换）。
- **`cjpm build success` 不等于产物存在：增量缓存会跳过链接**（2026-10-15 实测，`examples/leetcode-gui`）：
  上一轮构建被中断过（可执行文件被占用 / 被删）之后，`target/release/incremental-cache.json` 仍认为它是最新的，
  于是 `cjpm build` 只重编包对象、**不重新链接**却照报 `build success`——`target/release/bin/` 里只剩 `*.cjo`，
  启动时看到的却是 `拒绝访问。`（cmd）或 `No such file or directory`（bash，exit 127），极容易误判成权限 / 杀软问题。
  修法：`rm -f target/release/incremental-cache.json target/release/bin/*.cjo` 再 `cjpm build`。
  **判据看产物**（`ls -l target/release/bin/`），别只看 cjpm 的退出码与那行 success。
- **链接期 `undefined reference to cjTauri.plugins.<插件>` 先 `cjpm clean`，别急着补 `-l`**（2026-10-16 实测，
  `examples/ai-chat` 接 dialog 插件）：应用**新 import 一个插件**后，增量缓存里留着的**旧链接列表**不会带上
  新的插件库，报的是 `undefined reference to cjTauri.plugins.dialog:DialogPlugin.ti`——看着像「`cjpm.toml`
  少补一条 `-l`」。同一条构建 `cjpm clean` 之后即链上、`cjpm.toml` **一行都不用改**（`cjpm clean` 一律安全：
  `libcjtbridge.so` 在 `native/` 根、不在 `target/` 里，不受影响）。判据是「clean 后仍失败才算真缺」——
  否则会照着别的示例（`ai-chat` 为 fs 插件补过的那行）抄一条**可能并不需要**的链接选项，把真因掩盖掉。
- 换行符：`.sh` 必须 LF（否则 shebang 失效），`.bat` CRLF；以 `.gitattributes` 为准。
- **Windows 串口的读预算要「按每次调用」下发给驱动，否则 `timeoutMs` 形同虚设**（2026-10-16 实测，
  `native/platforms/windows/bridge_win.c`）：`SetCommTimeouts` 的 `ReadIntervalTimeout=MAXDWORD` +
  两个 total 全 0 是**「立刻交回已有字节」**语义——缓冲里没数据时驱动当场把请求完成成 0 字节、
  `ReadFile` 返回 TRUE，于是 C 桥里「等 OVERLAPPED 事件最多 timeout_ms」那条分支**根本进不去**
  （按同参数写的小 C 程序复现：预算 1000ms 的读 0ms 就交回 `got=0`）。表象是 `serial:read` 只返回
  「恰好已经躺在缓冲里」的字节，前端只能靠高频轮询碰运气；示例自检里串口那步读回 0 字节，
  `rx text=` 与 `close` 两条明细凭空消失（10/10 而不是 11/11）。修法：每次读之前用
  `SetCommTimeouts` 下发 `ReadIntervalTimeout=0` + `ReadTotalTimeoutConstant=预算`（有首字节立刻
  完成、没有就等满预算，与 Linux 的 `poll` 同口径），**只有预算为 0 才用「立即返回」那套**。
  判据：探针 10/10 → 11/11（串口 `read` 拿回 `hex=636a2d6c696e6b2d70696e67`）。
  教训是通用的：凡「宿主 API 声称按预算等」的实现，都别信「打开时设过一次就够了」——
  预算类语义要逐次随调用下发，且验的时候要**用一个真的没数据的时间窗**去打它。
- **拉取「改了 C 桥导出」的提交后，先重建桥再跑测试/构建**：`native/libcjtbridge.so`（Windows 侧
  `libcjtbridge.dll`）是**本地产物、不入库**。菜单能力位那次 C 桥加了 5 个 `cj_bridge_*` 导出，
  没重建桥就直接 `cjpm test`/`cjpm build` 会在**链接期**炸出一串
  `undefined reference to cj_bridge_set_menu…`（实测 2026-10-05：漏 5 个符号、88 个错误，不是代码错）。
  重建：Linux `bash native/build_linux.sh`、Windows `native\build_win.bat`；
  数导出 `nm -D --defined-only native/libcjtbridge.so | grep -c cj_bridge_`（0.7.0 为 22 个）。
- WebView2 版本规则：**SDK 不得高于本机 Runtime**（本机 Runtime 122.0.2365.106 → 用 SDK 1.0.2365.46）；
  `native/build_win.bat` 会同步同代的 `WebView2Loader.dll`（x64）到 `native/webview2/`。
- **Windows 宿主：页面的视口尺寸必须每帧自检，不能只等 `resize` 事件**——WebView2 建 WebView 时视口
  还是**临时尺寸**（实测 2026-10-07：初始化读到 961x1032，随后窗口才定到 1164x741），而那次变化**没有
  `resize` 事件送到页面**：只按 `resize` 更新画布（或只调一次 `renderer.setSize`）的页面会停在旧尺寸，
  3D 场景整幅走样。做法是把「`innerWidth/Height` 与上次应用值比一次」放进 `requestAnimationFrame` 循环
  （两次比较而已，顺带覆盖 DPI / 缩放变化），并留一条「画布 == 视口」的断言——本坑就是
  `examples/typing-poem` 的自检抓出来的（`ui/index.html` 的 `fitViewport()`）。
- **便携包（免 SDK 的 exe 包）必须自带两个「按名字 LoadLibrary」的组件**：`WebView2Loader.dll`（C 桥）
  与 `libssl-3-x64.dll` / `libcrypto-3-x64.dll`（仓颉运行时的 TLS 加载器，**SDK 与 stdx 都不带**）。
  这两类依赖**不在 PE 导入表里**，所以「递归解析导入表收 DLL」会漏掉——漏 OpenSSL 的症状极像网络问题
  （窗口照起、页面照加载、`http://` 照 200，**只有 https 全灭**：
  `TlsException: Can not load openssl library or function CRYPTO_get_ex_new_index.`）。
  打包用 `scripts/pack-win.sh`（已覆盖这两个），别手工抄 DLL 清单（实测 2026-10-06：`examples/movie`
  的便携包第一版就是这么挂的）。
- **静态库里的资源对象不会被链接器取出来：`.rsrc` 节消失、体积也不涨**（2026-10-21 实测，cjnote 单文件）：
  `pack_assets.o`（windres 产出的资源对象）没有任何符号被引用，`ar rcs` 进 `libcjtbridge.a` 之后
  链接器按需提取、根本不会碰它——产物照旧 `build success`、`objdump -h` 里连 `.rsrc` 一节都没有，
  表象是「资源明明嵌了却没生效」（运行期找不到 cjh，页面照旧「AI 后端未就绪」）。判据就是**看节表**：
  `objdump -h app.exe | grep -c rsrc` 必须 ≥ 1 且尺寸对得上（cjnote 是 `0x162df20` ≈ 22.2 MB，
  未 strip 产物 56.3 MB → strip 后 32.6 MB）。落法是**把 .o 当链接输入直接给 ld.lld**——打包器生成
  `link-option` 时拼上它的盘符路径，别指望静态库替它担保。
- **`llvm-rc` 不认字符串资源名，只能用数字 ID**：rc 里写 `"cjh.exe" RCDATA "…"` 报
  `llvm-rc: Error parsing file: expected int or identifier, got "cjh.exe"`（windres 的后端就是 llvm-rc）。
  于是「资源名即文件名」这条路走不通——桥改由打包器生成的 `pack_assets_map.h`（ID → 文件名）驱动，
  编桥时带 `-DCJ_PACK_ASSETS_EMBEDDED` 才包含它；桥因此依旧不认识应用的任何文件名，打包器放什么就释放什么。
  释放目录由应用给（cjnote 是 `%LOCALAPPDATA%\cjnote\runtime`，**不放 `%TEMP%`**：会被清理，等于每次重解几十 MB）。
- **单文件包（`scripts/pack-win-single.sh`）里 loader 必须内嵌释放，不能静态链**：SDK 的
  `WebView2LoaderStatic.lib` 是 MSVC 编的，要 `/GS` 的 `__security_cookie` 与 C++ 运行时符号
  （`?nothrow@std@@`、`_Init_thread_epoch` …），mingw 实测链接失败
  （`ld.lld: undefined symbol: __security_cookie`）。做法是把它当**资源**：DLL 字节用 `od` 生成 C 头、
  随静态桥一起编进 exe（`-DCJ_EMBED_WEBVIEW2_LOADER` + `native/bridge_win.c` 的 `unpack_embedded_loader`），
  首次运行释放到 `%TEMP%\cj-tauri-loader\` 再按绝对路径 `LoadLibraryW`（幂等：比大小；失败把错在哪一步打进 stderr）。
  取证判据：未修前那一轮 stderr 只有 `WebView2Loader.dll not found`，修好后同一份 exe 自检 57 passed / 0 failed。
- **单文件包只要碰 https，链接期还必须显式加 `-lcrypt32`**：`stdx.net.tls` 读根证书走 **Windows 证书库**
  （`CertOpenSystemStoreA` / `CertEnumCertificatesInStore` / `CertCloseStore` 都在 `crypt32.dll`），
  静态链接的 exe 不带它就在链接期炸一串 `undefined symbol: __declspec(dllimport) CertOpenSystemStoreA`
  （实测 2026-10-08：`examples/music` 的封面是 https，而 typing-poem 不碰 TLS，所以这条直到打音乐示例才暴露）。
  `scripts/pack-win-single.sh` 的 `link-option` 已加上；用不到它的示例多链一个系统库无副作用——
  **判据看导入表**（`objdump -p *.exe` 里 `DLL Name` 只该出现系统 DLL），不是看链接命令里写了什么。
- **单文件产物默认是 console 子系统：双击会弹一个 DOS 黑窗口，`link-option` 必须写 `--subsystem=windows`**：
  mingw/Cangjie 默认按 console 生成，Windows 见到 console 程序就给它配一个控制台（实测 2026-10-08：
  `music.exe` 交付后用户第一条反馈就是它）。`scripts/pack-win-single.sh` 已加，并在脚本末尾**事后复核**
  （`objdump -p` 里的 `Subsystem` 必须是 `00000002`，否则 `die`），免得被改回去只靠人眼发现。
  cjc 的 `--link-options` 是**直接交给 ld.lld** 的（不是交给 gcc 驱动），所以只能用链接器的写法：
  gcc 方言 `-mwindows` 会被当面拒（`lld: error: unknown parameter: -mwindows`），取值也只有 GNU 那套
  （`console` / `windows` / `native` / `posix`——写 `gui` 报 `ld.lld: error: unknown subsystem: gui`）。
  子系统只管「分不分配控制台」，**不碰日志链路**：从终端带重定向启动时 stderr 照旧落到文件
  （实测**不显式重定向也能抓到**：未重定向跑 `CJ_MUSIC_SELFCHECK=1 music.exe`，228 行 stderr 照落），
  实机取证与无人值守自检一行都不用改；代价是双击时看不到 stderr（要现场日志就 `app.exe 2> log.txt`）。
  目录式便携包 `scripts/pack-win.sh` 走各示例自己的 `cjpm.toml`：**13 个示例的 mingw `link-option` 都已带上
  同一个开关**（行内注释指向本条；打包器临时生成的 `dist-single/work/app` 副本同样带着它，但不入库）、
  另外 **`cj-tauri create` 生成的工程也带它**：`cli/src/scaffold.cj` 的 `buildTargetSection` 在 Windows 分支
  （`hostIsWindows()`）追加同一个开关（Linux 分支一行不动）——否则用户拿到的第一份产物照样弹黑窗，
  产物同样是 GUI。动手时要认准目标段——**Linux 段那串 `-lwebkit2gtk-4.1 …` 不能加**（与子系统无关，
  加了也会被链接器拒）；数「改了几个」时记得把 `dist-single/work/` 下的副本排除掉，否则会多算 2 个。
- **单文件包 strip 悄悄失败，exe 卡在 28MB**（2026-10-11 实测）：llvm-mingw 的 `strip.exe` 是包装器，
  实际调用同目录的 `llvm-strip`——有的发行包里这个真身缺失（本机 `C:\tool\llvm-mingw-*` 报
  `llvm-strip: No such file or directory`），而 `pack-win-single.sh` 里的 `strip 2>/dev/null` 把真实报错
  吞掉，表象成了「strip 对这个 exe 无效」，产物一直停在未裁剪的 ~29MB（music/typing-poem 的 ~6MB
  是早前在别的机器上 strip 成功的）。判据：`strip --version` 报 `llvm-strip: No such file or directory`
  即中招。修法：脚本已加回退——strip 失败就用 SDK 自带的
  `$CANGJIE_HOME/third_party/llvm/bin/llvm-objcopy.exe --strip-all`（同为 llvm 工具链，对 PE 等效），
  实测 29.3MB → 5.9MB。**教训：`2>/dev/null` 包住失败步骤时，失败会换一个更贵的样子出现（体积、
  产物异常），排查先去裸跑一遍那条命令看真实报错。**
- **新示例要进单文件包，先备两样**：`src/packed_assets.cj` 空存根（`public let PACKED_*_B64: String = ""`，
  **声明了哪几个常量打包器就生成哪几个**——没有 three.js 就不写那一条）与 `src/packed_resources.cj`
  （`decodeBase64` / `splitBy` / `textOrFile`），再把页面与能力清单的取用改成「内嵌优先、否则读盘」；
  最快是照 `examples/music/src/` 那两份抄。打包器会逐条 `die` 提示缺哪样。
- **判「这个 DLL 是不是系统的」先确认它在 `System32` 里，再决定加白名单还是报警**（2026-10-13 实测）：
  写分发实测脚本时按白名单分类 PE 导入表，`dbghelp.dll`（Windows 自带，崩溃栈回溯用）没进白名单，
  于是**四份单文件 exe 全被报成「非系统 DLL = 1」**——数字看着像把「免安装」当场推翻，实则是白名单漏项。
  教训与「过滤器本身会骗人」同源：**分类器的输出先拿一个已知结论校准一遍，再拿去判断新对象**
  （正确顺序是「先确认这台机器上的 `dbghelp.dll` 就是 System32 那一个，再决定加白」）。
- **统计「随包体积」务必先按真实路径去重**：`/lib` 与 `/usr/lib` 在多数发行版是同一份（合并 usr / 软链），
  同一个 `libssl.so.3` 被算两遍，体积凭空翻倍（2026-10-13 实测：报出来 12.0 MB，实际 6.0 MB）。
  凡是对外报体积 / 去重清单，都要 `readlink -f` 之后再判重。**另一类最容易漏的是「按名字加载」的组件**
  （导入表与 `ldd` 都看不见它们）：Windows 侧 `WebView2Loader.dll` 内嵌在 exe、`libssl-3-x64.dll` /
  `libcrypto-3-x64.dll` 需随包，Linux 侧 openssl 反而由**系统包**提供——两边不一样，得当两件事说。
- **mingw 的 `swprintf` 里 `%s` 收的是 `char*` 而不是 `wchar_t*`**（默认方言走 MSVCRT 语义）：
  拿它拼宽字符路径得到的是垃圾，而且**不报错**——单文件包第一版就只留了一句
  `failed to unpack embedded WebView2Loader.dll`，毫无线索。C 桥里拼宽字符串一律用
  `lstrcpyW` / `lstrcatW`（`windows.h` 自带，不碰 CRT 方言）。
- **cjpm 的 `path-option` 写 Windows 路径别用反斜杠**：TOML 基本字符串里 `\c` 是非法转义，
  `cjpm build` 直接以 `errLexEscape` 失败（`D:\cangjie-stdx\...` 得写成 `D:\\cangjie-stdx\\...`）。
  生成 toml 的脚本用正斜杠（`D:/cangjie-stdx/...`）：cjpm 与 gcc 都认，省掉这层转义。
- **不带引号的 heredoc 里，注释正文的反引号必须写成 `\``**：`scripts/pack-win-single.sh` 生成 `cjpm.toml`
  那段要展开 `$PKG_NAME` / `$BRIDGE_ARG`，所以定界符不能加引号，而反引号在 bash 里是**命令替换**——
  注释会被当命令执行（实测 2026-10-13 打 `serial-waveform` 时刷出一串 `-lcrypt32: command not found`，
  不致命，但等于把注释变成了执行，生成的 toml 注释还缺字）。要么转义，要么注释里别写反引号。
- **`native/` 按平台重整后，凡在别处编桥的脚本都要显式给 `-I<core 目录>`**：`bridge_win.c` 在
  `platforms/windows/`、`bridge_core.h` 在 `core/`，`#include "bridge_core.h"` 的同目录回落够不着，
  报的是 `bridge_core.h file not found`（`native/build_win.bat` 里的 `-Icore` 是同一件事；
  `pack-win-single.sh` 漏了这条，直到 2026-10-13 打包 serial-waveform 才暴露）。
- Linux 宿主：GTK/WebKit 的全部调用必须在 C 桥创建的原生 pthread 内执行——
  仓颉 M:N 轻量线程的堆上协程栈会被 JSC 的栈边界校验 abort。
- Linux 宿主：桥接脚本必须**在 document start 注入**（`WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START`）——
  用文档末尾注入会晚于发行态单文件里内联的 `<script type="module">`，前端读 `window.__CJ_TAURI__` 拿到
  `undefined`（Windows 的 `AddScriptToExecuteOnDocumentCreated` 同样是「页面脚本执行前」，两平台已对齐）。
  即便如此，应用前端也不要在模块作用域直接读桥：初始化时**等桥出现**（模板里的 `waitForBridge`）。
- Linux 上仓颉运行时的动态库**不查 PATH**：启动器只设 PATH 会让 CLI 以「找不到 libcangjie-runtime.so」
  直接退出（Git Bash 下表现为退出码 127 且无输出），必须同时把 `runtime/lib/<platform>` 设进 `LD_LIBRARY_PATH`。
- `cj-tauri dev` 的 dev server **不要用 `setsid` 另开会话**：那样它会脱离终端的进程组，
  终端 Ctrl-C 只杀掉 CLI、dev server 漏跑（实测残留 vite + esbuild）。正确做法是让它留在 CLI 的
  进程组里（Ctrl-C 能一并带走），收尾时按「先子后父」递归 kill 整棵树
  （`npm → sh -c vite → node(vite) → esbuild`）。
- Windows 宿主：COM 回调对象的 `AddRef` 必须返回 1 并显式 `AddRef`，否则出现 `hr=0x8007139F` 崩溃。
- 原生对话框（`dialog` 插件）：两平台的 JS→native 回调**本来就跑在宿主 UI 线程上**（Linux = GTK 线程，
  Windows = 跑 WebView2 消息循环的那个线程），所以「把弹窗投递到 UI 线程 + 阻塞等结果」会自锁——
  现象是日志停在 `[cj-bridge] dialog: kind=…`、对话框永不出现（第一次实机就是如此）。C 桥按调用线程分流：
  已在 UI 线程就直接弹，在别的线程才投递 + 等待；新增同类宿主能力（菜单、文件拖放等）照此办理。
- Windows 宿主**菜单栏必须用 `CreateMenu()` 建**：`SetMenu` 只接受「菜单栏」句柄，把 `CreatePopupMenu()`
  的 popup 句柄塞进去会以 `ERROR_INVALID_PARAMETER(87)` **静默失败**——`SetMenu` 返回 FALSE、平台日志
  照打 `menu applied`、窗口上却一直没有菜单（`GetMenu` 恒为 NULL；实机第一轮就是这么被坑的，排查中还
  因为过滤词带空格把失败行滤没了）。子菜单才用 popup。凡是「设了但没生效」的宿主调用，一律按这个模板
  收口：**检查 API 返回值 + 事后查询复核**打进同一行日志（`menu applied: … GetMenu=0x…`），
  否则日志只会说「我调过了」，等于没有凭证。
- 诊断日志的**过滤器本身也会骗人**：`findstr /C:"menu "`（带空格）一条都匹配不上
  `menu: … SetMenu failed: 87`，于是「没有失败日志」被误读成「没失败」。按前缀取证据时用 `[cj-bridge]`
  这样的**整行前缀**，不要用会在正文里撞词的中缀；改日志格式时一并核对断言用的 needle。
  **needle 也别跨字段**：`PUBLISH rx topic=x qos=1 payload=y` 看着像整行前缀，实际中间还夹着
  `retain=/dup=/pid=/bytes=`，字面量匹配当场落空，表象是「对端没收到报文」（2026-10-13 MQTT 轮实测，
  第一遍 23/25 全栽在这一条）——needle 截在字段边界上，载荷另立一条断言。
- 多窗口下**任何「静态单槽回调」都会丢事件 / 串台**：C 侧只有一个函数指针入口（每个宿主注册的是**同一个**
  函数指针，实机日志里两窗的 `on_destroy=` 同址可证），仓颉侧若把「本窗回调」写进同一个静态变量，后装配的
  窗口就覆盖先装配的——先装配的窗口从此收不到自己的事件（`HostGlobals.onShell` 最早实测如此）。**判据是
  「回调有没有自带身份」**：报文自带 label 的消息回调可以用单槽，其余（销毁 / shell 事件 / 对话框结果）
  一律走「句柄 → 回调」路由表（`HostRoute` / `registerHostRoute`；同一句柄重复登记＝替换而非叠加）。
  对应的 C 侧签名要求：`cj_on_shell_fn` / `cj_on_destroy_fn` / `cj_on_dialog_fn` 首参都是 `struct cj_host *`
  ——**新增宿主回调一律带头参**，别再造一个不带身份的单槽（2026-10-07 已把销毁与对话框结果两处补齐）。
- **PowerShell 的错误报告按「父进程的 OEM 码页」输出，会被 GBK 变成 findstr 抓不到的字节**（2026-10-10 实测）：
  `$OutputEncoding` / `[Console]::OutputEncoding` 只管脚本**自己** `Write-Output` 的行；
  脚本抛终止性错误时那份 `所在位置 …` 报告由**外层宿主**在我们设置失效之后打印，仍是 GBK——
  `%TEMP%\*.log` 里就是「Unicode 格式」警告 + 乱码，`findstr` 计数为 0，于是「没有这条日志」被误读成「没发生」。
  修法：起 PowerShell 的那层先 `chcp 65001`（`cmd /c "chcp 65001 >nul && powershell …"`），整份日志就是 ASCII；
  **脚本自身保持纯 ASCII，且别拿错误行当断言 needle**（能提前 catch 的就 catch 后自己 `Write-Output` 一行 ASCII）。
- **`start` 的重定向抓不到子窗输出，必须放进内层 `cmd /c` 字符串**（2026-10-10 实测）：
  `start "t" /min cmd /c "… > "%LOG%" 2>&1"` 里，那个 `>` 若写在 `start` 这一层，日志文件是 **0 字节**、
  命令照跑不报错（看着像「对端没输出」）；写进内层字符串才有内容。判断照旧看**副作用**（日志行数），不看退出码。
- **`.bat` 里 `timeout /t N` 会被 MSYS 的 GNU `timeout` 抢走**（2026-10-10 实测：`timeout: invalid time interval '/t'`）——
  与 `find` 那条同源（PATH 里 MSYS 的 Coreutils 排在 Windows 同名命令前面）。脚本里等几秒一律用
  `ping -n N 127.0.0.1 >nul`，别用 `timeout`。
- **`if (…)` 块内的 `echo` 正文不能含英文括号**（2026-10-10 实测）：`echo … wrote to the wire (peer-side proof), …`
  里的 `)` 被 cmd 当成 if 块的收尾，后面整段执行流错位，报的是
  `此时不应有 read。`这行与括号八竿子打不着的错（且退出码非 0，PASS 文案永远打不出来）。要写括号就 `^(` `^)` 转义，或换措辞。
- 执行子进程（`shell` 插件）：一律 **argv 直传**（`launch` / `executeWithOutput` 收参数数组），
  不要为省事拼 `bash -c "<一整串命令>"`——那等于把页面可控的字符串塞进 shell 解析，自己开后门。
  这类调用本身仍是**同步阻塞**的：它跑在命令 worker 线程上（命令分发已异步，见 §2），所以不再冻窗口，
  但没有流式输出、也没有超时 / 取消，别在命令里等长驻 / 交互式进程。
- Linux 宿主收尾**不要用 `pthread_join` 等宿主线程**：宿主线退出前要进仓颉运行时（窗口销毁回调），
  而仓颉线程阻塞在 join 上会与运行时的「停处理器」握手互等（实测约 1/6 概率整进程挂死，栈是
  `cj_plat_fini → pthread_join` ↔ `CJ_CJThreadMexit → CJ_ProcessorStopWithLastCheck`）。正确做法是
  `pthread_detach` + 宿主线自己置「跑完」标记 + 有界轮询等待；等不到就保留平台状态——`cj_plat_fini`
  返回 0 时 `cj_bridge_destroy` **不回收句柄**（进程随即退出，泄漏一次状态远比死锁安全）。
- Linux 宿主**销毁 WebKit 窗口必须留在 `gtk_main` 之外**（`quit` 只 `gtk_main_quit()`，窗口交给主循环
  返回后的收尾销毁）：在主循环内 `gtk_widget_destroy` 会让 libwebkit2gtk 的**退出期析构**在自己的
  `g_object_unref` 里 abort（退出码 134，栈 `StartMainTask → exit → __run_exit_handlers → libwebkit2gtk … → abort`，
  与框架代码无关，gdb 里一眼可见）。`onDestroy` 仍由 `destroy` 信号触发一次，收尾里那次是幂等兜底。
- 诊断输出一律走 stderr：仓颉 `println` 的 stdout 有缓冲，进程被强杀时日志会丢；
  桥的 stderr 每行即时落盘，端到端验证以它为准。
- **GUI 子系统 + 控制台子进程 = 桌面上那个黑窗口**（2026-10-21 实测，`examples/cjnote` 拉起 cjh）：
  应用产物是 `--subsystem=windows`、**没有控制台**，用 `std.process.launch` 起一个控制台子系统的程序，
  Windows 会给**子进程**单独配一个控制台窗口——用户看到的是「点一下按钮，旁边蹦出一个黑窗口」，
  而 stderr 里一行错误都没有（进程起得好好的，只是多了一扇窗）。`launch` 的签名没有创建标志可传，
  所以只能走框架的 `launchHidden()`（`CreateProcessW` + `DETACHED_PROCESS`），并且**顺手把三个标准句柄
  显式指到 NUL**：没有控制台时它们是无效句柄，控制台程序一 println（cjh 启动就打 banner）可能直接死在
  自己的控制台上。`SW_HIDE` 不算解法——它只是「先建再藏」，窗口会先闪一下。
  **判据要 A/B 两个读数**：① 数可见的 `ConsoleWindowClass` 窗口（同一份二进制，只差创建标志：
  不给标志 1 → 2 个，新增那只的 pid 就是子进程）；② `Get-Process <名> | MainWindowHandle`
  （隐藏那轮 = 0、弹出那轮非 0）。**先拿一个有窗口的进程（应用自己）校准一遍**，否则「读数为 0」
  完全可能是这个指标本来就恒 0——与「过滤器本身也会骗人」同族。
- **平台没有 C 桥时，「不带 `@When` 的核心包 `foreign func`」会留成未解析符号，表现是应用一启动就没**
  （2026-10-18 鸿蒙 ArkWeb 首轮实测：白屏三轮、误判成「静态包硬链进动态根包导致 init 卡死」）：
  `src/log_bridge.cj` 原本**故意**不写 `@When`（桌面两平台同名导出、实现只有 `native/core/bridge_core.c` 一份），
  可鸿蒙侧**没有 C 桥产物**（`native/platforms/harmonyos/` 目前只有契约），于是 `cj_bridge_set_log_file` /
  `cj_bridge_log_file` / `cj_bridge_log_write` 在模块里是 `U`，模块加载期直接 **SIGSEGV**
  （`exit with signal:11`，地址看着像野指针而非空指针）。表象极具误导性：窗口白屏或应用秒退，
  **hilog 里连 `AbilityStage.onCreate` 一行都没有**，而 Cangjie 运行时自己的 `CANGJIE-RUNTIME` 行照常打——
  很容易往「ability 生命周期卡死」「运行时模块 init 死锁」「stdx 重复链接」这些方向排查，
  这条路当晚白走了好几轮。
  **判据**：`llvm-nm -D --undefined-only <模块.so> | grep cj_bridge` 必须是 **0 行**——它比任何运行期日志都直接。
  落法是给 FFI 声明与薄包装**同一口径的 `@When[env != "ohos"]`**，并为无桥平台写一份如实降级
  （`enableLogFile` 返回 false 且留一行 stderr、`currentLogFilePath` 回空串、`writeLogLine` 返回 false），
  **不要**为了让它编过而假装成功。改完判据：同一命令 0 行 + `MyAbilityStage onCreated` 重新出现。
  同族风险面：`src/clipboard_bridge.cj` 与任何「谁调用谁包内」的核心 FFI，新增时先问「这个平台有桥吗」。
  完整过程（判据命令、被数据否定的三条弯路、真机 hilog 取证、hvigor 与签名断点）见
  `docs/鸿蒙ArkWeb接入踩坑.md`——本文只留判据，过程不在 §4 展开。
- **鸿蒙侧的三条硬约束（2026-10-19 真机闭环，改这块之前先看）**：
  ① **框架包不得引用 ArkUI**——`@Component` / `Web` / `javaScriptProxy` 一律留在应用侧，
  框架只导出 ArkUI-free 的桥接函数（`src/arkweb_proxy.cj`）。框架包作为独立编译单元引用
  `kit.ArkUI` 时，合并进应用动态库后 `_CGP7cjTaurifiHv` 初始化链里的 `bl _CGP9kit.ArkUIiiHv@plt`
  会跳到坏地址 → **启动即 SIGSEGV**（表象是白屏或秒退）。
  ② **`javaScriptProxy` 的返回值传不回页面**——把 `poll` 换成无条件返回固定串，页面拿到的仍是 `null`
  （参数能进、`methodList` 枚举也对）。所以「页面拉、原生答」的同步取数模型在鸿蒙侧**不成立**：
  回投一律**由原生推**——页面 `setInterval` 发 `{"type":"pull"}` 心跳 → 宿主 `acceptPageMessage`
  识别后直接 `return`（不进 IPC hub）→ 应用侧 proxy 回调（本来就在 UI 线程）取
  `takePendingScripts()` 用 `controller.runJavaScript` 推出去。
  ③ **组件的 `build()` 读不到「宿主落盘后的页面地址」**（那时组件自己的字段还是空串），会在
  「不建 `Web` → `onPageBegin` 不来 → 地址又只在它里面同步」上**死锁白屏**；在 `aboutToAppear()`
  里从宿主同步进 `@State`（`@State` 不接受 `private`）。判据：hilog 有 `BindWebTagToWebInstance`
  却一条 `page begin` 都没有、截图纯白。
  另：**`eprintln` 在设备上不进 hilog**（框架 stderr 全不可见），鸿蒙侧诊断要写 hilog；
  hilog 缓冲会滚掉启动瞬间的行，取证必须**流式**（先起 `hdc shell hilog > f` 再启动应用）。
  过程与可复现命令见 `docs/鸿蒙ArkWeb接入踩坑.md` §8.1。
  ④ **鸿蒙侧「改了没变化」先怀疑产物，别改代码**：hvigor 的 `CompileCangjie` 与框架侧 cjpm
  **各有一份增量缓存**，只清一边时旧 `libcjTauri.so` 会被喂回来，对照实验当场失真（实测：
  残留旧包时崩溃链仍指向已移出的框架包）。重编前 `rm -rf entry/build` + 清框架 `target/`，
  判据看**产物**（`.so` 尺寸 / `llvm-nm` 里 `cjTauri` 符号数，健康值 330），不看 `build success`。
  同族的两个哑巴失败：`cjpm.exe` 退出码 `0xC0000139` = 桌面 SDK 与鸿蒙 `build-tools` 的运行时冲突
  （摘掉桌面 SDK 并**重启 hvigor daemon**）；`aa start` 的 `-a` 要用 `module.json5` 的 `EntryAbility`，
  写成仓颉类名 `MainAbility` 返回 `10104001`。清单见 `docs/鸿蒙ArkWeb接入踩坑.md` §10。
- **鸿蒙侧给 `@Component` 传参只有一种写法：`@Prop` 成员 + 调用点纯调用**（2026-10-19 多窗口实测，
  两种写法报的都是同一句、看着都像「参数写错」）：
  ① 成员写成普通 `var x: String = "…"` 时，宏把它展开成 `ObservedProperty<String>` 形参，外面传
  字符串报 `missing arguments for parameter list '(Option<CustomView>, Option<ObservedProperty<String>>, …)'`；
  ② 改成 `@Prop var x: String` 后报同一句——真因是**调用点挂了链式修饰**
  （`MyComp(x: "y").height(50.percent)`）：宏展开时补不上 `__gen_parent`，同样报「expected 4 arguments」。
  落法是**调用点保持纯调用**，尺寸交给外层容器（`Column() { MyComp(x: "y") }.height(50.percent)`）。
- **鸿蒙侧每个窗口都要各自等宿主登记**（多窗口白屏）：`onWindowStageCreate` 只等默认 label 时，
  第二扇窗的组件 `aboutToAppear` 读到的 `currentUrl()` 仍是空串 → 永不建 `Web` → 白屏死锁，
  与单窗口那条是同一条链。判据：hilog 里 `host pageUrl label=<label>` 与 `page begin label=<label>`
  **每个 label 各一行**（页面文件名是 `cj-tauri-<label>.html`，两窗不会共用一份）。
- **多窗口「不串台」的判据是「原生归属 == 页面自认」逐条成立**：页面报一条自带 `me`（它读到的
  `__CJ_TAURI_LABEL__`）的命令，原生把报文里的 `window`（`IpcContext.window`）打进**同一行** hilog——
  `window == me` 全部成立才算路由正确；定向投递必须**发给对面窗口**（发给自己在错误实现下也能通过，
  等于没测）。
- **鸿蒙侧「页面触发的弹窗」只能用声明式 overlay，别调命令式弹窗 API**（2026-10-20 真机四轮对照）：
  `UIContext.showAlertDialog` 与 `getPromptAction().showDialog`（**含 `workerthread: true`**）在
  `javaScriptProxy` 的 `post` 回调**同步栈**上调用时一律**静默丢弃**——不抛异常、立即返回、窗口不画、
  回调不来；同一个 `showDialog` 从原生 `Button.onClick` 调却正常弹出，且两者 tid 相同（都是 UI 主线程，
  实测 `6549`），所以**不是线程问题**；把调用 `spawn` 到工作线程也不能救（`returned` 从 spawn 块内打出，
  证明 spawn 确实执行了）。落法：组件加 `@State`（**不能与 `private` 同用**，宏会拒），proxy 回调里只
  **置状态**，`build()` 里按状态把 overlay 渲染成根 `Stack` 的最后一个子节点
  （`.width(100.percent).height(100.percent).justifyContent(FlexAlign.Center)`），按钮回填走**普通
  `onClick`**（先 `dialogActive = false` 再回填，避免连点压在同一个 id 上）。
  **判据是四段齐全**：`dialog take` → `dialog present` → `declarative dialog answer` → 页面回执
  `confirmed=true`；只有 `present` 那段是「画出来了但没回填」，别混为一谈。
  两处 API 形状坑：`padding(top: n)` 这类**四参形式没有默认值**（用单参 + `Column(space:)` 拉开间距）；
  `Text` / `Row` / `Column` / `Button` 在 `.cj.d` 里是**按 class 声明**的，查签名要 grep `public init(`，
  grep `func Text(` 什么都得不到。框架侧 `hostCapabilities()` 的对话框位**仍报 0**——通的是应用侧 overlay，
  不是宿主能力，别据此改能力位。证据与命令见 `docs/鸿蒙ArkWeb接入踩坑.md` §10.11。
- **多窗口下「命令里拿宿主」必须按 `ipc.window` 解析，固定一个宿主就是串台**（2026-10-20 真机实测，
  `dialog` 插件）：插件在 `setup()` 里只记 `app.webviewHost()`（默认窗那一个）时，**所有窗**的
  `dialog:*` 都排进默认窗的 `pendingDialogs`——第二扇窗的框在**第一扇窗里画出来**，而第一扇窗自己的
  那次被覆盖成从未显示；命令 promise 照常 resolve，页面显示 `confirmed=true`，**失败无声**。
  判据是「两个宿主各自的 `id` 序列是否独立」：`dialog take label=main id=1` 与
  `dialog take label=second id=1` 才对，共用一个槽时会连号递增。落法：装配时注入
  `DialogCommands.attachHostResolver({ label => app.hostOf(label) })`，`requireHost(ipc)` 解析器优先，
  **解析器在场而窗口未登记时如实抛错、别回落到单槽**（回落正是串台来源）；三条命令实现都要多收
  `ipc`。**同族两处 2026-10-21 已按同一口径修完**（`clipboard` / `notification` 插件同样
  `attachHostResolver({ label => app.hostOf(label) })` + `requireHost(ipc)`，并各补两条 resolver 单测）——
  但**别拿真机日志当这条修复的凭证**：鸿蒙宿主这两条能力位都是 0，两扇窗都会如实拒绝，
  共用单槽也会打出一模一样的行，区分力只在单测（两个桩宿主行为不同）或宿主落地后的复测。
  取证与修复前后对照见 `docs/鸿蒙ArkWeb接入踩坑.md` §10.12 / §10.13。
- **`opt.exe` 报 `EnumReflection format: operand numbers error!` 时先查工具链配对，别去查 LLVM pass**
  （2026-10-20 定位）：`cjc` **不按 `PATH`** 找 `opt`，它按 `CANGJIE_HOME` 下到
  `third_party/llvm/bin/opt.exe`；两者差一代时必然崩——1.2.0 的 `cjc` 给枚举写 7 操作数 `.ti`，1.1.3 的
  `CJIRVerifier` 只认 6 个，IR 被判 `Broken global value`，表象是 `opt` 以 `0xC000001D`（Windows 的 `ud2`
  内部 trap）退出、栈里只剩一条 `enum … .ti`。**崩溃点在 `opt` 不等于原因在 `opt`**，它是第一个发现 IR
  不合法的关卡。**同时另一个独立问题会把它伪装成「偶发」**：hvigor 的常驻 daemon 在**它自己启动时的
  env** 里跑 `CompileCangjie`，构建脚本 `export` 的 `PATH` / `CANGJIE_HOME` 根本进不去，于是出现
  「命令行手动跑 `cjpm build` 成功、`build-hap.sh` 一跑就崩」的分裂。落法：`hvigorw` 一律
  `--no-daemon` + 先清残留 `node.exe`，并显式 `export CANGJIE_HOME=<SDK>/build-tools`、把 `cjc` / `opt`
  的实际路径与版本打进日志当凭证。对照表（最小枚举程序、框架根 / entry 两处直连 `cjpm`）见
  `docs/鸿蒙ArkWeb接入踩坑.md` §10.9 / §10.10——那四条「`-debug-pass-manager` / `llvm-reduce` / 换 5.0 /
  查 opt 隐式依赖」的诊断都建立在错误前提上，别再跑。
- **鸿蒙工程接框架走 cjpm 源码依赖，别手工把 static 产物塞进 `link-option`**（2026-10-18 实测）：
  `entry/cjpm.toml` 写 `[dependencies] cjTauri = { path = "<框架根>" }` 后 `hvigor` 的 `CompileCangjie`
  会按本模块（`output-type = "dynamic"`）需要的形态把框架各包编进来，零额外配置；
  手工 `-L… -lcjTauri` 虽然也链得过（框架是单对象 `libcjTauri.a`，一引就整包进来），
  但**包初始化登记链不由 cjpm 负责**，属于没人维护的路径——别再走。
  顺带一个 `@When` 口径：鸿蒙的 `os` 取值**就是 `"Linux"`**、`arch` 也**不能用**（桌面 aarch64 Linux
  同样是 `aarch64`，用它门禁会把有 C 桥的桌面平台一起摘掉），唯一可靠判据是 **`env`**
  （`aarch64-linux-ohos` → `ohos`，桌面 → `gnu`）；框架里一律写 `@When[env == "ohos"]` /
  `@When[env != "ohos"]`。详见 `native/platforms/harmonyos/README.md` 的平台判据小节。
- **从命令行构建鸿蒙工程（headless）必须自己喂仓颉插件路径，DevEco IDE 里构建不受影响**（2026-10-19 实测，
  `examples/ohos-probe`）：`hvigorw` 按「`hvigor-config.json5` 的 `dependencies` → `CANGJIE_BUILD_SUPPORT_PATH`
  → DevEco 安装根 → `DEVECO_CANGJIE_PATH` → **`DEVECO_HVIGOR_CANGJIE_PLUGIN`**」找仓颉构建插件，
  找到后它自己把 `<工程>/node_modules/@ohos/{hvigor,hvigor-ohos-plugin,cangjie-build-support}` 建成 junction。
  **只手工 mklink 那三个 junction 没用**（node 会把 junction 真路径化，插件里的裸模块名 `require` 仍解析失败），
  手工设 `NODE_PATH` 只让 `require` 不报错、schema 依然不认 `cangjieOptions`。表象是
  `Schema validate failed … property name must be valid: cangjieOptions`——**很像工程配置写错**，
  实际是插件没被加载；而「同样的工程在 IDE 里编得过」只是因为 IDE 喂了这个变量。
  **「NODE_PATH 不报错、schema 仍不认」的真因（2026-10-20 读源码定死）**：插件被判定为**未启用**时，
  `handleCangjieSchema()` 走的是 `deleteSchema()`——**主动把 cangjie 的 schema 删掉**，不报任何错。
  启用判定是纯环境变量：`DEVECO_CANGJIE_PATH` 指向含 `oh-uni-package.json` 的 SDK 根，
  或 `DEVECO_CANGJIE_PLUGIN_ENABLED=true`（`cangjie-plugin-factory.js` 的 `isPluginEnabled()`）。
  headless 构建要**两个都给**：`DEVECO_CANGJIE_PLUGIN_ENABLED=true`（或 `DEVECO_CANGJIE_PATH`）
  + `NODE_PATH=<工程>/node_modules`。真因只在 `<工程>/.hvigor/outputs/build-logs/build.log`
  （`grep -i cangjie`，形如 `failed to load cangjie to dynamically generate schemas: …`），
  终端只有 `00303038` 一行。IDE 侧同一条错看
  `%APPDATA%\Huawei\DevEcoStudio6.1\options\CangjiePluginConfiguration.xml` 的 `pluginStatus`（`DISABLE` 即失败）。
  **两个会把结论带偏的假线索**：① 同一工程「刚才还能编、现在不能」多为常驻 daemon 复用（分界是那个
  装好插件的进程还在不在，不是 `--no-daemon`）；② 「`*.hap` 存在」不能当构建成功——先删产物再看 mtime/大小。
  同族的第二条：环境里预置的 `DEVECO_SDK_HOME` / `NODE_HOME` 若指向**不存在**的安装（本机有一条
  `D:\Program Files\Huawei\DevEco Studio\sdk`），hvigor 当场判 `Invalid value of 'DEVECO_SDK_HOME'`；
  脚本要么校验目录存在再采用、要么让 `DEVECO_WIN` 覆盖（`examples/ohos-probe/build-hap.sh` 是校验后回退）。
- **hvigor 只替换它自己的模板变量：`path-option` 里写别的 `${…}` 会变空串，而空串让整条 `path-option` 一起失效**
  （2026-10-19 实测，2026-10-20 补落法）：`entry/cjpm.toml` 里写 `"${CANGJIE_STDX_OHOS}"` 时，经 hvigor 编到的 cjpm
  拿到的是空串，报错却是 `imports package 'stdx.encoding.json' in its source code, but it is not added as a dependency`
  ——**看着像 toml 漏配依赖，实为变量没落地**（同一份 toml 直接跑 `cjpm` 时是展开的，别拿它当反证）。
  判据：换成字面路径即 BUILD SUCCESSFUL；并且 `AARCH64_LIBS` / `AARCH64_MACRO_LIBS` /
  `AARCH64_KIT_LIBS` 这组 hvigor 注入的路径**不含 stdx**，那条不能省。
  **落法是相对路径 + 工程内联接**（`examples/ohos-probe`）：toml 写 `"../stdx"`，工程根放一个 `stdx`
  junction（本机由 `build-hap.sh` 按 `CANGJIE_STDX_OHOS` 建、不入库）。这样 DevEco IDE 里点 Build 也编得过
  ——而「脚本构建前替换成绝对路径、`trap` 还原」只治命令行那一路，IDE 构建不经过脚本，仍然报同一条错
  （用户侧第一轮还失败就是这个原因：以为已修好、其实是换了条路径构建）。
- CLI 让应用「跑完装配但**不能开窗口**」的场景（`cj-tauri info` 取插件清单）务必防住陈旧产物：旧产物认不出
  新环境变量，会真的创建窗口把命令卡住。守卫 = 「框架源码里有变量名」+「产物 mtime 不比框架源码旧」，
  两者都过才允许跑。
- 实机取证的三个坑（`/tmp/run-*-verify.sh` 一类脚本）：① 应用进程名是 `<示例>/target/release/bin/main`，
  按包名 `pkill -f plugin_shell` 匹配不上——陈旧实例会继续往同一个日志写（文件出现 NUL 空洞、上一轮旧输出混进
  本轮证据）；而 `pkill -f` 的模式又会匹配到脚本自己那行命令（自杀），写法用 `plugin-shel[l]/…` 避开。
  ② X11 是 SSH 转发时 `import -window root` 要抓远端整屏，抓屏本身会把 X 客户端冻住几秒——别在「命令进行中」
  抓屏，否则会污染「心跳是否中断」这类证据（实测先以为 UI 被卡住，其实是抓屏）。③ 等窗口别用固定 `sleep`：
  `cjpm run` 可能要先重编译，改为轮询 `xdotool search --name`。
- **E2E 入口里的断言名有两个写法禁区**（`scripts/e2e/lib.sh` 的证据层，两条都实测踩过）：
  ① **不能含 `:`**——证据层按**第一个** `:` 拆 `name:needle`，名字带冒号会被劈成「名字=前半段、
  needle=后半段」，明细明明在日志里也判未命中（实测 `fs:list 形状正确` 被劈成 `fs` +
  `list 形状正确:[frontend] …`，白红一条）；② **不能含反引号**——双引号里那玩意儿是命令替换，
  写「`..` 绕行仍被拒」当名字会让 `..` 被当命令执行，现象是 `line N: ..: command not found`、
  名字还被替换成空。断言名用中文/`「」`，别用 shell 元字符。
- **页面自检经 `report` 回投时，日志行序不保证**（2026-10-13 实测）：`report` 是**异步命令**
  （命令按 worker 并发分发，见 §2），所以明细行先后不定、**聚合行也不是最后一行**——实测聚合行
  `DONE passed=15` 落盘之后还来了两条明细。判据只能取**计数一致**：聚合行里的 `passed` 等于 PASS
  明细条数、`failed` 等于 0，两者缺一不可。按「最后一条必须是 DONE」写会**假红**（行序骗人），
  只看「有没有 FAIL 行」会**假绿**（红的那条可能正落在聚合行之后）。
- **E2E 断言 needle 别夹会变动的字段**（2026-10-13 实测）：桥的请求日志一行里既有结果又有耗时
  （`[http-client] GET … -> 200 4B 1ms truncated=false`），把 `-> 200 4B truncated=false` 整段当 needle
  **必然假红**——`1ms` 每轮都不一样。needle 取到「稳定且足以判别」的边界为止（`-> 200 4B`），
  要顺带断言 `truncated` 就单独立一条（`truncated=true`）。同理别把端口、耗时、临时路径写死进 needle。
  （自检条目名里带 `:` 会撞证据层拆分、带反引号会被 shell 当命令替换，见上两条。）
- **`DISPLAY` 存在 ≠ 显示器可用**（2026-10-13 实测）：SSH 转发的 `DISPLAY` 失效时变量**还在**
  （本机是 `localhost:15.0`），只看「变量非空」就放行，应用会死在 `cannot open display`，
  而验收脚本还会把这次失败记成「窗口起不来」。判定要**真去连**——`xdpyinfo` /
  `xdotool getdisplaygeometry` / `xset q` 谁在就用谁——连不上再回落 Xvfb
  （`scripts/e2e/lib.sh` 的 `e2e_ensure_display`，且回落时 `env -u DISPLAY` 摘掉那个坏值）。
- **跑仓颉应用时 stdx 的动态库必须进 `LD_LIBRARY_PATH`**（2026-10-13 实测）：stdx 不在 SDK 目录里，
  仓颉运行时也不查 `PATH`；缺它的表象是「应用启动即退、stderr 只有一行
  `cannot open shared object file: libstdx.encoding.json.so`」，极易被读成构建问题。
  兜底探测见 `scripts/e2e/lib.sh` 的 `e2e_ensure_sdk`（`$HOME/.cangjie/stdx/*/dynamic/stdx` 或 `CANGJIE_STDX`）。
- **`xvfb-run` 会把子进程的 stderr 并进 stdout**（2026-10-13 实测）：`/usr/bin/xvfb-run` 收尾跑的是
  `DISPLAY=… "$@" 2>&1`——你在外面写 `cmd 2> app.log` 收不到任何东西，**stdout 反而装满了 stderr 的内容**，
  表象是「应用一行日志都没打，但窗口照起、对端照收到命令」（Redis 示例首轮手搓取证就是这么被空文件骗了一轮）。
  要单独留 stderr 就把重定向**放进里层**：`xvfb-run -a … bash -c '<app> 2> app.log'`。
  E2E 的 `e2e_run_app` 本来就是「先进 xvfb 再重定向」，所以它不受影响——自己手搓实机脚本时才会踩。
- **对端 mock 的日志别同时写 stdout 与 stderr**（2026-10-13 实测）：无人值守脚本习惯 `>m.log 2>&1` 收日志，
  两边都写同一行就会让**同一行出现两次**，`grep -c` 那类计数断言（「对端看见几次客户端接入」）凭空翻倍——
  一次重连被数成 4 次。与「诊断日志的过滤器本身也会骗人」同族：**取证据的通道本身要先去重**。
- **工作目录 = 项目根**：`capabilities/`、`ui/` 都按相对路径读取，启动器/脚本必须切到项目根再启动应用。
- npm 发布的 2FA 现状（2026-10-02 实测）：npm 已停用**新** TOTP 动态码绑定（2025-09-29），passkey 账号
  根本拿不到 6 位码；且自 2026-09-09 起「用过恢复码」会给**所有账号**套 **72 小时只读持有**——期间发布、
  创建 token 等写操作全被拒（`temporarily suspended due to a recent security-sensitive action`），自动解除、
  无需申诉、无法加速。**不要拿恢复码反复试发布**（很可能重新计时）。旁路也不再可靠：本机 npm 10.9.4 的
  `npm token create` 没有 bypass 开关（npm 11 起才有），而 bypass-2FA token 本身已在退场（2026-07-31 公告）。
- **自检全绿 ≠ 界面没问题：布局缺陷只能抓图人眼验**（2026-10-08 实测）：三栏 flex 行里标题**默认参与收缩**，
  中间那栏一窄就把「热门歌曲」折成「热门歌 / 曲」——`examples/music` 那一轮 10 条页面自检断言**全绿**照样这样
  （断言只管「数据到位 / 真的在解码播放 / 歌词跟得上」，管不了排版）。修法是标题 `flex: 0 0 auto;
  white-space: nowrap`，让说明那一段（`min-width: 0; flex: 1 1 auto`）去收缩截断。
  **改过布局就抓一张图看**——Windows 抓 WebView2 内容用 `PrintWindow(hwnd, dc, 2)`（脚本见 `.atomcode/shot.ps1`，
  普通 `BitBlt` 只能拍到空白）。
- **抓屏抓到的永远是「那一刻压在这片坐标最上面的窗口」**（2026-10-16 实测）：`SetForegroundWindow`
  会被系统静默拒绝（不看返回值就当它成功了），此时 `CopyFromScreen` 拍到的是**别人的窗口**——
  于是「截图看起来布局正常」完全可能是一张别的程序的图，拿它当界面凭证会一路骗到最后。
  可靠做法：`ShowWindow(hwnd, SW_RESTORE)` → `SetWindowPos(hwnd, HWND_TOPMOST, 10, 10, …)` 顶到最前，
  **并且把窗口挪进屏内**（窗口有一角在屏外时，那片坐标拍到的也是屏外内容），抓完 `HWND_NOTOPMOST` 还原；
  `GetWindowRect` 给的尺寸可能比屏幕还大，别默认它在屏内。判据：拍完先自己看一眼图里是不是目标窗口
  （标题栏 + 自己的 UI），别看命令退出码。
- **CSS `zoom` 缩放整页时视口单位不跟着缩**（2026-10-16 实测；`examples/ai-chat` 当时用整页等比缩放，
  该示例随后**已撤回**两件缩放，坑对任何用 `zoom` 的页面同样成立）：
  `zoom: 1.3` 之后 `100vh` 仍是**未缩放**视口的高度，乘 1.3 就超过视口——`body{height:100vh}` 的页面短一截 /
  溢出。修法是按 `1/--z` 反向补偿（`calc(100vh / var(--z, 1))`，页面里所有 `vw` / `vh` 同口径）。两个附带条件：
  ① **先探测再补偿**——`zoom` 不被支持时若还写 `--z≠1`，补偿式反过来把页面压到 1/z 高；探测要真的量一个
  100px 探针（只看 `d.style.zoom === '1.5'` 认了属性不算数，得有实际布局效果），不认就保持 `--z = 1`
  （代价是「不缩放」而不是「布局塌一截」）；② **档位依据取 `screen.availWidth`，不要取 `innerWidth`**
  ——后者会被 zoom 改，拿它算缩放比会形成反馈环（越缩越小 / 越放越大）。
- **WebKitGTK 的 `<select>` 会用原生 combo 的浅色样式盖掉页面配色**（2026-10-09 实测：`serial-assistant`
  深色页里四个下拉框白底浅字几乎不可读，页面 CSS 的 `background`/`color` 都不生效）。深色页面一律给
  `select` 加 `-webkit-appearance:none; appearance:none` 自绘（箭头用 `background-image` 的两段
  `linear-gradient` 画三角），展开列表里的 `option` 另写一遍底色与文字色——它也吃原生样式。
- **取证脚本别在用户正用着的时候起第二个实例**（2026-10-08 实测）：同一目录的两个实例会共用同一个
  WebView2 用户数据目录（桥显式选 `%LOCALAPPDATA%\cj-tauri\<exe名>.WebView2`，env
  `WEBVIEW2_USER_DATA_FOLDER` 优先——2026-10-14 起不再落 exe 旁边；旧版产物仍会在 exe 旁生成
  `<exe>.WebView2/`），还会写同一份应用数据（如 `examples/music` 的
  `music-library.local.json`）；`taskkill /IM main.exe` 更是把用户那个窗口一并带走。要无人值守验证就
  **复制一份独立副本**（拷 `ui/` + `capabilities/` + `main.exe` + 一个纯 ASCII 的 `check.bat` 设好 `PATH`），
  副本自带自己的数据文件与 WebView2 目录，与真实示例彻底隔离、日志也落副本里——读自己的证据，不打扰用户。
- **Windows E2E 收尾：`pgrep -P` 杀不干净 WebView2 的子进程**（2026-10-13 实测）：`msedgewebview2.exe`
  是原生进程，Git Bash 的 `pgrep -P` 看不见——残留实例占住用户数据目录，下一个应用实例当场
  `create WebView2 controller failed: 0x800700aa`（表象像「窗口起不来」）。两道修法都在 `scripts/e2e/lib.sh`：
  ① `ps -W` 把 MSYS pid 映射成 Windows pid 后 `taskkill //F //T` 整树杀；② 每轮运行给独立
  `WEBVIEW2_USER_DATA_FOLDER`（WebView2 认这个环境变量），实例间互不锁。
- **「发后即忘」返回 0 ≠ 发送成功**（2026-10-13 实测）：通知的异步投递路径「投递成功即返回 0」，
  UI 线程里平台实际失败没人带回命令层——Windows 桩阶段页面侧拿到「发送成功」而 stderr 打着
  `-> failed`，靠 E2E 探针页回投结论才暴露。凡异步投递的命令，core 必须在投递前查能力位
  （`CJ_CAP_*`），平台没声明就当场如实拒绝，不能让「投递成功」冒充「执行成功」。
- **环境变量里的盘符路径进 PATH 前先 `cygpath -u`**（2026-10-13 实测）：`CANGJIE_STDX` 习惯设成
  `D:/...`（cjpm.toml 的 path-option 就是这个形式），脚本里直接 `PATH="$CANGJIE_STDX:$PATH"` 会让
  MSYS 路径转换破掉，依赖运行时 DLL 的进程找不到任何库——「PATH 盘符形式」老坑的环境变量变体。
- **跨平台脚本别拉解释器做小事**（2026-10-13 实测）：`e2e-evidence.sh` 原用 python3 做 JSON 转义，
  注释写「本机与 CI 都有」——Windows 机上没有，转义全空、证据成了坏 JSON（断言名为空、版本断行）。
  转义这类小事用纯 bash 实现；解释器不可得时的自检走回退链（`python3 → python → py -3`）。
- **应用调 `cjc` 编出来的东西要交付到别的机器，必须静态链接**（2026-10-15 实测，`examples/leetcode-gui`
  判题）：`cjc main.cj -o judge` 默认**动态**链接，产物在运行期由 loader 按 PATH / 系统目录解析
  `libcangjie-runtime.dll`——命中别代运行时时 ABI 名字对不上，报「无法定位程序输入点
  `CJMCC_ExclusiveScope`」（本 SDK 的运行时导出的是带下划线的 `CJ_MCC_*`），进程连 `main` 都进不去、
  stdout 与 stderr 全空，页面上看着像「运行没反应」；而**同一份源码在本机跑得出 3/3 PASS**（换一次
  PATH 就复现，别把「本机过了」当交付判据）。修法是编译命令带 `--static --static-std --strip-all`：
  `--strip-all` 把静态产物从 25MB 压回 2.7MB（动态版 2.1MB，体积代价可忽略，冷编译约 0.4~1 秒）；
  判据是**只给 `C:\windows\system32;C:\windows` 也能跑出 `RESULT PASS`**，且 `objdump -p` 的导入表里
  不再出现 `libcangjie-*`/`libboundscheck`（`cjc --help` 里这三个开关都有，不用外部 strip）。
  **同一轮还踩到它的下游：改了编译开关必须让它进产物缓存键**（2026-10-15 实测）——判题按「源码哈希 →
  产物」缓存，键里只有源码时，改成静态链接后**旧缓存照样命中**，把动态链接编出的旧产物原样拿去跑，
  用户端表象是「升级了新版本、报错一字不差」（排查时容易怀疑新版本没生效、或又去查产物）。键取
  「源码 + 开关签名」（开关收敛到 `commands.cj` 的 `JUDGE_COMPILE_FLAGS` 一处），旧条目自然失效、
  不必手工清缓存。判据：在旧缓存键目录里放一个 31 字节的假产物——修后不再出现 `compile cache hit`、
  重新编译的产物导入表里没有仓颉运行时 DLL、判题照旧 3/3 PASS（那个假文件毫发无损）。
- **E2E 的启动环境有两处会让「应用一启动就退、日志一行都没有」**（2026-10-15 实测，`scripts/e2e/lib.sh`）：
  ① `CANGJIE_HOME` 来自 envsetup.bat / 本机环境变量时是**盘符形式**（`D:\Program Files (x86)\Cangjie`），
  直接拼进 PATH 会被 MSYS 按「冒号即分隔符」切碎（拆成 `D` 与 `\Program Files...`）——与 `CANGJIE_STDX`
  那条同源，进 PATH 前统一 `cygpath -u`；② **stdx 目录没进 PATH**：Windows 上运行时按 PATH 找
  `libstdx.*.dll`，缺它的表象与①完全一样（0 行输出 + 退出码 127），原先只在环境变量已导出时才加它，
  现在会先探测再明确打一行失败。**判据：先手工带 POSIX 形式的 PATH 前台跑一遍产物**——能跑通就说明
  是启动环境的问题，别去查代码或产物。同族的第三种形状：`scripts/test.sh` 的 Windows 分支只把 stdx
  放进 PATH 而**没 `export CANGJIE_STDX`**，cjpm 展开 `${CANGJIE_STDX}` 得到空值，报的却是
  `root package 'cjTauri' imports package 'stdx.encoding.json' … not added as a dependency in cjpm.toml`
  （看着像 toml 漏配）——**凡是「探到了变量」，先 `export` 再谈进 PATH**。
- **实机入口的「产物新鲜度」检查只认探针自己的源码 = 假红**（2026-10-15 实测）：`ls -t src/*.cj` 给的是
  **相对名**，拿它比绝对路径的产物**永远判「不比它新」**（一条永不触发的检查）；而且探针静态链的是框架，
  只盯 `$FIXTURE/src` 会漏掉框架改动——本轮框架给 `system:host` 补了 `hotkey` 字段、探针产物没重建，
  页面读到 `hotkey=undefined`，断言白红一轮。两处都改绝对路径比较，并把 `$E2E_ROOT/src/*.cj` 一起计入。

## 5. 文档与提交

- 行为变更必须同步：`CHANGELOG.md` 的 `[Unreleased]` 段 + 受影响的 `README.md` / `docs/使用文档.md`。
- 提交信息用 Conventional Commits（`feat:` / `fix:` / `docs:` / `refactor:` / `chore:`），主题写英文，正文可中英混排；
  一次提交只做一件事。
- **双仓双推**：`origin` 已挂两条 pushurl（AtomGit + GitHub），一次 `git push origin main` 同步两个托管；
  单推某仓用 `git push github main`。**不要只推一个仓**。tag 同理（`git push origin main --tags`）。
- 文档与代码注释里引用托管地址一律用 **AtomGit**（`atomgit.com`），不要写其他托管站点。
  唯一例外是功能必需的两处：`.github/workflows/` 下的 GitHub Actions workflow（npm trusted publishing 只支持
  GitHub / GitLab / CircleCI 三家）；`npm/package.json` 的 `repository.url`（必须精确等于 GitHub 仓库名，
  否则 npm 以 `E422` 拒绝发布）。
- 不提交：`target/`、`dist-win/`、`**/dist-single/work/`、`**/dist-single/*.WebView2/`、`*.dll`、`*.log`、`cjpm.lock`、`.atomcode/`（本地会话产物）。
  `dist-single/` 下**打好的 exe 例外**——那份随仓库分发（不装 SDK 的人能直接拿到）。
  **第二处例外是随包 cjh 的依赖 DLL**（`examples/*/vendor/cjh/bin/**`）：cjh 是仓颉程序，Windows 侧
  `libcangjie-runtime.dll` / `libboundscheck.dll` / `libssl-3-x64.dll` / `libcrypto-3-x64.dll` 由它
  **按名字 LoadLibrary**（不在 PE 导入表里，漏了就起不来 / https 全灭），不随包分发等于把 cjh 交成残包。
  该目录由各示例自己的 `.gitignore` 用 `!vendor/cjh/bin/**` 开口子，`scripts/check-static.sh` 的
  「构建产物」检查按同一口径放行**这棵树里的** `.dll` 并把放行条数打进日志——**口径不放宽到任意 `*.dll`**。
  提交前 `git status` 自查，用**显式路径** `git add`，避免 `git add -A` 扫进无关文件。
- `docs/仓颉版Tauri-介绍与使用指南.md` 与 `docs/仓颉版Tauri-博客稿.md` 是**发表用文稿**：
  需要更新时另存新文件或先确认，不要为同步 API 直接覆盖。
- 代码以 **MIT** 发布（根 `LICENSE`）；引入第三方代码或资源时，必须在本文件登记其来源与许可证。
  当前已登记的第三方代码：**three.js r160**（`examples/typing-poem/ui/vendor/three.min.js`，669 884 字节，
  取自 `three@0.160.0` 的 **UMD** 构建；许可证随文件放在 `ui/vendor/three.LICENSE.txt`，MIT）、
  **marked v12.0.2 + Highlight.js v11.9.0**（`examples/markdown-notes/ui/vendor/` 下的 `marked.min.js`
  35 479 字节、`highlight.min.js` 121 727 字节，hljs 主题样式三份 `github-dark-dimmed.min.css` 1 251 字节、
  `github-dark.min.css` 1 315 字节、`atom-one-dark.min.css` 856 字节，均取自 jsDelivr 的
  UMD/CDN 构建、原样分发；许可证随文件放在 `ui/vendor/LICENSE.txt`——marked 为 MIT、
  Highlight.js 为 BSD-3-Clause，markdown-notes 预览渲染、代码高亮与主题切换用；
  **ai-chat 与 cjnote 复用同一份 hljs**：`examples/ai-chat/ui/vendor/` 与 `examples/cjnote/ui/vendor/`
  下的 `highlight.min.js`、`github-dark.min.css` 都是 markdown-notes 那份的逐字节拷贝，许可证同一份
  `LICENSE.txt`——更新时三处一起换）、
  **CodeMirror 5.65.16**（`examples/leetcode-gui/ui/vendor/` 下的 `codemirror.min.js` 173 953 字节
  与 `codemirror.min.css` 6 378 字节，取自 jsDelivr 的 `codemirror@5.65.16` CDN 构建，尾部的
  sourceMappingURL 行已删——内联后指向不存在的 map 文件；许可证随文件放在
  `ui/vendor/codemirror.LICENSE.txt`，MIT；leetcode-gui 编辑器的语法高亮/行号用，
  仓颉高亮规则是应用自写的轻量 mode 未用官方 clike——对仓颉关键字覆盖不全；
  **cjnote 复用同一份**：`examples/cjnote/ui/vendor/` 下的 `codemirror.min.js` / `codemirror.min.css`
  是 leetcode-gui 那两份的逐字节拷贝（`codemirror.LICENSE.txt` 同一份），`marked.min.js` /
  `github-dark.min.css` 则是 markdown-notes 那两份的逐字节拷贝——更新时两处一起换）。
  选 r160 的理由：**它是最后一个带 UMD 构建的版本**（`three@0.161+` 只剩 ESM），而这个示例的页面是
  `run(html)` 的内联来源（Windows 下 `NavigateToString`，无真实来源），相对 `<script src>` 与 ES module
  都不成立——只能把整份 UMD 经 `addInitScript()` 走 document-start 通道注入（AGENTS §4 有这条坑的完整形状）。
  第二项是**系统 SQLite**（`src/plugins/sqlite/sqlite_ffi.cj` 用 `foreign func` 直连，仓库首例「不经 C 桥」）：
  本仓**不随包分发** sqlite3 二进制，链接谁由消费方提供——Linux 走发行版 `libsqlite3.so`（示例的
  `link-option` 里加 `-lsqlite3`），Windows 本机自备 `sqlite3.dll`（官方预编译 zip 是 public domain，
  导入库 `native/libsqlite3.a` 由 `sqlite3.def` 经 `llvm-dlltool -m i386:x86-64` 生成，DLL 与导入库
  均不入库；框架 mingw `link-option` 已带 `-lsqlite3`，不引用 sqlite 插件的应用不会被链接到它——
  拆包后链接粒度是插件包级，见 §2）。这类「按名字 LoadLibrary」的库不在 PE 导入表里，最容易被漏，
  见 D-018 第 8 条。SQLite 本身是 **public domain**（`sqlite.org/copyright.html`）：
  不随包分发就不产生附许可证的义务；一旦哪个示例在 Windows 上落地并随包分发 `sqlite3.dll`，
  本条要补上它的来源、版本与许可证位置。
- 仓库根保持 5 个标准文件：`README.md`（必须含运行截图）/ `LICENSE` / `README.OpenSource` / `CHANGELOG.md` /
  `CONTRIBUTING.md`；功能与依赖变更时同步受影响的文件，平台或依赖变化时 `README.OpenSource` 也要改。
- **`skills/` 目录（AtomCode skills，已 marketplace 化）**：随仓库分发的 AI 指令（`cj-tauri-env` /
  `cj-tauri-app-dev` / `cj-tauri-verify` / `cj-tauri-troubleshoot` / `cj-tauri-contribute` 五个），`.atomcode-plugin/marketplace.json`
  声明 plugin、`skills/plugin.json` 声明 skills 路径。**新坑 / 新工作流优先沉淀回 skills**（速查表在
  `cj-tauri-troubleshoot/SKILL.md`），与 `AGENTS.md` §4 同步维护；skill 名限 `[a-z0-9_-]`。
  本机验证：`bash scripts/install-skills.sh` 后新会话 `/` 菜单可见。

## 6. 版本与发版

- 语义化版本。0.x 阶段：新增能力进中间位（0.6.0 → 0.7.0 → 0.8.0），修复进末位（0.8.0 → 0.8.1）；
  **1.0.0（2026-10-17）起对外 API 进入稳定承诺**，此后不兼容变更进主版本、新能力进次版本、修复进末位。当前 **1.0.0**。
- 必须同步的**五个位置**（`bash scripts/check-version.sh` 校验，权威目标是 CHANGELOG 顶部已发版段）：
  1. `cjpm.toml` 的 `version`（框架包）
  2. `cli/cjpm.toml` 的 `version` 与 `cli/src/project.cj` 的 `cliVersion()`（`--version` / `info` 打印它）
  3. `src/version.cj` 的 `CJ_TAURI_VERSION`（`system:version` 命令返回它）
  4. `CHANGELOG.md` 顶部已发版段
  5. `npm/package.json` 的 `version`（npm 包版本，`npx cj-tauri --version` 在无 SDK 时读它）
- **不随项目版本走**：`examples/hello/cjpm.toml`、`cli/templates/app/cjpm.toml` —— 那是各应用自己的版本。
- 发版步骤：CHANGELOG 的 `[Unreleased]` 改名成 `[x.y.z] - 日期` → 同步上面 1–3 → `check-version.sh` 全 `ok`
  → 提交 → 打 tag `vX.Y.Z` → `git push origin main --tags` 双推。
- **npm 发布**：首版必须手工发（trusted publishing 的配置入口在 npm 的包设置页，包得先存在），绑定好之后
  推 `v*` tag 由 `.github/workflows/npm-publish.yml` 自动发布：
  1. 手工发首版——**这一步躲不开**：npm 只允许给「已存在的包」配置 trusted publisher（入口在该包的 settings 页），
     所以自动发布只能从第二个版本开始。首版走 **staged publishing**（`npm stage publish` 不要 2FA，
     且**能创建尚不存在的包**：registry 先放一个 `0.0.0-stage` 占位版本，正文等批准后才公开）：
     `npx --yes npm@latest stage publish ./dist-npm/cj-tauri-<版本>.tgz --registry=https://registry.npmjs.org/`
     → npmjs.com 的 **Staged Packages** 页 → Approve（浏览器里 passkey 直接过 2FA）。
     `npm stage` 需 CLI ≥ 11.15.0 与 Node ≥ 22.14.0，本机 npm 10.9.4 没有该子命令，故用 `npx --yes npm@latest`
     绕开、不动全局 npm。发布固定走官方 registry（本机 npm 配的是 npmmirror 镜像，别直接 `npm publish`）。
     坑：**别拿 2FA 恢复码当 `--otp` 直发**。npm 自 2025-09-29 停用**新** TOTP 绑定，passkey 账号根本没有
     6 位动态码；而自 2026-09-09 起「用过恢复码」会给账号套上 **72 小时只读持有**——发布、建 token 全被拒，
     报 `temporarily suspended due to a recent security-sensitive action`，自动解除、无法加速，
     反复用恢复码很可能重新计时（本项目 2026-10-02 已实际踩过）。同理也别依赖
     `bash scripts/npm-pack.sh --publish` 直发：bypass-2FA 的 granular token 曾能直发，但 npm 已在
     2026-07-31 公告其退场（直发 2027-01 取消，此后只保留读私有包与 staging）；
  2. npmjs.com → 包 → Settings → **Trusted publishing** → 添加 GitHub Actions，三个字段逐字一致（大小写敏感，
     且保存时不校验）：user/repo `yangyongzhen/cj-tauri`、workflow 文件名 `npm-publish.yml`，并**勾上
     Allow npm publish**（2026-09-03 之后新建的配置默认只允许 `npm stage publish`，不勾则 CI 发布会 `E_STAGE_REQUIRED`）；
  3. 同一页把 Publishing access 改成「Require two-factor authentication and disallow tokens」，此后只有 OIDC 能发；
  4. 推 tag 即自动发布（OIDC 换短期凭据，**不需要任何 token**，自动附 provenance）。注意 CI 里没有仓颉 SDK，
     **CI 打的包不含预编译 CLI**，用户首次运行在本机源码构建；要带 `prebuilt/` 就用本机 `npm-pack.sh` 发。

## 7. 交付检查清单

- [ ] `cjpm build` 通过（涉及 CLI / 示例时各自再跑一次）
- [ ] `bash scripts/test.sh` 全绿（改动涉及 IPC 分发 / 能力校验 / 版本常量时；纯文档改动可跳过）
- [ ] `bash scripts/check-static.sh` 全绿（不需要 SDK；CI 跑的就是它，纯文档改动也要过——围栏检查盯着文档）
- [ ] 实机验证过的话：`bash scripts/e2e/run-all.sh` 跑一遍实机入口（`scripts/e2e/`，**平台守卫不匹配是
      FAIL 不是跳过**；本机必须跑的平台用 `CJ_TAURI_E2E_REQUIRE=linux` 声明），产出
      `dist/e2e-evidence/*.json`（证据可对账，判据见 §1 第 5 条）
- [ ] 新增实机入口放 `scripts/e2e/test-<平台>-*.sh`：必须 `source lib.sh` 并调用 `e2e_require_platform`
      （`check-static` 第 9 项守这条），驱动 `scripts/e2e/fixture-app/` 探针应用而不是临时脚本
- [ ] 实机跑通：桥 stderr 无 `hr=` 非 0，无 `command not allowed` / `command not registered` 误报
- [ ] 新命令/新 API 三处联动齐全（注册 + 能力清单 + 前端调用）
- [ ] `CHANGELOG.md` 的 `[Unreleased]` 已写；`README.md` / `docs/使用文档.md` 已同步

### CI 上的完整门禁（可选，默认跳过）

`.github/workflows/ci.yml` 除 `static` 作业外还有一个 `sdk` 作业，跑 `cjpm build` + `scripts/test.sh`。
仓颉 SDK 的官方下载页（`cangjie-lang.cn/download`）要登录华为账号、**没有匿名直链**，
本平台也没有预装 SDK 的官方镜像，所以 SDK 由仓库 secret 自托管
（GitHub → Settings → Secrets and variables → Actions）：

1. `CANGJIE_SDK_URL` —— SDK 压缩包直链；**配了才启用该作业**，未配置时作业只打印一条 notice 后跳过（不判失败，
   免得 CI 因「拿不到 SDK」这种环境原因长期变红）。
2. `CANGJIE_STDX_URL` —— stdx 压缩包直链（可选；本仓库各 `cjpm.toml` 的 `bin-dependencies` 依赖它）。

两个已知前提（不满足就会红，作业里已分别处理）：① stdx 解压到 `/root/.cangjie/stdx/` 后按
`*/dynamic/stdx` 探测真实目录写入 `CANGJIE_STDX` —— 源码仓 `cjpm.toml` 的 `bin-dependencies`
路径统一写 `${CANGJIE_STDX}`（issue #3），cjpm 按进程环境变量展开；② runner 要装
`gcc pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev` 才链得了 C 桥（`cjpm.toml` 里 `-lcjtbridge -lwebkit2gtk-4.1`）。
配好 secret 后**实推一次确认变绿再算数**，不要只看 YAML 通过。
- [ ] 发版相关改动已跑 `bash scripts/check-version.sh` 且全 `ok`
- [ ] `git status` 无构建产物与无关文件；按双仓约定推送（tag 一并推）
