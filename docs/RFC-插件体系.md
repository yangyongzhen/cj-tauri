# RFC-001：cj-tauri 插件体系 v1

| 项 | 内容 |
|---|---|
| 状态 | **v1 已落地（2026-10-02）**：实现 `src/plugin.cj` / `src/plugin_fs.cj`，示例 `examples/plugin-fs`，契约 `AGENTS.md` §2，落地对照见 §7.1；开放问题的 v1 结论见 §7.1 末段。**v1.1 增补（2026-10-02）：命名权限集落地**，见 §7.1 第 7 行与 §8 问题 2。**v1.2 增补（2026-10-02）：官方 `dialog` 插件落地**（系统原生对话框 + 宿主接口新能力 + 两平台 C 桥），见 §7.1 第 8 行。**v1.3 增补（2026-10-02）：官方 `shell` 插件落地**（打开系统默认程序 + 执行子进程；argv 直传不过 shell，纯仓颉零 C 桥），见 §7.1 第 9 行 |
| 编号 | RFC-001 |
| 日期 | 2026-10-01 |
| 评审方式 | 在本仓提 issue 讨论，标题以 `[RFC-001]` 开头；结论回写本文「开放问题」一节 |
| 适用范围 | 桌面两端（Windows WebView2 / Linux WebKitGTK）；鸿蒙留接口不留实现 |

## 1. 摘要

把「给应用加能力」从现在的三处联动（写 `CommandHandler`、`app.register(...)`、手改
`capabilities/*.json`）收敛成两件事：**加一个 cjpm 依赖，写一行 `app.plugin(FsPlugin())`**。
插件自己声明它提供哪些命令与事件、以及前端该怎么调用；权限仍然由应用的能力清单决定。

## 2. 现状与问题

| 已有底座 | 位置 |
|---|---|
| 命令注册与分发 | `src/ipc_hub.cj` 的 `IpcHub.register(cmd, handler)` / `handleRawMessage` |
| 权限模型（默认最小权限） | `src/capability.cj`：`Capability` / `CapabilityRegistry`，按完整命令名**精确匹配** |
| 应用装配 | `src/app.cj` 的 `TauriApp`：`window / register / addCapability / loadCapabilities / emit / run` |
| 前端桥 | `native/bridge_win.c` 里注入的 `BRIDGE_JS`，暴露 `window.__CJ_TAURI__`（`invoke` / `listen` / `emit`） |
| 内置命令 | `app.cj` 的 `run()` 里硬编码注册 `system:version` / `system:ping` / `system:echo` / `system:devtools` |

三个结论：

1. 「一组命令 + 一个命名空间」这件事框架里已经有雏形（`system:*` 就是内置插件），只是没有抽象；
2. 「命令」与「权限」都有底座，缺的是**装配范式**与**前端入口**；
3. 前端缺一个「插件往 `__CJ_TAURI__` 上挂命名空间」的机制——现在只有裸 `invoke`。

因此插件的价值不在「能不能调用命令」（早就能），而在三件事：**可分发**（第三方不用改框架源码）、
**自带说明**（前端知道有哪些 API、报错能说清缺哪条权限）、**装配一致**（一行注册，不是三处联动）。

## 3. 目标与非目标

### 3.1 目标（v1）

1. 插件是一个独立的仓颉包（cjpm 依赖），第三方可以在**不改框架源码**的前提下扩展能力。
2. 装配只有一行，且插件自报「我提供哪些命令/事件」。
3. 权限仍由应用的 `capabilities/*.json` 决定，**默认最小权限不被破坏**。
4. 前端有稳定的入口命名空间，插件 JS 不需要使用者手写胶水。
5. 缺权限时的报错要说清「缺哪一条、加到哪个文件」。

### 3.2 非目标（v1 明确不做）

- 插件市场、远程安装；**不做动态加载**（不引入 `.dll` / `.so` 形式的插件）。
- 跨语言插件（只做仓颉插件；C 桥扩展仍属框架内部工作）。
- 插件级热重载。
- 鸿蒙侧插件（先桌面两端）。
- 插件自动放行权限（理由见 §5.3）。

