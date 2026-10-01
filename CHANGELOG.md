# 更新日志（CHANGELOG）

本文件记录 cj-tauri 的对外可感知变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)：0.x 阶段只递增中间位（能力）与末位（修复），
打到 1.0.0 后才固定对外 API。

- 分类用 `Added` / `Changed` / `Fixed` / `Removed` / `Security`，中文描述；
- 每条写**能观测到的行为**（命令、API、文件、日志），不写内部重构流水账；
- 发版时更新的文件清单与校验方式见 `AGENTS.md` 的「版本与发版」一节；
  一致性用 `scripts/check-version.sh` 自检。

## [Unreleased]

（尚未发版的下一个版本，按 Added / Changed / Fixed / Removed 就地累积，
发版时把本段整体改名为 `[x.y.z] - YYYY-MM-DD`，并在下方新开一个空的 Unreleased。）

### Added

- **npm 包**：`npx cj-tauri` / `npm i -g cj-tauri` 成为跨平台统一入口（`npm/bin/cj-tauri.js`）——
  自动定位仓颉 SDK（`CANGJIE_HOME` 或平台默认路径）、拼 `PATH` / `LD_LIBRARY_PATH`、注入 `CJ_TAURI_ROOT`；
  CLI 本体优先用包内预编译二进制（`prebuilt/<平台-架构>/`），缺失则把 `cli/` 拷到缓存目录用本机 `cjpm build`
  构建一次并复用（`~/.cache/cj-tauri/<版本>/`，Windows 为 `%LOCALAPPDATA%\cj-tauri`），不往安装目录写产物；
  找不到 SDK 时打印安装说明与 `CANGJIE_HOME` 示例并以退出码 1 结束，`--version` 不依赖 SDK。
  打包脚本 `scripts/npm-pack.sh`（默认只打包，`--publish` 发布；发布固定走官方 registry
  `https://registry.npmjs.org/`（`NPM_PUBLISH_REGISTRY` 可覆盖）并先做登录预检——本机 npm 常配着镜像
  （`registry.npmmirror.com`），镜像不接收 publish，直接 `npm publish` 会报错或发错地方；未登录时打印确切的
  `npm login --registry=…` 命令并以退出码 1 结束）；包内容 = 框架源码 + CLI 源码与三个模板 +
  本机 CLI 产物（1.2 MB tarball / 55 文件）。Linux 实测：预编译分支、源码构建回落与缓存命中、`create` 生成的工程
  再跑 `info`、缺 SDK 提示路径全部走通。
- **npm 自动发布（GitHub Actions + trusted publishing）**：`.github/workflows/npm-publish.yml` 在推 `v*` tag 时
  依次跑「版本五处一致性 → tag 必须等于包版本 → 静态门禁 → `scripts/npm-pack.sh` → `npm publish`」，
  用 OIDC 换取短期发布凭据，**不需要任何长期 token**，并自动附带 provenance（公开仓库 + 公开包）。
  CI 里没有仓颉 SDK，故 CI 打的包不含预编译 CLI（用户首次运行在本机源码构建），与既定的
  「优先预编译、缺失回落源码构建」一致；要带 `prebuilt/` 仍用本机打包。
- 示例工程入库：`examples/vue_todo/` —— `examples/todo_check` 的 **Vue 3 版**，命令与事件完全同名
  （`todo:add` / `todo:remove` / `todo:list` + `todo:changed` 广播），后端 `src/main.cj` 两份可直接对照；
  前端是 Vite 工程（Vue 3 `script setup`），`cj-tauri dev` 接管 dev server 换 HMR，
  `cj-tauri build` 经 `vite-plugin-singlefile` 产出单文件 `ui/dist/index.html`（70.2 KB）。
  前端取桥用**等桥出现再初始化**（`waitForBridge`，与两个模板一致；宿主注入时机的修复见 `Fixed`）；Linux 实机（WebKitGTK）已验证：
  界面显示「已注入 __CJ_TAURI__」与 `system:version` 的后端 JSON（`0.4.0` / `cangjie 1.0.5` / `linux`），
  两条待办由后端保存并经 `todo:changed` 回投渲染（共 2 条 / 收到事件 2 次 / `todo:add 返回 2`）。
  另带 `run.bat`（Windows 一键跑：先检查已构建的 `main.exe` 与 `ui/dist/index.html`，再切到工程根启动，
  与 `examples/todo_check` 同款）。

### Changed

