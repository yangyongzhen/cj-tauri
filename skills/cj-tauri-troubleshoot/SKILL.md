---
name: cj-tauri-troubleshoot
description: cj-tauri / 仓颉开发的踩坑速查：编译报错、三引号字符串转义、@When 平台、FFI/C 桥、WebKitGTK 下拉框配色、异步命令线程模型等实测坑。当遇到仓颉编译错误、cj-tauri 行为异常、或写代码前预防踩坑时使用。
---

## 何时使用

- 仓颉/cjpm 编译报错看不懂、链接期 undefined reference
- cj-tauri 应用行为异常：页面白屏、命令没反应、事件收不到、窗口不起
- 写新代码前的预防性速查（这些坑全部**实测踩过**，别重踩）

## 速查表（按症状对号入座）

### 编译期

| 症状 / 写法 | 原因与修法 |
|---|---|
| 注释永不闭合、报莫名错误 | 块注释里出现 `/*` 开嵌套注释；路径通配（如 `*.json`）改写或换行注释 |
| `error: expected '#' or '"' in raw string` | `#` 不是注释符（是 raw string 前缀）；行注释一律 `//` |
| `unexpected main function in string interpolation` | `${main}` 撞同名函数；换个变量名 |
| `expressions of type 'Array' are not constant` | `const X: Array<String> = [...]` 不合法；顶层不可变量用 `let` |
| `no matching function for operator '()'` | `ArrayList.size` 是**属性**（无括号）；`JsonObject.size()` / `JsonArray.size()` 才是函数（必须带括号） |
| `unable to infer generic argument` | `JsonArray.size()` 漏了括号 |
| for-in JsonArray 编译不过 | `JsonArray` 不实现 `Iterable`；按 `0..size()` 索引 `get(i)` |
| lambda 编译不过「无法捕获可变局部变量」 | lambda 不能捕获 `var` 局部变量；用容器带出（`let seen = ArrayList<String>()` 再 `add`） |
| FFI 调用报 count 参数错 | `CPointer` 调用要**具名传参** `count=` |
| `ld.lld: undefined symbol: cjTauri:cj_bridge_*` | 子包（单测）调不了框架的 `foreign func`；在框架包内包一层可跨包函数 |
| `stdx.net.http` 报 TLS must be configured | `ClientBuilder().tlsConfig(TlsClientConfig())` 必须显式配 |
| `readToEnd(resp.body)` 编译不过 | 它要求 `Seekable`；自己按块读（`ByteBuffer.write` + `body.read(chunk)`） |
| 浮点转整数运行时炸 | `Int64(x * 10.0)` 越界抛异常（不像 C 静默截断）；转换前先夹范围 |

### 运行期 / 页面

| 症状 | 原因与修法 |
|---|---|
| 内联页面一行 JS 都不执行、stderr 无提示 | 三引号字符串处理反斜杠转义：JS 的 `\n` 被吃成真换行拆断 `<script>`。换行用 `String.fromCharCode(10)`，正则改 `indexOf`，改完 `node --check` 验；页面大就独立成 `ui/index.html` |
| 前端读 `window.__CJ_TAURI__` 是 undefined | 桥/插件 shim 在 document-start 注入，但模块作用域别直接读；用 `waitForBridge` 轮询等桥出现 |
| `command not registered` | 三处联动漏了第 2 处（`register` / `plugin()` 装配） |
| `command not allowed` | 三处联动漏了第 3 处（capabilities `commands` / `permissions` 声明） |
| 命令「没反应」、日志里也没有错误行 | handler 抛异常只回 reject 不打日志；把 reject 也回投给页面 `report`，并确认框架已带 `command failed` stderr 行 |
| 慢命令冻住窗口 | 命令必须在 worker 线程跑（框架已异步分发）；**不要**把 `handler.handle` 挪回调用线程 |
| worker 里直接调 GTK/WebKit abort | 仓颉轻量线程的堆上协程栈会被 JSC 栈边界校验 abort；worker 只经 `jsSink` 回投 |
| 深色页里 `<select>` 白底浅字不可读 | WebKitGTK 用原生 combo 浅色样式盖掉页面配色；`-webkit-appearance:none` 自绘 + 给 `option` 另写底色文字色 |
| 3D 画布整幅走样 | WebView2 初建时视口是临时尺寸且变化不触发 `resize` 事件；把 `innerWidth/Height` 自检放进 `requestAnimationFrame` 每帧比 |
| 防盗链图 `HTTP 200 + 0 字节` | 页面侧无解（只能减 Referer 不能换）；宿主命令带正确 `Referer` 取回转 `data:` URL，地址必须白名单（防 SSRF） |
| 迭代 String 数汉字错了 3 倍 | 迭代得到 `UInt8` 字节不是码点；按 UTF-8 首字节判 `(b & 0xC0u8) != 0x80u8` |

### 多窗口 / 回调

| 症状 | 原因与修法 |
|---|---|
| 后装配的窗口收不到自己的事件 | 静态单槽被覆盖；宿主级回调一律**按句柄路由**（报文自带 label 的消息回调才可用单槽） |
| 新增宿主回调后 C 侧签名不对 | `cj_on_*_fn` 首参必须 `struct cj_host *`（回调要自带身份） |
| 改了 C 桥导出后链接炸一串 undefined reference | 桥是本地产物不入库；先 `bash native/build_linux.sh`（或 `native\build_win.bat`）重建再构建/测试 |

## 规则

- 修完一个坑，把「症状 → 原因 → 修法」沉淀回本 skill 或项目 `AGENTS.md` §4（见 `cj-tauri-contribute`）；
- 平台标识不要发明未验证的（没跑过 macOS 就别写 `@When[os == "macOS"]`）；
- 上面每一条都在真实项目里踩过并验证过修法；与你的症状不完全相同时，先读项目 `AGENTS.md` 再判断。
