# 证据：网页版在同一窗口里以标签页切换（Windows 桌面，2026-10-25）

对应能力：`WebViewHost.createEmbeddedView / setEmbeddedViewVisible / setEmbeddedViewBounds /
navigateEmbeddedView / destroyEmbeddedView` + C 桥 `cj_bridge_view_*`（两平台同名同签名）。
取证对象：`examples/ai-chat` 的网页版入口（侧栏「网页」→ 点站点卡片）。

这一轮换掉了上一版形态：**不再开窗**（附庸窗 / 新窗口都已撤），改成主窗内的内嵌视图 +
顶栏右侧的站点标签条。旧形态的取证留在 `evidence-webtab-owner-windows.md`（那份现在只代表
`setOwnerWindow` 这个**框架能力**本身，不再代表 ai-chat 的网页版形态）。

## 判据与读数

| 项 | 读数 | 说明 |
|---|---|---|
| 内嵌视图建在主窗内 | `[cj-bridge] view create: rect=248,56 1056x777 url=https://www.kimi.com/ -> 9` + `view ready: id=9 rect=248,56 1056x777 visible=1` | 视图是主窗的子窗口，矩形由页面按 `getBoundingClientRect()` 上报（client 坐标 = DIP） |
| 页面真的渲染出来 | 截图 `.atomcode/tp-shot.png`（1320×860）：Kimi 首页完整绘制在顶栏以下的内容区，不是白块 | 「可见」的判据是画出来的内容，不是 `visible=1` 日志 |
| 标签条在顶栏右侧 | 截图顶栏一行：`☰` 之后是 DeepSeek / Kimi / 通义千问 / 智谱清言 / 文心一言 五枚标签，各带 `×` | 侧栏里那排标签**已撤**（侧栏只剩站点库卡片）；标签条住在顶栏里，所以内嵌视图的矩形（取 `topbar.bottom`）自动把它让出去，不必另算偏移 |
| 切到会话态才显示聊天控件 | 同一张截图：网页视图下顶栏只剩 `☰` + 标签条，`新会话`（会话标题）/ `未配置服务商` / `模式: 聊天` / `主题: 系统` / `紧凑: 关` 全部不见 | 规则是 `body.web-live` 上做 `display:none`；回会话态（`hideWebViews()` 摘掉该类）即恢复 |
| 矩形跟随窗口尺寸 | `[cj-bridge] view bounds: id=9 rect=248,56 1056x765`（主窗 1320×860） | resize / 侧栏折叠 / DPI 变化都会重报；节流 80ms |
| 视图上限 4 + LRU 淘汰 | `view destroy: id=3` 紧接 `view create: … -> 7`；`id=4` → `8`；`id=5` → `9` | 满 4 个就淘汰最久没用过的那个（**不淘汰本次要显示的**）；标签条本身可以多于视图数，点回去时重建视图、登录态仍在（同一用户数据目录） |
| 页面侧探针 | `[aichat] WEBTAB 9/9` | 探针直连命令（不经侧栏），9 条断言全过 |
| 默认窗口 | 1320×860 | 上一版 1080×760 偏小，实机看过之后放大 |

## 怎么复现

1. 复制一份独立副本（自己的 `ui/`、`capabilities/`、`main.exe`、独立 `LOCALAPPDATA`）——
   与正在使用的实例共用桥日志和 WebView2 用户数据目录会让证据串台。
2. 启动后点侧栏「网页」→ 点任意站点卡片；或带 `CJ_AICHAT_PROBE_WEBTAB=1` 让页面探针自己开
   （探针收尾会隐藏视图，所以**看界面要人点**，探针只用来对命令读数）。
3. 截图用 `PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)`（普通 `BitBlt` 只能拍到空白，
   见 AGENTS §4），并且抓之前把窗口顶到最前、挪进屏内——否则拍到的是压在上面别的窗口。
4. 判据：截图里能看到站点标签条在顶栏右侧、站点页面本身画在内容区、聊天控件不在。

## 本轮未取证（不要当成已验）

- **Linux 侧未实机**：`native/platforms/linux/bridge_linux.c` 与 `src/host_webkit.cj` 已按同一契约
  实现（GtkOverlay 打底 + GtkFixed 覆盖层，多 `WebKitWebView`），但本机没有 GTK 栈，没编译过、
  更没跑过——文档一律按「未实机验证」写。
- **鸿蒙侧是如实降级**：`hostCapabilities()` 的视图位为 0，`webtab:*` 当场返回业务错误，
  不是「支持」。
- **多显示器 / DPI 切换只验了同一块屏内的窗口缩放**，跨屏不同缩放比没有单独取证。
