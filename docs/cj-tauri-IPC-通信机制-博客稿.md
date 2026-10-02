# cj-tauri 的 IPC 到底怎么走的：一次 invoke 的全程

先给个数，免得后面全在抽象的「链路」里打转。

Linux + WebKitGTK，2 vCPU 的容器，一次 `invoke` 从页面发出到 promise 落地，平均 **0.39 ms**——2000 次总墙钟 781 ms，约 2561 ops/s。不等回地连发 500 条，吞吐能到 **1.0 万 ops/s**（三轮 9615 / 10000 / 10638，取中位）。同一台机器上，一条 localhost WebSocket 往返是 0.151 ms，裸 TCP 是 0.077 ms。

三个数在同一档。这个「同一档」比谁快谁慢重要得多，第五节再说。

数字来自仓库自带的探针，命令在文末，可以自己跑。

## 链路其实只有三层

cj-tauri 是「仓颉后端 + 系统 WebView 前端」。IPC 就是这两者之间的桥，桥分三层，每层只干一件事：

```
页面 JS    window.__CJ_TAURI__ { invoke, listen, emit, reload }
          出站：JSON.stringify(obj) → postMessage(一条字符串)
──────────────────────────────────────────────────────────────
宿主桥 C   Linux  ：window.webkit.messageHandlers.cjtauri.postMessage
           Windows：window.chrome.webview.postMessage
           入站：原生回调 → 原样交给仓颉（C 层不解析 JSON）
           回投：_dispatch(json)，加锁队列 + 空闲回调合并成批
──────────────────────────────────────────────────────────────
仓颉       解析 → 能力校验 → 命令分发 → worker 执行
           结果经 jsSink → 宿主 runJs → 回投
```

没有 socket，没有本地 HTTP 服务，没有端口。传输层用的就是 webview 自己那条消息通道——JS 和仓颉本来就活在同一个进程里，中间只隔一层原生消息回调，再架一层网络栈是自找麻烦。

有一条约束值得单独拎出来：**平台差异只允许出现在两个地方**，仓颉侧的 `@When` 条件编译，和 `native/bridge_linux.c` / `bridge_win.c`。协议、报文、能力校验、命令分发两平台共用一份代码。所以下面这套流程，Windows 和 Linux 是同构的，差别只在 API 名字和「V8 跑在独立进程里」这一点。

## 报文只有四种，外加一条走后门的

| 报文 | 方向 | 形状 |
|---|---|---|
| invoke | JS → 仓颉 | `{"type":"invoke","id":1,"cmd":"greet","args":{…}}` |
| emit | JS → 仓颉 | `{"type":"emit","id":2,"event":"save-done","payload":{…}}` |
| resolve | 仓颉 → JS | `{"type":"resolve","id":1,"ok":true,"data":…}` 或 `ok:false,"error":"…"` |
| event | 仓颉 → JS | `{"type":"event","event":"tick","payload":{…},"window":"main"}` |
| 控制消息 | JS → 宿主 | 裸字符串 `__cj_tauri_reload__`（不进仓颉） |

细节里有几个坑，都是踩出来的：

**链路上只有字符串。** `postMessage` 传的都是 `JSON.stringify` 的结果，C 桥原样上交，整条链路只解析一次 JSON，在仓颉侧（stdx 的 `JsonValue.fromStr`）。C 层永远不知道报文里写了什么。

**请求和响应靠 `id` 配对，不靠顺序。** 前端自增一个 `seq` 当 id，把 promise 的兑现函数存进 `pending[id]`，回投时按 id 取出来兑现。另外有个不太符合直觉、但有意为之的行为：**同一个命令并发调用不保证执行顺序**。执行挪到 worker 之后天然并发，要保序就得加队列，我们判断不值——真有顺序要求，在业务层排队比在框架里排更清楚。

**成功和失败共用一种报文。** 都是 `type:"resolve"`，失败只是多个 `ok:false`。代价是协议层看不出成败，前端必须看 `ok`；收益是分发端只有两个分支（`resolve` / `event`），前端桥那一百多行 JS 能一直保持可读。