- README 增「示例一览」章节：三个示例（`examples/hello` / `todo_check` / `vue_todo`）与三个工程模板
  （`cli/templates/app` / `app-vue` / `app-react`）的说明表，各配**发行态实机截图**
  （`docs/images/example-hello.png`、`docs/images/example-todo-check.png`、`docs/images/example-vue-todo.png`、
  `docs/images/template-app-vue.png`、`docs/images/template-app-react.png`，Linux / WebKitGTK，2026-10-02）；
  并修正首页两处陈旧信息：版本号 `0.3.0` → `0.4.0`、`cli/templates/` 目录说明补全三个模板。
- 版本一致性校验由四处扩到五处：`scripts/check-version.sh` 增加 `npm/package.json` 的 `version`
  （npm 包版本 = 框架版本，`npx cj-tauri --version` 在无 SDK 时读它），`AGENTS.md` 的「版本与发版」同步改写。
- `npm/package.json` 的 `repository.url` 改指 GitHub 仓库：trusted publishing 要求它与发布来源仓库**精确一致**
  （大小写敏感），否则 npm 以 `E422` 拒绝发布。`homepage` / `bugs` 仍指 AtomGit。

### Fixed

- `cj-tauri dev` 退出后残留 vite / esbuild：收尾改为按「先子后父」递归收掉整棵 dev server 进程树
  （`npm → sh -c vite → node(vite) → esbuild`），此前只 terminate 直接子进程（`bash`）。Linux 实测：
  应用退出后日志出现 `dev server 已收掉（pid=… 及后代）`，`pgrep` 查不到 vite / esbuild 残留。
- 上一版把 dev server 放进独立会话（`setsid`）以便按进程组收尾，实测这会让它脱离终端的进程组：
  终端 Ctrl-C 只杀掉 CLI，dev server 照样漏跑。已改回让 dev server 留在 CLI 的进程组里
  （Ctrl-C 能一并带走），整棵树的收尾交给上面的递归 kill。
- Linux 启动器 `cli/cj-tauri.sh`：运行时目录改为按宿主平台挑（此前 `find | head -1`，SDK 里同时存在
  `linux*` 与 `windows*` 目录时可能挑错）；并补设 `LD_LIBRARY_PATH`——Linux 上动态库不查 PATH，
  只设 PATH 会以「找不到 libcangjie-runtime.so」直接起不来。
- 示例在 Linux 上可直接构建：`examples/hello/cjpm.toml` 的 Linux 链接段去掉失效绝对路径
  （改用相对本仓的 `../../native`），`examples/todo_check/cjpm.toml` 补上 Linux 链接段与 stdx 路径；
  `examples/todo_check/run.bat` 的中文注释改为纯 ASCII（`.bat` 由 cmd.exe 按 OEM 码页读取，中文会吞行）。
- **Linux 宿主桥接脚本的注入时机过早无效**：`native/bridge_linux.c` 原为文档**末尾**注入
  （`WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END`），而发行态单文件把 `<script type="module">` 内联进 HTML、
  解析完即执行，会抢在注入之前；前端在模块作用域 / `onMounted` 里读 `window.__CJ_TAURI__` 会拿到
  `undefined`（开发态从 URL 加载、模块要现下载，反而掩盖了这个竞态）。现改为
  `WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START`，与 Windows 的 `AddScriptToExecuteOnDocumentCreated`
  （页面脚本执行前）一致。用 `--template vue` 生成的工程在发行态前后对比验证：改前界面显示
  「未注入 / 未找到 window.__CJ_TAURI__」，改后**同一份前端**（未做任何等待）显示「已注入 __CJ_TAURI__」
  且 `greet` 返回 `invoke OK: Hello, world! 来自仓颉后端`。
- `cli/templates/app-vue` / `app-react` 的示例前端改为**等桥出现再初始化**（`waitForBridge`：每 20ms 探测、
  3s 上限），不再在模块作用域直接读 `window.__CJ_TAURI__` —— 注入时机是宿主实现细节，应用侧等待才与时序无关。
  Linux 发行态实测：两个模板生成的新工程均显示「已注入 __CJ_TAURI__」、`greet` 返回
  `invoke OK: Hello, world! 来自仓颉后端`、`timer` 触发的事件回投显示「事件 tick #3 来自仓颉后端」。
