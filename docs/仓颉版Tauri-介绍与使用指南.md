# 仓颉版 Tauri：介绍与使用指南

> 用仓颉写桌面混合应用：**后端仓颉静态编译，前端任意 Web 技术**，中间的「系统 WebView 宿主 + IPC 双向桥 + 能力安全模型」已经装好并跑通 Windows/Linux 双平台。
>
> 本文是「这是个什么项目 + 怎么把它跑起来 + 怎么在上面开发」的一条龙介绍。
> 要查逐条命令的参数细节与平台陷阱速查表，见 [使用文档.md](使用文档.md)；原理与踩坑全过程见 [技术方案.md](技术方案.md)、[踩坑与实施记录.md](踩坑与实施记录.md)。

---

## 1. 它解决什么问题

桌面应用的界面层有两类做法：

- **把浏览器打包进去**（Electron 系）：开发体验好，代价是每个应用都背着一份 Chromium——安装包上百兆、内存占用高。
- **复用系统自带的 WebView**（Tauri 系）：界面仍然用 HTML/CSS/JS 写，但渲染交给操作系统的 WebView，
  后端只写业务逻辑并直接调系统能力。结果是安装包小、启动快，且没有额外的浏览器内核要跟随升级。

**cj-tauri 就是仓颉语言版的 Tauri**：把 Tauri 那套「WebView 宿主 + IPC 双向桥 + capability 权限模型」的架构，
原样搬到仓颉上实现。后端换成仓颉（静态编译、无需运行时 JIT、可面向 OpenHarmony/HarmonyOS 生态），
前端仍然是任意 Web 技术，两者之间的接口形态刻意贴近 Tauri——会写 Tauri 的人基本不用重新学。

### 1.1 与 Tauri 的逐项对照

| 维度 | Tauri 2 | cj-tauri |
|---|---|---|
| 后端语言 | Rust | **仓颉**（`cjc` 静态编译） |
| 前端 | 任意 Web 技术 | 任意 Web 技术 |
| 前端桥 API | `@tauri-apps/api`：`invoke` / `emit` / `listen` | `window.__CJ_TAURI__`：`invoke` / `emit` / `listen` |
| 命令定义 | `#[tauri::command]` 函数 + `Builder` 注册 | `CommandHandler` 类 + `TauriApp().register()` |
| 权限模型 | `capabilities/*.json` | `capabilities/*.json`（同构：命令/事件白名单，默认最小权限） |
| Windows WebView | WebView2 | WebView2 |
| Linux WebView | WebKitGTK | webkit2gtk-4.1 |
| macOS WebView | WKWebView | 未实现（路线中） |
| 鸿蒙 WebView | 无官方支持 | **预留 ArkWeb 后端位**（条件编译） |
| 构建工具 | `cargo` / `tauri` CLI | `cjpm` / `cj-tauri` CLI（仓颉原生实现） |

### 1.2 项目现状（当前版本 0.3.0）

| 能力 | 状态 |
|---|---|
| Linux 桌面（WebKitGTK） | ✅ MVP 已跑通 |
| Windows 桌面（WebView2） | ✅ 已跑通（本机验证：cjc 1.2.0 + Runtime 122.0.2365.106 + SDK 1.0.2365.46） |
| 窗口配置化 | ✅ `WindowConfig(title, width, height)`，另有 `devTools` 字段可关掉开发者工具；不配置时沿用默认（`cj-tauri` / 900×640） |
| capability 自动加载 | ✅ `run()` 时自动扫描 `capabilities/` 下的全部 json，显式挂载优先 |
| 内置命令 | ✅ `system:version` / `system:ping` / `system:echo` / `system:devtools` |
| 脚手架 CLI `cj-tauri` | ✅ `create` / `dev` / `build` / `run` / `info`，Windows + Linux 双平台启动器 |
| 文档与规范 | ✅ [使用文档.md](使用文档.md)、[AGENTS.md](../AGENTS.md)（开发契约）、[CHANGELOG.md](../CHANGELOG.md)（版本与变更） |
| 鸿蒙 ArkWeb 后端 | 🔜 路线中（需 DevEco + 真机） |
| 前端框架模板、插件体系 | 🔜 路线中 |

