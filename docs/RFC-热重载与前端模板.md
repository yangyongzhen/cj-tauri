# RFC-002：热重载与前端框架模板（草案）

| 项 | 内容 |
|---|---|
| 编号 | RFC-002 |
| 状态 | 草案（待评审） |
| 日期 | 2026-10-02 |
| 目标版本 | 0.4.0 |
| 评审方式 | 在本仓提 issue 讨论，标题以 `[RFC-002]` 开头；结论回写本文「开放问题」一节 |
| 适用范围 | 桌面两端（Windows WebView2 / Linux WebKitGTK）+ 脚手架 CLI；鸿蒙不在本 RFC |

## 1. 摘要

给宿主加一个 `loadUrl`：页面从「一段内联 HTML 字符串」升级为「一个 URL」。开发时于是可以
直接指向前端 dev server（Vite 自带 HMR，改一个组件不重启应用）；发布时模板产出**单文件**
HTML，仍走今天 `NavigateToString` 那条路，行为与现在等价。两种模式的 IPC 与能力校验完全同一套。

## 2. 现状与问题

| 事实 | 位置 |
|---|---|
| 入口是 `TauriApp.run(html: String)`，宿主接口只有 `start(html)`，**没有 `loadUrl`** | `src/app.cj`、`src/host.cj` |
| Windows 把页面经 `ICoreWebView2::NavigateToString` 加载（启动前存进 `g_pending_html`） | `native/bridge_win.c:265-271` |
| Linux 同理走 `webkit_web_view_load_html` | `native/bridge_linux.c:266` |
| 桥接脚本是**逐文档注入**：`AddScriptToExecuteOnDocumentCreated(BRIDGE_JS)` | `native/bridge_win.c:258` |
| Linux 侧同样是逐文档注入：`webkit_user_content_manager_add_script` | `native/bridge_linux.c:243-246` |
| CLI 的 `dev` 目前等于「`build` + `run`」，完全不认前端工程 | `cli/src/project.cj:257-263` |

由此带来的三条限制：

1. **页面没有 URL、没有基准路径**：相对路径的 `<img>`/`<link>`、`fetch`、动态 `import()`、
   前端路由（history API）都用不了——所以现在的模板只能把 JS/CSS 全内联成单文件。
2. **改前端要重编仓颉**：页面内容嵌在后端字符串里，改一行 CSS 也要 `cjpm build`。
3. **没有 HMR**：没有 dev server，也就没有模块级热替换，改完只能整页重来。

可行性上有一处关键的好消息：桥接脚本是逐文档注入的，**换成一个真实 URL 之后
`window.__CJ_TAURI__` 依然会在页面脚本执行前就位**（见上表第 4、5 行）。也就是说 IPC 那一层
不用动，本 RFC 的工作量集中在「页面怎么进来」而不是「消息怎么出去」。

另一处现实：本机没有 Node 参与框架构建，框架本身零 Node 依赖；引入前端模板会让**使用了
模板的项目**需要 Node，这一点在 §3.2 与 §8 问题 7 里正面讨论。

## 3. 目标与非目标

### 3.1 目标

1. 宿主能按 URL 加载页面：`WebViewHost.startUrl(url)` 与 `TauriApp.runUrl(url)`，语义与
   `run(html)` 平行。
2. 运行期能重新加载：宿主的 `reload()`，以及前端桥的 `__CJ_TAURI__.reload()`。
3. `cj-tauri dev` 在前端工程存在时接管 dev server：拉起 `npm run dev`、把地址交给应用；Vite 的
   HMR 直接可用。
4. 两个前端模板（Vue 3、React 18，均基于 Vite），发布构建产出**单文件 HTML**，与今天的
   `run(html)` 等价。
5. 权限模型不变：URL 页面同样受 capability 约束，不因为「这是 http 页面」就放宽任何一条。

### 3.2 非目标

