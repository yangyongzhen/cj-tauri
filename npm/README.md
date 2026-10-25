# cj-tauri

用[仓颉语言](https://cangjie-lang.cn)写桌面应用的脚手架 CLI——把 Tauri 的三件套带到仓颉：
仓颉后端（静态编译）+ 系统 WebView 前端（HTML/CSS/JS），三件套与 Tauri 一致 ——
WebView 宿主、IPC 双向桥（`invoke` / `resolve` / `event`）、能力安全模型（capability 白名单）。

- 仓库与完整文档：<https://atomgit.com/qq8864/cj-tauri>
- 当前版本：**2.1.0**（本版新增：单窗口多 WebView 内嵌视图与 ai-chat 网页版标签页、`fs:mkdir/rename/copy/stat` 四条命令、
  `http` / `sqlite` / `serial` 鸿蒙落地（真机取证）、`system:host` 补通知能力位；详见 CHANGELOG）
- 当前状态：**Windows（WebView2）、Linux（WebKitGTK）与鸿蒙 PC（ArkWeb）均已实机跑通**，
  鸿蒙侧菜单能力位与 fs/mqtt/redis/sqlite/store/http 真机取证通过

## 前置条件：仓颉 SDK

**这个包不替代仓颉 SDK**。应用后端就是仓颉代码，`cj-tauri dev` / `build` 要调用 SDK 里的 `cjc` / `cjpm`
把你的应用编译出来。所以请先装 SDK（验证版本 **1.2.0**，含 **stdx**），并让本包能找到它：

```bash
# Linux
export CANGJIE_HOME=/opt/cangjie/cangjie

# Windows cmd
set CANGJIE_HOME=D:\Program Files (x86)\Cangjie
```

不设 `CANGJIE_HOME` 时，本包会探测常见安装位置（Windows `D:\Program Files (x86)\Cangjie`、
Linux `/opt/cangjie/cangjie`）。另外两个变量视情况给：

| 变量 | 什么时候需要 |
|---|---|
| `CJ_TAURI_ROOT` | 不在 cj-tauri 仓库内运行、又找不到框架根目录时（`create` 要把框架路径写进工程） |
| `CANGJIE_STDX` | 应用的 `cjpm.toml` 用 `${CANGJIE_STDX}` 展开 stdx 路径；本包会从框架/工程的 toml 里探测，探不到就照此变量 |
| `CANGJIE_STDX_OHOS` | 只在构建鸿蒙工程时用（鸿蒙版 stdx，`build-hap.sh` 按它找动态库） |

装好后自检：

```bash
npx cj-tauri info        # 打印框架 / 项目 / stdx / SDK / cjpm / C 桥 的解析结果
```

没装 SDK 时本包会直接给出提示与安装说明，而不是抛一句 `cjpm: command not found`。
另外 `npx cj-tauri --version` 不需要 SDK 也能查版本。

## 用法

```bash
npx cj-tauri create myapp --template app     # 内联 HTML，零 Node（缺省模板）
cd myapp
npx cj-tauri sync                            # 按清单派生 targets/ 骨架（首次；重跑幂等）
npx cj-tauri dev                             # 构建 C 桥 + cjpm build + 启动窗口

npx cj-tauri create myapp-vue --template vue      # Vue 3 + Vite（前端工程在 assets/ui/）
npx cj-tauri create myapp-react --template react  # React 18 + Vite

npx cj-tauri create myohos --template ohos        # 鸿蒙 PC：同一份业务代码 + targets/ohos
npx cj-tauri create myohos --template ohos --bundle com.example.myapp --label "我的应用"

npm i -g cj-tauri                  # 也可以全局安装，之后直接用 cj-tauri <子命令>
```

**一份业务代码，骨架按目标派生**——`create` 只生成清单与业务侧，平台骨架是 `sync` 的产物：

```
myapp/
├── cj-tauri.toml           # 应用清单——单一真相（id/version/窗口/资产/能力目录）
├── cjpm.toml               # 业务包（static 库；骨架以 path 依赖引用）
├── src/main.cj             # 业务装配点 build(): AppSpec（零平台知识）
├── assets/
│   ├── ui/index.html       # 前端页面（任意 Web 技术栈）
│   └── capabilities/default.json   # 能力白名单（命令 / 事件 / 权限集）
└── targets/                # cj-tauri sync 生成（勿手改；check 判漂移）
    ├── desktop/            #   桌面可执行（launcher 调 build()）
    └── ohos/               #   鸿蒙 hap 工程（DevEco + build-hap.sh）
```

| 子命令 | 作用 |
|---|---|
| `create <项目名> [--template app\|vue\|react\|ohos]` | 生成统一工程（清单 + `src/` + `assets/`）；`--bundle` / `--label` 只对 `ohos` 模板有意义，缺省由项目名推导 |
| `sync [desktop\|ohos]` | 按清单派生 `targets/` 骨架（缺省两端都派生；幂等重跑） |
| `dev` | 构建 C 桥 + `cjpm build` + 启动应用；Vite 模板会接管 dev server（HMR） |
| `build` | 构建 C 桥 + `cjpm build`；鸿蒙端在 `targets/ohos` 里 `bash build-hap.sh` |
| `run` | 运行已构建产物；鸿蒙端 `bash build-hap.sh --install`（构建 + 装机 + 拉起） |
| `check` | 校验 `cj-tauri.toml`（id / 窗口 / 资产存在）+ `targets/` 骨架漂移 + 插件三方比对 |
| `info [--json]` | 环境自检（排障先跑它）；`--json` 只输出插件清单，机器可读 |
| `doctor` | 环境自检逐行给结论（每条自带「缺了就怎么办」） |
| `help` | 帮助 |

## 鸿蒙 PC（`--template ohos`）

同一套框架换个宿主：桌面用 WebView2 / WebKitGTK，鸿蒙 PC 用 **ArkWeb**，上层页面、命令层、能力校验不用改。
`--template ohos` 生成的仍是那种**统一工程**（`cj-tauri.toml` + `src/` + `assets/`），只是清单里带鸿蒙端信息
（`[app] id` 就是 `bundleName`）；DevEco 工程是 `sync` 的产物，落在 `targets/ohos/`：

```bash
npx cj-tauri create myohos --template ohos --bundle com.example.myapp --label "我的应用"
cd myohos
npx cj-tauri sync ohos             # 派生 targets/ohos（DevEco 骨架 + rawfile 里的页面与能力清单）
cd targets/ohos
bash build-hap.sh --install        # 构建 hap + hdc 装机 + aa start
```

`targets/ohos/` 是标准 DevEco 工程（`entry/` + `AppScope/` + `build-profile.json5` + `hvigorfile.ts`），
鸿蒙相关的那层很薄：

| 路径 | 作用 |
|---|---|
| `entry/src/main/cangjie/main_ability.cj` | UIAbility：`ArkWebRuntime.configure(filesDir)` → 非 UI 线程 `spawn { run() }` → 等宿主登记再 `loadContent` |
| `entry/src/main/cangjie/app_host.cj` | `@Component` 的 ArkWeb 宿主 + 双向桥（**必须住应用模块**，框架包引用 ArkUI 会启动即崩）；调你 `assets/` 里那份业务 `build()` |
| `entry/src/main/resources/rawfile/` | `index.html` 与能力清单（从 `assets/` 拷进来的真文件） |
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
`launchHidden` / 串口 / 托盘这类宿主能力在鸿蒙上不提供。改完 `assets/` 里的页面或能力清单要重跑
`cj-tauri sync ohos`（`targets/` 是生成物，`check` 会报漂移）。

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
- **数据目录**：Linux 用 `$XDG_CACHE_HOME/cj-tauri`（默认 `~/.cache/cj-tauri`），Windows 用 `%LOCALAPPDATA%\cj-tauri`。

已知限制：首次 `dev` / `build` 会把 C 桥构建到**框架目录的 `native/`** 下（应用 `cjpm.toml` 的
链接参数指向那里），所以包安装目录需要可写；如果装在只读路径下，请改用仓库内运行方式。

## 2.1.0 变更

- **新增**：单窗口多 WebView 内嵌视图（`webview:*`，一个窗口内挂多个页面视图、LRU 上限 4 枚，
  ai-chat 的九家网页版标签页即由它驱动）；`fs:mkdir` / `fs:rename` / `fs:copy` / `fs:stat` 四条命令
  （带 overwrite 与双路径 scope 校验）；`http` 插件鸿蒙传输层（走 `ohos.net.http` 系统栈，https 恢复可用）；
  `sqlite` / `serial` 鸿蒙落地；`system:host` 补 `notification` 能力位；CLI `doctor` 补 SDK 下载指路。
- **修复**：Linux C 桥 `duplicate member 'h'` 编译错误（内嵌视图的几何字段与宿主指针撞名）、
  `ai-chat` 收起侧栏后内嵌视图不跟随变宽、鸿蒙宿主能力位文档口径（菜单位已真机取证，不再是全 0）。
- 鸿蒙侧真机取证：`fs` / `mqtt` / `redis` / `sqlite` / `store` / `http` 与菜单能力位。

完整变更见仓库的 `CHANGELOG.md` 的 `[2.1.0] - 2026-10-25`。

## 2.0.0 变更

- **不兼容**：删除已失效的公开 API `setHostFactory` / `requireInjectedHost`（框架侧单槽宿主注入）。
  源码里仍在调用它们的应用会编译失败——那些调用本来也不生效（`requireInjectedHost` 没有任何调用方）。
  多宿主注入走 `registerHost(HostProvider)`（带优先级），鸿蒙宿主已内置。
- **修复**：`sync` 生成的工程在 Windows 上编不过（TOML 路径保留反斜杠触发 `errLexEscape`、鸿蒙 entry 的
  `compile-option` 内层引号未转义、生成源码里 `url=\"…\"` 少一层转义）；`cj-tauri check` 的三方比对在
  Windows 上因产物名 `main.exe` 恒被跳过；示例 `modbus-poll` 缺串口插件 import。
- **门禁**：版本校验从五处扩到六处（新增官网 `website/index.html`），并给与 `docs/` 同源的图片 / 图
  加上了逐字节比对——官网是独立拷贝、此前不在门禁里，正是它漏更的根因。

完整变更见仓库的 `CHANGELOG.md` 的 `[2.0.0] - 2026-10-23`。

## License

[MIT](https://atomgit.com/qq8864/cj-tauri/blob/main/LICENSE) © 2026 yangyongzhen
