# cj-tauri

用[仓颉语言](https://cangjie-lang.cn)写桌面应用的**类 Tauri 框架**脚手架 CLI：
仓颉后端（静态编译）+ 系统 WebView 前端（HTML/CSS/JS），三件套对标 Tauri ——
WebView 宿主、IPC 双向桥（`invoke` / `resolve` / `event`）、能力安全模型（capability 白名单）。

- 仓库与完整文档：<https://atomgit.com/qq8864/cj-tauri>
- 当前状态：**Windows（WebView2）与 Linux（WebKitGTK）均已实机跑通**；鸿蒙 ArkWeb 为架构预留位

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

npm i -g cj-tauri                  # 也可以全局安装，之后直接用 cj-tauri <子命令>
```

| 子命令 | 作用 |
|---|---|
| `create <项目名> [--template app\|vue\|react]` | 生成工程（`src/` + `ui/` + `capabilities/` + `cjpm.toml`） |
| `dev` | 构建 C 桥 + `cjpm build` + 启动应用；Vite 模板会接管 dev server（HMR） |
| `build` | 构建 C 桥 + `cjpm build` |
| `run` | 运行已构建产物 |
| `info` | 环境自检（排障先跑它） |
| `help` | 帮助 |

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
