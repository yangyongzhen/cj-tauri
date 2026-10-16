# 仓颉版 Tauri 到底能不能实战？我写了个 AI 客户端来验一验

先说结论。

`cj-tauri` 这个项目我一路写到现在，0.8.0：Windows（WebView2）和 Linux（WebKitGTK）都实机跑通了，插件排到十四个，示例堆到二十六个，单文件包也发了一排。但我心里一直有个疙瘩——**这些示例都是"框架自己家的孩子"**，用的全是最顺手的那些能力。一个框架到底能不能打，得看有没有人拿它去啃一块它自己都不熟的硬骨头。

于是我写了 `examples/ai-chat`。

这东西在 2026 年不算新品类，AI 客户端满天飞。但我偏要拿它来验 cj-tauri，理由很实在：**它是目前已知最苛刻的一份"能力清单验收器"**。它要长连接、要流式、要本机存密钥、要开子进程管生死、要托盘和全局快捷键、要读写文件、还要一堆面板轮着打 HTTP。框架缺哪一块，它当场就露馅。

结果是：**它没露馅**。而且反过来，它把 cj-tauri 狠狠补了一轮。

![ai-chat 聊天模式](https://raw.githubusercontent.com/yangyongzhen/cj-tauri/main/docs/images/example-ai-chat-chat.png)

*"聊天"模式：直连 OpenAI 兼容端点，流式增量按 Markdown 真实渲染（加粗、列表都走真实解析，不是当纯文本贴上去）。*

![ai-chat Agent 模式](https://raw.githubusercontent.com/yangyongzhen/cj-tauri/main/docs/images/example-ai-chat-agent.png)

*切到"Agent"模式：侧栏品牌跟着改口成 `cjh 客户端`、显示 `cjh: 已连接`，会话 / 技能 / MCP / 文件四个面板就位——管道换了，界面还在原地。*

## 先把 cj-tauri 说清楚

一句话：**仓颉语言的 Tauri**。

Tauri 的架构是三件套——WebView 宿主、IPC 双向桥、能力安全模型。cj-tauri 把这三件套用华为的仓颉语言独立实现了一遍：

- 后端用仓颉**静态编译**，没有 VM、也不捆 Chromium，直接用系统 WebView（Linux 走 WebKitGTK，Windows 走 WebView2），鸿蒙 ArkWeb 留了架构位；
- 前端随便用 Web 技术。`cj-tauri create` 出来的模板有内联 HTML 的零 Node 样板，也有 Vue 3 / React 18 的工程，`dev` 会把 Vite dev server 接管进窗口，HMR 直接用；
- **能力安全模型**是它真正的分量所在：`capabilities/*.json` 白名单——命令级放行、命名权限集、路径 scope、出网主机白名单，默认最小权限。没在清单里声明的命令，前端调用只会拿到一句 `command not allowed`，连"试一下"的余地都没有。

现在的家底：**14 个官方插件**（fs / dialog / shell / serial / store / clipboard / notification / menu / mqtt / redis / log / http / ws / sqlite）、**26 个示例**、八份免 SDK 的单文件 Windows 工具（4.69–9.79 MB，PE 导入表里只有系统 DLL，双击不弹黑窗）。

## ai-chat 是什么：一个客户端，两条管道

打开它，你会看到一个挺普通的聊天界面——左侧会话列表，右侧消息区，底部输入框，托盘里蹲着一个图标，`Ctrl+Alt+A` 随时唤起。

不普通的东西藏在顶栏那个开关里：**"聊天"和"Agent"两个模式，一键切。**

### 模式一：聊天（直连）

"聊天"模式走的是最短的那条线——页面把消息发给 OpenAI 兼容的 `/chat/completions`，流式增量一块块回来，直接渲染成带格式的正文。

在 cj-tauri 里这条线的落法：

- 出网走 `http` 插件新加的 **`http:postStream`**：命令 worker 按块读响应体，每块以 `http:chunk` 事件回投；SSE 的帧解析留在前端，宿主只负责把字节搬回来。
- 出网主机白名单写在能力清单的 `scopes.http` 里，**没写等于全拒**——出网面不做"没写就放行"这种事。
- 服务商的 Base URL / API Key / 模型 / system 提示词都能配，**多服务商并存**，Key 存本机（`store` 插件），不入库、不进日志。

### 模式二：Agent（cjh）

"Agent"模式接的是 **cjh**——我另一个用仓颉写的 AI agent 项目。

这条线完全是另一幅样子：

- 聊天流走 `ws` 插件的长连接（`ws://127.0.0.1:8765/ws`），帧是 cjh 自己的协议：`ack` / `delta` / `tool_start` / `tool_result` / `approval_request` / `done` / `error`；
- 会话、技能、MCP、文件四个面板全走 `http` 插件打 cjh 的 REST：`/api/sessions`、`/api/skills`、`/api/mcp`、`/api/fs/list`…；
- cjh 的进程生命周期由 `src/cjh_host.cj` 一个人管：发现二进制 → HTTP 健康检查（**已经在跑就复用，绝不重复起**）→ 没跑才按需 `spawn cjh web` → 退出时**只收自己拉起的那个**。

这里有个我很在意的细节：cjh web 默认 `--bind 0.0.0.0`，而且不带鉴权 token。跟着默认走，就等于把一个"能读写你的工作区、能跑 shell、能替你发消息给 LLM"的 agent 后端摊到整个局域网上。所以 ai-chat 拉起它的时候显式收回来：`--bind 127.0.0.1`。（用户自己起的实例不动——那是人家的进程，框架不去改。）

### 两个模式不是"两个皮肤"

有一点得说清楚：**切模式不是换皮肤，是换管道。**

聊天模式里，模型、工具、上下文全由你选的服务商决定；Agent 模式里，这些全归 cjh 管——本机 agent 拿着你的工作区，能调工具、能读写文件、能跑命令。它俩的产物都是同一种东西：**一个会话里的消息**。所以切回来之后，会话列表还在原地，你刚才聊的和 agent 干的，都在。

Agent 模式没连上 cjh 的时候，它会**当场如实拒绝**，不会偷偷退回直连假装一切正常。这类"不假装"的脾气，是这个项目里我最满意的部分之一。

## 为什么"内置一个 agent"这件事，纯 AI 客户端做不到

这一点值得单独说。

市面上的 AI 客户端——Cherry Studio、AIBot 这类——本体都是**一层 Web 界面**，是**"壳 + 远端 API"**的结构。它们能聊天、能挂工具、能接 MCP，这些事做得都不差（在"聊天"这件事上，它们比 ai-chat 成熟得多，我承认）。但能力边界就在这儿："跑 agent"只剩两条路：连一个**远端** agent 服务，或者让用户**自己装**一个 CLI，再想办法挂上去。

**"这个应用自带一个 agent 运行时、随包分发、由宿主进程直接管它的生死"**——这在纯 Web / Electron 客户端里是结构上做不出来的，它没有"宿主"这一层。

而在 ai-chat 里，Agent 模式不是外挂，是**同一个进程树里的第二个后端**。cjh 的预编译产物随包分发（`examples/ai-chat/vendor/cjh/`，带 `SHA256SUMS`；打包时解出来，**不做首次打开联网下载**），应用启动时自己发现、自己探活、自己按需拉起、退出自己收尾。你是聊天直连还是让本机 agent 干活，**同一个界面、同一份会话列表、一次点击**。

这就是我拿它当试金石的原因：它不是"cj-tauri 能跑的又一个 demo"，它是**用 cj-tauri 的宿主能力把东西组装出来的**。没有"能 spawn 子进程"、"能开长连接"、"能落本机存储"、"能托盘常驻"、"能全局快捷键"这几块基元，它一行都写不出来。

## 反过来，它把 cj-tauri 补了一遍

这部分是我最想说的。

写 ai-chat 的过程，基本就是拿真实需求去锤框架。锤出来的全是**框架级**的缺口——不是"示例少写了两行"，是"框架少了一块能力"：

| 真实需求 | 补进框架的东西 |
|---|---|
| 流式对话要长连接，而框架只有短请求 | 新增 **`ws` 插件**：`ws:connect` / `ws:send` / `ws:close` 三条命令 + `ws:frame` / `ws:state` 两个事件；握手用 stdx 自带的 `WebSocket.upgradeFromClient`，没手写 RFC6455 |
| OpenAI 兼容接口是 SSE 流 | `http` 插件新增 **`http:postStream`**：按块回投、UTF-8 跨块拼字节、`done` 收尾；流式增量必须**每条都 emit**，用"同帧只保最新"的通道会把中间增量整块吞掉 |
| 出网 URL 全是页面可控的 | `scopes.http` / `scopes.ws` **主机名白名单**（复用共享层 `globMatch`，**没写 = 全拒**）；禁自动重定向（3xx 原样回给页面）、禁页面自带 Host / Content-Length、响应体 8 MiB 上限截断并如实标记 |
| cjh 的工作区删除是带 body 的 DELETE | `http` 插件补 **`http:delete`** |
| 两个插件都要从 URL 里抠主机 | 抽出核心共享层 `src/urlutil.cj` 的 `urlHostOf`——**一份实现**，不给第二个插件再写一遍的机会 |
| 插件的 scope 语义不是文件路径 | `IpcContext.scopeRuleFor`：scope 规则本体直达插件（http 把模式当主机名匹配，不走路径规范化） |
| "日志里没有错误行"被读成"命令成功了" | 命令 handler 的两个 catch 各留一行 stderr（`command rejected` / `command failed`，前缀不同便于分流），失败不再无声 |

一个 AI 客户端，逼着框架补齐了长连接、流式、出网白名单、DELETE、共享工具层、诊断可见性。**这就是我说的"让 cj-tauri 更完善"——不是我在往里加功能，是真实需求在往里加功能。**

### 顺手揪出一个真 bug

这段我最有感触。

上线之后，Agent 模式下偶尔整条请求失败，报 `Invalid utf8 byte sequence.`。不是必现——**中文长回复的时候才偶发**。

顺着查下去，问题在 `http` 插件的流式分块里：`takeCompleteUtf8` 从缓冲区取走"完整的 UTF-8 序列"之后，要用 `remove(0..cut)` 把已发出的字节移掉。我原来写的是 `remove(0..(cut - 1))`——而仓颉的 Range 是**右开**的：`0..cut` 取 `cut` 个，`0..(cut-1)` 就只取 `cut-1` 个。

于是每轮都**少移一个字节**，上一个序列的末字节留在缓冲区里，下一轮拼出来的字节序列非法，严格的 `fromUtf8` 当场抛异常。

这个 bug 的形状值得记一笔：**ASCII 结尾的块少移一个字节照样合法，只有切在汉字中间才会炸**——它躲过了所有"跑一遍看看"的检查，一直到真实的中文对话才浮出来。修法是一行，加上两条单测钉死它；真正花时间的是搞明白"为什么偏偏中文才炸"。

**这就是拿真实项目当试金石的价值**：单元测试不会替你想到"块边界正好切在汉字中间"。

## 它现在的形态

已经不是一个"演示用的页面"了：

- **目录式 Linux 便携包**：`bash scripts/pack-linux.sh` → `examples/ai-chat/dist-linux/ai-chat-linux-x64/`（39 MB，其中 cjh 自己占 17 MB），归档 12 MB，进包直接跑 `run.sh`；
- **应用功能**：多会话、多服务商、流式 Markdown（表格 / 列表 / 引用 / 加粗 / 行内码，代码高亮跟着主题走）、会话搜索（标题与正文都搜）与行内重命名、侧栏收起（`Ctrl+B`）、`Ctrl+K` 搜会话、`Ctrl+Shift+N` 新会话、托盘常驻、最小化到托盘、全局快捷键 `Ctrl+Alt+A`、日志落盘；
- **Agent 模式那半边**：cjh 的会话 / 技能 / MCP / 文件四个面板、工作区切换、工具调用的 running / done / error 状态、审批请求、中止与结构化收尾（`ack` / `cancelled` / `error{code,retryable}` 各有各的落点，不混成一句"出错了"）；
- **模型透传**：Agent 模式发给 cjh 的 `chat` 帧带上当前选中的 `model` / `base_url` / `api_key`，**只对本回合生效、不落盘、不粘住**（这是和 cjh 商量出来的契约，不是桌面端自作主张）；
- **可验证**：页内自检 56/56 断言、FAIL 0（明细 65 条 PASS，其中 9 条 `CJH-*` 单独计数），另有 `CJH-PANELS` 4/4 与 `CJH-CHAT` PASS（deltas=1 / done=1 / err=0）两条独立探针行；打包后在同机副本里再跑一轮，同样 0 FAIL。

## 所以，可以放心用了

我把话说直白点：**ai-chat 这个项目的意义，就是给 cj-tauri 一个"能不能实战"的答案。**

一个框架能不能用，不看它的 README 写得多漂亮，看的是**当你真要做一个东西的时候，它会不会在第三个需求上把你拦住**。

做 ai-chat 的一路上，cj-tauri 被拦过几次——每次拦住的都是**该拦的地方**（出网要白名单、路径要 scope、命令要声明），不是**莫名其妙的地方**（"这个能力我没有"、"这个平台不支持"）。它暴露的缺口，最后都长成了框架自己的能力；它暴露的 bug，是一个真实场景才会碰到的边界。

所以我的判断：**cj-tauri 已经从"能跑起来"走到"能拿去做真东西"了。** 如果你手上有一个"壳 + 本地能力"的桌面工具想法——调试助手、看板、编辑器、下载器，或者像我这样往里面塞一个 agent——它值得你花一个下午试一把。

```bash
npx cj-tauri create myapp
cd myapp
npx cj-tauri dev
```

前置只要一个仓颉 SDK + stdx；Windows 另需 mingw 与 WebView2 Runtime，Linux 需要 `libwebkit2gtk-4.1-dev`。找不到 SDK 时 CLI 会把安装说明和 `CANGJIE_HOME` 示例打给你，而不是甩一句 `command not found`。

想直接看 ai-chat 长什么样：

```bash
cd examples/ai-chat
bash ../../native/build_linux.sh          # 首次：编 C 桥
cjpm build
CJ_AICHAT_CJH=<cjh 可执行文件路径> ./target/release/bin/main
```

不想编，直接出便携包：

```bash
bash scripts/pack-linux.sh                # cjh 从 vendor 里解出来，不联网下载
cd examples/ai-chat/dist-linux/ai-chat-linux-x64 && ./run.sh
```

---

*仓库：[AtomGit](https://atomgit.com/qq8864/cj-tauri) ｜ [GitHub](https://github.com/yangyongzhen/cj-tauri)（MIT）· 官网：[yangyongzhen.github.io/cj-tauri](https://yangyongzhen.github.io/cj-tauri/）*