- `cli/templates/app-react` 的示例页面此前**完全没有样式**（`App.jsx` 用了 `card` / `row` / `ghost` 等 class，
  但模板里没有任何 CSS，发行态渲染出来是裸的 HTML；Vue 模板的样式写在 `App.vue` 的 `<style scoped>` 里，
  所以没这个问题）。现补一份 `ui/src/App.css`（与 Vue 模板逐条等价的样式），并在 `App.jsx` 里 `import`。
  Linux 发行态实测：页面出现卡片 / 圆角输入框 / 彩色按钮，且 `greet`、`timer` 仍返回
  `invoke OK: Hello, world! 来自仓颉后端` 与「事件 tick #3 来自仓颉后端」；Vue 模板同步复测视觉未变。
- `cli/templates/app-vue` / `app-react` 与 `examples/vue_todo` 的页面**没有整页底色**：三处 `index.html` 里
  一行样式都没有（组件样式在各组件里，页面级样式漏了），发行态是白底 + 浅青 `<h1>`，几乎看不清。
  零 Node 模板与 `examples/hello` / `todo_check` 本来就是深色，只有这两个模板漏了。现给三处补上页面级样式
  （`:root { color-scheme: dark }` + `#16161d` 深色 body，与其余示例同一套调色板）。实测：两个模板工程与
  `vue_todo` 均为深色底、卡片层次清楚，`greet` / `timer` / `todo:add` 等交互不受影响。
- `cli/templates/app-vue` / `app-react` 与 `examples/vue_todo` 的示例页面**没有整页居中**：内容
  （标题 / 提示行 / 卡片）贴着窗口左上角，卡片不居中，与零 Node 模板、`examples/hello` 的版面不一致。
  现把 body 改成 flex 列居中（`align-items` / `justify-content: center`；用 `min-height` 而不是 `height`，
  内容比视口高时不会被裁掉），再把挂载点 `#app` / `#root` 设成 `width: 100%` 的居中列 —— 光靠 body 的
  `align-items` 不够：挂载点只有一个子节点，提示行（页面来源 / 桥状态 / 后端版本）很长时会把整列撑宽，
  卡片反而贴在左边。Linux 发行态实测：三处均为整列居中，`greet`、`timer`、`todo:add` 交互未回退。

### Changed

- 文档补 Linux 实测结论：README「验证结果」新增 Linux（2026-10-02）一节，`docs/进度记录.md`
  更新进度与后续项，`docs/使用文档.md` §6.6.1 第 5 步补两个平台的收尾语义与 Ctrl-C 行为。

## [0.4.0] - 2026-10-01

### Added

- 开源许可证：新增根目录 `LICENSE`（MIT）与 README 的许可证说明；开发规范里补「第三方代码需登记来源与许可证」。
- 仓库规范文件：新增 `README.OpenSource`（依赖与许可信息，OpenHarmony 7 字段格式）与 `CONTRIBUTING.md`（贡献指南）。
- 前端入门教程：新增 `docs/前端入门教程.md`（零基础，含一个完整的待办清单实战：桥 API、IPC 协议、事件、
  能力清单、调试入口），README 头部与使用文档 §6 增加入口；同时修正使用文档里 `emit` 的旧说明
  （它是占位实现，消息会被后端判为非法丢弃、也不会回投页面）。
- 教程示例工程入库：`examples/todo_check/`——把《前端入门教程》的待办清单实战落成可运行示例，
  前端 `ui/index.html` 由同目录 `extract.js` 从教程文档抽取，教程与代码同源（改教程可回灌示例）。
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
- URL 页面加载（热重载第一步）：新增 `TauriApp.runUrl(url)`、`TauriApp.devUrl()`（读环境变量
  `CJ_TAURI_DEV_URL`）与 `TauriApp.reload()`；宿主接口相应扩出 `startUrl` / `loadUrl` / `reload`，
  两平台桥各加同名导出 `cj_bridge_load_url` / `cj_bridge_reload`（Windows 走 `Navigate` 与整页 `Reload`）。
  前端桥新增 `__CJ_TAURI__.reload()`：作为宿主控制消息被拦截，不进 IPC hub。
  Windows 实机验证（本地 `http://127.0.0.1:8123/` 静态页 + 探针应用）：`load url:` → `Navigate -> hr=0x00000000`，
  URL 页面里 `window.__CJ_TAURI__` 照常就位、`invoke` 直接可用（`js -> native (101 bytes)`），
  前端调 `reload()` → `frontend requested reload` → `Reload -> hr=0x00000000` → 页面第二次加载并再次 invoke。
  权限模型不变：URL 页面同样受 capability 清单约束。Linux 侧实现同样写了，本机无工具链、未验证。
  CLI 的 `cj-tauri dev` 在同一版里已经接管 dev server 并注入该环境变量（见下一条）。