## 4. 术语与命名

- **插件名**（namespace）：小写字母与数字，如 `fs`、`dialog`。
- **命令全名**：`<插件名>:<命令短名>`，如 `fs:readText`。
  理由：与内置的 `system:*` 完全一致；`IpcHub` 与 `Capability` 都是按完整字符串匹配，
  **不需要改动任何校验逻辑**，插件体系可以零侵入接上。
  备选方案见 §8 开放问题 1（Tauri v2 风格 `plugin:fs|readText`）。
- **事件全名**：`<插件名>:<事件短名>`，如 `fs:changed`。

## 5. 设计

### 5.1 仓颉侧接口

```cangjie
/** 插件：一组命令 + 可选事件 + 可选前端 JS */
public interface Plugin {
    /** 插件名，作为命令/事件命名空间，如 "fs"；不得包含 ':' */
    public func name(): String

    /** 命令短名 → 处理器；框架注册为 "<name>:<短名>" */
    public func commands(): HashMap<String, CommandHandler>

    /** 插件可能推送的事件短名；框架注册为 "<name>:<短名>"（用于文档与缺权限提示） */
    public func events(): ArrayList<String>

    /** 前端 JS 片段：定义 window.__CJ_TAURI__.<name>；没有就返回空串 */
    public func jsShim(): String

    /** 初始化：记录 app 引用、做一次性准备 */
    public func setup(app: TauriApp): Unit
}
```

`WebViewHost`（`src/host.cj`）是纯声明的接口，没有默认实现。若仓颉接口支持默认方法，
`events()` / `jsShim()` / `setup()` 可以带默认实现，插件作者就只写 `name()` 与 `commands()`；
若不支持，则补一个 `AbstractPlugin` 基类提供空实现。二者取一，见 §8 开放问题 3。
（这一条需要实测确认，不作为本文的既定结论。）

### 5.2 装配

```cangjie
let app = TauriApp()
    .window(WindowConfig("我的应用", 900, 640))
    .plugin(FsPlugin())          // 新增：一行接入
    .plugin(DialogPlugin())
    .register("greet", GreetCommand())

let html = String.fromUtf8(File.readFrom("ui/index.html"))
app.run(html)
```

`plugin(p)` 内部做四件事：注册命令（自动加 `<name>:` 前缀）、登记事件名、收集 `jsShim()`、
调用 `p.setup(this)`。返回 `TauriApp` 保持链式风格，与现有 `register()` 一致。

注册时机沿用现状：必须在 `run()` 之前完成——页面加载前命令表要定稿。
`run()` 内部（注册内置命令之后）统一做一次装配收尾（§5.3 的未授权检查、§5.4 的 JS 组装）。

### 5.3 权限：插件声明不等于自动放行

这是本设计里最需要拍板的一处取舍，先把两种做法摆开：

| 做法 | 结果 |
|---|---|
| A. 插件自带 capability，注册时并入 registry | 一行接入即可用，但**第三方包能把权限一次性放行**——「默认最小权限」失效，审计时也说不清哪条权限是谁开的 |
| B. 插件只声明「提供什么」，放行仍由应用的能力清单决定 | 保持了最小权限与可审计性；代价是使用者写完 `plugin(...)` 还得去 JSON 里加一行 |

v1 选 **B**，理由：权限模型是这个框架区别于「随便一个 WebView 壳子」的地方，
不能为了少写一行 JSON 把它让掉。为把 B 的使用成本压到最低，做两件事：

1. **启动检查 + 明确提示**（`run()` 内，能力清单加载完成后执行）：
   ```
   [cj-tauri] 插件 fs 的命令 fs:readText 尚未授权，前端调用会被拒绝
   [cj-tauri]   请在 capabilities/*.json 的 commands 里加入 "fs:readText"
   ```
   这条提示的数据来源与 §5.5 的清单是同一份，几乎零成本。
