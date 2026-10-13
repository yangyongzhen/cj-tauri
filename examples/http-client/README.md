# HTTP API 客户端（examples/http-client）

用 cj-tauri 写的 HTTP 调试客户端（Postman 那一类）：**左边拼请求 / 中间看响应 / 右边管集合与历史**。
零 Node、零前端库、页面里**一次 `fetch` 都没有**——能拿到的数据全走 IPC，网络请求由**仓颉侧**直发。

它同时是几件框架能力的活样板：

| 展示的东西 | 落在哪 |
| --- | --- |
| 仓颉侧直发 HTTPS（TLS 走系统证书库，**不关校验**） | `http:send` → `stdx.net.http`（`ClientBuilder().tlsConfig(TlsClientConfig())`） |
| 大响应体的**回投边界**如实上报 | 体上限 + `bodyTruncated` / `bodyLimit` / `contentLength` 三个字段 |
| **命令放行 ≠ 路径放行** | 清单 `scopes.fs` 只放行 `$CWD/data` 及其下（集合 / 历史 / 变量集落盘） |
| **4xx / 5xx 是结果，不是异常** | 三分 `Exchange` / `Refused` / `Failed`：只有 scheme 不支持、host 不在白名单、传输层失败才 reject |
| 宿主参数交给页面（页面读不到进程环境） | `http:allow` 回投白名单 / 自检开关 / mock 地址 |

> HTTPS 那句说明白：`TlsClientConfig()` 默认就用系统证书库校验（与 `examples/movie` / `examples/music` 同一写法），
> 本示例**没有任何**「关校验」的开关。但离线证据链里的对端是 `http://`（见下），
> 所以「https 实机通了」这句本轮**没有**单独取证——不写进结论。

## 快速跑通

```bash
# 1) 先构建 C 桥（Linux；Windows 用 native\build_win.bat）
bash native/build_linux.sh

# 2) 一键跑（脚本会起 mock 对端 + 跑完整 E2E 取证，无显示器时自动进 Xvfb）
bash examples/http-client/run.sh
```

想自己在窗口里点，就手工三步：

```bash
# ① 起一个 mock 对端（纯 python3 标准库，零第三方依赖）
python3 examples/http-client/mock-http.py --port 8611 &

# ② 工作区要先建好（插件的面里**故意没有 mkdir**，见下），然后启动
cd examples/http-client
mkdir -p data
CJ_HTTP_MOCK_BASE=http://127.0.0.1:8611 CJ_HTTP_ALLOW=127.0.0.1 cjpm build
./target/release/bin/main
```

启动时的三个环境变量（都是**给宿主**的，页面读不到进程环境）：

| 变量 | 作用 | 缺省 |
| --- | --- | --- |
| `CJ_HTTP_MOCK_BASE` | 右栏「mock 端点」快捷按钮 + 自检用的地址 | 空（按钮不给地址，自检跳过 mock 组） |
| `CJ_HTTP_ALLOW` | 出网白名单（逗号分隔；`*` 表示全放行） | **只放本机**（`localhost` / `127.0.0.1` / `::1`） |
| `CJ_HTTP_SELFCHECK` | 置 `1` 时页面自动跑一轮自检 | 关 |
| `CJ_HTTP_BODY_LIMIT` | 响应体读取上限（1 B ~ 64 MiB，越界忽略） | 1 MiB |

`data/` 目录同样由脚本保证存在：**插件面里没有 mkdir**，建目录属于应用装配期的事，
不该由一个「页面能调到的命令」持有。没建目录就去保存集合，页面会把**原文**显示出来
（`fs:writeText failed: no such file: …/data/collections.json`），而不是吞成一句「保存失败」。

## 界面与操作

**左栏 · 请求构建**

- 方法下拉（GET / POST / PUT / PATCH / DELETE / HEAD / OPTIONS）+ 地址输入框，地址与头值里的 `{{变量}}` 会按当前变量集展开
- 请求头一行一对，可加可删——**同名头允许重复**（`Cookie` 之类合法多值，用对象存会静默吞掉）
- 请求体是纯文本域；超时（1 ms ~ 120 s）与体上限（1 B ~ 64 MiB）都能就地改，越界会被仓颉侧夹回范围
- 「mock 端点」是一排快捷按钮：点一下把方法 / 地址 / 体填好（`/slow` 还会顺手把超时改成 500 ms，好演示超时）

**中栏 · 响应查看**

- 一行元信息：状态码（按 2/3/4/5 上色）、耗时、体积、体类型、**是否被截断**
- 三个标签页：响应体 / 整段原文 / 响应头；响应体可在「原文」与「JSON 树」之间切（树是 `details` 折叠，零依赖）
- 响应头**逐条列出、不合并**同名头（`Set-Cookie` 出现两次就显示两行并标 ×）
- 「整段原文」是可直接复制去贴 issue 的形式：`HTTP <状态> <方法> <地址>` + 逐条头 + 空行 + 体

**右栏 · 变量集 / 集合 / 历史**

