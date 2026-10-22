# AI 对话客户端（ai-chat）

cj-tauri 的 AI 客户端示例——**同一个界面，两条管道，一键切换**：

- **聊天（直连）**：页面直接打 OpenAI 兼容的 `/chat/completions`，流式增量一块块回来渲染成 Markdown；
- **Agent（cjh）**：接本机的 **cjh**（用仓颉写的 AI agent），聊天流走 WebSocket 长连接，会话 / 技能 /
  MCP / 文件四个面板走 cjh 的 REST。

它是第一个同时消费 `ws` 与 `http` 两个插件的示例，也是 `ws` 插件落地的实际驱动方。

![聊天模式](../../docs/images/example-ai-chat-chat.png)

*"聊天"模式：直连服务商，流式 Markdown（加粗、列表走真实解析）。*

![Agent 模式](../../docs/images/example-ai-chat-agent.png)

*"Agent"模式：侧栏改口成 `cjh 客户端`、显示 `cjh: 已连接`，四个面板就位；会话列表按模式分家——
上半是 cjh 的会话历史（带它的标题与时间），下半是「本地会话」，各认各的，互不污染。*

## 有什么

**两条管道共用的**：多会话 + 会话搜索（标题与正文都搜）+ 行内重命名、多服务商（自定义 Base URL /
API Key / 模型 / system 提示词）、浅色与深色主题、紧凑模式、侧栏收起（`Ctrl+B`）、`Ctrl+K` 搜会话、
`Ctrl+Shift+N` 新会话、托盘常驻 + 全局快捷键 `Ctrl+Alt+A` + 最小化到托盘、日志落盘。

**Agent 模式独有**：cjh 的会话 / 技能 / MCP / 文件四个面板（MCP 面板**只读**——写回走 cjh 自己的
`settings.json` 更直接，也绕开 GET 掩码 `***` / POST 整体替换那套容易抹掉真实密钥的坑）、
工作区切换（「浏览…」走**原生目录框**，也能手输绝对路径）、工具调用的
running / done / error 状态、**危险操作审批**（cjh 要跑危险工具时弹一张待批准卡片：工具名 / 入参 /
命中规则 + 与 `expires_in_ms` 同步的倒计时，「批准 / 拒绝」经同一条 WS 回 `approval_response`——
cjh 阻塞在这条回执上，超时 / 断连一律按「拒绝」收场、回合继续，页面照它的口径说不假装能续期）、
中止与结构化收尾（`ack` / `cancelled` / `error{code,retryable}`
各有各的落点，不混成一句"出错了"）、**模型透传**（帧里带当前选中的 `model` / `base_url` / `api_key`，
按 cjh 的会话级契约**只对本回合生效**、不落盘、不粘住）。

API Key 存本机 `store.json`（**不入库**，见根 `.gitignore`），不进日志。

## 怎么跑

```bash
cd examples/ai-chat
cjpm build
# Agent 模式要 cjh。可以不设：首次切 Agent 会弹一张引导卡——按「一键部署并启动（推荐）」
# 用仓库自带的安装包解出 cjh（本地 SHA256 校验后解包、chmod、拉起，不走网络）；失败则按第 2/3 步
# 手动下载再选路径。已经知道路径也可以直接配环境变量：
export CJ_AICHAT_CJH=/path/to/cjh
./target/release/bin/main        # 工作目录必须是本示例根（capabilities/ 与 ui/ 都按相对路径读）
```

Linux 首次要先编 C 桥：`bash ../../native/build_linux.sh`；并保证仓颉运行时与 stdx 在
`LD_LIBRARY_PATH` 里（否则启动即退、stderr 只有一行 `cannot open shared object file`）。

不想编，直接出目录式便携包（cjh 从 `vendor/` 解出来，**不联网下载**）：

```bash
bash ../../scripts/pack-linux.sh
cd dist-linux/ai-chat-linux-x64 && ./run.sh
```

## Agent 模式怎么接上 cjh

切到 Agent 模式先问一次后端状态（`cjh:status`），按三态分流：

- **已经在跑**（含用户自己起的）：直接接上，不拉新进程；
- **有路径**（上次挑过的 > 环境变量 `CJ_AICHAT_CJH`）：`cjh:start {path}` 当场拉起，成功即接上；
- **都没有**：出引导卡——cjh 是什么、为什么装在本地（只听 `127.0.0.1`）、**按当前平台**给该下的产物名
  与下载页，出口是「选择 cjh 可执行文件… / 重新检测 / 回到聊天模式」。

