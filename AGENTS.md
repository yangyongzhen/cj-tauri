# cj-tauri 项目开发规范（AGENTS.md）

> 本文件是本项目的**开发契约**：人类开发者与 AI 助手共同遵守，由 agent 自动加载注入。
> 改代码前先读 §1 门禁与 §2 架构契约。适用版本：**0.4.0**（2026-10-01），与 `CHANGELOG.md` 同步维护。
> 当前进度、未完成项与本机环境坑见 `docs/进度记录.md`；会话上下文导出（含换到 Linux 机器怎么接）见 `docs/会话交接.md`。

## 0. 项目定位

用华为仓颉语言实现的类 Tauri 2 混合开发框架：**仓颉后端（静态编译）+ 系统 WebView 前端（HTML/CSS/JS）**。

三件套对标关系：WebView 宿主（对应 tao/wry）、IPC 双向桥（invoke/resolve/event）、能力安全模型（capability 白名单）。
配套仓颉原生脚手架 CLI 与工程模板：`cli/templates/app/`（内联 HTML 的零 Node 样板，`create` 缺省用它）、
`cli/templates/app-vue/`（Vue 3）、`cli/templates/app-react/`（React 18）——后两者带 `ui/` 前端工程，
`cj-tauri dev` 会接管它们的 Vite dev server（`CJ_TAURI_DEV_URL`）。
平台状态：**Windows（WebView2）已实机跑通**、**Linux（WebKitGTK）已跑通**、鸿蒙 ArkWeb 为架构预留位。

## 1. 交付门禁

1. `cjpm build` 通过（框架根目录）；改动涉及 CLI 时再跑 `cd cli && cjpm build`，涉及示例时再跑 `cd examples/hello && cjpm build`。
2. **实机跑一轮**：Windows 用 `run_win.bat`（仓内示例）或 `cli\cj-tauri.bat run`；交付凭证是**桥的 stderr 日志**——
   窗口创建成功、`set window:` 行、`js -> native` 与实际调用次数吻合、`ExecuteScript -> hr=0x00000000`。
3. 行为变更必须给出**可观测证据**（日志行、`system:version` 返回值、窗口标题等），不允许「先交付后补证据」。
4. 跑不起来就如实说明（含「哪些平台未验证」），禁止把未验证说成通过。
5. 单元测试为**渐进目标**：新增纯函数/解析器优先补 `cjpm test`；框架整体端到端仍以实机为准。
   测试放在 `src/tests/` 子包（`package cjTauri.tests`，可访问父包符号），入口是 `scripts/test.sh`；当前 71 个用例。
   `src/` 根只留框架源码——`cjpm` 不扫描顶层 `tests/` 目录，挪出去会静默变成 0 个用例。

## 2. 架构契约（改哪里、怎么改）

- **平台差异只允许出现在两处**：仓颉侧 `@When` 条件编译、C 桥 `native/bridge_*.c`。
  IPC、能力校验、命令分发必须跨平台共用，禁止在上层散落运行期平台分支。
- **新增宿主能力**：先扩 `WebViewHost` 接口（`src/host.cj`），再改各平台实现，最后在 C 桥加**同名同签名**的导出函数
  （`cj_bridge_*`）。两平台导出名必须一致，避免上层出现平台分叉的调用点。
- **新增命令三处联动**（漏一处就用不了）：
  1. 实现 `CommandHandler`；
  2. `TauriApp.register("cmd", Handler())`；
  3. 在能力清单的 `commands` 里声明。
  只做 1+3 会得到 `command not registered`；只做 1+2 会得到 `command not allowed`。