2. **给使用者一个「引用」动作而不是「自动放行」**：插件自带命名 permission set
   （对标 Tauri v2：插件发布 permission，应用 capability 里引用 `"permissions": ["fs:default"]`）。
   **v1.1 已落地**（2026-10-02，比本节原先「留到 v2」的判断提前）：`Plugin.permissions()` 声明集、
   `CapabilityRegistry.addPermissionSet` 注册、清单 `permissions` 字段引用；明文命令名保留且与集**等价**——
   集只解决「写法短」，闸门仍在清单手里（§8 问题 2 的答案）。

### 5.4 前端 JS：命名空间与注入时机

目标形态（插件作者只写 `jsShim()`，使用者直接用）：

```js
const text = await __CJ_TAURI__.fs.readText({ path: 'notes.txt' });
```

约定：

- `jsShim()` **只允许定义一个命名空间** `window.__CJ_TAURI__[插件名]`，
  不得覆盖 `invoke` / `listen` / `emit`，也不得注册全局变量（避免插件互相污染）。
- shim 内部一律走 `__CJ_TAURI__.invoke('<插件名>:<命令短名>', args)`，
  返回 `Promise`，**不吞异常**——`err.message` 仍然是后端给的原文（与 §3.3 的报错表一致）。
- shim 必须在页面脚本执行**之前**生效，否则页面里 `__CJ_TAURI__.fs` 可能是 `undefined`。

注入时机是本节的关键。现状：桥的 `BRIDGE_JS` 由 C 桥在「文档创建时」注入
（`AddScriptToExecuteOnDocumentCreated`），因此**先于页面脚本**；而插件的 shim 如果走
`runJs`（等价于 `ExecuteScript`）注入，就可能晚于页面里自己的 inline script，出现竞态。

v1 方案：**纯仓颉侧的 HTML 组装**——`run(html)` 时把各插件的 `jsShim()` 拼成一个 `<script>` 块，
插到 `</head>` 之前（没有 `</head>` 时插到文档最前面，并在 stderr 说明）。
优点：顺序确定，**不需要改 C 桥**，两端行为一致。
局限：本质上是字符串操作，对畸形 HTML 不健壮——因此 v2 的方向是给宿主层加「预执行脚本列表」
（WebView2 与 WebKit 都支持注入多段 pre-page script），届时替换掉这个取巧做法。

### 5.5 插件清单（给工具与文档用）

插件的数据（名称、命令、事件）在 `plugin()` 时已经拿到，顺手产出机器可读的一份，
供两处使用：`cj-tauri info` 打印已装配插件；生成能力清单片段给使用者粘贴。

```
已装配插件:
  fs      fs:readText, fs:writeText, fs:exists        events: fs:changed
```

v1 先做成 `info` 的输出；是否额外提供 `Plugin.manifest(): JsonValue` 供外部工具消费，见 §8 开放问题 7。

## 6. 兼容性与版本

- 插件体系是**新增 API**：`register()` / `Capability` / `capabilities/*.json` 语义都不变，
  0.3.x 的应用升级后行为一致（现有的 `examples/hello`、脚手架模板工程不需要改）。
- 但**插件接口本身**在 1.0 之前可能调整，处理方式：
  - 文档与 CHANGELOG 标注 experimental；
  - 约定「插件接口的破坏性变更走 minor（0.x）并在 CHANGELOG 的 Changed 里写明」；
  - 官方插件与框架同仓、同版本号，改接口时一起改，作为第一批使用者暴露问题。
- 命名空间与用户命令共存：`system:` 归框架、`<插件名>:` 归插件，无冒号的命令归应用自身。
  用户命令里出现 `:` 暂不限制（现状也不限制），只在文档里建议。

## 7. 交付物（v1 验收）

1. `src/plugin.cj`：`Plugin` 接口（+ 可能的 `AbstractPlugin`）、`TauriApp.plugin()`。
2. 装配收尾：未授权命令提示（含「缺哪条、加到哪里」）+ jsShim 的 HTML 组装。
3. 官方 `fs` 插件：`fs:readText` / `fs:writeText` / `fs:exists`，纯仓颉零 C 桥改动，自带 jsShim。
4. `examples/plugin-fs` 示例工程；Windows 实机验证，stderr 出证据（含未授权提示的对照组）。
5. 文档：使用文档新增「插件」一章；前端教程补「用插件」小节；CHANGELOG；
   `AGENTS.md` 增「新增插件的三处契约」（与现有「新增命令三处联动」并存）。
