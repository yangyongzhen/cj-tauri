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
| Windows 上没有 / 不想装 Visual Studio | 不需要 MSVC：C 桥用 **llvm-mingw**（免安装，解压即用，安装见 `cj-tauri-env` skill）；GitHub 下载慢/连不上就走清华镜像 <https://mirrors.tuna.tsinghua.edu.cn/qt/development_releases/prebuilt/mingw_64/>（挑 `ucrt` + `x86_64` 那份，镜像版本可能滞后官方） |
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
| 运行期 `undefined symbol: stdx.net.tls:TlsException.ti`（或其它 `stdx.*:*.ti`），看着像链接错误 | **示例产物陈旧 + stdx 版本错配**：产物是旧 stdx 编的、运行时加载了新 stdx（实测 `TlsException` 在 1.0.5.1 有导出、1.2.0.1 已移除）。判据 `nm -D --defined-only <stdx>/dynamic/stdx/libstdx.net.tls.so \| grep -c TlsException` 两版各数一次。落法：换过 stdx 版本后示例必须 `cjpm clean` 重编——E2E 里「产物在就不重编」的省时闸门会把版本错配伪装成符号问题 |
| Windows 单文件包双击「没反应」、窗口不出现，而构建一切正常 | **windows stdx 与 cjc 主次版本不配套**（混配能编能链、真机启动即崩），叠上 GUI 子系统双击时 stderr 无效 ⇒ 零日志、无从下手。判据：构建首行 `[winbuild] cjc 1.2.0 + windows stdx 1.2.0.1` 两边主次版本必须相同（`scripts/winbuild.sh` 已加守卫）；先打 `CJ_WINBUILD_CONSOLE=1` 的 console 版看现场，别先怀疑 WebView2 / 杀软 |
| 只删了 `incremental-cache.json` 后，下次 build 抛 `DataModelException: This data is not DataModelSeq` 且**退出码仍是 0**、产物没刷新 | cjpm 的增量缓存**不止一个文件**，只删一个留下损坏的依赖缓存（栈在 `loadDepIncrementalCache`）。要清就 `cjpm clean`（安全：`libcjtbridge.so` 在 `native/` 根不在 `target/`）；判据看产物 mtime，别看退出码 |
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
| 内联页面一行 JS 都不执行、stderr 无提示 | 三引号字符串处理反斜杠转义：JS 的 `\n` 被吃成真换行拆断 `<script>`。换行用 `String.fromCharCode(10)`，正则改 `indexOf`，改完 `node --check` 验；页面大就独立成 `assets/ui/index.html`（旧形态工程是 `ui/index.html`） |
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
| 单文件 exe 双击启动后日志文件是 0 字节（窗口其实好好开着） | `cj_bridge_set_log_file` 把 stderr `dup2` 到日志文件，而 `--subsystem=windows` 的产物双击时 **stderr 句柄无效**：文件被建出来却写不进一行。带 `app.exe 2> err.txt` 起即正常（日志有内容、`err.txt` 反而 0 字节，说明 stderr 已被接管）。**取证一律带 stderr 重定向**；要双击也有日志得改 C 桥的落盘通道（当前未做） |
| 单文件包里「一键部署 / 拉起随包程序」报找不到安装包 | 打包器只内嵌页面 / vendor 前端资源 / 能力清单（按 `PACKED_*_B64` 存根声明），**`vendor/` 里的大二进制不会进 exe**。ai-chat 的 cjh zip（13 MB）就属于这类：单文件产物里如实报「找不到 cjh 安装包」，要装就设 `CJ_AICHAT_CJH_BUNDLE` 指过去 |
| 构建带一堆 unused/redundant 警告 | 接口成员不写 `public`（隐式公开）；未用参数就地 `let _ = x` 显式弃用；未用 import 删；`ReentrantMutex`→`Mutex`、`ArrayList.sort()`→`std.sort.sort`（交付标准：零警告，AGENTS §3） |

### 运行期 / scope 与出网白名单

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

### 鸿蒙侧（改 `@When[env == "ohos"]` 分支 / 上真机前先读）

