# 把「仓颉爱音乐」搬到鸿蒙 PC：业务代码一行没改，换掉的是宿主

> 这是 `examples/music` 的鸿蒙 PC 版（`examples/ohos/ohos-music`）。设备是华为 MateBook Pro（HAD-W32 /
> HarmonyOS 7.0.0.107 / API 26 / aarch64，3120×2080 px），工具链用 DevEco 6.1 的仓颉插件。
> 结论放前面：**业务代码零改动**（`examples/music/src` 一个字没动），改的全部是「谁在跑页面」这件事——
> 桌面用 WebView2 / WebKitGTK，鸿蒙用 ArkWeb 组件。

![仓颉爱音乐在鸿蒙 PC：三栏铺开，底部播放条常驻](images/example-ohos-music.jpg)

## 目标：证明「框架」不是替某个平台定制的

我先给自己定的验收标准很克制，但都是页面自证、不看退出码：

1. 窗口是**桌面形态**（能拉宽、三栏并排），不是手机兼容窗；
2. 热门歌曲与后台歌单真的从后端拉到了（不是空列表 + 错误 toast）；
3. 播放进度在走（有具体时刻，比如 00:17 / 03:42）；
4. 页面和命令层是 `examples/music` 那一份，没有为鸿蒙另抄一套。

第 4 条是这次真正的实验点。如果为了跑上鸿蒙要维护两份业务代码，那这个框架的「跨平台」就是假的。

## 业务代码只留一份：构建时同步 + 改包名

鸿蒙工程里没有 `ui/`、也没有业务 `.cj`——`musiclib/` 是**生成物、不入库**。每次 `bash build-hap.sh`
会做两件事：

```
examples/music/src/*.cj（去掉 main.cj）
        └─ 复制到 entry/src/main/cangjie/musiclib/
            └─ 只改第一行：package music_app → package ohos_app_cangjie_entry.musiclib

examples/music/ui/index.html + capabilities/default.json
        └─ base64 编码 → musiclib/ohos_assets.cj（编译进包的字符串常量）
```

于是「谁是源」很清楚：**改业务逻辑去改 `examples/music`，改完重跑 `build-hap.sh`**（`--no-sync` 可跳过同步）。
生成物这条路不是偷懒，是因为另一种写法没验证过：

```toml
# 不这么写：music 的模块是 output-type = "executable"、自带 main()，
# 把它当依赖编进动态模块（鸿蒙侧是 dynamic）属于没跑通过的形态
music = { path = "../../../../music" }
```

entry 只依赖框架源码（`cjTauri`），业务作为「同包内的副本」参与编译——和之前探针工程跑通的构建链完全一致。

顺带一个便宜的好处：页面走 **base64 内嵌**，绕开了仓颉三引号字符串会把 JS 里的反斜杠转义先吃一遍那个坑
（内联 JS 里写 `\n` 会变成真换行，把字符串或单行注释拆断，整段 `<script>` 语法错误、页面一行都不执行，
而 stderr 毫无提示）。这条路我在别的示例上付过一次学费。

## UIAbility 只做三件事

鸿蒙上没有「自己起个进程跑 `main()`」这回事：窗口属于 ArkUI，页面由 ArkWeb 组件承载。
所以 `main_ability.cj` 很薄，三件事，顺序不能错：

```cangjie
// 1) 沙箱目录必须在 run() 之前给：run(html) 要把内联页面落盘再以 file:// 加载
let filesDir = "${this.context.filesDir}"
ArkWebRuntime.configure(filesDir)
configureMusicRuntime(filesDir)     // 收藏库也改落沙箱

// 2) run() 阻塞到 quit，只能在非 UI 线程跑——UI 线程要留给 ArkUI 建树
let _ = spawn { startTauriMusic() }
```

第三件在 `onWindowStageCreate` 里：**等框架把默认窗口的宿主登记上，再 `loadContent`**。
这一步是白屏那一轮的结论——组件的 `build()` 是一次性求值，页面地址为空就永远不建 `Web`；
我给的是 3 秒有界等待，等不到也照常 `loadContent`，让页面自己报「桥缺失」，比静默白屏好查。

## 两个「不这么写就是错」的配置

这两条都属于「报错指向的地方不是真因」，所以列出来比讲原理有用：

**① `deviceTypes` 必须写 `2in1`。** 只写 `phone` / `tablet` 时，系统把它当手机应用，给一扇约 600 宽的
竖屏兼容窗，歌单和播放器挤成一列。但仓颉构建插件默认把 `deviceTypes` 限死成 `phone` / `tablet`，
写 `2in1` 直接判 `01103012`。放行开关在 `entry/build-profile.json5`：

```json5
"cangjieOptions": { "path": "./cjpm.toml", "checkDeviceTypes": false }
```

**② `ohos.permission.INTERNET`。** 缺了它，每次请求都死成
`SocketException: Failed to create socket: Operation not permitted.`，而页面上显示的是自家的文案
「歌单拉取失败：连不上后台接口」——**看着像断网、像后端挂了**，实际是权限。这条是 `normal` 级，
安装即生效、不弹窗。判据很干净：同一份 hap 只差这一项，截图从「全空 + 错误 toast」变成「歌单 6 张 + 封面加载」。

## 真机上的样子

解压安装、`aa start` 之后，hilog 里（`CjMusic` tag）该有这条链：

```
MainAbility OnCreated.MainAbility
host registered after N polls label=main
host pageUrl label=main url="file:///data/storage/el2/base/haps/entry/files/cj-tauri-main.html"
page begin label=main
main window keeps system default 2090x1394 px at density 190% on screen 3120x2080, rect=[515 281 2090 1394]
```

窗口那行现在是 `2090×1394`——**系统按桌面形态给的默认值**。这里我走过两轮弯路（第一版 `resize(1440, 900)`
只占屏宽 46%，第二版按逻辑 vp × 密度在开窗瞬间跳一下），最后裁定「不干预窗口」，细节写在另一篇里。
早期版本这里打的是 `2683x1747`，那个数已经不用了。

页面侧的自证：三栏、热门歌曲与后台歌单都出来了、封面在加载，播放进度停在某个具体时刻——这四条对上，
才算这个示例真的通了，而不是「窗口起来了」。

## 已知限制（如实记）

- **与 `ohos-movie` 共用 `bundleName`（`com.yang.testcj`）**：两个工程复用同一份调试签名，所以
  **装那个会顶掉这个**，一台设备上只能留一个。换 `bundleName` 要在 DevEco 里重新自动签名，命令行做不了，这步我没做。
- **`music:quit` 在设备上不退出进程**：它只置框架的退出意图，鸿蒙侧进程生命周期归系统管，页面侧看起来是「已退出」。
  真要退用 `hdc shell aa force-stop com.yang.testcj`。
- **收藏与配置落沙箱**：`<filesDir>/music-library.local.json`（桌面版是工程根的相对路径），卸载即清。
- **`aa start` 需要屏幕已解锁**：开发者模式下没法自动解锁，锁屏时表现为启动失败，或者抓到一张锁屏截图。
- **单窗口**：一扇窗、无原生对话框；多窗口与弹窗的取证留在 `examples/ohos-probe`。

## 一句总结

这个示例最有价值的地方不是「跑起来了」，而是**业务代码一行没改**。宿主换了一整套（ArkWeb），
上层的命令层、能力校验、IPC 分发还是同一份——这才是我当初做这个框架想要的形状。

下一篇写观影示例：它在鸿蒙上撞到一个更硬的东西——仓颉运行时在设备上装不了 TLS。
