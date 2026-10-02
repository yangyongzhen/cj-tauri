# cj-tauri IPC 通信机制

> 面向两类读者：想给 cj-tauri 加通道 / 改协议的贡献者，以及正在评估「这套 IPC 够不够快、安不安全」的选型者。
> 本文的协议细节对着 v0.4.0 的实现逐条核对过（`native/bridge_linux.c`、`native/bridge_win.c`、`src/ipc_hub.cj`、
> `src/ipc_message.cj`、`src/app.cj`），性能数字是本机实机测出来的（方法与复现见 §8）。
> 相关文档：`AGENTS.md` §2（线程模型与装配契约）、`docs/RFC-插件体系.md`（能力模型）、`docs/使用文档.md` §5（CLI）。

## 0. 一句话总结

前端 `window.__CJ_TAURI__.invoke()` 与仓颉 `CommandHandler` 之间**没有 socket、没有 HTTP、没有额外的本地服务**：
一次调用就是「一条 JSON 字符串进宿主桥 → 函数调用进仓颉 → 一条 JSON 字符串回到页面」。
webview 自身的消息通道就是唯一的传输层，进程内一次函数调用即可完成，因此既不占端口，也不经过操作系统网络栈。

实测（Linux / WebKitGTK / 2 vCPU，详见 §4）：

| 场景 | 实测（当前实现，三轮中位） |
|---|---|
| 顺序往返（`bench:ping`，2000 次取均值） | **≈0.39 ms/次**（2561 ops/s） |
| 未授权命令被拒（同步快路径，2000 次取均值） | **≈0.35 ms/次**（2857 ops/s） |
| 管线化吞吐（500 条不等回） | **≈1.0 万 ops/s** |
| 1 MB 字符串回显往返 | **≈14.6 ms**（≈68.5 MB/s；这项单轮波动大，三轮 45.2–70.9 MB/s） |
| 事件推送（仓颉连发 200 条） | **≈0.02 ms/条**（三轮 0.015–0.06 ms，绝对值小、波动大） |

结论先给：**这个量级对「UI 交互 + 命令式 API」完全够用**；真正的边界在大 payload（MB/s 级）与高频小消息
（几千 ops/s 级）。它与 WebSocket 的关系不是「谁更快」，而是「压根不在同一层」——见 §5。

## 1. 分层结构

三层，每层只干一件事：

```
页面 JS   │  window.__CJ_TAURI__  { invoke, listen, emit, reload }
          │  出：JSON.stringify(obj) → postMessage(一条字符串)
──────────┼─────────────────────────────────────────────────────────
宿主桥 C  │  Linux  ：window.webkit.messageHandlers.cjtauri.postMessage
          │  Windows：window.chrome.webview.postMessage
          │  入：原生回调 → 仓颉（字符串原样上交，C 层不解析 JSON）
          │  回投：ExecuteScript("window.__CJ_TAURI__._dispatch(json)")
          │        加锁 FIFO 队列 + 一次调度合并成批（单条走快路径）+ 排空自续（在宿主 UI 线程执行）
──────────┼─────────────────────────────────────────────────────────
仓颉      │  IpcHub.handleRawMessage：解析 → 能力校验 → 命令分发
          │  执行在 worker 线程；结果经 jsSink → 宿主 runJs → 回投路径
```

| 层 | 文件 | 职责 | 不做的事 |
|---|---|---|---|
| 前端桥 | `native/bridge_linux.c` / `bridge_win.c` 里的 `BRIDGE_JS`（页面脚本执行前注入） | 暴露 `__CJ_TAURI__`、id 配对、promise、事件分发 | 不碰业务、不校验能力 |
| 宿主桥 | 同上两个 C 文件 | 收发字符串、reload 拦截、回投队列、窗口/对话框 FFI | 不解析 JSON、不做路由 |
| IPC 中心 | `src/ipc_hub.cj` + `src/ipc_message.cj` | 报文模型、能力校验、命令分发、异步执行、事件推送 | 不知道 GTK / WebView2 的存在 |

三条硬约束（来自 `AGENTS.md` §2 的架构契约）：

- **平台差异只在两处**：仓颉侧 `@When` 条件编译 + `native/bridge_*.c`。协议与分发两端共用，导出名一致
  （`cj_bridge_*`），所以上层没有平台分支。
- **依赖单向**：`app.cj` → `host.cj` / `ipc_hub.cj` → `capability.cj`。`IpcHub` 通过注入的 `jsSink`
  回调把结果交给宿主，不反向引用宿主。
- **窗口能力走宿主接口**：`WebViewHost`（`src/host.cj`）是唯一的宿主抽象，Linux 是 `WebKitHost`、
  Windows 是 `WebView2Host`，鸿蒙 ArkWeb 是预留位。

## 2. 协议：四种报文 + 一条控制消息

报文定义在 `src/ipc_message.cj` 的文件头注释里（那里就是协议的权威描述）：

