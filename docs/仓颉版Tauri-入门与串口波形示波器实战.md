# 用仓颉写桌面应用：从 npx 建工程到串口实时示波器

上周把仓库里第 17 个示例收尾了——一个**串口实时波形示波器**：选好设备与波特率，点连接，样本流进来，页面上的波形立刻开始滚；它自己算速率、上穿次数和丢帧，跑完给自己一个结论。

这件事在浏览器里做不成。Web 平台至今没有通用的串口 API（Web Serial 只在部分 Chromium 内核里落地，还得用户每次点授权），而「采集到的东西实时变成波形」恰恰是串口类桌面工具最直观的门面形态。所以拿它当引子正合适：**这类应用正是混合桌面框架存在的理由**——界面交给 Web 技术，浏览器碰不到的那部分交给原生后端。

这篇文章分两半：前半说清 cj-tauri 是什么、怎么用 npm 在几分钟内起一个工程；后半用这个示波器，把「从零到实机取证」的闭环完整走一遍。

## cj-tauri 是什么

一句话：**仓颉语言的 Tauri**——前端是系统 WebView 里的 HTML/CSS/JS，后端是仓颉静态编译出的原生可执行文件，中间靠一套 IPC 协议和一张能力白名单连起来。

它没有捆绑 Chromium。Linux 用的是系统里的 WebKitGTK，Windows 用的是系统里的 WebView2（Win11 自带），所以产物是几 MB 级的 exe，跟动辄上百 MB 的 Electron 应用不是一个量级。

![cj-tauri 架构图：前端桥 → IPC 消息桥 → 能力安全模型 → 内置 / 插件命令 → WebView 宿主 → 共享 C 层](docs/images/architecture.png)

这张图从上往下就是一次 `invoke` 的完整路径，中间有三处最容易看错的地方，我在图上直接标了：

- **授权是在调用线程上同步拒绝的**。`invoke` 一个没注册或没放行的命令，当场就回错误（`command not registered` / `command not allowed`），不会先排进队列再说；
- **通过校验的命令才被扔到 worker 线程执行**。所以慢命令（跑子进程、开原生对话框）不会把窗口冻住；同一个命令被并发调用不保证执行顺序，前端按 promise id 配对自己的结果；
- **结果和事件是异步回投的**（图右侧那条虚线）。事件是后端主动推给页面的，走的是另一条路。

最底下那个 `native/core/bridge_core.c` 是跨平台共享层：桥接脚本的注入、报文解析、能力校验都在这儿，跟 GTK-free 的平台实现分开——平台差异只允许出现在仓颉侧的 `@When` 条件编译和 `native/platforms/<平台>/` 两处，上层代码一份。

平台状态我按实测说，不按计划说：

| 平台 | 状态 |
|---|---|
| Windows（WebView2） | **已实机跑通**：菜单栏、拖放、文本框/剪贴板这类宿主能力都有实机证据 |
| Linux（WebKitGTK） | **已实机跑通**，CI 与本机自检都在这个平台上跑 |
| 鸿蒙（ArkWeb） | **架构预留**：目录与导出契约在，能力位如实上报 0，没有实机验证过 |

仓库里现在有 17 个可直接运行的示例、8 个官方插件（文件、对话框、子进程、串口、键值存储、剪贴板、通知、菜单），加上三个脚手架模板。够撑起「工具类桌面应用」这一档的日常需求。

## 用 npm 起一个工程

真要说上手成本，最省事的是这一条：

```bash
npx cj-tauri create myapp     # 免安装，直接跑
cd myapp
npx cj-tauri dev              # 构建 + 起窗口；Vue/React 模板还会接管 Vite dev server
```

前置条件就三样：**仓颉 SDK**（1.0.5 以上，我用 1.2.0 验证）与配套的 **stdx**；Windows 侧另需 mingw gcc 和 WebView2 Runtime（Win11 自带）；Linux 侧需 `libwebkit2gtk-4.1-dev`、gcc 与 pkg-config。SDK 从仓颉官网下载（下载页需要登录华为账号），装好后把 `CANGJIE_HOME` 指向 SDK 根目录即可，剩下的环境变量拼装 CLI 会替你做。

`create` 出来的工程是这几个文件，跟「前端工程」的心智模型差别不大：

