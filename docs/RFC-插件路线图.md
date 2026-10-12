# RFC-003：cj-tauri 插件路线图（对照 Tauri 2 官方插件清单）

> 状态：**规划稿**（2026-10-09）。对照 2026-10-09 抓取的 [Tauri 2 官方插件页](https://v2.tauri.app/plugin/)
> 与仓内实况逐项盘点，按「桌面常用度 + 落地成本」排期；体例对标 [RFC-002](RFC-菜单-托盘-拖放.md)。
> 排期不是承诺——每期开工前按当期实况复核一次，踩坑记录照旧沉淀进 `AGENTS.md` §4 与
> `skills/cj-tauri-troubleshoot`。

## 1. 现状（仓内已有）

| cj-tauri 已有 | 对标 Tauri | 备注 |
|---|---|---|
| `fs` 插件 | File System | **缺 scope**：页面能读任意可读文件（仓内已核实无路径限制），安全补齐见 §3.2 第 4 期 |
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
| **Clipboard（剪贴板）** | tauri-plugin-clipboard | 最基础的桌面能力 | C 桥导出 `cj_bridge_clipboard_{set_text,get_text}`；Linux `gtk_clipboard_get/set(GDK_SELECTION_CLIPBOARD)`（UI 线程），Windows `OpenClipboard`/`SetClipboardData(CF_UNICODETEXT)` |
| **Notifications** | tauri-plugin-notification | 桌面常用 | Linux `notify-notification`（libnotify）或 `org.freedesktop.Notifications` D-Bus；Windows toast（`Windows.UI.Notifications` 或 shell API）——**新增能力位** `CJ_CAP_NOTIFICATION` |

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

### 第 1 期：托盘 + 文件拖入（RFC-002 既定，优先于一切新插件）

**不是新插件，是核心能力位收口**——`system:host` 里 `tray=0 / dragDrop=0` 挂了很久，对桌面应用常用度高于
上表多数插件。按 RFC-002 §7 落地；前置：`native/build_win.bat` 补 `-lshell32`（托盘要 `Shell_NotifyIconW`）。

### 第 2 期：Store（纯仓颉，最快见效）

无 C 桥改动。判据：单测覆盖读写删/并发写/损坏文件回落；`examples/music` 改用它（手搓 JSON 删除）；
两平台 `cjpm build` 过。

### 第 3 期：Clipboard + Notifications（一组新 C 桥导出）

照 menu 的分层样板：`WebViewHost` 加方法 → 两平台实现 → core 加同名导出 + 能力位。
判据：`system:host` 如实上报新能力位；Linux/Windows 各一条实机证据（剪贴板写后系统其它程序能读到、
通知真弹出）；能力清单不声明即拒（最小权限不破）。

### 第 4 期：fs scope（安全补齐，趁插件生态还小）

判据：默认清单行为不破坏（旧清单全量 + stderr 提示）；新 scope 语法有单测与未授权对照组。

### 第 5 期起：Global Shortcut / Window State / Single Instance / Logging / HTTP 白名单

按需求拉取排序；每项开工前在本文件补「实现要点 + 判据」两行，别只留名字。

## 4. 架构红线（每期都适用）

- 平台差异只进 `@When` 与 `bridge_*.c`；core 侧放校验与白名单，平台侧放句柄与原生调用；
- 宿主级回调**按句柄路由**（`cj_on_*_fn` 首参 `struct cj_host *`），禁止再造静态单槽；
- 插件只声明「我提供什么」不自动放行；新能力位进 `HostCapabilities` 并在 `system:host` 如实上报；
- 零第三方依赖优先（termios 先例）：能用平台 API 自写的，不引外部库，MIT 口径不变；
- 每期交付都要有实机证据（`cj-tauri-verify` 的判据口径），跑不起来如实标注平台未验证。
