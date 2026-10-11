# 让 AI 助手真正会用 cj-tauri：五个 skills 的使用指南

> 面向读者：已经在用（或打算用）AtomCode 这类 AI 编码助手写应用的人。
> 如果你装了 [cj-tauri](https://atomgit.com/qq8864/cj-tauri) 的 skills，本文讲清楚它们各管什么、
> 怎么装、怎么调、以及怎么让它们跟着你的使用一起变好。

## 一、为什么要把框架经验做成 skills

用 AI 助手写代码的人大概都有类似的体会：让它写个独立脚本、写个算法，又快又好；
可一旦让它接一个**具体框架**，事情就变了味——它会把别的生态的习惯带过来，猜不存在的 API，
把命令注册了却忘了声明权限，构建过了就宣布"完成"，其实窗口都没起过。

我维护 cj-tauri（用华为仓颉语言写的类 Tauri 2 混合开发框架：仓颉后端 + 系统 WebView 前端），
几个月里和 AI 助手一起踩过的坑攒了满满一文件：仓颉的三引号字符串会吃掉 JS 的反斜杠转义、
`ArrayList.size` 是属性而 `JsonObject.size()` 是函数、`const` 收不了数组字面量、
WebKitGTK 会用原生下拉框的浅色样式盖掉页面配色……这些坑没一条是能靠 AI 的通用知识猜出来的，
每一条都是实机一轮一轮换来的。

这些经验原来只躺在仓库的 `AGENTS.md` 里——对我自己的会话有用，但**别人用不到**：
你没有那份文件，你的 AI 助手自然也不会遵守里面的约定。

skills 解决的就是这个问题。AtomCode 的 skill 本质是一段带 front matter 的 markdown 指令，
装上之后 AI 助手会在合适的时机按它行事。把框架的开发工作流、取证方法、踩坑速查沉淀成 skills，
等于给每一个接入 AtomCode 的助手配了一本"这个框架怎么干活的作业指导书"。

## 二、这五个 skill 各管什么

cj-tauri 的 skills 一共五个，对应开发一件事的五个环节：**环境怎么做齐、怎么做、怎么验、怎么避坑、怎么回馈**。

### cj-tauri-env —— 环境检测与安装指引

管"环境怎么做齐"。这是新用户的第一道坎，也是很多人卡住就放弃的地方：`cjc: command not found`、
退出码 127 且无输出、`dependency info is missing`——这些报错没有一条告诉了你**该怎么装**。

这个 skill 给了两组东西：

- **一键检测脚本**：Linux/Git Bash 与 Windows 各一份，逐项检查 cjc / cjpm / `CANGJIE_HOME` /
  `CANGJIE_STDX` / gcc（Linux）或 llvm-mingw（Windows）/ WebKitGTK / WebView2——先跑检测再动手，
  缺哪样补哪样，不猜；
- **缺什么装什么的指引**：仓颉 SDK（官网 cangjie-lang.cn 与环境搭建教程；注意官方下载页要登录华为账号、
  没有匿名直链，别浪费时间找）、stdx（`CANGJIE_STDX` 必须指 `dynamic/stdx` 动态库目录，不是包根——
  指错的表现是 `create` 成功、到生成工程 build 才炸）、Linux 的 gcc + WebKitGTK 一行 apt、
  Windows 推荐 **llvm-mingw**（免安装、解压即用，从 GitHub Releases 下载后解压到无空格路径、
  `bin` 进 PATH——不必上庞大的 MSVC / Visual Studio），以及给 AI 助手装仓颉语言知识库技能包
  **CangjieSkills**（Cangjie-SIG 维护）。末尾附一张仓颉资料速查表：官网 / 环境搭建 / API / 中心仓 /
  主库与三方库组织 / 社区优质项目 / 官方示例。

### cj-tauri-app-dev —— 开发主流程

管"怎么做"。从起工程（`cj-tauri create`）讲起，到加命令、加插件、写前端、过门禁。

它里面最有价值的是框架的**三处联动**契约。cj-tauri 有能力安全模型：一个命令要真正能用，
必须 ① 实现 `CommandHandler`、② 装配（`register` 或 `.plugin()`）、③ 在 capabilities 清单里声明。
漏了第 ② 处，报 `command not registered`；漏了第 ③ 处，报 `command not allowed`。
AI 助手十有八九会漏第 ③ 处——因为在别的生态里没有这一步。skill 里把这条铁律写死了，
模型每次加命令都会对齐三处，而不是构建通过就收工。

插件同理：实现 `Plugin`（`name()` + `commands()`）、装配、清单声明，一步不能少；
并且插件**只声明"我提供什么"，不自动放行**——最小权限的闸门永远在清单手里。

### cj-tauri-verify —— 实机验证与取证

管"怎么验"。这是五个 skill 里我觉得**最该被推广**的一个，因为它的核心是一组判据铁律：

- **窗口起来 ≠ 成功**。真正的证据是桥的 stderr 日志：窗口创建、`set window:` 行、
  `js -> native` 的次数与实际调用吻合、`ExecuteScript -> hr=0x00000000`；
- **日志里没有错误行 ≠ 命令成功了**。页面没接 `catch` 时，失败只在页面上看得见；
- **退出码 0 什么都不证明**。判真假看副作用：日志 mtime、行数、断言计数。

它还沉淀了两套"没有条件也要验"的办法：没有显示环境，`xvfb-run` 一行套上；
没有真串口设备，python3 的 `pty` 造一对虚拟对端（`examples/plugin-serial/serial-peer.py`
是现成样板），而且**写方向的证据必须在应用进程之外**——对端日志与落盘文件说了算，
应用自报"我写了 13 字节"不算数。

### cj-tauri-troubleshoot —— 踩坑速查表

管"怎么避坑"。按症状对号入座的三张表：编译期、运行期/页面、多窗口/回调。
比如编译报 `expressions of type 'Array' are not constant`，查一下就知道是 `const` 收不了
数组字面量、顶层可变量要用 `let`；页面里 `<select>` 白底浅字看不清，查一下就知道是
WebKitGTK 的原生 combo 样式在作怪、`-webkit-appearance:none` 自绘可解。

这张表的用法有两层：**救火**（报错了来查）和**预防**（写代码前扫一眼相关小节）。
实践里预防那一层更值钱——比如让 AI 知道"页面超过一屏就独立成 `ui/index.html`，
不要内联进三引号字符串"，一行话就能省掉整轮调试。

### cj-tauri-contribute —— 回贡献与自进化

管"怎么回馈"。它定义了使用中遇到问题时的三条路：报问题提 issue（复现步骤 / 期望与实际 /
证据三要素）、修 bug 提 PR（先 fork、分支做一件事、门禁全过再提交）、**沉淀新坑**。

第三条是这套 skills 能自我生长的关键：你踩到了速查表里没有的坑、并验证了修法之后，
把它回填进 `cj-tauri-troubleshoot/SKILL.md`（或项目 `AGENTS.md` §4）并提 PR。
合并之后，**所有用户的所有 AI 助手下次就自动避开这个坑**——框架和 skills 一起进化。

## 三、安装：三种方式挑一种

### 它发布在哪（链接）

这套 skills 的**正身随 cj-tauri 仓库分发**（已 marketplace 化），不在别的市场上：

| 位置 | 链接 |
|---|---|
| cj-tauri 仓库（AtomGit，skills 正身所在） | https://atomgit.com/qq8864/cj-tauri |
| skills 目录（五个 skill 就在这里面） | https://atomgit.com/qq8864/cj-tauri/tree/main/skills |
| GitHub 同步镜像 | https://github.com/yangyongzhen/cj-tauri （受限网络下可能需配代理访问） |

装好后可以在 AtomCode 里自查：`/plugin list` 应看到 `cj-tauri-skills@cj-tauri-skills`，
`/plugin marketplace list` 应看到 `cj-tauri-skills`。

### 方式一：整包装（推荐）

skills 已经 marketplace 化，一行命令装上五个：

```bash
atomcode plugin marketplace add https://atomgit.com/qq8864/cj-tauri.git
atomcode plugin install cj-tauri-skills@cj-tauri-skills
```

装完即用，通常不用重启 AtomCode。以后仓库更新了 skills，`atomcode plugin marketplace update cj-tauri-skills`
再 `install` 一次就能拿到新版。不想用了就卸载（保留 marketplace 注册）：

```bash
atomcode plugin uninstall cj-tauri-skills@cj-tauri-skills
atomcode plugin marketplace remove cj-tauri-skills   # 连 marketplace 一起移（需先卸载插件）
```

### 方式二：只装 skills

不需要 plugin 包装、只想把指令拷过去：

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git
bash cj-tauri/scripts/install-skills.sh            # 装到全局 ~/.atomcode/skills/
bash cj-tauri/scripts/install-skills.sh --project  # 或只装到当前项目 .atomcode/skills/
```

项目级会覆盖同名全局 skill——你可以拿这个给不同项目配不同流程。

### 其他市场与跨生态安装

skill 的格式（目录 + `SKILL.md`）是通用的，同一个仓能被多个生态装载（均已核实）：

- **Claude Code**：本仓已备 `.claude-plugin/marketplace.json`（AtomCode 的 plugin 协议与 CC 兼容）——
  `/plugin marketplace add yangyongzhen/cj-tauri` → `/plugin install cj-tauri-skills@cj-tauri-skills`；
- **skills CLI**（vercel-labs/skills，跨 75+ agent）：`npx skills add yangyongzhen/cj-tauri`——
  它自动扫仓库的 `skills/` 目录（GitHub 镜像同步后即可用）；
- **目录站**（自动索引公开 GitHub 仓库）：[Skill Navigator](https://www.skillnavigator.directory/)
  与 [agentskills.cc](https://agentskills.cc/)——仓库公开后会被自动收录，无需报名。

### 方式三：手动拷贝

把 `skills/<名字>/` 整个目录拷到 `~/.atomcode/skills/` 下即可，结构就是一个目录一个 `SKILL.md`。

## 四、调用：不用背名字

三个入口，按顺手程度挑：

- **直接说事**（最常用）：「用 cj-tauri 写个串口工具」「把这个示例在 Xvfb 里验一遍」——
  模型会按 skill 的 description 自动挑对应的技能，你甚至不用知道它叫什么；
- **斜杠命令**：`/cj-tauri-app-dev`、`/cj-tauri-verify`，补全菜单里选；
- **`$` 菜单**：行首打 `$` 过滤挑选，`$cj-tauri-troubleshoot` 直接调用，后面还能带参数。

什么时候会"撞上" skills？装了之后，只要任务描述和 skill 的 description 对得上
（比如报错信息像速查表里的某一条），模型就会主动加载它。这也是为什么 description 写得具体很重要——
它就是模型判断"要不要用"的依据。

## 五、让这套 skills 跟着你变好

这套内容不是一次性的快照，它的设计目标是**越用越准**：

1. **踩到新坑**：如果速查表里没有、`AGENTS.md` §4 也没有，按 `cj-tauri-contribute` 的流程
   提 issue 或 PR（复现步骤 / 期望与实际 / 证据，三要素齐了合并得快）；
2. **修出了新修法**：回填 `cj-tauri-troubleshoot/SKILL.md` 的速查表，一行"症状 → 原因与修法"；
3. **沉淀新工作流**：某个流程你重复跑了三轮以上（比如"打包前先过三道门禁"），
   就值得做成新 skill 放进 `skills/` 提 PR——下一个人（和下一个 AI）直接受益。

### 当前的 PR 与 issue 情况（2026-10-09 快照）

- **skills 地址**：https://atomgit.com/qq8864/cj-tauri/tree/main/skills
  （新增 skill 就提 PR 改这个目录；五个 skill 各一个子目录，照现有 `SKILL.md` 的结构写即可）；
- **PR**：https://atomgit.com/qq8864/cj-tauri/pulls —— 目前**还没有收到 PR**，
  你提的就是第一个：修 bug、补文档、加 skill、加示例都欢迎；
- **Issue**：https://atomgit.com/qq8864/cj-tauri/issues —— 当前有 **2 个开放 issue**，
  都是征求意见的设计草案：[#1 RFC-001 插件体系](https://atomgit.com/qq8864/cj-tauri/issues/1)
  与 [#2 RFC-002 热重载与前端模板](https://atomgit.com/qq8864/cj-tauri/issues/2)——
  对框架设计有想法的话，直接去这两个 issue 下评审留言，比提代码还帮得上忙。

cj-tauri 是 MIT 协议的开源项目，仓库在 AtomGit：https://atomgit.com/qq8864/cj-tauri
（GitHub 同步镜像）。觉得有用就点个 star；遇到了坑别忍着，提上来——
**你踩过的每一个坑，都会变成所有人下一段路里的平整地面。**

## 六、装完没出现？常见问题排查

**`/` 菜单里找不到这些 skill？** 按顺序查：

1. **装上了没有**：`/plugin list`（或 `atomcode plugin list`）应列出
   `cj-tauri-skills@cj-tauri-skills`。没有就回 §三 重装；
2. **带前缀找**：plugin 贡献的 skill 带 `<plugin名>:` 命名空间——在补全菜单里搜
   `cj-tauri-skills:`，别只搜裸名字；
3. **名字合规**：skill 名只允许 `[a-z0-9_-]`，带斜杠或大小写混合的名字会被 loader 静默跳过
   （本仓五个名字都合规，若你自己新增 skill 撞了这条，改名字）；
4. **重载一次**：装完通常自动刷新；极少数没刷的，`/plugin reload` 扫一遍磁盘变更；
5. **项目级覆盖**：项目级 `.atomcode/skills/` 会覆盖同名全局 skill——如果某个项目里名字对不上，
   查是不是被本地同名 skill 盖了；
6. **还看不见**：当前会话的 skill 列表可能是启动时的快照，开一个新会话再看
   （本机验证时就是：安装当轮 `list_skills` 没显示，磁盘与 `/plugin list` 都已确认落盘）。

