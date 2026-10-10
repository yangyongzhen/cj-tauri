---
name: cj-tauri-app-dev
description: 用 cj-tauri（仓颉版类 Tauri 框架）开发应用：起工程、加命令/插件（三处联动）、写前端、过验证门禁。当用户要用 cj-tauri 创建应用、加命令、加插件、写前端页面，或问「这个功能怎么接」时使用。
---

## 何时使用

- 「用 cj-tauri 起一个应用」「新建工程」「脚手架」
- 「加一个命令 / 加一个插件」「前端调用不通」「command not allowed」
- 任何在 cj-tauri 工程里写仓颉后端或 WebView 前端的任务

## 前置认识（一句话架构）

仓颉后端（静态编译）+ 系统 WebView 前端（HTML/CSS/JS），中间是 IPC 双向桥（invoke / event）。
能力安全模型：**capabilities 白名单是唯一闸门**——代码注册了、清单没声明，一样是拒绝。

## 步骤

### 1. 起工程

```bash
cj-tauri create <名> --template app    # app=零 Node 内联页；也可 vue / react（带 ui/ 前端工程）
# 框架仓内没有可执行 CLI 时：bash cli/cj-tauri.sh create <名> --template app
```

- 生成的 `cjpm.toml` 里 `cjTauri` 与 stdx 是**本机绝对路径**，换机器要改（框架依赖可改 `../..` 相对路径）。
- 工作目录 = 项目根：`capabilities/` 与 `ui/` 都按相对路径读，启动器必须切到项目根再启动。

### 2. 加命令（三处联动，漏一处就用不了）

1. 实现 `CommandHandler`：`handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue`；
2. `TauriApp().register("cmd", Handler())`；
3. `capabilities/*.json` 的 `commands` 里声明。

只做 1+3 → `command not registered`；只做 1+2 → `command not allowed`。

### 3. 加插件（同样三处联动）

1. 实现 `Plugin`（必写 `name()` + `commands()`；要推事件 / 前端 shim 再写 `events()` / `jsShim()`），
   实现文件放 `src/plugin_<名字>.cj`；
2. `TauriApp().plugin(XxxPlugin())`——命令自动注册成 `"<插件名>:<短名>"`；
3. capabilities 里声明 `"<插件名>:<短名>"`，或引用插件 `permissions()` 声明的**命名权限集**
   （`"permissions": ["fs:readonly"]`，成员展开后与明文名同权，单层展开不递归）。

铁律：**插件只声明「我提供什么」，不自动放行**；清单不引用就不生效。
官方插件样板：`src/plugin_fs.cj`（文件）、`plugin_dialog.cj`（对话框）、`plugin_shell.cj`（子进程）、
`plugin_serial.cj`（串口）、`plugin_menu.cj`（菜单）。

### 4. 写前端

- 页面超过一屏就独立成 `ui/index.html` 由 `run()` 读入——**不要内联进仓颉三引号字符串**
  （反斜杠转义与 `${}` 插值两个坑，见 `cj-tauri-troubleshoot`）；
- 页面脚本**等桥出现再调**（模板里的 `waitForBridge`）；插件 shim 由宿主在 document-start 注入，
  页面第一行就能读 `window.__CJ_TAURI__.<插件名>`；
- 只经 `window.__CJ_TAURI__` 的 `invoke` / `listen` / `emit`，不要自己 `postMessage`；
- 命令跑在 worker 线程：**读类操作超时/空结果不是错误**（如 `serial:read` 返回 `count=0`），
  前端按返回值判断，别把 rejected 当「空」。

### 5. 验证

走 `cj-tauri-verify` skill：构建 → 实机跑 → 桥 stderr 日志取证 → 断言/截图。

## 规则（红线）

- JSON 统一用 `stdx.encoding.json`（标准库没有 `std.json`）；
- 命名：函数 `camelCase` / 类型 `PascalCase` / 常量 `UPPER_SNAKE_CASE`；**注释用中文**；
- 依赖方向单向：`app.cj → host.cj / ipc_hub.cj → capability.cj`，禁止反向与循环（跨层协作用回调注入）；
- 平台差异只允许出现在 `@When` 条件编译与 C 桥（`native/bridge_*.c`）——上层禁止运行期平台分支；
- **写仓颉代码只用已验证的 API，不猜签名**：拿不准先 grep `examples/` 与 `src/` 的同形用法；
- 写代码前先看同形样板：`examples/` 下有十二个可跑示例（hello / todo_check / plugin-* / movie / music /
  serial-assistant / ipc-bench…），业务向的照 `serial-assistant`、插件向的照 `plugin-fs`。