6. 回归：`examples/hello` 与脚手架模板工程行为不变，版本自检脚本仍 4/4。

### 7.1 落地对照（2026-10-02）

| 交付物 | 落地位置 | 说明 |
|---|---|---|
| 1. `Plugin` 接口 + `TauriApp.plugin()` | `src/plugin.cj`、`src/app.cj` | 接口四个方法中 `events()` / `jsShim()` / `setup()` 带默认实现（开放问题 3 的实测答案：仓颉接口支持默认实现，无需 `AbstractPlugin`） |
| 2. 未授权提示 + jsShim 组装注入 | `src/plugin.cj`（`warnUnauthorizedPlugins` / `assemblePluginJs` / `injectPluginJs`） | 启动打印已装配清单并逐条提示缺哪条；shim 汇总成一个 `<script>` 插到第一个 `</head>` 之前 |
| 3. 官方 `fs` 插件 | `src/plugin_fs.cj` | 纯仓颉、零 C 桥改动；`fs:readText` / `fs:writeText`（覆盖写）/ `fs:exists` |
| 4. 示例 + 实机证据 | `examples/plugin-fs/` | capability 故意只放行 `fs:readText` / `fs:exists`，`fs:writeText` 作**未授权对照组**；Linux（WebKitGTK / Xvfb）实机：`shim-ready-at-script-start=true`、readText/exists 成功、writeText 被拒 `command not allowed`、`[verify] ALL DONE`（截图 `docs/images/example-plugin-fs.png`，日志 `/tmp/cj-plugin-fs-final.log`）。**Windows 未跑**（本机为 Linux） |
| 5. 文档 | `docs/使用文档.md` §6.7、`docs/前端入门教程.md` §11、`CHANGELOG.md`、`AGENTS.md` §2 | AGENTS.md 另记一条坑：内联在三引号字符串里的 JS 会被仓颉吃掉反斜杠转义（`\n` 变真换行 → 整段脚本语法错误、stderr 无提示） |
| 6. 回归 | `scripts/test.sh` 38/38、`scripts/check-version.sh` 5/5、`examples/hello` 实机复测 | 单测 23 → 38（`src/tests/plugin_test.cj`）；hello 在 Linux 下日志 623 行含 `[verify] ALL DONE`，行为未变 |
| 7. 命名权限集（**v1.1**，2026-10-02） | `src/plugin.cj`（`permissions()` / `pluginPermissionSets` / `registerPluginPermissionSets` / `describePermissionSets`）、`src/capability.cj`（`Capability.permissions` + `CapabilityRegistry.addPermissionSet` / `coveredByPermissionSet` / `warnUnknownPermissionSets`）、`src/plugin_fs.cj`（`fs:readonly` / `fs:default`） | 集名 `<插件名>:<短集名>`，成员短名自动补前缀、全名原样；**集声明 ≠ 放行**（清单不引用不生效）；未知集只提示；清单新增可选 `permissions` 字段，与明文命令名等价、可混用。示例清单改用 `"permissions": ["fs:readonly"]`，Linux 实机：启动打印两个集、只对 `fs:writeText` 报未授权、页面自检 `清单用集 fs:readonly=true; 清单未写死 fs:readText=true` / `DENY-OK fs:writeText` / `[verify] ALL DONE`（日志 `/tmp/cj-plugin-fs-permset.log`）。单测 38 → 50 |
| 8. 官方 `dialog` 插件（**v1.2**，2026-10-02） | `src/plugin_dialog.cj`、`src/host.cj`（`WebViewHost.showFileDialog` / `showMessageDialog`、对话框编号与结果回调共享槽位）、`src/host_webkit.cj` / `src/host_webview2.cj`、`native/bridge_linux.c` / `native/bridge_win.c`（`cj_bridge_show_dialog` / `cj_bridge_set_dialog_callback`）、`examples/plugin-dialog/` | 三条命令 `dialog:open` / `dialog:save` / `dialog:message`（`kind` = info/warning/error/confirm），弹**系统原生**对话框（Linux GTK / Windows Win32 通用对话框），结果经既有 `@C` 回调通道送回（不引入新的 FFI 形态）；命名集 `dialog:files` / `dialog:default`，同样不自动放行。宿主新能力按 §2 契约走：先扩接口、再改两平台实现、C 桥导出同名同签名。**实机抓到的坑**：两平台的 JS→native 回调本就跑在宿主 UI 线程上，故「投递到 UI 线程 + 阻塞等结果」会自锁（日志停在 `[cj-bridge] dialog: kind=…`、对话框永不出现）——桥改为按调用线程分流（已在 UI 线程直接弹，否则投递 + 等）。Linux（WebKitGTK / Xvfb）实机：`dialog closed: kind=2 ok=1` → `dialog:message(info) => confirmed=true` → `dialog closed: kind=0 ok=1 path=/tmp/dialog-pick.txt` → `dialog:open => path="/tmp/dialog-pick.txt"` → 对照组 `DENY-OK system:devtools` → `[verify] ALL DONE`（截图 `docs/images/example-plugin-dialog.png`，日志 `/tmp/cj-plugin-dialog.log`）。单测 50 → 57。**Windows 未实机**（仅 mingw 编译校验 + 桩语法检查） |
| 9. 官方 `shell` 插件（**v1.3**，2026-10-02） | `src/plugin_shell.cj`（**纯仓颉、零 C 桥**：进程 API 来自 `std.process`，平台差异只在 `@When` 里选 `xdg-open` / `rundll32 url.dll,FileProtocolHandler`）、`examples/plugin-shell/` | 两条命令 `shell:open`（URL / 本地路径交给系统默认程序）与 `shell:exec`（`{ program, args?, cwd? }` → `{ code, stdout, stderr }`）；命名集 `shell:allow-open`（只含 `open`）/ `shell:default`（另含 `exec`），同样不自动放行。**安全取舍（评审时请确认）**：v1 **不做程序白名单 scope**——放行 `shell:exec` 就等于把「执行任意程序」交给页面，闸门只有能力清单（见 §8 第 8 条）；注入面靠**不过 shell** 收敛：`program` 与每个参数都是独立 argv 元素直传 `launch` / `executeWithOutput`，页面写 `&&` / `;` / `>` 都只是普通字符（实机对照 `shell:exec(probe) => a b && echo INJECTED`）；输出每流截 256 KiB 并标注，非 UTF-8 退化成摘要。Linux（WebKitGTK / Xvfb）实机：`shell:open(url) => true` 且冒充系统默认程序的假浏览器收到 `argv=https://atomgit.com`（证明目标真到了系统处理器）、`shell:exec(uname) => code=0 stdout=Linux …`、`shell:exec(exit7) => code=7 stderr=to-stderr`、程序不存在给可读错误、对照组 `DENY-OK system:devtools` → `[verify] ALL DONE`（截图 `docs/images/example-plugin-shell.png`，日志 `/tmp/plugin-shell.log`）。单测 57 → 68。**Windows 未实机**（仅编译校验 `@When` 的 Windows 分支） |