| 症状 / 写法 | 原因与修法 |
|---|---|
| `@When` 的鸿蒙条件写什么 | `os` 取值**就是 `"Linux"`**、`arch` **不可用**（桌面 aarch64 Linux 同值，用它门禁会把有 C 桥的桌面平台一起摘掉）；唯一可靠判据是 **`env`**（`aarch64-linux-ohos` → `"ohos"`，桌面 → `"gnu"`）。一律写 `@When[env == "ohos"]` / `@When[env != "ohos"]` |
| 应用一启动就 SIGSEGV / 白屏秒退，hilog 里连 `AbilityStage.onCreate` 都没有 | 先查 `llvm-nm -D --undefined-only <模块.so> \| grep cj_bridge`——核心包**不带 `@When` 的 `foreign func`** 在无桥平台上留成未解析符号，模块加载期直接崩（编译期不报）。落法：FFI 声明与薄包装同口径 `@When[env != "ohos"]`，并为无桥平台写如实降级（返回 false/空串 + 一行 stderr），别假装成功 |
| 框架包一引用 ArkUI 就启动即崩 | `@Component` / `Web` / `javaScriptProxy` 属**应用侧**——框架包（独立编译单元）引用 `kit.ArkUI` 后合并进应用动态库，包初始化链跳坏地址。框架只导出 ArkUI-free 的桥接函数 |
| 页面拉原生数据拿到 `null`（参数进得去、`methodList` 枚举也对） | `javaScriptProxy` 的**返回值传不回页面**，是平台限制不是写法错。取数模型改成「原生推」：页面 `setInterval` 发心跳，原生在回调里 `runJavaScript` 推出去 |
| `eprintln` 的日志在设备上看不到 | `eprintln` 不进 hilog，框架 stderr 全不可见。框架自 2.3.0（**未发布**，见 CHANGELOG `[Unreleased]`；2.2.0 及以前框架诊断只有 stderr）起把自身诊断收到 `logd`（桌面 stderr / 鸿蒙 hilog，tag **`cj-tauri`**），应用自己的日志仍写 `Hilog.info`（tag `CjTauri`）——排「命令为什么没执行」看前者。hilog 缓冲会滚掉启动瞬间的行，取证必须**流式**（先起 `hdc shell hilog > f` 再启动应用）。自己接 hilog 三件套：入口模块 link-option 补 `-lhilog_ndk.z`（否则模块加载期就崩）、正文走 `%{public}s` + 一个实参（裸 `%s` 会打成 `<private>`）、超长行按 UTF-8 边界分条（单条有长度上限） |
| 「改了没变化」/ 对照实验失真 | hvigor 的 `CompileCangjie` 与框架侧 cjpm **各有一份增量缓存**，只清一边时旧 `.so` 被喂回来。重编前 `rm -rf entry/build` + 清框架 `target/`；判据看产物（`.so` 尺寸 / `llvm-nm` 符号数），不看 `build success` |
| 声明了权限却装不上包（`code:9568289 install failed`） | 权限位先查 `grantMode`/`availableLevel`（`hdc shell "atm dump -d -p <权限>"`）：`USER_GRANT` 要求 module.json5 带 `reason` + `usedScene`，`SYSTEM_BASIC` 还要签名 profile 带 ACL——**这类权限写进骨架等于让所有生成的工程装不上**，如实降级返回 None 才是诚实落法 |
| 调了系统原生 C API 却启动即 SIGSEGV | 查 `readelf -d <模块.so> \| grep <库>`：`foreign func` 直连后产物里留着一堆 `U OH_*` 而 `DT_NEEDED` 里没有那个库 = 模块加载期解析不到符号。链接开关要写在**入口模块**的 `cjpm.toml`（`output-type = "dynamic"`，最终链接在那儿）——鸿蒙工程的 entry `cjpm.toml` 是**生成物**，改模板没用，**必须改生成器**（两个 arch 段都要）。设备侧查库用 `hdc shell stat -L <路径>`，`ls /system/lib64` 是 Permission denied 别读成「没有这个库」 |
| PC 上窗口是竖屏窄窗、页面响应式救不了 | 先看 `deviceTypes`：只写 `phone`/`tablet` 时系统按手机应用给竖窗；桌面形态要写 `2in1`，且仓颉构建插件默认限制 phone/tablet，放行开关是 `entry/build-profile.json5` 的 `cangjieOptions.checkDeviceTypes = false` |
| `resize()` 写了 1440×900 只占半屏 | `resize()` / `moveWindowTo()` 收的是**像素不是 vp**（3120×2080 的机器上 1440px 只占 46%），日志照打「resized」不抛错，只有 `hidumper -s WindowManagerService` 读矩形才露馅；且 `densityPixels` 是 `Float32`，`Float64 * Float32` 报 invalid binary operator 还会连带把同一行日志报成参数不匹配 |
| 第二扇窗白屏、永不建 Web | 每个窗口都要**各自等宿主登记**：只等默认 label 时，第二窗的组件 `aboutToAppear` 读到的地址还是空串。判据：hilog 里 `host pageUrl label=<label>` 与 `page begin label=<label>` 每个 label 各一行 |
| 给 `@Component` 传参报 `missing arguments for parameter list '(Option<CustomView>, …)'` | 两种写法都撞它：普通 `var` 成员 + 外面传值；或 `@Prop` 但调用点挂了链式修饰（宏补不上 `__gen_parent`）。落法：`@Prop` 成员 + **调用点纯调用**，尺寸交给外层容器 |
| 页面触发的对话框调 `showAlertDialog` / `showDialog` 静默不弹（不抛异常、tid 还是 UI 主线程） | 命令式弹窗 API 在 `javaScriptProxy` 回调的**同步栈**上被静默丢弃，spawn 到工作线程也救不了。落法：组件加 `@State`，回调里只置状态，`build()` 里把 overlay 渲染成根 Stack 最后一个子节点；`@State` 不能与 `private` 同用 |
| Git Bash 下 `hdc shell … /data/local/tmp/x.jpeg` 报路径变成 `D:/Program Files/Git/data/...` | MSYS 把远端 POSIX 路径转写成本地路径；**远端路径**一律带 `MSYS_NO_PATHCONV=1`；`hdc file recv` 的本地落盘则相反——先 `cd` 到目标目录只传文件名，给绝对路径会被拼上 cwd |
| 应用启动即 `signal:6`，hilog 停在 `startApp begin`、连骨架的 initScripts 都不打，而业务只是想调 `@ohos.usbManager.serial` 这类 NAPI 模块 | **纯仓颉进程里没有 ArkTS VM**：`ohos.ark_interop` 链进来无害，但执行 `JSRuntime()` 必崩（放 UI 线程、放业务包一样崩，与「Cangjie 轻量线程」无关）。判据是 A/B：链接但不用 → 正常；真去建 runtime → 启动即没。落法：这类模块只能由**真正的 ArkTS 侧**发起（混合工程 / 应用自宿主 ArkTS 模块），框架侧只留接口 + 如实降级（别 import `ark_interop`） |
| 文件管理器「打开方式」能拉起应用，`FileIo.open(uri)` 却报 `13900012` | 纯仓颉 hap **读不了别人授权的文件**，三条路全堵：uri 的授权位没被用上（hilog `FILE-FS: Failed to open OpenFileByPath error -13`）、SDK 没有 `ohos.file.picker` 绑定、`FileIo.access(path)` 回 `true` 也不代表可读。别实现、别往骨架里加权限位，如实报「暂不支持」等官方能力。两个假线索：不是百分号编码问题、也不是文件不存在（应用视图 `Documents` ≠ 设备真路径 `Docs`） |
| 鸿蒙 PC 上串口打不开、`/dev/ttyUSB*` 不存在 | **先归因镜像缺驱动，别归因硬件**：`ls /dev`、`ls /sys/bus/usb/devices`、`ls /system/lib64` 一律 Permission denied——目录被拒不等于节点不存在，逐路径 `stat -L` 才可信；唯一能用完的枚举通道是 `hidumper -s UsbService -a 'usb_host -a'`。插拔前后读数变了（xHCI 根集线器 + hub + HID）却一个串口类设备（clazz `0x0a` CDC-ACM / `0xff` 厂商自定义）都没有，hilog 写着 `load libusbhost_acm.z.so failed, errno=2` ⇒ 镜像是真的没驱动库，任何应用都打不开。Windows 侧同理：CH340/CP210x/FTDI 驱动**不自带**，缺驱动的形状也是「端口(COM 和 LPT)里什么都没有」+「其他设备」一个感叹号 |