```
myapp/
├── cjpm.toml            # 仓颉包描述（名字、版本、依赖、链接选项）
├── capabilities/
│   └── default.json     # 能力清单：哪些命令/事件对页面放行
├── src/
│   └── main.cj          # 后端：注册命令、装配窗口、启动
└── ui/
    └── index.html       # 前端页面（零 Node 版本就是这一个文件）
```

模板里的 `main.cj` 不长，骨架就三件事——装配、注册、启动：

```cangjie
main(): Int64 {
    let app = TauriApp()
        .window(WindowConfig("cj-tauri 应用", 1000, 700))
        .register("greet", GreetCommand())      // 命令：页面 invoke("greet", {...})
        .register("timer", TimerCommand())      // 定时器：后端主动 emit("tick", ...)
        .plugin(MenuPlugin())                   // 插件：一行接入原生菜单栏
        .setMenu(demoMenu())                    // 菜单栏要在启动前定稿

    let html = String.fromUtf8(File.readFrom("ui/index.html"))
    app.run(html)                               // 阻塞到窗口关闭
    return 0
}
```

前端这一侧只有两个动词，`invoke` 和 `listen`：

```js
window.__CJ_TAURI__.invoke('greet', { name: '仓颉' }).then(d => console.log(d));
window.__CJ_TAURI__.listen('tick', p => console.log(p.n));   // 后端每秒推一次
```

这里有个**新手最容易踩的点**：桥不是页面自己加载的，是宿主在页面脚本之前注入的。所以页面里不要一上来就在模块顶层读 `window.__CJ_TAURI__`，等它出现再用（模板里那个 `waitForBridge` 就是干这个的，示波器页面也一样）：

```js
function waitForBridge(cb) {
  if (window.__CJ_TAURI__ && window.__CJ_TAURI__.serial) { cb(); return; }
  setTimeout(function () { waitForBridge(cb); }, 25);
}
```

### npm 这个包装里到底做了什么

`npx` 免安装是真的，但**仓颉 SDK 是硬前置**——应用的后端就是仓颉代码，没有 SDK 连编译都做不了。所以 npm 包里的入口脚本（`bin/cj-tauri.js`）干的主要是环境这件事，按三级顺序找 CLI 本体：

1. **包内预编译**（`prebuilt/<平台-架构>/cj-tauri`）——打 tarball 的机器上有产物就带上，这一档用户什么都不用装，除了 SDK；
2. **本机缓存**（`~/.cache/cj-tauri/<版本>/<平台-架构>/`）——第一次构建过就复用；
3. **源码构建**——把包里的 `cli/` 拷到缓存目录再 `cjpm build`。产物刻意不写进包的安装目录，因为全局安装的 node_modules 可能只读。

顺带把 PATH / `LD_LIBRARY_PATH` 拼好（Linux 上仓颉运行时的动态库不查 PATH，少了 `LD_LIBRARY_PATH` 会以「找不到 `libcangjie-runtime.so`」直接退出），再把退出码原样传回来。

没装 SDK 的时候它不会甩你一句 `cjpm: command not found`，而是告诉你缺什么、`CANGJIE_HOME` 该怎么设、去哪看安装说明。有意思的是 `npx cj-tauri --version` 在**没装 SDK** 的机器上也照样能打出 0.8.0——版本号直接读 `package.json`，不经过仓颉侧。

如果你连 SDK 都不想装，还有一条旁路：仓库随版本分发**免安装、免 SDK 的单文件 exe**（比如 Modbus 调试工具 5.6 MB、观影应用 9.5 MB）。这四个产物我逐个量过：PE 导入表里只有 Windows 系统 DLL，没有任何第三方运行时。口径与复核方式都写在 `docs/分发形态实测.md` 里，有兴趣可以自己跑一遍。

### 第一件事先跑 doctor

新机器上我会建议先跑这个：

```bash
npx cj-tauri doctor
```

它逐行给结论，每一条都自带「缺了怎么办」——框架版本、工程产物、stdx、SDK、`cjpm`、C 桥，谁没解析到都在这一屏里。另一条自检命令是 `npx cj-tauri info --json`，它输出机器可读的插件装配清单，用起来更像给 CI 的接口。

## 实战：串口实时波形示波器