| 报文 | 方向 | 形状 | 谁产生 | 谁消费 |
|---|---|---|---|---|
| invoke | JS → 仓颉 | `{"type":"invoke","id":1,"cmd":"greet","args":{…}}` | 前端 `invoke()` | `InvokeRequest.parse` |
| emit | JS → 仓颉 | `{"type":"emit","id":2,"event":"save-done","payload":{…}}` | 前端 `emit()` | `EmitRequest.parse` |
| resolve(成功) | 仓颉 → JS | `{"type":"resolve","id":1,"ok":true,"data":…}` | `IpcMessage.resolve` | 前端 `_dispatch` |
| resolve(失败) | 仓颉 → JS | `{"type":"resolve","id":1,"ok":false,"error":"…"}` | `IpcMessage.reject` | 前端 `_dispatch` |
| event | 仓颉 → JS | `{"type":"event","event":"tick","payload":{…},"window":"main"}` | `IpcMessage.event` | 前端 `_dispatch` → `listen` 的监听器 |
| 控制消息 | JS → 宿主 | 裸字符串 `__cj_tauri_reload__` | 前端 `reload()` | **C 桥**（不进仓颉） |

`emit` 与 `invoke` 共用 `resolve` 回执（`emit` 的 `data` 恒为空对象）；`event` 的 `window` 字段标明目标窗口，
**空 = 广播**（当前只有 `"main"` 一个窗口，投递侧尚未按它分流，见 §3.3 与 §7 限制 2）。

设计要点：

- **只有字符串在链路上跑**。`postMessage` 两端传的都是 `JSON.stringify(obj)` 的结果；C 桥把它原样交给仓颉，
  解析只发生一次，在仓颉侧（`JsonValue.fromStr`，来自 stdx）。
- **请求与响应靠 `id` 配对**，不靠顺序。前端自增 `seq` 生成 id，`pending[id]` 里存着 promise 的
  `resolve` / `reject`；回投时按 id 取出来兑现。**同一命令并发调用不保证执行顺序**（`src/ipc_hub.cj` 的注释里
  写明了这是有意为之：执行挪到 worker 后天然并发，保序要靠队列，没必要）。
- **三种响应共用 `type:"resolve"`**，失败只是 `ok:false` + `error`。好处是前端 `_dispatch` 只有两个分支
  （`resolve` / `event`），坏处是「成功」与「失败」在协议层长得像——前端必须看 `ok`。
- **`args` 宽松处理**：不是对象（缺省 / `null` / 数组）一律当空对象；`id`、`cmd`（`emit` 则是
  `event`）缺失、或 `type` 不认识则整条判为非法——**读得出 `id` 就回一条 `ok:false` 的 reject**
  （`IpcMessage.peekId`），读不出 `id` 的才只往 stderr 打 `invalid IPC message: …`（见 §7 限制 1）。
- **事件两个方向都在**：仓颉 → JS 是 `ipc.emit(event, payload)`，前端 `listen` 订阅（没有订阅报文，
  `listen` 纯前端行为）；JS → 仓颉 是前端 `emit()`，后端 `app.listenEvent(name, handler)` 订阅（见 §3.3）。
  两个方向都按 `canEmit(event)` 校验事件名；**前端 emit 只投后端监听器、不回投页面**——有意与 Tauri 不同，理由见 §7 限制 2。
- **reload 走旁路**：它是宿主控制消息，C 桥 `strcmp` 命中就自己处理（记日志 + 投递重载），
  所以它永远不会进 IPC hub，也不受能力清单约束。

## 3. 一次 invoke 的完整时序

以 Linux / WebKitGTK 为例（Windows 结构同构，差别只在 API 名与「V8 在独立进程」这点，见 §3.4）：

```
页面           C 桥(GTK 线程)              仓颉                        worker 线程
 invoke(cmd,args)
  ├ JSON.stringify
  ├ postMessage ──► on_script_message
  │                   ├ 是 __cj_tauri_reload__ ? 自己处理
  │                   └ 否则 g_on_message(str) ──► handleRawMessage
  │                                                 ├ InvokeRequest.parse  ← JSON 解析一次
  │                                                 ├ capabilities.canInvoke?  ─┐ 同步
  │                                                 ├ commands.contains?      ─┘ 拒绝
  │                                                 └ spawn ─────────────────► runCommand
  │                                                                             ├ handler.handle
 promise 挂起 ◄──────────────────────────────────────────────────────────────────┤
  │                                    g_idle_add(flush_pending_js) ◄── jsSink(resolve json)
  │                                        └ run_javascript ──► window.__CJ_TAURI__._dispatch(json)
  └ _dispatch {type:'resolve',id,ok,data} → pending[id].resolve(data)
```

逐步说明（对应源码位置）：

1. **出站**：`invoke(cmd, args)` 生成 id、把 promise 的兑现函数塞进 `pending[id]`，然后
   `postMessage(JSON.stringify({type:'invoke',id,cmd,args}))`。
2. **入站（C）**：Linux 是 `on_script_message`（`webkit_user_content_manager_register_script_message_handler`
   注册的 `cjtauri` 通道）；Windows 是 WebView2 的 `WebMessageReceived`（`msg_Invoke`，取
   `TryGetWebMessageAsString` → UTF-8）。两端都只做「reload 拦截 + 把字符串上交」。
3. **入站（仓颉）**：`TauriApp` 装配时把 `host.setMessageHandler` 接到 `hub.handleRawMessage`
   （`src/app.cj`）。解析 → 能力校验 → 命令存在性校验，**这两道拒绝都发生在调用线程上、同步返回**；
   通过后才 `spawn` 到 worker 执行。
