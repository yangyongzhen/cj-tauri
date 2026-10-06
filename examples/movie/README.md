# 观影应用示例（examples/movie）

用**仓颉后端 + 系统 WebView 前端**做的 Windows PC 观影应用：榜单浏览 → 搜索 → 详情 → 播放。
影视数据来自开源接口服务 `http://49.235.52.102:8000`（`/static/docs/` 是它的接口文档页）；
本示例演示 cj-tauri 的三件套在真实业务里的用法——WebView 宿主、IPC 桥、能力白名单。

## 运行

```bat
examples\movie\run.bat
```

`run.bat` 做四件事：`cjpm build` → 把 SDK 运行时 / stdx / C 桥 / WebView2Loader 塞进 `PATH`
→ **切到 `examples\movie` 再启动**（应用按相对路径读 `capabilities\` 与 `ui\index.html`，工作目录必须是项目根）
→ 把应用 stderr 落到 `%TEMP%\cj-movie-app.log`，退出后自动摘出 `[movie]` 与 `[frontend]` 两类行。

`CANGJIE_HOME` / `CANGJIE_STDX` 与默认位置不同时，在跑之前自行 `set`。
`run.bat` 按项目规范保持**纯 ASCII**（cmd.exe 以 OEM 码页读 `.bat`，非 ASCII 字节会吞掉后续行）。

## 架构：请求为什么全在仓颉侧

前端**只经 `window.__CJ_TAURI__` 的 `invoke`**，页面里没有一处 `fetch`：

- 框架契约就是「前端只经桥说话」（`AGENTS.md` §3）；
- 页面由宿主 `NavigateToString` 载入，来源是 opaque（`Origin: null`）——即使后台带了
  `Access-Control-Allow-Origin: *`，把业务押在这上面也不对；
- 走 `invoke` 才拿得到本项目的取证通道：每次调用都在 stderr 留一行 `[movie]`，
  实机验证不必开 devtools 就能看到「页面点了 → 仓颉发出去了 → 后台回了什么」。

## 命令 ↔ 后台接口

命令在 `src/commands.cj` 实现、`src/main.cj` 注册、`capabilities/default.json` 声明（三处缺一不可），
后台路径与请求体在 `src/api.cj`。

| 命令 | 参数 | 后台接口 | 说明 |
| --- | --- | --- | --- |
| `movie:list` | `kind, start, count, city?` | `POST /api/v1/<kind>movie` | `kind` 取 `hot/new/soon/top/week/us`；只有 `hot`（hotmovie）要 `city` |
| `movie:search` | `q, start, count` | `POST /api/v1/searchmovie` | 关键词必填 |
| `movie:detail` | `id` | `POST /api/v1/detailmovie` | 返回件名、评分、简介、演员 |
| `movie:source` | `sid` | `GET /api/v1/mvsource/{sid}` | 播放源总表：**主源**的 `tvurls`（剧集各集）/ `urls`（电影线路），外加全 20 个源的元信息（`items[]` 全字段 / `sources[]` 精简版，`primary` 标出哪个是主源） |
| `movie:sourceitem` | `sid, note, aid?` | `GET /api/v1/mvsourceitem/{sid}?note=&aid=` | 切源用：某个具体源的完整 `tvurls`（按源 1–13KB）。`note` / `aid` 是页面可控串，命令层白名单（`note` 限 `[a-z0-9_-]` 且 ≤32，`aid` 只许数字或空串） |
| `movie:image` | `url` | —（取回图片字节） | 封面/海报/演员头像：仓颉侧带正确 `Referer` 取回，转 `data:` URL 交给页面（见下节） |
| `report` | `line` | —（只打 stderr） | 页面侧结论回传，实机取证用 |
| `system:version` | — | — | 框架内置命令 |

后台文档页 `docs_script.js` 指向的 `swagger/imovie.json` 是接口清单来源；`getmvmenus` /
`musicmenus` 这类菜单接口本示例未使用。

## 前端

单页 `ui/index.html`（无构建、无 Node）：Dark 影院风，四个视图——首页榜单（6 个 tab + 主角位 + 卡片网格
+ 加载更多）、搜索结果、详情（海报 / 评分 / 简介 / 演员）、播放（`<video>` + 剧集集数按钮 / 电影线路列表
+ 复制地址）。

**剧集与电影的分流**（后台 `mvsource` 一个接口两种形状）：电视剧回的是 `urls:[""]`（占位空串）+
`tvurls:[…]`，电影才在 `urls` 里有内容。页面按「**`tvurls` 有值就是剧集**」分流：

- 剧集：播放器下方出「第一集 / 第二集 …」集数按钮（**下标即集数**，0 = 第一集；超四位直接回阿拉伯数字），
  点集数即切集，下面一行跟着显示当前集的地址 + 复制；
- 电影：`tvurls` 为空、`urls` 有值，仍是原来的线路列表。

空串一律当位置占位丢掉，不当可播地址。

**播放源切换**（后台 2026-10-06 改版后新增的一层）：一部片子在后台往往挂着 **20 个源**（不同站点、
甚至同名不同版本，如「优酷 动漫 194 集」与「优酷 国产剧 30 集」），而 `mvsource/{sid}` 返回的
`urls` / `tvurls` **只是主源那一份**——其余源的剧集要按 `note` + `aid` 现取（`movie:sourceitem`）。
所以页面在剧集按钮**上方**加了「播放源」胶囊区（比剧集更外层的一层选择）：

- 胶囊写「源名 + 分类 + 集数」，同名两版本靠分类区分；`primary` 那个标「主源」并默认高亮；
- **只有一个源时整个区不显示**（电影实测只有 1 条源，没得选）；
- 点某个源即切：`movie:sourceitem{sid, note, aid}` → 拿到该源 `tvurls` → **保留当前集数**
  重渲染集数按钮并从同一集起播（新源集数不够就落到它最后一集），播放页标题也跟着换
  （切到极速那个源标题会变成《凡人修仙传 重制版》）；
- 失败一律显示在播放器上，不静默回退：源不存在时后台回 **HTTP 200 + `code:404` +
  `message:"source not found"`**（不是 4xx），所以页面判的是 `code`，不能只看 invoke 有没有被拒。

- **为什么前端是独立文件而不是内联进 `"""`**：仓颉三引号字符串会处理反斜杠转义、`${}` 又与会插值同形，
  一整页 UI 塞进去必然踩坑（`AGENTS.md` §4 有实测记录）。独立文件后 `node --check` 就能验语法。
- **页面自检**：加载后自动跑 `system:version`、首页榜单、详情，并做一次**未授权对照组**
  （`movie:nope` 期望被能力校验拒掉）；结论右下角面板可见，同时经 `report` 命令落到 stderr。
- **HLS**：后台给的多是 `.m3u8`，而 WebView2（Chromium）不原生支持 HLS，所以首次播放 m3u8 时
  从 CDN（jsdelivr，失败回落 unpkg）取 `hls.js`；直链（mp4）走原生播放器，不联网取库。
  离线环境下首页 / 搜索 / 详情照常可用，播放会明确提示「HLS 播放器加载失败」并列出地址。

## 实机验收

看 `%TEMP%\cj-movie-app.log`（本项目以 stderr 为准——`println` 的 stdout 有缓冲，进程被强杀会丢）：

| 期望日志 | 说明 |
| --- | --- |
| `[movie] main start` | 装配到了 `main()` |
| `[movie] 前端页面已载入：ui/index.html（N 字节）` | 页面读到了 |
| `[movie] /api/v1/hotmovie -> 200 ok bytes=…` | 页面点下去，请求经仓颉侧发出并拿到 200 |
| `[cj-bridge] set window:` 一行 | 宿主窗口创建成功 |
| `[movie] image … -> 200 ok bytes=… image/jpeg` | 封面经仓颉侧取回（页面的 `<img src>` 直连是取不到的，见下节） |
| `[frontend] …` | 页面侧自检结论（含未授权对照组被拒一行） |
| `[frontend] movie:source(…) 剧集模式：N 集，从第一集起播` | 剧集分流命中（`tvurls` 有值），集数按钮已渲染 |
| `[frontend] 切集：第 N 集 -> …` | 点了第 N 集的按钮（电影模式下不会有这行） |
| `[frontend] 切源请求：uku/348 保留第 N 集` | 点了「播放源」里的某个源：先留请求（切到谁、保留第几集） |
| `[frontend] 切源成功：<note>/<aid> -> N 集，起第 M 集（标题 …）` | 切源拿到了该源的剧集并起播（集数按钮已按新源重渲染） |
| `[frontend] 切源被拒：… code=404 message=source not found` | 该源后台没有（HTTP 200 + `code:404`），播放器上同时显示错误 |

窗口里应看到卡片网格与主角位大图；点卡片进详情、点「立即播放」进播放页。剧集会看到集数按钮组、
当前集高亮，**上方还有一行「播放源」胶囊**（多源时才有，点一下即切源）；电影看到线路列表。
封面取不到的卡片会显示**生成式占位**（标题首字 + 色相渐变），这是设计内的降级，不是破图。

## 两条实机踩坑（都很容易白折腾半天）

### 1. 封面图必须绕仓颉侧取（页面的 `<img src>` 永远出不来）

后台给的封面全是**防盗链**资源。实测（2026-10-05，同一张图对照）：

| 请求方式 | 结果 |
| --- | --- |
| `image.baidu.com/search/down?url=…` + `Referer: https://image.baidu.com/` | **200，26628 字节**，`image/jpeg` |
| 同一地址 + 其它 Referer（或不带） | **200，0 字节**（注意不是 4xx） |
| `img*.doubanio.com` 原图 + `Referer: https://movie.douban.com/` | 200，26628 字节 |
| 同一原图 + 不带该 Referer | 418 |

失败形状是「**HTTP 200 + 空 body**」——前端只能从 `<img>` 的 `onerror` 知道它没成，
而页面**没法补救**：浏览器只允许用 `Referrer-Policy` *减少* Referer、不允许替换，
何况页面是 `NavigateToString` 载入的（来源 opaque），根本发不出图源要的那个 Referer。

所以 `movie:image` 走仓颉侧：想带什么 Referer 就带什么头，取回字节转 `data:` URL 交给页面。
前端 `posterHtml()` 刻意**不给 `<img>` 设 src**，地址放在 `data-cover` 里，
由「并发 4、同址去重、失败不留缓存」的取图队列去填；取不到就干净地留在一张
**生成式占位**（标题首字 + 按标题散列的色相渐变）上，而不是破图。
实机一轮（2026-10-06）38 次取图、30 次拿到字节，8 次是上游回 **HTTP 200 空 body**（含 `tv_default` 占位图）。

> `movie:image` 的参数是页面可控字符串，所以 `src/api.cj` 对地址做了**白名单**
> （只放行上面那两个图源）——否则这个命令就是「让后端替你请求任意地址」的 SSRF 跳板。

### 2. 仓颉 HTTP 客户端**不带默认 TLS**，https 请求要先配

`stdx.net.http` 的 `ClientBuilder` 不配 TLS 时，发 https 请求直接抛：

```
HttpException: TLS must be configured when HTTPS requests are sent.
```

后台 API 是 `http://`，所以这条一直没暴露；封面是 `https://`，第一轮 54 次取图**全军覆没**。
修法是显式挂 `TlsClientConfig()`（默认走系统证书库校验，别图省事关校验）：

```cangjie
ClientBuilder().tlsConfig(TlsClientConfig()).build()
```

顺带一条：`readToEnd(resp.body)` 编译不过——它要求 `T: InputStream & Seekable`，
而 `resp.body` 的静态类型只有 `InputStream`，得自己按块读到 EOF（`src/api.cj` 的 `readBodyBytes`）。

## 上游接口现状（2026-10-05 实测，2026-10-06 复核）

| 接口 | 现状 |
| --- | --- |
| `hotmovie` / `soonmovie` / `topmovie` / `usmovie` / `detailmovie` | 可用（HTTP 200 + 数据） |
| `newmovie` / `weekmovie` | HTTP 200，但 `code=0` + `message=403 Forbidden`（上游限流） |
| `searchmovie` | 可用（HTTP 200 + 数据；实测关键词返回 20 条） |
| `mvsource/{sid}` | 可用（HTTP 200）。改版后只回**主源**的 `urls` / `tvurls`，另带 `items[]`（20 条全字段）/ `sources[]`（精简版，含 `primary`）；实测 `sid=35861087` 回 18738 字符 / 194 集（改版前同片是 ~139KB） |
| `mvsourceitem/{sid}?note=&aid=` | 可用（HTTP 200）。实测 `note=uku&aid=348` 10778 字符 / 194 集，`note=jszy&aid=25010` 1163 字符 / 21 集，`note=uku`（不带 aid）194 集。源不存在时**照样 HTTP 200**，靠 `code:404` + `message:"source not found"` 判 |
| `getmvmenus` | Request Timeout（未使用） |

因此页面把「业务级失败」（HTTP 200 但 `data` 为空）与「传输级失败」（503）**分开**显示：
前者露出后台的 `message`，后者给出可重试的提示，播放页还会把拿到的地址列出来供复制到系统播放器。

`mvsource` 实测（2026-10-06）**已恢复且已改版**：`sid` 就取影视 `id`（两者都是豆瓣 id），
`35861087`（凡人修仙传）主源回 194 集，`items[]` / `sources[]` 列出全 20 个源（`uku` 同名两版本
348 / 58817、`jszy` 21 集的《凡人修仙传 重制版》等）。但**地址当前播不出来**——集地址的域名
`cdn.wlcdn99.com` 解析不到记录（本机 `nslookup` 走 8.8.8.8 是 `NOERROR` 却无 A/AAAA/CNAME，
`curl` 报 `Could not resolve host`；同机 `image.baidu.com` 正常解析），所以 hls.js 一律
`manifestLoadError`。**这跟跨域无关**：页面是 opaque 来源、源站又没给 ACAO 时确实也报这个错，
但本例连 DNS 都没过。排查顺序应该是「先解析域名，再看跨域」。

## 文件

```
examples/movie/
  cjpm.toml               # 应用包（依赖框架 + stdx）
  capabilities/default.json  # 能力白名单：commands 与上面表格一一对应
  run.bat                 # Windows 启动脚本（纯 ASCII）
  src/main.cj             # 装配：窗口配置 → 注册命令 → 读页面 → run()
  src/api.cj              # HTTP 传输层（TLS/Referer/按块读流）+ 榜单路径映射 + 封面白名单
  src/commands.cj         # 六个命令 + report + 参数读取助手
  ui/index.html           # 前端单页（HTML + CSS + JS，无构建；含取图队列、生成式占位、剧集集数按钮与播放源切换）
```