### C 桥 / 宿主层（改 `native/*.c` 时）

| 症状 | 原因与修法 |
|---|---|
| UI 线程回调里崩 `munmap_chunk(): invalid pointer` / double free | 投递归 UI 线程的载荷**必须堆分配**（谁 post 谁分配、UI 线程接管所有权）；把栈上的结构体指针递过去，回调再 `free()` 必崩 |
| GLib 回调被反复重入（同一动作执行两次、double free） | `g_idle_add` 的回调必须返回 `gboolean`；裸 `void` 函数的「返回值」是寄存器垃圾，非 0 即被当 `G_SOURCE_CONTINUE` 重入——用跳板包一层返回 `G_SOURCE_REMOVE` |
| 宿主调用「调过了但没生效」 | 一律「检查 API 返回值 + 事后查询复核」打进同一行日志（如 `SetMenu` 静默失败、`GetMenu` 恒 NULL） |
| 读原生 cookie 之后进程直接没（WER `0xc0000005`，故障模块是 `EmbeddedBrowserWebView.dll`**不是**自家桥） | WebView2 完成回调 `Invoke(HRESULT, ICoreWebView2CookieList *result)` 的参数是**借用**，对它 `Release` 会让运行时随后用到已销毁对象；handler 也别写成「`Invoke` 里 `free(self)`」——运行时自己 AddRef/Release 它。判据：加 `addref/release -> N` 与 `complete count=N` 日志，看崩点是否与「回调返回」同一秒、各 handler 计数是否各自归零。同族风险面：所有把对象交给 WebView2 保管的调用（`GetCookies` / `ExecuteScript` / 事件登记） |
| `snprintf` 拼出来的 JSON 看着读成功了，前端整条命令却失败 | 缓冲按**最坏取值**算：`char num[32]` 装 `{"ok":true,"count":%u,"cookies":[` 至少要 34 字节（固定 31 + 10 位计数 + NUL），gcc 的 `-Wformat-truncation` 就在说这件事；不理会就得到非法 JSON（空 store 那轮被截掉 `":[`），而桥侧看起来「读成功了」 |
| 用 `llvm-nm` 查未解析符号，得到「0 个 = 干净」的结论 | 本机 SDK 可能**根本没有** `llvm-nm.exe`（`third_party/llvm/bin/` 只有 `llvm-objdump`）：命令不存在时输出为空、`grep -c` 得 0——恰好等于「干净」的读数，假绿凭空成立。先 `llvm-objdump -h <文件>` 确认工具真读得到文件，再用 `-p`（`DT_NEEDED`）/ `-T`（动态符号）下结论 |

