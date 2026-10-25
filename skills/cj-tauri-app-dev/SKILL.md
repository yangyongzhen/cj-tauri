---
name: cj-tauri-app-dev
description: 用 cj-tauri（仓颉语言的 Tauri 框架）开发应用：起工程、加命令/插件（三处联动）、写前端、过验证门禁。当用户要用 cj-tauri 创建应用、加命令、加插件、写前端页面，或问「这个功能怎么接」时使用。
---

## 何时使用

- 「用 cj-tauri 起一个应用」「新建工程」「脚手架」
- 「加一个命令 / 加一个插件」「前端调用不通」「command not allowed」
- 任何在 cj-tauri 工程里写仓颉后端或 WebView 前端的任务

## 前置认识（一句话架构）

仓颉后端（静态编译）+ 系统 WebView 前端（HTML/CSS/JS），中间是 IPC 双向桥（invoke / event）。
能力安全模型：**capabilities 白名单是唯一闸门**——代码注册了、清单没声明，一样是拒绝。

## 步骤

### 0. 环境先过关（没有环境，后面全是空谈）

先跑 `cj-tauri-env` skill 的一键检测：`cjc` / `cjpm` / `CANGJIE_HOME` / `CANGJIE_STDX` /
gcc（Linux）或 llvm-mingw（Windows）/ WebKitGTK / WebView2。缺哪样补哪样——
安装指引、仓颉资料入口（官网 / 中心仓 / API / CangjieSkills 技能包）都在那个 skill 里。
环境没齐就先装环境，**不要**在缺失的环境里试编译。

### 1. 起工程（v2.0 新形态：一份清单 + sync 派生）

```bash
cj-tauri create <名> --template app    # app=零 Node 内联页；也可 vue / react / ohos
# 框架仓内没有可执行 CLI 时：bash cli/cj-tauri.sh create <名> --template app
```

生成的工程根是三样东西：

- **`cj-tauri.toml`** —— 工程清单（id / 前端入口 / 目标端），**单一真相**；
- `src/` —— 业务仓颉代码（`build()` 装配就在 `src/main.cj`）；
- `assets/` —— `assets/ui/` 前端页面与 `assets/capabilities/` 能力清单。

各端骨架（`targets/desktop`、`targets/ohos`）**不入库、不手写**：`cj-tauri sync [desktop|ohos]`
从清单派生，业务代码以 path 依赖进入骨架。改了清单/模板后重跑 `sync` 即可。
（旧形态工程 = 根目录没有 `cj-tauri.toml`，CLI 命令双轨兼容，但新工程一律走新形态。）

- 生成的 `cjpm.toml` 里 `cjTauri` 与 stdx 是**本机绝对路径**，换机器要改（框架依赖可改 `../..` 相对路径）；
- 工作目录 = 项目根：`assets/` 与 `cj-tauri.toml` 都按相对路径读，启动器必须切到项目根再启动。

### 2. 加命令（三处联动，漏一处就用不了）

1. 实现 `CommandHandler`：`handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue`；
2. `TauriApp().register("cmd", Handler())`；
3. `assets/capabilities/*.json` 的 `commands` 里声明（旧形态工程则是根目录 `capabilities/`）。

只做 1+3 → `command not registered`；只做 1+2 → `command not allowed`。

### 3. 加插件（同样三处联动）

1. 实现 `Plugin`（必写 `name()` + `commands()`；要推事件 / 前端 shim / 权限集 / scope 再写
   `events()` / `jsShim()` / `permissions()` / `scopeAware()`），实现文件放**插件子包**
   `src/plugins/<名字>/plugin_<名字>.cj`（文件头 `package cjTauri.plugins.<名字>`，如
   `src/plugins/fs/plugin_fs.cj`；FFI 声明也随插件放同目录）——**一个插件一个子包**：
   链接粒度是「包 = 静态库」，挤同一个包会导致用谁都整包连坐；
2. `TauriApp().plugin(XxxPlugin())`——命令自动注册成 `"<插件名>:<短名>"`；
   **`commands()` 返回的 map 键必须写「短名」**，键里再写前缀就得到 `redis:redis:connect`
   （所有命令以未注册告终）；
3. capabilities 里声明 `"<插件名>:<短名>"`，或引用插件 `permissions()` 声明的**命名权限集**
   （`"permissions": ["fs:readonly"]`，成员展开后与明文名同权，单层展开不递归）。

铁律：**插件只声明「我提供什么」，不自动放行**；清单不引用就不生效。
插件间**不得互相引用**（会重新引入连坐）；共用工具进核心共享层。
官方插件样板：`src/plugins/` 下 14 个子包——fs（文件）、dialog（对话框）、shell（子进程）、
serial（串口）、store（持久化 KV）、clipboard（剪贴板）、notification（系统通知）、menu（菜单）、
http（出网白名单）、ws（WebSocket）、mqtt、redis（协议纯仓颉）、log（轮转落盘）、sqlite（FFI 直连系统库）；
插件向示例照 `examples/plugin-fs/`。

**带路径参数的插件还有第三层闸门（路径 scope，RFC-003 第 4 期）**：命令放行 ≠ 路径放行。
清单可加 `"scopes": { "fs": { "allow": ["$HOME/notes/**"], "deny": ["**/id_rsa"] } }`；
插件侧用 `Plugin.scopeAware()` 声明「我懂 scope」，再对页面可控的路径参数调
`IpcContext.resolveScopedPath("<插件名>", path)` 取规范化后的真实路径（判定只有共享层一份，
别在插件里另写）。语义：**先 deny 后 allow**、allow 必须显式命中（空 allow = 全拒）、
`*` / `**` / `?` 与 `$HOME` / `$TEMP` / `$CWD`。没写 `scopes` 的清单行为不变（全量放行 + 启动提示）。

### 4. 写前端

- 页面超过一屏就独立成 `assets/ui/index.html`（新形态）由 `run()` 读入——**不要内联进仓颉三引号字符串**
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
- 写代码前先看同形样板：`examples/` 下 28 个可跑示例（hello / plugin-* / http-client / mqtt-client /
  redis-client / music / serial-assistant / modbus-poll / markdown-notes / ai-chat…），
  业务向的照 `serial-assistant`、插件向的照 `plugin-fs`；要接鸿蒙再看 `examples/ohos/`（music / movie）。