---

## 2. 架构：一次 `invoke` 走完的完整链路

```
 前端页面 (HTML/CSS/JS)
   │   window.__CJ_TAURI__.invoke('greet', { name: '仓颉' })
   ▼
 注入的桥 JS（对标 @tauri-apps/api）
   │   JSON over postMessage
   ▼
 WebView 宿主抽象 host.cj
   ├─ Windows: host_webview2.cj + native/bridge_win.c   (Win32 窗口 + WebView2，消息循环在宿主线程)
   └─ Linux  : host_webkit.cj   + native/bridge_linux.c (GTK/WebKit，全部调用在原生 pthread 内)
   │   FFI 回调进入仓颉
   ▼
 IPC 消息桥 ipc_hub.cj  ← JSON 反序列化 / 命令分发 / 结果回填
   ▼
 能力安全模型 capability.cj  ← 命令与事件白名单，未声明即拒绝（默认最小权限）
   ▼
 你注册的命令 CommandHandler.handle(cmd, args, ipc)
   ▼
 内置命令 api_system.cj：system:version / system:ping / system:echo / system:devtools
```

具体到一次 `invoke("greet", {name:"仓颉"})` 的时序：

1. 前端调 `window.__CJ_TAURI__.invoke(...)`，桥 JS 为本次调用生成一个 id，把 `{cmd, args, id}` 拼成 JSON，
   通过宿主提供的消息通道投出去（Windows：`chrome.webview.postMessage`；Linux：WebKit 的 script message）。
2. 宿主的原生回调收到字符串，经 FFI 交给仓颉侧的 `IpcHub`。
3. `IpcHub` 反序列化出命令名与参数，先过 **capability 校验**：命令没写进能力清单就直接拒绝，返回
   `command not allowed: xxx`，不会进入业务代码。
4. 校验通过，分发到 `TauriApp().register("greet", GreetCommand())` 注册的那个 handler，执行你的业务逻辑。
5. 返回值序列化成 JSON 回传宿主，由宿主 `ExecuteScript` 注入回页面并 resolve 对应的 Promise。
6. 反向通道同理：后端 `ipc.emit("tick", payload)` → 宿主投递到页面 → 前端 `listen("tick", cb)` 的回调被触发。

**这套流程在 Windows 与 Linux 上完全共用**：`ipc_hub` / `capability` / `api_system` 是纯仓颉、
不含任何平台分支，平台差异只存在于 `host_*.cj` 与对应的 C 桥里。这也是为什么鸿蒙 ArkWeb 后端
将来只需要补一个宿主实现。

---

## 3. 两个平台的宿主实现差异

| | Linux | Windows |
|---|---|---|
| WebView | webkit2gtk-4.1 | WebView2 |
| 前端 → 原生 | `WebKitUserContentManager` 的 script message | `chrome.webview.postMessage` |
| 原生 → 前端 | `webkit_web_view_evaluate_javascript` | `ICoreWebView2::ExecuteScript` |
| 窗口 | GTK 窗口 | Win32 窗口（`ShowWindow` + 自绘客户区） |
| C 桥文件 | `native/bridge_linux.c` | `native/bridge_win.c` |
| 构建脚本 | `native/build_linux.sh` | `native/build_win.bat` |
| 运行期动态库 | Linux `.so` + `LD_LIBRARY_PATH` | Windows `.dll` + `PATH` |

两条实现各自有一个**必须遵守的约束**（改宿主层时别踩）：

