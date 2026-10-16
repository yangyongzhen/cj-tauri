# RFC-003：cj-tauri 插件路线图（对照 Tauri 2 官方插件清单）

> 状态：**规划稿**（2026-10-09）。对照 2026-10-09 抓取的 [Tauri 2 官方插件页](https://v2.tauri.app/plugin/)
> 与仓内实况逐项盘点，按「桌面常用度 + 落地成本」排期；体例沿用 [RFC-002](RFC-菜单-托盘-拖放.md)。
> 排期不是承诺——每期开工前按当期实况复核一次，踩坑记录照旧沉淀进 `AGENTS.md` §4 与
> `skills/cj-tauri-troubleshoot`。

## 1. 现状（仓内已有）

| cj-tauri 已有 | 对应 Tauri | 备注 |
|---|---|---|
| `fs` 插件 | File System | 路径 scope **已补齐**（第 4 期，2026-10-12）：`scopes` 字段按插件名收路径白名单 |
| `dialog` 插件 | Dialog | 已实机验证（Linux/WebKitGTK） |
| `shell` 插件（open + exec） | Opener + Shell | argv 直传不过 shell 已实测 |
| `menu` 插件 | （Tauri 里是核心功能） | Windows 14/14、Linux 21/21 实机证据 |
| `serial` 插件 | 社区插件 serialport | Tauri 官方没有；白名单在 C 桥 core，Linux 实机闭环 |
| `stdx.net.http` 直用（movie/music 示例） | HTTP Client | **未插件化**：没有命令层白名单，见 §3.2 第 5 期 |

移动端专属插件（Barcode / Biometric / Haptics / NFC / Geolocation）对桌面框架不适用，**不进路线图**。

## 2. 缺口总表（按优先级）

### P0 —— 桌面应用的「水电煤」

| 插件 | Tauri 对应 | 缺口说明 | 实现要点 |
|---|---|---|---|
| **Store（持久化 KV）** | tauri-plugin-store | `examples/music` 已在用 JSON 手搓收藏/最近播放——框架级补上后这类代码可删 | **纯仓颉**（JSON 落盘 + 原子写 + 内存缓存），零 C 桥；命令 `store:get/set/delete/keys`，路径固定在应用数据目录 |
| **Clipboard（剪贴板）** ✅ 已交付（第 3 期） | tauri-plugin-clipboard | 最基础的桌面能力 | C 桥导出 `cj_bridge_clipboard_*`；Linux `gtk_clipboard_get/set(GDK_SELECTION_CLIPBOARD)`（UI 线程），Windows `OpenClipboard`/`SetClipboardData(CF_UNICODETEXT)` |
| **Notifications** ✅ 已交付（第 3 期） | tauri-plugin-notification | 桌面常用 | Linux `org.freedesktop.Notifications` D-Bus（GDBus，纯平台 API）；Windows 桩——**新增能力位** `CJ_CAP_NOTIFICATION` |

### P1 —— 工具类应用刚需

| 插件 | Tauri 对应 | 实现要点 |
|---|---|---|
| **Global Shortcut** | tauri-plugin-global-shortcut | X11 XGrabKey / Windows `RegisterHotKey`；回调带句柄身份（§4 红线） |
| **Window State** | tauri-plugin-window-state | 依赖 Store：记住 size/position/maximized，`start()` 前恢复 |
| **Single Instance** | tauri-plugin-single-instance | Linux 抽象套接字锁 + 二次启动把参数转给首实例；Windows 命名互斥量 |
| **Logging** | tauri-plugin-log | 框架已有 stderr 口径，插件化后加「落盘 + 轮转」与前端可控日志命令 |
| **fs scope 补齐** | Tauri fs 的 scope | **安全补齐**（现有 `fs` 无路径限制）：清单声明 `fs:scope`（目录/通配白名单），默认收窄到应用目录；兼容策略：未声明 scope 的旧清单保持全量放行并打一条 stderr 提示 |

### P2 —— 按需

| 插件 | Tauri 对应 | 说明 |
|---|---|---|
| **HTTP 插件化**（`http:fetch`） | tauri-plugin-http | 后端 `stdx.net.http` 已在用，缺的是**命令层域名白名单**（SSRF 防护 + Referer 代理经验产品化，movie 的 `movie:image` 是现成样板） |
| **OS Information** | tauri-plugin-os | 扩展 `system:host`：内核版本 / 架构 / locale / 显示器信息 |
| Autostart / Deep Linking / Positioner | 同名 | 等真实应用诉求 |

### P3 —— 重型，1.0 之后

SQL（sqlx 级别）、Stronghold（加密库）、**Updater**（要签名与分发基础设施）、Upload。

## 3. 分期与判据

### 第 1 期：托盘 + 文件拖入（RFC-002 既定，优先于一切新插件）——**拖放已交付（2026-10-13，Linux 实机）；托盘按裁定暂缓**

**不是新插件，是核心能力位收口**——`system:host` 里 `tray=0 / dragDrop=0` 挂了很久，对桌面应用常用度高于
上表多数插件。按 RFC-002 §7 落地；前置：`native/build_win.bat` 补 `-lshell32`（托盘要 `Shell_NotifyIconW`）。

**落地结果（2026-10-13）**：**文件拖入**全链交付——`src/dragdrop.cj`（`DragDropPolicy` 策略模型，start 前
定稿）→ `TauriApp.setDragDrop / setDragDropTo` → `WebViewHost.setDragDropPolicy` → C 桥
`cj_bridge_set_drag_drop`（core 记 pending + 平台原语单一来源）；URI 解析（`file://` 剥前缀、%XX 解码、
注释/空行跳过、32 个/4096 字节上限）在 core（`cj_core_drop_files`，桩自检可测），报文
`{"kind":"drop","paths":[…]}` 经 on_shell 按句柄路由 → 前端 `dragdrop:files` 事件（需清单 `events` 声明）。
Linux 实机（Xvfb）：pygobject drag source + xdotool 合成真实鼠标拖拽 →
`drop: paths=2 first=/tmp/dragdrop-files/proof one.txt`（含空格文件名 %20 解码正确）→ 页面
`drop-received paths=2`；能力位 `dragDrop=1` 如实。**托盘不做**（用户裁定：Linux 依赖
libayatana-appindicator3 三方库，暂缓；Windows 侧本轮也未做，`tray=0` 如实）。
**Windows 拖放为同名桩**（能力位不置位，实机轮补 IDropTarget）。桩自检 151 → **162**；单测 189 → **192**
（含 SEC-003 软链接逃逸/百分比编码 3 条）。

### 第 2 期：Store（纯仓颉，最快见效）——**已交付（2026-10-09）**

**设计定稿（2026-10-09，开工前按约定补）**：

- **命令面**：`store:get { key, default? }` / `store:set { key, value }`（**值是任意 JSON**——music
  存的是整段歌曲数组）/ `store:delete { key }` / `store:keys` → `{ keys: [...] }` / `store:clear` →
  `{ cleared: N }`（返回清掉几条，便于页面提示）；
- **命名权限集**：`store:readonly`（get + keys）与 `store:default`（全部）——照 `fs` 先例；
- **落盘位置**：`StorePlugin()` 默认 `<工作目录>/store.json`（与 capabilities/ 同一套项目根约定），
  `StorePlugin(path)` 自定义路径；v1 一应用一个 store（插件按 name 装配，多实例会撞名），多 store 留待有真实诉求；
- **原子写**：先写 `path.tmp` 再 `std.fs.rename(..., overwrite: true)`（契约已查证）；rename 失败
  回落直写并打 stderr——与 music 现状同级兜底；
- **并发**：命令跑在 worker 线程，set/delete/clear 走内存对象 + 锁（`std.sync`，API 以仓内已验证
  用法为准，实现时先 grep 再写）；
- **损坏文件**：读失败不是致命错误——一行 stderr + 从空开始（music 先例），save 会覆盖掉坏文件。
- **判据**：单测覆盖读写删 / keys / 并发写 / 损坏文件回落 / 原子写（tmp 不残留）；
  `examples/music` 改用它（手搓 JSON 删除，收藏文件形状不变：顶层 `songs` / `recent` 两个键，
  老用户文件无缝迁移）；两平台 `cjpm build` 过 + Linux 实机闭环。

### 第 3 期：Clipboard + Notifications（一组新 C 桥导出）——**已交付（2026-10-12，Linux 实机；Windows 侧同名桩）**

照 menu 的分层样板：`WebViewHost` 加方法 → 两平台实现 → core 加同名导出 + 能力位。
判据：`system:host` 如实上报新能力位；Linux/Windows 各一条实机证据（剪贴板写后系统其它程序能读到、
通知真弹出）；能力清单不声明即拒（最小权限不破）。

**交付结果**：`clipboard:write` / `clipboard:read` 与 `notification:notify`（各带命名权限集）；
平台差异全在 C 桥，仓颉侧共享层只做参数校验。Linux 证据——应用存活时外部回读剪贴板 token 一致、
会话总线上的通知桩实收 NOTIFY（截图与日志归档在 `/tmp/cj-tauri-shots/`）；**Windows 实机未做**
（同名桩 + 能力位如实上报，等 Windows 机）；桩自检 139 → **151**。实机还抓到并修掉两处真崩溃：
把**栈上**的投递载荷交给 UI 线程而回调里 `free()`（`munmap_chunk(): invalid pointer`）、
`g_idle_add` 的 `void` 回调把寄存器垃圾当返回值（GLib 反复重入 → double free）。

### 第 4 期：fs scope（安全补齐，趁插件生态还小）——**已交付（2026-10-12，Linux 实机）**

**为什么**：`fs` 插件只做「命令是否放行」的粗粒度校验——清单放行 `fs:readText` 之后，页面就能读**任意**可读
文件（`/etc/passwd`、源码、私钥）。Tauri v2 的对策是 fs 的 `scope`（按路径白名单二次校验），本期补上。

**语法**（capabilities 清单里新增可选字段 `scopes`，键是插件名——与 `commands` 的命名空间对齐）：

```json
{
  "identifier": "app",
  "windows": ["main"],
  "commands": ["fs:readText", "fs:writeText"],
  "scopes": {
    "fs": { "allow": ["$HOME/notes/**", "data/*.json"], "deny": ["**/id_rsa"] }
  }
}
```

**实现要点**：

- **落在仓颉侧共享层**（`src/scope.cj`），不是插件里手搓：路径变量展开、规范化、glob 匹配、判定顺序
  都只有一份，插件只调 `IpcContext.resolveScopedPath("<插件名>", 页面给的路径)` 取值——
  插件作者不会漏做、也不会各写一套（core 侧放白名单，与 C 桥那条红线同一条道理）。
- **判定顺序**：先 `deny` 后 `allow`——命中 deny 一律拒（含同时命中 allow 的情况）；allow 必须显式命中。
  写了 `scopes.fs` 但 `allow` 为空集 = 该插件路径全拒（显式的最小权限，不做「空即放行」那种反向默认）。
- **路径变量**：`$HOME` / `$TEMP` / `$CWD`（`$CWD` = 进程工作目录，即项目根）。未知变量**保留原文**，
  于是模式匹配不上 = 失败即拒（fail closed），不做「看不懂就当放行」。
- **规范化先于匹配**：已存在的路径走 `std.fs.canonicalize`（连带解析符号链接——白名单目录里的软链接指到
  `/etc/passwd` 也会被拒）；不存在的路径（写新文件的场景）退化为词法规范化（折叠 `.` 与 `..`）。
  相对路径按工作目录解析，与 `capabilities/`、`ui/` 的相对路径口径一致。
- **匹配语义**：`*` 不跨分隔符、`**` 跨分隔符、`?` 匹配单个码点（不是单字节——汉字是 3 字节，按字节匹配会错）；
  Windows 下两侧大小写折叠（`@When[os == "Windows"]`），Linux 保持大小写敏感。
- **兼容策略**：某插件**没有任何**清单给它写 `scopes` → 维持旧行为（全量放行），但启动时由
  `warnUnscopedPlugins` 打 stderr 提示（只在「该插件有命令被授权」时提示，免得没用到也刷屏）。
  插件侧用 `Plugin.scopeAware()` 声明自己吃这层校验（默认 `false`，只有 `fs` 目前为 `true`）——
  框架不该替一个不知道路径是什么的插件猜「哪个参数是路径」。
- **拒绝要有凭证**：拒的时候 stderr 一行 `[cj-tauri] scope denied (<插件>): <原文> -> <规范化结果>`
  （照 `command rejected` 那套前缀口径），前端拿到的是可读的业务错误。

**判据**：默认清单行为不破坏（旧清单全量 + stderr 提示）；新 scope 语法有单测与未授权对照组
（同名命令：允许路径通、越界路径拒、deny 优先、`..` 与软链接绕不过、未声明 scope 时旧行为照旧）。

**交付结果**：`src/scope.cj`（`parseScopeRule` / `scopeAllows` / `globMatch` / `expandScopeVars` /
`normalizeScopePath`）+ `Capability.scopes` + `IpcContext.resolveScopedPath` + `Plugin.scopeAware()`
（`fs` 为 true，其余默认 false）。单测 155 → **189**（14 条 scope 用例，含未授权对照组与 `..` 对照组）。
`examples/plugin-fs` 清单只放行 `$CWD/capabilities/**`，Xvfb 实机取证：白名单内 `fs:readText` 读回
224 字符；`src/main.cj` 与 `../../src/version.cj` 两条越界读被拒，stderr 各一行 `scope denied (fs)`。
实现期补的一条 glob 语义：**`**/` 允许匹配零个目录**（`/a/**/b` 能匹配 `/a/b`，照 gitignore 口径），
否则「白名单目录直接放文件」的写法会莫名其妙全拒。列级 / 窗口级细分（Tauri v2 更细的模型）本轮不做。

### 第 5 期起：Global Shortcut / Window State / Single Instance / Logging / HTTP 白名单

按需求拉取排序；每项开工前在本文件补「实现要点 + 判据」两行，别只留名字。
（Global Shortcut 已随剪贴板历史示例交付，见 `docs/需求追踪.md` PLG-010。）

#### Logging（2026-10-15 开工）

**为什么先做**：已经分发的单文件产物是 Windows 的 **GUI 子系统**——双击时没有控制台，stderr 无处可去，
用户报障时拿不到任何凭证；而框架现在的诊断输出**全走 stderr**（C 侧 173 处 `fprintf(stderr, …)`、
仓颉侧另有上百处）。补一个文件落地点，等于把「日志里没有错误行 ≠ 成功」这条纪律变成可交付的凭证；
对托盘/常驻类应用（用户开着不动好几天）尤其如此。

**实现要点**：

- **接管的层级是 fd，不是调用点**：`freopen(path, "a", stderr)`——此后**所有** stderr 写者（C 桥 core、
  平台实现、仓颉侧 `eprintln`）自动落进同一个 FILE*，顺序天然一致。这样两端上百处调用点**一处都不用改**，
  Windows 平台文件也不必动（本项在 Linux 机器上做，改不动的文件就不该动）。
  **stdout 一律不碰**：`CJ_TAURI_MANIFEST` 的插件清单走 stdout，`cj-tauri info` 靠它。
- **core 侧只给「加时间戳 + 轮转检查点」改名**：`bridge_core.h` 提供 `cj_logf(fmt, …)`，把 **core 内**的
  `fprintf(stderr, …)` 被调方机械改名（参数列表不变）。未开文件时逐字节照旧（现有 E2E needle、
  `[cj-bridge]` 前缀断言全不受影响）；开了文件才在行首加 `[YYYY-MM-DD HH:MM:SS] `。
  平台文件不动：它们照样落盘，只是没有时间戳——**这是有意的取舍**，不为一行时间戳去改本机编不了的文件。
- **轮转要跨平台可做，所以不 rename 打开中的文件**：Windows 上 rename 一个还开着的文件会失败，
  `freopen` 又没法「先关再开」地保住标准流。做法是**先流式拷贝再截断**：`fflush` → 把当前文件拷进
  `log.1`（上限就是 `maxKB`，几百 KB 的拷贝可忽略）→ `log.1 → log.2` 这些**已关闭**的文件平移
  （`keep` 决定保留份数）→ `freopen(path, "w", stderr)` 重开 → 写一行「已轮转」。
  这样没有平台分支、不需要空设备名，桩自检也能直接测。
- **轮转在写路径上判**（`fstat` 看真实大小），不是定时 tick：常驻应用不产生命令时也会轮转。
- **开关显式、失败要说**：`cj_bridge_set_log_file(path, max_kb, keep)` 返回 1/0；打不开就把
  `log file open failed: <path> (<errno>)` 打在**还在的** stderr 上并退回纯 stderr——不留
  「我说我开了」的假状态（与「发后即忘返回 0 ≠ 发送成功」同一形状的坑）。
  `cj_bridge_log_file()` 回读生效路径，供上报。
- **前端走同一条出口**：`cj_bridge_log_write(const char* line)` 追加一行（同样轮转），`log` 插件用它；
  页面 `window.onerror` 由此可并进同一份文件——单文件产物里「页面报错」原本也是看不见的。
- **不新设能力位，改上报路径**：落盘在两平台都无条件可用（纯 libc），一个恒为真的位没有信息量；
  真正要能回答的是「日志在哪」。`system:host` 增字段 `logFile`（空串＝未开）。
- **不做按级别分流的开关**：接管发生在 **fd 级**、对所有 stderr 写者一视同仁，要按级别过滤就得先给
  上百处调用点分类（core 43 处、平台侧另算、仓颉侧还有上百处），收益与改动量不成比例；本期的口径是
  「要静音就整份不开（不设 `CJ_TAURI_LOG` / 不调 `setLogFile`），要取证就整份开」。级别表达留给
  应用在自己那层做（业务日志自己带前缀，落盘后照样能 grep）。
- **框架侧**：`TauriApp.setLogFile(path, maxKB, keep)` 在 `start()` 之前调，空路径＝关；默认目录按
  `@When` 落平台惯例（Linux `$XDG_STATE_HOME` 或 `~/.local/state/cj-tauri/`，
  Windows `%LOCALAPPDATA%\cj-tauri\logs\`）；另有 `CJ_TAURI_LOG` / `CJ_TAURI_LOG_MAX_KB` /
  `CJ_TAURI_LOG_KEEP` 环境变量兜底——**免编译给已分发的 exe 开日志**，报障时一条命令就能拿到凭证。
- `log` 插件（`src/plugins/log/`）：`log:write` / `log:path` + 权限集 `log:default` + JS shim。
- 红线不变：零第三方依赖；轮转与开关全在 core，平台侧一行不改。

**判据**：

- **桩自检**（不依赖 SDK / 图形栈）：开文件后文件里含当轮日志；`max_kb` 调小后**确实出现 `log.1`**、
  `log.1 → log.2` 平移且 `keep` 上限被遵守（多轮后只有 `keep` 份）；`cj_bridge_log_file()` 回读与传入一致；
  打开失败（路径不可写）时返回 0 且 stderr 上一行 `log file open failed`；**关闭后文件不再增长**（对照组）。
- **框架单测**：纯决策函数（`logPathOrDefault` / `logEnvOr` / `logBudgetFromEnv` / `defaultLogPath`）、
  环境变量路径优先于平台惯例目录、`system:host` 带出 `logFile`。**真的开 fd 那一段单测碰不了**
  （子包调不了 `foreign func`，AGENTS §4 会在链接期报未定义符号），所以那条线由桩自检与实机两处承担。
- **实机（Linux/Xvfb）**：`scripts/e2e/test-linux-logfile.sh` 驱动 `scripts/e2e/fixture-app/` 探针，
  两轮各出一份证据（`linux-logfile.json` / `linux-logfile-rotate.json`）——轮一预算 4 MB 验落盘 / 并流 / 增长
  （接管行、C 桥调用行、探针页 `log:write` 行同在一份文件；行数两采样递增；多级父目录是按需建出来的）；
  轮二预算 1 KB keep 2 验轮转（`.1`/`.2` 出现、`.3` 不出现、轮转标记行之后仍有新行、填充行随档案平移）。
  **GUI 无控制台的等价场景**用比 `/dev/null` 更强的对照：应用起来前的启动段（壳那层继承来的 stderr）里
  **不该**有前端诊断行，而日志文件里必须有——一句话同时钉住「接管生效」与「没接管时它本来在哪」。
- Windows：本轮只保证 core 共享代码与桩自检通过；**没有实机就写没有**，不拿「同名实现」冒充跑通。

## 4. 架构红线（每期都适用）

- 平台差异只进 `@When` 与 `bridge_*.c`；core 侧放校验与白名单，平台侧放句柄与原生调用；
- 宿主级回调**按句柄路由**（`cj_on_*_fn` 首参 `struct cj_host *`），禁止再造静态单槽；
- 插件只声明「我提供什么」不自动放行；新能力位进 `HostCapabilities` 并在 `system:host` 如实上报；
- 零第三方依赖优先（termios 先例）：能用平台 API 自写的，不引外部库，MIT 口径不变；
- 每期交付都要有实机证据（`cj-tauri-verify` 的判据口径），跑不起来如实标注平台未验证。