### 鸿蒙真机签名（`cj-tauri sign`）

| 症状 / 问题 | 原因与处置 |
|---|---|
| `hdc install` 报 `9568322 signature verification failed due to not trusted app source` | **HarmonyOS 真机只信任华为签发、且 profile 的 device-ids 含本机 UDID 的证书**。SDK 自带的 OpenHarmony 默认材料签出来「有 signed 文件」但装不上；`hdc install` 失败时**退出码仍是 0**，只能按输出文本判。正解：`cj-tauri sign`（离线体检）→ `--login` + `--auto`（为本包名现签） |
| hvigor 报 `00303074 The bundleName … does not match … SigningConfigs` | **profile（.p7b）是按 bundleName 签发的**：别的包名的材料哪怕含本机 UDID 也不能用。「机器上有含本机的材料」只过两道门里的一道，另一道是包名。本机材料普查：`strings <某.p7b> \| grep bundle-name`（p7b 是 DER 包着明文 JSON，可直接按字节找） |
| 装不上但不知道缺哪道门 | 跑 `cj-tauri sign`（纯离线、免账号）：取 UDID（`hdc shell bm get --udid`）→ 解析工程 build-profile.json5 的 signingConfigs → 扫 `~/.ohos/config/*.p7b`（type=debug + device-ids 含本机 UDID + bundle-name 等于工程包名）→ 给「能不能装 + 缺什么 + 下一步」 |
| 本机有含 UDID 的材料，但明文口令不可知，离线写回做不了 | `storePassword`/`keyPassword` 是 DevEco AesGcmKit 密文，明文只存在于生成那一次。两条路：① 找用**同一个 .p12** 的 donor 工程搬它的密文（同一套材料 → 密文通用）；② `cj-tauri sign --login` + `--auto` 生成一套自己掌口令的新材料（本地 p12+CSR，私钥永不上云） |
| 想自己生成口令密文（不依赖 DevEco） | 算法：`material/{ac, ce, fd/0,1,2}`（`~/.ohos/config/material/`，config 级共享）→ passphrase = lossyUtf8(XOR(fd0,fd1,fd2,固定16B)) → rootKey = PBKDF2-HMAC-SHA256(passphrase, salt, 10000, 16) → workKey = AES-GCM 解 material/ce → 密文 = hex([len(4BE) \| IV(12) \| ct \| tag(16)])。仓颉 std/stdx 没有 AES，需自带 AES-128-GCM 实现（`cli/src/sign_gcm.cj`，NIST 向量已过） |
| AGC 登录/云接口怎么调 | 端点抄自 flutter_flutter e2793de 的 ohos/signing/：登录页 `cn.devecostudio.huawei.com/console/DevEcoIDE/apply?port=&appid=1009&code=`；回调只绑 127.0.0.1 + Host 白名单 + siteId=="1"（**回调 code 不做硬比对**——华为回调自带它自己的 code，硬比对误杀正常登录）；tempToken→JWT 响应体本身就是 JWT；业务 API 基址 `connect-api.cloud.huawei.com`，**成功判据是 body 的 ret.code==0 不是 HTTP 200**；删证书是 DELETE 带请求体；profile 的 deviceList 传**云端设备 id**（≤32 位），不是 64 位 UDID |
| 证书/profile 下载 403 | AGC 下载链是 AWS SigV4 签名 URL，通用 HTTP 客户端会重编码 `%2F` → 签名失效。**用系统 curl 原样 GET**（把 URL 当字节）；下载前先过 SSRF 护栏（拒内网）并校验 sha256 |
| 令牌没落盘、`--auto` 说没有令牌 | 错误被吞了：saveAgcToken 的返回值必须落到 stderr（已修）。令牌落 `~/.cj-tauri/sign/token.enc`（KEK 加密），**约 4 小时过期**，过期重跑 `--login` |

