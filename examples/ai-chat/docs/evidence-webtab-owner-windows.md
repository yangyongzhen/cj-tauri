# 证据：网页版窗口作为附庸窗（Windows 桌面，2026-10-25）

> **这份证据现在只代表 `setOwnerWindow` 这个框架能力本身**：ai-chat 的网页版入口已经改成
> **同窗内嵌视图 + 顶栏标签条**（不再开窗），形态取证见 `evidence-webtab-embedded-windows.md`。
> 保留下文是因为附庸窗这条路仍是公开 API，将来有「独立窗口但不占任务栏」的场景还要用它。

对应能力：`WebViewHost.setOwnerWindow(label)` + C 桥 `cj_bridge_set_owner_window`。
取证对象：`examples/ai-chat` 的网页版窗口（`webtab:open` 开出的 DeepSeek 窗口）。

## 判据与读数

| 项 | 读数 | 说明 |
|---|---|---|
| 属主回读 | `owner window applied: owner=0x50290 GetWindow(hwnd,GW_OWNER)=0x50290` | 桥日志；设置值与 `GetWindow(GW_OWNER)` 回读一致 = Windows 真认了这层父子 |
| 附庸窗 ex-style | `hwnd=0x2A05F8 owner=0x50274 toolwindow=YES visible=yes title=DeepSeek — 网页版` | `WS_EX_TOOLWINDOW` 置位 = 不进任务栏 / 不进 Alt-Tab |
| 主窗对照 | `hwnd=0x50274 owner=0x0 toolwindow=no title=AI 对话` | 主窗照旧是普通应用窗（owner 为空、无 toolwindow 位） |

`toolwindow=YES` 与「owner 指向主窗」两者同时成立，才算「它不另占一格」——
单独看 owner 可能是别的用途，单独看 toolwindow 位则说明不了它属于谁。

## 怎么复现

1. 带 `CJ_AICHAT_PROBE_WEBTAB=1` 启动 ai-chat（页面自检的 `webtabProbe()` 会自己开窗，
   不依赖人点卡片），并且**用独立的 `LOCALAPPDATA`** —— 否则与正在使用的实例共用桥日志与
   WebView2 用户数据目录，证据会串。
2. 用只读探针枚举该 pid 的顶层窗口（`EnumWindows` + `GetWindow(h, GW_OWNER)` +
   `GetWindowLongW(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW`），逐窗打印
   `hwnd / owner / toolwindow / visible / state / title`。
3. 判据：网页版窗口那行必须是 `toolwindow=YES` 且 `owner` 等于主窗 hwnd。

## 本轮未取证的一项（不要当成已验）

**「主窗最小化时附庸窗一起收起」没有拿到干净读数**：一次 `SW_MINIMIZE` 之后
`IsIconic(主窗)` 与随后的窗口枚举读数互相矛盾（前者 `iconic=True`、后者 `state=norm`），
中间隔了约 2 秒，怀疑被应用的托盘隐藏/恢复逻辑打断。要验它得在**同一次调用内**先最小化主窗、
立刻枚举两扇窗的状态，或改用 `SW_HIDE`（Windows 对 owned windows 的隐藏联动更确定）。
在那之前，文档只声明已取证的部分：不进任务栏与 Alt-Tab。