4. **执行**：worker 上跑 `handler.handle`，成功 → `IpcMessage.resolve(id, result)`，
   `CommandException` → `reject(id, message)`，其他异常 → `reject(id, "command failed: …")`
   （后端错误不会让页面崩，只会让那条 promise reject）。
5. **回投**：`jsSink` 拼出 `window.postMessage(<json>, '*');` 交给 `host.runJs`。C 侧
   **加锁入队 + 只投递队首**，在宿主 UI 线程执行 `evaluate_javascript` / `ExecuteScript`；
   执行完若队列还有货，再调度一次（自续），避免「一个 idle 里跑一串脚本」阻塞 UI。
6. **兑现**：页面收到 `message` 事件 → `_dispatch` → 按 id 找到 `pending` → `resolve` / `reject` → `await` 继续。

### 3.1 为什么回投要排队

回投可能来自**任意线程**（worker、事件推送线程、对话框回调）。GTK / WebKit 只允许在创建它们的那个
原生 pthread 上调用，而且仓颉轻量线程的堆上协程栈会被 JSC 的栈边界校验 abort（`AGENTS.md` §4 的坑）。
所以宿主桥统一成「谁都能塞队列，只有 UI 线程能执行」：Linux 用 `g_idle_add` 唤醒 GTK 线程，
Windows 用 `PostMessageW(WM_CJT_FLUSH)` 唤醒窗口线程。**这也是 worker 里不要直接调 GTK/WebKit 的原因**。

### 3.2 为什么校验留在调用线程

「未授权 / 未注册」在前端是最常见的失败，报错必须即时且顺序确定；而且为一条注定失败的请求白开一个线程
不划算。所以线程模型是**两段式**：校验同步、执行异步。实测这两条路径的差距很小（§4：拒绝 0.350 ms vs
成功 0.3905 ms），说明「同步拒绝」并没有因为「没走 worker」而变慢——省下的是线程与回投排队，量级约 40 µs。

### 3.3 事件推送（仓颉 → JS）

`IpcContext.emit(event, payload)` → `IpcHub.emitToWindow` → `canEmit(event)` 校验 → `jsSink(event json)`。
与 invoke 相比少了三件事：**没有 id 配对、没有 promise、没有 worker**（发射方本来就在某个线程上）。
所以单位成本更低（实测 0.02 ms/条，比往返的 0.39 ms 低一个量级；这项绝对值小、单轮波动大，三轮分别是
0.06 / 0.015 / 0.02 ms）。事件没有背压与丢包策略：
一条 emit 就是一次 JS 执行，前端的监听器同步跑——监听器里写重活会拖慢整个页面。

反方向（前端 → 后端）走的是**另一条路**，别把两者当成同一个 `emit`：

```
页面                     C 桥(GTK 线程)            仓颉                       worker 线程
 emit(event, payload)
  ├ JSON.stringify
  ├ postMessage ──► on_script_message ──► handleRawMessage
  │                                          ├ EmitRequest.parse
  │                                          ├ canEmit(event)? ─┐ 同步拒绝
  │                                          │                  └ reject("event not allowed: …")
  │                                          └ spawn ──────────► 逐个跑 listenEvent 的监听器
 promise 挂起 ◄────────────────────────────────────────────────────┤
  │                          _dispatch ◄── jsSink(resolve) ◄────────┘
  └ pending[id].resolve({})
```

与仓颉 → JS 方向的差别只有一处：**它带 `id`、有 promise**。代价是每条 emit 多一次回投，收益是
「事件未授权」能以 `reject` 回到前端（以前只在 stderr 里丢，调用方永远等不到结果）。后端某个监听器
抛异常只记 stderr，不影响同事件上的其它监听器，也不影响发送方——事件是广播语义，没有「整体成功 / 失败」。
**它不回投给页面**：谁 emit 的、页面上有没有 `listen` 同一个事件，都不影响投递（理由见 §7 限制 2）。

### 3.4 两平台的结构差异

| | Linux (WebKitGTK) | Windows (WebView2) |
|---|---|---|
| JS API | `window.webkit.messageHandlers.cjtauri.postMessage` | `window.chrome.webview.postMessage` |
| JS 引擎位置 | 宿主进程内（JSC） | **独立进程** `msedgewebview2.exe`（V8） |
| 入站回调 | `script-message-received::cjtauri` | `WebMessageReceived`（`TryGetWebMessageAsString`） |
| 回投唤醒 | `g_idle_add(flush_pending_js)` | `PostMessageW(hwnd, WM_CJT_FLUSH)` → `flush_js` |
| 线程约束 | 所有 GTK/WebKit 调用必须在创建它的原生 pthread | 同上（保持同构），但 V8 在别的进程，无 JSC 栈校验问题 |
| 调试线索 | `[cj-bridge] set window: …` / `devtools enabled`（无逐条消息计数行） | `js -> native (N bytes)`（每条入站一条）、`ExecuteScript -> hr=0x0` |

协议、报文、能力校验、命令分发**两端完全一致**——这正是「平台差异只允许出现在 `@When` 与 C 桥」的收益。

## 4. 性能实测（Linux / WebKitGTK）

### 4.1 环境与方法

