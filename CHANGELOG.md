# 更新日志（CHANGELOG）

本文件记录 cj-tauri 的对外可感知变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)：0.x 阶段只递增中间位（能力）与末位（修复），
打到 1.0.0 后才固定对外 API。

- 分类用 `Added` / `Changed` / `Fixed` / `Removed` / `Security`，中文描述；
- 每条写**能观测到的行为**（命令、API、文件、日志），不写内部重构流水账；
- 发版时更新的文件清单与校验方式见 `AGENTS.md` 的「版本与发版」一节；
  一致性用 `scripts/check-version.sh` 自检。

## [Unreleased]

### Added

- 开源许可证：新增根目录 `LICENSE`（MIT）与 README 的许可证说明；开发规范里补「第三方代码需登记来源与许可证」。
- 仓库规范文件：新增 `README.OpenSource`（依赖与许可信息，OpenHarmony 7 字段格式）与 `CONTRIBUTING.md`（贡献指南）。
- 前端入门教程：新增 `docs/前端入门教程.md`（零基础，含一个完整的待办清单实战：桥 API、IPC 协议、事件、
  能力清单、调试入口），README 头部与使用文档 §6 增加入口；同时修正使用文档里 `emit` 的旧说明
  （它是占位实现，消息会被后端判为非法丢弃、也不会回投页面）。
- 插件体系设计草案：新增 `docs/RFC-插件体系.md`（RFC-001），并开 issue 征求评审。设计要点是
  「插件 = 仓颉包，贡献命令集 + 事件名 + 前端 JS 片段，一行 `app.plugin(...)` 接入」，
  命令命名与内置 `system:*` 同构（`<插件名>:<命令短名>`），权限仍由应用的能力清单决定。
- 热重载与前端模板设计草案：新增 `docs/RFC-热重载与前端模板.md`（RFC-002）。要点是给宿主加
  `loadUrl`（`TauriApp.runUrl`）：开发时指向前端 dev server 换取 HMR，发布仍产出单文件 HTML；
  桥接脚本本来就是逐文档注入，换成真实 URL 后 `window.__CJ_TAURI__` 照样在页面脚本前就位。
  含七个待评审问题。（本项只是设计草案，实现尚未开始。）
- 框架单元测试：新增 `src/tests/ipc_hub_test.cj`、`src/tests/capability_test.cj`、`src/tests/version_test.cj`
  （23 个用例，覆盖 IPC 解析与分发、能力默认最小权限、版本常量与内置命令），以及入口脚本 `scripts/test.sh`
  （Windows Git Bash 与 Linux 通用）。测试不创建窗口，可在无 GUI 环境跑；`cjpm build` 不编译测试文件。
- 测试目录整理：单元测试从 `src/` 根挪进 `src/tests/` 子包（`package cjTauri.tests`），`src/` 根只留框架源码。
  理由：`cjpm` 只从包内源目录收集测试，顶层 `tests/` 不会被扫描（实测 `TOTAL: 0`），而 `src/tests/`
  作为子包既能被 `cjpm test` 正常收集，也能访问父包符号——23 个用例依旧全绿。
- 窗口图标：新增 `WindowConfig.iconPath`（默认空串 = 系统默认图标，老应用行为不变）与两平台桥的
  同名导出 `cj_bridge_set_icon`。Windows 用 Win32 `LoadImageW` 从 `.ico` 文件加载大小两档图标，
  同时设置窗口类图标与 `WM_SETICON`（标题栏 / 任务栏 / Alt-Tab 一致）；Linux 走 GTK 的
  `gtk_window_set_icon_from_file`（png/ico 均可）。`examples/hello` 带上 `icon.ico` 作为样板，
  该文件由 `scripts/make-demo-icon.js` 生成、可重跑换图。Windows 端已实机验证；Linux 端未验证。
- 静态门禁与 CI：新增 `scripts/check-static.sh`（版本一致性、markdown 围栏成对、脚手架模板占位符
  都在渲染表内、`.bat`/`.ps1` 纯 ASCII、没有被跟踪的构建产物），不需要仓颉 SDK 即可跑；
  两条流水线 `.atomgit/workflows/ci.yml` 与 `.github/workflows/ci.yml` 在 push / PR 时执行它。
  需要 SDK 的 `cjpm build` 与单元测试尚未进 CI（缺 SDK 镜像）。

（尚未发版的下一个版本，按 Added / Changed / Fixed / Removed 就地累积，
发版时把本段整体改名为 `[x.y.z] - YYYY-MM-DD`，并在下方新开一个空的 Unreleased。）

## [0.3.0] - 2026-10-01

### Added