- **Linux**：仓颉 `cjnative` 的 `main` 跑在 M:N 轻量线程的堆上协程栈里，而 WebKit 的 JSC 会用
  pthread 栈边界校验 SP —— 直接在仓颉线程里调 GTK/WebKit 会 `abort`。所以桥把所有 GTK/WebKit 调用
  放在自己创建的原生 pthread 中，仓颉侧只通过 FFI 调用、回调经 `CFunc` 回到仓颉。
- **Windows**：回调里拿到的 `ICoreWebView2Environment` / `ICoreWebView2Controller` **必须自己 `AddRef`**
  持有，否则回调返回后对象即被释放，WebView2 会立刻关掉浏览器进程——现象是「窗口空白、导航完成事件
  不触发、`ExecuteScript` 恒返回 `0x8007139F`（E_ILLEGAL_METHOD_CALL）」。另外要先 `ShowWindow` 再
  `put_Bounds`，否则首帧尺寸为 0。

> 这两条约束的完整踩坑过程（含错误码与修复思路）记录在 [踩坑与实施记录.md](踩坑与实施记录.md)。

---

## 4. 快速上手

### 4.1 准备三样东西

**① 仓颉 SDK**（本文验证版本 **1.2.0**，目标三元组 Windows `x86_64-w64-mingw32` / Linux `x86_64-unknown-linux-gnu`）

SDK 目录不只要能跑 `cjc`，还要让这四个目录在 `PATH` 里（官方 `envsetup` 的布局）：
`runtime/lib/<平台>`、`bin`、`tools/bin`、`tools/lib`。懒得全配也行——**只设 `CANGJIE_HOME` 指向 SDK 根目录**，
`cj-tauri` 启动器会自动补齐。

```bash
# Linux / Git Bash
source /path/to/Cangjie/envsetup.sh     # 最省事，SDK 自带脚本
# 或只设根目录，交给 cj-tauri 自己补 PATH
export CANGJIE_HOME=/path/to/Cangjie
```
```bat
REM Windows cmd
set "CANGJIE_HOME=D:\Program Files (x86)\Cangjie"
```

**② stdx 扩展库**（必需）

应用与框架都用它做 JSON（`stdx.encoding.json`），`create` 会把路径写进生成的 `cjpm.toml`：

```bash
export CANGJIE_STDX=/opt/cangjie-stdx/linux_x86_64_cjnative/dynamic/stdx      # Linux
export CANGJIE_STDX=/d/cangjie-stdx/windows_x86_64_cjnative/dynamic/stdx      # Git Bash
```
```bat
REM Windows cmd
set "CANGJIE_STDX=D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"
```

**③ 平台依赖**

| 平台 | 依赖 | 备注 |
|---|---|---|
| Windows | mingw gcc、WebView2 Runtime、WebView2 SDK | Runtime：Win11 自带；SDK **仅编译 C 桥时需要** |
| Linux | `libwebkit2gtk-4.1-dev`、`libgtk-3-dev` | 运行时还需要 `webkit2gtk-4.1` 的 `.so` |

> **WebView2 的版本红线**：编译桥用的 SDK 版本**不能高于**机器上的 WebView2 Runtime。
> 本机实测组合是 Runtime `122.0.2365.106` + SDK `1.0.2365.46`（对应关系可在 `native/build_win.bat`
> 顶部的注释里查到查询命令）。换版本改 `native/build_win.bat` 顶部的 `WEBVIEW2_SDK_ROOT` 即可，
> 脚本会自动把**同版本**的 x64 `WebView2Loader.dll` 同步到 `native/webview2/`。