| 项 | 值 |
|---|---|
| 机器 | AMD EPYC 7K83 2 vCPU / 1.9 GiB（容器）、Xvfb 虚拟显示（无物理显示器） |
| 栈 | cj-tauri 0.4.0、cjc 1.0.5（SDK 1.2.0 工具链）、WebKitGTK 4.1、GTK 3 |
| 探针 | **`examples/ipc-bench/`**（随仓库走，可复现）：4 组基准，结果经 `report` 命令回传仓颉侧 stderr |
| 对照 | Node v22.22.0：内置 `WebSocket` 客户端 + 手写最小 WS 服务端（RFC6455 握手 + 文本帧回显）+ 裸 TCP 回显 |

方法要点（不写清这几条，数字会被误读）：

- **每条样本都是一次完整往返**：JS 出站（含 `JSON.stringify`）→ 桥 → 仓颉解析 → 能力校验 → 执行 → 回投 → 页面 `_dispatch` → `await` 继续。
  也就是说，下面所有数字都含「两次 JSON 编解码 + 一次 webview 消息 + 一次 JS eval + 一次 promise 调度」。
- **逐条计时不可信**：WebKitGTK 的 `performance.now()` 实测粒度约 1 ms（`latency` 项 min=0 ms、p50=1 ms），
  所以可信的均值一律来自**总墙钟 ÷ N**（`latency_scaled` / `throughput` / `payload` / `events` 项）。
- 预热 20 次后才计时；**连跑三轮取中位**（2026-10-02，原始日志 `/tmp/ipc-bench-round{1,2,3}.log`，
  §8 摘录的是吞吐那一项为中位的第 1 轮，与 `/tmp/ipc-bench-linux.log` 逐字节一致）。
  机器负载依然会影响绝对值——**请看量级与相对关系，不要抠小数**。

### 4.2 结果

`examples/ipc-bench/`，**当前实现**（回投直派 + 批处理 + 单条快路径）连跑三轮取中位
（原始日志 `/tmp/ipc-bench-round{1,2,3}.log`）：

| 基准 | 参数 | 结果（三轮中位） |
|---|---|---|
| `latency_scaled` `bench:ping` | 2000 次顺序 | 781 ms → **390.5 µs/次**，2561 ops/s |
| `deny_scaled` 未授权命令 | 2000 次顺序 | 700 ms → **350 µs/次**，2857 ops/s |
| `throughput` `bench:ping` | 500 条不等回 | 50 ms → **10000 ops/s** |
| `payload` `bench:echo` 1 KB | 100 次 | 0.49 ms/次 → 1.99 MB/s |
| `payload` `bench:echo` 64 KB | 40 次 | 1.65 ms/次 → 37.9 MB/s |
| `payload` `bench:echo` 1 MB | 10 次 | 14.6 ms/次 → **68.5 MB/s**（单轮 45.2–70.9） |
| `events` 仓颉连发事件 | 200 条 | 4 ms → **0.02 ms/条**（单轮 0.015–0.06） |
| `latency` 逐条分布（仅看长尾） | 200 次 | min=0 ms / p50=1 ms / p95=2 ms / max=6 ms（粒度所限） |

改动前（回投走 `window.postMessage`、每条响应一次 eval）的历史基线，保留作对照（单次运行，
那份原始日志已被后续运行覆盖）：

| 基准 | 参数 | 结果 |
|---|---|---|
| `latency_scaled` | 2000 次顺序 | 893 ms → 446.5 µs/次，2240 ops/s |
| `deny_scaled` | 2000 次顺序 | 752 ms → 376 µs/次，2660 ops/s |
| `throughput` | 500 条不等回 | 78 ms → 6410 ops/s |
| `payload` 1 KB / 64 KB | 100 / 40 次 | 0.54 ms（1.81 MB/s） / 2.03 ms（30.9 MB/s） |
| `payload` 1 MB | 10 次 | 16.8 ms → 59.5 MB/s |
| `events` | 200 条 | 23 ms → 0.115 ms/条 |

怎么读：

- **顺序 0.39 ms/次、管线化 1.0 万 ops/s**：管线化快了约 3.9×——顺序模式每次都在等一次
  「eval 回投 + JS 事件循环」的往返，不等回地连发可以重叠这些等待。前端要不要并发，取决于业务是否关心顺序。
- **拒绝路径 0.350 ms，比成功少约 40 µs**：省掉的是 `spawn` + `handler.handle` + `resolve` 组装。
  这条是「校验留在调用线程」这个设计决策的直接收益——同步拒绝没有额外代价。
- **payload 越大越接近吞吐上限**：1 KB → 64 KB（数据 64×）时间涨 3.4×，MB/s 从 1.99 涨到 37.9；
  1 MB 时 68.5 MB/s。小 payload 完全被固定开销支配（0.49 ms 里几乎没有「数据搬运」的份额），
  1 MB 那行的 ≈68 MB/s 就是 **JSON 编解码 + 单线程 JS** 的实际天花板量级。
- **事件 0.02 ms/条**（三轮 0.06 / 0.015 / 0.02）：比请求-响应低一个量级，符合「少了 id 配对、promise、worker」
  的预期。这项绝对值小、单轮波动大，别拿单次结果做结论。高频事件推送（例如 60 fps 量级的动画数据）
  在这个量级下是可行的，但注意 §7 的背压问题。

### 4.3 同机对照：localhost WebSocket / 裸 TCP

