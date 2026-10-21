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
| `cjc: command not found` / 原生进程退出码 127 且无输出 | 环境没配齐：cjc 在 SDK `bin`，cjpm 在 `tools/bin`；Linux 运行时 .so 还要 `LD_LIBRARY_PATH` 含 `runtime/lib/<平台>`——**先跑 `cj-tauri-env` skill 的一键检测**，缺哪样补哪样 |
| `root package ... imports package 'stdx...' but the dependency info is missing` | `CANGJIE_STDX` 指错了：必须指 `<stdx>/<三元组>/dynamic/stdx`（动态库目录，不是包根）；`create` 能成功、到生成工程 build 才炸，极具迷惑性 |
| Windows 上没有 / 不想装 Visual Studio | 不需要 MSVC：C 桥用 **llvm-mingw**（免安装，解压即用，安装见 `cj-tauri-env` skill） |
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
| `undefined reference to cjTauri.plugins.<插件>:…` | **先 `cjpm clean`**：增量缓存里的旧链接列表没带上新 import 的插件库，clean 后同一条构建即链上、`cjpm.toml` 一行不用改；别一上来就抄别的示例补 `-l` |
| `stdx.net.http` 报 TLS must be configured | `ClientBuilder().tlsConfig(TlsClientConfig())` 必须显式配 |
| `readToEnd(resp.body)` 编译不过 | 它要求 `Seekable`；自己按块读（`ByteBuffer.write` + `body.read(chunk)`） |
| 浮点转整数运行时炸 | `Int64(x * 10.0)` 越界抛异常（不像 C 静默截断）；转换前先夹范围 |

### FFI（`foreign func` 调 C 库）

| 症状 / 写法 | 原因与修法 |
|---|---|
| 出参怎么写 | 仓颉**没有 `&x` 取地址表达式**；调用处写 `inout <var>`（探针实测，2026-10-13） |
| C 回调（函数指针）怎么传 | 直接写 `CFunc<(...)->...>` 实参即可（sqlite3 的 authorizer 就是这样接的） |
| 想调第三方系统库 | `foreign func` 可以**直连系统库、不经 C 桥**：`cjpm.toml` 的 `link-option` 加 `-lsqlite3` 之类；Windows 侧要自带 DLL 并补进 `scripts/pack-win*.sh` 清单（分发口径见 AGENTS §5） |
| `sqlite3_open_v2` 报 `no such vfs:` | `zVfs` 参数传**空串**会被当成 VFS 名；要传 NULL |

### 运行期 / 页面