- 不自己实现打包器或 HMR（复用 Vite），不做前端框架的深度适配（不写 `@cj-tauri/vue` 之类）。
- 不做**后端仓颉代码**的热重载（那需要进程内增量重编，另案）。
- 不把 Node 变成框架的运行时依赖：不用前端模板的项目，装机要求与现在完全一样。
- 鸿蒙 ArkWeb 宿主不在本 RFC 范围（先桌面两端，鸿蒙另开 RFC）。

## 4. 术语

- **页面模式**：内联 HTML（现状，`NavigateToString` / `load_html`）/ URL（新增，`Navigate` / `load_uri`）。
- **dev URL**：前端 dev server 地址，本 RFC 的默认值是 `http://127.0.0.1:5173`。
- **单文件构建**：把 JS/CSS 全部内联进一个 `index.html`，使发布物仍然是「一个文件」，与现状等价。

## 5. 设计

### 5.1 宿主接口（`src/host.cj`）

```cangjie
public interface WebViewHost {
    // 现状不变：内联 HTML 启动
    public func start(html: String): Unit

    // 新增：按 URL 启动（http(s):// 或 file://），与 start(html) 二选一
    public func startUrl(url: String): Unit

    // 新增：重新加载当前页面（dev 用；未加载过页面时为空操作）
    public func reload(): Unit
    // …其余不变
}
```

`TauriApp` 侧新增一个与 `run(html)` 平行的方法：

```cangjie
app.run(html)      // 现状，一行不改
app.runUrl(url)    // 新增：注册内置命令 → 应用窗口配置 → startUrl → 同样的阻塞与退出循环
```

两者共用同一段装配逻辑（内置命令注册、capability 自动扫描、`jsSink`/`devToolsSink` 接线），
差别只在最后调用 `start(html)` 还是 `startUrl(url)`。

### 5.2 C 桥（两端同名新导出）

```c
void cj_bridge_load_url(const char *url);  /* 设置导航目标为 URL；启动前调用，与 start(html) 互斥 */
void cj_bridge_reload(void);               /* 运行期重新加载当前页面 */
```

Windows 实现要点：

- 启动前：新增 `g_pending_url`，与 `g_pending_html` 并存但**互斥**（两者都设时 URL 优先，并在
  stderr 打一行提示）。在 controller ready 处（`native/bridge_win.c:265-271`）按模式二选一：
  `Navigate(url)` 或 `NavigateToString(html)`。
- 运行期：WebView2 的接口对象只能在宿主 UI 线程上碰，所以 `cj_bridge_reload()` 走
  `PostMessageW(g_hwnd, WM_CJT_RELOAD, 0, 0)`，在 `wnd_proc` 里调 `Reload()`；这与现有
  `WM_CJT_DEVTOOLS` 是同一个套路（`native/bridge_win.c:572-578`）。
- 运行期换 URL（启动后才调 `cj_bridge_load_url`）同样走消息投递：URL 字符串用 `HeapAlloc`
  传出去，由宿主线程负责 `free`——否则就是跨线程悬垂指针。

Linux 实现要点：

- 启动前：`webkit_web_view_load_uri(view, url)`，替换现在的 `webkit_web_view_load_html`（二选一）。
- 运行期：`g_idle_add(load_url_idle, …)` / `webkit_web_view_reload(view)`，与现有
  `open_devtools_idle` 同套路（`native/bridge_linux.c:74-85`）——仓颉线程不直接碰 WebKit 对象。

### 5.3 三种页面来源（给使用者一张对照表）

| 场景 | 页面来源 | 走哪条路 | 有基准路径？ |
|---|---|---|---|
| 现状 / 单文件发布 | `ui/dist/index.html` 读成字符串 | `run(html)` | 无 |
| 多文件但不装 Node | `file:///…/ui/index.html` | `runUrl` | 有 |
| 开发（HMR） | `http://127.0.0.1:5173` | `runUrl` | 有 |

