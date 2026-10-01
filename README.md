# cj-tauri：仓颉版 Tauri

用华为仓颉语言实现的轻量混合开发框架——仿 Tauri（Rust 后端 + 系统 WebView 前端）架构：
**WebView 宿主 + IPC 双向桥 + 能力安全模型**。前端用任意 Web 技术，后端用仓颉静态编译。

> **使用指南：[docs/使用文档.md](docs/使用文档.md)**——环境准备 → 创建应用 → 开发 → 排障。
> 可行性论证见 `docs/技术方案.md`；开发过程踩坑与已验证成果见 `docs/踩坑与实施记录.md`。
>
> 仓库（双托管，一次 `git push` 同步推送两个远端）：
> **AtomGit** <https://atomgit.com/qq8864/cj-tauri> ｜ **GitHub** <https://github.com/yangyongzhen/cj-tauri>
>
> ```bash
> git clone https://atomgit.com/qq8864/cj-tauri.git          # AtomGit（国内直连推荐）
> git clone git@github.com:yangyongzhen/cj-tauri.git         # GitHub（需已配置 SSH 密钥）
> ```

## 运行效果

![cj-tauri hello 示例运行效果](docs/cj_tauri.png)

*示例应用：深色主题卡片 UI，输入名字点 greet 触发 invoke，底部实时显示仓颉后端推送的 tick 事件。*

## 架构（对标 Tauri 三件套）

```
前端 (HTML/CSS/JS)  ← window.__CJ_TAURI__.invoke/listen/emit（注入桥接 JS，对标 @tauri-apps/api）
        │  JSON over postMessage（Linux: WebKitUserContentManager script message；Windows: chrome.webview.postMessage）
        ▼
IPC 消息桥（src/ipc_hub.cj）← 命令注册/分发/校验（对标 tauri IPC）
        ▼
能力安全模型（src/capability.cj）← 命令/事件白名单，默认最小权限（对标 capability）
        ▼
内置命令（src/api_system.cj）：system:version / system:ping / system:echo
        ▼
WebView 宿主（src/host.cj 抽象 + 各平台实现）
   ├─ Linux: webkit2gtk-4.1（src/host_webkit.cj + native/bridge_linux.c，C 桥在原生 pthread 运行）
   ├─ Windows: WebView2（src/host_webview2.cj + native/bridge_win.c，Win32 消息循环在宿主线程）
   └─ 鸿蒙: ArkWeb（架构预留，条件编译位）
```

## 目录结构

```
cj-tauri/
├── cj-env.sh              # 仓颉 SDK 环境变量（Linux 用）
├── run_win.bat            # Windows 一键运行仓内示例（配好运行时/stdx/桥 DLL 的 PATH）
├── cjpm.toml              # 框架库（cjTauri，静态库）
├── src/                   # 框架核心（纯仓颉）
│   ├── ipc_message.cj     # IPC 协议模型（invoke/resolve/event）
│   ├── ipc_hub.cj         # 命令注册/分发/校验中心
│   ├── capability.cj      # 能力安全模型
│   ├── api_system.cj      # 内置系统命令
│   ├── host.cj            # WebViewHost 抽象接口
│   ├── host_webkit.cj     # Linux WebKit 宿主（FFI + C 桥）
│   ├── host_webview2.cj   # Windows WebView2 宿主（FFI + C 桥）
│   └── app.cj             # TauriApp 装配（对标 tauri::Builder）
├── native/
│   ├── bridge_linux.c     # Linux C 桥（GTK/WebKit 原生线程宿主）
│   ├── bridge_win.c       # Windows C 桥（Win32 窗口 + WebView2）
│   ├── build_win.bat      # Windows 桥构建（含 WebView2 SDK / x64 loader 同步）
│   ├── build_linux.sh     # Linux 桥构建
│   ├── test_host_win.c    # Windows 桥隔离测试宿主
│   └── webview2/          # 与本机 Runtime 同代的 WebView2Loader.dll（构建时同步，不入库）
├── examples/hello/        # 示例应用（greet + tick 事件 + 越权演示）
├── cli/                   # 脚手架 CLI（仓颉实现，跨平台）
│   ├── cj-tauri.sh        # Linux / macOS / Git Bash 启动器（首次运行自动构建 CLI）
│   ├── cj-tauri.bat       # Windows 启动器
│   ├── src/               # CLI 源码：resolve / scaffold / project / main
│   └── templates/app/     # 工程模板（占位符渲染，按宿主平台注入依赖与链接段）
└── docs/                  # 使用文档 + 技术方案 + 踩坑记录
```

> `cli/cj-tauri` 是早期 bash 版 CLI，功能已被 `cli/src` 的仓颉实现完全覆盖，保留仅作参考。

## 快速开始

