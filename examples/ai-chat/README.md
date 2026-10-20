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

引导卡上排第一个的是「**一键部署并启动（推荐）**」，走 `cjh:deploy`：从仓库自带的
`vendor/cjh/cjh-v<版本>-linux-x64.tar.gz` 解出 cjh（**先按同目录的 `SHA256SUMS` 校验，对不上就不部署**，
全程不走网络），chmod 后当场拉起并接上，返回形状与 `cjh:start` 对齐
（`{ok, reused, port, apiUrl, wsUrl}`）。失败时**说清楚卡在哪一步**——安装包找不到 / 校验失败 /
部署完 10 秒没就绪（这时连"最常见原因是这份二进制与本机不兼容（例如要更新的 glibc）"一起讲），
并按引导卡第 2/3 步回落手动安装。第 2 步里就带着下载页地址与**按当前平台**给的产物名，
用户不用自己猜该下哪个包。这条路只在 Linux 落地，其他平台如实拒绝、仍走「选择 cjh 可执行文件…」。

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

## 自检

设 `CJ_AICHAT_PROBE=1` 启动即注入页内自检，断言经 `report` 回投到 stderr（明细行序不保证，
按**计数**对账：PASS 明细条数对上断言总数、`failed` = 0）。源码里目前共 **73 处断言**；
本机隔离副本实跑（cjh 空配置）是 **65 条明细 PASS、SELFCHECK 侧 0 FAIL**——差额是条件分支
（依赖已配置 cjh / 已配技能那几条）没走到，不是漏跑。另有三条独立探针行（都不进自检计数）：
`CJH-GUIDE`（引导三态：缺 cjh 出卡、产物名按平台、**不得**假装端点已就绪；给了路径则当场拉起并接上）、
`CJH-PANELS`、`CJH-CHAT`——本轮实机是 `CJH-PANELS 4/4`、`CJH-CHAT deltas=1 done=1 err=0`。
**接上空配置的 cjh 时后两条会掉**（那时如实报 2/4、无 delta，不当成通过）：`CJH-CHAT` 的判据是
「有没有 WS 帧回来」，而一个没有 provider 的 cjh 收得下 `chat` 帧、回不出帧（会话文件里只有 system + user）。

## 已知限制

- **Windows 未实机验证**（如实说明）；
- 引导卡上「选择 cjh 可执行文件…」那一步走的是**原生文件框**（阻塞模态）：无人值守的实机脚本点不了它，
  自动化取证走的是它背后同一个 `cjhStartWith()`（命令链一致），对话框本身留人点验；
- MCP 面板**只读**（2026-10-20 起撤掉「编辑配置」入口）：要改配置直接改 cjh 自己的 `settings.json`，
  改完需重启 cjh 才建连接（cjh 只在启动时 `loadMcpServers`）；
- 「停止生成」只置中断标记并把已到的文本落地：cjh **没有** WS 中断消息，除断连外没有真叫停服务端
  那一轮的办法，页面就这么写，不假装能停；
- cjh 会话历史**前端暂不给改名 / 删除**：cjh 的 a3e1e6e 已补 `PATCH` / `DELETE /api/sessions/{id}`
  （含路径穿越防护），本示例还没接线。
