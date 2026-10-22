# cj-tauri

用[仓颉语言](https://cangjie-lang.cn)写桌面应用的脚手架 CLI——把 Tauri 的三件套带到仓颉：
仓颉后端（静态编译）+ 系统 WebView 前端（HTML/CSS/JS），三件套与 Tauri 一致 ——
WebView 宿主、IPC 双向桥（`invoke` / `resolve` / `event`）、能力安全模型（capability 白名单）。

- 仓库与完整文档：<https://atomgit.com/qq8864/cj-tauri>
- 当前状态：**Windows（WebView2）、Linux（WebKitGTK）与鸿蒙 PC（ArkWeb）均已实机跑通**

## 前置条件：仓颉 SDK

**这个包不替代仓颉 SDK**。应用后端就是仓颉代码，`cj-tauri dev` / `build` 要调用 SDK 里的 `cjc` / `cjpm`
把你的应用编译出来。所以请先装 SDK（验证版本 **1.2.0**，含 **stdx**），并让本包能找到它：

```bash
# Linux / macOS
export CANGJIE_HOME=/opt/cangjie/cangjie

# Windows cmd
set CANGJIE_HOME=D:\Program Files (x86)\Cangjie
```

不设 `CANGJIE_HOME` 时，本包会探测常见安装位置（Windows `D:\Program Files (x86)\Cangjie`、
Linux `/opt/cangjie/cangjie`）。装好后自检：

```bash
npx cj-tauri info        # 打印框架 / 项目 / stdx / SDK / cjpm / C 桥 的解析结果
```

没装 SDK 时本包会直接给出提示与安装说明，而不是抛一句 `cjpm: command not found`。
另外 `npx cj-tauri --version` 不需要 SDK 也能查版本。

## 用法

```bash
npx cj-tauri create myapp          # 创建项目（默认模板：内联 HTML，零 Node）
cd myapp
npx cj-tauri dev                   # 构建 C 桥 + cjpm build + 启动窗口

npx cj-tauri create myapp-vue --template vue      # Vue 3 + Vite
npx cj-tauri create myapp-react --template react  # React 18 + Vite

npx cj-tauri create myohos --template ohos        # 鸿蒙 PC（2in1）工程：ArkWeb 宿主 + build-hap.sh
npx cj-tauri create myohos --template ohos --bundle com.example.myapp --label "我的应用"

npm i -g cj-tauri                  # 也可以全局安装，之后直接用 cj-tauri <子命令>
```

| 子命令 | 作用 |
|---|---|
| `create <项目名> [--template app\|vue\|react\|ohos]` | 生成工程（桌面模板：`src/` + `ui/` + `capabilities/` + `cjpm.toml`；`ohos` 见下一节） |
| `dev` | 构建 C 桥 + `cjpm build` + 启动应用；Vite 模板会接管 dev server（HMR）；鸿蒙工程转交 `build-hap.sh` |
| `build` | 构建 C 桥 + `cjpm build`；鸿蒙工程转交 `build-hap.sh` |
| `run` | 运行已构建产物；鸿蒙工程转交 `build-hap.sh --install`（构建 + 装机 + 启动） |
| `info` | 环境自检（排障先跑它） |
| `help` | 帮助 |

## 鸿蒙 PC（`--template ohos`）

同一套框架换个宿主：桌面用 WebView2 / WebKitGTK，鸿蒙 PC 用 **ArkWeb**，上层页面、命令层、能力校验不用改。

```bash
npx cj-tauri create myohos --template ohos
cd myohos
bash build-hap.sh --install        # 构建 hap + hdc 装机 + aa start；等价于 npx cj-tauri run
```

生成的是标准 DevEco 工程（`entry/` + `AppScope/` + `build-profile.json5` + `hvigorfile.ts`），
鸿蒙相关的那层很薄：

| 路径 | 作用 |
|---|---|
| `entry/src/main/cangjie/main_ability.cj` | UIAbility：`ArkWebRuntime.configure(filesDir)` → 非 UI 线程 `spawn { run() }` → 等宿主登记再 `loadContent` |
| `entry/src/main/cangjie/index.cj` | `@Component` 的 ArkWeb 宿主 + 双向桥（**必须住应用模块**，框架包引用 ArkUI 会启动即崩） |
| `entry/src/main/resources/rawfile/` | `index.html`（页面真文件）与 `capabilities.json`（能力清单） |
| `build-hap.sh` | 唯一构建入口：探测 DevEco / stdx、`--no-daemon` 跑 hvigor、可选 `--install` |

前置两件事：

- **DevEco Studio 6.1**（含仓颉插件）+ 已配好签名。`build-hap.sh` 用 `DEVECO_WIN` 找安装根
  （默认 `D:\oh\DevEcoStudio`），用 `CANGJIE_STDX_OHOS` 找鸿蒙版 stdx 动态库；两者给不出时脚本会直接说清楚缺哪个。
- 真机开着**开发者模式 + USB 调试**，`hdc` 能列到设备；`aa start` 需要**屏幕已解锁**。

工程默认是桌面形态：`module.json5` 的 `deviceTypes` 写 `2in1`，并在 `entry/build-profile.json5` 里
`cangjieOptions.checkDeviceTypes = false`（插件默认只放行 `phone` / `tablet`，写 `2in1` 会判 `01103012`）；
窗口**不干预尺寸**，沿用系统给的默认矩形（实测本机 `2090×1394`，约屏宽 2/3 且居中）。

已知限制：签名要在 DevEco 里配（命令行不做自动签名，换 `bundleName` 需重新签）；同一份调试签名下两个
工程会互相顶掉安装位；单窗口、暂无原生对话框（那两条能力位如实返回 0）；没有可用的 C 桥，
`launchHidden` / 串口 / 托盘这类宿主能力在鸿蒙上不提供。

真机上怎么自证它通了（hilog，`CjTauri` tag）：

```
host registered after N polls label=main
host pageUrl label=main url="file:///.../files/cj-tauri-main.html"
page begin label=main
main window keeps system default 2090x1394 px at density 190% on screen 3120x2080
```

## 这个包装层做了什么

- **跨平台入口**：Windows / Linux / Git Bash 都是同一条 `cj-tauri` 命令，不再分 `.bat` 与 `.sh`；
- **环境自检**：`cjpm` 与 SDK 运行时库的定位、`PATH` / `LD_LIBRARY_PATH` 的拼装都在这里完成；
- **CLI 本体的获取**：优先用包内预编译二进制（`prebuilt/<平台-架构>/`），没有则把 CLI 源码拷到
  `~/.cache/cj-tauri/<版本>/` 下用本机 `cjpm build` 一次并缓存 —— 不往安装目录写产物，避免全局安装只读；
- **数据目录**：Linux/macOS 用 `$XDG_CACHE_HOME/cj-tauri`（默认 `~/.cache/cj-tauri`），Windows 用 `%LOCALAPPDATA%\cj-tauri`。

已知限制：首次 `dev` / `build` 会把 C 桥构建到**框架目录的 `native/`** 下（应用 `cjpm.toml` 的
链接参数指向那里），所以包安装目录需要可写；如果装在只读路径下，请改用仓库内运行方式。

## License

[MIT](https://atomgit.com/qq8864/cj-tauri/blob/main/LICENSE) © 2026 yangyongzhen
