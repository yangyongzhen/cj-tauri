# 用仓颉写桌面应用：一个类 Tauri 框架的实现与使用

仓颉没有官方的桌面 WebView 绑定，想拿它写带界面的桌面程序，眼下只有两条路：自己用 FFI 去接系统 WebView，或者干脆不写桌面。这个项目选了前者，做法基本照搬 Tauri——界面还是 HTML/CSS/JS，渲染交给系统自带的 WebView，后端换成仓颉，中间用一条 JSON 的 IPC 通道连起来。

目前它在 Linux（WebKitGTK）和 Windows（WebView2）上都能跑：窗口出得来、双向通信通、权限校验拦得住。下面说清楚它是什么、怎么用，以及我在两个平台上分别踩了什么坑。

## 为什么不干脆用 Electron

Electron 的问题不是难用，是代价重。每个应用都要打包一份 Chromium，安装包上百兆，空载内存也下不来。

而桌面系统本来就带着 WebView——Windows 有 WebView2，Linux 有 WebKitGTK，macOS 有 WKWebView。界面完全可以让它们去渲染，安装包降到几兆。Tauri 证明了这条路走得通，而且顺手解决了一个更棘手的问题：前端能调到哪些后端能力，不该由前端自己说了算。它用一份 capabilities 白名单把这件事变成了显式声明，默认什么都不给。

把同样的架构换到仓颉上，还有一层考虑。仓颉是静态编译的，不带运行时，本身又是奔着 OpenHarmony 生态去的。一个今天能跑桌面、以后能落到鸿蒙上的「WebView 壳 + 仓颉后端」，比纯桌面框架更有余地。

代价是现成的东西几乎没有。仓颉既没有 WebView2 绑定，也没有 WebKitGTK 绑定，两块都得自己写 C 桥，再从仓颉侧用 FFI 调进来。

## 拆开来看是三个部分

**宿主。** 一个窗口加一个 WebView，负责渲染页和投递消息。Windows 这边用 Win32 建窗口、WebView2 渲染，消息循环留在宿主线程上；Linux 这边是 GTK + WebKitGTK，多一条额外约束，下面单独讲。

**IPC 桥。** 前端发出 `{cmd, args, id}` 形状的 JSON，宿主的原生回调接住，通过 FFI 交给仓颉。仓颉执行完把结果按 id 注入回页面，resolve 掉对应的 Promise。反向也走同一条路：仓颉 `ipc.emit()` 推事件，宿主投递到页面，前端 `listen` 的回调被触发。整条链路两平台共用，`ipc_hub`、`capability`、内置命令都是纯仓颉，一行平台分支都没有，平台差异只存在于宿主层和对应的 C 桥里。

**能力模型。** 每个命令、每个事件都要在 `capabilities/default.json` 里写过才放行。没声明的命令会被直接拒掉，返回 `command not allowed: xxx`，压根进不到业务代码。

一次 `invoke("greet", { name: "仓颉" })` 的完整往返，压缩成图大概是这样：

```
前端  window.__CJ_TAURI__.invoke('greet', {...})
  │   {cmd, args, id} 的 JSON
  ▼
宿主  postMessage / script message  ──FFI──▶  IpcHub
                                                │
                                    capability 校验（不通过就直接拒）
                                                │
                                    注册的 CommandHandler.handle()
                                                │
  ExecuteScript 注入结果 ◀──────────────────────┘
  │
  ▼
前端  Promise resolve
```

接口形态是刻意贴着 Tauri 做的：`invoke` / `emit` / `listen` 一套，capabilities 一份 JSON 的结构也一样。写过 Tauri 的人换过来基本不用重新学。

## 在 Windows 上把它跑起来

先凑齐三样东西，缺一样都跑不动。

