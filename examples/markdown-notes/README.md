# Markdown 笔记（examples/markdown-notes）

用 cj-tauri 写的本地 Markdown 笔记：**左侧文件树 / 中间编辑 / 右侧实时预览**（预览窗格可从
「视图」菜单整体关掉，进入单栏专注编辑；文件树支持按名称 / 大小 / 修改时间排序）。
零 Node、零前端构建、零第三方 Markdown 库——渲染器与界面都在一份 `ui/index.html` 里。

它同时是三个框架能力的活样板：

| 展示的东西 | 落在哪 |
| --- | --- |
| 文件读写走 IPC（页面对文件系统没有直接访问） | `fs` 插件：`readText` / `writeText` / `exists` / `list` / `remove` |
| **路径 scope**：命令放行 ≠ 路径放行 | 清单里的 `scopes.fs`（只放行 `$CWD/notes` 及其下） |
| 宿主参数交给页面（页面读不到进程环境） | `notes:env` 命令 + `store` 插件记住「上次打开」 |

## 快速跑通

```bash
# 1) 先构建 C 桥（Linux；Windows 用 native\build_win.bat）
bash native/build_linux.sh

# 2) 一键跑（脚本会播种工作区 + 走完整 E2E 取证）
bash examples/markdown-notes/run.sh
```

手工两步（想在窗口里自己点）：

```bash
cd examples/markdown-notes
mkdir -p notes && echo '# 我的第一篇笔记' > notes/第一篇.md   # 工作区要**先建好**，见下
cjpm build && ./target/release/bin/main
```

**工作区为什么由脚本建**：插件的面里**故意没有 mkdir**。建目录属于应用装配期的事，
不该由一个「页面能调到的命令」持有；页面因此只在一个已经存在的目录里读写。
没建目录就去读，页面会把**原文**显示出来（`fs:list failed: no such file: …/notes`），
而不是吞成一句「加载失败」。

## 界面与操作

- **文件树**：`fs:list` 列 `notes/`，点文件名即 `fs:readText`（目录只显示、不展开——本示例的工作区是平铺的）
- **编辑**：中间是纯文本域；每敲一个字右边立刻重渲染（渲染是本地的，不触发 IPC）
- **保存**：`Ctrl+S` 或工具栏「保存」（`fs:writeText`）；标题栏出现「未保存」就是有未落盘的改动
- **新建**：自动取名 `新笔记.md`、`新笔记-2.md`…（**不弹窗问名字**，理由见下）
- **重命名**：标题栏的行内输入框，回车提交 = **写新 + 删旧**（插件的面里没有 rename，就这两步）
- **删除**：按两次「删除」（第二次变成「确认删除？」，4 秒不按自动收回）
- **刷新**：重新列目录；**有未保存改动时拒绝刷新**并提示先保存，免得刷掉刚敲的字
- **重开**：`store` 记着上次打开的笔记，重启自动恢复

> 全程不用 `window.prompt` / `confirm`：WebKitGTK 的脚本对话框要宿主的 `script-dialog` 信号
> 才弹得出来，没接就是「点了没反应」——这类宿主依赖一律换成页内实现（行内输入框 + 按钮二次确认）。

## Markdown 子集（自写渲染器）

渲染全部用 `createElement` + `textContent` 构造，**不拼 `innerHTML`**：
笔记正文因此不可能是注入点（页面自检里有一条就是拿 `<img src=x onerror=alert(1)>` 验这个）。