- **新增插件三处联动**（同命令，漏一处就用不了）：
  1. 实现 `Plugin`（`src/plugin.cj`）——必写 `name()` + `commands()`，要推事件 / 前端 shim 再写 `events()` / `jsShim()`；
  2. 装配：`TauriApp().plugin(XxxPlugin())`（框架自动把命令注册成 `"<插件名>:<短名>"`）；
  3. 在能力清单的 `commands` 里声明 `"<插件名>:<短名>"`。
  插件**只声明「我提供什么」，不自动放行**（默认最小权限不破）；`jsShim()` 返回的前端片段由框架
  汇总插到第一个 `</head>` 之前（早于页面脚本），`runUrl()` 下无法并入需在 stderr 提示。
  实现文件放 `src/plugin_<名字>.cj`（如 `src/plugin_fs.cj`），可跑样板 `examples/plugin-fs/`，设计见 `docs/RFC-插件体系.md`。
- **命名权限集（v1.1）**：插件用 `Plugin.permissions()` 声明「短集名 → 成员」，框架装配时注册成 `<插件名>:<短集名>`；
  应用的 `capabilities/*.json` 用 `"permissions": ["fs:readonly"]` 引用，成员展开后与 `commands`/`events`
  里的明文名字**同权**（`CapabilityRegistry.coveredByPermissionSet`，单层展开、不递归）。
  与插件的铁律一致：**集声明 ≠ 放行**，清单不引用就不生效；引用了没有插件提供的集名只提示不报错
  （`warnUnknownPermissionSets`，在插件装配完之后才可能判定）。旧清单全写明文的行为不变，两者可混用。
- **内置命令**统一 `system:` 前缀，集中在 `src/api_system.cj`，并在 `TauriApp.run()` 里注册（`system:version/ping/echo/devtools`）。
- **命令执行线程模型（异步分发）**：`IpcHub.handleInvoke` 只做校验——「未授权 / 未注册」在调用线程上**同步拒绝**，
  通过校验的命令 `spawn` 到 worker 线程执行（`runCommand`），结果经 `jsSink` 回投。**不要**把 `handler.handle`
  挪回调用线程（那会退化成「慢命令钉住宿主 UI 线程」，`shell:exec` / 原生对话框最先遭殃）；worker 里也**只能**经
  `jsSink` 回投，不要直接调 GTK / WebKit（仓颉轻量线程的堆上协程栈会被 JSC 的栈边界校验 abort，见 §4）。
  同一命令被并发调用**不保证执行顺序**，前端按 promise id 匹配；异步契约的用例在 `src/tests/ipc_hub_test.cj`。
- **能力清单加载**：默认在 `run()` 时自动扫描工作目录下 `capabilities/` 的所有 json；
  显式 `loadCapabilities(dir)` 或 `addCapabilityJson(json)` 优先，且一旦调用即不自动扫描。
- **依赖方向单向**：`app.cj` → `host.cj` / `ipc_hub.cj` → `capability.cj`；禁止反向依赖与循环依赖
  （需要跨层协作时用回调注入，不要引入双向引用）。
- 新增文件按单一职责拆分（例：`src/window.cj` 只放窗口配置模型，`src/capability_loader.cj` 只放清单加载/扫描）。

## 3. 编码规范

- 语言与工具链：仓颉 SDK 1.2.0 + stdx（1.2.0.1）；`cjc-version` 写**最低要求** `1.0.5`；C 桥用 mingw-w64 gcc 构建。
  引入新的第三方仓颉包必须先在本文件登记。
- 命名：函数/变量 `camelCase`，类型/接口 `PascalCase`，常量/全局 `UPPER_SNAKE_CASE`（如 `CJ_TAURI_VERSION`）；
  标识符用英文，**注释用中文**（与既有代码一致，不要中英混写同一句）。
- 注释写「为什么」和坑，不逐行复述代码；公开 API 用 `/** */` 文档注释说明契约与调用时机。
- JSON 统一用 stdx 的 `stdx.encoding.json`（标准库无 `std.json`）。
- 前端只经 `window.__CJ_TAURI__` 的 `invoke` / `listen` / `emit`；业务代码里不要自己 `postMessage`。
- 文件重写要克制：改动既有长文件用定点替换，大段重写前先确认 git 里有可回退的副本。

## 4. 已踩坑清单（禁止重踩）

