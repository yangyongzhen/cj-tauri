# cj-tauri skills —— 让 AI 助手会用 cj-tauri 开发应用

这里是 [cj-tauri](https://atomgit.com/qq8864/cj-tauri)（仓颉版类 Tauri 框架）沉淀的 **AtomCode skills**：
把框架的开发工作流、实机取证方法、踩坑速查与回贡献流程固化成 AI 可复用的指令，
让任何接入 AtomCode 的助手都能按这套经过实战的方法开发应用。

## 包含的 skills

| skill | 干什么 | 什么时候会被触发 |
|---|---|---|
| `cj-tauri-app-dev` | 起工程、加命令/插件（三处联动）、写前端、过门禁 | 「用 cj-tauri 起个应用」「加个命令/插件」「前端调用不通」 |
| `cj-tauri-verify` | 构建 → 实机跑 → 桥 stderr 取证 → Xvfb/pty → 断言截图 | 「跑一下」「验证」「自动化验收」「截图」 |
| `cj-tauri-troubleshoot` | 编译报错 / 页面异常 / 多窗口回调的**实测坑速查表** | 仓颉编译错、应用行为怪、写代码前预防 |
| `cj-tauri-contribute` | 问题→issue、修法→PR、新坑→回仓沉淀（**自进化入口**） | 「提个 issue」「提个 PR」「反馈给上游」 |

## 安装

### 方式一：作为 plugin 安装（推荐，可整包更新）

本目录已 marketplace 化（`.atomcode-plugin/marketplace.json`），一行命令把四个 skill 一起装上：

```bash
# CLI 方式
atomcode plugin marketplace add https://atomgit.com/qq8864/cj-tauri.git
atomcode plugin install cj-tauri-skills@cj-tauri-skills
```

或在 AtomCode TUI 里 `/plugin` 打开交互式管理器操作。装完后 skills 出现在 `/` 菜单
（带 `cj-tauri-skills:` 前缀），模型也会按任务自动调用。

### 方式二：只装 skills（仓库脚本）

```bash
bash scripts/install-skills.sh            # 装到全局 ~/.atomcode/skills/
bash scripts/install-skills.sh --project  # 装到项目级 .atomcode/skills/（只影响当前项目）
```

### 方式三：手动拷贝

把 `skills/<名字>/` 整个目录拷到 `~/.atomcode/skills/`（全局）或 `.atomcode/skills/`（项目级）即可。

## 使用

- 斜杠命令：`/cj-tauri-app-dev`、`/cj-tauri-verify`…（补全菜单里直接选）；
- `$` 菜单：行首打 `$` 过滤挑选，`$cj-tauri-troubleshoot` 直接调用；
- **自动触发**：不用记名字——直接说「用 cj-tauri 写个串口工具」「验证一下这个示例」，
  模型会按 description 自动挑对应的 skill。

## 自进化：用着用着就变好

这套 skills 不是死的。使用中遇到新问题、修出新修法时，走 `cj-tauri-contribute`：

1. **提 issue**：https://atomgit.com/qq8864/cj-tauri/issues （复现步骤 / 期望与实际 / 证据）；
2. **提 PR**：修 bug、加能力、补文档都欢迎（门禁见仓内 `AGENTS.md` §1）；
3. **沉淀新坑**：验证过的修法回 `skills/cj-tauri-troubleshoot/SKILL.md` 速查表与 `AGENTS.md` §4——
   合并后，所有用户（以及所有 AI 助手）下次就自动避开这个坑。

仓库采用 MIT 协议；欢迎star、fork、共建。

## 为什么是这套内容

cj-tauri 是「仓颉后端 + 系统 WebView 前端」的混合开发框架，开发中的真实难点不在 Hello World，
而在：**能力安全模型的三处联动**（漏一处命令就用不了）、**实机取证**（窗口起来 ≠ 成功，
证据在桥的 stderr 日志）、以及**平台与语言层面的坑**（三引号转义、FFI 签名、WebKitGTK 行为…）。
这四个 skill 分别把「怎么做 / 怎么验 / 怎么避坑 / 怎么回馈」固化下来，
全部内容来自真实项目的实战轮次——每一坑都实测踩过、每条修法都实机验证过。