### 4.2 拿到框架代码，构建 CLI 本体

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git      # AtomGit（国内直连推荐）
git clone git@github.com:yangyongzhen/cj-tauri.git     # GitHub（需已配置 SSH 密钥）
cd cj-tauri
```

CLI 本体是一个仓颉程序（`cli/` 下自带 `cjpm.toml`）。**首次运行启动器会自动 `cjpm build`**，
打印一行 `first run: building the CLI itself ...`，产物落在 `cli/target/release/bin/main.exe`；
也可以手动构建：

```bash
./cli/cj-tauri.sh --version      # Git Bash / Linux / macOS 启动器
```
```bat
REM Windows cmd
cli\cj-tauri.bat --version
```

### 4.3 三步得到一个应用

```bash
# ── Git Bash / Linux / macOS ──
cd ~/projects
/path/to/cj-tauri/cli/cj-tauri.sh create myapp     # ① 生成工程（src/ ui/ capabilities/ cjpm.toml）
cd myapp
/path/to/cj-tauri/cli/cj-tauri.sh info             # ② 自检：框架/项目/stdx/SDK/cjpm/桥 是否都解析得到
/path/to/cj-tauri/cli/cj-tauri.sh dev              # ③ 构建 C 桥 + cjpm build + 启动窗口
```
```bat
REM ── Windows cmd ──
mkdir D:\temp\myapp-src
cd /d D:\temp\myapp-src
E:\path\to\cj-tauri\cli\cj-tauri.bat create myapp
cd myapp
E:\path\to\cj-tauri\cli\cj-tauri.bat info
E:\path\to\cj-tauri\cli\cj-tauri.bat dev
```

`create` 生成 6 个文件：`cjpm.toml`、`src/main.cj`、`ui/index.html`、`capabilities/default.json`、`README.md`、`.gitignore`。
`dev` / `build` / `run` 会**自动为子进程准备好「C 桥（含 Windows 的 `native/webview2/`）+ stdx + 仓颉运行时」的
动态库搜索路径**，不用自己拼 `PATH` / `LD_LIBRARY_PATH`——这是用 CLI 相比手动构建最省事的地方。

### 4.4 跑起来应该看到什么

一个深色主题的卡片界面：输入名字点按钮 → 前端 `invoke("greet")` → 仓颉返回 `Hello, <名字>! 来自仓颉后端`；
点「启动定时器」→ 后端 `ipc.emit("tick")` 每秒推一次，底部实时刷出计数。

参考实测数据（Windows / WebView2，本机验证）：

| 现象 | 观测值 |
|---|---|
| 窗口创建、环境与控制器就绪、HTML 导航 | `hr=0x0`（成功） |
| JS → 原生消息 | 62 字节 |
| 原生 → JS 消息 | 48 字节 |
| 脚本注入 `ExecuteScript` | `hr=0x0` |

---

## 5. 工程结构：脚手架给了你什么

```
myapp/
├── cjpm.toml                  # 应用构建配置：cjTauri 框架路径依赖 + 平台链接段
├── src/main.cj                # 后端入口：命令定义 + 装配 + 启动
├── ui/index.html              # 前端页面（任意 Web 技术，直接改它就行）
├── capabilities/default.json  # 能力清单：命令 / 事件白名单
├── README.md
└── .gitignore
```

框架仓库的对应位置：

```
cj-tauri/
├── src/            # 框架核心（纯仓颉，两平台共用，不含平台分支）
├── native/         # 两平台 C 桥 + 构建脚本 + Windows WebView2 SDK 产物目录
├── cli/            # 脚手架 CLI（仓颉实现）+ templates/app/ 模板
├── examples/hello/ # 示例应用（greet + tick + 越权演示）
└── docs/           # 本文 + 使用文档 + 技术方案 + 踩坑记录
```

`create` 生成的 `cjpm.toml` 里有两处和你机器相关：`cjTauri` 的**本机绝对路径依赖**，
以及按宿主平台注入的**链接段**（Windows 要链 `libcjtbridge.dll` 对应的导入库）。所以：

> 换机器、换目录后直接 `cjpm build` 会失败——**重跑一次 `create`**，或手改 `cjpm.toml` 里的这两个地方。

## 6. 开发一个应用

### 6.1 应用的入口（模板 `src/main.cj`）

```cangjie
package {{PACKAGE_NAME}}

import cjTauri.*
import stdx.encoding.json.*
import std.fs.File

