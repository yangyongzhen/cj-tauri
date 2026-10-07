# 用仓颉给孩子写了个打字游戏：cj-tauri 实战

> 一个「古诗词打字练习」桌面应用，从零到跑起来，以及我在里面踩过的坑。

## 起因：两件事，一个应用

我家孩子上小学，有两件事同时在推进：

1. **背古诗词**。部编版教材从一年级就有古诗，老师还额外要求背《小学生必背古诗词 75 首》。
2. **练打字**。学校开始有上机课，但键盘上 26 个字母的位置还没形成肌肉记忆。

这两件事各自都有现成的工具——背诗有 App，练打字有各种在线打字网站。但我不想让孩子每天开一堆网页，更不想让他一个人对着"asdf jkl;"这些无意义字母敲。于是就有了一个很自然的需求：

**能不能把古诗词本身当作打字素材？屏幕上出现一句"曲项向天歌"，字上面标着拼音，孩子照着拼音敲 `qu xiang xiang tian ge`——打完这一句，这句诗也就记住了。**

需求清楚了，接下来是技术选型。桌面应用，我希望是**一个双击就能开的窗口**，不需要装 Node、不需要联网、开机就有，最好体积小一点（给孩子用的东西，我不想要一个 200 MB 的 Electron）。这时候正好想起了自己一直在写的 [cj-tauri](https://atomgit.com/qq8864/cj-tauri)——用华为仓颉语言实现的、对标 Tauri 的混合开发框架。

于是就有了 `examples/typing-poem`：**仓颉做后端（诗库、成绩、逻辑），系统 WebView 做前端（three.js 渲染 3D 诗词卡片）**。

## cj-tauri 是什么

一句话：**用仓颉写的 Tauri**。

Tauri 的卖点是"Rust 后端 + 系统 WebView 前端"，用系统自带的浏览器内核渲染界面，而不是像 Electron 那样打包一整个 Chromium。cj-tauri 把这一套搬到仓颉上，三件套严格对位：

| Tauri | cj-tauri | 干什么的 |
|---|---|---|
| `tauri::Builder` | `TauriApp` | 装配应用：窗口、命令、插件 |
| `#[tauri::command]` | `CommandHandler` 接口 | 前端能调的后端函数 |
| `@tauri-apps/api` | `window.__CJ_TAURI__` | 前端的 `invoke` / `listen` / `emit` |
| `capabilities/*.json` | `capabilities/*.json` | 命令/事件白名单，**默认最小权限** |
| `tao` + `wry` | `src/host.cj` + `native/bridge_*.c` | WebView 宿主（Linux GTK / Windows Win32+WebView2） |

架构从上到下就四层：

```
前端 (HTML/CSS/JS)  ← window.__CJ_TAURI__.invoke/listen/emit
        │  JSON over postMessage
        ▼
IPC 消息桥（src/ipc_hub.cj）   命令注册 / 分发 / 校验
        ▼
能力安全模型（src/capability.cj）  白名单，没声明一律拒绝
        ▼
WebView 宿主（src/host.cj + 各平台实现）
   ├─ Linux:   webkit2gtk-4.1（C 桥跑在原生 pthread）
   ├─ Windows: WebView2（Win32 消息循环在宿主线程）
   └─ 鸿蒙:    ArkWeb（架构预留）
```

平台状态说清楚，免得你照着这篇去做却发现跑不起来：

- **Windows + WebView2：已实机跑通**（我写这个打字游戏的主力平台）；
- **Linux + WebKitGTK：已实机跑通**（示例和自检都在 Xvfb 下跑过）；
- **鸿蒙 ArkWeb：只有架构预留位**，还没实现。

## 五分钟起一个自己的应用

先说实话：这个"五分钟"是指**装好仓颉 SDK 之后**五分钟。SDK 要去 [cangjie-lang.cn](https://cangjie-lang.cn) 下载（需要华为账号，没有匿名直链），再配上 stdx。Windows 上要么把 SDK 的 `runtime/lib/<平台>`、`bin`、`tools/bin`、`tools/lib` 都塞进 `PATH`（官方 `envsetup` 的布局），要么只设 `CANGJIE_HOME`、让启动器自己补齐——后者省事得多。

环境好了之后，两条路都行：

```bash
# 路 1：npm（跨平台，推荐）
npx cj-tauri create myapp
cd myapp
npx cj-tauri dev

# 路 2：直接用仓库里的 CLI
./cli/cj-tauri.sh create myapp     # Windows: cli\cj-tauri.bat create myapp
cd myapp
./cli/cj-tauri.sh dev
```

CLI 的子命令就六个，够用：`create` / `dev` / `build` / `run` / `info` / `help`。其中：

- `dev` 会构建 C 桥 → `cjpm build` → 拉起窗口；如果工程用的是 Vue / React 模板，它还会**接管 Vite dev server**（把地址经 `CJ_TAURI_DEV_URL` 交给宿主），退出时把 dev server 连同它的后代进程一起收掉，不留 `vite` / `esbuild` 残骸；
- `build` 出 `target/release/bin/main.exe`，前端如果是工程化的就用 `vite-plugin-singlefile` 打成单个 `index.html`；
- `info` 是排障第一站：框架 / 项目 / stdx / SDK / cjpm / 桥 的路径解析结果，外加已装配的插件清单（`info --json` 只有这份 JSON，给 CI 用）。

### 后端：一个命令十行代码

生成的工程里，后端长这样（这是我给示例 `examples/hello` 写的精简版）：

```cangjie
import cjTauri.*
import stdx.encoding.json.*

// 1. 实现命令：前端 invoke("greet", {name}) 就走到这儿
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
    // 2. 装配：窗口 + 注册命令（对标 tauri::Builder）
    let app = TauriApp()
        .window(WindowConfig("myapp", 1000, 700))
        .register("greet", GreetCommand())

    // 3. 启动（阻塞）。能力清单由 run() 自动扫描 capabilities/ 目录
    app.run(html)
    return 0
}
```

### 前端：注入的桥

前端不用装任何东西，`window.__CJ_TAURI__` 是宿主在 document-start 时注入的：

```js
const tauri = window.__CJ_TAURI__;

tauri.invoke('greet', { name: '仓颉' }).then(d => console.log(d));  // JS → 仓颉
tauri.listen('tick', p => console.log(p));                          // 仓颉 → JS
```

有一个细节值得单独提醒：**不要在模块作用域里直接读 `window.__CJ_TAURI__`**。桥确实是页面脚本之前注入的，但"页面脚本"在发行态是打成一个单文件的——谁先谁后属于实现细节，不该由应用来赌。稳妥写法是初始化时**等桥出现**：

```js
var bridge = null;
function waitForBridge(cb) {
  if (window.__CJ_TAURI__) { bridge = window.__CJ_TAURI__; cb(); return; }
  var tries = 0;
  var timer = setInterval(function () {
    tries++;
    if (window.__CJ_TAURI__) { clearInterval(timer); bridge = window.__CJ_TAURI__; cb(); }
    else if (tries > 200) { clearInterval(timer); /* 桥没来，报错或降级 */ }
  }, 25);
}
```

这段就是我打字游戏 `ui/index.html` 里的原样代码。看起来像多余的防御，实际上它在 Linux 上救过我——那里的桥必须用"文档开始"时机注入，用文档末尾注入会晚于内联的 `<script type="module">`，前端读到的就是 `undefined`。

### 能力清单：默认什么都不允许

`capabilities/default.json`：

```json
{
  "identifier": "default",
  "windows": ["main"],
  "commands": ["greet", "system:version"],
  "events": []
}
```

规则很短：**没在这里声明的命令，前端一律调不到**，会收到 `command not allowed: xxx`。没有声明的事件也不会投到页面。

这是我认为 cj-tauri 从 Tauri 那儿继承得最值的一条设计——尤其当你的前端是别人写的、或者从远端加载的时候，"默认最小权限"能省掉一整个类别的安全事故。对照组的写法也简单：故意留一条不在清单里的命令，让前端调一次、看它被拒。

新增一个命令是**三处联动**，缺一处就用不了，这点新人必踩：

1. 实现 `CommandHandler`；
2. `app.register("cmd", Handler())`；
3. 在能力清单的 `commands` 里声明。

只做 1+3，得到 `command not registered`；只做 1+2，得到 `command not allowed`。两个错误信息不一样，正好能告诉你漏了哪一步。

## 打字游戏：素材为什么放在仓颉侧

先说结论：**诗库和成绩都在仓颉侧，页面只经 `invoke` 取用**。

这不是为了"炫后端能力"，是两个很实际的理由：

**第一，拼音和汉字必须逐字对齐，而这件事最容易写错。**

每句诗在仓颉侧是一个二元组——汉字和它的拼音，拼音按音节用空格分隔：

```cangjie
Poem("yonge", "咏鹅", "骆宾王", "唐", [
    ("鹅鹅鹅", "e e e"),
    ("曲项向天歌", "qu xiang xiang tian ge"),
    ("白毛浮绿水", "bai mao fu lv shui"),
    ("红掌拨清波", "hong zhang bo qing bo")
])
```

约定是：**音节数必须等于汉字数**（全库都是"一个字一个音节"，没有儿化/轻声合并）。游戏里的打字单位就是音节——敲对一串字母，对应的那个字就点亮。

手写 108 首诗，几千个音节，写错的概率不低。所以素材放仓颉侧的好处是：**能在启动时自检**。`checkPoemData()` 会把每句的汉字数和音节数对一遍，对不上就在 stderr 上喊出来：

```
[typing] 素材有 3 处对不上：游戏里会在那些字上卡住，请先修 src/poems.cj
```

而不是等孩子打到那一个字，卡在那儿不知道发生了什么。页面侧还有一遍对称的校验（从 `poem:list` 拿回来的数据再对一次），两边都过才算数。

**第二，成绩得落盘，而落盘是宿主的活。**

最好成绩写在本机文件 `typing-scores.local.json`（`.local` 后缀已经进了 `.gitignore`，本机数据不进仓）。页面刷新、应用重启都不丢。文件格式是一整个 JSON 对象，`诗 id → 记录`：

```json
{
  "yonge": {
    "attempts": 4,
    "bestStars": 3,
    "bestKpm": 78.4,
    "bestAccuracy": 96.2,
    "lastStars": 2,
    "lastKpm": 61.0,
    "lastAccuracy": 92.5,
    "syllables": 18
  }
}
```

为什么整份读写、而不是逐条追加：这份数据的体量就是"一百来首诗各一行"，读写只在进入和打完一首时发生。整份读写换来的是**格式自愈**——文件被人改坏了，最坏情况也只是这一轮从空开始，不会把解析错误带进游戏。

### 108 首是怎么来的

素材范围我按"覆盖小学阶段"来定：以教育部推荐的《小学生必背古诗词 75 首》打底，再补上部编版语文教材里出现、但不在那 75 首里的诗词（含"日积月累""古诗词诵读"栏目），去重后是 **108 首、2996 个音节**，从 16 字的《采薇（节选）》到 56 字的《闻官军收河南河北》。

**故意不收三类**：

1. **文言文**——"学弈""两小儿辩日"这类没有逐字拼音可打的玩法；
2. **蒙学韵文**——《对韵歌》《人之初》，性质上是识字韵文，不是诗；
3. **仍在版权期内的现代诗词**——比如毛泽东《卜算子·咏梅》，要到 2026 年底才进入公有领域，先不引。

这三条不是洁癖，是给孩子看的应用里"素材边界"必须有人拿主意。收进来一部版权不明的作品，比少收十首诗的代价大得多。

## 这个应用是怎么对孩子友好的

技术部分讲完了，接下来是我真正花心思的地方。**"能用"和"孩子愿意一直用"是两件完全不同的事**，中间隔着一堆细节。

### 一、字要大，拼音要清楚

小学生的手和眼都在发育，屏幕上挤一片小字是劝退。所以卡面的尺寸是刻意放大的：

| 元素 | 尺寸 | 为什么 |
|---|---|---|
| 汉字 | **156px** | 一眼看清笔画，远一点也能看 |
| 当前字的拼音 | **80px** | 正在打的那个字，拼音要最醒目 |
| 其它字的拼音 | 66px | 给下一个字留出预告，但别抢戏 |
| 当前字底衬 | 浅金底色 | 不靠颜色对比瞎猜"我打到哪了" |

而且字号**随诗的行数自适应**：五行以内字号最大，行数多了按行高同比收，不会挤成一片。

### 二、长诗自动分栏，而且分栏门槛是"算两遍"

这条是我改了三轮的地方。

《长歌行》10 行、《春夜喜雨》8 行，单栏排下去要么字小到看不清，要么溢出屏幕。所以行数多的长诗自动分成**左右两栏**，句序是"先左栏后右栏"。

关键在门槛怎么定。设一个固定阈值（比如"超过 6 行就分栏"）是最容易的做法，但不对——**同样是 6 行，五言和七言的宽度差很多**。所以现在的做法是：

**单栏排一遍、两栏排一遍，各自算出"这套版面下字能有多大"，取字更大的那一套。**

结果是《长歌行》分栏后汉字 128px，单栏只有 64px（差一倍）；而 4 行七言仍然走单栏。全库 **94 首单栏 / 14 首分栏**。这条规则不用维护，加了新诗它自己会算。

> 顺带说，分栏的坐标我一开始是写死的。后来收成一套几何函数（`rowTop()` / `pinyinBaseY()` / `charBaseY()`），卡片的绘制和"第几个字的坐标在哪"共用同一套——**因为 3D 卡片是画在纹理上的，点击/高亮的坐标得按纹理坐标换算**，早先两套坐标各写一遍的时候，光标位置偶尔会和实际字对不上。

### 三、难度台阶要看得见

诗库按字数**从少到多**排开，孩子从上往下就是一条"越打越长"的路。星级分三档，档位由仓颉侧定，页面只负责渲染：

- ★ **≤20 字**：五言短篇，《咏鹅》《静夜思》这种，一分钟不到就能打完；
- ★★ **≤28 字**：七言与词曲，得忍一忍；
- ★★★ **更长**：《长歌行》《春夜喜雨》这类大篇。

而游戏里的成绩星级是**另一套门槛，刻意要求"先准后快"**：

| 星级 | 正确率 | 速度 |
|---|---|---|
| ★★★ | ≥ 95% | ≥ 60 键/分 |
| ★★ | ≥ 85% | ≥ 30 键/分 |
| ★ | 其余 | 其余 |

打字练习最容易变成"乱敲求快"，所以三星把正确率卡在 95%——**宁可慢一点，别练出一手错位肌肉记忆**。

### 四、反馈要一层一层给，而且不能惩罚

孩子对"我做对了"这件事的感知，全靠反馈。这个应用的反馈是有层次的：

- **每敲对一个音节**：那个字点亮、冒一点星光——最小单位的正反馈，频率最高；
- **连击**：连对越多，音越高。音效是 **WebAudio 现场按五声音阶合成的**（宫商角徵羽），零音频资源，连击五档一档比一档亮；
- **敲错**：屏幕边缘泛一层红晕。**连击只减半、不归零**——这是刻意的，归零会让一次手滑抹掉前面全部努力，对小孩太苛刻；
- **打完一整句**：这句诗**从纸上浮起**，一道墨光扫过，一声磬；
- **打完一整首**：礼花 → 盖印 → 三颗星逐个落下 → 才亮成绩面板。

最后这条顺序也是有意设计的：**先把"完成"这件事演完，再给你看分数**。孩子先得到的是庆祝，不是评估。

### 五、世界随着输入变化

光有卡片太单调。所以每首短诗配了专属的 3D 场景，打完整一句就推进一幕：

| 篇目 | 场景 |
|---|---|
| 《咏鹅》 | 绿水、白鹅 |
| 《静夜思》 | 月亮与霜 |
| 《望庐山瀑布》 | 瀑布水雾 |
| 其余篇目 | 通用"墨卷星云" |

three.js 渲染出来的世界会随着打字进度推进——**打的字真的在改变这个世界**，这比任何进度条都直观。

### 六、HUD 上写的是"追平你自己"

游戏过程中，右上角一直显示两个数：

- **距离你自己的纪录还差多少**（速度进度条）；
- **三星门槛是多少**（正确率 / 速度的真值）。

这两个数的**真值都在仓颉侧**（`starsFor()` 那个函数），页面上显示的只是副本。这么做的原因很实在：门槛改一次，两处只有一个地方是真源，不会漂移。而且对孩子来说，"跟自己的纪录比"比"跟一个陌生排行榜比"踏实得多——**这个应用里没有任何联网排行榜，也不需要账号**。

### 七、离线、无账号、一秒开

最后一点也算"友好"，是给家长的友好：

- **零 Node、零构建**：前端就是一个 `ui/index.html`，改完刷新就是新样子；
- **不联网**：three.js 是随包走的（`ui/vendor/three.min.js`），诗库在二进制里，成绩在本机文件里。断网照玩，也没有任何数据往外走；
- **双击就开**：仓颉静态编译 + 系统 WebView，没有 Electron 那两百兆的运行时要下载。

## 三个值得单独讲的实现细节

### 1. three.js 是怎么进到页面里的

按常规做法，前端要用 three.js 有两条路：`<script src="vendor/three.min.js">`，或者 ES module `import`。

**在这个应用里，两条都不成立。**

页面是 `app.run(html)` 的**内联字符串**来源（Windows 下走 `NavigateToString`），也就是**没有真实来源**——origin 是 opaque 的。于是：

- 相对路径 `<script src="...">` 没有 base URL，取不到；
- ES module 在 `file://` / opaque 来源下被 CORS 拦。

真正的解法是利用宿主已有的**"预执行脚本"通道**：`WebViewHost.addInitScript()`。它本来是给插件的 `jsShim()` 用的（document-start 注入，排在桥 JS 之后），整份 UMD 产物注进去之后，页面里 `window.THREE` 直接可用，两平台语义一致，而且**离线可跑**（不走 CDN）：

```cangjie
let three = readTextFile("ui/vendor/three.min.js", "three.js")
app.webviewHost().addInitScript(three)
```

`ui/vendor/` 里连 UMD 产物和它的许可证一起放。选 **r160** 是有理由的：**它是最后一个带 UMD 构建的版本**，`three@0.161+` 只剩 ESM 了。

### 2. 命令是异步分发的，慢命令不冻窗口

`IpcHub.handleInvoke` 只做校验，通过校验的命令 `spawn` 到 worker 线程执行，结果经 `jsSink` 回投：

- **"未授权 / 未注册"在调用线程上同步拒绝**（这种判断是纯内存的，快）；
- 真正的业务逻辑在 worker 线程跑，所以慢命令——跑子进程的 `shell:exec`、弹原生对话框——**不会把宿主 UI 线程钉住**；
- 同一命令被并发调用**不保证执行顺序**，前端按 promise id 匹配。

对打字游戏来说，这一条其实很关键：`score:save` 要写文件，如果它跑在宿主线程上，正好在礼花播放的那一刻写盘，动画就会卡一下。现在它写在后台，孩子看不到任何停顿。

### 3. 一个我修了两轮才找到的真 bug

这个值得讲，因为它属于"测试全绿但功能已经坏了"那一类。

`score:save` 里有个字段 `bestAccuracy`。落盘时我按**百分比**写（`96.2`），读回来的时候却当**分数（0..1）**用。结果每存一轮，旧值就被放大 100 倍：

```
94.5 → 9450 → 945000 → ... → 9.63e15
```

涨到 9.6e15 的时候，`round1()` 里的 `Int64(x * 10.0)` **转换溢出抛异常**（仓颉里 Int64 越界转换是抛异常，不是回绕），于是 `score:save` 每一次都抛错、成绩再也存不下去。

**最坑的是它不打日志。** 数据显示成 `NaN`，页面拿不到回投，自检里才出现 `[无回投]` 这种断言失败。而且前面 11 次都是"成功"的，光看 `PASS` 根本发现不了——是自检跑到第 12 次才暴露的。

修法三处：仓颉侧读写统一口径（内部一律用分数，只在落盘和吐给页面时 ×100）、`round1()` 加越界兜底、页面侧补诊断与回归断言。

这件事教我的东西比 bug 本身重要：**"读写同口径"是数据落盘的基本纪律**，以及**量纲不一致的 bug 会静默积累**，只有"跑很多轮"才能把它逼出来。

## 让孩子自己验收：无人值守自检

上面那个 bug 是靠自检抓到的，所以这一节值得单独讲。

孩子没法帮我做回归测试，我自己也不想每次都盯着窗口看一遍。所以这个示例带一个**页面自检**：跑 `run.bat selfcheck`（内部设 `CJ_TYPING_SELFCHECK=1`），页面就**自己把《咏鹅》从头打完**，一路把断言结果经 `report` 命令回传到 stderr。

按键一律用 `dispatchEvent` 走**真实的 keydown 通路**，不另写一条"测试专用"的输入路径——否则测的就不是孩子按的那条路了。

**57 条断言**覆盖这些层面：

| 层面 | 断言举例 |
|---|---|
| three.js 通道 | `three.js 经 addInitScript 注入`（并核对 `THREE.REVISION === '160'`） |
| 素材 | `每句的汉字数与音节数一一对齐`；`诗库按音节数升序（难度递增）` |
| 成绩与模式 | `score:save 回投了星级与成绩`；`成绩已落盘（persisted=true）` |
| 玩法 | `敲错时连击减半而不是清零`；`打完一整句触发句末高潮`；`浮起的是真的 3D 文字` |
| 版面 | 字号 / 行内几何 / 长音节宽度 / **长诗分栏** / 滚动条配色确实生效 |
| 能力校验 | 故意调 `poem:nope`（清单里没声明的命令），验证它**真的被拒** |

最后那条是我特别喜欢的用法：**故意留一条不在白名单里的命令**，让前端调它，"被拒绝"本身就是一条断言。安全模型不是写在文档里的承诺，是每次运行都会验一遍的事实。

自检跑完的结果是这样一串（每一行都是页面回传的真实输出）：

```
[frontend] PASS three.js 经 addInitScript 注入  [REVISION=160]
[frontend] PASS 诗库装进来了（≥20 首，扩库不该悄悄掉篇目）  [count=108]
[frontend] PASS 每句的汉字数与音节数一一对齐  [1440 字 / 5774 个字母]
[frontend] PASS 敲错时连击减半而不是清零
[typing] score:save 《咏鹅》 用时 3.4s 正确率 94.5% 速度 78.4 键/分 星级 3 破纪录=true 第 15 次 落盘=true
```

`57 passed / 0 failed`，跑完自己退出，全程无人值守。整个门禁还有一层在框架侧：`scripts/test.sh`（132 个仓颉单测）+ `scripts/test-bridge-core.sh`（C 桥桩平台自检 99 项断言），都不需要图形环境。

## 踩过的坑

按"我以为能跑、结果跑不起来"的顺序列几个，都是真实发生过的：

**1. 仓颉的三引号字符串会处理反斜杠转义。**

把 HTML + JS 内联在 `"""..."""` 里时，JS 的 `\n` 会**先被仓颉吃掉**变成真换行，把 JS 字符串或单行注释拆断 → 整段 `<script>` 语法错误 → **页面里一行都不执行，而 stderr 毫无提示**。

我第一次遇到的时候，是靠对照另一个正常示例才定位的。现在的纪律是：内联 JS 里不出现反斜杠（换行用 `String.fromCharCode(10)`，正则改用 `indexOf`），改完先用 `node --check` 验一遍。

**2. WebView2 的 SDK 不能高于本机 Runtime。**

编译 C 桥用的 WebView2 SDK 必须**不高于**机器上的 WebView2 Runtime。我的机器是 Runtime 122.0.2365.106，对应 SDK 1.0.2365.46。版本反了的表现是窗口空白、导航事件不触发、`ExecuteScript` 返回 `0x8007139F`。

顺带一个相关的坑：**COM 回调对象必须自己 AddRef 持有**，否则回调返回后对象就被释放，WebView2 会立刻关掉浏览器进程——现象和上面几乎一样（窗口空白）。

**3. Git Bash 下往 PATH 里塞路径必须用 POSIX 形式。**

写 `/d/Program Files (x86)/Cangjie/...` 可以，写 `D:/...` 不行——MSYS 会把它破坏掉，而现象是**依赖仓颉运行时 DLL 的原生进程退出码 127、且没有任何输出**。这种"无声失败"最费时间，因为你看不到任何错误信息。

**4. 工具链的"假成功"。**

这条最阴：`MSYS_NO_PATHCONV=1 cmd //c run.bat selfcheck` —— `//c` 到 `/c` 的改写本身就属于 MSYS 的路径转换，被关掉之后 cmd 收到的是字面量 `//c`，于是它**只打印 banner 和提示符就 EOF 退出了，退出码 0**，批处理一行都没跑。

我是怎么看出来的？**看副作用**：日志文件的修改时间没变、`grep PASS` 数是 0。所以现在的纪律是：**判断脚本有没有真的跑，一律看副作用（日志 mtime / 行数 / 断言计数），别只看退出码。** 正确写法是二选一——`cmd //c xxx.bat`，或者 `MSYS_NO_PATHCONV=1 cmd.exe /c "xxx.bat"`。

**5. 平台差异只允许出现在两处。**

这条是架构纪律，不是 bug，但它防止了一整类 bug：**仓颉侧用 `@When` 条件编译、C 桥用 `native/bridge_*.c`，其他所有地方（IPC、能力校验、命令分发）必须跨平台共用**。所以这个打字游戏的后端代码里，一行平台判断都没有——同一份 `commands.cj` 在 Windows 和 Linux 上跑。

## 怎么跑起来

想自己玩一下，或者照这个思路做一个自己的：

```bash
# 1. 克隆（AtomGit 主仓，国内直连）
git clone https://atomgit.com/qq8864/cj-tauri.git
cd cj-tauri

# 2. 编译 C 桥
native/build_win.bat          # Windows；Linux 用 native/build_linux.sh

# 3. 编译示例
cd examples/typing-poem && cjpm build

# 4. 跑
cd /d E:\path\to\cj-tauri\examples\typing-poem
run.bat                        # 正常游玩
run.bat selfcheck              # 无人值守自检（57 条断言）
set CJ_TYPING_POEM=changgexing && run.bat   # 开窗就是《长歌行》，看长诗分栏
```

`CJ_TYPING_POEM=<诗 id>` 这个钩子是我给人眼验收留的：**长诗分栏好不好看，几何断言只能证明"放得下、不重叠"，证明不了"好看、不串行"**——所以得有个办法一开窗就是那一首，方便截图归档。

项目仓库（MIT 协议）：

- **AtomGit（主仓）**：<https://atomgit.com/qq8864/cj-tauri>
- 打字游戏示例：`examples/typing-poem`
- 同系列还有：观影应用 `examples/movie`（后台数据全由仓颉侧取）、插件示例 `examples/plugin-{fs,dialog,shell}`、多窗口与原生菜单 `examples/menu`

## 最后

一个小结，也是我做完这个应用的感受：

**cj-tauri 帮我省掉的，是"把 Web 技术搬上桌面"的全部管道。** 我不用面对 Electron 的打包体积，也不用为了一个窗口去学 Win32 或 GTK——那部分被框架和 C 桥吃掉了。我写的代码就两类：**仓颉侧的纯逻辑**（诗库、存分、门槛），和**一个 HTML 文件**（渲染、玩法）。中间那条 IPC 通道是透明的。

**而真正花时间的，是"什么对一个 8 岁孩子是友好的"这件事。** 字要多大、分栏门槛怎么定、敲错了是清零还是减半、先放礼花还是先给分数——这些没有框架能替你决定。技术选型只决定你能不能在半小时内把想法变成窗口；剩下的时间都花在打磨上。

如果这篇对你有用，或者你也想给孩子做一个练打字/练琴/练口算的小工具，欢迎去仓库看看。仓颉生态还年轻，多一个真实的应用就有多一份参考。

---

> **写作备忘（发布前删掉）**：
> - 截图待补——`docs/images/` 里目前没有本示例的截图。建议补三张：选诗面板（能看到 108 首与右侧滚动条）、
>   打字中的卡面（《长歌行》两栏、当前字金框）、结算礼花。跑 `set CJ_TYPING_POEM=changgexing && run.bat` 开窗即拍。
> - 文中的断言输出是形态示意，实际数字（用时/速度/第几次）每轮不同，发布前可跑一次 `run.bat selfcheck` 贴真实输出。
> - 链接已统一为 AtomGit。


