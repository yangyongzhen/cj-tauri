# 与 Tauri 的差异清单

> 给从 Tauri 过来的开发者：哪些概念能直接映射、哪些形状不同、哪些能力暂缺。
> 口径：只写本仓验证过的事实；Tauri 侧以 Tauri 2 为参照。

## 一眼总览

| 维度 | Tauri 2 | cj-tauri |
|---|---|---|
| 后端语言 | Rust | 仓颉（静态编译，无 VM） |
| WebView | 系统 WebView（WebView2 / WKWebView / WebKitGTK） | 同策略：系统 WebView（WebView2 / WebKitGTK / 鸿蒙 ArkWeb） |
| 支持平台 | Windows / macOS / Linux / iOS / Android | Windows / Linux / 鸿蒙（ArkWeb，真机闭环）；**macOS 未做** |
| 前端 | 任意 Web 技术栈 | 同；`create` 缺省给零 Node 内联 HTML 模板，Vue/React 模板走 Vite |
| 脚手架 | create-tauri-app（npm） | `cj-tauri create`（npm 包 `cj-tauri`，同款命令面） |
| 进程形态 | 多进程 WebView | 每平台一个宿主进程，页面跑在系统 WebView 里 |

## 概念映射

| Tauri 2 概念 | cj-tauri 对应 | 差异 |
|---|---|---|
| `#[tauri::command]` + `invoke_handler` | 实现 `CommandHandler` + `TauriApp.register` + 清单 `commands` | 三处联动缺一不可（少注册报 `command not registered`，少放行报 `command not allowed`） |
| `@tauri-apps/api` 的 `invoke` / `listen` / `emit` | `window.__CJ_TAURI__.invoke / listen / emit`（document-start 注入，对标同语义） | 业务代码不要自己 `postMessage` |
| Capabilities（ACL） | `capabilities/*.json`：`commands` / `events` / `permissions` | 形状相似；cj-tauri 另有「命名权限集」（插件声明短集名，清单引用）与**路径 scope**（见下） |
| 插件（`tauri-plugin-*`） | `src/plugins/<名字>/` 子包，`Plugin` trait | 命令自动登记成 `<插件名>:<短名>`；权限集声明 ≠ 放行，清单不引用就不生效 |
| 路径 scope（`fs:scope`） | 清单 `scopes`（allow/deny + `$HOME`/`$TEMP`/`$CWD` 变量） | **先 deny 后 allow**；空 allow = 该插件路径全拒；运行期加白只收具体值、拒通配 |
| 窗口 label | 同（`WindowConfig` + label，多窗口按 label 路由事件与命令） | 语义一致 |
| 事件 | `listen` / `emit` + 事件也在白名单里声明 | 未声明事件被拒（Tauri 2 对事件不做 ACL） |

## 行为差异（容易踩的）

- **命令是异步分发的**：通过校验的命令进 worker 线程执行，慢命令不冻 UI；同一命令并发调用
  **不保证顺序**，前端按 promise id 匹配。Tauri 的同步/异步命令语义与这里不同步——这里一律异步回投。
- **插件 JS 注入只在 `start()` 前注册**：`Plugin.jsShim()` 经 `addInitScript` 通道注入，
  `runUrl()` 的外部页面拿不到插件 shim（会有 stderr 提示），需要并入页面自己带。
- **权限集与 scope 都是「声明 ≠ 放行」**：集声明、scope 规则都要被清单 `permissions` / `scopes`
  引用才生效——这点比 Tauri 的 ACL 更显式，也更容易漏。
- **越权拒绝有日志**：`command not allowed` / `command not registered` / `scope denied` 都打 stderr，
  排查第一件事看桥日志。

## 平台能力差异

- **菜单**：三端都有；鸿蒙侧渲染在应用侧组件（`bindMenu`），只支持**扁平菜单、无禁用位**，
  嵌套树写法在鸿蒙上要退化为扁平。
- **托盘 / 全局快捷键 / 文件拖入 / 原生对话框 / 系统通知**：Windows / Linux 落地（部分为桩，见
  `docs/平台能力矩阵.md`）；鸿蒙侧能力位多数为 0（如实拒绝），原生对话框可由应用侧声明式 overlay 代偿。
- **剪贴板**：三端可用（鸿蒙走 `OH_Pasteboard_*` NDK FFI 直连，不经 C 桥）。
- **shell 子进程**：argv 直传（无 shell 注入面），同步阻塞、无流式输出/超时——Tauri 的
  `Command` 有事件流，这里长驻/交互式进程不适用。
- **updater / 自动更新**：暂无对应物。

## 构建与打包差异

- **无系统级 bundler**：桌面产物是单个可执行 + 资源目录；Windows 另有便携目录包与
  免安装单文件包（内嵌 WebView2Loader 与页面资源），npm 侧只发脚手架 CLI 不发框架。
- **鸿蒙侧不走 C 桥**：宿主直接写在仓颉侧（ArkUI 绑定），核心 FFI 按 `@When[env != "ohos"]` 门禁降级；
  工程形态是标准 DevEco 工程（`cj-tauri sync` 派生），构建交给 DevEco / hvigor。
- **Vite dev server 由 CLI 接管**：`cj-tauri dev` 对 Vue/React 模板起 dev server 并把地址传给窗口
  （对标 Tauri 的 `beforeDevCommand` + `devUrl`，但由 CLI 全程托管、Ctrl-C 一并收掉进程树）。

## 迁移清单

从 Tauri 2 项目迁过来时按此对照：

1. `#[tauri::command]` → `CommandHandler` 类 + `register` + 清单放行（三处）；
2. `invoke()` 调用点改名空间 `window.__CJ_TAURI__`（或等 `waitForBridge`）；
3. `tauri.conf.json` 的 allowlist/capabilities → `capabilities/*.json`（逐命令写明文或引用权限集）；
4. `fs` 插件的路径白名单 → `scopes`（注意先 deny 后 allow、空 allow 全拒）；
5. 事件如果用了动态名，需要在清单里逐个声明；
6. macOS/移动端目标暂不可用——先按 Windows/Linux/鸿蒙排期。