// 一个命令 = 一个 CommandHandler 子类（对标 tauri command）
public class GreetCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var name = "world"
        if (let Some(n) <- args.get("name")) {
            match (n.kind()) {
                case JsonKind.JsString => name = n.asString().getValue()
                case _ => ()
            }
        }
        return JsonString("Hello, ${name}! 来自仓颉后端")
    }
}

main(): Int64 {
    // 1) 装配应用（对标 tauri::Builder）：配置窗口 + 注册命令
    //    能力清单不需要手写读文件：run() 会自动扫描工作目录下的 capabilities/ 全部 json
    let app = TauriApp()
        .window(WindowConfig("我的应用", 1000, 700))   // 标题 / 宽 / 高；不调用则用默认 cj-tauri 900×640
        .register("greet", GreetCommand())
        .register("timer", TimerCommand())

    // 2) 载入前端页面并启动（阻塞至窗口关闭）
    let html = String.fromUtf8(File.readFrom("ui/index.html"))
    app.run(html)
    return 0
}
```

注意三点：**页面是后端读文件后交给宿主的**（所以换页面 = 改 `ui/index.html`，或把构建产物拷进去）；
**应用以项目根目录为工作目录**，`capabilities/` 与 `ui/` 都按相对路径读取；
**能力清单默认自动加载**——只想挂载指定清单时用 `addCapabilityJson(...)` / `loadCapabilities(dir)` 显式挂载，
一旦显式挂载就不再自动扫描（更适合多套权限分发的场景）。

### 6.2 加一个自己的命令：改三处

**第一步**，写命令类——照抄模板 `greet` 的取参写法最稳（`args` 是 `JsonObject`，取值前先判 `kind`）：

```cangjie
public class ShoutCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var text = "hello"
        if (let Some(v) <- args.get("text")) {
            match (v.kind()) {
                case JsonKind.JsString => text = v.asString().getValue()
                case _ => ()
            }
        }
        return JsonString("收到：${text}")
    }
}
```

**第二步**，注册进去：

```cangjie
let app = TauriApp()
    .window(WindowConfig("我的应用", 1000, 700))
    .register("greet", GreetCommand())
    .register("timer", TimerCommand())
    .register("shout", ShoutCommand())      // ← 新增