**仓颉语言**

- 块注释里出现 `/*` 会开启**嵌套注释**：正文/注释里写路径通配（如能力 json 的星号通配）必须改写，否则注释永不闭合、编译报莫名错误。
- **三引号字符串会处理反斜杠转义**：示例/模板把 HTML+JS 内联在 `"""` 里时，JS 的反斜杠转义会**先被仓颉吃掉**——
  写 `\n` 会变成真换行，把 JS 字符串或单行注释拆断 → 整段 `<script>` 语法错误 → 页面里一行都不执行，
  而 stderr 毫无提示（实测踩坑：`examples/plugin-fs` 的验证脚本静默全灭，靠对照 `examples/hello` 才定位）。
  内联 JS 里避免出现反斜杠（换行用 `String.fromCharCode(10)`，正则改用 `indexOf`），改完用 `node --check` 验一遍。
- `@When` 的平台取值**首字母大写**：`@When[os == "Windows"]` / `"Linux"`，不是 `windows`。
- 迭代 `String` 得到的是 `UInt32` 码点（不是 `Rune`），需要时用 `Rune(cp)` 还原。
- `cjc-version` 是最低要求而非精确版本：写 `1.0.5` 时用 1.2.0 的 cjc 也能编译。
- 条件编译函数按平台各写一份时，**不要发明未验证的平台标识**（例如未用过 macOS 就别加 `@When[os == "macOS"]`）。

**平台与工具链**

- Windows 脚本编码：`.bat` 由 cmd.exe 按 OEM 码页读取、`.ps1` 被 PowerShell 5.1 按 ANSI 读取——
  **保持纯 ASCII**，UTF-8 中文注释会吞掉后续行/导致解析崩溃（本项目已实际踩过）。
- Git Bash 下 `PATH` 里的 SDK 路径必须是 POSIX 形式（`/d/Program Files (x86)/Cangjie/...`）；
  盘符形式（`D:/...`）会被 MSYS 破坏，导致依赖仓颉运行时 DLL 的原生进程退出码 127 且无输出。
- 换行符：`.sh` 必须 LF（否则 shebang 失效），`.bat` CRLF；以 `.gitattributes` 为准。
- WebView2 版本规则：**SDK 不得高于本机 Runtime**（本机 Runtime 122.0.2365.106 → 用 SDK 1.0.2365.46）；
  `native/build_win.bat` 会同步同代的 `WebView2Loader.dll`（x64）到 `native/webview2/`。
- Linux 宿主：GTK/WebKit 的全部调用必须在 C 桥创建的原生 pthread 内执行——
  仓颉 M:N 轻量线程的堆上协程栈会被 JSC 的栈边界校验 abort。
- Linux 宿主：桥接脚本必须**在 document start 注入**（`WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START`）——
  用文档末尾注入会晚于发行态单文件里内联的 `<script type="module">`，前端读 `window.__CJ_TAURI__` 拿到
  `undefined`（Windows 的 `AddScriptToExecuteOnDocumentCreated` 同样是「页面脚本执行前」，两平台已对齐）。
  即便如此，应用前端也不要在模块作用域直接读桥：初始化时**等桥出现**（模板里的 `waitForBridge`）。
- Linux 上仓颉运行时的动态库**不查 PATH**：启动器只设 PATH 会让 CLI 以「找不到 libcangjie-runtime.so」
  直接退出（Git Bash 下表现为退出码 127 且无输出），必须同时把 `runtime/lib/<platform>` 设进 `LD_LIBRARY_PATH`。
- `cj-tauri dev` 的 dev server **不要用 `setsid` 另开会话**：那样它会脱离终端的进程组，
  终端 Ctrl-C 只杀掉 CLI、dev server 漏跑（实测残留 vite + esbuild）。正确做法是让它留在 CLI 的
  进程组里（Ctrl-C 能一并带走），收尾时按「先子后父」递归 kill 整棵树
  （`npm → sh -c vite → node(vite) → esbuild`）。