开放问题的 v1 结论：1）命令全名用 `<插件名>:<短名>`（与 `system:*` 同形，分发与校验零改动）；
2）v1 不引入 permission set，权限按全名写进 `capabilities/`——**v1.1 已改为支持命名权限集**
（明文仍可用，两者等价、可混用）；3）接口默认实现可用；
4）jsShim 用 HTML 字符串组装注入（`runUrl` 下 HTML 不在本进程、无法并入，已在 stderr 提示 + 文档对齐 `waitForBridge`）；
5）不允许插件依赖插件，装配顺序由使用者负责；6）非命令类能力留待宿主层先有对应 API；7）`manifest()` v1 不做。

## 8. 开放问题（评审时请逐条回答）

1. 命令全名用 `<插件名>:<命令短名>`（改动为零、与 `system:*` 一致），
   还是 Tauri v2 风格 `plugin:<插件名>|<命令短名>`（来源更显式、便于按前缀统一放行，但要动校验）？
2. 插件自带「命名 permission set」（使用者按名引用，如 `"permissions": ["fs:default"]`）是否 v1 就引入？
   **已决（v1.1 落地，2026-10-02）**：引入，但**只作为写法简写**——插件 `permissions()` 声明集，
   应用清单引用；集不自动放行、未知集只提示；明文命令名无限期保留（旧清单零改动）。理由：命令一多，
   「逐条放行」的写法噪音大且容易漏；集让使用者写意图（`fs:readonly`）而不是写清单（三条命令名）。