```

**第三步**，写进能力清单 `capabilities/default.json`（漏了这步，前端会收到 `command not allowed: shout`）：

```json
{
  "identifier": "default",
  "windows": ["main"],
  "commands": ["greet", "timer", "shout", "system:version", "system:ping", "system:echo", "system:devtools"],
  "events": ["tick"]
}
```

前端调用：

```js
window.__CJ_TAURI__.invoke('shout', { text: 'hi' }).then(r => console.log(r));
```

### 6.3 后端推事件、前端监听（仓颉 → JS 通道）

模板里的 `TimerCommand` 就是标准写法：命令被调用时只负责启动一次后台线程，之后由线程持续推事件。

```cangjie
spawn {
    while (true) {
        sleep(Duration.second)
        this.counter += 1
        var payload = JsonObject()
        payload.put("n", JsonInt(this.counter))
        ipc.emit("tick", payload)        // 事件名必须写进能力清单的 events
    }
}
```

```js
const tauri = window.__CJ_TAURI__;
tauri.listen('tick', function (payload) { console.log(payload.n); });   // 每秒收到一个 n
tauri.invoke('timer');                                                  // 触发上面的线程
```

### 6.4 前端桥 API

| API | 方向 | 说明 |
|---|---|---|
| `invoke(cmd, args)` | 前端 → 后端 | 调用命令，返回 Promise；`args` 是普通对象，后端收到 `JsonObject` |
| `listen(event, cb)` | 后端 → 前端 | 订阅事件，回调收到后端 `ipc.emit` 的 payload |
| `emit(event, payload)` | 前端 → 后端 | 前端侧的事件投递，与 `listen` 同一套事件模型 |

涉及系统能力的命令（`system:version` / `system:ping` / `system:echo` / `system:devtools`）也**同样要在能力清单里声明**才能用。

### 6.5 能力清单：默认最小权限

- 应用在 `capabilities/` 下声明命令与事件白名单；**启动时自动加载该目录下的全部 json**（目录缺失或为空时按最小权限启动，任何命令都会被拒绝）；
- 想只挂载指定清单时用 `loadCapabilities(dir)` / `addCapabilityJson(json)` 显式挂载：**显式挂载优先，且不再自动扫描**；
- **未声明的命令一律拒绝**，返回 `command not allowed: xxx`，不会进入业务代码；
- 未声明的事件不会投递到页面；
- 校验层独立于 WebView 后端，Windows / Linux（以及将来的鸿蒙 ArkWeb）**共用同一套**。

改动后端逻辑时，这个清单就是你的安全边界：新增能力要显式声明，等于强制作者做一次「这个能力要不要暴露」的决定。

---

## 7. CLI 命令参考

| 命令 | 作用 |
|---|---|
| `cj-tauri create <项目名>` | 创建新工程（`src/` + `ui/` + `capabilities/` + `cjpm.toml`） |
| `cj-tauri dev` | 构建 C 桥 + `cjpm build` + 启动应用 |
| `cj-tauri build` | 构建 C 桥 + `cjpm build`（不启动） |
| `cj-tauri run` | 运行已构建产物 |
| `cj-tauri info` | 环境自检：打印框架 / 项目 / stdx / SDK / cjpm / 桥的解析结果（排障第一步） |
| `cj-tauri help` / `-h` / `--help` | 帮助 |
| `cj-tauri --version` / `-V` | 版本 |

环境变量：

| 变量 | 作用 |
|---|---|
| `CJ_TAURI_ROOT` | 框架仓库根目录。**不在框架仓库内运行时必须设置**（CLI 靠它找到框架、模板与 C 桥） |
| `CANGJIE_HOME` | 仓颉 SDK 根目录；默认从 `PATH` 里的 `cjc` 反推 |
| `CANGJIE_STDX` | stdx 动态库目录；默认从框架 / 项目的 `cjpm.toml` 读取 |

两个启动器（CLI 本体是仓颉程序，启动器负责补 PATH 并在首次运行时构建它）：

| 平台 | 启动器 | 产物 |
|---|---|---|
| Linux / macOS / Git Bash | `cli/cj-tauri.sh` | `cli/target/release/bin/main.exe` |
| Windows cmd | `cli/cj-tauri.bat` | 同上 |

## 8. 不用 CLI 的手动构建

想看清每一步在干什么，或者要接进自己的构建流水线时，手动跑这三步：

```bash
# 1) 编译 C 桥（只需一次；改了 native/*.c 之后重跑）
cd native && ./build_linux.sh && cd ..            # Linux：产出 libcjtbridge.so
cd native && build_win.bat && cd ..               # Windows：产出 libcjtbridge.dll + 同步 WebView2Loader.dll

# 2) 编译应用
cd myapp && cjpm build