- Windows 宿主：COM 回调对象的 `AddRef` 必须返回 1 并显式 `AddRef`，否则出现 `hr=0x8007139F` 崩溃。
- 原生对话框（`dialog` 插件）：两平台的 JS→native 回调**本来就跑在宿主 UI 线程上**（Linux = GTK 线程，
  Windows = 跑 WebView2 消息循环的那个线程），所以「把弹窗投递到 UI 线程 + 阻塞等结果」会自锁——
  现象是日志停在 `[cj-bridge] dialog: kind=…`、对话框永不出现（第一次实机就是如此）。C 桥按调用线程分流：
  已在 UI 线程就直接弹，在别的线程才投递 + 等待；新增同类宿主能力（菜单、文件拖放等）照此办理。
- 执行子进程（`shell` 插件）：一律 **argv 直传**（`launch` / `executeWithOutput` 收参数数组），
  不要为省事拼 `bash -c "<一整串命令>"`——那等于把页面可控的字符串塞进 shell 解析，自己开后门。
  这类调用本身仍是**同步阻塞**的：它跑在命令 worker 线程上（命令分发已异步，见 §2），所以不再冻窗口，
  但没有流式输出、也没有超时 / 取消，别在命令里等长驻 / 交互式进程。
- 诊断输出一律走 stderr：仓颉 `println` 的 stdout 有缓冲，进程被强杀时日志会丢；
  桥的 stderr 每行即时落盘，端到端验证以它为准。
- 实机取证的三个坑（`/tmp/run-*-verify.sh` 一类脚本）：① 应用进程名是 `<示例>/target/release/bin/main`，
  按包名 `pkill -f plugin_shell` 匹配不上——陈旧实例会继续往同一个日志写（文件出现 NUL 空洞、上一轮旧输出混进
  本轮证据）；而 `pkill -f` 的模式又会匹配到脚本自己那行命令（自杀），写法用 `plugin-shel[l]/…` 避开。
  ② X11 是 SSH 转发时 `import -window root` 要抓远端整屏，抓屏本身会把 X 客户端冻住几秒——别在「命令进行中」
  抓屏，否则会污染「心跳是否中断」这类证据（实测先以为 UI 被卡住，其实是抓屏）。③ 等窗口别用固定 `sleep`：
  `cjpm run` 可能要先重编译，改为轮询 `xdotool search --name`。
- **工作目录 = 项目根**：`capabilities/`、`ui/` 都按相对路径读取，启动器/脚本必须切到项目根再启动应用。
- npm 发布的 2FA 现状（2026-10-02 实测）：npm 已停用**新** TOTP 动态码绑定（2025-09-29），passkey 账号
  根本拿不到 6 位码；且自 2026-09-09 起「用过恢复码」会给**所有账号**套 **72 小时只读持有**——期间发布、
  创建 token 等写操作全被拒（`temporarily suspended due to a recent security-sensitive action`），自动解除、
  无需申诉、无法加速。**不要拿恢复码反复试发布**（很可能重新计时）。旁路也不再可靠：本机 npm 10.9.4 的
  `npm token create` 没有 bypass 开关（npm 11 起才有），而 bypass-2FA token 本身已在退场（2026-07-31 公告）。

## 5. 文档与提交

- 行为变更必须同步：`CHANGELOG.md` 的 `[Unreleased]` 段 + 受影响的 `README.md` / `docs/使用文档.md`。
- 提交信息用 Conventional Commits（`feat:` / `fix:` / `docs:` / `refactor:` / `chore:`），主题写英文，正文可中英混排；
  一次提交只做一件事。
- **双仓双推**：`origin` 已挂两条 pushurl（AtomGit + GitHub），一次 `git push origin main` 同步两个托管；
  单推某仓用 `git push github main`。**不要只推一个仓**。tag 同理（`git push origin main --tags`）。
