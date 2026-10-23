<div align="center">

# cj-tauri · 仓颉版 Tauri

**用华为仓颉语言实现的桌面应用混合开发框架 —— 仓颉静态编译后端 + 系统 WebView 前端，产物不带 Chromium、几 MB 级。**

[![Platform](https://img.shields.io/badge/%E5%B9%B3%E5%8F%B0-Windows%20%7C%20Linux%20%7C%20%E9%B8%BF%E8%92%99%20PC-blue)](#示例一览)
[![Cangjie](https://img.shields.io/badge/%E4%BB%93%E9%A2%89-SDK%201.2.0%2B-ff69b4)](https://cangjie-lang.cn)
[![License](https://img.shields.io/badge/%E8%AE%B8%E5%8F%AF%E8%AF%81-MIT-green)](./LICENSE)
[![QQ 群](https://img.shields.io/badge/QQ%E7%BE%A4-92381027-red)](#仓库与推送)

前端用任意 Web 技术，后端是可审计的静态二进制：IPC 双向桥、能力白名单安全模型、14 个官方插件、
28 个可运行示例。Linux（WebKitGTK）、Windows（WebView2）与鸿蒙 PC（ArkWeb）均已实机跑通。

> 📖 **在线官网**：<https://yangyongzhen.github.io/cj-tauri/> —— 中英双语，特性、24 屏实机截图与文档入口。

> 💬 **QQ 技术交流群**：**92381027** —— 使用问题、功能建议、插件与踩坑交流都欢迎。

[运行效果](#运行效果) · [快速开始](#快速开始) · [为什么是 cj-tauri](#为什么是-cj-tauri) · [示例一览](#示例一览) · [架构](#架构) · [文档](#文档索引)

</div>

## 30 秒上手

**最快路径：npm 脚手架，三行命令出第一个应用**（前置：[仓颉 SDK](docs/使用文档.md#2-环境准备) 1.0.5+ 与 stdx；Windows 另需 mingw gcc 与 WebView2 Runtime（Win11 自带），Linux 需 `libwebkit2gtk-4.1-dev`）：

```bash
npx cj-tauri create myapp          # 免安装，直接跑
cd myapp
npx cj-tauri dev                   # 接管 Vite dev server（Vue/React 模板），HMR 在窗口内生效
```

不想装 SDK？仓库随版本分发**八份静态链接的单文件 Windows 工具**（4.69–9.79 MB，免安装、
双击即用，PE 导入表全部实测过）——[直接下载](#方式二直接下载单文件工具免安装免-sdk)。

![cj-tauri hello 示例运行效果](docs/images/cj_tauri.png)

*hello 示例：深色卡片 UI，输入名字点 greet 触发 invoke，底部实时显示仓颉后端推送的 tick 事件。*

## 运行效果

用 cj-tauri 实现的 **AI 对话客户端**（`examples/ai-chat`，聊天直连服务商 / Agent 接本机 cjh 两种模式）：

![ai-chat 模式切换](docs/images/ai-chat-mode-switch.gif)

*聊天（直连服务商）→ Agent（接本机 cjh）一键切换：侧栏改口、四面板就位、徽章显示 cjh 侧真实模型。*

![ai-chat 缺 cjh 引导](docs/images/ai-chat-guide.gif)

*缺 cjh 时切 Agent 出引导卡：一键部署（用仓库自带安装包，本地 SHA256 校验后解包启动，不走网络）；
失败回落第 2/3 步的手动安装——按平台给产物名与下载地址，选一次可执行文件当场拉起并记住路径。*

用 cj-tauri 实现的 **Modbus 调试工具**（`examples/modbus-poll`，对标 Modbus Poll 并补齐其痛点）：

![Modbus Poll (cj-tauri) 主界面](examples/modbus-poll/images/modbus-poll-main.png)

*多面板并行监控 + 底部报文监视逐帧滚动 Tx/Rx 十六进制。详见[它的 README](examples/modbus-poll/README.md)。*

用 cj-tauri 实现的 **鸿蒙 PC 应用**（`examples/ohos/ohos-music` 与 `ohos-movie` —— 仓颉后端 + ArkWeb 前端，
跑在 HarmonyOS PC 的 2in1 桌面形态里，页面代码与桌面版同一份）：

![仓颉爱音乐（鸿蒙 PC 实机）](docs/images/example-ohos-music.jpg)

*`ohos-music` 实机：窗口尺寸交给系统（cj-tauri 不 resize、不挪位），标题栏是鸿蒙 PC 的原生窗口装饰。*

![仓颉观影（鸿蒙 PC 实机）](docs/images/example-ohos-movie.jpg)

*`ohos-movie` 实机：封面经宿主侧 `movie:image` 带 Referer / UA 取回——页面直连图床会被防盗链挡成「200 + 0 字节」。*

![cj-tauri create --template ohos 生成物（鸿蒙 PC 实机）](docs/images/example-ohos-template.jpg)

*`cj-tauri create --template ohos` 生成的统一工程（单业务代码 + 清单），`sync ohos` 派生的 `build-hap.sh` 编出可签安装的 hap，greet / `system:version` / 后端事件推送三条链路开箱可点。*

更多示例截图见下文[示例一览](#示例一览)。

## 为什么是 cj-tauri

- **静态编译的后端**：仓颉无 VM、无 GC 抖动顾虑，协议层两百行可审计；
- **零 Chromium 捆绑**：直接用系统 WebView（Linux WebKitGTK / Windows WebView2），单示例产物 4~10MB；
- **能力安全模型**：`capabilities/` 白名单默认最小权限，未声明命令一律拒绝，与宿主实现解耦；
- **插件体系**：`fs` / `dialog` / `shell` / `serial` / `store` / `clipboard` / `notification` / `menu` / `mqtt` / `redis` / `log` / `http` / `ws` / `sqlite` 十四个官方插件，
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

鸿蒙 PC（2in1）与桌面共用同一份业务代码：`create --template ohos` 生成的仍是**统一工程**
（`cj-tauri.toml` 清单 + 业务 static 包 + `assets/`），hap 骨架由 `sync` 派生到 `targets/ohos/`，
构建入口是那里面自带的 `build-hap.sh`（**工程根没有它**）：

```bash
npx cj-tauri create myohosapp --template ohos --bundle com.example.myohosapp --label "我的应用"
cd myohosapp
npx cj-tauri sync ohos             # 按清单派生 targets/ohos（桌面端同理：sync desktop）
export CANGJIE_STDX_OHOS=<鸿蒙版 stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx
cd targets/ohos && npx cj-tauri run
# 等价：bash build-hap.sh --install（编 hap → 装到设备 → 拉起，需先在 DevEco 配好自动签名）
```

前置条件见[30 秒上手](#30-秒上手)。找不到 SDK 时 CLI 会给出安装说明与 `CANGJIE_HOME` 示例，
而不是一句 `command not found`。同目录还有 `cj-tauri build/run/info/doctor`：
`doctor` 逐行给「缺了什么、怎么补」，新机器第一件事跑它。

### 方式二：直接下载单文件工具（免安装、免 SDK）

仓库随版本分发静态链接的单文件 Windows 工具（点击下载，九份产物全部实测过导入表）：

**调试与工具类**：

| 工具 | 说明 |
|---|---|
| [cj-link.exe](examples/cj-link/dist-single/cj-link.exe)（5.48MB） | 串口/网络二合一调试助手：串口 + TCP 客户端/服务器 + UDP 共用收发日志，HEX/ASCII 双显、发送队列、CRC 计算、定时发送，[中文说明](examples/cj-link/README.md) |
| [modbus-poll.exe](examples/modbus-poll/dist-single/modbus-poll.exe)（5.59MB） | Modbus TCP/RTU 调试工具：多面板并行监控、FC 01-04/05/06/15/16、报文监视、CSV 记录，[中文说明](examples/modbus-poll/README.md) |
| [serial-waveform.exe](examples/serial-waveform/dist-single/serial-waveform.exe)（4.69MB） | 串口实时波形示波器：400 Hz 样本流下页面自算速率/上穿/丢帧，[中文说明](examples/serial-waveform/README.md) |

**效率与学习类**：

| 工具 | 说明 |
|---|---|
| [markdown-notes.exe](examples/markdown-notes/dist-single/markdown-notes.exe)（4.78MB） | Markdown 笔记：文件树 / 编辑 / 实时预览三态切换，marked + Highlight.js 内联，[中文说明](examples/markdown-notes/README.md) |
| [leetcode-gui.exe](examples/leetcode-gui/dist-single/leetcode-gui.exe)（9.79MB） | 仓颉力扣：题库 + 编辑器 + 判题终端，判题器就是 `cjc`，[中文说明](examples/leetcode-gui/README.md) |

**示例应用类**：

| 应用 | 说明 |
|---|---|
| [music.exe](examples/music/dist-single/music.exe)（9.50MB） | 音乐播放器：榜单/歌单/收藏 + 同步歌词 + 4 套主题色，[中文说明](examples/music/README.md) |
| [movie.exe](examples/movie/dist-single/movie.exe)（9.42MB） | 观影应用（数据取自第三方公开接口，[仅供学习研究](examples/movie/README.md#用途与免责声明)） |
| [typing-poem.exe](examples/typing-poem/dist-single/typing-poem.exe)（5.50MB） | 古诗词打字练习（小学生向）：three.js 3D 卡面，[中文说明](examples/typing-poem/README.md) |
| [cjnote.exe](examples/cjnote/dist-single/cjnote.exe)（34.1MB） | AI 原生 Markdown 笔记：三栏布局 + 原生菜单栏 + **内嵌 cjh AI 后端**（随包 release 到 `%LOCALAPPDATA%`、静默拉起、退出收尾）；体积大是因为 cjh 与 4 个运行时 DLL 一起嵌进了 exe，[中文说明](examples/cjnote/README.md) |

体积、依赖与冷启动都是**实测**的：九份产物 4.69–34.1 MB（`cjnote` 那份含内嵌 AI 后端，其余 4.69–9.79 MB），
PE 导入表里只有 Windows 系统 DLL
（没有任何第三方运行时，非系统 DLL 一列全是 0），双击不弹控制台
（`Subsystem 00000002 (Windows GUI)`）。口径与复核方式见 [`docs/分发形态实测.md`](docs/分发形态实测.md)，
一条命令复核：`bash scripts/dist-report.sh`。

### 方式三：源码构建

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git && cd cj-tauri
native/build_win.bat               # Windows：编译 C 桥（Linux 为 native/build_linux.sh）

cli\cj-tauri.bat info              # 自检：框架/项目/stdx/SDK/cjpm/桥 是否都解析得到
cli\cj-tauri.bat create myapp && cd myapp
..\cli\cj-tauri.bat dev            # Linux/macOS 用 cli/cj-tauri.sh
```

> 源码仓内的 `cjpm.toml` 用 `${CANGJIE_STDX}` 引用 stdx 动态库目录（机器无关），
> 构建前需把这个环境变量设到 `<stdx>/<三元组>/dynamic/stdx`（如 Linux 的
> `$HOME/.cangjie/stdx/*/dynamic/stdx`、Windows 的
> `D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx`）。`cj-tauri create` 生成的
> 工程不依赖它（脚手架会把探测到的路径写死进生成的 `cjpm.toml`）。

运行仓内示例（以 hello 为例）：`native\build_win.bat` → `cd examples\hello && cjpm build` → 根目录 `run_win.bat`。

## 示例一览

`examples/` 下二十七个可直接运行的示例，`cli/templates/` 有三个脚手架模板
（app / app-vue / app-react，均为 `cj-tauri.toml` 清单 + 业务 static 包 + `assets/` 的新形态，
骨架由 `cj-tauri sync` 派生；鸿蒙工程用 `create --template ohos` 生成同款统一工程）。
各示例的完整说明与自检方式见各自目录的 README。

**业务向工具与应用**：

| 示例 | 一句话 |
|---|---|
| [modbus-poll](examples/modbus-poll) | **Modbus TCP/RTU 调试工具**：多面板并行监控（一屏任意多组）、读写 FC 01-04/05/06/15/16、报文监视、数据记录 CSV、字节序选项、内置从站自检闭环——对标 Modbus Poll 并补齐其痛点 |
| [mqtt-client](examples/mqtt-client) | **MQTT 调试台**：连 broker / 订阅 / 发布 / 报文流时间线（按 `seq` 去重、可过滤暂停），协议由框架插件 `mqtt` 纯仓颉实现；示例自带 mock broker 对端，Linux 实机 E2E 27 条断言两侧对账 |
| [redis-client](examples/redis-client) | **Redis 调试台**：连接 / 键空间浏览（SCAN 游标分页 + MATCH + TYPE 过滤、每行带类型与 TTL）/ 类型化取值与写值 / 发布订阅消息流 / INFO·DBSIZE·SLOWLOG，协议由框架插件 `redis` 纯仓颉实现（RESP2 双 socket）；示例自带 mock redis 对端，Linux 实机 E2E 47 条断言两侧对账 |
| [markdown-notes](examples/markdown-notes) | **Markdown 笔记**：左文件树 / 中编辑 / 右实时预览（marked + Highlight.js 渲染，代码高亮三种主题勾选切换），工作区 = `notes/` 目录；视图三态（仅编辑 / 分屏 / 仅预览，`Ctrl+1/2/3`）与文件操作全走原生菜单；**路径 scope 的真实用法**——清单把 `fs` 钉在工作区内，越界与 `..` 绕行都由共享层拒，Linux 实机 E2E 25 条断言两侧对账 |
| [cjnote](examples/cjnote) | **AI 原生 Markdown 笔记**：三栏（笔记库 / CodeMirror 编辑 / AI 助手），笔记是 `notes/` 下的纯 `.md`——存取走自研 `NoteStore`（**不引 fs 插件**，路径穿越在入口挡掉）；原生菜单（文件 / 视图 / 帮助）+ `setTitlebarSubtitle` 副标题（平台没这块能力位时自动退回页面顶栏）；视图三态与界面主题**与原生菜单勾选双向同步**；`Ctrl+O` 打开库外文件只进内存、首次保存才落成库里的新笔记，**绝不静默改写磁盘原文件**；**AI 后端只有 cjh 一条路**——⚙ 整页设置把地址 / 密钥 / 模型 / 协议写进 cjh，白名单字段**即时推给运行中的实例**（端口上是别人拉起的 cjh 也照样生效，协议改动才需重启；密钥框留空即不修改），设置页带「测试连通」按钮（用表单里的值发一条帧级覆盖的最小对话，只验连通、不改配置）；随包 cjh 预编译产物让 AI 开箱可用；页面零 `fetch`，网络只走 cjh 的 ws；页面自检 90 项 |
| [http-client](examples/http-client) | **HTTP API 客户端**（Postman 那一类）：左拼请求 / 中看响应（原文 · JSON 树 · 响应头）/ 右管集合与历史，**网络请求全由仓颉侧直发**（页面零 `fetch`，TLS 走系统证书库不关校验）；白名单与响应体上限在仓颉侧兜底，越界读由路径 scope 拒；示例自带 mock 对端，Linux 实机 E2E 55 条断言两侧对账（含截断三侧对账） |
| [sqlite-browser](examples/sqlite-browser) | **SQLite 数据库浏览器**：库对象 / 数据分页网格（排序、类型上色、超长单元格截断标记）/ SQL 调试台（只读与可写两个按钮）；**仓颉 FFI 直连系统 `libsqlite3`**（仓库首例，不经 C 桥），命令放行与路径 scope 两层、只读走内核级连接、`ATTACH` 由 authorizer 按语句拒；示例自带夹具对端，Linux 实机 E2E 49 条断言（含**进程外**只读复查页面写入的那一行） |
| [serial-assistant](examples/serial-assistant) | **串口调试助手**：参数面板、TX/RX 分色收发日志、定时发送、探针自检 |
| [cj-link](examples/cj-link) | **串口/网络二合一调试助手**：串口（serial 插件）+ 网络三模式（TCP 客户端 / TCP 服务器多客户端广播 / UDP，`std.net`）共用收发日志，HEX/ASCII 双显、发送队列、校验计算（CRC16-Modbus/CCITT 等，`link:crcCalc`）、定时发送（周期可调）、面板配置持久化（store 插件）；对端由 pty echo + TCP/UDP echo 扮演，Linux 实机 run.sh 33 条断言两侧对账 |
| [ai-chat](examples/ai-chat) | **AI 对话客户端（cjh 桌面端）**：聊天（直连服务商，流式 Markdown）/ Agent（接本机 [cjh](https://atomgit.com/qq8864/cjh)：会话/技能/MCP/文件四面板 + 审批 + 模型透传）一键切换；缺 cjh 时给**能走完的引导**（按平台给下载产物、选一次可执行文件当场拉起并记住）；cjh 预编译包随仓 vendored，`scripts/pack-linux.sh` 出便携包 |
| [clipboard-history](examples/clipboard-history) | **剪贴板历史管理器**：**托盘** + **全局快捷键**两个能力位的首个消费者，**Windows（`Shell_NotifyIconW` / `RegisterHotKey`）与 Linux（libayatana-appindicator3 可选编译 / X11 grab）都已跑通**——托盘菜单（显示面板 / 清空 / 退出）与 `Ctrl+Alt+V` 唤回全走框架事件（`tray:click` / `hotkey:press`），**「最小化到托盘」走宿主基元**（`WindowConfig.minimizeToTray`，平台上没装托盘就如实降级为普通最小化并打 stderr）；历史捕获是前端 500ms 轮询 `clipboard:read` 去重（零新命令），点击条目 `clipboard:write` 回写并以 `xclip -o`（Linux）/ 系统剪贴板读回（Windows）对账；Linux 实机 E2E 15/15，Windows 侧另有实机链「最小化 → 窗口隐藏 → 快捷键唤回」 |
| [serial-waveform](examples/serial-waveform) | **串口实时波形示波器**：`serial` 插件 + canvas 双缓冲自绘，行协议 `<序号>,<值>`；400 Hz 样本流下页面自算速率/上穿/丢帧，实机取证见该目录 README |
| [movie](examples/movie) | **观影应用**：榜单/搜索/详情/播放，数据全由仓颉侧 HTTP 取回，前端零 fetch |
| [music](examples/music) | **音乐播放器**：榜单/歌单/收藏/分享 + 同步歌词 + 4 套主题色，封面由宿主带 Referer 取回并缩略 |
| [typing-poem](examples/typing-poem) | **古诗词打字练习**（小学生向）：108 首诗逐字拼音，three.js 3D 卡面，连对升调、世界随输入变化 |
| [leetcode-gui](examples/leetcode-gui) | **桌面版算法练习工具**：左侧按分类分组的题库 / 中间题面 + 仓颉代码编辑器 / 下方判题终端——点「运行」把代码交给 **cjc 编译**再逐个用例判定，结果带期望值与耗时回投，全程离线 |

**框架能力演示**：

| 示例 | 演示什么 |
|---|---|
| [hello](examples/hello) | 最小闭环：`invoke` 命令 + 事件推送 + 越权拒绝 |
| [todo_check](examples/todo_check) / [vue_todo](examples/vue_todo) | 待办清单（零 Node 版与 Vue 3 + Vite 工程版，同一套命令） |
| [plugin-fs](examples/plugin-fs) / [plugin-dialog](examples/plugin-dialog) / [plugin-shell](examples/plugin-shell) / [plugin-serial](examples/plugin-serial) | 官方插件四件套：文件读写（含**路径 scope 对照**）/ 原生对话框 / 打开链接与子进程 / 串口，各带权限对照 |
| 框架内置 `store` 插件 | 持久化键值（RFC-003 第 2 期）：任意 JSON、原子写（tmp + rename）、命名集 `store:readonly`/`store:default`；`examples/music` 已迁移到它 |
| 框架内置 `clipboard` / `notification` 插件 | 系统剪贴板读写 / 系统通知（RFC-003 第 3 期）：Linux 实机取证（外部回读剪贴板、会话总线上实收通知），Windows 侧同名桩且能力位如实上报 |
| 框架内置 `log` 插件 + 日志落盘（RFC-003 第 5 期） | `app.setLogFile(path[, maxKB, keep])` / `setLogToDefaultFile(app)` 把仓颉侧与 C 桥的诊断落进同一份文件（**fd 级接管**，超预算轮转 `.1`…`.keep`）；`CJ_TAURI_LOG` / `CJ_TAURI_LOG_MAX_KB` / `CJ_TAURI_LOG_KEEP` 可为**已分发的 exe** 就地开日志，`system:host` 的 `logFile` 回读生效路径，页面 `log:write` / `log:path` 同走一个出口 |
| 框架内置 `http` 插件（SEC-006 白名单收口） | 页面可控的出网口：`http:get` / `http:post` / `http:delete` / `http:postStream`（SSE 流式经 `http:chunk` 事件按块回投），主机白名单写在能力清单 `scopes.http`（**没写 = 全拒**）、禁自动重定向、8 MiB 上限；`examples/ai-chat`（AI 对话客户端）是首个消费者 |
| 框架内置 `ws` 插件（长连接出网口） | `ws:connect` / `ws:send` / `ws:close` + `ws:frame` / `ws:state` 事件，主机白名单写在能力清单 `scopes.ws`（**没写 = 全拒**，与 `http` 插件同构、共用核心层 `urlHostOf`）；握手用 stdx 自带 `WebSocket.upgradeFromClient`，不手写协议 |
| [示例 examples/ai-chat](examples/ai-chat) | **cjh 的桌面客户端**：聊天流式走 `ws` 插件、会话/技能/MCP/文件四面板走 `http` 插件；另有 AI 对话客户端本体的多会话 + 多服务商（自定义 Base URL / API Key / 模型）、流式 Markdown 渲染（模型输出先转义再放行标记）、托盘 + 全局快捷键 + 最小化到托盘 + 日志落盘，**零新命令**；UI 侧含会话搜索 / 行内改名 / 侧栏收起 / 输入框自适应 / 文件预览与面包屑 / 工作区切换、停止生成与工具调用 chip、设置页（内联于主区 + 常驻底栏，打开即定位当前服务商）、**「聊天（直连）/ Agent（cjh）」模式开关**（默认聊天：模型选择真的生效；Agent 才连 cjh，徽章显示 cjh 侧真实模型）；cjh 预编译包**随仓 vendored**（`examples/ai-chat/vendor/cjh/`，更新时手动替换包、不做首次联网下载），`scripts/pack-linux.sh` 出 Linux 目录式便携包（包内自带 cjh，65 条自检全过）（页面自检 **56/56 全过**） |
| [menu](examples/menu) | 原生菜单栏（Windows + Linux 实机点选证据） |
| [ipc-bench](examples/ipc-bench) | IPC 性能探针：往返延迟 / 吞吐 / payload 放大 / 事件成本 |
| [ipc-coalesce](examples/ipc-coalesce) | 事件合并探针：`emitLatest`（同帧槽位 + rAF 批刷，尾值必达）与 `emit` 的对照——`emitLatest × 50` 合并成个位数次回调、`emit × 50` 老老实实 50 次，默认行为一行没改 |
| [multi-window](examples/multi-window) | 多窗口：同一份 HTML 起两窗，角色由自己的 label 决定；两窗**同时**开原生对话框各预置 `probe-<label>.txt`，验证宿主回调按句柄路由不串台 |

**生态项目**（独立仓库，基于 cj-tauri 构建、不在 `examples/` 里）：

| 项目 | 一句话 |
|---|---|
| [cjnote](https://atomgit.com/qq8864/cjnote) | **AI 原生 Markdown 笔记**：三栏（笔记库 / 编辑区 / AI 助手）+ 三态视图（编辑/分屏/预览，`Ctrl+1/2/3`）；**原生菜单栏 + 副标题**——文件 / 视图 / 帮助 三个顶层菜单，标题·保存状态·字数推进系统菜单行右侧（能力位不给就退回页面顶栏）；侧栏「大纲」页签抽 1~3 级标题点击跳行；AI 上下文只给**指针**——默认只带当前笔记的**绝对路径**（正文由 AI 自己按需读取，保证读到的永远是盘上最新内容），勾「问笔记库」才要求这一轮做全库检索，选区改写 / 续写 / 翻译走 **diff 确认**；`Ctrl+O` 打开库外 `.md` 只进内存作草稿（首次 `Ctrl+S` 才落库，绝不静默改写原文件）、`Ctrl+P` 页内快速打开；**AI 全走 cjh**（随包预编译产物 + 整页设置可改地址/密钥/模型并即时生效，自带「测试连通」），页面零 `fetch`；Linux 实机页面自检 **90 PASS / 2 FAIL**（仅有的 2 条 FAIL 为真实服务商聊天往返，随厂商可用性波动）；**AI 面板可折叠**（面板头「»」/ `Ctrl+4` / 视图菜单「显示 AI 助手」，隐藏后工具条出「✦ AI 助手」把手唤回，状态落盘） |

部分示例截图（全部为实机截图，完整集见各示例 README）：

| [markdown-notes](examples/markdown-notes)：文件树 / 编辑 / 实时预览 | [sqlite-browser](examples/sqlite-browser)：分页网格 + SQL 调试台 |
|---|---|
| ![Markdown 笔记](docs/images/example-markdown-notes.png) | ![SQLite 数据库浏览器](docs/images/example-sqlite-browser.png) |
| [leetcode-gui](examples/leetcode-gui)：题库 / 编辑器 / 判题终端 | [cj-link](examples/cj-link)：串口 + 网络三模式二合一调试助手 |
| ![仓颉力扣](docs/images/example-leetcode-gui.png) | ![串口网络二合一调试助手](docs/images/example-cj-link.png) |
| [serial-assistant](examples/serial-assistant)：参数面板 + TX/RX 分色收发日志 | [http-client](examples/http-client)：请求拼装 / 响应查看 / 集合管理 |
| ![串口调试助手](docs/images/example-serial-assistant.png) | ![HTTP API 客户端](docs/images/example-http-client.png) |
| [serial-waveform](examples/serial-waveform)：400 Hz 串口实时波形 | [typing-poem](examples/typing-poem)：古诗词打字练习（three.js 3D） |
| ![串口实时波形示波器](docs/images/example-serial-waveform.png) | ![古诗词打字练习](docs/images/example-typing-poem-typing.png) |
| [movie](examples/movie)：观影应用 | [music](examples/music)：音乐播放器（同步歌词） |
| ![观影应用](docs/images/example-movie.png) | ![音乐播放器](docs/images/example-music-playing.png) |
| [ai-chat](examples/ai-chat)：聊天模式（直连，流式 Markdown） | [ai-chat](examples/ai-chat)：Agent 模式（cjh 已连接 + 四面板） |
| ![AI 对话客户端：聊天模式](docs/images/example-ai-chat-chat.png) | ![AI 对话客户端：Agent 模式](docs/images/example-ai-chat-agent.png) |
| [cjnote](https://atomgit.com/qq8864/cjnote)（生态项目）：分屏编辑 + AI 助手，顶栏并入原生菜单行 | [cjnote](https://atomgit.com/qq8864/cjnote)：原生「视图」菜单（三态与主题勾选同步） |
| ![cjnote：分屏编辑 + AI 助手](docs/images/example-cjnote.png) | ![cjnote：原生视图菜单](docs/images/example-cjnote-menu.png) |
| [ohos-music](examples/ohos/ohos-music)：鸿蒙 PC 音乐播放器（同步歌词） | [ohos-movie](examples/ohos/ohos-movie)：鸿蒙 PC 观影应用 |
| ![仓颉爱音乐（鸿蒙 PC）](docs/images/example-ohos-music.jpg) | ![仓颉观影（鸿蒙 PC）](docs/images/example-ohos-movie.jpg) |

## 架构

**一份业务代码、多端产物**——改业务改 `src/`，改页面改 `assets/`，`cj-tauri sync` 把骨架派生成 `targets/desktop` 与 `targets/ohos`，业务包以 path 依赖进去，从不复制：

![cj-tauri 多端架构图：业务代码（src/main.cj + assets/）→ cj-tauri.toml 清单 → CLI（create / sync / check / build / dev）→ targets/desktop 与 targets/ohos → WebKitGTK / WebView2 / ArkWeb](docs/images/architecture-multiplatform.png)

**分层调用链**——页面到宿主每一层的职责与跨平台边界：

![cj-tauri 分层架构图：前端桥 → IPC 消息桥 → 能力安全模型 → 内置 / 插件命令 → WebView 宿主（Linux / Windows / 鸿蒙）→ 共享 C 层](docs/images/architecture.png)

分层文字版（同上图，便于搜索与复制）：

```
前端 (HTML/CSS/JS)  ← window.__CJ_TAURI__.invoke/listen/emit（注入桥接 JS，对应 @tauri-apps/api）
        │  JSON over postMessage（Linux: WebKitUserContentManager；Windows: chrome.webview.postMessage）
        ▼
IPC 消息桥（src/ipc_hub.cj）← 命令注册/分发/校验（与 tauri IPC 同构；命令在 worker 线程异步执行）
        ▼
能力安全模型（src/capability.cj）← 命令/事件白名单，默认最小权限（对应 capability）
        ▼
内置命令（src/api_system.cj）：system:version / ping / echo / devtools
        ▼
WebView 宿主（src/host.cj 抽象 + 各平台实现）
   ├─ Linux: webkit2gtk-4.1（src/host_webkit.cj + native/platforms/linux/bridge_linux.c，C 桥在原生 pthread 运行）
   ├─ Windows: WebView2（src/host_webview2.cj + native/platforms/windows/bridge_win.c，Win32 消息循环在宿主线程）
   └─ 鸿蒙: ArkWeb（应用侧 ArkUI 组件宿主 + `arkweb_proxy.cj` 桥接，2in1 / 鸿蒙 PC）
```

开发一个应用只需三步（对应 tauri 的 command / Builder / capabilities）：

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
| [串口/网络调试助手开发记](docs/仓颉版串口调试助手-开发记.md) | 一个窗口两条链路（串口 / TCP·UDP）：探针自检与对端取证、平台层串口读超时的定位、免 SDK 单文件包 |
| [技术方案](docs/技术方案.md) / [踩坑与实施记录](docs/踩坑与实施记录.md) | 可行性论证 / 开发全程踩坑 |
| [设计决策记录](docs/设计决策记录.md) | 为什么长这样：同进程桥、能力分级、scope 语义等 12 条决策的理由、代价与复评触发条件 |
| [需求追踪矩阵](docs/需求追踪.md) | 每个能力做到哪了：五级状态 + 可复核证据 |
| [CHANGELOG](CHANGELOG.md) / [AGENTS.md](AGENTS.md) / [CONTRIBUTING](CONTRIBUTING.md) / [README.OpenSource](README.OpenSource) | 变更记录 / 开发规范 / 贡献流程 / 依赖与许可 |

延伸阅读（CSDN）：[用仓颉写桌面应用：仓颉语言的 Tauri 框架实现与使用](https://blog.csdn.net/qq8864/article/details/166944044)。

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

- ✅ **三平台宿主**：Linux（WebKitGTK）、Windows（WebView2）、鸿蒙 PC（ArkWeb，2in1 桌面窗）——
  IPC / 能力模型 / 命令分发完全共用，平台差异只落在条件编译与 C 桥两处
- ✅ 脚手架 CLI（仓颉原生）：`create / dev / build / run / info`，npm 包跨平台分发
- ✅ 插件体系 v1 + 14 个官方插件（fs / dialog / shell / serial / store / clipboard / notification / menu / mqtt / redis / log / http / ws / sqlite）；
  命令级白名单、命名权限集、**路径 scope**（RFC-003 第 4 期）三层闸门，Windows + Linux 实机证据
- ✅ 命令异步分发（慢命令不冻窗口）、多窗口按 label 路由、插件清单 `info --json` 机器可读
- ✅ 宿主能力位：菜单 / **托盘** / **全局快捷键** / 文件拖入 / 通知——Windows（WebView2）与
  Linux（WebKitGTK）双实现、`system:host` 如实上报；「最小化到托盘」是宿主基元（`minimizeToTray`，
  没装托盘就如实降级为普通最小化）
- ✅ 工程化：294 个单元测试 + 免 SDK 静态门禁（CI 跑的就是它）+ 示例无人值守自检
- ✅ 鸿蒙 PC（ArkWeb，2in1 桌面窗）：页面 `system:version` 往返、多窗口 label 路由、`music` / `movie` 两个示例
  真机闭环，`cj-tauri create --template ohos` 直接生成可直接编 hap 的工程
- 🔜 鸿蒙宿主能力位（菜单 / 托盘 / 快捷键 / 拖放 / 对话框仍如实报 0）、macOS WebView、更多官方插件

## 仓库与推送

同一份代码双托管，`origin` 挂两条 pushurl，**一次 `git push` 同时推 AtomGit + GitHub**：

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git          # AtomGit（国内直连推荐）
git clone https://github.com/yangyongzhen/cj-tauri.git     # GitHub
git ls-remote origin main && git ls-remote github main     # 核对两仓 SHA 一致
```

## License

[MIT](LICENSE) © 2026 yangyongzhen
