---
name: cj-tauri-contribute
description: 向 cj-tauri 仓库回贡献：把使用中遇到的问题、修法与新能力沉淀成 issue 或 PR 提交回仓，让 skills 与框架自进化。当使用 cj-tauri/skills 过程中发现了新坑、修了 bug、或想补充文档与示例时使用。
---

## 何时使用

- 使用 cj-tauri 或其 skills 时**踩到了新坑**（本 skill 与 `AGENTS.md` §4 都没记的）
- 修好了一个 bug、加了新能力、写了新示例/新 skill，想回馈给项目
- 用户说「提个 issue」「提个 PR」「反馈给上游」「沉淀下来」

## 仓库与约定

- 仓库：**https://atomgit.com/qq8864/cj-tauri**（仓颉版类 Tauri 框架 + 本 skills 的正身所在）
- 开发契约：仓内 `AGENTS.md`（门禁 / 架构 / 编码规范 / 踩坑清单）；**改代码前先读 §1 与 §2**
- 提交信息：Conventional Commits（`feat:` / `fix:` / `docs:` / `chore:`），主题英文、正文可中英混排

## 步骤

### 1. 先查重

- 翻仓内 `AGENTS.md` §4（踩坑清单）与本 skills 目录：坑已被记过就只补充证据，不重复提；
- issue 用 `atomgit_issue` 工具（action=list）搜现有条目；没有工具时在 AtomGit 网页搜。

### 2. 提 issue（报问题 / 提议）

- 用 `atomgit_issue`（owner=qq8864, repo=cj-tauri）或网页 https://atomgit.com/qq8864/cj-tauri/issues ;
- 正文三要素：**复现步骤 / 期望与实际 / 证据**（桥 stderr 日志行、截图、退出码——
  「取证」的口径见 `cj-tauri-verify`：日志行为准，不看退出码猜成败）。

### 3. 提 PR（修 bug / 加能力 / 沉淀新坑）

1. fork 仓库（AtomGit 网页或 `atomgit_repo` action=fork），克隆到本地；
2. 建分支，一次提交只做一件事；改动面遵守 `AGENTS.md` §2（平台差异只进 `@When` 与 C 桥、
   依赖方向单向、新命令/插件三处联动）；
3. **门禁全过再提交**（`AGENTS.md` §1）：`cjpm build` + `bash scripts/test.sh` +
   `bash scripts/check-static.sh`；行为变更附可观测证据（日志行 / `system:version` 返回值）；
4. 有 `atomgit_pr` 工具就直接 `create`（head=`<你的fork>:<分支>`, base=`main`）；
   没有工具就推 fork 后在网页开 PR，描述里带上证据与门禁结果。

### 4. 沉淀新坑（自进化的关键一步）

踩到新坑并验证修法后，**两处都要回**：

- 本 skills 仓库的 `skills/cj-tauri-troubleshoot/SKILL.md` 速查表加一行（症状 → 原因与修法）；
- 若是项目级契约（架构约束 / 编码规范），提 PR 改 `AGENTS.md` §4。

PR 描述里写清「哪轮实测踩的、证据是什么」，合并后项目与 skills 同步长进。

## 规则

- **不提交**：`target/`、`*.dll`、`*.log`、`cjpm.lock`、`.atomcode/`（本地会话产物）、`dist-win/`；
- 文档与代码注释里引用托管地址一律用 **AtomGit**（atomgit.com）；
- 凭据（token / 密码 / 动态码）不进 issue、不进 PR、不进提交；
- 无法验证的平台（如手头没有的 Windows / 鸿蒙）如实标注「未验证」，禁止把未验证说成通过。