- 文档与代码注释里引用托管地址一律用 **AtomGit**（`atomgit.com`），不要写其他托管站点。
  唯一例外是功能必需的两处：`.github/workflows/` 下的 GitHub Actions workflow（npm trusted publishing 只支持
  GitHub / GitLab / CircleCI 三家）；`npm/package.json` 的 `repository.url`（必须精确等于 GitHub 仓库名，
  否则 npm 以 `E422` 拒绝发布）。
- 不提交：`target/`、`*.dll`、`*.log`、`cjpm.lock`、`.atomcode/`（本地会话产物）。
  提交前 `git status` 自查，用**显式路径** `git add`，避免 `git add -A` 扫进无关文件。
- `docs/仓颉版Tauri-介绍与使用指南.md` 与 `docs/仓颉版Tauri-博客稿.md` 是**发表用文稿**：
  需要更新时另存新文件或先确认，不要为同步 API 直接覆盖。
- 代码以 **MIT** 发布（根 `LICENSE`）；引入第三方代码或资源时，必须在本文件登记其来源与许可证。
- 仓库根保持 5 个标准文件：`README.md`（必须含运行截图）/ `LICENSE` / `README.OpenSource` / `CHANGELOG.md` /
  `CONTRIBUTING.md`；功能与依赖变更时同步受影响的文件，平台或依赖变化时 `README.OpenSource` 也要改。

## 6. 版本与发版

- 语义化版本。0.x 阶段：新增能力进中间位（0.3.0 → 0.4.0），修复进末位（0.4.0 → 0.4.1）。当前 **0.4.0**。
- 必须同步的**五个位置**（`bash scripts/check-version.sh` 校验，权威目标是 CHANGELOG 顶部已发版段）：
  1. `cjpm.toml` 的 `version`（框架包）
  2. `cli/cjpm.toml` 的 `version` 与 `cli/src/project.cj` 的 `cliVersion()`（`--version` / `info` 打印它）
  3. `src/version.cj` 的 `CJ_TAURI_VERSION`（`system:version` 命令返回它）
  4. `CHANGELOG.md` 顶部已发版段
  5. `npm/package.json` 的 `version`（npm 包版本，`npx cj-tauri --version` 在无 SDK 时读它）
- **不随项目版本走**：`examples/hello/cjpm.toml`、`cli/templates/app/cjpm.toml` —— 那是各应用自己的版本。
- 发版步骤：CHANGELOG 的 `[Unreleased]` 改名成 `[x.y.z] - 日期` → 同步上面 1–3 → `check-version.sh` 全 `ok`
  → 提交 → 打 tag `vX.Y.Z` → `git push origin main --tags` 双推。