第三个按钮背后的 `cjh:start` 是**运行期**指定路径：`__CJH_API__` 只在 document-start 注入一次，
启动那刻 cjh 不在就永远拿不到端点（Windows 双击的 GUI 连设环境变量的地方都没有），所以安装结果必须由
应用自己接住，不能只提示一句「未连接」。挑过的路径记进存档，下次进 Agent 不再问。

引导卡上排第一个的是「**一键部署并启动（推荐）**」，走 `cjh:deploy`：从仓库自带的安装包解出 cjh
（**先按同目录的 `SHA256SUMS` 校验，对不上就不部署**，全程不走网络），然后当场拉起并接上，
返回形状与 `cjh:start` 对齐（`{ok, reused, port, apiUrl, wsUrl}`）。失败时**说清楚卡在哪一步**——
安装包找不到 / 校验失败 / 解包失败（回包里直接带真因：找不到解包工具、解包后没找到二进制或缺运行时库）/
部署完 10 秒没就绪（这时连"最常见原因是这份二进制与本机不兼容"一起讲，Windows 侧点名 SmartScreen / 杀软 /
缺 VC 运行时，Linux 侧点名 glibc），并按引导卡第 2/3 步回落手动安装。第 2 步里就带着下载页地址与
**按当前平台**给的产物名，用户不用自己猜该下哪个包。

两平台都落地，差别只在「装哪儿、怎么解包」（其余流程共用同一份代码）：

| | Linux | Windows |
|---|---|---|
| 安装包 | `vendor/cjh/cjh-v<版本>-linux-x64.tar.gz` | `vendor/cjh/cjh-v<版本>-windows-x64-selfcontained.zip` |
| 安装目录 | `~/.local/share/cj-ai-chat/` | `%LOCALAPPDATA%\cj-ai-chat\cjh\` |
| 解包 | 系统 `tar -xzf` + `chmod +x` | 系统自带 bsdtar（`%SystemRoot%\System32\tar.exe`，Win10 1803+） |
| 拉起 | `std.process.launch`（能收退出码） | 框架 `launchHidden`（`DETACHED_PROCESS`，只留 pid） |

Windows 侧两个坑写在这里省得再查：① 解包**必须用绝对路径的 bsdtar**，从 Git Bash 起的应用 PATH 里
MSYS 的 GNU tar 排在前面，它不认 zip；② zip 里 4 个运行时 DLL（`libcangjie-runtime` / `libboundscheck` /
`libssl-3` / `libcrypto-3`）不在 cjh 的 PE 导入表里、是按名字 `LoadLibrary` 的，解包后逐个点名核对，
缺一个就当场判失败——不然只会表现成「部署看着成功、cjh 一起就崩」。

`src/cjh_host.cj` 只管**生命周期**，不参与数据面：

1. `GET /api/health` 探活——**已经在跑就复用**（`gCjhOwned=false`，退出时不动人家的进程）；
2. 没跑，且配了 `CJ_AICHAT_CJH`，才 `spawn cjh web --port 8765 --bind 127.0.0.1`，然后 100ms 一步
   轮询健康检查，最多 10 秒；
3. 退出时**只收自己拉起的那个**。

`--bind 127.0.0.1` 是刻意的：cjh web 默认绑 `0.0.0.0` 且不带鉴权 token，跟着默认走等于把一个"能读写
你的工作区、能跑 shell、能替你发消息给 LLM"的 agent 后端摊到整个局域网上。本应用的消费面全在本机
（页面、ws、REST 都是回环），所以收回来。**只对本应用 spawn 的实例生效**——用户自己起的实例绑定
由用户决定。

没配 cjh 且 8765 上也没有活的实例时，应用照常启动，页面如实显示「未连接」，**不假装连上了**；Agent
模式下没连上会当场拒绝，不偷偷退回直连。

端口可用 `CJ_AICHAT_CJH_PORT` 覆写（默认 8765）。

### 桌面端选的服务商怎么进 cjh

两条路都要，各自管一件事：

- **每回合的 chat 帧**（`agentChatFrame()`）：`model` / `base_url` / `api_key` 随帧下发，按 cjh#3 的契约
  **只对那一回合生效、不落盘、不粘住**——所以「这一轮用的是你选的模型」并不等于 cjh 自己的配置变了；
- **同步进 cjh 基线**（`syncProviderToCjh()`）：`POST /api/settings`，触发点是**切到 Agent 模式 / 保存服务商 /
  切换到某个服务商 / 每次连上 cjh**。cjh 侧立即生效，`base_url` / `model` 落盘 `~/.cjh/settings.json`，
  于是 cjh 自己发起的调用、后台任务和设置页徽章显示的模型都是同一份值（以前并排放着两套值，界面也说不清）。

载荷只带**非空**字段：cjh 侧 `baseUrl` / `model` 是直接赋值，发空串等于把它的配置清空；`apiKey` 为空或含
掩码（`GET /api/settings` 返回的是 `sk-e****493a` 这类掩码）一律不发——回写掩码等于把真 Key 换成星星。
**cjh 侧目前的缺口已提 `cjh#6`**：REST 写进去的 `apiKey` 只进内存（`saveAll()` 只写 `base_url` / `model`，
而 `/provider` 命令走 `saveApiKey()` 写 auth.json），重启 cjh 后会丢——本应用的兜底正是「每次连上都重推
一次」，所以 cjh 重启后配置照旧收敛，不用用户再点一遍。自检 / 探针模式（`CJ_AICHAT_PROBE=1`）下**不发**：
自检会拿假服务商走一遍保存路径，真发出去会污染用户 cjh 的配置；载荷形状由 `cjh-sync-payload` 这条纯函数
断言守着。

