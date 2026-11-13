# ionic-music —— Ionic 前端的移动端形态音乐播放器

 cj-tauri 的 **Ionic Vue** 前端示例：竖屏窄窗（400×820，手机比例），`@ionic/vue` 组件铺满呈现，
后端与 [`examples/music-next`](../music-next/README.md) **共用同一套命令**（源码拷贝自 music-next，
仅改包名 `ionic_music`）——验证「框架对前端零约束，Ionic 也能当 cj-tauri 的 UI」。

## 它演示了什么

- **Ionic 组件接入 cj-tauri**：`@ionic/vue` 的 `ion-app / ion-toolbar / ion-searchbar / ion-list /
  ion-range / ion-refresher` 等在系统 WebView 里正常工作，无需任何桥接适配；
- **移动端形态**：底部页签（热门 / 搜索 / 收藏）+ 底部播放条 + 点标题展开的歌词浮层，
  桌面窗口按手机比例竖着开；
- **后端零改动复用**：`music:hot / music:search / music:lyric / music:image / fav:get / fav:set /
  music:quit / report` 全部来自 music-next 的命令层（含封面防盗链宿主侧取回、歌词仓颉侧归一化、
  收藏整表替换语义）。

## 前端关键点（与模板的差异）

- `package.json` 多三个依赖：`@ionic/vue`（自带 `@ionic/core`）、`vue-router`（**@ionic/vue 的
  硬依赖，不装构建直接失败**）、`ionicons`；
- `main.js` 引 `@ionic/vue/css/*` 四个基础样式与 `dark.class.css` 调色板（深色主题）；
- `vite-plugin-singlefile` 照旧：产物是 `assets/ui/dist/index.html` 单文件（约 1.2 MB，
  Ionic 全量内联进去了），清单 `[assets] page` 指向它。

## 运行

```bash
# 首次：装前端依赖并构建（产物 assets/ui/dist/index.html）
cd assets/ui && npm install && npm run build && cd ../..

cj-tauri build        # 编后端（骨架 + 业务 static 包）
npx cj-tauri run      # 实机跑（先起流：后台数据来自音乐接口，桥日志有 [music] 行）
```

工作目录 = 项目根（capabilities/ 与 assets/ 按相对路径读）。后台接口基址可用
环境变量 `CJ_MUSIC_API` 覆盖（同 music-next）。

## 已知边界

- 后台搜索结果的 `title` 是 GBK 乱码（music-next 已知的后台缺陷），页面不显示它，
  自己拼「“关键词” 的搜索结果」；
- 封面是防盗链图源，只能由宿主命令 `music:image` 带正确 Referer 取回转 data: URL；
- `fav:set` 是**整表替换**（`{songs: [...]}`），页面收藏按钮先本地增删再整表发回。