**reload 走旁路。** `__cj_tauri_reload__` 是个裸字符串，C 桥 `strcmp` 命中就自己处理（记日志、投递重载），根本不进仓颉，也不受能力清单约束。它是个宿主控制消息，不是业务命令。

## 一次 invoke 的全程

以 Linux 为例，一步一步走：

```
页面                  C 桥(GTK 线程)          仓颉                     worker 线程
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

**出站。** `invoke(cmd, args)` 生成 id，把 promise 的兑现函数塞进 `pending[id]`，然后 `postMessage(JSON.stringify({type:'invoke', id, cmd, args}))`。就这一件事。

**入站，C 层。** Linux 是 `on_script_message`（`webkit_user_content_manager_register_script_message_handler` 注册的 `cjtauri` 通道），Windows 是 WebView2 的 `WebMessageReceived`。两端都只做两件事：拦 reload，把字符串上交。不解析、不路由。

**入站，仓颉侧。** `TauriApp` 装配时把 `host.setMessageHandler` 接到 `hub.handleRawMessage`。这里先解析，然后两道校验：能力清单放不放行这个命令，命令注册表里有没有这个命令。**两道拒绝都发生在调用线程上、同步返回**——这点后面还会提。

**执行。** 校验通过才 `spawn` 到 worker 跑 `handler.handle`。成功就 `IpcMessage.resolve(id, result)`，业务抛 `CommandException` 就把异常消息 reject 回去，其他异常统一 `reject(id, "command failed: …")`。后端怎么炸，页面都不会崩，只会让那一条 promise reject。

**回投。** worker 拼出 `_dispatch(<json>)` 交给 `host.runJs`，C 侧加锁入队，只允许宿主 UI 线程执行，执行完如果队列还有货就再调度一次。

**兑现。** 页面 `_dispatch` 按 id 找到 `pending`，`resolve` / `reject`，`await` 继续往下跑。

到此一次往返结束。下面三件事是这套流程里刻意的选择，踩过才知道为什么要这么写。

## 三处刻意的设计

### 一、回投必须排队，且只有 UI 线程能执行

回投可能来自任何线程：worker、事件推送、对话框回调。而 GTK / WebKit 只允许在创建它们的那个原生 pthread 上调用——这条大家都熟。

不熟的是后半句：**在 Linux 上，仓颉轻量线程的堆上协程栈会被 JSC 的栈边界校验直接 abort**。不是报错，是进程没了。所以我们也没法在 worker 里「小心点」凑合用。

于是宿主桥统一成一句话：**谁都能往队列里塞，只有宿主 UI 线程能执行**。Linux 用 `g_idle_add` 唤醒 GTK 线程，Windows 用 `PostMessageW(WM_CJT_FLUSH)` 唤醒窗口线程。配套结论是：**worker 里不要绕过桥去直接调 GTK / WebKit**，只能经 `jsSink` 排队回投。

### 二、能力校验留在调用线程，只有执行挪走

最常见的失败是「未授权」和「命令没注册」。这类错误必须即时、顺序确定，而且要为了它白开一个线程、白排一次回投，不划算。

所以线程模型是两段式：**校验同步、执行异步**。实测这条路径确实更快——拒绝 350 µs vs 成功 390.5 µs，差 40 µs 左右，正好是 `spawn` + `handler.handle` + 组装 resolve 的钱。

有个反直觉的推论：同步拒绝并没有因为「没走 worker」而变慢，它快是因为**根本不需要走**。这也是我劝人别为了微优化把校验挪进 worker 的原因——省不下时间，还会把「同步拒绝、顺序确定」的语义弄丢。

### 三、两个方向的 emit 不是同一个东西

仓颉 → JS 是 `ipc.emit(event, payload)`，前端 `listen` 订阅。这条路很轻：**没有 id 配对、没有 promise、没有 worker**（发射方本来就在某个线程上），所以单位成本只有 0.02 ms/条（三轮 0.06 / 0.015 / 0.02），比往返低了整整一个量级。

JS → 仓颉 是前端 `emit()`，后端 `app.listenEvent(name, handler)` 订阅。它**带 id、返 Promise**，因为要多一次回投。多花这次回投买来一件事：事件未授权时，`reject("event not allowed: …")` 会回到调用方手里。在这之前，未授权的事件只在 stderr 里丢一行，前端那条 promise 永远等不到结果。

这里有个我们**故意没对齐 Tauri** 的地方：前端 `emit()` 只投给后端监听器，**不回投给页面**。

Tauri 的 `emit` 是广播给所有监听者，`emit_to` 才是定向。但 Tauri 是先有多窗口，才需要区分「全局」和「定向」；我们现在只有 `"main"` 一个窗口，全局广播退化成自己发自己收——这是 Tauri 用户真实踩过的坑，官方 issue 的结论是 won't fix，不值得照搬。页面内要广播，用原生 `CustomEvent` 就好。

协议里 `window` 字段和桥的 label 过滤已经就位（空 = 广播），将来真做多窗口，投递侧接上去就行，**协议和前端一行都不用改**。

## 0.39 ms 拆开，谁在花钱

把一次往返按段落拆开，逐段记账：

| # | 步骤 | 在哪 |
|---|---|---|
| 1 | `JSON.stringify` + `postMessage` | 页面 JS |
| 2 | 原生回调 → 仓颉回调 | C 桥（跨 FFI） |
| 3 | `InvokeRequest.parse` | 仓颉 |
| 4 | 能力校验 + 命令存在性校验 | 仓颉（调用线程） |
| 5 | `spawn` 一个 worker | 仓颉（每条命令一次线程创建） |
| 6 | `handler.handle` | worker |
| 7 | 拼 resolve 的 JSON | worker |
| 8 | 入队 + 唤醒 UI 线程 | C 桥 |
| 9 | `run_javascript("__CJ_TAURI__._dispatch(<json>)")` | 宿主 UI 线程 |
| 10 | `_dispatch` → promise → `await` 续体 | 页面 JS |

拿拒绝路径对一下就有结论了：拒绝只走 1–4 + 8–10，350 µs；成功多走 5–7，390.5 µs。**业务相关的 5–7 段合计约 40 µs，剩下约 350 µs 全是固定开销**——JSON 编解码、两次跨语言边界、UI 线程里的 eval、promise 调度。

结论有点丧但很有用：**优化要冲着固定开销去，改业务代码没用。**

## 改了两处，第二次差点翻车

第一处，**回投从 `window.postMessage` 改成直派 `_dispatch(json)`**。

原来的回投脚本是 `window.postMessage(<json>, '*')`，靠页面上的 `message` 监听器落地。改成直派之后，省掉一次结构化克隆和一次 message 事件派发，顺带把「谁能向 `window.postMessage` 投递，谁就能伪造回包」这个投递面整个消掉了——监听器删了，可投递的目标不存在了。实测页面自己 `window.postMessage({type:'event',…})` 时，监听器被调用 0 次。

改的时候我还顺手写错过一句：注释里说这里能省一次 `JSON.parse`。**这是错的**，后来专门更正了——`<json>` 是被当作 JS 对象字面量嵌进 eval 的，页面拿到的本来就已经是对象，`typeof msg === 'string'` 那条分支压根不走。省的确实有，但不是 JSON 解析。

第二处，**回投批处理**：一次空闲回调把队列里最多 64 条响应拼成一段脚本，只 eval 一次，没取空就自续再排。

这里最值得说的是那个「差点交付的错误版本」。第一版只做了拼批，没做快路径，测出来顺序往返中位数 414.5 µs，**比基线 386.5 µs 慢了 7%**。原因很直白：最热的路上每次只有一条响应，却要白走一遍拼接和拷贝。

补上「队列里只有一条就直接用原字符串」的快路径后：

| 指标 | 改前 | 改后 |
|---|---|---|
| 管线化吞吐 | 6024 ops/s | **11905 ops/s**（约 2.0×） |
| 事件推送 | 0.105 ms/条 | **0.04 ms/条**（约 2.6×） |
| 顺序往返 | 386.5 µs | 390.5 µs（噪声内） |
| 1 MiB 回显 | 49.5 MB/s | 51.8 MB/s（噪声内） |

（Xvfb 同机、同一份应用二进制只换 C 桥，各 3 轮取中位。口径得说清楚：这张表是当时的 A/B 对照，「只换 C 桥」才能把这两处改动的收益单独摘出来；本文开头那几个数字则是 2026-10-02 对当前实现重跑三轮的中位——吞吐 9615 / 10000 / 10638 → 10000 ops/s，跟表里的 11905 同档，差异来自会话噪声；事件那一项同理，表里的 0.04 ms/条 是 A/B 当次的中位，今天重跑是 0.015–0.06、中位 0.02。）

快路径上线前还有个更阴的 bug：Linux 侧的投递守卫被我写成 `n > 0`，**单条消息被静默丢掉**——不影响拼批的批量场景，只在「一次只有一条响应」时命中，也就是最寻常的那条路。日志里什么都看不出来，是顺着顺序往返的时间不对才翻出来的。

这两个 bug 的共同点是：**性能代码错了不会报错，只会给你一个看起来合理的数字。** 没有前后对照的基线，这两个都会当成「优化完成」交出去。

## 那为什么不用 WebSocket？

这大概是这套 IPC 被问得最多的问题，提问的人通常已经准备好了一组数字：localhost loopback 的往返比 0.39 ms 快。

先看数字。同机实测：

| 方式 | mean | p50 |
|---|---|---|
| WebSocket `ws://127.0.0.1` | 0.151 ms | 0.131 ms |
| 裸 TCP 回显 | 0.077 ms | 0.059 ms |
| cj-tauri invoke（成功 / 拒绝） | 0.39 / 0.35 ms | — |

