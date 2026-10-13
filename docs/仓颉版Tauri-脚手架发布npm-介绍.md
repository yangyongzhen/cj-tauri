# cj-tauri 用起来变简单了：脚手架已上架 npm，一条命令起一个桌面应用

> 2026-10-11 · [yangyongzhen/cj-tauri](https://atomgit.com/qq8864/cj-tauri)（AtomGit，GitHub 同步）
> npm 包地址：<https://www.npmjs.com/package/cj-tauri>

[cj-tauri](https://atomgit.com/qq8864/cj-tauri) 是**仓颉语言的 Tauri**：用华为仓颉语言实现的混合开发框架，
**仓颉后端（静态编译）+ 系统 WebView 前端**，与 Tauri 一致的三件套——WebView 宿主、IPC 双向桥、
能力安全模型。之前想试试它，你得先 clone 仓库、认出 `cli/cj-tauri.sh` 和 `cli/cj-tauri.bat`
两套启动器、再手动对齐 SDK 路径——门槛都在「跑起来之前」。

现在不一样了：**脚手架发布到了 npm**，上手压缩成一条命令：

```bash
npx cj-tauri create myapp
```

这篇文章讲清楚三件事：npm 包替你做了什么、5 分钟怎么跑起来、以及现在用它能造出什么。

---

## 一、npm 包替你做了什么

`cj-tauri` 这个 npm 包（0.8.0 起）把「使用前的所有杂事」收进了一个入口：

### 1. 三端同一条命令

Windows 的 `cmd`、Git Bash、Linux 的 bash，用的都是同一个 `cj-tauri` 子命令——
不再需要分辨 `.bat` 与 `.sh`，也不需要往 `PATH` 里手工拼「仓颉运行时 + stdx + 桥 DLL」。
`dev` / `build` / `run` 会自动为子进程准备完整的动态库搜索路径，路径转义、POSIX 形式
转换这类平台暗坑（Git Bash 下盘符形式的 PATH 会让原生进程退出码 127 且无输出）都由包内部处理。

### 2. 环境自检，缺什么说什么

没配仓颉 SDK？CLI 不会甩给你一句 `cjpm: command not found`，而是给出安装说明与
`CANGJIE_HOME` 配置示例（退出码 1）。排障第一入口是：

```bash
cj-tauri info          # 打印框架/项目/stdx/SDK/cjpm/桥 的全部解析结果
cj-tauri info --json   # 末段输出已装配的插件清单 JSON，给 CI 管道用
```

### 3. CLI 本体：预编译优先，源码构建回落并缓存

包内带了预编译 CLI（如 `prebuilt/linux-x64/`），有就直接用；没有对应平台的预编译产物
（比如 Windows）就在本机用 `cjpm` 构建一次，缓存到 `~/.cache/cj-tauri/<版本>/`
（Windows 为 `%LOCALAPPDATA%\cj-tauri`），之后命中缓存秒起。不往 npm 安装目录写任何产物。

### 4. 前端模板三选一

| 模板 | 命令 | 适合 |
|---|---|---|
| `app`（缺省） | `npx cj-tauri create myapp` | HTML/CSS/JS 内联，零 Node，最轻 |
| `app-vue` | `npx cj-tauri create myapp --template vue` | Vue 3 + Vite 工程 |
| `app-react` | `npx cj-tauri create myapp --template react` | React 18 + Vite 工程 |

---

## 二、5 分钟跑起来

```bash
npx cj-tauri create myapp          # 免安装，直接跑（也可以 npm i -g cj-tauri 后直接 cj-tauri ...）
cd myapp
npx cj-tauri dev                   # 构建 + 启动窗口（Vue/React 模板会接管 Vite dev server）
```

要装什么：**仓颉 SDK**（1.0.5+，验证版本 1.2.0）+ **stdx**——前端那半什么都不用装；
Windows 另需 mingw gcc（WebView2 Runtime Win11 自带），Linux 需 `libwebkit2gtk-4.1-dev`。
`cj-tauri info` 随时告诉你哪一环没就位。

两个顺手的细节：

- **dev 支持热更新**：Vue/React 模板下，CLI 接管 Vite dev server 并注入 `CJ_TAURI_DEV_URL`，
  改 `.vue` / `.tsx` 直接在窗口里 HMR；Ctrl-C 退出时 dev server 一并收掉，不留残留进程；
- **build 出单文件前端**：`cj-tauri build` 用 `vite-plugin-singlefile` 把前端打成一个
  `ui/dist/index.html`，再 `cjpm build` 得到独立桌面产物。

## 三、写个应用只要「三处联动」

cj-tauri 的应用是命令驱动的。加一条前端可调用的命令，共三步：

```cangjie
// 1. 实现 CommandHandler（后端，src/main.cj）
public class GreetCommand <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        return JsonString("Hello, ${argString(args, "name", "world")}!")
    }
}

main(): Int64 {
    // 2. 装配：窗口 + 注册命令
    let app = TauriApp()
        .window(WindowConfig("hello", 1000, 700))
        .register("greet", GreetCommand())
    // 3. 启动（能力清单由 run() 自动扫描 capabilities/；缺一步会得到明确的 denied 提示）
    app.run(html)
    return 0
}
```

```js
// 前端只走注入的桥，不碰 postMessage / fetch 后端
window.__CJ_TAURI__.invoke('greet', { name: '仓颉' }).then(console.log);
window.__CJ_TAURI__.listen('tick', console.log);   // 仓颉 → JS 事件
```

能力安全模型是默认拒绝：`capabilities/` 清单里没声明的命令一律
`command not allowed`——权限长什么样，在清单文件里一目了然。

## 四、现在能用它造什么

仓库的 `examples/` 里已经有一批**实机验证过的**应用，从「能力演示」到「能日常用的小工具」：

| 类别 | 示例 | 说明 |
|---|---|---|
| 调试工具 | `modbus-poll` | **Modbus TCP/RTU 调试工具**：多面板并行监控、报文监视、CSV 记录、内置从站自检——对齐 Modbus Poll 并补齐其痛点 |
| 调试工具 | `serial-assistant` | 串口调试助手：TX/RX 分色日志、定时发送、探针自检 |
| 应用 | `music` / `movie` | 音乐播放器（同步歌词 + 4 套主题色）/ 观影应用（榜单/搜索/播放） |
| 应用 | `typing-poem` | 古诗词打字练习（小学生向，three.js 3D 卡面 + 逐字拼音） |

其中 **modbus-poll 和 movie 还有免安装的单文件 exe**（`dist-single/`，静态链接、不带 Chromium、
双击即用）——不装仓颉 SDK 也能先体验效果，再决定要不要上手开发。

## 五、版本与入口

- npm 包：<https://www.npmjs.com/package/cj-tauri>（当前 0.8.0，MIT）
- 仓库（双托管，代码与 issue 均可提）：[AtomGit](https://atomgit.com/qq8864/cj-tauri) ｜ [GitHub](https://github.com/yangyongzhen/cj-tauri)
- 文档：[使用文档](使用文档.md) · [前端入门教程](前端入门教程.md) · [Modbus 工具实战](仓颉版Modbus调试工具-介绍与实战.md)
- 后续发版：推 `v*` tag 由 GitHub Actions 自动发布（OIDC，无 token 无动态码）

一句话总结：**仓颉写后端、网页写界面、npm 管工程**——想给鸿蒙生态之外的桌面写点原生工具，
现在从想法到窗口只剩一条命令的距离。欢迎 star / fork / 提 issue 共建。

