# 仓颉版 Tauri：给鸿蒙铺一条 Web 开发者的路

> 一个从"可行性报告"到"能跑的 Demo"的实践记录与思考
>
> 2026-08-21

---

## 一、为什么我要做这件事

先交代一下背景。华为仓颉语言 2025 年 7 月发布了 1.0.0 LTS，月底在 GitCode 开源——编译器、运行时、标准库全给了。鸿蒙官方把它和 ArkTS、C/C++ 并列为三大开发语言。语言本身没什么可怀疑的：静态类型、多后端编译、性能和安全的设计取向都很现代。

但有一个很现实的问题：**鸿蒙原生应用的开发者从哪里来？**

存量 App 不会因为鸿蒙上线就自动长出 ArkTS 版本。指望全球开发者用 ArkTS 从头重写一遍应用，不现实。华为也清楚这一点，所以 HDC 2025 上把 RN、Flutter、KMP、Cordova 的鸿蒙适配成果挨个点名——官方态度很明确：**拉拢存量开发者，尤其是 Web 开发者**，是生态战略的一部分。

而 Web 开发者要什么？说白了就是"我写 HTML/CSS/JS，你负责让它变成原生应用，别让我学一套全新的东西"。这个诉求，Tauri 模式正好完美命中：**系统 WebView 渲染前端，编译型语言做后端**。前端还是那套 Web 技术栈，后端拿到的是原生性能和内存安全。

Tauri 用 Rust 做到了"体积小于 600KB、启动快、默认最小权限"三个卖点。仓颉的语言定位——高性能、强安全、静态编译——跟 Rust 几乎是同一个生态位。那么问题就变成了：

> 用仓颉能不能复刻一个 Tauri？

我的结论是：能，而且不只是"理论上能"。这篇文章记录我实际把它跑起来的全过程，包括踩的那个大坑。

## 二、生态意义：为什么这件事值得做

### 1. 供给侧有个真实的缺口

鸿蒙原生应用数量相比 Android/iOS 还是洼地，华为正拿激励计划补。但补的数量靠什么？靠开发者。而海量 Web/前端开发者恰恰是最容易被"低门槛方案"转化的群体。

仓颉版 Tauri 就是给这批人铺路：**前端写 UI、仓颉写后端，一天上手鸿蒙**。这不是画饼——Capacitor（JS 后端）和 Tauri（Rust 后端）双双被 Eclipse 基金会移植到了 OpenHarmony，就发生在 2026 年 4 月。Eclipse 用真实项目证明了两件事：

- 鸿蒙系 OS 上"WebView + 原生后端"的完整链路**已经被打通**；
- 官方对"借 Web 技术做鸿蒙应用"的态度是**生态战略，不是野路子**。

### 2. 差异化价值正好卡在鸿蒙最需要的地方

对比几条路线：

- **Electron 式**：捆绑 Chromium，体积 10MB 起步——政企类应用（金融、办公、政务）对体积和启动速度敏感，这条路在鸿蒙上走不通；
- **Capacitor/Cordova 式**：JS 后端，开发快但性能上限低；
- **仓颉版 Tauri**：系统 WebView + 仓颉原生后端——**体积小、启动快、权限安全**三个卖点，恰好是鸿蒙企业级应用最看重的三点。

### 3. 卡位价值：谁先做，谁定义范式

仓颉的 UI 生态刚起步，App 框架几乎是空白。Tauri 从 2019 年走到 30k+ star 的路径就是参照系——**"框架 + 脚手架 + 插件体系"谁先做出来，谁就定义了仓颉的应用开发范式**。这是典型的生态卡位机会，窗口期不会太长。

### 4. 复用成本低，不需要发明架构

Tauri 的 capability 权限模型、IPC 协议、资源打包方案，全是成熟设计，直接平移即可。省下的是"想清楚怎么做"，花的是"按鸿蒙/仓颉特性落地"。我这次落地最大的体会就是：**架构完全不用发明，难的是平台细节**——具体是什么细节，下面讲。

## 三、实现方案：复刻 Tauri 三件套

Tauri 不是"浏览器套壳"，它的架构由三块拼成。仓颉版逐块对应：

### 第一块：WebView 宿主（对标 WRY + TAO）

- **Linux 桌面**：webkit2gtk-4.1，仓颉 C FFI 直绑；
- **鸿蒙**：官方 `arkweb_cangjie_wrapper`（ArkWeb 的仓颉封装，WebviewController 等全是 .cj 实现）——鸿蒙版连窗口都不用自己造，ArkUI 就是现成的窗口宿主层。

我的做法是定义统一的 `WebViewHost` 接口，Linux 实现一套，鸿蒙将来实现同一接口接入，上层完全无感。

### 第二块：IPC 消息桥（invoke / event）

协议用 JSON over postMessage，与 WRY 同构：

```json
// JS → 仓颉（invoke）
{"type":"invoke","id":1,"cmd":"greet","args":{"name":"world"}}
// 仓颉 → JS（resolve）
{"type":"resolve","id":1,"ok":true,"data":"hello world"}
// 仓颉 → JS（事件推送）
{"type":"event","event":"tick","payload":{"n":1}}
```

前端注入一个 `window.__CJ_TAURI__` 桥（对标 @tauri-apps/api），提供 `invoke/listen/emit` 三个 API。前端用起来跟 Tauri 一模一样：