**但这组对照不是胜负判决**，因为两条线根本不在同一个执行环境里。WS 那条跑在 Node 里——没有 webview，没有页面事件循环，没有跨语言回调；cj-tauri 这条跑在 webview 里，每次都要跨 JS ↔ C ↔ 仓颉三道边界，还要付 JSON 编解码和线程 spawn 的钱。

它真正的价值是给出一个量级参考：三者都在 0.1–0.5 ms 这一档。也就是说，这一档的耗时主要由「报文编解码 + 调度 + 跨边界调用」构成，**跟有没有 socket 没关系**。

概念上更清楚的说法是：两者不在同一层。WebSocket 是传输层，它假定两端可能隔着网络；cj-tauri 的 JS 和仓颉本来就在同一个进程里，中间只隔一层 webview 消息回调——这里没有「传输层」可换。

用 WebSocket 做 IPC，等于自造一个传输层。它买到的是跨进程、跨机器、跨语言客户端；付出的是端口占用、握手开销、多一个常驻进程，以及「本机多了一个监听端口」这个额外暴露面。在单机同进程的场景里，这些付出换不到延迟上的收益。

顺便说清楚代价那边的账：**大 payload 我们确实不如二进制通道**。1 MiB 回显 14.6 ms、约 68.5 MB/s（这项单轮波动大，三轮 45.2–70.9），瓶颈是 JSON 编解码加单线程 JS。要搬 MB 级数据，正确做法是回句柄或路径、让上层自己解析，而不是指望把 JSON 往返调快；再往上就是专门开二进制通道，Tauri v2 也是往这个方向补的。