## 能力清单与 scope

`capabilities/` 里声明了本示例用到的命令与事件，另外两处 scope 值得注意：

- `scopes.fs` 只放行 `$HOME` 之下——文件面板的路径预览走自家 `fs:readText`，越界由插件拒；
- `scopes.http` / `scopes.ws` 是**出网主机白名单**，**没写等于全拒**（出网面不做"没写就放行"）。

### 名单之外的端点怎么放行（运行期加白）

清单是**启动时读的静态文件**，页面改不了它——这正是出网防线的意思。所以放行要**人**点一下：
设置里保存服务商时，应用拿 Base URL 的主机名问一次（命令 `app:allowHost`），不在名单里就弹**原生确认框**。

- **确认**：`TauriApp.allowScopePattern("http", host)` 当场把它叠进注册中心（这一轮立刻可用），
  并把主机名追加到 `~/.local/share/cj-ai-chat/allowed-hosts.txt`；下次启动在 `run()` 之前重放，长期有效。
  端口与路径不进名单（判定按主机名）。两道校验：注册中心**只收具体值**（`*` / `?` 与制表/换行当场拒、
  返回 `false`，因为一个通配就等于全放行），应用侧再按主机名字符集过一遍（拒 `%` `#` 与空白）。
- **取消**：什么都不改，请求仍被 scope 挡住（日志里一行 `scope denied`），页面如实提示。
- 请求被挡（业务错误含 `outside the authorized scope`）时，页面会直接把这张确认框推到人面前，
  不用自己去翻清单。

被注入的页面**没法自行加白**：确认框是原生的、页面点不了它；清单里的 `deny` 也掀不掉
（判定顺序始终是先 deny 后 allow）。

## 单文件包（一个 exe、零随行文件）

```bash
bash scripts/pack-win-single.sh examples/ai-chat     # 产物：examples/ai-chat/dist-single/ai-chat.exe
```

产物是**一个文件**（实测 10.6 MB，`Subsystem = 00000002` 即 Windows GUI，双击不弹控制台；
导入表只有 msvcrt / KERNEL32 / WS2_32 / SHELL32 / dbghelp / ole32 / comdlg32 / USER32 / CRYPT32 这些系统库）。
页面、highlight.js 与主题、`capabilities/app.json` 都 base64 编进二进制，运行时不再读 `ui/` 与 `capabilities/`。

三件套（本示例已接好，新示例照抄）：`src/packed_assets.cj`（空存根，打包器整体覆盖它）、
`src/packed_resources.cj`（`decodeBase64` / `splitBy` / `textOrFile` / `vendorSegments`）、
`ui/vendor/pack-files.txt`（vendor 清单，**行序即契约**——与打包器的拼接序、`vendorSegments()` 的取用序三方对齐）。
判据固定是「base64 非空即内嵌、否则读盘」，所以仓库内正常构建的行为一点没变。

实测（2026-10-23，Windows）：把 exe 单独拷进一个**空目录**启动，窗口与页面照常（会话列表、输入框、
高亮配色都在），日志里是一行 `[cj-ai-chat] 能力清单来自内嵌资源：1 份` + `host created` + 7 个插件装配完成。

两件要提前知道的事：