# 3) 运行（★ 工作目录必须是项目根，capabilities/ 与 ui/ 按相对路径读）
LD_LIBRARY_PATH=<框架>/native:<stdx>:$LD_LIBRARY_PATH ./target/release/bin/main     # Linux
```

```bat
REM Windows：运行仓内示例（run_win.bat 已配好 Cangjie 运行时 / stdx / 桥 DLL 的 PATH）
native\build_win.bat
cd examples\hello && cjpm build
cd ..\..
run_win.bat
```

差别就在第 3 步的环境：`dev` / `run` 会替你把这些动态库目录拼好，手动跑则要自己拼——
Linux 是 `LD_LIBRARY_PATH`，Windows 是 `PATH`。

## 9. 排障速查

**第一条命令永远是 `cj-tauri info`**：它会把「框架根目录、项目根、stdx、SDK、cjpm、C 桥」逐个解析并打印是否命中，
哪一环是空的通常一眼可见。

| 症状 | 原因与处理 |
|---|---|
| `cjpm build` 返回 **127 且没有任何输出** | `PATH` 里少了 SDK 的 `runtime/lib/<平台>`、`bin`、`tools/bin`、`tools/lib` 之一（缺一即 127）→ 回到 §4.1① |
| **Git Bash 下原生进程起不来**（127、无输出） | `PATH` 里写成了盘符形式 `D:/...`，MSYS 的路径转换会破坏该条目 → 必须写 POSIX 形式 `/d/...`；`cli/cj-tauri.sh` 已内置该转换 |
| 提示找不到 `cjpm` | SDK 的 `tools/bin` 不在 `PATH` |
| 前端 `invoke` 返回 `command not allowed: xxx` | 命令没写进 `capabilities/default.json` 的 `commands` |
| 事件收不到 | 事件名没写进能力清单的 `events` |
| **窗口空白 / 导航完成事件不触发 / `ExecuteScript` 恒返回 `0x8007139F`** | 桥里的 `ICoreWebView2Environment` / `ICoreWebView2Controller` 没有 `AddRef` 持有（改 Windows 桥时最常踩） |
| WebView2 初始化失败 | 编译桥的 SDK 版本高于本机 Runtime → 降 SDK 或升 Runtime，见 §4.1③ |
| 换机器 / 换目录后构建失败 | 生成的 `cjpm.toml` 里是旧机器的绝对路径 → 重跑 `create` 或手改依赖与链接段 |
| 启动后找不到页面或能力清单 | 运行的工作目录不是项目根 |

平台专属的坑（GTK 主线程约束、MSYS 路径、`hdc file recv` 的 `MSYS_NO_PATHCONV=1` 等）在
[使用文档.md](使用文档.md) 第 7 节有更细的说明。

---

## 10. 验证结果（实测数据，非推测）

**Linux / WebKitGTK（2026-08-21）**

| 验证项 | 结果 |
|---|---|
| `invoke("greet")` JS → 仓颉 → JS | ✅ `Hello, 仓颉! 来自仓颉后端` |
| 内置命令 `system:ping` | ✅ `pong` |
| capability 越权 `system:rm` | ✅ 拒绝：`command not allowed` |
| 未注册命令 `no_such_cmd` | ✅ 拒绝 |
| 事件推送 `tick`（仓颉 → JS） | ✅ 11+ 条到达前端 |
| UI 真实渲染 | ✅ 截图确认（深色主题卡片 + 按钮） |

**Windows / WebView2（2026-10-01，cjc 1.2.0 + Runtime 122.0.2365.106 + SDK 1.0.2365.46）**

| 验证项 | 结果 |
|---|---|
| C 桥构建 `native\build_win.bat` | ✅ `libcjtbridge.dll` + 同步 `webview2\WebView2Loader.dll` |
| 示例应用启动 | ✅ 窗口创建、环境与控制器就绪、HTML 导航 `hr=0x0` |
| 脚手架 CLI 构建与自检 | ✅ `cjpm build success`；`cj-tauri info` 正确解析框架 / 项目 / stdx / SDK / cjpm / 桥 |
| `cj-tauri create` 生成工程 | ✅ 6 个文件，`cjpm.toml` 的路径转义、mingw 链接段、stdx 段均正确 |
| 新工程 `cj-tauri build` | ✅ 产出 `target/release/bin/main.exe` |
| 新工程 `cj-tauri run` | ✅ 窗口显示，JS ↔ 原生双向通信（62 / 48 字节，`ExecuteScript hr=0x0`） |

**Windows / WebView2（2026-10-01，0.3.0：窗口配置化 + 能力自动加载 + devtools 开关）**

| 验证项 | 结果 |
|---|---|
| 能力清单自动加载 | ✅ 框架 stderr：`[cj-tauri] 已自动加载 capabilities/：1 个清单` |
| 窗口配置生效 | ✅ 桥 stderr：`[cj-bridge] set window: title=cj-tauri hello size=1000x700`，OS 枚举到该标题的窗口 |
| 开发者工具开关 | ✅ 前端 `invoke('system:devtools')` 成功，OS 枚举到独立的 `[DevTools - about:blank]` 窗口 |
| `system:version` 平台字段 | ✅ `{"name":"cj-tauri","version":"0.3.0","cangjie":"1.0.5","platform":"windows"}`（此前写死 `linux`） |
| 能力管控未回退 | ✅ `greet` 正常 / `system:rm` 被拒 / 未注册命令被拒；示例自检 `[verify] ALL DONE`，FAIL=0，无 panic |

## 11. 仓库与推送（双托管）

同一份代码托管在两个地方，**一次 `git push` 会同时推送到两个远端**（`origin` 上挂了两条 pushurl，
fetch 仍只走 AtomGit）：

| 远端 | 地址 | 说明 |
|---|---|---|
| AtomGit | <https://atomgit.com/qq8864/cj-tauri.git> | 主仓，`origin` 的 fetch 源 |
| GitHub | <https://github.com/yangyongzhen/cj-tauri.git> | 同步备份，走 SSH |

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git        # AtomGit（国内直连推荐）
git clone git@github.com:yangyongzhen/cj-tauri.git       # GitHub（需已配置 SSH 密钥）

git remote -v                 # 会看到 origin 的两个 push 地址
git push                      # 一次推送 → AtomGit + GitHub 各推一次
git ls-remote origin main     # 核对两个仓的 commit SHA 是否一致
git ls-remote github main
```

