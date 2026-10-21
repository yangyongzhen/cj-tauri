# cjnote — AI 原生 Markdown 笔记

用 [仓颉](https://cangjie-lang.cn/) + [cj-tauri](https://atomgit.com/qq8864/cj-tauri) 写的桌面笔记应用：
**后端静态编译，前端就是系统 WebView**（Linux WebKitGTK / Windows WebView2），不捆 Chromium、不带 Node。

三栏布局（笔记库 / 编辑区 / AI 助手），原生 GTK 菜单栏，顶栏的标题、保存状态与字数推进系统菜单行右侧的副标题。
本机实测：菜单、副标题、AI 流式对话、笔记增删改查整条链路都有 stderr 凭证。

> 📖 **cj-tauri 官网**：<https://yangyongzhen.github.io/cj-tauri/> —— 特性、实机截图与文档入口。

## 界面

![cjnote 主界面](docs/images/cjnote-main.png)

*分屏模式：左侧编辑器（仓颉高亮 + 行号），右侧实时预览，最右是 AI 助手。系统菜单行右侧是「文件 · 状态 · 字数」副标题，页面自己的顶栏因此整条隐藏。*

<table>
<tr>
<td><img src="docs/images/cjnote-outline.png" alt="大纲页签"></td>
<td><img src="docs/images/cjnote-viewmenu.png" alt="原生视图菜单"></td>
</tr>
<tr>
<td><em>大纲页签：标题点击跳行，围栏里的 <code>#</code> 不算标题</em></td>
<td><em>原生「视图」菜单：三态与界面主题都是勾选项，与页面状态同步</em></td>
</tr>
</table>

![原生文件菜单](docs/images/cjnote-filemenu.png)

*原生「文件」菜单：新建 / 打开 / 保存 / 重命名 / 删除都走宿主菜单栏，快捷键与页面内操作同权。*

![AI 设置页](docs/images/cjnote-settings.png)

*⚙ 打开的是整页设置：接入地址、密钥（脱敏回显、留空不改）、模型名、接入协议、温度 / tokens / 轮数，
顶上显示后端状态与两个端点；带「测试连通」。*

## 功能

| 能力 | 说明 |
| --- | --- |
| **三态视图** | 编辑 / 分屏 / 预览，`Ctrl+1/2/3`；与原生「视图」菜单同名同序，切换后菜单勾选自动回写 |
| **原生菜单栏** | 文件 / 视图 / 帮助 三个顶层菜单；`Ctrl+O` 打开外部文件、`Ctrl+P` 快速打开、`Ctrl+N` 新建、`Ctrl+S` 保存、`Ctrl+Q` 退出 |
| **原生副标题** | 标题 · 已保存/未保存 · 字数，走 `setTitlebarSubtitle` 推到菜单行右侧；能力不可用（如 WebView2）时自动退回页面顶栏 |
| **大纲** | 侧栏第二个页签，抽 1~3 级标题（跳过围栏代码块里的 `#`），点一条跳一行（编辑器光标与预览区同步滚动） |
| **最近打开** | `Ctrl+O` 打开的库外文件直接并进左侧单列表（只显示文件名、完整路径悬停可见，点击重开、文件没了自动清条目，最近 8 条持久化）；重启自动恢复上次打开的笔记 |
| **列表排序** | 侧栏「按修改时间 / 按名称」下拉，默认按修改时间（最近动过的在最上），偏好落盘 |
| **侧栏可调宽** | 拖动侧栏右缘拖条调宽（160~480px 夹取），双击复位 220px，偏好落盘；长内容 ellipsis 截断不受影响 |
| **重命名 / 删除** | 「文件」菜单作用于当前笔记：真重命名（保留 mtime、拒绝覆盖已存在目标名）、删除带页内确认；外部文件被拒 |
| **AI 助手** | 后端是 [cjh](https://atomgit.com/qq8864/cjh)（随包分发、自动拉起、退出收尾）；页面经 ws 直连 `ws://127.0.0.1:8765/ws` 流式收帧，逐字落进对话区，回复按 markdown 渲染（代码块高亮，与预览同源）；状态胶囊（就绪/未连接/忙/出错）、空态建议按钮一键提问、工具调用单行展示、审批请求内联成卡片（批准/拒绝） |
| **AI 上下文（指针式）** | 每问默认只带**当前笔记的绝对路径**（外加笔记库根），**不带正文**——正文由 AI 自己按需 `read_file` 读，读的是最新内容。勾「问笔记库」则显式要求这一轮做全库检索；页面不做预取 |
| **设置页** | 点 AI 头部 ⚙ 切到**整页设置**（不是浮层状态卡）：可改接入地址（Base URL）、API Key、模型名、接入协议（OpenAI 兼容 / Anthropic）、温度、单轮最大 tokens、最大工具轮数；显示后端状态与两端点；带**测试连通**按钮。密钥只脱敏回显、留空即不修改。保存是**两条腿**：写 cjh 自己的 `~/.cjh`（管下次拉起与协议字段）+ 把地址 / 模型 / 密钥即时推给**正在运行的那只 cjh**——哪怕它是别的程序拉起的也照样生效，不必等重启；只有接入协议（`provider_protocol`）只认配置文件、需重启 cjh |
| **选区动作** | 选中正文 → 重写 / 续写 / 翻译，结果先进 diff 确认条，接受才改文档、丢弃则原样 |
| **主题** | 跟随系统 / 浅色 / 深色，页面与原生菜单勾选双向同步，偏好落盘 |
| **外部文件草稿** | `Ctrl+O` 打开库外 `.md` 只进内存，首次 `Ctrl+S` 才落成库里的新笔记，**绝不静默改写磁盘原文件** |

## 快捷键

| 按键 | 动作 |
| --- | --- |
| `Ctrl+1` / `Ctrl+2` / `Ctrl+3` | 编辑 / 分屏 / 预览 |
| `Ctrl+N` | 新建笔记 |
| `Ctrl+S` | 保存（外部草稿首次保存＝落库） |
| `Ctrl+O` | 打开磁盘上的 `.md`（原生文件对话框） |
| `Ctrl+P` | 页内快速打开库内笔记（`↑↓` 移动、`Enter` 打开、`Esc` 关闭） |
| `Ctrl+Q` | 退出 |

## 架构

```
ui/index.html            单页前端（HTML+CSS+JS，无构建步骤，改完重启即生效）
src/main.cj              应用装配：命令注册、菜单模型与 MenuRouter、主题/副标题回写、ws 与 cjh 装配
src/notestore.cj         笔记存储：列表 / 检索 / 打开 / 保存 / 新建 / 删除（名字净化，路径穿越在入口挡掉）
src/cjh_host.cj          cjh 托管：二进制发现、健康检查、按需拉起与收尾，以及配置读写（settings.json / auth.json）
capabilities/default.json 能力清单：命令放行、事件声明、http/ws 域名白名单
vendor/cjh/bin/          随包 cjh 二进制（按平台分目录，Linux 4 个 .so / Windows 4 个 DLL 同级）
notes/                   笔记库（运行期数据，不入库）
```

应用注册 18 条命令，一律经 `invoke` 走 IPC：

| 命令 | 作用 |
| --- | --- |
| `note:list` / `note:open` / `note:save` / `note:create` / `note:delete` / `note:rename` | 笔记增删改查 + 重命名（`note:list` 每条带 `mtime`，并回笔记库根绝对路径） |
| `note:search` | 全库关键词检索（标题 + 正文，返回命中片段）。**朴素 `contains`：自然语言提问通常 0 命中**，所以检索交给 AI 自己（`grep` / 列目录） |
| `note:readExternal` | 读库外文件（外部草稿入口） |
| `notes:env` | 运行环境：是否自检模式、笔记库相对路径、框架版本号（「关于」浮层要显示它） |
| `cjh:status` / `cjh:start` | cjh 是否就绪 / 按需拉起（返回 `wsUrl`、`apiUrl`） |
| `cjh:config` / `cjh:saveConfig` / `cjh:restart` | 设置页的配置通路：读（密钥脱敏）、合并写 + **即时推给运行中的 cjh**（`POST /api/settings` 白名单字段）、重启（协议改动才需要） |
| `theme:apply` / `titlebar:sync` | 主题同步到原生菜单勾选 / 副标题推送 |
| `linenos:sync` | 行号开关同步到原生「视图」菜单的勾选项 |
| `report` | 页面自检结论回投 stderr（异步命令，供无人值守取证） |
| `dialog:open`、`store:*`、`http:*`、`ws:*`、`log:write`、`clipboard:write`、`system:version` | 框架插件 / 内置命令提供（对话框 / 偏好落盘 / REST / 聊天流 / 日志 / 剪贴板 / 框架版本） |

> 能力清单里放行的是 32 条（含上述插件命令）；未放行的命令前端一调就被拒并在 stderr 留一行
> `尚未授权`——启动日志里那几条 `dialog:save` / `dialog:pickFolder` / `dialog:message` 的提示即属此类。

**AI 只有 cjh 一个后端，应用不做任何直连**：聊天走 `ws:connect` + `ws:send` 到
`ws://127.0.0.1:8765/ws` 收流式帧（`delta` 逐字、`tool_start`/`tool_result` 单行、审批帧内联成卡、
`done` 收尾），配置读写走宿主（页面没有 `~/.cjh` 的写权限）。模型与凭证都在 cjh 自己的配置里，
所以要换服务商／模型／密钥，改设置页即可，本应用不保存也不中转明文密钥。

**上下文为什么只给指针**：`Chat`（当前笔记）按**绝对路径 + 笔记库根**发出去，正文由 AI 自取。
绝对路径是硬前提——cjh 的 `read_file` 对相对路径是按**它当时的工作区**解析的，给相对路径会静默读错目录；
而给正文快照则会读到旧内容（页面持有的文本可能落后于盘）。指针式既省 token，又保证 AI 读到的永远是最新落盘内容。

为什么不直接只调 cjh 的 `/api/settings`：实测该接口是**字段白名单**的部分更新——
`baseUrl` / `model` / `apiKey` / `temperature` / `maxTokens` / `maxIterations` 能改（改完立刻生效并落盘），
但 `provider_protocol`（接入协议）传进去会被静默忽略（GET 也不回显）。所以设置页的保存是**两条腿**：
写盘（管下次拉起 + 协议字段）+ 把白名单字段推给正在运行的实例；协议改了才提示重启，其余不必等。

**测试连通**用的是一个更轻的通道：cjh 的 `chat` 帧支持**帧级 `model` / `baseUrl` / `apiKey` 覆盖**
（单次生效、不落盘、不粘连），于是按钮直接把表单里的值随一条最小对话发过去——
测的就是「我填的这组值能不能用」，而且配置一字未动。探针不带 `session_id`（cjh 为这一轮另开会话），
既不污染当前对话，也不会顶掉当前会话 id。

端口与二进制位置都可用环境变量覆写：`CJNOTE_CJH_PORT`（默认 8765）、`CJNOTE_CJH`（指向别的 cjh 可执行文件）。

## 运行

依赖与 cj-tauri 相同：仓颉 SDK 1.2.0 + stdx（同代），Linux 另需 `gcc pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev`。

```bash
# 1) 编 C 桥（首次或框架有 C 改动时；产物在框架根的 native/）
bash ../../native/build_linux.sh

# 2) 编本应用
cjpm build

# 3) 跑（stdx 动态库与桥都要进 LD_LIBRARY_PATH，否则启动即退、只留一行 so not found）
export LD_LIBRARY_PATH=$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$CANGJIE_STDX:../../native:$LD_LIBRARY_PATH
./target/release/bin/main
```

工作目录就是笔记库根：首次启动会在 `notes/` 下播种一篇 `欢迎.md`。

AI 后端 cjh 随包放在 `vendor/cjh/bin/<平台>/`：应用启动时先探 `127.0.0.1:8765`，端口上已有活着的 cjh 就
直接复用（不动别人的进程），没有就用随包二进制自己拉起（`web --port 8765 --bind 127.0.0.1`），退出时只收掉
自己拉起的那只。模型与凭证配在 cjh 自己的 `~/.cjh` 里——点 AI 头部的 ⚙ 进设置页改即可，
不需要装 cjh、不需要找路径、也没有任何 API Key 落在本应用的 `store.json`。

## 单文件打包（可选）

想把应用交付成**一个文件**（没有 `lib/`、没有 `ui/`、没有 `capabilities/`），用框架的通用打包脚本：

```bash
bash ../../scripts/pack-linux-single.sh                             # 默认打本示例 → dist-single/cjnote
bash ../../scripts/pack-linux-single.sh examples/cjnote /tmp/out    # 也可指定示例与输出目录
```

产物 `dist-single/cjnote` 11 698 576 B（对比 `cjpm build` 那版动态 `main` 7 967 584 B——多出来的是静态链进来的
仓颉运行时、std/stdx、各插件包与内嵌的页面资源）。它与 `scripts/pack-linux.sh` 打的**目录包**是两种交付形态：

| | 目录包（`pack-linux.sh`） | 单文件（`pack-linux-single.sh`） |
| --- | --- | --- |
| 链接 | 动态（`libcjTauri*.so`、`libcjtbridge.so`） | 静态（`--static --static-std --static-libs` + 静态 C 桥归档） |
| 运行时依赖 | 仓颉运行时 + stdx + 桥，须随包或设 `LD_LIBRARY_PATH` | **只要系统 WebKitGTK / GTK 那一套**，不再需要 SDK / stdx / `LD_LIBRARY_PATH` |
| 页面 / 前端库 / 能力清单 | 随包的 `ui/`、`capabilities/` 目录 | 编进二进制，启动日志打「能力清单来自内嵌资源」 |

Linux 侧有个硬天花板：**系统 WebKitGTK / GTK 没有静态库**（发行版里查无 `libwebkit2gtk-4.1.a` / `libgtk-3.a`），
所以「全静态 ELF」在 Linux 上不可得——产物仍动态依赖系统那套图形栈，能静态下来的只是「本框架带来的依赖」。
实测启动（刻意摘掉 `LD_LIBRARY_PATH`）：窗口建成、菜单 16 项生效、
`[cjnote] 能力清单来自内嵌资源（1 份，共 1568 字节 base64）`，stderr 49 行、无 `not found`。

两条注意：① **cjh 不在产物里**——它按 `vendor/cjh/bin/<平台>/` 找现成二进制、运行期不解包，
所以单文件要和 `vendor/cjh/` **同级摆放**，且**工作目录就是它所在目录**（笔记库 `notes/` 同样按相对路径读）；
② 脚本本身是通用的（示例路径当第一个参数、包名从示例的 `cjpm.toml` 读，脚本内无任何示例专属逻辑），
示例侧只需备好三件套（`src/packed_assets.cj` 空存根、`src/packed_resources.cj`、至少一份 `capabilities/*.json`），
所以它留在框架的 `scripts/` 里、不必复制进每个示例。

## 自检

无人值守跑一轮页面自检，结论经 `report` 回投 stderr：

> 注意：其中两条涉及 cjh 配置的断言（`cjh:config` / `cjh:saveConfig`）按「本机已装并配置过 cjh」写。
> 用隔离 HOME 跑沙盒时先放一份 `~/.cjh/settings.json`，否则 `cjh:config` 那条会因读不到 model 而红——
> 那是「这台机器没配置过 cjh」，不是回归。

```bash
CJNOTE_SELFCHECK=1 ./target/release/bin/main 2>&1 | grep SELFCHECK
# SELFCHECK DONE passed=68 failed=0
```

（汇总行的 `passed` 与 PASS 明细条数**不保证末行对齐**：`report` 是异步命令，聚合行之后还可能再来明细，
所以探针那条断言会落在汇总行之后——判据是「PASS 明细 68 条、FAIL 0 条、汇总 failed=0」三者一致。）

断言覆盖：列表与打开、保存与字数同步、三态切换与持久化、主题切换与勾选回写、外部草稿保存、
大纲抽取与跳行、原生副标题能力探测、AI 设置页切换、四个可编辑字段与按钮齐备、配置通路
（`cjh:config` 回模型名且密钥脱敏、`cjh:saveConfig` 写盘并回报写入键、白名单字段即时推给运行中的实例），
以及两条**真实 cjh** 的通路：流式聊天探针（有后端才跑，连不上记一行 SKIP，不把「环境里没有后端」算成失败）
与设置页的**测试连通**（帧级覆盖真发一轮，回包非空才算过）。
本轮沙盒实测：**68 PASS / 0 FAIL / 1 SKIP**。

## 平台状态

| 平台 | 状态 |
| --- | --- |
| Linux（WebKitGTK） | **已实机跑通**：菜单、副标题、AI 流式（markdown 气泡、工具行、审批卡）、AI 设置页（改配置即时生效 + 测试连通）、笔记增删改查重命名、最近打开、侧栏可调宽；沙盒自检 **68 PASS / 0 FAIL**、单文件产物启动同样取证过 |
| Windows（WebView2） | 代码路径与同名导出齐备（`--subsystem=windows`），副标题走能力位降级到页面顶栏；**未实机验证** |

## 相关文档

- cj-tauri 官网：<https://yangyongzhen.github.io/cj-tauri/>
- 用仓颉写个桌面应用：cj-tauri 与 Markdown 笔记 —— [实战拆解](https://atomgit.com/qq8864/cj-tauri/blob/main/docs/用仓颉写个桌面应用-cj-tauri与Markdown笔记.md)
- cj-tauri 框架：[README](https://atomgit.com/qq8864/cj-tauri) · [使用文档](https://atomgit.com/qq8864/cj-tauri/blob/main/docs/使用文档.md)

## License

MIT