| 支持 | 写法 |
| --- | --- |
| 标题 | `#` ~ `######`（h5/h6 并到 h4，内容不丢） |
| 行内 | `**粗体**`、`*斜体*`、`` `行内码` ``、`~~删除线~~`、`[文字](链接)` |
| 列表 | `- ` / `* ` / `+ `；`1. ` 有序 |
| 引用 | `> `（连续多行合到一个引用块，每行一段） |
| 代码块 | 围栏 ``` ``` ``` 起止，可带语言标记 |
| 分隔线 | `---` / `***` / `___` |

**有意不做**（不是漏了，各有理由）：

- **表格、嵌套列表**：渲染器的表面积要能一眼看全；需要时加，加之前先想清楚谁维护。
- **原始 HTML 透传**：等于把「正文」变成可执行内容，与上面那条安全结论直接冲突。
- **图片渲染**：页面是 `run(html)` 的**内联来源**（Windows 走 `NavigateToString`），
  没有真实来源，相对路径的图取不回来；与其留个白框，不如显式降级成一行说明。
  真要图片得走宿主命令取回字节再以 `data:` URL 交还（`examples/movie` 的 `movie:image` 是那个形状）。
- **认不出的行**：一律当普通段落原样显示——「渲染器少支持一种语法」不该变成「内容凭空消失」。

## 能力清单与路径 scope

`capabilities/default.json` 全文是这段（`commands` / `permissions` / `scopes` 三件套齐了才叫「能用」）：

```json
{
  "identifier": "default",
  "windows": ["main"],
  "commands": ["report", "notes:env", "system:version"],
  "permissions": ["fs:default", "store:default"],
  "scopes": {
    "fs": { "allow": ["$CWD/notes", "$CWD/notes/**"], "deny": ["**/*.secret.md"] }
  },
  "events": []
}
```

这里演示的是框架里最容易被混淆的一条：**命令放行 ≠ 参数放行**。
`fs:default` 只是「允许调这些命令名」，能不能碰**某个路径**由 `scopes.fs` 说了算：

- `notes/欢迎.md` → 放行（在 `$CWD/notes` 之下）
- `src/main.cj` → **拒**，且拒绝发生在**共享层**（`src/scope.cj`），插件实现里没有第二份判定
- `notes/../src/main.cj` → **拒**：`..` 先按词法折叠再判，绕不过去
- `notes/密钥.secret.md` → 拒（`deny` 命中即拒，先 deny 后 allow）
- 页面自己**不做任何路径检查**：它是把相对路径原样交给命令，判定只在一个地方

被拒的形状（两处都能查到，这也是 E2E 双侧对账的取信方式）：

```
[frontend] SELFCHECK PASS scope-deny-readText :: 已拒：fs: path is outside the authorized scope
[cj-tauri] scope denied (fs): src/main.cj -> /root/test/cj/cj-tauri/examples/markdown-notes/src/main.cj
[cj-tauri] command rejected (fs:readText): fs: path is outside the authorized scope
```

## 自检（无人值守取证）

`CJ_MARKDOWN_SELFCHECK=1` 启动时，页面会自动跑一轮 **21 条**断言（开关经 `notes:env` 交给页面——
页面没有进程环境，而「要不要自检」必须由**启动它的脚本**决定）：

```bash
cd examples/markdown-notes && CJ_MARKDOWN_SELFCHECK=1 ./target/release/bin/main 2>&1 | grep SELFCHECK
```

| 组 | 断言 |
| --- | --- |
| 桥与插件 | shim 命名空间（`fs` / `store`）在页面脚本之前就位 |
| 布局 | 三栏**几何**宽度（不只是「元素存在」，AGENTS §4 的排版坑就是这么抓的） |
| Markdown | 块级 / 行内 / 围栏 / 图片降级 / **正文不构成注入点** |
| fs | 写读回逐字一致、`list` 形状、改名（写新+删旧）、删不存在必须报错、目录不可 remove |
| scope | 越界读 / 越界列目录 / `..` 绕行——三条**必须被拒**（成功了才算失败） |
| store | 写读一致、删除生效 |
| 界面 | 文件树行数与 `list` 结果一致、预览渲染出节点 |

每条断言经 `report` 命令回投成 `[frontend] SELFCHECK PASS|FAIL <名字> :: <细节>`，最后打一条聚合行：

```
[frontend] SELFCHECK DONE passed=21 failed=0
```

**看证据的方式有一个坑**：`report` 是异步命令（命令按 worker 并发分发），所以**明细行的先后不保证**，
聚合行也不是「最后一行」。判据只能是**计数一致**——聚合行里的 `passed` 等于 PASS 明细条数、
`failed` 等于 0；只看「有没有 FAIL 行」会漏掉「落在聚合行之后的红」。

## 实机 E2E

```bash
bash scripts/e2e/test-linux-markdown-notes.sh     # 无 DISPLAY 时自动进 Xvfb
```

入口做的事：构建（缺产物时）→ **播种工作区**（`mkdir -p notes` + 一份欢迎笔记，幂等）→
带自检开关启动 → 等那条聚合行 → 双侧取证（页面侧明细 + 桥侧 `scope denied`）→ 收尾。

证据：`dist/e2e-evidence/linux-linux-markdown-notes.json`（+ 同名 `.log`），当前 **25/25 断言通过**。
除了断言表，脚本还会直接判四件事：**没有 FAIL 行**、PASS 明细 **≥ 21 条**、
**聚合行计数与明细一致**、工作区**没有残留探针文件**（自检自己建的必须自己删干净）。

## 平台状态（如实）

| 平台 | 状态 |
| --- | --- |
| Linux（WebKitGTK） | **已实机跑通**：25/25 断言，日志见上 |
| Windows（WebView2） | **未验证**（本示例没在 Windows 上跑过，也没进单文件打包） |

## 已知边界

- **不做多窗口**：一个窗口一份笔记（多窗口要的是窗口级路由，示例没必要扩散）
- **不做搜索 / 标签 / 目录树展开**：工作区是平铺的 `notes/`
- **不支持嵌套列表与表格**：见上面「有意不做」
- **没有并发写保护**：两个实例同时开同一份笔记，后保存的覆盖先保存的
- **命令是同步一问一答**：`fs:list` 在超大目录下会慢（它在命令 worker 线程上跑，不冻窗口）

## 目录结构

```
examples/markdown-notes/
├── cjpm.toml              # 示例工程（依赖框架包 + stdx）
├── capabilities/default.json
├── src/main.cj            # 装配：FsPlugin / StorePlugin + report / notes:env 两条示例命令
├── ui/index.html          # 全部界面与渲染器（含页内自检），**独立文件**便于 node --check
├── run.sh                 # 一键转发到 scripts/e2e/test-linux-markdown-notes.sh
└── notes/                 # 工作区（由脚本播种，不入库）
```

页面为什么**不内联**进仓颉三引号字符串：AGENTS §4 有一条实测坑——三引号字符串会先被仓颉处理
反斜杠转义，而 Markdown 渲染器必然要写正则与转义，内联进去等于让整段 `<script>` 静默语法错误
（页面一行都不执行，stderr 毫无提示）。独立文件还顺带能被 `node --check` 静态验语法。