仓颉 SDK（我用的 1.2.0）。光装好还不够，`runtime\lib\windows_x86_64_cjnative`、`bin`、`tools\bin`、`tools\lib` 这四个目录得在 PATH 里。少一个的症状特别迷惑：`cjpm build` 直接返回 127，一点输出都没有，很容易怀疑是 cjpm 装坏了。真因往往只是 PATH 不全——而且不用一个个补，把 `CANGJIE_HOME` 指到 SDK 根目录就行，cj-tauri 的启动器会自己补齐剩下的。

stdx 扩展库。JSON 走的是它（标准库目前还没有 `std.json`），`CANGJIE_STDX` 指到 `...\windows_x86_64_cjnative\dynamic\stdx`。

WebView2 有点绕。Win11 自带 Runtime，但编译 C 桥还需要单独的 WebView2 SDK，而且 SDK 版本不能高于机器上的 Runtime。我本机是 Runtime 122.0.2365.106，配 SDK 1.0.2365.46；SDK 版本一高，桥照样能编过，运行时初始化直接失败，排查起来是另一条冤枉路。

凑齐之后就是三步：

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git

/path/to/cj-tauri/cli/cj-tauri.sh create myapp   # 生成 src/、ui/、capabilities/、cjpm.toml
cd myapp
/path/to/cj-tauri/cli/cj-tauri.sh info           # 自检：框架、项目、stdx、SDK、cjpm、C 桥都解析到了吗
/path/to/cj-tauri/cli/cj-tauri.sh dev            # 编 C 桥 → cjpm build → 起窗口
```

Windows cmd 下把启动器换成 `cli\cj-tauri.bat` 即可，命令和参数完全一样。CLI 本体也是仓颉写的，首次运行会自己先 build 一遍，产物落在 `cli/target/release/bin/main.exe`。

`dev` / `build` / `run` 这三个命令实际上帮你做掉了一件事：把「C 桥 + stdx + 仓颉运行时」这几个动态库目录塞进子进程的搜索路径（Linux 是 `LD_LIBRARY_PATH`，Windows 是 `PATH`）。手动构建时这步得自己来，少一个不是 127 就是「找不到 libcjtbridge.dll」。

跑起来该看到的是一个深色卡片界面：输入名字点按钮，仓颉返回 `Hello, <名字>! 来自仓颉后端`；点一下定时器按钮，后端每秒推一个 tick 事件，页面底部的数字自己往上跳。输入框那一栏是空的也没关系，`greet` 的参数取不到时会用 `world` 兜底。

Git Bash 用户还有一条要记着：PATH 里如果写成 `D:/Program Files (x86)/Cangjie/bin` 这种盘符形式，MSYS 会把这条改坏，原生进程起不来，症状还是 127、无输出。要么自己写 POSIX 形式 `/d/...`，要么干脆用启动器——它内置了这个转换。

## 一个命令为什么要注册两次

模板生成的 `src/main.cj` 只有两个命令，加起来六十多行。要看懂它，先看一个命令长什么样：

```cangjie
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
```

然后在 `main` 里装配：

```cangjie
let app = TauriApp()
    .register("greet", GreetCommand())
    .register("timer", TimerCommand())
    .addCapabilityJson(capJson)
