---
name: cj-tauri-env
description: cj-tauri 开发环境检测与安装指引：仓颉 SDK / stdx / Linux gcc+WebKitGTK / Windows llvm-mingw / WebView2，附仓颉语言资料入口与 CangjieSkills 技能包安装。当环境缺失（cjc、cjpm、gcc、clang 找不到）、要装或升级仓颉工具链、新机器初始化、或问"环境怎么搭"时使用。
---

## 何时使用

- 「检测一下环境」「这台机器能不能跑」「缺什么装什么」
- `cjc` / `cjpm` / `gcc` / `clang` 找不到、原生进程退出码 127 且无输出、
  `cjpm build` 报 `dependency info is missing`
- 新机器初始化 cj-tauri 开发环境；给 AI 助手装仓颉语言技能包（CangjieSkills）

## 步骤

### 1. 一键检测（先跑这个，别猜）

Linux / Git Bash（两条实测坑：① 判存在别用 `命令 | head || echo`——管道退出码取的是 `head` 的、
恒 0；② **判「跑得起来」必须以命令自身退出码为准**——cjc / cjpm 本身是仓颉程序，二进制在 PATH 里
但没设 `LD_LIBRARY_PATH` 时照样加载不了运行时，stdout 空、exit=127，`command -v` 查不出来）：

```bash
cjc  -v >/dev/null 2>&1 && echo "cjc  : $(cjc -v  2>/dev/null | head -1)" || echo "缺 cjc 或运行时不可用（SDK bin + LD_LIBRARY_PATH，见下）"
cjpm -v >/dev/null 2>&1 && echo "cjpm : $(cjpm -v 2>/dev/null | head -1)" || echo "缺 cjpm 或运行时不可用（SDK tools/bin + LD_LIBRARY_PATH，见下）"
echo "CANGJIE_HOME=${CANGJIE_HOME:-未设}  CANGJIE_STDX=${CANGJIE_STDX:-未设}"
gcc --version >/dev/null 2>&1 && gcc --version | head -1 || echo "缺 gcc（C 桥构建）"
pkg-config --modversion webkit2gtk-4.1 2>/dev/null || echo "缺 libwebkit2gtk-4.1-dev"
pkg-config --modversion gtk+-3.0 2>/dev/null || echo "缺 libgtk-3-dev"
```

Windows（cmd / PowerShell）：

```bat
cjc -v          REM 仓颉 SDK
cjpm -v         REM SDK tools/bin
gcc --version   REM llvm-mingw 的 bin 已进 PATH 就有输出
clang --version
cli\cj-tauri.bat info   REM 框架自带一键自检：框架/项目/stdx/SDK/cjpm/桥 是否都解析得到
```

**判据**：`cj-tauri info` 全解析 +（Linux）`pkg-config webkit2gtk-4.1` 有版本号 = 环境齐了。

装了 CLI 的话直接 `cj-tauri doctor`（同一套判据，逐行给 `ok` / `warn` / `FAIL` + 「缺了就怎么办」，
有 FAIL 时退出码 1）——不必人眼比对上表；上面的裸命令是**没有 CLI** 时的替代（`npx cj-tauri doctor` 亦可）。

### 2. 缺什么装什么

**仓颉 SDK（含 cjc / cjpm，验证版本 1.2.0）**

- 官网与下载：https://cangjie-lang.cn/ ；环境搭建教程：https://cangjie-lang.cn/安装仓颉工具链.html
- 注意：官方下载页要登录华为账号、**没有匿名直链**——别浪费时间找直链；
- 装完把 `bin`、`tools/bin` 加进 PATH，并把 `runtime/lib/<平台>` 设进 **`LD_LIBRARY_PATH`**
  （Linux 运行时 .so 不查 PATH：只设 PATH 的表现是退出码 127 且无输出）。

**stdx（扩展标准库；本仓 cjpm.toml 依赖它，验证版本 1.2.0.1）**