`/tmp/ws-vs-tcp.js`（41 B payload、n=200、Node v22.22.0、握手后顺序往返）：

| 方式 | min | p50 | p95 | max | mean |
|---|---|---|---|---|---|
| WebSocket `ws://127.0.0.1`（手写最小服务端） | 0.112 ms | 0.131 ms | 0.215 ms | 0.945 ms | **0.151 ms** |
| 裸 TCP 回显（socket 往返下限） | 0.051 ms | 0.059 ms | 0.137 ms | 0.399 ms | **0.077 ms** |

**怎么读这组对照（重要）**：表面看 loopback socket 更快（0.08–0.15 ms vs cj-tauri 的 0.35–0.39 ms），
但这个比较**不是胜负判决**，因为两条线不在同一个执行环境里：WS 那条跑在 Node 里（没有 webview、
没有页面事件循环、没有跨语言回调），cj-tauri 那条跑在 webview 里且每次都要跨 JS↔C↔仓颉 三道边界，
还要付 JSON 编解码与 worker 线程 spawn。它的价值是给出**量级参考**：三者都在 0.1–0.5 ms 这一档，
说明「换传输方式」不是数量级的差异——真正的开销在报文处理与调度上（§6）。
要真刀真枪比，得让 socket 客户端也跑在同一个 webview 里（§7 列为未做的验证）。

## 5. 与 WebSocket 方案的对比

### 5.1 先对齐概念：两者不在同一层

WebSocket 是**传输层**：它的职责是把字节从 A 搬到 B，并且假定 A 与 B 可能隔着网络。
cj-tauri 的 IPC 没有「传输层」可换——JS 与仓颉本来就在同一个进程里，中间只隔一层 webview 的消息回调。
所以这里的传输就是 webview 自带的 `postMessage`，而本文 §2 讲的报文语义（id 配对、`ok/error`、事件）
才是「协议」的实质。

**用 WebSocket 做 IPC，等于自造一个传输层**：起一个本地服务、绑端口、握手、帧编解码、进程与线程调度。
它买到的是「跨进程 / 跨机器 / 跨语言客户端」；付出的是端口占用、握手开销、额外进程、
以及「本机多了一个监听端口」这个暴露面——在单机同进程的场景里，这些付出换不到延迟上的收益。

### 5.2 结构性对比

| 维度 | cj-tauri IPC（webview 消息通道） | WebSocket IPC（自建本地服务） |
|---|---|---|
| 数据路径 | 页面 → C 桥 → 仓颉（同一进程内） | 页面 → socket → OS 网络栈 → 另一进程/线程 → 业务 |
| 端口 / 握手 | 无端口，无握手 | 需要端口（或 unix socket 文件），每次连接一次 HTTP Upgrade 握手 |
| 额外进程 | 无 | 通常需要一个常驻服务进程（生命周期管理、崩溃恢复、日志） |
| 跨语言边界 | 1 次（JS ↔ 仓颉，经 C 桥） | 2 次以上（JS ↔ socket ↔ 服务，服务再调业务） |
| 载荷格式 | JSON 字符串（与 WebSocket 文本帧同形） | 文本或二进制帧（二进制是它的优势） |
| 消息语义 | 需自己实现（我们：`id` 配对 + `ok/error` + `event`） | 需自己实现（WebSocket 只给字节流） |
| 安全模型 | 能力清单在 hub 内同步校验，未授权直接拒绝（无外部入口） | 要额外考虑「谁能连这个端口」：鉴权、只绑 127.0.0.1、防火墙 |
| 部署面 | 零端口、零服务，杀进程即全清 | 端口冲突、残留进程、容器/沙箱网络策略都可能出问题 |
| 适用距离 | 同进程（同机多进程需另设计） | 跨进程、跨机器、跨客户端 |
| 典型失败模式 | UI 线程被 eval 阻塞、队列积压 | 端口占用、连接断开、握手失败、代理干扰 |

### 5.3 数字对照

同机 loopback 的实测下限（§4.3）：WebSocket 0.151 ms、裸 TCP 0.077 ms；
cj-tauri 的进程内往返 0.39 ms（成功）/ 0.35 ms（拒绝）。三者同处 **0.1–0.5 ms 这一档**，
没有数量级差异——因为这一档的耗时主要由「报文编解码 + 调度 + 跨边界调用」构成，而不是由「有没有 socket」决定。

大 payload（1 MB ≈ 14.6 ms / 68.5 MB/s，单轮 45.2–70.9）是另一回事：我们这条链路的瓶颈是
**JSON 编解码 + 单线程 JS**，而 WebSocket 有二进制帧与更省的分片路径，在 MB 级以上通常更有优势。
真要搬大块二进制数据（图像、音视频帧），应当设计专门通道（Tauri v2 也是往这个方向补的），
而不是指望把 JSON 往返调快。

### 5.4 什么时候 socket 反而更合适

- **需要跨进程或跨机器**：后端要做成常驻服务、多个窗口/多个客户端共用一个后端、或要能被外部工具连上调试。
- **需要持续双向流**：视频帧、串口/传感器数据这类高频、可丢、可用二进制的场景。
- **前后端生命周期不同**：后端常驻，UI 可关可开（本项目目前是「窗口关则进程退」，不适用）。
- **要复用现成生态**：已有的 HTTP / gRPC / MQTT 服务端接口，接进 cj-tauri 比重新实现命令更快。