- `WindowConfig(title, width, height, devTools)` 与 `TauriApp.window(cfg)`：窗口标题与尺寸可配置
  （对标 tauri.conf.json 的 `app.windows`）。默认值与此前 C 桥里的硬编码一致（标题 `cj-tauri`、
  900×640、开发者工具开启），不配置窗口的应用行为不变。
- `TauriApp.loadCapabilities(dir)` 与 `capabilities/` 目录自动扫描：`run()` 时若没有显式挂载任何清单，
  自动加载工作目录下 `capabilities/` 里的所有 json 文件（对标 Tauri 的 capability 目录）；
  显式挂载优先于自动扫描。新增框架源码 `src/capability_loader.cj`。
- `TauriApp.openDevTools()`、命令处理器里的 `ipc.openDevTools()`、内置命令 `system:devtools`，
  以及 `WindowConfig.devTools = false` 的禁用开关。新增框架源码 `src/window.cj`。
- 两平台 C 桥新增同名导出 `cj_bridge_set_window` 与 `cj_bridge_open_devtools`。
- 文档：`docs/仓颉版Tauri-介绍与使用指南.md`（指南体）与 `docs/仓颉版Tauri-博客稿.md`（博客体）。
- 工程文件：本 `CHANGELOG.md`、`AGENTS.md`（开发规范契约）、`scripts/check-version.sh`（版本一致性自检）。

### Changed

- 脚手架模板与 `examples/hello` 改用 `window()` + 能力自动加载；模板的能力清单加入 `system:devtools`。
- `examples/hello` 的能力清单从内联 JSON 改为独立文件 `capabilities/default.json`。
- `run_win.bat` 固定以 `examples/hello` 为工作目录——`capabilities/`、`ui/` 是按相对路径读取的
  （对标 Tauri 以项目根目录为工作目录的约定）。
- 桥与框架的诊断日志统一走 stderr：仓颉 `println` 的 stdout 有缓冲，进程被强杀时日志会丢失，
  而桥的 stderr 每行都即时落盘，端到端验证以此为准。
- Linux 桥 `native/bridge_linux.c` 的窗口尺寸改为可配置（原先硬编码 900×640）。

### Fixed

- `system:devtools` 没有注册进 IPC hub（只在 `SystemCommands.handle` 里加了分支），
  前端 invoke 会拿到 `command not registered: system:devtools`。
- `system:version` 返回的 `platform` 字段固定为 `linux`，在 Windows 上返回了错误的平台。

### Removed

- 端到端验证用的临时工程目录 `.e2e/`（验证完成后清理，不入库）。

## [0.2.0] - 2026-10-01

### Added

- Windows 后端：WebView2 宿主 `src/host_webview2.cj` + C 桥 `native/bridge_win.c`，
  Win32 窗口与消息循环在宿主线程运行（对标 Tauri 的 wry/windows 后端）。
- 仓颉原生 CLI `cli/src/*.cj`：`create` / `dev` / `build` / `run` / `info` / `help` / `--version`，
  外加启动器 `cli/cj-tauri.sh`、`cli/cj-tauri.bat`。
- 脚手架模板 `cli/templates/app/`：占位符渲染，按宿主平台注入依赖与链接段。
- Windows 桥构建脚本 `native/build_win.bat`（含 WebView2 SDK 与 x64 loader 同步）。
- 文档 `docs/使用文档.md`。

### Changed

- README 重写为「CLI 优先」的工作流，并标注 Windows 端到端已验证。
- 仓库改为双托管：`origin` 挂两条 pushurl，一次 `git push` 同时推送 AtomGit 与 GitHub。

### Fixed

- Windows WebView2 集成阶段的崩溃：`hr=0x8007139F`（COM 引用计数语义错误，
  桥内 `ctrl_AddRef`/`nav_AddRef` 改为返回 1 并显式 `AddRef`）。

## [0.1.0] - 2026-08-21

### Added

- 首个可用版本（MVP）：
  - `WebViewHost` 抽象与 Linux webkit2gtk-4.1 宿主（`src/host_webkit.cj` + `native/bridge_linux.c`）——
    GTK/WebKit 调用全部在 C 桥创建的原生 pthread 内执行，规避仓颉 M:N 轻量线程栈被
    JSC 的栈边界校验 abort 的问题。
  - IPC 协议与消息桥：`invoke` / `resolve` / `event`，命令注册、分发与校验中心（`src/ipc_hub.cj`）。
  - 能力安全模型：命令与事件白名单，默认最小权限（`src/capability.cj`）。
  - 内置命令 `system:version` / `system:ping` / `system:echo`。
  - 示例应用 `examples/hello`（greet + tick 事件推送 + 越权拒绝演示）。