```

如果到这里就收工，新加的命令前端调不通——`command not allowed: xxx`。因为它还得写进 `capabilities/default.json`：

```json
{
  "identifier": "default",
  "windows": ["main"],
  "commands": ["greet", "timer", "system:version", "system:ping", "system:echo"],
  "events": ["tick"]
}
```

这看起来有点多余：都在同一个仓库里，注册过了凭什么不让调？但命令正是暴露给页面的攻击面，而页面里跑的东西不一定都是你写的——加载一个远端 UI、一次 XSS、一个被别人换掉的构建产物，都可能让任意脚本拿到这套 API。`commands` 这份白名单写在后端代码里，页面改不了它。默认拒绝的意思是：忘记声明最多让功能不工作，不会让一个没打算暴露的能力悄悄开放。

至于页面本身，它也不是宿主自己去加载的，而是后端读进来交给宿主：

```cangjie
let html = String.fromUtf8(File.readFrom("ui/index.html"))
app.run(html)
```

好处是换前端不用碰后端逻辑，改 `ui/index.html` 即可；前端如果是构建产物，把产物拷进 `ui/` 也一样。要注意应用以项目根目录为工作目录，`capabilities/` 和 `ui/` 都按相对路径读，换个目录启动就找不到了。

## 两个平台，各有一个必须先搞明白的约束

两个平台的宿主是分开写的，各自卡住过一次，而且两次的现象都把人往错误的方向带。

Windows 那边的现象是：窗口出来了，页面一片空白，导航完成事件不触发，`ExecuteScript` 稳定返回 `0x8007139F`（E_ILLEGAL_METHOD_CALL）。这个错误码的字面意思是「方法调用的时机不对」，顺着它想，很容易去怀疑线程模型或者 COM 初始化，但都不是。

真因在回调的生命周期上。WebView2 的环境和控制器是异步回调传进来的，如果只是把指针存下来，回调返回之后没人持有这两个对象，引用计数归零就被释放，WebView2 随即把浏览器进程关掉——窗口空白，随后所有调用都返回那个似是而非的错误码。修法很朴素：在回调里对环境和控制器都 `AddRef`，自己持有一份，直到退出再释放，改完 `hr=0x0`。

这段逻辑现在在 `native/bridge_win.c` 里，动桥的时候别把那几个 `AddRef` 删掉。同一处还有个小顺序问题：先 `ShowWindow` 再 `put_Bounds`，反过来的话首帧尺寸是 0，页面照样是白的。

Linux 那边是直接 abort，更难查。GTK 和 WebKit 的调用只能在主线程上，但这里说的「主线程」跟仓颉侧的主线程不是一回事：仓颉 `cjnative` 的 `main` 跑在 M:N 轻量线程的堆上协程栈里，WebKit 的 JSC 在调用边界会用 pthread 的栈边界校验栈指针，两者对不上，进程直接挂。所以桥把 GTK/WebKit 的调用全部搬进 C 桥自己创建的 pthread，仓颉侧只通过 FFI 调进去，回调再用 `CFunc` 回到仓颉。`bridge_linux.c` 里那些线程调度不是过度设计，是只能这么写。

跨平台框架真正麻烦的地方通常不是「两边各写一遍」，而是这种同一个概念在两边不是一回事的地方——主线程、所有权、生命周期，语义边界对不齐。

## 说点实话

跑通的功能都是实测出来的：Linux 侧 invoke 往返、内置命令、越权被拒、事件推送（连续收到 11 条以上）、页面真实渲染；Windows 侧窗口创建与导航 `hr=0x0`、双向消息 62 / 48 字节、脚本注入 `hr=0x0`，以及脚手架从 `create` 到 `run` 的完整流程。

但离 Tauri 那种成熟度还差得远，现在的短板挺具体：

- 窗口只有一个，尺寸和标题写在桥里，没有配置项；
- devtools 没有开关，调前端目前只能靠页面里打日志；
- `capabilities/` 是应用自己读文件后传给框架的，还没做到像 Tauri 那样自动扫描目录；
- macOS 没实现，鸿蒙只留了位置——前端接口按 ArkWeb 的可能性设计过，但宿主一行没写；
- 前端框架模板、插件体系都还没有。

所以路线也大致定了：先把 capability 自动加载、窗口配置化、devtools 开关这些「用起来顺手」的事补上，再去做鸿蒙的 ArkWeb 宿主，前端模板和插件体系放最后。

## 想上手看看

仓库托管在 AtomGit 和 GitHub 两边，一次 push 同时推两个远端，代码是同步的：

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git
```

`docs/` 里按需阅读的顺序是：[使用文档.md](使用文档.md) 查命令参数和平台陷阱速查，[技术方案.md](技术方案.md) 讲架构为什么这么选，[踩坑与实施记录.md](踩坑与实施记录.md) 就是上面那两个坑的完整记录（含错误码和排查过程）。读完再回头看 `examples/hello`，基本就能自己加命令了。