反过来，只要守住「同进程 + 命令式 API + 单机」这三条，webview 消息通道就是更省的选择：
少一层传输、少一个进程、少一个端口，能力校验还能卡在唯一的入口上。

### 5.5 Tauri 官方怎么选（对照）

Tauri v2 官方文档对自家 IPC 的描述与本项目同构（原文见 §9）：

- IPC 风格叫 **Asynchronous Message Passing**，两个原语是 `Commands`（`invoke`，形似浏览器 `fetch`）与
  `Events`（fire-and-forget，双向；事件本身也走 Commands 实现）；
- 底层是「**JSON-RPC like protocol**」，参数与返回值**必须可 JSON 序列化**；
- 文档明确了「报文传递比共享内存/直接函数调用更安全：接收方可以自由拒绝或丢弃请求」——
  这与本项目「能力校验不通过就在 hub 里同步拒绝」是同一个思路；
- v2.0 的权限模型（permissions / scopes / capabilities）由 core 判断「一条 invoke 是否允许到达命令函数」
  并附带 scope，命令实现自己再校验参数——本项目的能力清单是同一模型的精简版（详见 `docs/RFC-插件体系.md`）。

也就是说：**WebView 宿主框架不使用 socket 做 IPC 是共识，而不是本项目省事的妥协**。
把复杂度放在「协议 + 权限」而不是「传输」，是本类框架的通行取舍。

## 6. 一次往返的开销构成与优化空间

把 0.39 ms 拆开（`src/ipc_hub.cj` + C 桥逐段对照）：

| # | 步骤 | 在哪 | 备注 |
|---|---|---|---|
| 1 | `JSON.stringify(args)` + `postMessage` | 页面 JS | 一次序列化，跨 JSC ↔ C |
| 2 | 原生回调 → 仓颉回调 | C 桥 | 一次 Cangjie 回调跨 FFI |
| 3 | `InvokeRequest.parse`：JSON 解析 | 仓颉 | stdx `JsonValue.fromStr` |
| 4 | 能力校验 + 命令存在性校验 | 仓颉（调用线程） | HashMap 查表，命中则放行 |
| 5 | `spawn` 一个 worker | 仓颉 | **每条命令一次线程创建** |
| 6 | `handler.handle` | worker | 业务本身 |
| 7 | `IpcMessage.resolve`：拼 JSON 字符串 | worker | 一次序列化 |
| 8 | `jsSink` → 入队 + 唤醒 UI 线程 | C 桥 | `g_idle_add` / `PostMessageW` |
| 9 | `run_javascript("window.__CJ_TAURI__._dispatch(<json>)")` | 宿主 UI 线程 | 一次 eval 直派（**不含 JSON 解析**，也没有结构克隆 / message 事件）；同批积压合并成一次 eval |
| 10 | `_dispatch` → `pending[id]` → promise → `await` 续体 | 页面 JS | 兑现 |

哪几段占大头？实测拒绝路径（只走 1–4 + 8–10）是 0.350 ms，成功路径 0.3905 ms：
**5–7 段合计 ≈40 µs，其余 ≈350 µs 全是"固定开销"**——JSON 编解码、两次跨语言边界、
UI 线程 eval、promise 调度。所以调优要冲着固定开销去，而不是业务代码。

按「收益 / 风险」排序的可做优化（**第 1、2 项本轮已实施并实测，其余仍是方向**）：

1. ~~回投直接派发~~ **已实施**：第 9 步的回投脚本从 `window.postMessage(<json>, '*')` 改为直派
   `window.__CJ_TAURI__._dispatch(<json>)`（`src/app.cj` 的 `jsSink`），桥 JS 里那个 `message`
   监听器随之删除——省掉结构化克隆 + 一次 message 事件派发，顺带消掉
   「谁能向 `window.postMessage` 投递谁就能伪造回包」的那个面（实测伪造投递被派发 0 次，§7-8）。
   ⚠️ **更正一处早先的误述**：这里**并没有多一次 `JSON.parse`**——`<json>` 是被当作 JS
   **对象字面量**嵌进 eval 的，页面收到的已经是对象，`_dispatch` 中 `typeof msg === 'string'`
   的分支根本不走。
2. ~~回投批处理~~ **已实施**：一次空闲回调（Linux `g_idle_add`，Windows `WM_CJT_FLUSH`）把队列里
   最多 64 条响应拼成一段脚本、只执行一次 eval，没取空就自续再排；队列里只有一条时走**快路径**
   （直接用原字符串，不拼批）。实测（Xvfb，各 3 轮取中位，同一份应用二进制只换 C 桥）：
   吞吐 6024 → **11905 ops/s**（≈2.0×）、事件 0.105 → **0.04 ms/条**（≈2.6×）、
   顺序往返 386.5 → 390.5 µs（+1%，噪声内）、1 MiB 回显 49.5 → 51.8 MB/s（噪声内）。
   快路径不是可选项：只做拼批、不做快路径时顺序往返中位数是 414.5 µs（比基线慢约 7%），
   因为「一次往返一条响应」这条最热的路上白花了一次拷贝。
   （注：这是「只换 C 桥」的 A/B 对照——两处改动的收益要单独摘出来只能这么测；§4.2 是对当前实现的
   绝对测量（三轮中位吞吐 10000 ops/s），与这里的 11905 属同一档，差异来自会话噪声。）