`examples/serial-waveform`。先说为什么值得再做一个串口示例：仓库里已经有一个串口调试助手（收发日志）和一个 Modbus 调试工具（轮询取值），可这两个页面**一行 canvas 都没有**——它们都是文本工具。「采集到的东西实时变成波形」这一档是空白，而它恰好是串口类桌面应用最直观的门面：一眼看懂，且浏览器打不开串口，这是纯 Web 技术碰不到的活。

### 后端：接入插件是一行

后端就干三件事——接插件、注册两个命令、把页面读进来交给 `run()`：

```cangjie
main(): Int64 {
    let app = TauriApp()
        .window(WindowConfig("串口实时波形 · cj-tauri", 1180, 760))
        .plugin(SerialPlugin())                  // 串口能力：一行接入
        .register("report", ReportCommand())     // 页面把每行诊断回投到 stderr
    app.register("quit", QuitCommand(app))       // 要引用 app 本身，所以没串在链上

    let html = loadUi()                          // 读 ui/index.html
    app.run(html)
    return 0
}
```

`ReportCommand` 那 15 行不是凑数的：**诊断一律走 stderr**（仓颉 `println` 的 stdout 有缓冲，进程被强杀时日志会丢），自动化脚本要抓的「页面自评」就是从这儿取证的。`QuitCommand` 则让探针跑完一轮能自己退掉，脚本不用靠 `kill` 收尾。

### 权限：插件只声明「我提供什么」

能力清单就一行：

```json
{ "commands": ["report", "quit", "system:version"], "permissions": ["serial:default"] }
```

`serial:default` 是个**命名权限集**，一次放行 `open` / `read` / `write` / `close` 四条命令。这里没用更保守的 `serial:readonly`——示波器要先给设备发 `SCAN` 让它开始吐样本（写），再连续读，只读不够用。

三条规矩值得记住：

1. 插件**只声明「我提供什么」，不自动放行**。清单里不写 `serial:default`，页面调 `serial.open` 就是 `command not allowed`；
2. 命令放行 ≠ 参数放行。设备路径最终要过白名单，这个校验在 **C 桥 core** 里，不在页面；
3. 命名集和逐条写命令名是同权的，混用也没问题——`report` / `quit` 是应用自己的命令，就直接写明文。

### 协议：真实仪器里最常见的那种

设备侧只认三个报文：

| 方向 | 报文 | 说明 |
|---|---|---|
| 应用 → 设备 | `SCAN\n` | 开始连续输出 |
| 应用 → 设备 | `STOP\n` | 暂停 |
| 设备 → 应用 | `<序号>,<值>\n` | 值域 -1.0..1.0，序号用来算丢帧 |

页面**不预设设备型号**，换真实传感器只要改解析函数。读法也不是一次长阻塞读——`serial:read` 单次上限 4096 字节、`timeoutMs` 到期就返回空，页面用一个短读循环拿数据、再按行拼：

```js
function ser() { return window.__CJ_TAURI__.serial; }

var binFrames = 0;                  // 只有 hex、没有 text 的帧数（二进制设备流：如实计数，不硬解析）

function readOnce() {
  if (handle === 0) { return; }
  ser().read({ handle: handle, maxBytes: 4096, timeoutMs: 120 }).then(function (r) {
    if (r.count > 0) {
      if (r.text !== undefined && r.text !== null) { parseChunk(r.text); }
      else { binFrames++; }
    }
    if (handle !== 0) { setTimeout(readOnce, 0); }
  }).catch(function (e) {
    report('[wave] serial:read FAIL => ' + e.message);
    setHint('读取出错：' + e.message);
    disconnect('读取失败');
  });
}
```

这个循环的形状是被 IPC 契约逼出来的：命令跑在 worker 线程上、本身不流式，所以「一直读」只能在页面侧用短读循环表达，而这也顺带让「设备不出数」不会把页面卡住（`timeoutMs` 到期返回空，循环接着下一轮）。另外，**切在半行上的残行要留着等下一帧补齐**——这是串口解析最容易错的地方，`parseChunk` 里那个 `rxText` 就是干这个的。

### 页面：canvas 自绘，指标自己算

`ui/index.html` 是独立文件，不是内联进 `"""` 字符串——这一页有 canvas 绘制、控制面板和统计，内联会踩两个坑：三引号字符串会先吃掉 JS 的反斜杠转义；`${...}` 又和 JS 模板字面量同形。独立文件后两个坑都不存在。