- 中心仓：https://pkg.cangjie-lang.cn/index ；API 查询：https://cangjie-lang.cn/api.html
- `CANGJIE_STDX` 必须指 `<stdx解压目录>/<三元组>/dynamic/stdx`（**动态库目录**，不是包根）——
  指错的表现很隐蔽：`create` 成功、要到生成工程里 `cjpm build` 才报
  `root package ... imports package 'stdx.encoding.json' ... but the dependency info is missing`。

**Linux：C 桥构建链 + WebKitGTK**

```bash
sudo apt install gcc pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev
# 无人值守实机验证再加：sudo apt install xvfb xdotool
```

**Windows：推荐 llvm-mingw（不要上 MSVC / Visual Studio）**

Windows 的 C/C++ 工具链长期两分天下：MSVC 深度绑定 Visual Studio、体积庞大；
GCC MinGW（mingw-w64）轻但偏老。**推荐 llvm-mingw**（Martin Storsjö 维护，clang 驱动 +
mingw-w64 运行时）：免安装、一套目录就够，且本项目 `native\build_win.bat` 实测兼容。

1. 从 https://github.com/mstorsjo/llvm-mingw/releases 下载 `llvm-mingw-20260324-ucrt-x86_64.zip`；
2. 解压到**无空格路径**（如 `C:\llvm-mingw`）；
3. 把 `C:\llvm-mingw\bin` 加入 PATH；
4. 新开终端 `gcc --version` / `clang --version` 有输出即成。

另需 **WebView2 Runtime**（Win11 自带；仅运行需要）与 **WebView2 SDK**（仅编译桥时，
`native\build_win.bat` 管理；**SDK 版本不得高于本机 Runtime**，否则加载失败）。

**仓颉语言技能包（给 AI 助手装，可选但推荐）**

- **CangjieSkills**：https://atomgit.com/Cangjie-SIG/CangjieSkills —— 仓颉语言知识库技能包
  （语言特性 / 标准库 / 工具链 / 示例），让助手掌握仓颉本身而不只是本框架。
  安装走 atomcode 的 plugin 通道（plugin 名与 marketplace 名以该仓 README 为准，不要凭空猜）：

```bash
atomcode plugin marketplace add https://atomgit.com/Cangjie-SIG/CangjieSkills.git
atomcode plugin install <plugin名>@<marketplace名>   # 名字看该仓 README
```

### 3. 仓颉资料入口（速查）

| 资料 | 地址 |
|---|---|
| 仓颉编程语言官网 | https://cangjie-lang.cn/ |
| 环境搭建教程（安装仓颉工具链） | https://cangjie-lang.cn/安装仓颉工具链.html |
| 官网 API 查询 | https://cangjie-lang.cn/api.html |
| 仓颉中心仓（三方包索引） | https://pkg.cangjie-lang.cn/index |
| Cangjie 主库组织地址 | https://atomgit.com/Cangjie |
| Cangjie-SIG 组织地址 | https://atomgit.com/Cangjie-SIG |
| Cangjie 三方库组织地址 | https://atomgit.com/Cangjie-TPC |
| 仓颉社区优质开源项目 | https://atomgit.com/Cangjie/仓颉社区优质开源项目.md |
| 仓颉官方示例代码 | https://atomgit.com/Cangjie/Cangjie-Examples |
| CangjieSkills（语言技能包） | https://atomgit.com/Cangjie-SIG/CangjieSkills |

## 规则

- 环境问题不要猜：先跑 §1 检测，按输出对号入座，缺哪样补哪样；
- 版本：SDK 1.2.0 + stdx 1.2.0.1 为验证组合（`cjpm.toml` 的 `cjc-version` 写最低要求 1.0.5，高版本兼容）；
- Windows 工具链一律装**无空格路径**；WebView2 SDK 不得高于本机 Runtime；
- 装完用 `cj-tauri doctor`（或 `cj-tauri info`）复检（全解析才算数），不要只看单条命令有输出；
- 检测输出与安装结果都贴给用户看，装了什么、还缺什么，一目了然。