### 音频播放（`<audio>` / 媒体栈）

| 症状 / 问题 | 原因与处置 |
|---|---|
| 播放页「某一块莫名其妙很高」，把下面的内容顶到屏幕底部（如歌词贴底、间距调不动） | **先量再调**：给页面挂一段自检把各块 `getBoundingClientRect()` 报到 stderr，别靠肉眼猜。实测踩坑：`ion-range` 的**宿主被内部结构撑到 278px**，CSS 里写 `height:26px` 压不住——症状是标题与进度条之间凭空多出 200 多像素空白。修法：外面套一层固定高度容器 `{ height:22px; overflow:hidden; display:flex; align-items:center }` 夹住它（改完复测 `h=22`） |
|---|---|
| 播放「播几秒卡一下」，两端都这样，同一音源在别的示例里正常 | **先怀疑页面自己每 200ms 把播放器 seek 一次**：进度条写成 `<ion-range :value="progress" @ionInput="seek(...)">` 时，ion-range 被**程序化更新**（`timeupdate` → `:value` 回写）**也会 emit `ionInput`** → `currentTime` 反复重定位 → 媒体管线被反复打断、缓冲填满也断续。判据：给 `audio` 挂 `seeking/waiting/playing/seeked` 事件经 `report` 命令打到 stderr，看 `seeking` 是否按 timeupdate 节奏（~200ms）循环；ohos 侧对应系统日志每 1~2 秒一条 `Write audio underrun error event`（`hilog -x \| grep 'audio underrun'`）。修法：seek 只挂 `@ionChange`（用户松手提交），程序化更新不触发 |
| 想判断是「取流慢」还是「客户端折腾」 | 别用进程 IO 计数器（`Win32_Process.ReadTransferCount`）——GPU/IPC 读量远高于音频码率，没有区分度。用页面侧音频事件 + 服务端分段 curl（整文件 GET、`-r 0-`、逐块 Range）交叉验证：整文件快而 `seeking` 狂循环 ⟹ 客户端问题 |
| ohos 上媒体播放卡顿但页面日志看不见 | `eprintln` 在设备上不进 hilog。诊断行改用框架的 `logd`（`public func logd`，桌面写 stderr、鸿蒙写 hilog，tag `cj-tauri`），同一行代码两端都能取证 |

### 打包脚本（Windows 本机跑 `scripts/winbuild.sh`）