界面上该有的都有：设备路径、波特率、量程（自动/±1/±2/±5/±10）、显示点数（500–3000）、触发（自动/正常/单次 + 电平 + 上升/下降沿），底下是 canvas 波形区，再底下一行统计：状态、样本数、速率、最新/最小/最大/均值、滚动丢弃、帧率、画布尺寸。

这里有个我刻意做的选择：**指标全部由页面自己算，不看对端脸色**。速率是按收到样本的时间戳算出来的，不是抄对端报的「我按 400 Hz 发」；丢帧是靠报文里的序号连不连续判断的；上穿次数是直接在样本序列上数的。对端说自己健康没有意义，**页面自己收到的样子才算数**。

### 探针：让窗口自己跑一轮自检

图形应用的自动化测试一直被当成麻烦事，我的办法是把「配置」塞进页面、把「结论」打到 stderr：

```bash
CJ_SERIAL_PROBE_PATH=/dev/pts/3 CJ_SERIAL_PROBE_MS=2500 ./target/release/bin/main
```

给了设备路径之后，后端就把探针配置经 **document-start 预执行脚本**注入页面（早于页面脚本执行，所以页面一启动就看得见）：

```cangjie
let js = "window.__WAVE_PROBE__ = { path: " + JsonString(probePath).toJsonString() +
    ", baud: " + JsonString(baud).toJsonString() +
    ", ms: " + JsonString(ms).toJsonString() +
    ", quit: " + JsonString(quit).toJsonString() + " };\n"
host.addInitScript(js)
```

字面量特意用 JSON 编码器拼，而不是手写字符串——Windows 的设备路径长这样 `\\.\COM3`，反斜杠交给编码器转义，人不用管。

页面侧拿到 `window.__WAVE_PROBE__` 就自动跑一轮：连接 → 发 `SCAN` → 收 N 毫秒 → 打形状结论与统计 → （默认）自退。环境变量一共四个：`CJ_SERIAL_PROBE_PATH` / `_BAUD`（默认 115200）/ `_MS`（默认 2500）/ `_QUIT`（默认 1）。失败也会照打结论行——**自动化脚本不该因为「没打日志」而空等到超时**。

## 实机跑一轮，数据长这样

下面这些数字是 Linux 实机上量出来的（Xvfb 显示 + 对端按 400 Hz 出样本），不是我写在文档里的目标值：

| 指标 | 实测 | 它证明什么 |
|---|---|---|
| 速率 | **404.2 /s** | 对端按 400 Hz 出样本，速率是页面按自己收到的时间戳算的 |
| 上穿次数 | 8 | 正弦过零 8 次，与画出来的波形对得上 |
| 丢帧 | 0 | 报文序号连续，短读循环没丢样本 |
| 判定 | `verdict=ok` | 速率在容差内且无丢帧（页面自评，探针据此退出） |
| 规模 | 样本 2002 / 画布 1148x566 | 画布尺寸与视口一致（布局问题另有截图人眼验） |

![串口实时波形示波器（serial-waveform）实机运行](docs/images/example-serial-waveform.png)

**只信页面自己报的数还不够**，所以还有一条进程外证据：应用发出的 `SCAN` 必须出现在**对端落盘的文件**里（对端起在自己指的文件上）。「页面说它写了」证明不了它真写到了线路上，这条由 E2E 入口断言。

在示例目录里一条命令就能复跑整轮：

```bash
cd examples/serial-waveform
bash run.sh          # pty 对端 + 应用 + 探针自检，跑完打印结论
```

它是转发到仓内 E2E 入口（`scripts/e2e/test-linux-serial-waveform.sh`）的，10 条断言全绿；汇总跑 `bash scripts/e2e/run-all.sh` 是**通过 2 / 跳过 0 / 失败 0**，证据 JSON 落在 `dist/e2e-evidence/linux-linux-serial-waveform.json`。口径、断言和证据都在 E2E 那边维护——示例目录不另立一份标准，这点我刻意坚持，否则实测数据会慢慢变成两套互相打架的版本。

## 没有真设备也能跑

串口示例最烦的就是「没设备怎么试」。这里用 python3 的 `pty` 造一对内核虚拟串口，**不需要 socat**（本机没装也照样跑），对端脚本还负责按 400 Hz 吐正弦样本、并把收到的字节落盘：

```bash
python3 serial-wave-peer.py --write-rx /tmp/wave-rx.bin    # 它会打印自己用的 /dev/pts/N
./target/release/bin/main                                   # 窗口里填 /dev/pts/N → 连接
```

