# G-Star 认证申请材料（cj-tauri）

> 依据官方指南（gitcode.com/GitCode/G-Star_guiding）整理。申请入口：`https://atomgit.com/g-star/apply`，
> 评审周期 1-2 个工作日，通过后每年年审。分**孵化项目**与**毕业项目**两级，先申孵化、达标再晋毕业。

## 一、官方条件逐条自查（2026-10-28 实测）

| 官方条件 | 现状 | 判定 |
|---|---|---|
| 在 GitCode/AtomGit 平台托管且开源许可合规 | AtomGit 主仓库（`qq8864/cj-tauri`），MIT（LICENSE / README.OpenSource 齐全） | ✅ |
| 每年至少 10 次更新 | 近一年 494 次提交、4 个 Release、npm 4 个版本 | ✅ 大幅超出 |
| 文档完备 | README（中英，含运行截图）、CHANGELOG（Keep a Changelog 规范）、CONTRIBUTING、docs/ 下 RFC×3 + 使用文档 + 教程×2 + 踩坑记录 | ✅ |
| 官网有仓库链接 | 官网（website/index.html，GitCode Pages 部署）顶栏「主仓库」按钮直指 AtomGit，JSON-LD 亦引用 | ✅ |
| 多平台同步更新 | AtomGit 与 GitHub 一次 push 双推，无时差 | ✅ |
| 至少 5 位活跃贡献者 | GitHub 实测 2 位（yangyongzhen 450 / zh1an 26） | ⚠️ 差距 |
| 100 个以上 Star | AtomGit 9 + GitHub 3 | ⚠️ 差距（孵化级先申请） |
| 及时回应用户 | issue 当天响应（#6 当日开当日修完双 MR） | ✅ |

结论：硬性门槛（托管/许可/更新频率/文档/官网）全部达标；社区两项（贡献者数、Star 数）建议以**孵化项目**先申请，配第三节的成长计划。

## 二、项目介绍（可直接粘贴）

**一句话**：仓颉语言的 Tauri——用华为仓颉（Cangjie）写桌面应用的混合开发框架，几 MB 级产物。

**一段话**：cj-tauri 把 Tauri 的架构搬到仓颉生态：**仓颉后端静态编译 + 系统 WebView 前端（HTML/CSS/JS）**，
通过 `window.__CJ_TAURI__` 双向 IPC 桥（invoke/listen）连接，配**能力白名单安全模型**（capability
allowlist，默认最小权限）与**插件体系**（fs / http / sqlite / serial / mqtt / redis / ws / menu /
clipboard / notification 等 14 个）。内置 CLI 脚手架（`npx cj-tauri`）与「业务单份、骨架按目标派生」
的统一工程（`cj-tauri.toml` 清单 + `sync` 派生桌面/鸿蒙骨架）。**Windows（WebView2）、Linux
（WebKitGTK）已实机跑通，鸿蒙 PC（ArkWeb）真机闭环**——宿主写在仓颉侧、不走 C 桥，属先例性工作。
配套官网（GitCode Pages）、npm 包（GitHub Actions OIDC 自动发布）、入门教程与三份 RFC 设计文档。

**核心数据**（申报时可直接引用，均已实测）：

- 30 个示例应用、14 个插件、11 条 E2E 实机入口、349 项单元测试
- 近一年 494 次提交；语义化发版 2.1.1（CHANGELOG 全程可追溯）
- Windows 单文件 exe 全自洽（内嵌 WebView2Loader / OpenSSL / 业务依赖，26MB 免安装）
- npm 包 `cj-tauri`（`npx cj-tauri create` 一条命令出工程），v2.1.1 起由 Actions OIDC 自动发布

**差异化亮点**（评审关注点）：

1. **华为仓颉语言的桌面 GUI 生态空白**：仓颉官方尚无成熟的桌面混合开发方案，本项目是该方向首个完整开源实现（静态后端 + 系统前端，产物几 MB，不捆 Node/Chromium）。
2. **安全模型先行**：能力白名单 + 命令三处联动 + 路径 scope，默认最小权限，对标 Tauri 且文档化（RFC-003）。
3. **鸿蒙先例**：ArkWeb 宿主以仓颉侧实现（应用侧组件 + 框架桥接），多窗口 label 路由真机取证，踩坑记录完整公开（docs/鸿蒙ArkWeb接入踩坑.md）。
4. **工程质量**：零警告纪律、桩平台自检（不依赖 SDK/图形栈的 247 项断言）、E2E 证据落盘可对账、CI 双 workflow（静态门禁 + npm OIDC 发布）。

## 三、指南四步准备的落实情况

1. **完善项目基础信息** ✅：仓库介绍、标签（atomcode/bug/good-first-issue/平台适配/插件开发）、Logo。
2. **添加 AtomGit 标识** ⚠️ 本轮已补：README.md 与 README.zh-CN.md 顶栏已加 AtomGit 徽章
   （`[![AtomGitStars](https://atomgit.com/qq8864/cj-tauri/star/badge.svg)](https://atomgit.com/qq8864/cj-tauri)`），
   并保留「国内 AtomGit 托管」文案与 clone 地址。
3. **保持同步更新** ✅：`git push origin main` 一次推送双仓（AtomGit + GitHub），无 1 个月时差风险。
4. **官网跳转链接** ✅：官网顶栏「主仓库」指向 AtomGit。

## 四、社区差距与成长计划（随申请附上）

**现状**：活跃贡献者 2 位、Star 合计 12。**计划（申请后 3 个月）**：

1. **Star 增长**：G-Star 频道曝光 + 官网/README 徽章引流 + CSDN/掘金技术文（已有博客稿基础：
   入门教程、鸿蒙踩坑系列均为可改编素材），目标季度 +40。
2. **贡献者扩容**：CONTRIBUTING 已备；把 good-first-issue 标签落到实处（CLI/文档/示例三类低门槛
   issue 各备 3-5 个）；校园开发者增长计划（gstar-activity.atomgit.com/campus）已有仓颉示例可承接。
3. **响应承诺**：issue 24h 内响应、行为变更同轮更新文档与 CHANGELOG（现行惯例）。

## 五、申请操作清单

- [ ] 打开 `https://atomgit.com/g-star/apply`（或联系运营官微信 GitCode_G-Star 定向邀请）
- [ ] 粘贴第二节「一段话」介绍 + 核心数据
- [ ] 附仓库链接 `https://atomgit.com/qq8864/cj-tauri` 与官网 `https://yangyongzhen.github.io/cj-tauri/`（GitHub Pages，gh-pages 分支发布）
- [ ] 附差异证据链接：docs/鸿蒙ArkWeb接入踩坑.md、docs/RFC-插件体系.md、examples/ai-chat/dist-single/ai-chat.exe
- [ ] 说明社区差距与本计划（第四节），申请孵化级
- [ ] 评审通过后：铭牌截图回填官网、次年按时年审