| 症状 / 问题 | 原因与处置 |
|---|---|
| `llvm-rc: Error in N statement (ID 1001): No such file or directory` | rc 里写的是 MSYS POSIX 路径（`/e/...`），windres/llvm-rc 是原生 exe 不认。生成 rc 时经 `cygpath -m` 转盘符形式（Linux 交叉侧没有 cygpath，原样返回） |
| `the path '/e/...' of module 'cjTauri' does not exist`（work 副本 cjpm.toml） | 同理：`[dependencies] cjTauri = { path = ... }`、`bin-dependencies.path-option`、`link-option` 里的 `libcjtbridge.a` / 资源 `.o` 都要转盘符形式 |
| `没找到产物: .../target/x86_64-w64-mingw32/release/bin/main.exe` | Windows 本机跑时 cjpm 会提示 `--target` 被忽略，产物落在不带三元组的 `target/release/bin/`；两条路都探 |
| `strip` 失败、exe 停在 40MB+ | llvm-mingw 的 `strip.exe` 是包装器，真身可能缺失；回退 `$CANGJIE_HOME/third_party/llvm/bin/llvm-objcopy.exe --strip-all`（实测 43MB → 19.5MB） |

### 鸿蒙真机取证的锁屏陷阱

| 症状 / 问题 | 原因与处置 |
|---|---|
| `aa start` 报 `Error Code:10106102 The device screen is locked during the application launch, unlock screen failed` | 屏幕锁着时系统拒绝拉起应用，而**开发者模式下脚本解不了锁**（`power-shell wakeup` 只亮屏、`uinput` 上滑不一定生效）——只能请人手动解锁。别在这一条上反复重试刷屏 |
| `snapshot_display` 抓回来是一张**全黑图**（有时只剩状态栏），看着像「应用黑屏/渲染坏了」 | 锁屏期间抓屏本来就是黑的，与应用无关。判据：先查 `pidof <bundle>` 与 `hilog -x \| grep cj-tauri` 有没有页面加载日志，**别只凭截图下结论**（本项目实测因此误判过一轮） |
| 日志里连框架的 `cj-tauri` 一条都没有 | `hilog -x \| grep` 是查**当前缓冲**：应用在很久前跑过、或已被后续 chromium 日志刷掉就查不到。要在启动瞬间抓：`hilog -r; aa force-stop …; aa start …; sleep 15; hilog -x -T cj-tauri` 放在**同一条 shell 命令**里 |

### 鸿蒙上 https 全灭（`TlsException: Can not load openssl library`）

| 症状 / 问题 | 原因与处置 |
|---|---|
| 鸿蒙真机上 `http://` 接口全部正常，唯独 https 资源（封面、图片、外部 API）全失败；日志 `TlsException: Can not load openssl library or function CRYPTO_get_ex_new_index.` | **仓颉运行时的 `stdx.net.tls` 只是 OpenSSL 的按名 dlopen 绑定**（`libcangjie-dynamicLoader-opensslFFI` → `libcrypto_openssl.z.so` / `libssl_openssl.z.so`），而设备上没有这两个库。判据：`stat -L /system/lib64/libcrypto_openssl.z.so` 与 `/system/lib64/ndk/...` 都回 `No such file or directory`（**`ls /system/lib64` 是 Permission denied，别拿它当结论**）。修法：那条出网链路在鸿蒙分支改走**系统网络栈 `ohos.net.http`**（`createHttp()` + `HttpRequestOptions(method: RequestMethod.Get, expectDataType: HttpDataType.ArrayBuffer, ...)` + `client.request(url, options) { err, resp => ... }` 回调 + `sleep` 轮询收口），平台差异只落在命令实现那一层，命令名/入参/返回契约不变。参考实现：`examples/ohos/ohos-movie/entry/src/main/cangjie/ohos_movie_image.cj`、本仓 `src/plugins/http/http_ohos.cj` |
| 想确认「到底是网络不通、证书链不对，还是 TLS 栈本身没起来」 | 设备自带 `openssl`，锁屏也能用（`hdc shell` 不需要解锁，只有拉起应用需要）：`echo \| openssl s_client -connect <host>:443 -servername <host> -verify 5` 看握手与校验码；再发一次真实请求确认资源可取：`printf "GET <path> HTTP/1.1\r\nHost: <host>\r\nConnection: close\r\n\r\n" \| openssl s_client -quiet -connect <host>:443`。**两者都通却在应用里失败 ⟹ TLS 栈/客户端实现问题，不是网络** |

## 规则

- 修完一个坑，把「症状 → 原因 → 修法」沉淀回本 skill 或项目 `AGENTS.md` §4（见 `cj-tauri-contribute`）；
- 平台标识不要发明未验证的（没跑过 macOS 就别写 `@When[os == "macOS"]`）；
- 上面每一条都在真实项目里踩过并验证过修法；与你的症状不完全相同时，先读项目 `AGENTS.md` 再判断。
