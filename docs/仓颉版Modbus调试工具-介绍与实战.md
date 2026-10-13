# 用仓颉写一个比 Modbus Poll 更好用的 Modbus 调试工具——兼谈 cj-tauri 脚手架实战

> 2026-10-11 · [yangyongzhen/cj-tauri](https://atomgit.com/qq8864/cj-tauri)（AtomGit，GitHub 同步镜像 yangyongzhen/cj-tauri）

做嵌入式 / 工控联调的人，大概率都用过 [Modbus Poll](https://modbustools.com/modbus_poll.html)——它确实是
Modbus 主站模拟器的事实标准。但用得越多，越觉得它那套 2000 年代的 MDI 界面在 2026 年有点难受了。
这篇文讲两件事：

1. **cj-tauri 脚手架怎么用**——5 分钟从零起一个「仓颉后端 + 系统 WebView」的桌面应用；
2. **用 cj-tauri 实现的 Modbus 调试工具**（`examples/modbus-poll`）——功能对标 Modbus Poll，
   并把它几个最难受的地方直接摁平了。

---

## 一、Modbus Poll 好用，但有几个多年的老毛病

先说公道话：协议覆盖全、稳定、文档好，这些是它值得付费的原因。但从日常联调视角，痛点也很实在：

| # | Modbus Poll 的痛点 | 具体表现 |
| --- | --- | --- |
| 1 | **一屏只能盯一组寄存器** | MDI 多窗口虽然能开多个，但每个窗口都是小表格，想同时盯「温度 + 电流 + 状态字 + 线圈」就要开四五个窗口来回切，屏幕稍小直接叠罗汉 |
| 2 | **窗口小、信息密度低** | 默认窗口尺寸很小，列宽、字号都不适合长时间盯屏；要么手动调半天 |
| 3 | **付费** | 下载免费、使用收费（$49.95 起），试用期有限制；生产环境随便一装就是一套授权 |
| 4 | **通信报文窗口要单独开** | 排协议问题时得再开一个 Communication 窗口，且与数据窗口割裂 |
| 5 | **数据记录要另配** | Data Logging 向导绕，导 Excel 要 OLE/自动化那套老接口 |
| 6 | **写操作零确认** | 双击单元格改值直接就发出去了，地址填错一下就是一次误写——现场设备可没有撤销键 |
| 7 | **Windows 专属** | Linux 上没有官方版本，信创/国产化环境直接出局 |
| 8 | **界面无法定制** | 深色模式、大字号、按需隐藏列，都没有 |

这些不是挑刺——每一条都来自真实的联调场景。cj-tauri 的 Modbus 工具就是照着这张清单逐条反着做的。

---

## 二、cj-tauri：仓颉版的 Tauri，脚手架 5 分钟起一个桌面应用

[cj-tauri](https://atomgit.com/qq8864/cj-tauri) 是**仓颉语言的 Tauri 2**：用华为仓颉语言实现的混合开发框架，
**仓颉后端（静态编译）+ 系统 WebView 前端（HTML/CSS/JS，零 Chromium 捆绑）**。三件套对标：
WebView 宿主（对应 tao/wry）、IPC 双向桥（invoke/resolve/event）、能力安全模型（capability 白名单）。

### 2.1 脚手架 CLI：create / dev / build / run / info

装好仓颉 SDK（1.0.5+，实测 1.2.0）后，`cli/` 下就是仓颉原生实现的脚手架 `cj-tauri`：

```bat
REM 创建工程：缺省用内联 HTML 的零 Node 模板，也可以 --template vue / --template react
cli\cj-tauri.bat create my-modbus-tool

REM 前端要 Vite 的话：dev 会接管 Vite dev server，后端经 CJ_TAURI_DEV_URL 热加载
cli\cj-tauri.bat dev

REM 构建 + 运行（在工程目录里）
cd my-modbus-tool && cjpm build
cli\cj-tauri.bat run

REM 看装配信息：插件清单、命令、权限（CLI 先过守卫再启动应用，不会真开窗口）
cli\cj-tauri.bat info --json
```

`create` 生成的工程已经把「能力清单 `capabilities/`、`ui/` 前端、cjpm 配置、GUI 子系统链接开关」
全部备好——尤其最后这个：Windows 下 mingw 默认按 console 子系统出产物，双击会弹 DOS 黑窗口，
脚手架生成时就写好了 `--subsystem=windows`，这类坑不用用户再踩一遍。

### 2.2 新增一条命令的「三处联动」

cj-tauri 的应用是「命令驱动」的：前端只经 `window.__CJ_TAURI__` 的 invoke，后端是仓颉的
`CommandHandler`。加一条命令三步：

```cangjie
// 1) 实现 CommandHandler（出错抛 CommandException，前端 catch 到的就是这句话）
class GreetCommand <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        return JsonString("hello, ${argString(args, "who", "modbus")}")
    }
}

// 2) 装配时注册
app.register("greet", GreetCommand())

// 3) capabilities/default.json 里声明（能力白名单，最小权限不破）
{ "commands": ["greet", ...] }
```

漏了第 3 步会得到 `command not allowed`，漏了第 2 步是 `command not registered`——
权限模型默认拒绝，这是框架级的安全底线（协议命令的参数校验也都在这一层做，系统边界不外包）。

Modbus 工具的全部能力就是十来条这样的命令：`mb:read` / `mb:write` / `mb:trace` / `mb:export` / `mb:import` / `mb:config`。

---

## 三、工具实战：一屏多组 + 报文监视 + 记录导出

完整源码在仓库的 [`examples/modbus-poll`](https://atomgit.com/qq8864/cj-tauri/tree/main/examples/modbus-poll)，
仓颉侧只用标准库（`std.net` 做 Modbus TCP 传输、框架 serial 桥做 RTU），前端零依赖零构建。

![Modbus Poll (cj-tauri) 效果图](../examples/modbus-poll/images/modbus-poll-main.png)

*双面板并行轮询真实从站，底部报文监视逐帧滚动 Tx/Rx 十六进制（相对时间戳 + 过滤 + 导出）*

### 3.1 一屏多组：把「窗口」摊平成「面板」

这是与 Modbus Poll 分歧最大的地方。原版的 MDI 是「一个窗口 = 一组定义」，我们的答案是
**一个面板 = 一组定义，面板自由加减铺满整个窗口**：

- 每个面板独立配置：从站 ID、功能码、地址、数量、扫描周期、显示格式；
- 网格自适应布局，1280 宽的窗口并排两组、最大化四组，盯「温度 + 电流 + 状态字」不用再切窗口；
- 多面板轮询同一设备时，后端**按 host:port 复用一条 TCP 连接**（连接池 + 互斥串行），不会像
  开多个 Modbus Poll 实例那样把设备打出一堆连接；
- 面板状态（定义、运行开关、别名、连接参数、字节序）全部存 localStorage，下次打开接着跑。

### 3.2 写操作：先确认，再下发

现场设备没有撤销键。这里所有写操作都过模态框：**回显从站 ID、地址、当前旧值**，确认后才发——
对应 Modbus Poll 的「双击直接写」，多了一道保险。写完立即重读一轮，回环肉眼可见。

支持的写手势：

- 双击寄存器 → FC06 单写（支持 0x 前缀十六进制）；
- 双击线圈 → FC05 取反（ON/OFF 预览）；
- Float32 / Int16 格式下双击 → 按显示类型输入，自动拆寄存器 FC16 对写；
- 「批量写」→ 整段编辑，留空的地址保持不变，**连续地址自动合并成最少帧数的 FC16**。

### 3.3 报文监视：常驻在底下，不用再开窗口

底部停靠面板实时滚动 Tx/Rx 十六进制（逐字节空格对齐，MBAP 头一眼可数），每帧带相对时间戳；
过滤框输入 `Rx`、`fc=3`、端口号实时筛选；一键导出文本到 `logs/`。后端是取走即清的环形缓冲，
监视请求本身不走主站——**看流量不会产生流量**。

### 3.4 数据记录与点位表

- 每面板「记录」开关按扫描周期采样（内存 10000 条上限），「导出CSV」生成 ISO 时间戳的表格文件，
  Excel/WPS 直接打开画趋势；
- 「导出/导入点位表」把面板定义 + 别名 + 连接参数整份存成 JSON——点位表从此可以进 git、可以跨机器、
  可以让同事直接用你调好的布局。

### 3.5 Modbus TCP + RTU 串口，双通道同一个契约

顶栏「模式」一键切换。TCP 与 RTU 各自实现同一个传输接口，命令层对类型无感：

- **Modbus TCP**：MBAP 编解码、连接复用、超时自动重连；
- **Modbus RTU**：CRC16 帧层（多项式 0xA001，标准向量 `123456789 → 0x4B37` 在自检里逐轮断言）、
  按功能码推算响应长度、串口句柄复用；串口路径白名单在框架 C 桥侧兜底。

异常码不再是干巴巴的数字：从站回 `02` 直接显示「ILLEGAL DATA ADDRESS（地址不存在）」。

### 3.6 内置从站：没有设备也能闭环

调试工具最难取证的是「没有设备」。这个工具自带一个 Modbus TCP 从站模拟器（`CJ_MB_SLAVE=1` 启动，
127.0.0.1:15020），`run.bat selfcheck` 一条命令跑完 18 项无人值守断言：读值逐项对、写后回读、
异常码、CRC 向量、导出/导入往返——**全绿才收工**。这也是「用框架写工具」的额外红利：
应用本身可以自检。

---

## 四、逐条对账：Modbus Poll 的痛点 vs 这个工具

| Modbus Poll 的痛点 | cj-tauri Modbus 工具的答案 |
| --- | --- |
| 一屏一组，多组开窗口叠罗汉 | 面板网格自由铺满，一屏任意多组，每组独立扫描周期 |
| 窗口小、信息密度低 | 现代布局自适应 + 深色主题 + 大字号表格，最大化即全屏监控墙 |
| 付费 | 开源（MIT），源码就在仓库里，随框架一起免费 |
| 报文窗口另开、与数据割裂 | 报文监视常驻底部停靠，随开随看，可过滤可导出 |
| 数据记录绕、导 Excel 靠 OLE | 记录开关一键采样，直接导 CSV（ISO 时间戳），无需任何向导 |
| 写操作零确认 | 所有写操作模态框确认 + 旧值回显，批量写还能「留空=不变」 |
| Windows 专属 | Windows（WebView2）与 Linux（WebKitGTK）双平台实机跑通，信创友好 |
| 界面无法定制 | 前端就是 HTML/CSS/JS——想加趋势图、改配色、接自己的面板，都是改几行网页的事 |
| 串口类功能码全都要 | TCP + RTU 双通道；诊断类功能码（08/11/17/22/23）作为后续路线 |

一句话：**Modbus Poll 是「装好就能用的商业工具」，这个是「功能对标、痛点反着做、还带完整源码的开源工具」**——
你甚至可以用它的源码当模板，把公司自己的上位机一小时之内搭出来。

---

## 五、上手 5 分钟

```bat
git clone https://atomgit.com/qq8864/cj-tauri.git
cd cj-tauri\examples\modbus-poll

REM 跑起来（默认面板自动开跑；改顶栏主机/端口指向你的设备）
run.bat

REM 没有设备？内置从站 + 18 项自检闭环
run.bat selfcheck
```

前置条件只有两样：仓颉 SDK（见仓库 README）与 `native\build_win.bat` 编译过的 C 桥。
Linux 侧 `bash scripts/test.sh` 同样能跑，WebKitGTK 实机验证过。

## 六、小结

用 cj-tauri 做垂直工具的体验可以浓缩成三句：

1. **脚手架管起程**：`create` 一条命令出工程，能力白名单、GUI 子系统、跨平台链接这些坑框架替你踩完；
2. **仓颉管协议**：静态编译、无 GC 抖动顾虑、标准库 `std.net` 足够写传输层——协议代码两百行，全程可审计；
3. **网页管界面**：多面板、报文监视、CSV 导出这些「交互密集」的部分，用网页做比原生控件快一个数量级。

仓库与工具源码（AtomGit）：[atomgit.com/qq8864/cj-tauri](https://atomgit.com/qq8864/cj-tauri) ·
问题与建议欢迎提 [issue](https://atomgit.com/qq8864/cj-tauri/issues)。
