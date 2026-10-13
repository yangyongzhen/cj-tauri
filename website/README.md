# website/ —— cj-tauri 官网

静态单页落地页，中英双语，**零外部依赖**（不引 CDN、不引 Web Font、没有任何统计脚本）。
源文件随仓库版本化；GitHub Pages 发布的就是**这个目录本身**，没有构建步骤——
所以「本地看到的样子」和「线上发布的样子」是同一份字节。

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `index.html` | 唯一页面：首屏 / 三件套 / 特性 / 架构 / 代码展示 / 插件 / 示例画廊 / 实测数据 / 上手 / 平台状态 / 文档 / 页脚 |
| `assets/style.css` | 全部样式（深色单一主题，设计令牌在顶部 `:root`） |
| `assets/app.js` | 中英切换、代码标签页、滚动进场、移动端菜单 |
| `assets/favicon.svg` | 站点图标（也是页脚与 OG 卡片里的标识） |
| `assets/og.svg` → `assets/og.png` | 分享卡片源图与产物（1200×630，`og:image` 用） |
| `assets/architecture.svg` | 架构图（与 `docs/images/` 同源拷贝） |
| `assets/dist-size-compare.svg` | 产物体积对比图 |
| `assets/screenshots/*.png\|jpg` | 实机截图（源自 `docs/images/`，见下「素材口径」） |
| `.nojekyll` | 关掉 GitHub Pages 的 Jekyll 处理（本项目用不到 Jekyll，且避免它改写文件） |

## 发布

`.github/workflows/pages.yml`：`main` 上任何改动 `website/**` 的提交都会跑一次站点自检，
然后把**本目录的内容**整份推到 `gh-pages` 分支（孤儿提交，不带历史）——GitHub Pages 的源
认这个分支，因此推上去即发布，不需要有人去动仓库设置。首次若站点没出现，检查
Settings → Pages → Source 是否为 `Deploy from a branch` + `gh-pages` / `(root)`。

线上地址：<https://yangyongzhen.github.io/cj-tauri/>（`index.html` 里的 `canonical` 与 `og:url` 用的就是它）。


## 本地预览

无需服务器，直接打开即可（页面不请求任何外部资源）：

```bash
xdg-open website/index.html      # Windows 上直接双击
```

要强制某个语言（分享链接、抓图都用它）：

```
website/index.html?lang=en       # 英文；?lang=zh 中文
```

## 自检

```bash
bash scripts/site-check.sh              # 快速档：静态断言（不需要浏览器，断网可跑）
bash scripts/site-check.sh --links      # 再联网核对页面里的外部链接
bash scripts/site-check.sh --shots      # 再抓中英两态截图到 /tmp/cj-tauri-shots
```

`scripts/check-static.sh` 会调用快速档，所以改动站点会被常规门禁拦住。当前覆盖：

- 本地引用（`src`/`href`/CSS `url()`）是否都能落地、图片是否都有 `alt`；
- **零外部依赖**：任何 `<script>`/`<link>`/`<img>` 指向站外即失败（`rel="canonical"` 是元信息，不算）；
- **中英文案覆盖**：含中文的文本 / `alt` / `title` 必须配 `data-en*`，漏一个英文态就露中文；
- 正文里是否残留 markdown 记号（`**强调**` 写进 HTML 就是字面星号——踩过）；
- 死锚点、标签页与面板是否配对、语言按钮是否成对、HTML 用到的 class 在 CSS 里是否存在；
- `og.png` 必须是 1200×630，`website/` 总体积。

## 双语机制

中文是页面正文，英文写在属性里，由 `assets/app.js` 在首屏前切换：

| 属性 | 用途 |
| --- | --- |
| `data-en="…"` | 整段的英文（中文取页面初始 `innerHTML`，切回来时还原） |
| `data-en-alt="…"` | `<img>` 的英文 `alt` |
| `data-en-title="…"` | 元素的英文 `title` |
| `data-no-i18n` | 该子树不参与翻译（如「中文 / EN」切换按钮本身） |
| `data-en-html="…"` | 需要富文本的英文（保留标签，慎用） |

语言优先级：`?lang=` → `localStorage` → 浏览器语言。**新增文案必须带 `data-en*`**，否则
`site-check` 直接失败（这条是硬门禁，不是建议）。`<script>`/`<style>`/`<pre>` 里的中文
（JSON-LD、代码注释、终端记录）有意不翻译。

## 素材口径

- **数字**：体积 / 第三方 DLL / 冷启动全部来自 `docs/分发形态实测.md`（由 `scripts/dist-report.sh`
  现场量、证据 JSON 落 `dist/`，不入库）。**没量到的一格留空说明**——Windows 冷启动在本机（Linux）
  量不到，页面就写「还没量到」，不拿别处的数字替它。
- **截图**：从 `docs/images/` 的实机取证里挑，拷进 `assets/screenshots/`。>200KB 的转 JPEG
  （`convert x.png -resize '1200>' -strip -quality 82 x.jpg`）——UI 截图里的封面/剧照用 PNG 存纯属浪费。
- **OG 卡片**：改文案就改 `assets/og.svg` 再重新渲染一行：

  ```bash
  rsvg-convert -w 1200 -h 630 assets/og.svg -o assets/og.png
  ```

  **别用 ImageMagick 的 SVG 渲染器**（`convert og.svg og.png`）：它渲染大号粗体字的字距是错的，
  实测标题会叠成一坨。`rsvg-convert` 走 librsvg，字距正确（已肉眼验收）。

## 改版 checklist

- 新增分区 → 左侧导航也要加入口，并让 `site-check` 的锚点检查通过（`#id` 必须有落点）。
- 新增文案 → 中英成对（`data-en*`）。
- 新增截图 → 拷进 `assets/screenshots/` 并在 `index.html` 里引用（引用即纳入存在性检查）。
- 不要为了好看引外部字体/图标库：图标一律内联 SVG，字体用系统字体栈。
- 站点形态或素材口径变了 → 同步本文件与 `CHANGELOG.md`。
