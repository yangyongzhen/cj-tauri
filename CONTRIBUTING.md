# 贡献指南

感谢你对 cj-tauri 感兴趣！本指南帮助你快速上手，确保贡献流程顺畅。

动手改代码前请先读 [`AGENTS.md`](AGENTS.md)——它是本项目的**开发契约**（架构契约、已踩坑清单、交付门禁），
本指南只讲流程，冲突时以 `AGENTS.md` 为准。

## 环境搭建

### 必备工具

- **仓颉 SDK**：1.2.0（`CANGJIE_HOME`，如 `D:\Program Files (x86)\Cangjie`）
- **仓颉 stdx**：1.2.0.1（`CANGJIE_STDX`）
- **MinGW-w64 gcc**：编译 Windows 宿主 C 桥 `native/bridge_win.c`
- **Microsoft Edge WebView2**：需要运行时；构建 C 桥还需要 SDK（`WEBVIEW2_SDK_ROOT`）。
  **SDK 版本不得高于本机 Runtime 版本**，否则加载失败（详见 `AGENTS.md` §4）
- **Linux（可选）**：GTK 3 + WebKit2GTK 3.0 开发包

### 克隆与构建

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git
cd cj-tauri

cjpm build                          # 框架本体
cd cli && cjpm build && cd ..       # 脚手架 CLI
cd examples/hello && cjpm build && cd ..   # 示例应用
```

Windows 上跑示例（会一并构建 C 桥、准备环境变量并启动窗口）：

```bat
run_win.bat
```

Git Bash 里手工配环境时注意：`PATH` 中的 SDK 路径必须是 POSIX 形式（`/d/Program Files (x86)/Cangjie/...`），
写成 `D:/...` 会被 MSYS 破坏，原生进程退出码 127 且无任何输出。

### 脚手架 CLI

```bash
cli/cj-tauri.bat info               # 解析框架/项目/stdx/SDK/cjpm/桥 的路径，排环境问题先用它
cli/cj-tauri.bat create my-app      # 生成工程（模板见 cli/templates/app/）
cd my-app && ../cli/cj-tauri.bat run
```

## 开发规范

### 改代码

- `cjpm build` 必须通过；改动涉及 CLI 或示例时各自再跑一次。
- 行为变更要有**可观测证据**：桥的 stderr 日志行、`system:version` 返回值、窗口标题等；
  不允许「先交付后补证据」，跑不起来或不支持的平台如实说明。
- 新增命令要**三处联动**（漏一处就用不了）：实现 `CommandHandler` → `TauriApp.register` → 能力清单 `commands` 声明。
- 平台差异只允许出现在 `@When` 条件编译与 `native/bridge_*.c`；IPC、能力校验、命令分发必须跨平台共用。
- 注释用中文、标识符用英文；`.bat` / `.ps1` 保持**纯 ASCII**（中文注释会吞掉后续行或让 PowerShell 解析崩溃）。
- 条件编译的平台取值首字母大写：`@When[os == "Windows"]` / `"Linux"`。

### 跑测试

```bash
bash scripts/test.sh                    # 框架单元测试（IPC 分发 / 能力校验 / 版本常量）
bash scripts/test.sh --filter invoke    # 参数透传给 cjpm test
```

测试不创建窗口，纯逻辑，可在无 GUI 的环境跑。改动涉及 IPC 分发、能力校验、版本常量时，请先让它们全绿。
Windows 上如果测试二进制报 `0xC0000135`，是桥的 DLL 不在 `PATH` 里——`scripts/test.sh` 已经处理，
手写命令时记得把 `native/` 与 `native/webview2/` 加进去。

### 提交前自检

```bash
bash scripts/check-static.sh    # 不需要 SDK：版本一致 / 文档围栏 / 模板占位符 / 脚本编码 / 构建产物
bash scripts/test.sh            # 需要 SDK：框架单元测试
```

两条流水线（`.atomgit/workflows/ci.yml` 与 `.github/workflows/ci.yml`）在 push 与 PR 时跑的就是
`check-static.sh`——它是**不需要仓颉 SDK** 的那一半门禁，所以能在任何 runner 上跑。
需要 SDK 的 `cjpm build` 与单元测试暂时还没进 CI（缺预装仓颉的镜像），本地提交前务必自己跑一遍。

### 版本与自检

```bash
bash scripts/check-version.sh       # 版本号四处一致（权威目标是 CHANGELOG 顶部已发版段），应全 ok
```

发版流程见 `AGENTS.md` §6，不要在功能提交里顺手改版本号。

### Commit 规范

使用 [Conventional Commits](https://www.conventionalcommits.org/) 格式，主题写英文，正文可中英混排：

```
feat: add the window resize command
fix(win): keep the WebView2 callback AddRef returning 1
docs: document the capability loader
```

类型前缀：`feat` / `fix` / `docs` / `style` / `refactor` / `test` / `chore` / `ci`。
一次提交只做一件事；行为变更同时更新 `CHANGELOG.md` 的 `[Unreleased]` 段。

### 分支策略

- `main`：稳定发布分支
- 功能分支：`feat/<描述>` 或 `fix/<描述>`

## 提交 PR

1. Fork 本仓库并创建功能分支
2. 本地跑通 `cjpm build`（必要时含 CLI / 示例）、`bash scripts/test.sh`、`bash scripts/check-static.sh`
   与 `bash scripts/check-version.sh`
3. 在 `CHANGELOG.md` 的 `[Unreleased]` 段登记行为变更，并同步受影响的 `README.md` / `docs/使用文档.md`
4. 推送并创建 Pull Request，写清变更动机、验证方式，以及**哪些平台/场景未验证**
5. 本仓双托管：`origin` 挂了 AtomGit 与 GitHub 两条 pushurl，一次 `git push origin main` 同步两仓。
   提交请用**显式路径** `git add`（别用 `git add -A`），不要提交 `target/`、`*.dll`、`*.log`、`cjpm.lock`

## 报告问题

提问时请提供：

- 操作系统与版本（如 Windows 11 24H2 / Ubuntu 24.04）
- 仓颉 SDK 版本（`cjc -v`）与 `cjpm.toml` 里的 `cjc-version`
- WebView2 Runtime 版本（桥日志里的 `WebView2 runtime: ... ver=` 一行）
- 复现步骤，以及**桥的 stderr 日志原文**（含 `hr=` 的行；日志请贴文本，不要只给截图）
- `cli/cj-tauri info` 的输出（能一次性排除大部分环境/路径问题）

## 行为准则

请遵守尊重、友善的沟通原则。禁止骚扰、歧视性言论或恶意攻击。

---

如有疑问，欢迎在 Issue 中提问。开源信息与依赖许可见 [`README.OpenSource`](README.OpenSource) 与 [`LICENSE`](LICENSE)。
