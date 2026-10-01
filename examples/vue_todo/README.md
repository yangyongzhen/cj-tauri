# vue_todo

待办清单示例的 **Vue 3 版**：与 `examples/todo_check` 用**同一套命令与事件**
（`todo:add` / `todo:remove` / `todo:list` + `todo:changed` 广播），后端 `src/main.cj` 两边可直接对照；
差别只在前端——那边是原生 JS 单页，这边是 `cj-tauri create --template vue` 生成的 Vite 工程。

目录结构：

```
vue_todo/
  src/main.cj                 后端入口（窗口 + 待办命令注册 + 页面来源选择）
  capabilities/default.json   能力清单（三条 todo 命令 + todo:changed 事件）
  ui/                         前端工程（Vite + Vue 3）
    index.html
    vite.config.js
    src/App.vue               待办清单界面
    src/main.js
  cjpm.toml                   仓颉包配置（依赖与链接路径都指向本仓的 `../..`）
```

## 开发：`cj-tauri dev`（热重载）

```bash
cj-tauri dev
```

`dev` 依次做：桥已构建则跳过 → 若 `ui/node_modules` 不存在则 `npm install` → 后台起 Vite dev server
（`127.0.0.1:5173`）→ 探活 → 以环境变量 `CJ_TAURI_DEV_URL` 启动应用。页面来自真实 URL，所以：

- 改 `ui/src/**.vue` / `.js`：保存后页面自己更新，**应用不重启**（Vite HMR）；
- 改后端 `src/*.cj`：需要重新 `cj-tauri dev`（框架不承诺后端进程内热替换）；
- 应用窗口关闭后会一并收掉 dev server。

想手动控制前端时，也可以自己起 dev server 再启动应用：

```bash
cd ui && npm run dev            # 另一个终端
CJ_TAURI_DEV_URL=http://127.0.0.1:5173/ cj-tauri run
```

## 发布：打成一个 HTML 文件

```bash
cd ui && npm install && npm run build   # 产出 ui/dist/index.html（js/css/图片全内联）
cd .. && cj-tauri build                 # 构建桥 + cjpm build
cj-tauri run                            # 没有 CJ_TAURI_DEV_URL 时读 ui/dist/index.html
```

`vite-plugin-singlefile` 保证产物就是**一个** `index.html`，与 `app` 模板的单文件模式等价。

## 前后端怎么通信

前端拿到的是 `window.__CJ_TAURI__`（与 Tauri 的 `@tauri-apps/api` 同形）：

```js
await window.__CJ_TAURI__.invoke('todo:add', { text: '写示例 README' }); // → 后端返回当前条数
window.__CJ_TAURI__.listen('todo:changed', (p) => { /* p.items / p.count */ });
window.__CJ_TAURI__.reload();                                            // 整页刷新
```

能调哪些命令、能收哪些事件，由 `capabilities/default.json` 决定；没声明的命令一律被拒
（`command not allowed: xxx`）。

### 注意：桥是**异步**注入的，别在模块顶层直接读

Linux 宿主的桥接脚本注入在**文档末尾**（`native/bridge_linux.c` 的
`WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END`；Windows 侧是 document-created），而 `npm run build`
产出的单文件把 `<script type="module">` 内联进 HTML、解析完立即执行 —— 内联模块会跑在注入**之前**，
此时 `window.__CJ_TAURI__` 还是 `undefined`（开发态从 URL 加载、模块要现下载，反而掩盖了这个竞态）。
所以 `ui/src/App.vue` 统一**等桥出现再初始化**：

```js
const t = await waitForBridge();  // 见 ui/src/App.vue：每 20ms 探一次，上限 3s
if (!t) { /* 不是 cj-tauri 载入的页面 */ }
```

自己写应用时同理：在 `onMounted` / 入口处等桥就绪，不要在模块作用域直接读。
