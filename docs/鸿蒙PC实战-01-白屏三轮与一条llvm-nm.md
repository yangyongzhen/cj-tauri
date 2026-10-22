# 第一次把 cj-tauri 应用跑进鸿蒙 PC：白屏三轮，最后是一条 llvm-nm 定的案

> 设备：华为 MateBook Pro（HAD-W32）、HarmonyOS 7.0.0.107、API 26、aarch64，屏幕 3120×2080 px、
> 密度 190%。工具链是 DevEco Studio 6.1 自带的仓颉插件，hdc 串号 `3QC0124B20000048`。
> 框架：[cj-tauri](https://atomgit.com/qq8864/cj-tauri)，同一个页面在 Windows（WebView2）和
> Linux（WebKitGTK）上已经跑了大半年。
> 下面这轮的完整证据链留在 `docs/鸿蒙ArkWeb接入踩坑.md`，这篇只讲我自己的那份「本来以为」是怎么被推翻的。

## 起因：我以为最难的会是 ArkWeb

仓库里那个音乐播放器示例，Windows 和 Linux 都是三栏布局、能放歌、歌词跟着走。我想把它搬到这台
鸿蒙笔记本上，心里排的难度顺序是：ArkWeb 的 `Web` 组件怎么用 > 仓颉怎么跟 JS 双向通信 >
工程怎么编成 hap。C 桥、运行时、包管理这些「已经有了」的东西，我根本没排进风险清单。

结果正好反过来了：ArkWeb 那部分是最顺的，真正让我白走一晚上的，是一条符号表。

![跑起来的 ohos-music：三栏桌面布局，歌单与播放器都在](images/example-ohos-music.jpg)

## 第一轮白屏：应用启动即退，hilog 里连一行 `onCreate` 都没有

第一次装上去点图标，屏幕黑一下就没了。我先跑的是 hdc 的 hilog，看到的是这个：

```
exit with signal:11
```

仓颉运行时自己的 `CANGJIE-RUNTIME` 那几行照常打印，但**我自己的 `AbilityStage.onCreate` 一行都没有**。
于是我开始往「生命周期」上想，那晚白走了三轮：

1. **以为 ability 生命周期卡死了。** 在 `onCreate` 里加日志，日志没出来——看起来像「根本没进生命周期」，
   其实是那行日志所在的模块加载期就已经死了。
2. **以为运行时模块初始化死锁。** 鸿蒙侧的仓颉运行时会把模块的初始化链拉一遍，我猜是静态包硬链进
   动态根包导致 `init` 卡住。改了几次依赖写法，结论没变。
3. **以为 stdx 重复链接。** 把 stdx 的引入方式来回换，一样。

三条判断的共同毛病是：**我一直在看运行期日志，而这次失败发生在「日志能力本身可能不在了」的地方。**

### 判据：不要看日志，看符号

后来我把排查顺序倒过来，先问一句「这个模块里有没有解析不了的符号」，一条命令出结果：

```bash
llvm-nm -D --undefined-only entry/build/default/intermediates/libs/default/arm64-v8a/libentry.so | grep cj_bridge
```

**必须是 0 行。** 当时不是 0 行。

根因很简单，但很反直觉：`src/log_bridge.cj` 是**故意不写 `@When`** 的——桌面两个平台导出同名符号、
实现只有 `native/core/bridge_core.c` 一份，所以这文件打一开始就没打算做平台分叉。可鸿蒙侧**没有 C 桥产物**，
那三个 `foreign func` 在模块里是 `U`，模块加载期直接 SIGSEGV。地址看着像野指针而不是空指针，
这也是我当时没往「符号缺失」上想的原因。

### 修法：没有桥就如实降级，别假装成功

给 FFI 声明与薄包装加**同一口径**的平台门禁，再给无桥平台写一份如实的降级：

```cangjie
@When[env != "ohos"]
foreign func cj_bridge_set_log_file(path: CString): Int32

// 无桥平台：不写文件日志，但要留一行 stderr，别静默
@When[env == "ohos"]
func enableLogFile(path: String): Bool {
    eprintln("[cj-tauri] file logging is not available on this platform")
    return false
}
```

两块必须同时改：只给 `foreign func` 加 `@When`、不给调用方加，编译期直接报未声明；反过来只改调用方，
链接期还是那个 `U`。改完同一条 `14 llvm-nm ... | grep cj_bridge` 变成 0 行，`MyAbilityStage onCreated`
重新出现在 hilog 里。

顺带记住两条判断口径，它们比任何日志都直接：

- 鸿蒙的 `os` 取值**就是 `"Linux"`**，`arch` 也不能用（桌面 aarch64 Linux 一样是 aarch64）。
  平台判据只认 **`env`**：`aarch64-linux-ohos` → `ohos`，桌面 → `gnu`。所以框架里一律写
  `@When[env == "ohos"]` / `@When[env != "ohos"]`。
- 同族风险面：`src/clipboard_bridge.cj` 以及任何「谁调用谁包内」的核心 FFI。新增之前先问一句
  **「这个平台有桥吗」**。

## 第二轮白屏：窗口起来了，页面纯白

符号修完，应用能起来了、窗口也在，但页面全白。这次 hilog 里有意思了：

```
BindWebTagToWebInstance webTag:arkweb:0
```

`Web` 组件**确实建过**，但 `page begin` / `page end` 一条都没有。

真因是声明式 UI 的一个求值时机问题：`@Component` 的 `build()` 是**一次性求值**，而宿主把内联页面落盘后的
`file://` 地址只存在宿主对象上，组件自己那个字段初值是空串。于是首帧 `if (pageUrl.size > 0)` 不成立 →
不建 `Web` → `onPageBegin` 永远不来 → 而我原设计的「地址同步点」恰好就写在 `onPageBegin` 里。
**死锁，页面永远白屏。**

修法是把同步点前移到 `aboutToAppear()`（首次 `build()` 之前跑一次）：

```cangjie
@State var pageUrl: String = ""      // 注意：@State 不允许带 private / public，带了直接编译失败

protected func aboutToAppear(): Unit {
    pageUrl = host.currentUrl()      // 宿主落盘后的 file:///.../cj-tauri-main.html
    Hilog.info(1, "CjTauri", "host pageUrl label=main url=${pageUrl}")
}
```

`@State` 只在**组件自己赋值**时触发重绘；宿主在别的线程改它自己的字段，组件永远读到旧值——这条我踩了一次才服。

## 第三轮：页面出来了，命令没反应

到这一步页面渲染正常，但点 `system:version` 一直显示 `-`：promise 既不 resolve 也不 reject。

先在页面里绕过桥做三个探针，把嫌疑排掉：

```js
typeof window.__CJ_TAURI_HOST__                 // object
typeof window.__CJ_TAURI_HOST__.post            // function
try { window.__CJ_TAURI_HOST__.post('{...}') }  // 同步调用成功
```

三项都正常，说明注入通道好、`post` 也好。那问题只能在「回投」这一侧。桌面版用的是「页面定时 `poll()`
取回待执行脚本」的泵，鸿蒙侧我照搬了，结果是 `poll -> null`。

隔离实验很干脆：把 `funcList` 里的 `poll` 换成**无条件返回固定串**的实现，不看框架、只改应用侧那一行——

```cangjie
funcList: [ { _ => "poll-probe" } ]   // 页面拿到的仍然是 null
```

**仓颉侧 `funcList` 的返回值根本回不到 JS。** 参数能进去、`methodList` 枚举顺序也对、方法都调得到，
就是返回值恒为 `null`。所以「页面拉、原生答」这种同步取数模型在鸿蒙侧不成立。

改成反过来由原生推，链路就通了：页面 `setInterval` 发一条 `{"type":"pull"}` 心跳 → 宿主识别后**直接 return**、
不进 IPC 分发 → 应用侧 proxy 回调（本来就在 UI 线程）取队列里的待执行脚本，用 `controller.runJavaScript` 推出去。
`runJavaScript` 本身是通的，日志里有 `runJavaScript ok`。

## 两条便宜的教训

- **`eprintln` 在设备上完全不可见。** 框架里 stderr 是主要的诊断通道，在鸿蒙上等于没有——诊断一律写 hilog。
- **一次性 `hilog -x` 会把启动瞬间那几行滚掉。** `hilog -r` 清缓冲 → 启动 → 等十几秒 → `hilog -x`，
  中间系统日志能刷三千多行，我们那 5～10 行直接被挤出环形缓冲。判据很怪：`ps` 里进程活着，但 `Cangjie`
  tag 计数是 0。取证一律**流式**：先起 `hdc shell hilog > f`，再启动应用，跑完再 grep 文件。

## 现在正常启动的标记链

跑通之后我把这条链当成验收标准，八行，缺哪行就知道断在哪：

```
MyAbilityStage onCreated
host registered after 0 polls label=main
host pageUrl label=main url="file:///data/storage/el2/base/haps/entry/files/cj-tauri-main.html"
page begin label=main
runJavaScript ok
```

## 结语

回头看，这轮最贵的一课不是「ArkWeb 怎么用」，而是**排错顺序**：当失败可能发生在「诊断能力本身失效」的
位置时（无桥平台的 FFI、加载期崩溃、日志被滚掉），先取一条不问运行期的证据——这次是符号表，
比任何一行日志都快。

下一篇写窗口尺寸：我为了让窗口「正常点」，连续两版都把系统给的合适默认值改坏了。

![同一套框架、同一份页面，搬到鸿蒙 PC 的观影示例](images/example-ohos-movie.jpg)