| 症状 | 原因与修法 |
|---|---|
| 内联页面一行 JS 都不执行、stderr 无提示 | 三引号字符串处理反斜杠转义：JS 的 `\n` 被吃成真换行拆断 `<script>`。换行用 `String.fromCharCode(10)`，正则改 `indexOf`，改完 `node --check` 验；页面大就独立成 `ui/index.html` |
| 前端读 `window.__CJ_TAURI__` 是 undefined | 桥/插件 shim 在 document-start 注入，但模块作用域别直接读；用 `waitForBridge` 轮询等桥出现 |
| `command not registered` | 三处联动漏了第 2 处（`register` / `plugin()` 装配） |
| `command not allowed` | 三处联动漏了第 3 处（capabilities `commands` / `permissions` 声明） |
| 命令「没反应」、日志里也没有错误行 | handler 抛异常只回 reject 不打日志；把 reject 也回投给页面 `report`，并确认框架已带 `command failed` stderr 行 |
| 慢命令冻住窗口 | 命令必须在 worker 线程跑（框架已异步分发）；**不要**把 `handler.handle` 挪回调用线程 |
| 拉起 CLI 后端时桌面上蹦出一个黑窗口（日志里无任何错误） | 应用是 GUI 子系统、没有控制台，`std.process.launch` 起控制台子进程时 Windows 会**给子进程单独配一个控制台窗口**；改走框架 `launchHidden()`（`CreateProcessW` + `DETACHED_PROCESS`，标准句柄指 NUL）。两个不算解法的：`SW_HIDE` 只是先建再藏、会闪；`CREATE_NO_WINDOW` 不显示但子进程仍持有一个**隐藏 console**（conhost 照样挂）。判据要 A/B：数可见 `ConsoleWindowClass` 窗口（1 → 2）+ `MainWindowHandle`（0 对非 0），并先用一个有窗口的进程校准读数 |
| worker 里直接调 GTK/WebKit abort | 仓颉轻量线程的堆上协程栈会被 JSC 栈边界校验 abort；worker 只经 `jsSink` 回投 |
| 深色页里 `<select>` 白底浅字不可读 | WebKitGTK 用原生 combo 浅色样式盖掉页面配色；`-webkit-appearance:none` 自绘 + 给 `option` 另写底色文字色 |
| 3D 画布整幅走样 | WebView2 初建时视口是临时尺寸且变化不触发 `resize` 事件；把 `innerWidth/Height` 自检放进 `requestAnimationFrame` 每帧比 |
| 防盗链图 `HTTP 200 + 0 字节` | 页面侧无解（只能减 Referer 不能换）；宿主命令带正确 `Referer` 取回转 `data:` URL，地址必须白名单（防 SSRF） |
| 迭代 String 数汉字错了 3 倍 | 迭代得到 `UInt8` 字节不是码点；按 UTF-8 首字节判 `(b & 0xC0u8) != 0x80u8` |
| 单文件 exe 28MB 不瘦身 | llvm-mingw 的 `strip.exe` 包装器缺 `llvm-strip` 真身，`strip 2>/dev/null` 吞了报错；回退 SDK 的 `llvm-objcopy --strip-all`（脚本已内置），排查先裸跑 strip 看真实报错 |
| 单文件包里嵌了外部程序（cjh 这类）却运行期找不到它、exe 体积也没涨 | 资源对象（windres 产出的 `.o`）塞进 `libcjtbridge.a` 后**不会被链接器提取**（静态库按需提取，它没有任何符号引用），产物照旧 `build success`、而 `objdump -h app.exe` 里数 `.rsrc` 一节是 0。落法：把它**当链接输入直接给 ld.lld**（打包器拼进 `link-option`），判据看节表不看构建日志 |
| rc 里写资源名 `"cjh.exe" RCDATA "…"` 编译失败 | `llvm-rc`（windres 的后端）不认字符串资源名，报 `expected int or identifier`。资源名只能数字 ID，文件名由打包器另生成 `pack_assets_map.h`（ID → 名字，编桥时 `-DCJ_PACK_ASSETS_EMBEDDED` 才包含），桥因此仍不认识应用的任何文件名 |
| 构建带一堆 unused/redundant 警告 | 接口成员不写 `public`（隐式公开）；未用参数就地 `let _ = x` 显式弃用；未用 import 删；`ReentrantMutex`→`Mutex`、`ArrayList.sort()`→`std.sort.sort`（交付标准：零警告，AGENTS §3） |

### 运行期 / 页面