什么情况下 socket 反而合适？要跨进程跨机器、要持续双向流（视频帧、传感器数据）、前后端生命周期不同（后端常驻、UI 可关可开），或者已经有一套现成的 HTTP / gRPC 服务端想直接复用。只要守住「同进程 + 命令式 API + 单机」这三条，webview 消息通道就是更省的选择：少一层传输、少一个进程、少一个端口，能力校验还能卡在唯一入口上。

顺便说一句，这不是为省事找的理由。Tauri v2 官方文档对自家 IPC 的描述是同构的：风格叫 Asynchronous Message Passing，底层是「JSON-RPC like protocol」，参数和返回值必须可 JSON 序列化，而且官方明确写了「报文传递比共享内存或直接函数调用更安全，因为接收方可以自由拒绝或丢弃请求」——和我们「能力校验不通过就在 hub 里同步拒绝」是同一个思路。WebView 宿主框架不用 socket 做 IPC 是共识。

## 几个还没修的坑，以及一个修不起的

按诚实程度排序：

**读不出 `id` 的非法报文仍然没有回包。** 解析失败时会先尽量把 `id` 捞出来，捞到就回一条 `ok:false`，前端那条 promise 立刻落地——探针里页面投一条 `{"type":"wat","id":9001}`，能收到 `{"type":"resolve","id":9001,"ok":false,"error":"invalid IPC message"}`。但**捞不出 `id` 的（压根不是 JSON、或者缺 `id`）只能打 stderr**：没有 id 就对应不上任何 promise，回包也没地方落地。这类情况前端得自己加超时兜底。

