# 我用仓颉写了个桌面版力扣：从判题机到 100 道题

> 这篇文章记录 `examples/leetcode-gui` 这个示例的完整来路——它为什么存在、判题到底是怎么跑起来的、题库怎么从 19 题涨到 100 题、以及我在真机上被哪些坑绊过。不是 API 手册，想看命令清单可以直接翻同目录的 `README.md`。

## 一、缘起：我要验证的其实不是算法题

先说清楚动机，不然会觉得「又一个刷题客户端」很无聊。

`cj-tauri` 是我用仓颉语言做的 Tauri 2 对应物：**仓颉后端（静态编译）+ 系统 WebView 前端**，三件套是 WebView 宿主、IPC 双向桥、能力白名单安全模型。框架本身能起窗口、能 invoke 命令，测起来都挺顺——但我一直缺一个「像真实应用」的靶子：它得同时压到好几条链路，还得能长期迭代。

力扣这个题材刚好合适：

- **要跑外部程序**：判题得先把用户代码编译成可执行文件，再运行、比对结果——这就压到了 `shell` 那套子进程能力、工作目录、临时文件、超时。
- **要读写本地状态**：草稿、做题进度、题包缓存，都是真实落盘。
- **要有像样的前端**：代码编辑器、语法高亮、三栏布局，普通的手写 textarea 糊不过去。
- **要有网络**：从远端拉题包——正好压到那句「`stdx.net.http` 的 `ClientBuilder` 不带默认 TLS」的坑。

所以它名义上是「刷题 GUI」，实际是我给自己的框架找的一块试金石。判题机是真判题，题库是真题目，不是摆拍。

## 二、先说清楚 cj-tauri 是什么

后面所有内容都建立在这一句话上：**`cj-tauri` 是用仓颉语言实现的 Tauri 2 对应物**——把 Tauri（Rust + 系统 WebView）的三件套架构在仓颉里独立实现了一遍：**WebView 宿主 + IPC 双向桥 + 能力安全模型**。前端照旧用任意 Web 技术（HTML/CSS/JS，另有 Vue 3、React 18 模板），后端用仓颉静态编译，产物是**不带 Chromium 的原生桌面应用**：Windows 走 WebView2，Linux 走 WebKitGTK，鸿蒙 ArkWeb 是架构预留位。

跟「换个语言重写一遍」相比，真正让我觉得有意思的是仓颉这门语言的形状把几件事推到了前台：

- **平台差异只允许出现在两处**：仓颉侧的 `@When` 条件编译，和 C 桥的 `native/bridge_*.c`。IPC、能力校验、命令分发必须跨平台共用——所以我敢拿「同一个示例在 Windows 与 Linux 上都跑起来」当验收标准，而不是维护两套逻辑。
- **安全模型是「能力清单 + 三处联动」**：一个命令要能调，得同时做到「实现 handler」「`app.register(...)` 注册」「在 `capabilities/*.json` 里声明」。默认最小权限，漏一处分别得到 `command not registered` 或 `command not allowed`——下面这个力扣示例的 9 个命令就是照这条规矩配的。
- **命令是异步分发的**：校验在调用线程上同步做（未授权 / 未注册当场拒），通过的命令 `spawn` 到 worker 线程执行、结果回投给前端。所以「等编译器好几秒」的判题命令不会把窗口冻住——这条不是设计上的锦上添花，是被真机卡顿逼出来的。
- **命令放行 ≠ 参数放行**：清单还能给插件写路径 scope（`deny` 优先、`allow` 必须显式命中，支持 `$HOME` 这类变量），插件自己声明吃不吃这层限制。

一个最小工程长这样（`cj-tauri create` 生成的就是这套，只是默认模板把页面内联进了二进制）：

```
myapp/
├── cjpm.toml             # 仓颉工程；Windows 分支已带 --subsystem=windows（双击不弹控制台黑窗）
├── src/main.cj           # 装配：TauriApp().window(...).register("greet", …) → app.run(html)
├── capabilities/app.json # 能力清单：命令与事件的放行表（不声明 = 前端调不到）
└── ui/index.html         # 前端；经 window.__CJ_TAURI__ 的 invoke / listen / emit 与后端通信
```

### 怎么把它装起来用

两条路，看你想干什么。