- **单文件包不含 cjh 安装包**（那份 13 MB 的 zip 没有编进 exe，打包器只内嵌页面 / vendor / 清单）。
  所以引导卡第 1 步「一键部署并启动」在这个产物里会如实报「找不到 cjh 安装包 … ——
  请确认在 examples/ai-chat 目录下启动应用，或设 `CJ_AICHAT_CJH_BUNDLE` 指向它」；
  要么按提示把 zip 路径给它，要么走第 2/3 步手动指定 cjh。
- **双击启动时日志落盘不生效**：C 桥是把 stderr `dup2` 到日志文件的，而 GUI 子系统双击时 stderr 句柄无效，
  文件会被建出来但一行都写不进（实测 0 字节；同一份 exe 带 `2> err.txt` 起就正常，日志 605 行、`err.txt` 反而 0 字节）。
  要现场日志就用 `ai-chat.exe 2> ai-chat.log` 启动。

## 自检

设 `CJ_AICHAT_PROBE=1` 启动即注入页内自检，断言经 `report` 回投到 stderr（明细行序不保证，
按**计数**对账：PASS 明细条数对上断言总数、`failed` = 0）。源码里目前共 **73 处断言**；
本机隔离副本实跑（cjh 空配置）是 **65 条明细 PASS、SELFCHECK 侧 0 FAIL**——差额是条件分支
（依赖已配置 cjh / 已配技能那几条）没走到，不是漏跑。另有四条独立探针行（都不进自检计数）：
`CJH-GUIDE`（引导三态：缺 cjh 出卡、产物名按平台、**不得**假装端点已就绪；给了路径则当场拉起并接上）、
`CJH-DEPLOY`、`CJH-PANELS`、`CJH-CHAT`——本轮实机是 `CJH-PANELS 4/4`、`CJH-CHAT deltas=1 done=1 err=0`。
**接上空配置的 cjh 时后两条会掉**（那时如实报 2/4、无 delta，不当成通过）：`CJH-CHAT` 的判据是
「有没有 WS 帧回来」，而一个没有 provider 的 cjh 收得下 `chat` 帧、回不出帧（会话文件里只有 system + user）。

`CJH-DEPLOY` 走**自己的开关** `CJ_AICHAT_PROBE_DEPLOY=1`（`main.cj` 里注入
`window.__AICHAT_PROBE_DEPLOY__`，桥就绪后 1200ms 跑一次 `cjh:deploy`）：它要真的装一份 cjh 并起进程，
和「自检要求先没有 cjh」的前提互斥，所以**必须与 `CJ_AICHAT_PROBE=1` 分两轮跑**。判据两条：
`CJH-DEPLOY PASS deploy ok=true reused=<false|true> deployed=<路径> api=yes` 与紧随其后的
`CJH-DEPLOY PASS status state=running api=yes`；`reused=true` 那一轮表示端口上已有 cjh（不再解包、不再起进程）。

## 已知限制

- **Windows 已实机跑通**（2026-10-23，WebView2）：一键部署从全新状态走完「SHA256 校验 → bsdtar 解包 →
拉起 cjh → `/api/health` 200」，凭证是 `CJH-DEPLOY PASS deploy ok=true reused=false deployed=…cjh-v1.5.3-windows-x64.exe api=yes`
加 `CJH-DEPLOY PASS status state=running api=yes`；端口上已有 cjh 时同一探针报 `reused=true`（不解包、不起第二份）。
**本机 GUI 子系统下应用自己的 stderr 收不到**（重定向也是 0 字节），所以这条链的取证只看页内探针回投的日志行；
- 引导卡上「选择 cjh 可执行文件…」那一步走的是**原生文件框**（阻塞模态）：无人值守的实机脚本点不了它，
  自动化取证走的是它背后同一个 `cjhStartWith()`（命令链一致），对话框本身留人点验；
- MCP 面板**只读**（2026-10-20 起撤掉「编辑配置」入口）：要改配置直接改 cjh 自己的 `settings.json`，
  改完需重启 cjh 才建连接（cjh 只在启动时 `loadMcpServers`）；
- 「停止生成」只置中断标记并把已到的文本落地：cjh **没有** WS 中断消息，除断连外没有真叫停服务端
  那一轮的办法，页面就这么写，不假装能停；
- cjh 会话历史**前端暂不给改名 / 删除**：cjh 的 a3e1e6e 已补 `PATCH` / `DELETE /api/sessions/{id}`
  （含路径穿越防护），本示例还没接线。
