# cj-tauri 项目开发规范（AGENTS.md）

> 本文件是本项目的**开发契约**：人类开发者与 AI 助手共同遵守，由 agent 自动加载注入。
> 改代码前先读 §1 门禁与 §2 架构契约。适用版本：**0.3.0**（2026-10-01），与 `CHANGELOG.md` 同步维护。

## 0. 项目定位

用华为仓颉语言实现的类 Tauri 2 混合开发框架：**仓颉后端（静态编译）+ 系统 WebView 前端（HTML/CSS/JS）**。

三件套对标关系：WebView 宿主（对应 tao/wry）、IPC 双向桥（invoke/resolve/event）、能力安全模型（capability 白名单）。
配套仓颉原生脚手架 CLI 与工程模板 `cli/templates/app/`。
平台状态：**Windows（WebView2）已实机跑通**、**Linux（WebKitGTK）已跑通**、鸿蒙 ArkWeb 为架构预留位。

## 1. 交付门禁

1. `cjpm build` 通过（框架根目录）；改动涉及 CLI 时再跑 `cd cli && cjpm build`，涉及示例时再跑 `cd examples/hello && cjpm build`。
2. **实机跑一轮**：Windows 用 `run_win.bat`（仓内示例）或 `cli\cj-tauri.bat run`；交付凭证是**桥的 stderr 日志**——
   窗口创建成功、`set window:` 行、`js -> native` 与实际调用次数吻合、`ExecuteScript -> hr=0x00000000`。
3. 行为变更必须给出**可观测证据**（日志行、`system:version` 返回值、窗口标题等），不允许「先交付后补证据」。
4. 跑不起来就如实说明（含「哪些平台未验证」），禁止把未验证说成通过。
5. 单元测试为**渐进目标**：新增纯函数/解析器优先补 `cjpm test`；框架整体端到端仍以实机为准。
   目前仓库尚无测试目录，引入时先补 `scripts/test.sh` 并在本文件登记（不要只在本地口头约定）。

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
- **内置命令**统一 `system:` 前缀，集中在 `src/api_system.cj`，并在 `TauriApp.run()` 里注册（`system:version/ping/echo/devtools`）。
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
- Windows 宿主：COM 回调对象的 `AddRef` 必须返回 1 并显式 `AddRef`，否则出现 `hr=0x8007139F` 崩溃。
- 诊断输出一律走 stderr：仓颉 `println` 的 stdout 有缓冲，进程被强杀时日志会丢；
  桥的 stderr 每行即时落盘，端到端验证以它为准。
- **工作目录 = 项目根**：`capabilities/`、`ui/` 都按相对路径读取，启动器/脚本必须切到项目根再启动应用。

## 5. 文档与提交

- 行为变更必须同步：`CHANGELOG.md` 的 `[Unreleased]` 段 + 受影响的 `README.md` / `docs/使用文档.md`。
- 提交信息用 Conventional Commits（`feat:` / `fix:` / `docs:` / `refactor:` / `chore:`），主题写英文，正文可中英混排；
  一次提交只做一件事。
- **双仓双推**：`origin` 已挂两条 pushurl（AtomGit + GitHub），一次 `git push origin main` 同步两个托管；
  单推某仓用 `git push github main`。**不要只推一个仓**。tag 同理（`git push origin main --tags`）。
- 文档与代码注释里引用托管地址一律用 **AtomGit**（`atomgit.com`），不要写其他托管站点。
- 不提交：`target/`、`*.dll`、`*.log`、`cjpm.lock`、`.atomcode/`（本地会话产物）。
  提交前 `git status` 自查，用**显式路径** `git add`，避免 `git add -A` 扫进无关文件。
- `docs/仓颉版Tauri-介绍与使用指南.md` 与 `docs/仓颉版Tauri-博客稿.md` 是**发表用文稿**：
  需要更新时另存新文件或先确认，不要为同步 API 直接覆盖。
- 代码以 **MIT** 发布（根 `LICENSE`）；引入第三方代码或资源时，必须在本文件登记其来源与许可证。

## 6. 版本与发版

- 语义化版本。0.x 阶段：新增能力进中间位（0.2.0 → 0.3.0），修复进末位（0.3.0 → 0.3.1）。当前 **0.3.0**。
- 必须同步的四个位置（`bash scripts/check-version.sh` 校验，权威目标是 CHANGELOG 顶部已发版段）：
  1. `cjpm.toml` 的 `version`（框架包）
  2. `cli/cjpm.toml` 的 `version` 与 `cli/src/project.cj` 的 `cliVersion()`（`--version` / `info` 打印它）
  3. `src/version.cj` 的 `CJ_TAURI_VERSION`（`system:version` 命令返回它）
  4. `CHANGELOG.md` 顶部已发版段
- **不随项目版本走**：`examples/hello/cjpm.toml`、`cli/templates/app/cjpm.toml` —— 那是各应用自己的版本。
- 发版步骤：CHANGELOG 的 `[Unreleased]` 改名成 `[x.y.z] - 日期` → 同步上面 1–3 → `check-version.sh` 全 `ok`
  → 提交 → 打 tag `vX.Y.Z` → `git push origin main --tags` 双推。

## 7. 交付检查清单

- [ ] `cjpm build` 通过（涉及 CLI / 示例时各自再跑一次）
- [ ] 实机跑通：桥 stderr 无 `hr=` 非 0，无 `command not allowed` / `command not registered` 误报
- [ ] 新命令/新 API 三处联动齐全（注册 + 能力清单 + 前端调用）
- [ ] `CHANGELOG.md` 的 `[Unreleased]` 已写；`README.md` / `docs/使用文档.md` 已同步
- [ ] 发版相关改动已跑 `bash scripts/check-version.sh` 且全 `ok`
- [ ] `git status` 无构建产物与无关文件；按双仓约定推送（tag 一并推）