```js
const tauri = window.__CJ_TAURI__;
tauri.invoke('greet', { name: '仓颉' }).then(d => console.log(d));
tauri.listen('tick', p => console.log(p));
```

### 第三块：能力安全模型（对标 capability）

这是"套壳"与"框架"的分水岭。capability 清单声明应用能用哪些命令、收哪些事件：

```json
{
  "identifier": "default",
  "windows": ["main"],
  "commands": ["greet", "system:version", "system:ping"],
  "events": ["tick"]
}
```

**未声明的一律拒绝**，默认最小权限。IPC 分发前先过校验层，越权直接返回 `command not allowed`。校验层独立于宿主实现——鸿蒙 ArkWeb 后端复用同一套，安全语义跨端一致。

## 四、踩的那个大坑：仓颉的"协程栈"差点让 WebKit 崩掉

这是本次实现最值得记录的部分，因为它在任何文档里都查不到，只能自己踩出来。

现象是：仓颉程序里创建 WebView、执行 JS，**必崩**，SIGABRT，堆栈指向 WebKit 的 `JSC::sanitizeStackForVM`——JSC 在"校验当前线程栈是否合法"。

一开始我以为是 webkit2gtk 绑定写错了，反复排查。直到我用探针打出了关键数据：

```
C 探针: pthread 栈 base=0x7ffd... size=8MB
仓颉 main 内实际 SP = 0x770f...   ← 不在 pthread 栈范围内！
```

真相浮出水面：**仓颉的线程是 M:N 用户态轻量级线程模型，连 `main` 都跑在堆上分配的协程栈里**。JSC 用自己的线程栈边界去校验当前栈指针，发现 SP 压根不在栈内，判定"栈已损坏"，直接 abort。

这个坑有多隐蔽？纯 C 程序调 webkit 完全正常，C 程序 dlopen 仓颉运行时再调 webkit 也正常——只有"由仓颉运行时启动"的进程才崩。区别就在于：仓颉运行时启动时把主线程执行切到了协程栈上。

解法很朴素：**GTK/WebKit 的全部调用搬到一个 C 桥创建的原生 pthread 里**（标准 8MB 栈，SP 合法），仓颉侧经 FFI 调用，消息回调再经函数指针回到仓颉。改完之后，一路通畅。

```c
// C 桥：原生线程里跑 GTK 主循环
void *gtk_thread_main(void *arg) {
    gtk_init(NULL, NULL);
    // ... 建窗口、建 WebView、注入桥、跑 gtk_main
}
void cj_bridge_start(const char *html) {
    pthread_create(&t, NULL, gtk_thread_main, NULL);
}
```

这个坑也顺带解释了一个现象：社区那个 `webview-sdk`（仓颉绑 webview）只在 Mac/Windows 上给了预编译库，**Linux 缺失**——大概率就是撞上了同一个问题。所以这件事，**Linux 桌面版是仓颉 WebView 路上最需要先趟平的一段**。

## 五、跑起来的效果

Demo 应用（Tauri 官方 hello-world 的仓颉版）在 Linux + WebKitGTK 上真实运行，端到端验证全绿：

| 验证项 | 结果 |
|---|---|
| `invoke("greet")` JS → 仓颉 → JS | ✅ `Hello, 仓颉! 来自仓颉后端` |
| 内置命令 `system:ping` | ✅ `pong` |
| capability 越权 `system:rm` | ✅ 拒绝 `command not allowed` |
| 未注册命令 | ✅ 拒绝 |
| 事件推送 `tick`（仓颉 → JS） | ✅ 持续到达，前端实时刷新 |
| UI 渲染 | ✅ 窗口真实显示（截图确认） |
| 脚手架 `cj-tauri create` | ✅ 生成新项目可独立构建运行 |

## 六、路线：先鸿蒙，再跨端

报告里我建议的里程碑是：**先鸿蒙单端跑通 MVP，再做桌面端，最后铺插件生态**。这次实际落地的是桌面端（因为本机就是 Linux），反而把"最硬的那块骨头"先啃了——Linux 的协程栈坑、C 桥架构、IPC 时序，这些经验对鸿蒙版是直接可复用的资产。

接下来的路：

- **P1**：鸿蒙 ArkWeb 后端（`WebViewHost` 接口已留好，接入 `arkweb_cangjie_wrapper`），capability 文件自动加载，窗口配置化；
- **P2**：Windows/macOS WebView 后端，依托仓颉 `os/backend` 条件编译做平台差异；
- **P3**：插件体系 + React/Vue 官方模板——让社区能"插电"，这是生态起飞的开关。

## 七、一点私心话

说实话，做这件事之前我也有过犹豫：仓颉才发布一年，生态太新，文档赶不上 ArkTS，三方库少，第一批吃螃蟹的人注定要自己趟坑。

但做完这个 Demo 我反而更确定了：**生态缺的不是语言能力，是"样板"**。Eclipse 移植 Tauri 到 OpenHarmony 用了"Vibe Coding"几周搞定，社区 `webview-sdk` 已经证明了 bind/Result 雏形可行——大家都看到了路，缺的是有人把这条路按 Tauri 的完整架构走一遍，把坑标出来。

这篇文档和同目录的《技术方案》《踩坑与实施记录》，就是想把"怎么走"和"坑在哪"都留下来。如果你也在做仓颉相关的框架，欢迎来对答案。

---

*相关文档：`技术方案.md`（架构设计）、`踩坑与实施记录.md`（协程栈坑与全部工程细节）、`README.md`（框架使用）。*