**A. 起一个新工程**（Node 环境即可拿到 CLI）：

```bash
npx cj-tauri create myapp     # 脚手架；另有 --template vue|react
cd myapp
npx cj-tauri dev              # 编译并起窗口；vue/react 模板会接管它们的 Vite dev server
```

**B. 跑仓库里的示例**（这篇讲的力扣就在 `examples/leetcode-gui`）：

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git && cd cj-tauri
cd native && ./build_linux.sh          # 先编 C 桥；Windows 用 native\build_win.bat
                                       # 产物必须落在 native/ 根，cjpm.toml 按那个路径找库
cd ../examples/hello && cjpm build && ./run.sh   # Windows：run.bat
```

两条路的前置都一样：**仓颉 SDK 1.2.0（含 stdx）进 PATH**（`cjc` 要能被找到）。另外 Windows 需要 WebView2 Runtime 与 mingw-w64 gcc，Linux 需要 libwebkit2gtk-4.1 + GTK3 + gcc。跑起来后 `cj-tauri info` 能打出应用的装配结果（插件与命令清单），加 `--json` 给机器读——我给这个示例核对「哪些命令真的被放行了」时就靠它。

### 去哪儿找它

| 想找什么 | 地址 |
| --- | --- |
| 仓库（主托管，双推 AtomGit + GitHub） | **[atomgit.com/qq8864/cj-tauri](https://atomgit.com/qq8864/cj-tauri)** |
| 官网（中英双语，源文件在 `website/`） | **[yangyongzhen.github.io/cj-tauri](https://yangyongzhen.github.io/cj-tauri/)** |
| npm（CLI 与脚手架） | [npmjs.com/package/cj-tauri](https://www.npmjs.com/package/cj-tauri) |
| 上手文档 | `README.md`（概览与示例一览）、`docs/使用文档.md`（从零到窗口） |
| 设计取舍 | `docs/设计决策记录.md`（每个长期决策的「为什么」与真实代价） |
| 开发契约与坑清单 | `AGENTS.md`（这篇里的坑大半也在那儿有一份） |

## 三、它长什么样

一张实机截图就能说明白（窗口 1280×820，Windows WebView2）：

```
┌──────────────────────────────────────────────────────────────┐
│ 仓颉力扣 · cj-tauri   已保存草稿·题目 206   已解决 7/108 题   │  ← 菜单：运行 / 重置 / 关于
│                              [参考答案] [统计] [运行 Ctrl+R] [重置]
├───────────────┬──────────────────────────────────────────────┤
│ 题库           │  206. 前 K 个高频元素        [中等]           │
│ 全部/简单/中等 │  给定一个整数数组 nums …                      │
│ 未做 / 已过     │ ┌──────────────────────────────────────────┐ │
│               │ │ 1  func topKFrequent(nums: …, k: Int64) { │ │ ← CodeMirror
│ 哈希与计数      │ │ 2      let counts = HashMap…              │ │   行号 + 高亮
│  1 两数之和 ✓   │ │ …                                        │ │
│  2 多数元素     │ └──────────────────────────────────────────┘ │
│ …             │  判题终端                                      │
│ 数组与双指针    │  已载入题 206 的参考答案                       │
│  3 移动零       │  运行题目 206. 前 K 个高频元素                  │
│               │  判定结果（编译 + 运行 737ms）                  │
│ 堆与优先队列    │  ✓ 用例 1 通过  topKFrequent([1,1,1,2,2,3],2)==5│
│  206 前 K 个… ✓ │  通过 3/3 个用例。全部通过！                     │
└───────────────┴──────────────────────────────────────────────┘
```

三栏的分工：左栏是题库（按分类分组，支持难度/进度筛选），中栏是题面 + 编辑器，下栏是判题终端。顶部那排按钮里，`运行` 绑了 Ctrl+R，`参考答案` 会把每题自带的解答载进编辑器（**覆盖前会先存草稿**），`统计` 拉一次进度。

架构上它没有任何特殊之处，就是框架的标准用法：

```
main.cj        ── TauriApp().window(...).register("leetcode:*", …) → app.run(html)
commands.cj    ── 9 个 CommandHandler：list / get / run / saveDraft / loadDraft
                  / packs / fetchMore / solution / stats
problems_data.cj ─ 内置题库（100 题，JSON 字符串常量）
remote_packs.cj  ─ 远端题包：拉取、校验、缓存
progress.cj      ─ 草稿与做题进度（lc-stats.local.json）
ui/index.html    ─ 三栏页面，vendor 是 CodeMirror 5（内联进页面）
capabilities/app.json ─ 能力清单：这 9 个命令与 menu:click / dragdrop:files 事件
```

前端只经 `window.__CJ_TAURI__` 的 `invoke / listen / emit`，没有任何自己写的 `postMessage`。这一条是框架的红线，示例也不例外。

## 四、判题机：把你的代码拼成一份能编译的程序

这块是这个示例最有意思的地方，也是「真判题」和「假演示」的分界线。

流程很直白，难点全在细节：

```
前端点「运行」 → invoke("leetcode:run", {id, code})
  → RunCommand 取这道题的 tests
  → 拼一份完整源码：prefix + 用户代码 + harness
  → 写进 target/leetcode/<题目id>-<时间戳>-<序号>/main.cj
  → cjc 编译出可执行文件 → 运行 → 逐行扫 PASS/FAIL
  → 结果回投前端（下栏那几行"✓ 用例 1 通过 …"）
```

**harness 长什么样**：题库里每道题的 `tests` 是「一条完整调用表达式 + 一个期望字面量」，判题时生成：

```cangjie
let r1 = topKFrequent([1, 1, 1, 2, 2, 3], 2)
if (r1 == 5) {
    println("PASS 1")
} else {
    println("FAIL 1: got " + r1.toString() + ", want 5")
}
```

为什么不用仓颉测试框架写单测？因为**题库是数据，不是代码**。这样一份题就是一个 JSON 对象，能整体从远端拉下来、能缓存、能随仓库分发。代价是签名被限制在能 `==` 比较的类型上（`Int64` / `Bool` / `String` / `Array<Int64>` / `Array<String>`）——判题机不需要懂语义，它只比对期望结果。这个取舍我觉得划算。

**预置符号**：刷题的人不想为了一个 `HashMap` 先写一行 import，所以判题前会检查源码里有没有 `import `，没有就补一行 `import std.collection.*`。就这一行，`HashMap` / `ArrayList` / `HashSet` 全到位。

**编译缓存**：缓存键是**源码哈希**。同一份代码再点一次运行不会重新编译（不用等 `cjc` 那几百毫秒），改了任意一个字符就重编译——因为题库里每题是独立编译的，函数重名根本不冲突。

**然后我踩了 Windows 上最典型的一脚**：`cjc main.cj -o judge` 在 Windows 产出的是**没有后缀**的 `judge`，而我用 `cmd /c judge` 去跑它——`cmd.exe` 只认「名字 + PATHEXT」，于是报文里出现：

```
'judge' 不是内部或外部命令，也不是可运行的程序或批处理文件。
```

编译是成功的，失败在「怎么把它叫起来」。修法照框架里已有的 `cjcExeName()` 范式加一个 `judgeExeName()`：编译 `-o` 的产物名、编译缓存的路径、调用命令行**三处同源**地按平台分叉（Windows 带 `.exe`，Linux 不带）。这种「同一件事写在三个地方」的坑，唯一的解法就是让这三处共用同一个函数。

## 五、题库：19 题 → 100 题，答案跟着题走

最初的 19 题（两数之和、爬楼梯、打家劫舍这类）够跑通链路，但摆出来实在不像个刷题的地方。于是扩到了 **100 题、11 个分类**：

| 分类 | 题数 | 分类 | 题数 |
| --- | --- | --- | --- |
| 数组与双指针 | 17 | 字符串 | 14 |
| 二叉树 | 13 | 动态规划 | 11 |
| 哈希与计数 | 10 | 栈与队列 | 9 |
| 贪心 | 8 | 链表 | 6 |
| 递归与回溯 | 6 | 二分与排序 | 4 |
| 位运算与数学 | 2 | | |

难度分布：简单 45 / 中等 53 / 困难 2。

一句必须说在前面的话：**所有题目描述都是我自己按公开的经典题型写的**，只取「考点是什么」，不照抄任何题面原文。`problems_data.cj` 头部把这件事写清楚了，也算给仓库留个凭据。

**最值一提的改动是「答案跟着题走」**。原来答案是另一份文件（`solutions.cj`）里按 id 查表，后来我把整个文件退役了：题目的 JSON 里直接多一个 `solution` 字段，`leetcode:solution` 命令从题库里读。好处只有一条，但很关键——**只有一条路径**：远程题包只要愿意，也能自带解答，不必再跟一个 id 表。这次迁移把 19 内置题 + 8 道题包的答案一次性塞进了各自的 JSON。

**81 道新题不是手敲的**。手敲 81 个 JSON 对象，错一个逗号就是编译期一片红。我的做法是写个生成器脚本产出仓颉字符串常量，正文逐条写；写完跑两层自检：

1. **模板 + harness 到底能不能编译**（每题一份 `cjc`，模板得是合法骨架）；
2. **答案 + harness 是否逐用例 PASS**（这才是真验证——它抓出了我自己算错的两道题：腐烂的橘子那题第二组用例其实全烂，答案是 3 不是 4；还有一道二叉树的层序约定我写成 LeetCode 的压缩层序，而这个题库的约定是**孩子在下标 2i+1 / 2i+2**）。

89 条断言全绿才敢把生成结果回填进 `problems_data.cj`。这里有个必须写进题目描述的约定：层序约定、输入输出格式——不写清楚，「答案对不上」就变成用户的问题了。

### 题包：远端拉取、缓存与号段

题库之外还有「题包」机制，点左下角「加载更多题包」就会去拉：

- 题包放在仓库里（`docs/leetcode-packs/advanced-1.json`），客户端从 GitHub raw 拉——这样题包能独立于应用发版更新；
- 拉回来落本地缓存（`problems-remote.local.json`），下次启动直接并入题库；
- 有响应体上限（256KB）、题包名白名单（字母数字、下划线、连字符），https 请求显式 `TlsClientConfig()`（仓颉的 `stdx.net.http` **不带默认 TLS**，不显式配就直接抛异常）；
- **号段是分开的**：内置题占 1..100，题包从 200 起，校验会拦下 `<200` 的远程题。

这条号段规则刚上线就现场报了一次错，很值得记：

```
✗ 加载更多失败: 题包 schema 错误：远程题 id 必须 >= 200（内置题占 1..100），得到 100
```

原因是**新客户端 + 还没推上去的新题包**：远端还是旧的 100–107，而内置题库已经占满 1..100，旧题包的 `id=100` 正好和内置第 100 题撞车。规则要求「题包不许覆盖内置题」，所以**拒得对**——问题出在数据没跟着代码走。把新题包推上去就好了，而且顺手确认了一件事：旧客户端不会因此坏（它的下限是 `>=100`，新的 200–207 照样满足）。

## 六、前端：为什么 CodeMirror 必须「内联」，以及「一个 exe」是怎么打出来的

页面本身没什么好说的：一个三栏 flex 布局，深色主题，编辑器区挂 CodeMirror 5。真正花时间的是两件事。

**第一件：`<script src>` 这类相对路径在这个页面里根本不成立。**

这个应用的页面不是从 URL 加载的，而是 `app.run(html)`——把**一整段 HTML 字符串**交给宿主（Windows 下走 WebView2 的 `NavigateToString`）。字符串没有「来源 URL」，所以 `ui/vendor/codemirror.min.js` 这种相对路径解析不出来。于是流程变成：

```
读 ui/index.html → 在页面里找两个占位注释
  → 把 CodeMirror 的 CSS / JS 文本替换进去
  → 作为「一个字符串」交给 run()
```

占位符是形如 `__VENDOR_CSS__` 的注释标记。这里有个我自己写注释时踩的小坑：**往块注释里写通配符会开启嵌套注释**，所以描述占位符时不能把它连符号一起写全。

vendor 读不到时会降级：页面留空注释，编辑器退化成纯 textarea——功能弱了，但**不会白屏**。（这个降级路径我在真机上见过一次，日志里就一行 `[lc] vendor 缺失 …`，挺好定位。）

**第二件：把整个应用打成一个 exe。**

`scripts/pack-win-single.sh` 干的事：复制一份临时构建副本，把**页面、vendor、能力清单**各自 base64 写进副本的 `src/packed_assets.cj`，随二进制一起编进去——产物是一个**不带任何随行文件**的 exe，不装仓颉 SDK 的人也能直接跑。

应用侧的取用规则只有一条：**base64 非空就用内嵌的，否则按相对路径读盘**。仓库里正常构建走第二条路，所以这个机制对日常开发完全透明。为什么用 base64 而不是生成字符串字面量？因为页面正文里有成片的反斜杠和引号（minified 逻辑、正则、CSS 转义尤其密集），转义错一个字符的后果是**整段脚本静默不执行**，页面看着正常、就是什么都不动。base64 的字符表只有 `A-Za-z0-9+/=`，生成和解码都不碰转义，坏不了。

还有一处必须一起内嵌：**能力清单**。单文件产物没有随行的 `capabilities/`，清单缺席的话所有命令都会被拒（`command not allowed`），应用看起来就是「界面在、按钮全不灵」。所以打包器会把每个 `capabilities/*.json` 单独 base64、用逗号拼起来，应用启动时逐个 `addCapabilityJson` 挂上（显式挂载即不自动扫描目录，两条路互斥）。

顺便说个这次刚改的地方：vendor 的清单原来是写死在打包器里的（markdown-notes 那 5 份）。力扣这边只有 CodeMirror 两份，所以我把它改成「示例自带 `ui/vendor/pack-files.txt` 就按它的逐行清单打，没有则沿用默认」——**顺序是契约**，必须和应用侧 `VENDOR_FILES` 逐字对齐，改一边就会错位。

打包器里另外两条经验，也是真金白银换来的：

- **`strip` 失败会换一副面孔出现**：有的 llvm-mingw 发行包里 `strip.exe` 只是个包装器、真身 `llvm-strip` 缺失，而脚本里那句 `2>/dev/null` 把报错吞了，表象成了「strip 对这个 exe 无效」——产物一直卡在 29MB 左右。判据是**裸跑一遍 `strip --version`**；现在脚本会回退到 SDK 自带的 `llvm-objcopy --strip-all`，实测 29.3MB → 5.9MB。
- **子系统默认是 console**：默认链接出来的是控制台程序，双击会先弹一个黑窗口（交付后用户第一条反馈就是这个）。所以 `link-option` 里必须写 `--subsystem=windows`，而且脚本收尾会 `objdump -p` 复核一次（必须是 `00000002`），免得被人改回去只靠肉眼发现。
- **「按名字 LoadLibrary」的组件不在 PE 导入表里**：`WebView2Loader.dll`、OpenSSL 的 `libssl-3-x64.dll` / `libcrypto-3-x64.dll` 都属于这一类——递归解析导入表收不全，只能靠打包脚本单独收（单文件包里 loader 是内嵌进 exe、首次运行释放到 `%TEMP%`）。

## 七、那些让我返工的坑（附判据）

写到这里，把真正花掉时间的几条集中记一下。它们的共同点是：**表现和病因经常只差一个判据**。

**1. `"""` 里的 `${...}` 是活插值——题库里不能写它。**

题库是一整段仓颉三引号字符串常量。有一道题的答案里我写了 `"${x}"`（想在结果里拼出变量），编译直接报 `undeclared identifier 'x'`——因为三引号里 `${}` 会被当**仓颉插值**先解析掉。规矩后来定死了：**答案里禁用 `${`**，并且自检脚本加一条守卫，扫题库时命中即报错。

**2. `cjpm build success` 不等于产物存在。**

上一轮构建被占用/中断过之后，`target/release/incremental-cache.json` 仍认为可执行文件是最新的，于是 `cjpm build` 只重编包对象、**跳过链接**却照报 `build success`。你启动时看到的是「拒绝访问。」（cmd）或 exit 127 且无输出（bash）——太容易被误判成杀软/权限问题了。判据是**看产物**：`ls -l target/release/bin/`。产物不在就删掉 `incremental-cache.json` 与 `*.cjo` 重建。

**3. Windows 上 `cmd.exe` 不执行没有后缀的可执行文件。**

就是前面判题那件事。`cjc main.cj -o judge` 在 Windows 产出 `judge`（无后缀），`cmd /c judge` 报「不是内部或外部命令」。这类「编译成功、调用失败」的坑，判据只有一条：**去看产出目录里到底叫什么名字**，别信自己写下的 `-o` 参数。

**4. WebView2 用户数据目录互锁：`0x800700aa`。**

上一个实例（含它的 `msedgewebview2.exe` 子进程）没退干净就会占住用户数据目录，新实例报 `create WebView2 controller failed: 0x800700aa`——看起来像「窗口起不来」，其实是被锁了。无人值守跑验证时，我给每轮都设一个独立的 `WEBVIEW2_USER_DATA_FOLDER`，实例之间就不再互相锁。**另外：用户正在用的时候别起第二个实例**——同一个目录、同一份进度文件，会把真实数据搅在一起。

**5. 诊断日志一定要走 stderr。**

仓颉 `println` 的 stdout 有缓冲，进程被强杀时日志会丢；`eprintln` 和 C 桥的 stderr 才即时落盘。端到端验证我读的永远是 stderr 那份。

**6. 自检脚本比人靠谱，但「自检全绿」不等于界面没问题。**

两层编译自检抓出了我自己算错的两道题（见第四节），价值已经回本。但也要说清楚它的边界：**断言管得了数据，管不了排版**。仓库里 `examples/music` 就出过「10 条页面自检全绿、标题却被挤成两行」的事——布局缺陷只能抓图靠人眼看。所以力扣这边每次改过 UI，我都会留一张实机截图当证据。

**7. 判题工作目录漏建了顶层 `target`——只在打包产物上炸。**

这条是打包那天现抓的，也是最值得写下来的一条。判题要把源码写进 `target/leetcode/<题号>-<序号>/`，建目录时我只写了下面那一级（`target/leetcode`），顶层 `target/` 靠「构建树里本来就有」蒙着——开发期天天在示例目录里跑，所以从来没露馅。可单文件 exe 是从一个**空目录**启动的，那里根本没有 `target/`，于是：

```
✗ 运行失败: 建判题目录失败: FSException: Failed to create directory
  `target/leetcode/1-44097-1`, parent directory `target/leetcode` does not exist
```

更阴的是第一层 `Directory.create` 外面套了个空 `catch`，失败是静默的，报出来的是第二层——所以我一开始还在想「`target` 怎么会不存在」。修法就是显式补建顶层 `target`；教训两条：**「环境里恰好存在的东西」不是依赖，是隐性假设**；**空 catch 会把真正的失败点往后挪一层**，挪出来的错会指向一个看起来不可能的原因。

## 八、怎么用它

### 前置条件

| 需要什么 | 说明 |
| --- | --- |
| 仓颉 SDK 1.2.0（含 stdx） | 编译应用；`cjc` 还要在 PATH 里，**判题靠它** |
| WebView2 Runtime（Windows） | Win11 自带，Win10 多数已装 |
| libwebkit2gtk-4.1 + GTK3（Linux） | 系统包 |
| mingw-w64 gcc（Windows）/ gcc（Linux） | 编 C 桥用，仓库里 `native/build_win.bat` 或 `build_linux.sh` |

### 在仓库里跑起来

```bash
# 1) 先编 C 桥（仓库根）——产物必须落在 native/ 根，cjpm.toml 按那个路径找库
cd native && ./build_linux.sh        # Linux
#   native\build_win.bat             # Windows

# 2) 编示例
cd examples/leetcode-gui
cjpm build

# 3) 起窗口
./run.sh                             # Linux
#   run.bat                          # Windows（双击，或在 cmd 里跑）
```

两个容易踩的地方：

- **工作目录必须是示例根**。`capabilities/` 与 `ui/` 都是按项目根相对路径读的，在别处启动就是「命令全被拒」或「读不到前端页面」。
- **`run.bat` / `run.sh` 只在产物不存在时才构建**。改过代码请自己先 `cjpm build`，否则跑的还是旧产物——我取证时就因为这件事差点把旧日志当成本轮结果。

### 判题能不能用

启动时 stderr 会打一行：

```
[lc] cjc found: <路径>（判题功能就绪）
# 或者
[lc] cjc not found —— 判题不可用
```

没有 `cjc` 时应用照样能用：选题、写代码、看题面都正常，只有「运行」会返回可读的业务错误。判题的临时工作目录在 `target/leetcode/<题目id>-<时间戳>-<序号>/`，随便删。

### 界面上的六件事

1. **左栏选题**：按分类分组，可按 全部 / 简单 / 中等 / 困难 与 未做 / 已过 筛选；
2. **中栏写代码**：模板已经给了函数骨架——**函数名别改**，判题靠它拼 harness；
3. **Ctrl+R 运行**：下栏逐条列用例结果，通过的打 ✓；编辑过程会自动存草稿（顶部显示「已保存草稿」）；
4. **卡住了点「参考答案」**：载入该题解答（覆盖前先存草稿），我的建议是看懂了自己再写一遍——`重置` 会回到模板；
5. **「统计」**：看已解决数与通过数，数据落在 `lc-stats.local.json`；
6. **「加载更多题包」**：从远端拉题包（要网络），拉回来落缓存，下次启动自动并入。

### 免 SDK 分发：一个 exe

```bash
bash scripts/pack-win-single.sh examples/leetcode-gui
# => examples/leetcode-gui/dist-single/leetcode-gui.exe
```

产物是一个**不带任何随行文件**的 exe：页面、CodeMirror、能力清单全在二进制里，双击就开（仍然需要 WebView2 Runtime）。但要说清楚边界：**判题依然要本机有 `cjc`**——我把题目和编辑器装进了包里，编译器没法装（那是几百 MB 的 SDK）。所以这个包对「只想看看界面/读题」的人友好，对「要判题」的人还是得装 SDK。

所有本地数据（进度、题包缓存、判题临时目录）都落在**启动时的工作目录**下——仓库里跑就在示例目录，打包产物跑就在你双击/启动它的那个目录，删掉不心疼。单文件包也因此可以放在任意空目录里跑，不会和别人的进度文件搅在一起。

## 九、写在最后

回头看，这个示例做的其实是三件事：

**一是证明判题是真的**——真写成源文件、真调 `cjc` 编译、真运行、真比对。不是把答案和预期值写在页面里演的。整条链路（子进程、工作目录、缓存、超时、平台分叉）都在真机上跑过。

**二是把框架的几条关键路径压出了声音**：异步命令分发（慢命令不冻窗口）、能力清单与命令三处联动、内联页面里 vendor 的加载方式、单文件打包的 base64 通道——这些坑大半是先在这个示例里撞出来的，然后才回到框架和文档里。

**三是留下了可核对的数字**：内置 100 题（11 分类，简单 45 / 中等 53 / 困难 2）、题包 8 题（id 200–207），合起来界面上是 108 题；答案 100% 内嵌；两层编译自检 89 条断言全绿。

最后是几句实话，免得读者期待错位：

- 题目描述是我按公开的经典题型**自己写的**，没有照抄任何题面原文，`problems_data.cj` 头部也这么声明；
- 判题只做「调用 + 比对期望结果」，没有 LeetCode 那种大规模测试集与性能/内存限制——它验证的是**判题链路**，不是给人当刷题评分器；
- 平台实测以 Windows（WebView2）为主，Linux 侧的框架链路是通的，鸿蒙 ArkWeb 目前还是架构预留位。

如果你想拿它当工具，装好 SDK 直接 `run.bat`；如果拿它当 `cj-tauri` 的样本，建议从 `src/commands.cj` 里的 `RunCommand` 开始读——那一百来行把「仓颉应用怎么把外部编译器用起来」讲得比文档清楚。

## 相关链接

- **仓库（主托管）**：[atomgit.com/qq8864/cj-tauri](https://atomgit.com/qq8864/cj-tauri)
- **官网**（中英双语）：[yangyongzhen.github.io/cj-tauri](https://yangyongzhen.github.io/cj-tauri/)
- **npm**（CLI 与脚手架）：[npmjs.com/package/cj-tauri](https://www.npmjs.com/package/cj-tauri)
- **这个示例**：[examples/leetcode-gui](https://atomgit.com/qq8864/cj-tauri/tree/main/examples/leetcode-gui)（含 README、题库与打包脚本）
- **单文件 exe**：`examples/leetcode-gui/dist-single/leetcode-gui.exe`——随仓库分发，不装 SDK 也能先把界面点一遍（判题仍要本机 `cjc`）
- **同类示例**：`examples/modbus-poll`（Modbus 调试工具，对标 Modbus Poll）、`examples/markdown-notes`、`examples/typing-poem`、`examples/music` 等，全部在 `examples/` 下