想省手，就设 `CJ_SERIAL_PROBE_PATH` 走探针模式，连接、发指令、收样本、打统计、退出全自动。

## 几个我自己踩过的坑

写这篇文章的时候顺手把踩过的坑也交代一下，都是真疼过的：

- **三引号字符串会先吃掉 JS 的反斜杠**。最初把整个页面内联进 `"""` 字符串，里面的 `\n` 被仓颉先转义成真换行，把 JS 字符串和单行注释拆断——整段 `<script>` 语法错误，**页面里一行都不执行，而 stderr 毫无提示**。所以这个示例的页面是独立文件。
- **桥必须在 document-start 注入**。Linux 侧用「文档末尾注入」时，会晚于发行态单文件里内联的 `<script type="module">`，页面读 `window.__CJ_TAURI__` 拿到 `undefined`。现在两个平台都对齐到「页面脚本执行前」，但前端仍然要 `waitForBridge`。
- **自检全绿不等于界面没问题**。布局缺陷只能抓图人眼看：有个示例的三栏 flex 里标题默认参与收缩，中间一栏一窄就把「热门歌曲」折成「热门歌 / 曲」——那一轮 10 条页面自检断言全绿。所以本文这套证据里，截图和数据是并列的，不是谁替代谁。
- **统计体积要按真实路径去重**。我量分发产物时，`/lib` 和 `/usr/lib` 下同一份 `libssl.so.3` 被算了两遍，报出来 12.0 MB，实际 6.0 MB；另外「按名字 `LoadLibrary`／`dlopen` 加载」的组件压根不在导入表里，统计脚本看不见它们。

这些坑都沉淀在仓库的 `AGENTS.md` §4 和 skills 里了，新同学改代码前看那一节能省不少时间。

## 边界，如实说

- **串口的 Windows 侧还没有实机证据**。桥里有对应实现（`cj_bridge_serial_list` 走 `QueryDosDeviceW` 扫 MS-DOS 设备名），但没在 Windows 机器上跑过，所以我不说「Windows 也能跑通」——Linux 侧才有上表中那份证据；
- **鸿蒙是架构预留**：目录、契约 README、导出命名都留好了，能力位如实上报 0，没实机验证过；
- **托盘不做**：Linux 侧要依赖 `libayatana-appindicator3`，这个三方库我暂时不想让框架背，所以直接标为暂缓而不是「计划中」；
- **这个示波器是入门形态**：只画滚动窗口内的样本，没有缩放、游标、FFT；要当分析仪用，得自己接着写；
- **它还没接单文件打包**：缺两个资源存根文件，所以暂时不产 `serial-waveform.exe`。

我把这些写出来不是自曝其短，而是**「自检全绿」和「实机跑通」是两件事**——一个框架如果连自己没验过的平台都说支持，那它的支持列表就没有信息量了。

## 上手值不值

如果你要做的是**工具类桌面应用**——串口/CAN 调试、Modbus 之类的协议工具、本地数据查看器、播放器、给孩子做的练习软件——而你又不想背 Chromium 的体积和内存，cj-tauri 这条路值得看一眼：后端静态编译、产物几 MB、原生能力（串口、子进程、剪贴板、通知、原生菜单、文件拖放）都是现成插件，权限由清单统一收口。

不适合的场景我也列一下：要打包移动端（没做）、重度依赖完整 Web API 生态（系统 WebView 的差异仍在，尤其 Linux 的 WebKitGTK 有自己的脾气）、要常驻托盘的（暂缓）。

- 仓库（AtomGit）：`https://atomgit.com/qq8864/cj-tauri`，MIT 许可，当前版本 **0.8.0**
- npm：`https://www.npmjs.com/package/cj-tauri`，`npx cj-tauri create myapp` 即可起步
- 上手先读 `docs/使用文档.md`，排障看 `AGENTS.md` §4 的踩坑清单，示例逐个跑 `examples/<名字>/README.md`

17 个示例里我最推荐按这个顺序往下走：`hello`（最小闭环）→ `todo_check`（命令 + 事件 + 能力清单）→ `plugin-serial`（插件与权限对照）→ `serial-waveform`（本文这个）→ `modbus-poll`（真项目形态）。走完这五个，框架该会的你基本都会了。
