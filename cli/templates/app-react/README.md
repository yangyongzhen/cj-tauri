# {{PROJECT_NAME}}

`cj-tauri create {{PROJECT_NAME}} --template react` 生成的工程：**仓颉后端 + React 18 / Vite 前端**。

目录结构：

```
{{PROJECT_NAME}}/
  src/main.cj            后端入口（窗口 + 命令注册 + 页面来源选择）
  capabilities/          能力清单（哪些命令 / 事件允许被前端调用）
  ui/                    前端工程（Vite + React）
    index.html
    vite.config.js
    src/App.jsx
    src/main.jsx
  cjpm.toml              仓颉包配置（cjTauri 依赖路径由 create 写入本机绝对路径）
```

## 开发：`cj-tauri dev`（热重载）

```bash
cj-tauri dev
```

`dev` 依次做：桥已构建则跳过 → 若 `ui/node_modules` 不存在则 `npm install` → 后台起 Vite dev server
（`127.0.0.1:5173`）→ 探活 → 以环境变量 `CJ_TAURI_DEV_URL` 启动应用。页面来自真实 URL，所以：

- 改 `ui/src/**.jsx` / `.js`：保存后页面自己更新，**应用不重启**（Vite HMR）；
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
window.__CJ_TAURI__.invoke('greet', { name: '仓颉' });   // → Promise
window.__CJ_TAURI__.listen('tick', (payload) => { /* ... */ });
window.__CJ_TAURI__.reload();                            // 整页刷新
```

能调哪些命令、能收哪些事件，由 `capabilities/default.json` 决定；没声明的命令一律被拒
（`command not allowed: xxx`）。

## 和 vue 模板的差别

只有 `ui/` 里换成了 React：`@vitejs/plugin-react` 替掉 `@vitejs/plugin-vue`，入口是 `src/main.jsx`、
根组件是 `src/App.jsx`；Vite 配置、`src/main.cj`、能力清单、`cj-tauri dev` 的用法完全一致。
`src/main.jsx` 里**没有**用 `React.StrictMode`：开发模式下它会把 effect 跑两遍，
而这个模板的 effect 里要调 `invoke` / `listen`，双跑容易让人误以为桥重复投递。