- 环境变量集：`{{base}}` 这类占位符的来源，改完点「保存」才落盘（`data/envs.json`）
- 集合：把当前请求存下来（存的是**原文**——变量不展开，这样换个变量集就能换目标），点一条灌回左栏
- 历史：最近 30 条，记方法 / 地址 / 状态 / 字节 / 耗时（`data/history.json`）

> 全程不用 `window.prompt` / `confirm`：嵌入式 WebView 里脚本对话框各家实现不一，
> 没接宿主信号就是「点了没反应」。新建变量集自动命名，这类宿主依赖一律换成页内实现。

## 请求与响应契约（`http:send`）

| 入参 | 说明 |
| --- | --- |
| `method` | 方法名，大小写不敏感（页面传 `get` 也按 `GET` 发） |
| `url` | 完整地址；白名单与 scheme 在**建客户端之前**就判掉 |
| `headers` | `[{ "name": "...", "value": "..." }, …]`（数组，允许同名重复；空名丢弃） |
| `body` | 可选；**不传**与传空串是两回事（后者会带一个 0 长度的体） |
| `timeoutMs` | 可选，1 ~ 120000，越界夹回 |
| `bodyLimit` | 可选，1 ~ 64 MiB，越界夹回 |

回投的字段（`Exchange` 的 JSON）：`method` / `url` / `status` / `elapsedMs` /
`headers[{name,value}]` / `bodyKind`（`empty` \| `text` \| `binary`）/ `bodyText` / `bodyBytes` /
`bodyTruncated` / `bodyLimit` / `contentType` / `contentLength`（对端没给就是 `null`）。

**二进制体只报字节数，不回投原始字节**：把非法 UTF-8 塞进 IPC 只会让页面显示乱码或炸掉，
不会让用户更明白（`bodyKind=binary` + `bodyBytes` + `contentType` 够用了）。

## 白名单与路径 scope

`capabilities/default.json` 全文：

```json
{
  "identifier": "default",
  "windows": ["main"],
  "commands": ["report", "http:allow", "http:send", "system:version"],
  "permissions": ["fs:default"],
  "scopes": { "fs": { "allow": ["$CWD/data", "$CWD/data/**"] } },
  "events": []
}
```

两件容易混的事，这里各演示一半：

- **命令放行 ≠ 参数放行**：`fs:default` 只是「允许调这些命令名」，能不能碰**某个路径**由 `scopes.fs` 说了算。
  `data/envs.json` 放行；`../etc/hostname` **拒**，且拒绝发生在共享层（`src/scope.cj`），示例里没有第二份路径判定。
- **出网白名单在示例自己手里**：`http:send` 是**示例自己注册的命令，不是插件**——
  HTTP 客户端的能力面就是「任意 URL」，做成插件等于给所有应用开一条通用出网通道（`docs/设计决策记录.md` D-017）。

两处拒绝的形状（这也是 E2E 双侧对账的取信方式）：

```
[http-client] refused: host=example.invalid not in allowlist (127.0.0.1)
[cj-tauri] scope denied (fs): ../etc/hostname -> /root/test/cj/cj-tauri/examples/etc/hostname
[cj-tauri] command rejected (http:send): 请求失败：HttpTimeoutException: Client1.1 read response timeout and the connection is closed.
```

## mock 对端（`mock-http.py`）

纯 python3 标准库、零第三方依赖，9 条路径分支：`/health` `/json` `/text` `/echo`（GET 与 POST）
`/status/<码>`（如 `/status/404`）`/slow?ms=` `/big?kb=` `/binary` `/redirect`（302 → `/json`）。

- `--selftest` 自带 **16 项断言**（服务端起在随机端口、用 `http.client` 打自己），退出码即结论
- `--port 0` 让系统分配端口，启动后打一行 `READY port=<端口>`（脚本唯一可靠的「起好了 + 端口是多少」）
- 每行前缀 `[mock-http] `，逐行 flush：`REQ method=… path=… query=… ct=… len=…` /
  `RESP status=… path=… bytes=…`（`bytes=` 是**真发出去**的体长，截断对账靠它）

**对端为什么自写而不是打真的公网 API**：E2E 要能离线跑、结果要可复现，
拿公网端点当断言锚点等于把「今天网通不通」写进结论里。自写对端的另一个好处是**两侧都有日志**，
于是「到底谁没说话」一眼可分。

## 自检（无人值守取证）

`CJ_HTTP_SELFCHECK=1` 时页面自动跑 **34 条**断言，每条经 `report` 回投成
`[frontend] SELFCHECK PASS|FAIL <名字> :: <细节>`，最后一行是聚合：

```bash
cd examples/http-client
CJ_HTTP_MOCK_BASE=http://127.0.0.1:8611 CJ_HTTP_ALLOW=127.0.0.1 CJ_HTTP_SELFCHECK=1 \
  ./target/release/bin/main 2>&1 | grep SELFCHECK
```