第二行看着诱人，但要写清一个 Chromium 限制：**`file://` 页面禁止 XHR/fetch 本地文件**。
所以「多文件 + 不装 Node」只解决 `<script src>` / `<link href>` 这类引用，不解决用 fetch 读数据
的场景。是否在 v1 就提供这条路、文档怎么写，见 §8 问题 3、4。

### 5.4 前端模板

新增两个模板目录，沿用现有占位符机制（`{{PROJECT_NAME}}` 等）与 `scaffold.cj` 的递归拷贝：

```
cli/templates/app-vue/     # Vue 3 + Vite
cli/templates/app-react/   # React 18 + Vite
```

- 前端源码放在 `ui/`：`ui/src/*.vue|tsx`、`ui/index.html`、`ui/vite.config.ts`、`ui/package.json`。
- `vite.config.ts` 里装 `vite-plugin-singlefile`：构建产物 `ui/dist/index.html` 是**一个文件**
  （JS/CSS 内联），发布时与今天的单文件等价；`assetsInlineLimit` 一并调大，避免图片资源外链。
- 后端 `src/main.cj` 的页面选择逻辑（模板生成的部分）：

```cangjie
main(): Int64 {
    let app = TauriApp()
        .window(WindowConfig("我的应用", 1000, 700))
        .register("greet", GreetCommand())

    // dev：CLI 注入了前端 dev server 地址就按 URL 加载（Vite HMR 生效）
    // 读环境变量的具体函数名以 SDK 为准（见 §8 问题 5）
    let devUrl = /* getEnv("CJ_TAURI_DEV_URL") */
    if (devUrl.size > 0) {
        app.runUrl(devUrl)
    } else {
        // 发布：单文件，与现状一致
        app.run(String.fromUtf8(File.readFrom("ui/dist/index.html")))
    }
    return 0
}
```

- `create --template vue|react`：`scaffold.cj` 目前把模板目录名写死在 `cli/src/scaffold.cj:156`，
  需要参数化（缺省仍是现在的 `app`，老用法不受影响）。

### 5.5 CLI 接线（`cli/src/project.cj`）

- `dev`：若项目有 `ui/package.json` →（`node_modules` 缺失时先 `npm install`）→ 后台起
  `npm run dev`（只绑 `127.0.0.1`，端口固定 5173）→ HTTP 探活 → 以 `CJ_TAURI_DEV_URL` 启动应用
  → 应用退出时收尾 dev server（连同子进程）。
- `build`：若项目有 `ui/package.json` → `npm run build`（Vite + singlefile）产出
  `ui/dist/index.html`，再走现有的「桥 + `cjpm build`」。
- **没有 `ui/package.json` 的项目，这一整段直接跳过**，行为与 0.3.x 完全一致。

### 5.6 开发手感与 reload 语义

- 组件级改动交给 Vite HMR（Vue/React 组件热替换，状态不丢）。
- 整页重载：前端桥新增 `__CJ_TAURI__.reload()`（映射到 `cj_bridge_reload`）；DevTools 里的
  reload 在有真实 URL 之后也变得可用（现状是 `about:blank`，reload 没有意义）。
- 后端命令改了仍要重编仓颉：`cj-tauri dev` 的定位是「前端热重载 + 后端自动重建再启动」，
  不承诺后端的进程内热替换。

## 6. 兼容性与版本

- **纯新增**：`run(html)`、桥接脚本、能力清单语义、`capabilities/` 自动扫描都不变；0.3.x 的项目
  升级后行为一致（`examples/hello` 与现有模板工程一行不用改）。
- C 桥新增两个导出 → dll/so 与仓颉侧必须同版本（现状本来就是「桥与框架一起构建」，CLI 会
  按需重建桥）。
