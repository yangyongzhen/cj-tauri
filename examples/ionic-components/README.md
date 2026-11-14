# ionic-components — Ionic 组件示例（新形态）

用 cj-tauri（仓颉后端 + 系统 WebView 前端）跑一个**纯前端的 Ionic 组件陈列**，信息架构参考
[ionic-team/ionic-conference-app](https://github.com/ionic-team/ionic-conference-app)：
底部 4 个 tab（Schedule / Speakers / Components / About）+ 全局 drawer 菜单，把 Ionic 常用组件
（tabs / list / searchbar / segment / chip / card / avatar / badge / toggle / radio / range /
progress / fab / modal / popover / actionSheet / alert / toast / datetime / select / sliding item /
ripple）在一处跑通、看得见。

**纯前端静态 demo 数据**：没有后端业务，前端不 fetch 任何接口；唯一用到的后端命令是
`system:version`（About 页用它显示「桥通了」——那行版本号就是前端经 `window.__CJ_TAURI__`
从仓颉侧取回来的）。

## 运行

```bash
# 1) 前端构建（Vite 单文件产物 ui/dist/index.html）
cd examples/ionic-components/assets/ui && npm install && npm run build

# 2) 桌面端编译运行（串起 sync 派生骨架 + cjpm build + 启动）
npx cj-tauri run ionic-components
```

`npx cj-tauri run` 会自动：按清单派生 `targets/desktop` 骨架 → 构建业务 static 包 → 启动窗口。
手动分步等价于：`npx cj-tauri sync ionic-components` 再 `cd targets/desktop && cjpm run`。

## 结构

- `cj-tauri.toml` — 应用清单（单一真相：id / package / 窗口尺寸 / 页面 / 能力目录）
- `cjpm.toml` + `src/main.cj` — 业务 static 包（本示例只建窗，不注册业务命令）
- `assets/ui/` — Vite + Ionic 8 + Vue 3 前端（单文件产物）
- `assets/capabilities/default.json` — 能力清单（只放 `system:version`）

## 与 ionic-music 的差异

ionic-music 是**移动端窄窗 + 真实后端接口**（歌单 / 搜索 / 播放 / 同步歌词）；
本示例是**桌面宽窗 + 纯静态组件陈列**——两者共用同一套 cj-tauri 骨架与桥，
区别只在清单（窗口尺寸、能力）与前端页面。