3. **worker 线程池**（中等收益、影响语义）：把第 5 步的 `spawn` 换成池化。
   `spawn` 只占那 ~40 µs 里的一部分，所以只对「命令本身极短」的场景有意义；
   代价是并发/顺序/取消语义要重新定义，风险比 1、2 高。
4. **大 payload 走专门通道**：需要搬 MB 级数据时，别回内容，回**句柄/路径**（我们自己解析）；
   或后续版本加二进制通道（Tauri v2 的方向）。
5. **事件背压与合并**：给 `emit` 加「同事件同 tick 合并」或丢弃策略，避免 UI 被事件淹没（§7）。

**不建议**为了微优化去做的事：把能力校验挪进 worker（会破坏「同步拒绝、顺序确定」的语义）、
把 JSON 换成自定义二进制编码（收益要到 MB 级才显现，代价是可调试性——现在抓包看日志就能看懂报文）。

## 7. 已知限制与坑

1. **读不出 `id` 的非法报文仍然没有回包（已部分修）**：解析失败时先尽量把 `id` 捞出来
   （`IpcMessage.peekId`），捞得到就回一条 `ok:false` 的 reject，前端那条 promise 立刻落地——
   实机探针里页面直接投 `{"type":"wat","id":9001}`，收到的回投报文是
   `{"type":"resolve","id":9001,"ok":false,"error":"invalid IPC message"}`。
   **捞不出 `id` 的（不是 JSON / 缺 `id`）只能打 stderr**：没有 id 就对应不到任何 promise，
   回包也没处落地。这类情况前端仍要自己加超时兜底。
2. **前端 `emit()` 已打通，但事件不做跨窗口广播（有意）**：`__CJ_TAURI__.emit(event, payload)` 现在返回
   Promise——`EmitRequest.parse` → `canEmit(event)`（调用线程同步拒绝）→ worker 上跑后端监听器
   （`app.listenEvent` 注册）→ 回投 resolve；未授权则 `reject("event not allowed: <event>")`。
   **它不回投给任何页面**：单窗口下"广播"等于自己发自己收（Tauri 用户真实踩过这个坑，官方 issue 是
   won't fix），多窗口寻址我们也还没实现。协议里的 `window` 字段与桥的 label 过滤已经就位，
   将来接投递侧时**协议与前端都不用改**。页面内广播继续用原生 `CustomEvent`。
3. **没有超时 / 取消 / 背压 / 丢包策略**：命令一旦发出去就只能等；事件连发会把 UI 线程的脚本队列堆满
   （每条事件都是一次 `eval`，且都在宿主 UI 线程执行）。
4. **UI 线程是稀缺资源**：所有回投都在宿主 UI 线程执行，单条 MB 级 payload 或高频事件会直接卡住界面。
   worker 里**不要**绕过桥去直接调 GTK/WebKit——JSC 的栈边界校验会 abort（`AGENTS.md` §4 的坑），
   只能经 `jsSink` 排队回投。
5. **同一命令不保序**：并发调用按完成先后回投（有意为之，见 §2）；需要顺序就得自己在业务层排队。
6. **Linux 侧缺少逐条消息日志**（**已修**）：现在两平台入站都打 `js -> native (N bytes)`，
   排查时能直接对数（实测见 §8）。
7. **回投失败原先不可见**（**已修**）：Linux 桥以前是 `run_javascript(..., NULL, NULL, NULL)`，不接执行结果，
   eval 失败（脚本抛异常、JS 上下文失效）只会静默丢掉这条回投，前端那条 promise 永久 pending。
   现在挂了 `on_js_done`（用 `webkit_web_view_run_javascript_finish` 取 `GError`）打 `run js failed: …`；
   实测把页面 `_dispatch` 换成必抛实现后，宿主日志出现
   `run js failed: about:blank:31:78: Error: probe-boom`。Windows 侧一直是 `log_hr("ExecuteScript", …)`。
8. **页面可以伪造回投**（**已修**）：回投原先经 `window.postMessage(json, '*')` + 页面 `message` 监听器落地，
   任何拿得到 window 的脚本（包括被注入的第三方脚本）都能投一条假 `resolve` / `event` 冒充原生。
   改成直派 `__CJ_TAURI__._dispatch(json)` 后监听器删除，这个投递面随之消失；
   实测页面自己 `window.postMessage({type:'event',…}, '*')` 时监听器被调 **0** 次。
9. **本轮未验证的部分（如实说明）**：Windows 宿主只做了编译校验（本机无 WebView2 头文件），
   协议同构但未在本机实机跑；「让 socket 客户端也跑在同一个 webview 里」的严格对照实验没做
   （§4.3 的对照是量级参考，不是胜负判决）；性能数字是 3 次运行的中位数、无显示器（Xvfb）环境，
   不能直接外推到有真实 GPU/合成分辨率的桌面。

## 8. 复现本文的数字

探针本身随仓库发布，不需要额外工程：

