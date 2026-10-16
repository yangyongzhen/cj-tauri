# AI 对话客户端（ai-chat）

cj-tauri 的 AI 客户端示例——**同一个界面，两条管道，一键切换**：

- **聊天（直连）**：页面直接打 OpenAI 兼容的 `/chat/completions`，流式增量一块块回来渲染成 Markdown；
- **Agent（cjh）**：接本机的 **cjh**（用仓颉写的 AI agent），聊天流走 WebSocket 长连接，会话 / 技能 /
  MCP / 文件四个面板走 cjh 的 REST。

它是第一个同时消费 `ws` 与 `http` 两个插件的示例，也是 `ws` 插件落地的实际驱动方。

![聊天模式](../../docs/images/example-ai-chat-chat.png)

*"聊天"模式：直连服务商，流式 Markdown（加粗、列表走真实解析）。*

![Agent 模式](../../docs/images/example-ai-chat-agent.png)

*"Agent"模式：侧栏改口成 `cjh 客户端`、显示 `cjh: 已连接`，四个面板就位——管道换了，界面还在原地。*

## 有什么

**两条管道共用的**：多会话 + 会话搜索（标题与正文都搜）+ 行内重命名、多服务商（自定义 Base URL /
API Key / 模型 / system 提示词）、浅色与深色主题、紧凑模式、侧栏收起（`Ctrl+B`）、`Ctrl+K` 搜会话、
`Ctrl+Shift+N` 新会话、托盘常驻 + 全局快捷键 `Ctrl+Alt+A` + 最小化到托盘、日志落盘。

**Agent 模式独有**：cjh 的会话 / 技能 / MCP / 文件四个面板（MCP 面板可改配置，改完需重启 cjh）、
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
# Agent 模式要 cjh：给它可执行文件路径；只聊天可以不设，页面会显示 cjh「未连接」
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

## 自检

设 `CJ_AICHAT_PROBE=1` 启动即注入页内自检，断言经 `report` 回投到 stderr（明细行序不保证，
按**计数**对账：聚合行的 `passed` = PASS 明细条数、`failed` = 0）。当前 **67/67 断言、FAIL 0**
（Linux，隔离开副本 + 已配好技能 / MCP 的 cjh），另有 `CJH-PANELS` 与 `CJH-CHAT` 两条独立探针行：
本轮实机是 `CJH-PANELS 4/4`、`CJH-CHAT deltas=1 done=1 err=0`——**接上空配置的 cjh 时这两条会掉**
（那时如实报 2/4、无 delta，不当成通过）。

## 已知限制

- **Windows 未实机验证**（如实说明）；
- MCP 面板**可编辑但需重启 cjh**才建连接（cjh 只在启动时 `loadMcpServers`）；且 GET 回来的 `env`
  值是掩码 `***`，格式里含掩码的文本**拒发**——POST 是整体替换，回写会把真实密钥抹成三个星号；
- 「停止生成」只置中断标记并把已到的文本落地：cjh **没有** WS 中断消息，除断连外没有真叫停服务端
  那一轮的办法，页面就这么写，不假装能停；
- CLI 侧 `cjh 会话历史` 那组不给改名删——`/api/sessions` 目前只读。