- **npm 发布**：首版必须手工发（trusted publishing 的配置入口在 npm 的包设置页，包得先存在），绑定好之后
  推 `v*` tag 由 `.github/workflows/npm-publish.yml` 自动发布：
  1. 手工发首版——**这一步躲不开**：npm 只允许给「已存在的包」配置 trusted publisher（入口在该包的 settings 页），
     所以自动发布只能从第二个版本开始。首版走 **staged publishing**（`npm stage publish` 不要 2FA，
     且**能创建尚不存在的包**：registry 先放一个 `0.0.0-stage` 占位版本，正文等批准后才公开）：
     `npx --yes npm@latest stage publish ./dist-npm/cj-tauri-<版本>.tgz --registry=https://registry.npmjs.org/`
     → npmjs.com 的 **Staged Packages** 页 → Approve（浏览器里 passkey 直接过 2FA）。
     `npm stage` 需 CLI ≥ 11.15.0 与 Node ≥ 22.14.0，本机 npm 10.9.4 没有该子命令，故用 `npx --yes npm@latest`
     绕开、不动全局 npm。发布固定走官方 registry（本机 npm 配的是 npmmirror 镜像，别直接 `npm publish`）。
     坑：**别拿 2FA 恢复码当 `--otp` 直发**。npm 自 2025-09-29 停用**新** TOTP 绑定，passkey 账号根本没有
     6 位动态码；而自 2026-09-09 起「用过恢复码」会给账号套上 **72 小时只读持有**——发布、建 token 全被拒，
     报 `temporarily suspended due to a recent security-sensitive action`，自动解除、无法加速，
     反复用恢复码很可能重新计时（本项目 2026-10-02 已实际踩过）。同理也别依赖
     `bash scripts/npm-pack.sh --publish` 直发：bypass-2FA 的 granular token 曾能直发，但 npm 已在
     2026-07-31 公告其退场（直发 2027-01 取消，此后只保留读私有包与 staging）；
  2. npmjs.com → 包 → Settings → **Trusted publishing** → 添加 GitHub Actions，三个字段逐字一致（大小写敏感，
     且保存时不校验）：user/repo `yangyongzhen/cj-tauri`、workflow 文件名 `npm-publish.yml`，并**勾上
     Allow npm publish**（2026-09-03 之后新建的配置默认只允许 `npm stage publish`，不勾则 CI 发布会 `E_STAGE_REQUIRED`）；
  3. 同一页把 Publishing access 改成「Require two-factor authentication and disallow tokens」，此后只有 OIDC 能发；
  4. 推 tag 即自动发布（OIDC 换短期凭据，**不需要任何 token**，自动附 provenance）。注意 CI 里没有仓颉 SDK，
     **CI 打的包不含预编译 CLI**，用户首次运行在本机源码构建；要带 `prebuilt/` 就用本机 `npm-pack.sh` 发。

## 7. 交付检查清单

- [ ] `cjpm build` 通过（涉及 CLI / 示例时各自再跑一次）
- [ ] `bash scripts/test.sh` 全绿（改动涉及 IPC 分发 / 能力校验 / 版本常量时；纯文档改动可跳过）
- [ ] `bash scripts/check-static.sh` 全绿（不需要 SDK；CI 跑的就是它，纯文档改动也要过——围栏检查盯着文档）
- [ ] 实机跑通：桥 stderr 无 `hr=` 非 0，无 `command not allowed` / `command not registered` 误报
- [ ] 新命令/新 API 三处联动齐全（注册 + 能力清单 + 前端调用）
- [ ] `CHANGELOG.md` 的 `[Unreleased]` 已写；`README.md` / `docs/使用文档.md` 已同步

### CI 上的完整门禁（可选，默认跳过）

`.github/workflows/ci.yml` 除 `static` 作业外还有一个 `sdk` 作业，跑 `cjpm build` + `scripts/test.sh`。
仓颉 SDK 的官方下载页（`cangjie-lang.cn/download`）要登录华为账号、**没有匿名直链**，
本平台也没有预装 SDK 的官方镜像，所以 SDK 由仓库 secret 自托管
（GitHub → Settings → Secrets and variables → Actions）：

1. `CANGJIE_SDK_URL` —— SDK 压缩包直链；**配了才启用该作业**，未配置时作业只打印一条 notice 后跳过（不判失败，
   免得 CI 因「拿不到 SDK」这种环境原因长期变红）。
2. `CANGJIE_STDX_URL` —— stdx 压缩包直链（可选；本仓库各 `cjpm.toml` 的 `bin-dependencies` 依赖它）。

两个已知前提（不满足就会红，作业里已分别处理）：① 用 `sudo` 把 stdx 放到 `/root/.cangjie/stdx/` —— `cjpm.toml`
的 `bin-dependencies` 路径是写死的本地路径，CI runner 是普通用户、`$HOME` 不同；② runner 要装
`gcc pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev` 才链得了 C 桥（`cjpm.toml` 里 `-lcjtbridge -lwebkit2gtk-4.1`）。
配好 secret 后**实推一次确认变绿再算数**，不要只看 YAML 通过。
- [ ] 发版相关改动已跑 `bash scripts/check-version.sh` 且全 `ok`
- [ ] `git status` 无构建产物与无关文件；按双仓约定推送（tag 一并推）