前提（详见[使用文档](docs/使用文档.md#2-环境准备)）：

- **仓颉 SDK**（验证版本 1.2.0）+ **stdx**；
- PATH 需包含 SDK 的 `runtime/lib/<平台>`、`bin`、`tools/bin`、`tools/lib`（官方 `envsetup` 的布局），
  或只设 `CANGJIE_HOME` 交给 `cli/cj-tauri.sh` / `cli/cj-tauri.bat` 自动补齐；stdx 路径可用 `CANGJIE_STDX` 指定；
- Windows：mingw gcc + WebView2 Runtime（Win11 自带）+ WebView2 SDK（仅编译桥时需要）；
  Linux：`libwebkit2gtk-4.1-dev`、`libgtk-3-dev`。

### Windows 上跑起来（本机验证组合）

cjc 1.2.0 + WebView2 Runtime 122.0.2365.106 + WebView2 SDK 1.0.2365.46：

```bat
REM 只需指两个目录：SDK 根目录与 stdx；其余 PATH 由启动器按 envsetup 布局补齐
set "CANGJIE_HOME=D:\Program Files (x86)\Cangjie"
set "CANGJIE_STDX=D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"

cd /d E:\path\to\cj-tauri
cli\cj-tauri.bat info                 REM 先自检：框架/项目/stdx/SDK/cjpm/桥 是否都解析得到
cli\cj-tauri.bat create D:\temp\myapp
cd /d D:\temp\myapp
E:\path\to\cj-tauri\cli\cj-tauri.bat dev
```

> 启动器内置两个默认值，不设也能跑本机验证组合：`CANGJIE_HOME` 默认
> `D:\Program Files (x86)\Cangjie`；桥构建默认 WebView2 SDK `D:\webview2sdk\sdk-1.0.2365.46`
> （改 `native\build_win.bat` 顶部即可换版本）。

用脚手架建一个新应用（首次运行会自动构建 CLI 本体）：

```bash
# Linux / macOS / Git Bash
./cli/cj-tauri.sh create myapp
cd myapp
./cli/cj-tauri.sh dev        # 构建 C 桥 + cjpm build + 启动窗口
```

```bat
REM Windows cmd
cli\cj-tauri.bat create myapp
cd myapp
..\..\cli\cj-tauri.bat dev
```

`cj-tauri` 子命令：`create` / `dev` / `build` / `run` / `info` / `help`。
`dev`/`build`/`run` 会自动为子进程准备「桥（含 `native/webview2`）+ stdx + 仓颉运行时」的动态库搜索路径，
不必手工拼 `PATH` / `LD_LIBRARY_PATH`；`cj-tauri info` 可打印全部路径解析结果，排障先跑它。

### 运行仓内示例（不用脚手架）

Windows：
```bat
REM 1. 编译 C 桥（SDK 路径与版本要求见 native\build_win.bat 顶部）
native\build_win.bat

REM 2. 编译示例应用
cd examples\hello && cjpm build

REM 3. 运行（run_win.bat 已配好 Cangjie 运行时 / stdx / 桥 DLL 的 PATH）
run_win.bat
```

Linux：
```bash
# 1. 编译 C 桥
cd native && ./build_linux.sh && cd ..

# 2. 编译并运行示例应用（应用以项目根为工作目录）
cd examples/hello && cjpm build
LD_LIBRARY_PATH=../../native:$(stdx路径):$LD_LIBRARY_PATH ./target/release/bin/main
```

> Windows 注意：编译桥所用 WebView2 SDK 版本应与机器上的 WebView2 Runtime 版本兼容
> （SDK 不高于运行时；本机运行时 122.0.2365.106 对应 SDK 1.0.2365.46）。
> 运行时版本查询命令见 `native/build_win.bat` 注释。
>
> Git Bash 注意：往 `PATH` 里塞路径必须用 POSIX 形式（`/d/...`），写成 `D:/...` 会让依赖仓颉运行时
> DLL 的原生进程启动失败（退出码 127 且无输出）；`cli/cj-tauri.sh` 已内置该转换。

## 开发一个应用

```cangjie
import cjTauri.*
import stdx.encoding.json.*

// 1. 实现命令（对标 tauri command）
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
        return JsonString("Hello, ${name}!")
    }
}

main(): Int64 {
    // 2. 装配 + 注册 + 能力清单（对标 capabilities/*.json）
    let app = TauriApp()
        .register("greet", GreetCommand())
    app.addCapabilityJson(JsonValue.fromStr("""
        {"identifier":"default","windows":["main"],
         "commands":["greet","system:version"],
         "events":[]}"""))
    // 3. 启动（阻塞）
    app.run(html)
    return 0
}
```

前端侧：

```js
// 注入的桥：window.__CJ_TAURI__
const tauri = window.__CJ_TAURI__;
tauri.invoke('greet', { name: '仓颉' }).then(d => console.log(d));  // JS → 仓颉
tauri.listen('tick', p => console.log(p));                          // 仓颉 → JS 事件
```

## 能力安全模型

- 应用在 `capabilities/` 声明 `commands`/`events` 白名单；
- **未声明命令一律拒绝**（默认最小权限），返回 `command not allowed: xxx`；
- 未声明事件不投递到页面；
- 校验层独立于宿主实现，鸿蒙 ArkWeb 后端复用同一套。

## 关键技术点（务必阅读）

1. **仓颉 cjnative 的 main 运行在 M:N 轻量级线程的堆上协程栈**，
   JSC（WebKit 的 JS 引擎）的 `sanitizeStackForVM` 用 pthread 栈边界校验 SP 会 **abort**。
   → 解决方案：GTK/WebKit 全部调用必须在 **C 桥创建的原生 pthread** 内执行，
   仓颉侧经 FFI 调用，消息回调经 `CFunc` 回到仓颉。
2. 原生→JS 的脚本投递用 **FIFO 队列 + g_idle_add**，不能单槽位覆盖。
3. 仓颉迭代 String 得到的是 **UInt32 码点**（非 Rune），`Rune(cp)` 还原字符。
4. stdx 的 JSON（`JsonValue.fromStr`）是 1.0.5 的 JSON 方案，标准库无 `std.json`。
5. **Windows（WebView2）：回调里拿到的 `ICoreWebView2Environment` / `Controller` 必须自己 AddRef 持有**，
   否则回调返回后对象即被释放，WebView2 会立刻关掉浏览器进程——现象是窗口空白、导航完成事件不触发、
   `ExecuteScript` 返回 `0x8007139F`（E_ILLEGAL_METHOD_CALL）。

## 现状与路线

- ✅ MVP（Linux 桌面）：WebView 宿主 + IPC 双向 + capability + 内置命令 + 示例
- ✅ Windows 桌面：WebView2 后端（`src/host_webview2.cj` + `native/bridge_win.c`），IPC/capability 与 Linux 完全共用
- ✅ 脚手架 CLI（仓颉原生实现，`cli/`）：`create` / `dev` / `build` / `run` / `info`，Windows + Linux
  双平台启动器（`cli/cj-tauri.sh` / `cli/cj-tauri.bat`），首次运行自动构建 CLI 本体
- ✅ 使用文档：`docs/使用文档.md`
- 🔜 P1：capability 文件自动加载、窗口配置化、devtools 开关
- 🔜 P2：鸿蒙 ArkWeb 后端（`host_harmony.cj`，需 DevEco + 真机）、macOS WebView
- 🔜 P3：前端框架模板（React/Vue）、插件体系

## 验证结果

Linux（2026-08-21）：

| 验证项 | 结果 |
|---|---|
| `invoke("greet")` JS→仓颉→JS | ✅ `Hello, 仓颉! 来自仓颉后端` |
| 内置命令 `system:ping` | ✅ `pong` |
| capability 越权 `system:rm` | ✅ 拒绝 `command not allowed` |
| 未注册命令 `no_such_cmd` | ✅ 拒绝 |
| 事件推送 `tick`（仓颉→JS） | ✅ 11+ 条到达前端 |
| UI 真实渲染 | ✅ 截图确认（深色主题卡片 + 按钮） |

Windows / WebView2（2026-10-01，cjc 1.2.0 + Runtime 122.0.2365.106 + SDK 1.0.2365.46）：

| 验证项 | 结果 |
|---|---|
| C 桥构建 `native\build_win.bat` | ✅ `libcjtbridge.dll` + 同步 `webview2\WebView2Loader.dll` |
| 示例应用启动（WebView2） | ✅ 窗口创建、环境/控制器就绪、HTML 导航 `hr=0x0` |
| 脚手架 CLI 构建与自检 | ✅ `cjpm build success`；`cj-tauri info` 正确解析框架/项目/stdx/SDK/cjpm/桥 |
| `cj-tauri create` 生成工程 | ✅ 6 个文件，`cjpm.toml` 路径转义、mingw 链接段、stdx 段均正确 |
| 新工程 `cj-tauri build` | ✅ `target/release/bin/main.exe` |
| 新工程 `cj-tauri run` | ✅ 窗口显示，JS→原生双向通信（62/48 字节消息，`ExecuteScript hr=0x0`） |

## 仓库与推送

同一份代码双托管，**一次 `git push` 同时推送两个远端**——`origin` 挂了两条 pushurl，fetch 仍只走 AtomGit：

| 远端 | 地址 | 说明 |
|---|---|---|
| AtomGit | `https://atomgit.com/qq8864/cj-tauri.git` | 主仓，`origin` 的 fetch 源 |
| GitHub | `git@github.com:yangyongzhen/cj-tauri.git` | 同步备份，走 SSH |

```bash
git remote -v                 # origin 会列出两条 push 地址
git push                      # 一次推送 → AtomGit + GitHub 各推一次
git push github main          # 只想推 GitHub 时用命名远端
git ls-remote origin main     # 核对两个仓的 commit SHA 是否一致
git ls-remote github main
```

> **本机 GitHub 推送用的是专用密钥**：`~/.ssh/id_ed25519_yangyongzhen`，经 `~/.ssh/config` 的
> `Host github-yangyongzhen` 别名（`IdentityFile` + `IdentitiesOnly yes`）与其它账号的 `id_rsa` 隔离，
> 因此本仓 remote 写成 `git@github-yangyongzhen:yangyongzhen/cj-tauri.git`。换机器克隆时用常规
> `git@github.com:yangyongzhen/cj-tauri.git`，把该机公钥加到 GitHub 账号即可。