- 版本进 **0.4.0**（新增能力），不动 0.3.x。
- 只有用新模板新建、或自己写了 `ui/package.json` 的项目才会触发 Node 路径。
- `examples/hello` 保持内联 HTML，作为「零 Node 依赖」的样板；本 RFC 不改它。

## 7. 交付物（分三步验收）

**M1 宿主层 loadUrl（不含前端工程）**

1. `WebViewHost.startUrl()` / `reload()`；`TauriApp.runUrl()`；前端桥 `__CJ_TAURI__.reload()`。
2. 两桥的新导出与实现（Windows 走消息投递，Linux 走 idle 投递）。
3. Windows 实机验证：DevTools 里 `location.href` 等于传入的 URL、`window.__CJ_TAURI__` 可用、
   `invoke('system:version')` 正常返回、`__CJ_TAURI__.reload()` 触发一次导航、桥日志无 `hr` 非 0。
4. 文档：`docs/使用文档.md` 增「按 URL 加载」一节；README 验证表增行。

**M2 dev 模式 + Vue 模板**

5. `cli/templates/app-vue`、`scaffold.cj` 参数化、`dev`/`build` 的 npm 接线。
6. 实机验证（这一条是本 RFC 的核心卖点）：跑 `cj-tauri dev` → 改一个 `.vue` 文件 → 页面在
   **不重启应用**的前提下更新；再改一条后端命令 → 应用重建重启后仍正常。
7. 一个可跑的示例工程或逐步教程。

**M3 React 模板 + 文档收口**

8. `cli/templates/app-react` 与同一套接线；两个模板的 README（怎么开发、怎么发布单文件）。
9. 教程增「用 Vue/React 写前端」一节（含「单文件发布」的产物检查）。

## 8. 开放问题（评审时请逐条回答）

1. `app.runUrl(url)` 独立方法（本文倾向：不动现有签名、语义显式），还是把 `run` 做成重载
   `run(url)`（API 面更小，但两义性靠重载解析）？
2. dev URL 怎么传：CLI 固定端口并把 `CJ_TAURI_DEV_URL` 注入环境变量（本文倾向，简单可预期），
   还是引入 `tauri.conf.json` 式的配置文件（更可配置，但要新增一份配置面）？
3. 发布形态：模板默认仍产出**单文件**（与现状等价、部署简单），还是顺便支持「`file://` +
   多文件」（体积小、可读，但 fetch 受限）？两者都提供的话，模板里用哪个做缺省？
4. `file://` 模式 v1 就提供吗？若提供，文档必须显式写「`file://` 下不能用 fetch/XHR」这个
   Chromium 限制，避免使用者踩坑后才回来问。
5. 模板里读环境变量的写法（`std.env` 的具体 API）需要一个确定的形式；是否再加一个
   `TauriApp.devUrl()` 之类的语法糖，让模板代码更好读？
6. `cj_bridge_reload` 的语义：整页 `Reload()`（本文倾向）还是「清缓存再 reload」（dev 更彻底、
   发布场景更危险）？
7. **这条最需要拍板**：两个前端模板要不要进仓库？进仓 = 两个 `package.json` + lock 文件，
   仓库体积与维护面都上升；不进仓 = 只在文档里给逐步命令，使用者自己搭。本文倾向「进仓，
   但只在 `create --template` 时拷贝」，因为模板的价值就在于开箱即用。

## 9. 参考

- Tauri v2 的 `WebviewUrl`（`App` / `External` / `CustomProtocol`）与 `tauri dev` 的 devUrl 机制，
  以及 `@tauri-apps/cli` 在前端工程里探测 dev server 的做法。
- Vite 的 `vite-plugin-singlefile`（把构建产物内联成单文件）。
- 本仓相关位置：`src/host.cj`、`src/app.cj`、`native/bridge_win.c:258/265-271/572-578`、
  `native/bridge_linux.c:74/243/266`、`cli/src/project.cj:257`、`cli/src/scaffold.cj:156`。