> 维护者本机的 GitHub 推送使用专用密钥 `~/.ssh/id_ed25519_yangyongzhen`，经 `~/.ssh/config` 的
> `Host github-yangyongzhen` 别名（`IdentityFile` + `IdentitiesOnly yes`）与其它账号的 `id_rsa` 隔离。
> 你在自己机器上克隆时用常规的 `git@github.com:yangyongzhen/cj-tauri.git`，把本机公钥加到 GitHub 账号即可。

## 12. 该从哪读起

| 文档 | 适合什么时候读 |
|---|---|
| 本文 | 第一次接触：这是什么、怎么跑起来、怎么加功能 |
| [使用文档.md](使用文档.md) | 查具体命令参数、双平台陷阱速查（本文的详细版） |
| [技术方案.md](技术方案.md) | 想知道架构为什么这么选、可行性如何论证 |
| [踩坑与实施记录.md](踩坑与实施记录.md) | 要改宿主层/桥时——先看别人踩过什么 |
| [仓颉资源地址.md](仓颉资源地址.md) | 找仓颉 SDK、语言文档、技能包地址 |
| [../README.md](../README.md) | 仓库首页速览（架构图、目录树、验证表） |

## 13. 结语与下一步

现在的 cj-tauri 已经是一个**能用的最小框架**：双平台 WebView 宿主、双向 IPC、能力安全模型、
窗口与开发者工具可配置、能力清单自动加载，仓颉原生脚手架 CLI，外加一套把环境坑写清楚的文档。
你可以用它直接开一个仓颉桌面应用，后端逻辑用仓颉写、界面用熟悉的 Web 技术写，
改动只在 `ui/index.html` 与 `src/main.cj` 两个文件附近。

后续路线：

- **P1（0.3.0 已完成）**：capability 文件自动加载、窗口配置化（标题/尺寸）、devtools 开关；
- **P2**：鸿蒙 ArkWeb 后端（`host_harmony.cj`，需 DevEco + 真机）、窗口图标、macOS WebView；
- **P3**：前端框架模板（React/Vue）、插件体系。

想参与或反馈，直接在仓库提 issue / PR 即可——两个远端都在，代码同步推送。