```bash
# 1) 编译探针（Linux 还需先构建 C 桥：bash native/build_linux.sh → native/libcjtbridge.so）
cd examples/ipc-bench && cjpm build

# 2) 跑基准：无显示器机器用 Xvfb；结果全部落在 stderr（日志以 BENCH 开头）
xvfb-run -a ./target/release/bin/main 2>&1 | grep BENCH

# 3) 同机对照：localhost WebSocket vs 裸 TCP 回显（Node 22 起自带 WebSocket 客户端，无需装依赖）
node scripts/bench-ws-vs-tcp.js
```

本文数字对应的真实输出（原样摘录）。**改动前**（回投走 `window.postMessage`，每条响应一次 eval）——
历史记录，那份日志文件已被后续运行覆盖，摘录按原样保留：

```
[frontend] BENCH latency_scaled n=2000 wall=893ms mean=446.5us ops/s=2240
[frontend] BENCH deny_scaled n=2000 wall=752ms mean=376us ops/s=2660
[frontend] BENCH throughput n=500 wall=78ms ops/s=6410
[frontend] BENCH payload bytes=1024 iters=100 mean=0.54ms MB/s=1.808
[frontend] BENCH payload bytes=65536 iters=40 mean=2.025ms MB/s=30.864
[frontend] BENCH payload bytes=1048576 iters=10 mean=16.8ms MB/s=59.524
[frontend] BENCH events n=200 received=200 wall=23ms per=0.115ms
[frontend] BENCH done
```

**改动后 / 当前实现**（回投直派 `_dispatch` + 批处理 + 单条快路径）——2026-10-02 连跑三轮，
下面是吞吐为中位的那一轮（第 1 轮），与 `/tmp/ipc-bench-linux.log` 逐字节一致：

```
[frontend] BENCH start ua=Mozilla/5.0 (X11; Ubuntu; Linux x86_64) AppleWeb
[frontend] BENCH latency n=200 ping min=0ms p50=1ms p95=2ms max=7ms mean=0.75ms
[frontend] BENCH latency_scaled n=2000 wall=785ms mean=392.5us ops/s=2548
[frontend] BENCH deny_scaled n=2000 wall=700ms mean=350us ops/s=2857
[frontend] BENCH throughput n=500 wall=50ms ops/s=10000
[frontend] BENCH payload bytes=1024 iters=100 mean=0.5ms MB/s=1.953
[frontend] BENCH payload bytes=65536 iters=40 mean=1.725ms MB/s=36.232
[frontend] BENCH payload bytes=1048576 iters=10 mean=22.1ms MB/s=45.249
[frontend] BENCH events n=200 received=200 wall=12ms per=0.06ms
[frontend] BENCH done
```

（§4.2 的每一行都取这三轮的中位：吞吐 10000 / 9615 / 10638 → 10000 ops/s；1 MB 回显 45.2 / 70.9 / 68.5 →
68.5 MB/s；事件 0.06 / 0.015 / 0.02 → 0.02 ms/条。单轮取样波动大——引用时按 3 轮中位，不要挑最好的一轮，
也不要把单轮数字当结论。§6 里的 11905 ops/s 是更早那次「只换 C 桥」A/B 对照的吞吐中位，两者属同一档。）

```
payload=41B n=200 warmup=20 node=v22.22.0
WS   localhost ws://127.0.0.1 min=0.112ms p50=0.131ms p95=0.215ms max=0.945ms mean=0.151ms
TCP  localhost tcp echo  min=0.051ms p50=0.059ms p95=0.137ms max=0.399ms mean=0.077ms
```

跑之前注意两件事：**工作目录必须是工程根**（`capabilities/` 与页面资源都按相对路径读，
本探针只用到 `capabilities/`）；**探针要 `cjpm run` 或按上面的方式补齐 `LD_LIBRARY_PATH`**，
直接双击/直跑二进制在 Linux 上会因找不到 `libstdx.encoding.json.so` 而静默退出。

## 9. 参考

- Tauri v2 官方文档《Inter-Process Communication》——IPC 风格（Asynchronous Message Passing）、
  两个原语（`Commands` / `Events`）、底层「JSON-RPC like protocol」、参数与返回值需可 JSON 序列化、
  「报文传递比共享内存或直接函数调用更安全，接收方可自由拒绝或丢弃请求」：
  <https://v2.tauri.app/concept/inter-process-communication/>
- Tauri 2.0 发布说明——`allowlist` 被 permissions / scopes / capabilities 取代，
  core 判断一条 invoke 是否允许到达命令函数：<https://v2.tauri.app/blog/tauri-20/>

本仓库内的对应实现（改协议前先读这四处文件头注释）：

| 内容 | 位置 |
|---|---|
| 报文定义（协议权威描述） | `src/ipc_message.cj` |
| 分发 / 能力校验 / 异步执行 / 事件推送 | `src/ipc_hub.cj` |
| 前端桥 + reload 拦截 + 回投队列（桥 JS 两平台共用一份） | `native/bridge_js.h`、`native/bridge_linux.c`、`native/bridge_win.c` |
| 装配与 `jsSink` 接线 | `src/app.cj`、`src/host.cj` |
| 能力模型（与 Tauri permissions 对照） | `src/capability.cj`、`docs/RFC-插件体系.md` |
| 性能探针 | `examples/ipc-bench/`、`scripts/bench-ws-vs-tcp.js` |
| 线程模型与平台约束 | `AGENTS.md` §2、§4 |