**没有超时、取消、背压和丢包策略。** 命令发出去就只能等；事件连发会把宿主 UI 线程的脚本队列堆满——每条事件都是一次 eval，而且都在 UI 线程上跑。给 `emit` 加「同事件同 tick 合并」我们已经列进计划了，但还没做。

**UI 线程是稀缺资源。** 单条 MB 级 payload 或高频事件会直接卡住界面。这不是设计缺陷，是这台机器只有一条 UI 线程的物理事实——回投必须在它上面执行。

**同一命令不保序。** 前面说过，有意为之。需要顺序就在业务层排队。

有几条是这轮才补上的，值得记一下——它们都属于「不出事就永远发现不了」的类型：Linux 侧入站原先没有逐条日志（Windows 一直有 `js -> native (N bytes)`），排查时对不上数；Linux 回投原先不接执行结果，eval 失败只会静默丢掉这条回投，前端 promise 永久挂起，现在挂上了 `on_js_done` 打 `run js failed: …`（把页面 `_dispatch` 换成必抛实现验证过，宿主日志里确实出现了 `run js failed: about:blank:31:78: Error: probe-boom`）；还有上面说的伪造回投面，已经随直派一起消失。

最后说清楚没做的部分，省得有人拿这篇当验收报告：

- **Windows 只做了编译校验**，本机没有 WebView2 头文件，协议同构但没实机跑；
- 「让 socket 客户端也跑在同一个 webview 里」这个严格对照实验**没做**，上面那组 WS/TCP 数字只是量级参考；
- 性能数字是 Xvfb（无显示器）环境下三轮的中位数，**不能直接外推到有真实 GPU 和合成分辨率的桌面**。

## 复现

探针随仓库发布，不用另建工程：

```bash
# 1) 编译（Linux 先建 C 桥：bash native/build_linux.sh）
cd examples/ipc-bench && cjpm build

# 2) 跑基准，结果全在 stderr，日志以 BENCH 开头
xvfb-run -a ./target/release/bin/main 2>&1 | grep BENCH

# 3) 同机对照：localhost WebSocket vs 裸 TCP
node scripts/bench-ws-vs-tcp.js
```

（本文所有数字是 2026-10-02 三轮运行的中位，原始日志在 `/tmp/ipc-bench-round{1,2,3}.log`；单轮波动有多大，看 1 MiB 回显那一项就知道了——三轮 45.2 / 70.9 / 68.5 MB/s。）

两个前置条件，不满足会浪费你半小时：**工作目录必须是工程根**（`capabilities/` 和页面资源按相对路径读）；**Linux 上要 `cjpm run` 或自己补 `LD_LIBRARY_PATH`**，直接跑二进制会因为找不到 `libstdx.encoding.json.so` 静默退出——没有报错，没有输出，什么都看不到。

改协议之前，建议先读这四个文件头的注释：`src/ipc_message.cj`（协议权威描述）、`src/ipc_hub.cj`（分发与校验）、`native/bridge_js.h` 加两个 `bridge_*.c`（前端桥与回投队列）、`src/app.cj`（装配与 `jsSink` 接线）。

写这套东西最大的收获不是那几个数字，而是一条方法论：**先量，再改，改完再量，而且必须同一台机器、同一份二进制。** 中间态那 7% 的回退和丢单条消息的守卫，只有对照基线才看得见。

