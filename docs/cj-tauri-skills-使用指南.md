# 让 AI 助手真正会用 cj-tauri：四个 skills 的使用指南

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

## 二、这四个 skill 各管什么

cj-tauri 的 skills 一共四个，对应开发一件事的四个环节：**怎么做、怎么验、怎么避坑、怎么回馈**。

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

管"怎么验"。这是四个 skill 里我觉得**最该被推广**的一个，因为它的核心是一组判据铁律：

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

### 方式一：整包装（推荐）

skills 已经 marketplace 化，一行命令装上四个：

```bash
atomcode plugin marketplace add https://atomgit.com/qq8864/cj-tauri.git
atomcode plugin install cj-tauri-skills@cj-tauri-skills
```

装完即用，通常不用重启 AtomCode。以后仓库更新了 skills，`atomcode plugin marketplace update cj-tauri-skills`
再 `install` 一次就能拿到新版。

### 方式二：只装 skills

不需要 plugin 包装、只想把指令拷过去：

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git
bash cj-tauri/scripts/install-skills.sh            # 装到全局 ~/.atomcode/skills/
bash cj-tauri/scripts/install-skills.sh --project  # 或只装到当前项目 .atomcode/skills/
```

项目级会覆盖同名全局 skill——你可以拿这个给不同项目配不同流程。

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

cj-tauri 是 MIT 协议的开源项目，仓库在 AtomGit：https://atomgit.com/qq8864/cj-tauri
（GitHub 同步镜像）。觉得有用就点个 star；遇到了坑别忍着，提上来——
**你踩过的每一个坑，都会变成所有人下一段路里的平整地面。**