| 症状 | 原因与修法 |
|---|---|
| 前端收到 `path is outside the authorized scope`，stderr 有 `[cj-tauri] scope denied (fs)` | **不是 bug**：清单给该插件写了 `scopes`，这条路径不在 `allow` 里（或命中了 `deny`）。要么把路径加进 `scopes`，要么改用白名单内的路径；`..` 与软链接都会被规范化拆穿，绕不过去。没写 `scopes` 的旧清单是全量放行的（启动有一行 stderr 提示） |
| 用户要用名单之外的服务商 / 端点（页面侧就是加不进白名单） | 这是**设计使然**（清单是启动时读的静态文件 = 出网防线，页面改不了）。放行要**人**点一下：框架 `TauriApp.allowScopePattern(plugin, pattern)` 运行期叠加（内存态、重启即空，回 `Bool`）+ `isScopeAllowed(plugin, value)` 查当前口径；持久化与启动重放归应用（样板见 `examples/ai-chat` 的 `app:allowHost`：原生确认框 → 加白 → 写 `~/.local/share/cj-ai-chat/allowed-hosts.txt`）。注册中心**只收具体值**：空串或含 `*` / `?` 与制表换行的模式当场拒并回 `false`（通配一进来就等于全放行），回 `false` 别当成功。口径不变：**先 deny 后 allow**，加白掀不掉 `deny`；插件名传字符串（`"http"` / `"fs"` / `"ws"`） |
| 随包 cjh 拉不起来 / 界面「AI 后端未就绪」，日志却是 `Created process failed … cannot find the file specified`（2026-10-21 实测） | **文件其实在**：`vendor/<工具>/bin/` 里 linux-x64（ELF）与 windows-x64（PE）并排躺，发现逻辑只问「打得开吗」——Windows 的 `fileReadable` 对 ELF 同样 true，于是选中 Linux 那份；而 `CreateProcess` 对**不带扩展名的名字自动补 `.exe`**，它去找 `linux-x64/cjh.exe` → 报「找不到文件」（与 cmd 不执行无后缀文件同源）。落法：候选表按 `@When[os == "Windows"]` / `@When[os != "Windows"]` 各列一份，**并把实际选中的 bin 打进失败日志**。先别怀疑 `launch()` 写法 / 子系统 / 线程——三个探针（console、GUI 子系统、`spawn` 里各跑一次）都成功就说明挑错了对象 |
| 应用改完 cjh 配置「保存了却不生效」（cjh 后端，2026-10-20 实测） | 三条都实测过：① `POST /api/settings` 是**字段白名单**——`baseUrl` / `model` / `apiKey` / `temperature` / `maxTokens` / `maxIterations` 能改**且改内存即生效**（GET 立刻回新值），`provider_protocol` 传进去**静默忽略**（GET 也不回显），它只能靠「写文件 + 重启」；② 「重启 cjh」的那条命令通常**只重启本应用 spawn 的实例**，端口上是别人拉起的 cjh（如 ai-chat 先起、另一个应用后连）时只回一句「需手动重启」——所以别把「配置生效」建在重启上；③ `chat` 帧支持**帧级 `model` / `baseUrl` / `apiKey` 覆盖**（单次生效、不落盘、不粘连），做「测试连通」按钮就用它：拿表单里的值真发一条最小对话，配一个故意错的 key 会被服务商拒（`provider_auth_error`）证明确实生效；探针别带 `session_id`，否则要么污染用户当前会话、要么多出一个会话（cjh 会用帧里的 id 回投，盘上的文件名却不是它回的 id，按 id 删不掉） |

### 多窗口 / 回调

| 症状 | 原因与修法 |
|---|---|
| 后装配的窗口收不到自己的事件 | 静态单槽被覆盖；宿主级回调一律**按句柄路由**（报文自带 label 的消息回调才可用单槽） |
| 第二扇窗的对话框在**别人窗口里弹出来**，自己那个从不出现，页面却显示 `confirmed=true` | 插件在 `setup()` 里固定了 `app.webviewHost()`（只代表默认窗），所有窗的 `dialog:*` 排进同一个队列。判据看 `dialog take` 的 `id` 是否**各宿主独立从 1 起**。落法：`attachHostResolver({ label => app.hostOf(label) })` + 命令实现多收 `ipc`（解析器在场而窗口未登记就抛错，别回落单槽）。`clipboard` / `notification` 仍是固定宿主，用前先问「是否只在默认窗可用」 |
| 新增宿主回调后 C 侧签名不对 | `cj_on_*_fn` 首参必须 `struct cj_host *`（回调要自带身份） |
| 改了 C 桥导出后链接炸一串 undefined reference | 桥是本地产物不入库；先 `bash native/build_linux.sh`（或 `native\build_win.bat`）重建再构建/测试 |

### C 桥 / 宿主层（改 `native/*.c` 时）

| 症状 | 原因与修法 |
|---|---|
| UI 线程回调里崩 `munmap_chunk(): invalid pointer` / double free | 投递归 UI 线程的载荷**必须堆分配**（谁 post 谁分配、UI 线程接管所有权）；把栈上的结构体指针递过去，回调再 `free()` 必崩 |
| GLib 回调被反复重入（同一动作执行两次、double free） | `g_idle_add` 的回调必须返回 `gboolean`；裸 `void` 函数的「返回值」是寄存器垃圾，非 0 即被当 `G_SOURCE_CONTINUE` 重入——用跳板包一层返回 `G_SOURCE_REMOVE` |
| 宿主调用「调过了但没生效」 | 一律「检查 API 返回值 + 事后查询复核」打进同一行日志（如 `SetMenu` 静默失败、`GetMenu` 恒 NULL） |

## 规则

- 修完一个坑，把「症状 → 原因 → 修法」沉淀回本 skill 或项目 `AGENTS.md` §4（见 `cj-tauri-contribute`）；
- 平台标识不要发明未验证的（没跑过 macOS 就别写 `@When[os == "macOS"]`）；
- 上面每一条都在真实项目里踩过并验证过修法；与你的症状不完全相同时，先读项目 `AGENTS.md` 再判断。
