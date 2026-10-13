# cj-tauri：仓颉版 Tauri

[English](README_EN.md) | 中文

用华为仓颉语言实现的轻量混合开发框架——对标 Tauri（Rust + 系统 WebView）的三件套架构：
**WebView 宿主 + IPC 双向桥 + 能力安全模型**。前端用任意 Web 技术，后端用仓颉静态编译，
产物是不带 Chromium 的原生桌面应用。Linux（WebKitGTK）与 Windows（WebView2）均已实机跑通，鸿蒙 ArkWeb 预留。

- 仓库：**[AtomGit](https://atomgit.com/qq8864/cj-tauri)** ｜ [GitHub](https://github.com/yangyongzhen/cj-tauri)（双托管，一次 push 同步两仓）
- 版本：**0.8.0**（[CHANGELOG](CHANGELOG.md)）· 许可证 MIT
- npm：`npx cj-tauri create myapp`（[npmjs.com/cj-tauri](https://www.npmjs.com/package/cj-tauri)）
- 官网：**[yangyongzhen.github.io/cj-tauri](https://yangyongzhen.github.io/cj-tauri/)**（中英双语，
  源文件在 `website/`，`bash scripts/site-check.sh` 自检；托管在 GitHub Pages 是本项目唯一「非 AtomGit 的对外链接」）

## 运行效果

![cj-tauri hello 示例运行效果](docs/images/cj_tauri.png)

*hello 示例：深色卡片 UI，输入名字点 greet 触发 invoke，底部实时显示仓颉后端推送的 tick 事件。*

用 cj-tauri 实现的 **Modbus 调试工具**（`examples/modbus-poll`，对标 Modbus Poll 并补齐其痛点）：

![Modbus Poll (cj-tauri) 主界面](examples/modbus-poll/images/modbus-poll-main.png)

*多面板并行监控 + 底部报文监视逐帧滚动 Tx/Rx 十六进制。详见[它的 README](examples/modbus-poll/README.md)。*

更多示例截图见下文[示例一览](#示例一览)。

## 为什么是 cj-tauri

- **静态编译的后端**：仓颉无 VM、无 GC 抖动顾虑，协议层两百行可审计；
- **零 Chromium 捆绑**：直接用系统 WebView（Linux WebKitGTK / Windows WebView2），单示例产物 4~10MB；
- **能力安全模型**：`capabilities/` 白名单默认最小权限，未声明命令一律拒绝，与宿主实现解耦；
- **插件体系**：`fs` / `dialog` / `shell` / `serial` / `store` / `clipboard` / `notification` / `menu` / `mqtt` / `redis` 官方插件，
  一行接入，权限（命令级白名单 + 命名权限集 + 路径 scope）仍由清单决定；
- **全链路可验证**：桥 stderr 即时取证 + 页面自检断言回传，每个示例都能无人值守自检；
- **配套脚手架**：`cj-tauri create/dev/build/run/info/doctor`，能力清单、GUI 子系统、跨平台链接的坑框架替你踩完；
  `doctor` 逐行给「缺了什么、怎么补」，新机器第一件事跑它。

## 快速开始

### 方式一：npm（跨平台，推荐）

```bash
npx cj-tauri create myapp          # 免安装，直接跑
cd myapp
npx cj-tauri dev                   # 接管 Vite dev server（Vue/React 模板），HMR 在窗口内生效
```

前置条件：[仓颉 SDK](docs/使用文档.md#2-环境准备)（1.0.5+，验证版本 1.2.0）+ stdx；
Windows 另需 mingw gcc 与 WebView2 Runtime（Win11 自带），Linux 需 `libwebkit2gtk-4.1-dev`。
找不到 SDK 时 CLI 会给出安装说明与 `CANGJIE_HOME` 示例，而不是一句 `command not found`。

### 方式二：直接下载单文件工具（免安装、免 SDK）

仓库随版本分发静态链接的单文件 Windows 工具（点击下载）：

| 工具 | 说明 |
|---|---|
| [modbus-poll.exe](examples/modbus-poll/dist-single/modbus-poll.exe)（5.6MB） | Modbus TCP/RTU 调试工具，[中文说明](examples/modbus-poll/README.md) |
| [movie.exe](examples/movie/dist-single/movie.exe)（9.5MB） | 观影应用（数据取自第三方公开接口，[仅供学习研究](examples/movie/README.md#用途与免责声明)） |

体积、依赖与冷启动都是**实测**的：四份产物 5.5–9.5 MB，PE 导入表里只有 Windows 系统 DLL
（没有任何第三方运行时），双击不弹控制台。口径与复核方式见 [`docs/分发形态实测.md`](docs/分发形态实测.md)。

### 方式三：源码构建

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git && cd cj-tauri
native/build_win.bat               # Windows：编译 C 桥（Linux 为 native/build_linux.sh）

cli\cj-tauri.bat info              # 自检：框架/项目/stdx/SDK/cjpm/桥 是否都解析得到
cli\cj-tauri.bat create myapp && cd myapp
..\cli\cj-tauri.bat dev            # Linux/macOS 用 cli/cj-tauri.sh
```

运行仓内示例（以 hello 为例）：`native\build_win.bat` → `cd examples\hello && cjpm build` → 根目录 `run_win.bat`。

## 示例一览

`examples/` 下二十二个可直接运行的示例，`cli/templates/` 有三个脚手架模板（app / app-vue / app-react）。
各示例的完整说明与自检方式见各自目录的 README。

**业务向工具与应用**：

| 示例 | 一句话 |
|---|---|
| [modbus-poll](examples/modbus-poll) | **Modbus TCP/RTU 调试工具**：多面板并行监控（一屏任意多组）、读写 FC 01-04/05/06/15/16、报文监视、数据记录 CSV、字节序选项、内置从站自检闭环——对标 Modbus Poll 并补齐其痛点 |
| [mqtt-client](examples/mqtt-client) | **MQTT 调试台**：连 broker / 订阅 / 发布 / 报文流时间线（按 `seq` 去重、可过滤暂停），协议由框架插件 `mqtt` 纯仓颉实现；示例自带 mock broker 对端，Linux 实机 E2E 27 条断言两侧对账 |
| [redis-client](examples/redis-client) | **Redis 调试台**：连接 / 键空间浏览（SCAN 游标分页 + MATCH + TYPE 过滤、每行带类型与 TTL）/ 类型化取值与写值 / 发布订阅消息流 / INFO·DBSIZE·SLOWLOG，协议由框架插件 `redis` 纯仓颉实现（RESP2 双 socket）；示例自带 mock redis 对端，Linux 实机 E2E 47 条断言两侧对账 |
| [markdown-notes](examples/markdown-notes) | **Markdown 笔记**：左文件树 / 中编辑 / 右实时预览，工作区 = `notes/` 目录；自写 Markdown 子集渲染器（不引第三方库、不拼 `innerHTML`，正文不构成注入点）；**路径 scope 的真实用法**——清单把 `fs` 钉在工作区内，越界与 `..` 绕行都由共享层拒，Linux 实机 E2E 25 条断言两侧对账 |
| [http-client](examples/http-client) | **HTTP API 客户端**（Postman 那一类）：左拼请求 / 中看响应（原文 · JSON 树 · 响应头）/ 右管集合与历史，**网络请求全由仓颉侧直发**（页面零 `fetch`，TLS 走系统证书库不关校验）；白名单与响应体上限在仓颉侧兜底，越界读由路径 scope 拒；示例自带 mock 对端，Linux 实机 E2E 55 条断言两侧对账（含截断三侧对账） |
| [sqlite-browser](examples/sqlite-browser) | **SQLite 数据库浏览器**：库对象 / 数据分页网格（排序、类型上色、超长单元格截断标记）/ SQL 调试台（只读与可写两个按钮）；**仓颉 FFI 直连系统 `libsqlite3`**（仓库首例，不经 C 桥），命令放行与路径 scope 两层、只读走内核级连接、`ATTACH` 由 authorizer 按语句拒；示例自带夹具对端，Linux 实机 E2E 49 条断言（含**进程外**只读复查页面写入的那一行） |
| [serial-assistant](examples/serial-assistant) | **串口调试助手**：参数面板、TX/RX 分色收发日志、定时发送、探针自检 |
| [serial-waveform](examples/serial-waveform) | **串口实时波形示波器**：`serial` 插件 + canvas 双缓冲自绘，行协议 `<序号>,<值>`；400 Hz 样本流下页面自算速率/上穿/丢帧，实机取证见该目录 README |
| [movie](examples/movie) | **观影应用**：榜单/搜索/详情/播放，数据全由仓颉侧 HTTP 取回，前端零 fetch |
| [music](examples/music) | **音乐播放器**：榜单/歌单/收藏/分享 + 同步歌词 + 4 套主题色，封面由宿主带 Referer 取回并缩略 |
| [typing-poem](examples/typing-poem) | **古诗词打字练习**（小学生向）：108 首诗逐字拼音，three.js 3D 卡面，连对升调、世界随输入变化 |

**框架能力演示**：

| 示例 | 演示什么 |
|---|---|
| [hello](examples/hello) | 最小闭环：`invoke` 命令 + 事件推送 + 越权拒绝 |
| [todo_check](examples/todo_check) / [vue_todo](examples/vue_todo) | 待办清单（零 Node 版与 Vue 3 + Vite 工程版，同一套命令） |
| [plugin-fs](examples/plugin-fs) / [plugin-dialog](examples/plugin-dialog) / [plugin-shell](examples/plugin-shell) / [plugin-serial](examples/plugin-serial) | 官方插件四件套：文件读写（含**路径 scope 对照**）/ 原生对话框 / 打开链接与子进程 / 串口，各带权限对照 |
| 框架内置 `store` 插件 | 持久化键值（RFC-003 第 2 期）：任意 JSON、原子写（tmp + rename）、命名集 `store:readonly`/`store:default`；`examples/music` 已迁移到它 |
| 框架内置 `clipboard` / `notification` 插件 | 系统剪贴板读写 / 系统通知（RFC-003 第 3 期）：Linux 实机取证（外部回读剪贴板、会话总线上实收通知），Windows 侧同名桩且能力位如实上报 |
| [menu](examples/menu) | 原生菜单栏（Windows + Linux 实机点选证据） |
| [ipc-bench](examples/ipc-bench) | IPC 性能探针：往返延迟 / 吞吐 / payload 放大 / 事件成本 |

部分示例截图（全部为实机截图，完整集见各示例 README）：

| movie 观影 | music 播放中 |
|---|---|
| ![movie 观影应用](docs/images/example-movie.png) | ![music 播放中](docs/images/example-music-playing.png) |
| ![typing-poem 打字练习](docs/images/example-typing-poem-typing.png) | ![串口实时波形示波器（serial-waveform）](docs/images/example-serial-waveform.png) |

## 架构

![cj-tauri 架构图：前端桥 → IPC 消息桥 → 能力安全模型 → 内置 / 插件命令 → WebView 宿主（Linux / Windows / 鸿蒙）→ 共享 C 层](docs/images/architecture.png)

文字版（同上，便于搜索与复制）：

```
前端 (HTML/CSS/JS)  ← window.__CJ_TAURI__.invoke/listen/emit（注入桥接 JS，对标 @tauri-apps/api）
        │  JSON over postMessage（Linux: WebKitUserContentManager；Windows: chrome.webview.postMessage）
        ▼
IPC 消息桥（src/ipc_hub.cj）← 命令注册/分发/校验（对标 tauri IPC；命令在 worker 线程异步执行）
        ▼
能力安全模型（src/capability.cj）← 命令/事件白名单，默认最小权限（对标 capability）
        ▼
内置命令（src/api_system.cj）：system:version / ping / echo / devtools
        ▼
WebView 宿主（src/host.cj 抽象 + 各平台实现）
   ├─ Linux: webkit2gtk-4.1（src/host_webkit.cj + native/bridge_linux.c，C 桥在原生 pthread 运行）
   ├─ Windows: WebView2（src/host_webview2.cj + native/bridge_win.c，Win32 消息循环在宿主线程）
   └─ 鸿蒙: ArkWeb（架构预留，条件编译位）
```

开发一个应用只需三步（对标 tauri command / Builder / capabilities）：

```cangjie
// 1. 实现命令
public class GreetCommand <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        return JsonString("Hello, ${argString(args, "name", "world")}!")
    }
}

main(): Int64 {
    // 2. 装配：窗口 + 注册命令；3. 启动（能力清单由 run() 自动扫描 capabilities/）
    let app = TauriApp()
        .window(WindowConfig("hello", 1000, 700))
        .register("greet", GreetCommand())
    app.run(html)
    return 0
}
```

```js
// 前端侧：桥由宿主在页面脚本之前注入（稳妥做法是先等桥出现，模板里的 waitForBridge 即范例）
window.__CJ_TAURI__.invoke('greet', { name: '仓颉' }).then(d => console.log(d));
window.__CJ_TAURI__.listen('tick', p => console.log(p));
```

## 文档索引

| 文档 | 内容 |
|---|---|
| [使用文档](docs/使用文档.md) | 环境准备 → 创建应用 → 开发 → 排障（权威上手文档） |
| [前端入门教程](docs/前端入门教程.md) | 零基础把前端跑起来：目录约定 → 桥 API → 事件 → 能力清单 → 完整实战 |
| [插件体系教程](docs/插件体系教程.md) | 插件是干嘛的 → 一行接入官方插件 → 自己写一个 |
| [IPC 通信机制](docs/IPC-通信机制.md) | 协议报文 → 完整时序 → 实测性能（与 WebSocket/裸 TCP 对照） |
| [movie 实战](docs/cj-tauri-介绍与movie实战.md) / [打字游戏实战](docs/仓颉版Tauri-打字游戏实战.md) / [音乐播放器实战](docs/仓颉版Tauri-音乐播放器实战.md) | 三个业务示例的逐块拆解 |
| [Modbus 工具实战](docs/仓颉版Modbus调试工具-介绍与实战.md) | 脚手架用法 + Modbus 工具实现 + 与 Modbus Poll 对比 |
| [技术方案](docs/技术方案.md) / [踩坑与实施记录](docs/踩坑与实施记录.md) | 可行性论证 / 开发全程踩坑 |
| [设计决策记录](docs/设计决策记录.md) | 为什么长这样：同进程桥、能力分级、scope 语义等 12 条决策的理由、代价与复评触发条件 |
| [需求追踪矩阵](docs/需求追踪.md) | 每个能力做到哪了：五级状态 + 可复核证据 |
| [CHANGELOG](CHANGELOG.md) / [AGENTS.md](AGENTS.md) / [CONTRIBUTING](CONTRIBUTING.md) / [README.OpenSource](README.OpenSource) | 变更记录 / 开发规范 / 贡献流程 / 依赖与许可 |

延伸阅读（CSDN）：[用仓颉写桌面应用：一个类 Tauri 框架的实现与使用](https://blog.csdn.net/qq8864/article/details/166944044)。

## 用 AtomCode 的 AI 助手开发（skills）

本仓把开发工作流、实机取证、踩坑速查与回贡献流程沉淀成了 **AtomCode skills**（已 marketplace 化）：

```bash
atomcode plugin marketplace add https://atomgit.com/qq8864/cj-tauri.git
atomcode plugin install cj-tauri-skills@cj-tauri-skills
```

五个 skill：`cj-tauri-env`（环境检测 + 工具链安装指引）、`cj-tauri-app-dev`（起工程/三处联动/门禁）、
`cj-tauri-verify`（构建→实机→stderr 取证→断言截图）、`cj-tauri-troubleshoot`（实测坑速查）、
`cj-tauri-contribute`（问题→issue、修法→PR）。详见 [skills/README.md](skills/README.md)。

## 现状与路线

- ✅ Linux（WebKitGTK）与 Windows（WebView2）双平台宿主，IPC/能力模型完全共用
- ✅ 脚手架 CLI（仓颉原生）：`create / dev / build / run / info`，npm 包跨平台分发
- ✅ 插件体系 v1 + 官方插件（fs / dialog / shell / serial / store / clipboard / notification / menu）；
  命令级白名单、命名权限集、**路径 scope**（RFC-003 第 4 期）三层闸门，Windows + Linux 实机证据
- ✅ 命令异步分发（慢命令不冻窗口）、多窗口按 label 路由、插件清单 `info --json` 机器可读
- ✅ 工程化：189 个单元测试 + 免 SDK 静态门禁（CI 跑的就是它）+ 示例无人值守自检
- 🔜 鸿蒙 ArkWeb 后端（架构预留）、macOS WebView、更多官方插件（托盘 / 全局快捷键）

## 仓库与推送

同一份代码双托管，`origin` 挂两条 pushurl，**一次 `git push` 同时推 AtomGit + GitHub**：

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git          # AtomGit（国内直连推荐）
git clone https://github.com/yangyongzhen/cj-tauri.git     # GitHub
git ls-remote origin main && git ls-remote github main     # 核对两仓 SHA 一致
```

## License

[MIT](LICENSE) © 2026 yangyongzhen