| 组 | 断言 |
| --- | --- |
| 白名单 / 变量 | 白名单已交到页面、`{{变量}}` 展开、未定义变量**原样保留**、变量集已载入 |
| 落盘与 scope | 写读往返一致（含中文与嵌套）、越界读**必须被拒** |
| JSON 端点 | 状态 200、`Content-Type`、自定义头、**同名头不合并（2 条 Set-Cookie）**、体逐字一致、体类型判定 |
| 渲染层 | 状态码已显示、头部表格行数与数据一致、JSON 树真的建出了节点（断言的是页面**显示出来的**东西） |
| 中文体 / 回显 | UTF-8 解码逐字、回显自定义头与查询串、回显 POST 体、**请求体字节数双侧一致** |
| 4xx / 5xx | 404 与 500 都**照常 resolve**（不是异常），页面拿得到状态码 |
| 超时 / 截断 | `/slow` 变成 reject；`/big` 报 `bodyTruncated=true`、`bodyBytes` 等于上限、`contentLength` 报全量 |
| 二进制 / 重定向 | 二进制体判为 `binary` 且只报字节数；重定向已跟随（最终 200） |
| 前置拒绝 | 白名单外的 host 与 `ftp://` 都被拒（**连客户端都不建**） |

聚合行是 `[frontend] SELFCHECK DONE passed=34 failed=0`。**看证据有一个坑**：`report` 是异步命令
（命令按 worker 并发分发），所以**明细行的先后不保证**、聚合行也不是「最后一行」；
判据只能是**计数一致**——聚合行的 `passed` 等于 PASS 明细条数、`failed` 等于 0。

## 实机 E2E

```bash
bash scripts/e2e/test-linux-http-client.sh     # 无 DISPLAY 时自动进 Xvfb
```

入口做的事：构建（缺产物时）→ **清干净工作区** → 对端自检（16 项）→ 起 mock →
带自检开关启动 → 等聚合行 → 收尾 → **把对端日志并入同一份证据日志** → 取证。

证据：`dist/e2e-evidence/linux-linux-http-client.json`（+ 同名 `.log`），当前 **55/55 断言通过**。
除了 34 条页内自检逐条 + 桥侧/对端侧断言，脚本还直接判四件**外部对账**：

| 对账 | 判据 |
| --- | --- |
| 自检计数 | 聚合行 `passed=34 failed=0`，且日志里 0 条 FAIL 行 |
| **截断三侧对账** | 对端说发出 `2097152` 字节 / 桥侧说只读了 `1048576` 且 `truncated=true` / 页面说 `bodyBytes=1048576` 且 `contentLength=2097152` |
| **对端 REQ/RESP 计数** | `REQ=11 RESP=10`，**差的那 1 条正是被超时中断的 `/slow`**（超时路径在对端侧看得见） |
| 请求体字节数 | 页面按 `TextEncoder` 自算 22 字节 == 对端 `Content-Length` 数出的 22 字节 |

另有三条负向证据：**无** `command not allowed` / `not registered` 误报、`scope denied` 恰好 **1 次**
（就是自检里那次故意越界）、被拒的 `http:send` 都在桥侧留了原因（超时 + 白名单 + scheme 共 3 条）。

## 平台状态（如实）

| 平台 | 状态 |
| --- | --- |
| Linux（WebKitGTK） | **已实机跑通**：55/55 断言，页内自检 34/0 |
| Windows（WebView2） | **未验证**（本示例没在 Windows 上跑过，也没进单文件打包） |

## 已知边界

- **不做 WebSocket / SSE / HTTP2 细节**：这一版就是 HTTP 请求-响应，别把「能连」说成「能推流」
- **不做证书 UI / 抓包代理 / OAuth**：TLS 用系统证书库默认校验，没有「忽略证书错误」的开关（刻意的）
- **不做 curl 导入导出 / 多标签并发**：集合是「一条请求」的最小模型，够演示 IPC 与 scope
- **一次一条请求**：命令之间是异步并发的，但界面按「当前这一条」呈现（没有请求列表的并发编排）
- **浏览器强制加的头改不了**：`Host` / `Content-Length` 由客户端自己决定，填了也不生效（这是 HTTP 客户端的常识）
- **没有流式输出**：响应体是**读完之后**一次回投的；超大响应靠体上限截断，别指望边收边显示

## 目录结构

```
examples/http-client/
├── cjpm.toml               # 示例工程（依赖框架包 + stdx）
├── capabilities/default.json
├── src/http_client.cj      # 网络层：白名单 / URL 校验 / 读体（带上限）/ 结果模型（不认识 IPC）
├── src/main.cj             # 装配：FsPlugin + report / http:allow / http:send
├── ui/index.html           # 全部界面（含页内自检），**独立文件**便于 node --check
├── mock-http.py            # mock 对端（python3 标准库，自带 16 项自检）
├── run.sh                  # 一键转发到 scripts/e2e/test-linux-http-client.sh
└── data/                   # 工作区：envs.json / collections.json / history.json（由脚本播种，不入库）
```

页面为什么**不内联**进仓颉三引号字符串：AGENTS §4 有一条实测坑——三引号字符串会先被仓颉处理
反斜杠转义，而这份页面里满是正则与转义，内联进去等于让整段 `<script>` 静默语法错误
（页面一行都不执行，stderr 毫无提示）。独立文件还顺带能被 `node --check` 静态验语法。