- 前端模板（Vue 3 + Vite）：`cj-tauri create <工程名> --template vue` 生成带 `ui/` 前端工程的仓颉应用，
  模板目录 `cli/templates/app-vue/`。前端用 Vue 3 + Vite，产物经 `vite-plugin-singlefile` 打成单个
  `ui/dist/index.html`——框架是把页面读成字符串交给 WebView 的，页面没有基准路径，所以发布态必须单文件。
  `create` 的模板参数化（`-t/--template`），缺省仍是 `app`（内联 HTML 的零 Node 样板，老用法不受影响）；
  未知模板名会明确报错。实机验证：`create --template vue` 生成 11 个文件、占位符 0 残留。
- 前端模板（React 18 + Vite）：`--template react` 生成同一套结构（`cli/templates/app-react/`），
  只把 `ui/` 换成 React——`@vitejs/plugin-react`、`src/main.jsx`、`src/App.jsx`，Vite 配置与单文件产物要求一致。
  实机验证：`create --template react` 生成 11 个文件、无残留占位符，`npm install` 与 `npm run build` 均 rc=0，
  产物目录里**只有** `dist/index.html`（145 KB，js/css 文件数 0）。React 版刻意不用 `React.StrictMode`：
  开发模式下它会把 effect 跑两遍，而这个模板的 effect 里要调 `invoke` / `listen`，双跑会让人误以为桥重复投递。
- 文档：`docs/使用文档.md` 新增 §6.6.1「交给 `cj-tauri dev` 自动做」（含 dev 接管 dev server 的 5 步、
  「没有 `ui/package.json` 就不碰 Node」的边界），`docs/前端入门教程.md` 新增 §8.4「官方的 Vue / React 模板」。
  两处都写了 HMR 的排查判据：Vite 的模块图是**客户端请求过页面之后**才建立的，没有客户端连上来时改文件，
  日志只会出现 `[no modules matched]`——那不代表 HMR 坏了；并给了 `DEBUG=vite:hmr` 的实测日志形态。
- `cj-tauri dev` 接管前端 dev server：工程里有 `ui/package.json` 才走这条路径——缺 `node_modules` 先
  `npm install`；再后台起 `npm run dev`（Vite 的输出重定向到 `ui/dev-server.log`）；等到日志里出现 Vite 的
  `Local:` 行（最多 180 秒，超时告警但不硬失败）再启动应用，并注入环境变量 `CJ_TAURI_DEV_URL`。
  应用侧 `TauriApp.devUrl()` 读到它就走 `runUrl`，页面直接来自 dev server；应用退出后收掉 dev server
  （Windows 用 `taskkill /F /T`，连 npm→node 整棵进程树；其他平台 `terminate`）。
  没有 `ui/package.json` 的工程完全不碰 Node，行为与 0.3.x 一致。
  Windows 实机验证（`examples/m2_verify/vueapp`，Vue 3 + Vite 6.4.3）：日志里 `load url: http://127.0.0.1:5173/`
  → `Navigate -> hr=0x00000000` → 页面两次 `js -> native`（第二次只在第一次拿到后端响应后才发出，
  等于「URL 页面 ↔ 仓颉」整条链路通了）→ 前端调 `reload()` → `frontend requested reload` → `Reload -> hr=0x00000000`
  → 重载后再次两次 invoke → 关窗口后 `应用退出` 与 `dev server 已收掉（pid=…）`，`node.exe` 无残留。
- `cj-tauri build` 先打前端发布包：有 `ui/package.json` 时先 `npm run build`，再检查 `ui/dist/index.html`
  确实产出（没装 `vite-plugin-singlefile` 会明确报错），然后才编译仓颉应用。该分支本轮未实机验证。

### Fixed

- `cj-tauri dev` 起 dev server 的命令行改用**相对文件名**重定向日志。`launch` 会给整条命令行加引号，
  绝对路径再自带引号会让 `cmd.exe` 拿到嵌套引号并直接报「文件名、目录名或卷标语法不正确」——
  结果是 dev server 从未启动、应用去连 URL 必然失败（`navigation failed: web status=9`）。
  已实机复现并修复。
- dev server 就绪阈值由 90 秒放宽到 180 秒：本机（Windows + Node 24 / npm 11）实测 `npm` 把 Vite 拉起来
  最慢约 85 秒（Vite 自身只用了 322 毫秒），贴着 90 秒走会误报「没就绪」。
- `create` 的收尾提示语写死了「改了 `.vue` 不重启应用就能看到效果」，React 工程下会误导用户；
  改成「改 `ui/src` 下的前端源码不重启应用就能看到效果」，两个模板都适用。

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