3. 仓颉接口能否带默认实现？不能的话，用 `AbstractPlugin` 基类提供 `events()` / `jsShim()` / `setup()` 的空实现，可以接受吗？
4. jsShim 用「HTML 字符串组装注入」是否可接受（v2 换成宿主层的预执行脚本列表）？
5. 插件是否允许声明「依赖另一个插件」（例如 `dialog` 依赖 `fs`）？v1 我倾向不允许，装配顺序由使用者负责。
6. 非命令类能力（托盘、全局快捷键、协议处理）以后怎么进这个模型？v1 的 `Plugin` 只覆盖「命令 + 事件 + JS」，
   这类能力需要宿主层先有对应 API——是否要把「插件可以要求宿主能力」写进接口预留位？
7. 是否需要 `Plugin.manifest()` 这样的机器可读清单（供 CLI 打印与生成能力片段）？
8. 执行子进程（§7.1 第 9 行 `shell:exec`）要不要**挪出 UI 线程**、要不要做**程序白名单 scope**？
   **v1（2026-10-02）的答案：都不做。** ① 同步阻塞是已知限制——IPC 处理器跑在宿主 UI 线程上，长驻 / 交互式程序
   会把窗口卡住；文档与插件注释都已写明「别这么用」，等宿主层有工作线程（或命令分发支持异步返回）再改，
   那属破坏性变更。② 「程序白名单」需要能力模型新增**命令级 scope**（`Capability` 里按命令写 `programs: [...]`，
   插件在放行前查），比 v1.1 的命名集动得深（要扩 `capability.cj` 的校验口径与清单 schema），因此 v1 明确
   **不做**：闸门仍是「放行 / 不放行 `shell:exec`」，要更细的粒度请等 scope 设计定稿。
   **① 已落地（2026-10-02，命令异步化）**：`IpcHub.handleInvoke` 只做校验，执行 `spawn` 到 worker 线程
   （契约见 `AGENTS.md` §2 的线程模型），`shell:exec` 与原生对话框都不再冻窗口。对照取证：同一个演示
   （`examples/plugin-shell` 的「长命令 3 秒 + 心跳」）只切换分发方式——同步臂心跳全堆在命令结束后
   （`slow: done +3124ms`、心跳 +3126…3133ms），异步臂首跳 +503ms 并贯穿 3 秒全程（详值与截图见
   `CHANGELOG.md` 的 `Changed` 首条与 `docs/进度记录.md` §3.1）。
   **② 仍不做**：v1 的答案不变，闸门仍是「放行 / 不放行 `shell:exec`」。

## 9. 参考

- 对标对象：Tauri v2 插件模型——插件 = 一个 Rust crate + 可选 JS 包 + permission set，
  应用在 capability 里引用插件的 permission。
- 本仓现状：`src/app.cj`（装配）、`src/capability.cj`（权限）、`src/ipc_hub.cj`（分发）、
  `src/host.cj`（宿主接口）、`native/bridge_win.c`（`BRIDGE_JS` 的注入时机）、
  [使用文档 §6](使用文档.md)、[前端入门教程 §4/§6](前端入门教程.md)。
- 命令与权限的实际行为（含报错文本）见[前端入门教程 §3.3](前端入门教程.md)的对照表。

