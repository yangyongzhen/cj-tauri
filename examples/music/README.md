# 音乐播放器示例（`examples/music`）

一个用 cj-tauri 写的桌面音乐播放器：**深色三栏界面**（左侧导航 / 中间榜单·搜索·歌单 / 右侧「正在播放 + 同步歌词」）
+ 底部播放条，能拉榜单、搜歌、点播、跟着歌词滚动、收藏、记最近播放，还能把收藏当歌单**分享到后台**。

它同时是**框架能力的一次综合演示**：数据全部经 `invoke` 由仓颉侧取回（前端一次 `fetch` 都不发），
封面走宿主侧防盗链代理，收藏落本机 JSON，并且自带一套**无人值守自检**——跑完把结论写成日志行，
不用靠「看起来能用」。

![热门榜单（首页）](../../docs/images/example-music.png)

![播放中：搜索 + 同步歌词 + 唱片随封面转](../../docs/images/example-music-playing.png)

## 什么是 cj-tauri

[cj-tauri](../../README.md) 是用**华为仓颉语言**实现的类 Tauri 2 混合开发框架：
**仓颉后端（静态编译）+ 系统 WebView 前端（HTML / CSS / JS）**。三件套与 Tauri 一一对标：

| cj-tauri | 对标 Tauri 的 | 在这个示例里落在哪 |
| --- | --- | --- |
| WebView 宿主 | tao / wry | C 桥 `native/bridge_win.c`（WebView2）/ `native/bridge_linux.c`（WebKitGTK） |
| IPC 双向桥 | invoke / resolve / event | 页面 `window.__CJ_TAURI__.invoke('music:hot')` → 仓颉侧 `CommandHandler` |
| 能力安全模型 | capability 白名单 | `capabilities/default.json` 里逐条声明命令与事件 |

平台状态：**Windows（WebView2）与 Linux（WebKitGTK）已实机跑通**，鸿蒙 ArkWeb 为架构预留位。

本示例是**框架的一个普通应用**：框架源码一行没改，应用侧只写三样东西——
`src/`（仓颉后端）、`ui/`（页面）、`capabilities/`（白名单）。换句话说，
**看懂这个示例 ≈ 会写一个 cj-tauri 应用**。

> 框架自身的能力（宿主菜单 / 插件体系 / 命名权限集 / 打包发版）看仓库根的
> [`README.md`](../../README.md) 与 [`docs/使用文档.md`](../../docs/使用文档.md)；
> 开发契约与「禁止重踩的坑」看 [`AGENTS.md`](../../AGENTS.md)。本 README 只讲这一个应用。

## 用 cj-tauri 生成本项目

`examples/music` 不是手搓的骨架，而是**脚手架生成 + 定制**：一条 `cj-tauri create music` 得到一个能跑的
空应用，再往里填业务。下面是复刻它的完整路径。

### 1) 准备 CLI

CLI 就在框架仓库里（仓颉源码，`cli/src/` 5 个文件），**不用单独安装**：

```bash
# Windows
cli\cj-tauri.bat --version

# Linux / Git Bash
bash cli/cj-tauri.sh --version
```

首次运行会自动用 `cjpm build` 构建 CLI 本体，并按 SDK `envsetup.bat` 的那套目录布局设好 PATH
（运行时库目录 + `bin` + `tools\bin` + `tools\lib`）——所以**前提是本机装了仓颉 SDK + stdx**；
SDK 不在默认位置时用 `CANGJIE_HOME` 指定。

### 2) 一条命令创建

```bash
cd <你想放项目的目录>          # 父目录，create 会在里面新建 <项目名>/
<框架仓库>/cli/cj-tauri.bat create music      # Linux 用 cli/cj-tauri.sh
```

真实输出（2026-10-08 本机实跑，两处本机绝对路径已换成占位符）：

```text
[cj-tauri] 已创建项目 music/（6 个文件）

  项目名   : music
  模板     : app
  仓颉包名 : music
  框架依赖 : <框架仓库根目录>
  stdx     : <stdx 动态库目录>

下一步:
  cd music
  cj-tauri dev          # 构建 C 桥 + 编译 + 启动窗口
  cj-tauri build        # 仅构建

提示: cjpm.toml 里的路径是本机绝对路径；换机器需重新执行 create 或手改这两处。
```

生成的 6 个文件（行数是实测）：

| 文件 | 行数 | 里面是什么 |
| --- | --- | --- |
| `cjpm.toml` | 22 | 应用构建配置：`[dependencies] cjTauri = { path = … }` + `[target.<triple>]` 链接参数 |
| `src/main.cj` | 88 | 入口：`greet` / `timer`（推事件）/ 菜单演示 + `app.run(html)` |
| `ui/index.html` | 118 | 演示页：`invoke` / `listen` / 插件 shim 的用法样板 |
| `capabilities/default.json` | 7 | 白名单：`greet` / `timer` / `system:*`，事件 `tick` / `menu:click` |
| `README.md` | 80 | 模板自带说明：加命令、推事件、窗口配置怎么写 |
| `.gitignore` | 16 | 构建产物 + 平台动态库 |

几条 `create` 的规矩（源码在 `cli/src/scaffold.cj`，实测一致）：

- **项目名要能推出仓颉包名**：必须以字母开头，只含字母 / 数字 / `-` `_` `.`；
  分隔符后面首字母会转大写（`my-app` → 包名 `myApp`）。推不出来直接报错退出。
- **目标目录必须不存在**：已存在就报 `[cj-tauri] 错误: 目录已存在: …`，不会覆盖。
- **模板**：`--template app`（缺省，内联 HTML 单文件、零 Node 依赖）/ `vue`（Vue 3 + Vite）/ `react`（React 18 + Vite）；
  `vue` / `react` 会多带一套 `ui/` 前端工程，`cj-tauri dev` 会接管它的 Vite dev server，
  改 `ui/src` 下的前端源码不重启应用就能看到效果（页面走 `CJ_TAURI_DEV_URL`）。
  也可以直接写仓库里自建的模板目录名（`cli/templates/<名字>`）。
- **换机器要重新 `create` 或手改两处**：`cjpm.toml` 里的框架依赖路径与 stdx `path-option` 是本机绝对路径。
  本项目就是把它改成了仓库内相对路径（见下表）。

### 3) 日常子命令

| 子命令 | 干什么 | 什么时候用 |
| --- | --- | --- |
| `cj-tauri dev` | 构建 C 桥 + `cjpm build` + 启动窗口 | 开发时最常用（Vite 模板还会顺带起 dev server） |
| `cj-tauri build` | 构建 C 桥 + `cjpm build` | 只想要产物 |
| `cj-tauri run` | 运行已构建产物（不再编译） | 产物是最新的、只想再开一次 |
| `cj-tauri info [--json]` | 环境自检 / 打印插件装配清单 | 排障；`--json` 供 CLI 之间消费 |
| `cj-tauri help` | 帮助 | —— |

`create` 之后**先建 C 桥**这一步 `dev` 会替你做——注意 `native/libcjtbridge.dll`（或 `.so`）是**本地产物、不入库**，
换机器 / 拉过改 C 桥的提交后必须重建，否则会在链接期炸出一串 `undefined reference to cj_bridge_*`（`AGENTS.md` §4）。

### 4) 从空模板到本项目：改了什么

| 位置 | `create music` 生成的 | 本项目 |
| --- | --- | --- |
| `cjpm.toml` | 依赖写**本机绝对路径**，只有本机那一个 `[target.<triple>]` | 依赖改仓库内相对路径 `../..`；补上 **Linux + Windows 两个 target**；包名 `music` → `music_app` |
| `src/` | 单文件 88 行（`greet` / `timer` / 菜单演示） | **6 个文件 1 371 行**，按单一职责拆分（`main` / `commands` / `api` / `cover` / `lrc` / `store`） |
| `ui/index.html` | 118 行演示页 | **3 657 行**：深色三栏播放器 + 同步歌词 + 页面自检 |
| `capabilities/default.json` | `greet` / `timer` / `system:*`，事件 `tick` / `menu:click` | **12 条命令**（`music:*` / `fav:*` / `report` / `system:version`），不再用事件 |
| `.gitignore` | 构建产物 + `*.dll` | 多一行运行期数据 `music-library.local.json`（本机收藏与最近播放） |
| `run.bat` | 无（模板只给 `cj-tauri dev`） | 新增纯 ASCII 的 `run.bat`：一键构建 + 起窗口 + 两档自检 + stderr 落盘 |
| `README.md` | 模板自带「怎么写命令 / 事件」说明 | 换成这个示例的用法、取证与踩坑清单（就是本文件） |

也就是说：**脚手架负责「能跑起来」，本项目负责「业务 + 取证」**。想自己写一个新应用，改的也是这几处。

### 5) 往应用里加东西：记住「三处联动」

脚手架模板自带一节说明，本示例又把它验证了一遍——这是最容易漏的地方：

| 要加的东西 | 三处联动（漏一处就用不了） |
| --- | --- |
| 一个命令 | ① 实现 `CommandHandler` ② `app.register("名字", …)` ③ 在 `capabilities/default.json` 的 `commands` 里声明 |
| 一个插件 | ① 实现 `Plugin`（`src/plugin_<名字>.cj`）② `app.plugin(XxxPlugin())` ③ 能力清单里声明 `"<插件名>:<短名>"` |
| 一个宿主能力 | ① 扩 `WebViewHost` 接口 ② 改各平台实现 ③ C 桥加**同名同签名**的 `cj_bridge_*` 导出 |

漏 ① / ③ → `command not registered`；漏 ③（只注册、不声明）→ `command not allowed`。
命令的参数校验、异常回投、日志前缀这些约定见本文件 §4 与 §5，架构层面的硬规矩见
[`AGENTS.md`](../../AGENTS.md) §2。

## 0. 说明

- 榜单 / 歌词 / 歌单数据来自公开教学接口（`http://49.235.52.102:8000`，网易热歌榜），**仅供框架示例使用**；
  音频是第三方外包播放地址，随时可能失效。封面与音频的版权归各权利人所有，请勿商用。
- 本项目以 MIT 发布，但**不包含**上述第三方数据与音频。

## 1. 这个示例演示了什么

| 你看到的功能 | 用到框架的哪一块 | 落点在哪个文件 |
| --- | --- | --- |
| 三栏深色播放器界面 | `run(html)` 内联页面（`ui/index.html` 独立文件，启动时读入） | `src/main.cj` + `ui/index.html` |
| 拉榜单 / 搜索 / 歌单 / 歌词 | `invoke` → 命令 → 仓颉侧 HTTP | `src/commands.cj` + `src/api.cj` |
| 封面防盗链取图 | 宿主侧带 `Referer` 取回，再以 `data:` URL 交还页面 | `src/cover.cj` |
| 音频播放与进度 | 页面 `<audio>` 直连外包地址（**不走 IPC**） | `ui/index.html` |
| 歌词同步滚动 | LRC 在仓颉侧解成「毫秒 → 行」数组 | `src/lrc.cj` |
| 收藏 / 最近播放 | 仓颉侧写本机 `music-library.local.json` | `src/store.cj` |
| 分享歌单到后台 | `POST /api/v1/createsongmenu` | `src/commands.cj` |
| 无人值守自检 | 页面侧结论经 `report` 回投 stderr + `music:quit` 收尾 | `ui/index.html` + `src/commands.cj` |

## 2. 五分钟跑起来

前置：Windows + WebView2 Runtime、仓颉 SDK 1.2.0 / stdx 1.2.0.1，
并且**先建过 C 桥**（`native\build_win.bat`，`native\libcjtbridge.dll` 与
`native\webview2\WebView2Loader.dll` 是本地产物、不入库）。

```bat
cd examples\music

run.bat             :: 正常玩：开窗口，自己点歌
run.bat selfcheck   :: 无人值守自检（只读后台 + 只写本机收藏），跑完自己退出
run.bat selfcheck2  :: 自检 + 往后台**写**一条歌单（会真的提交到共享后台）
```

跑起来的判据看 stderr 日志（`run.bat` 直接把它打到控制台；文件在 `%TEMP%\cj-music-app.log`）：

```text
[music] main start
[music] 后台接口：http://49.235.52.102:8000（可用环境变量 CJ_MUSIC_API 覆盖）
[music] 收藏已载入：songs=0 recent=1
[music] 前端页面已载入：ui/index.html（96187 字节）
[music] /api/v1/musicmenus -> 200 ok bytes=7831
[music] image http://p2.music.126.net/…/109951173454764907.jpg?param=200y200 -> 200 ok bytes=4194 image/jpeg (200px)
[music] lyric sid=3397958994 lines=32
[music] fav set: songs=1 saved=true
```

配置项都能用环境变量覆盖，不必改代码：`CJ_MUSIC_API`（后台地址）、`CJ_MUSIC_SELFCHECK`（0/1/2 自检等级）、
`CJ_MUSIC_LIBRARY`（收藏库路径）。页面右侧边栏底部会把当前生效的值显示出来，省得猜。

## 3. 文件分工

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `src/main.cj` | 72 | 窗口配置、装配命令、载入页面 |
| `src/commands.cj` | 608 | 命令层：参数校验 → 调接口 / 读写收藏 / 取封面 |
| `src/api.cj` | 166 | HTTP 传输层（超时、redirect、TLS、浏览器 UA） |
| `src/cover.cj` | 207 | 封面取回：白名单、剥代理、缩略计划 |
| `src/lrc.cj` | 224 | LRC 解析（多时间戳行、去前缀、毫秒换算） |
| `src/store.cj` | 94 | 本机收藏库（JSON 文件读写 + 上限夹取） |
| `ui/index.html` | 3657 | 全部界面与交互（含页面自检），独立文件、不走三引号字符串 |

## 4. 命令 ↔ 后台接口

| 命令 | 参数 | 后台 | 备注 |
| --- | --- | --- | --- |
| `music:hot` | `{start?, count?}` | `POST /api/v1/musicmenus`（`kind=topWyMusic`） | 实测**只有这一个 kind 有数据**，其余一律 400 `mongo: no documents in result` |
| `music:search` | `{q, start?, count?}` | `POST /api/v1/musicsearch` | 空 `q` 在仓颉侧就拦掉，不发请求 |
| `music:menus` | `{start?, count?}` | `GET /api/v1/getsongmenu` | **不带 `start` 会 400**（`field start is not set`），参数必须给全 |
| `music:lyric` | `{sid, kind?}` | `GET /api/v1/musicsearchlrc` | 返回 LRC 文本，解析在仓颉侧做 |
| `music:image` | `{url, size?}` | —— | 宿主侧取图；`size` 是缩略边长，`0` 表示原图 |
| `music:share` | `{title, user, email, note?, cover?, songs[]}` | `POST /api/v1/createsongmenu` | 把收藏当歌单提交；必填项在仓颉侧校验 |
| `fav:get` | `{}` | —— | 读本机收藏库，顺带回 `path` 供界面显示 |
| `fav:set` | `{songs?, recent?}` | —— | 覆盖对应字段并落盘（**返回 `ok`，不是 `saved`**） |
| `music:config` | `{}` | —— | 暴露 `apiBase / libraryPath / selfCheck / hotKind / pageSize` 给页面 |
| `music:quit` | `{}` | —— | 退出应用（自检收尾用，照搬 `typing-poem` 的 `typing:quit`） |
| `report` | `{line}` | —— | 页面侧把结论回投仓颉侧 stderr（前缀 `[frontend]`） |
| `system:version` | `{}` | —— | 框架内置命令，这里用来在界面上显示框架版本 |

三处联动一个都不能少（`AGENTS.md` §2）：实现 `CommandHandler` → `app.register("名字", …)` →
在 `capabilities/default.json` 的 `commands` 里声明。少一处就是 `command not registered` / `command not allowed`。

`music:image` 这条要**单独说一句**：它的参数是页面可控的 URL，所以仓颉侧做了**图源白名单**
（百度图片代理 / 网易图床 / QQ 音乐图床），不在白名单里的地址直接拒绝——否则这个命令等于对外开放 SSRF。

## 5. 四个值得单独讲的设计

### 5.1 封面：防盗链 + 缩略，709 KB → 4 KB

后台给的封面**全是百度图片代理**（`image.baidu.com/search/down?url=…`），而这个代理按 `Referer` 放行。
实测（2026-10-08，同一张网易封面）：

| 取法 | 结果 |
| --- | --- |
| 百度代理 + `Referer: https://image.baidu.com/` | 200 + 真图（149 706 / 709 326 字节） |
| 百度代理 + 别的 Referer 或不带 | **200 + `image/jpeg` + 0 字节** |
| 直连网易图床，不带 Referer | 200 + 原图（709 326 字节） |
| 直连网易图床 + `?param=200y200` | 200 + **4 194 字节** |
| 直连网易图床 + `?param=500y500` | 200 + 21 996 字节 |

「200 + 空 body」是最坑的失败形状，而**页面侧无解**：浏览器只允许用 `Referrer-Policy` *减少* Referer、
不允许替换，何况本应用的页面是 `run(html)` 从字符串载入的（来源 opaque，连相对地址都不成立）。
所以封面只能由仓颉侧带对 `Referer` 取回，再以 `data:` URL 交给页面。

缩略只对**网易图床**做（地址在代理串里是明文、`?param=` 是它自己的参数，注意是 `y` 不是 `x`），
其它图源保持原尺寸——没实测过的图源，宁可大一点也不要猜错参数把图取空。榜单一次 30 首，
按原图就是约 21 MB base64 灌进 DOM，而列表里那个框只有 56 px：**列表按 200 取、主视觉与「正在播放」按 500 取**，
拿不到就回退原图。尺寸一律在仓颉侧夹进 `[48, 2048]`，页面传来的值不当真。

前端侧配套做了三件事（`ui/index.html` 的封面加载器）：**按 url 缓存 Promise**（同一张图只取一次）、
**并发上限 4**（一次 30 张不至于把命令线程打满）、**失败 resolve 成 `null` 而不是 reject**（一张图取不到不该让整屏报错）。

### 5.2 歌词在仓颉侧解成「毫秒 → 行」

页面拿到的不是 LRC 原文，而是 `{ms, text}` 数组（`src/lrc.cj` 解析）：

- **页面拿不到文件**：内联来源是 opaque origin，相对地址与 `file://` 都不成立，读歌词只能走 `invoke`；
  既然要走 IPC，就别把「解析」这件确定的事拆两次做——仓颉侧解完，页面只管显示。
- **口径统一**：多时间戳行（`[00:12.34][01:20.00]同一句`）、`[ti:]`/`[ar:]` 元信息、空行、
  半角与全角空白，全部在一处收口；页面侧只做一次二分查找定位当前行。
- **可断言**：自检能直接数出行数、跳到第 5 行的时刻再看高亮索引，把「歌词跟得上」变成一条日志。

解析里踩过一个坑：去空白只该去 **ASCII** 空白。`String.size` 数与 `String` 迭代得到的都是**字节**
（`AGENTS.md` §4），拿「字符数」当长度去找文本，汉字（3 字节）就会错位——所以 `trimAsciiText` 只处理
空格 / 制表 / `\r`，不碰汉字。

### 5.3 音频播放留在页面侧，不走 IPC

播放地址由 `music:hot` / `music:search` 随条目一起返回，页面直接 `audio.src = item.url`。
把音频字节搬进 IPC 再解码成 blob 是没必要的（几十 MB 走一次 `invoke`，还得自己管缓冲），
而进度条、`duration`、`error` 这些事件本来就在页面侧。

两个实证细节：

- **自动播放策略会拦下「带声音的起播」**：自检里先 `muted=true` 起播，验完再解除静音——
  否则只会拿到一句 `NotAllowedError`，什么都没验到。
- **`currentTime > 0 && duration > 0 && readyState >= 2`** 才算「真的在解码播放」，
  光看 `src` 设上了没用（自检第 ④ 项就是这么断言的）。

### 5.4 收藏与「最近播放」写在本机 JSON，不用 localStorage

`fav:get` / `fav:set` 读写 `music-library.local.json`（路径可用 `CJ_MUSIC_LIBRARY` 覆盖）。
放仓颉侧的理由：清浏览器缓存不该把收藏清掉；而且这份数据还要参与「分享歌单」——
数据在仓颉侧，提交时不用再从页面搬一遍。

三条纪律：

- **整份回写 + 上限夹取**：`songs` 最多 500、`recent` 最多 100，写入前夹一次（页面可控的数组长度不当真）。
- **落盘失败必须喊**：写不进去要打 `[music] fav set … saved=false` 并把错误回投给页面，
  不能让界面以为存上了——「日志里没有错误行」不等于「成功了」（`AGENTS.md` §4 的教训）。
- **写后读回**：`fav:set` 返回前会把文件重新读一次再报 `songs=N`，自检第 ⑧ 项就是拿这个数对账。

### 5.5 分享歌单：写后台的动作只放在等级 2

「分享」是全示例唯一**往共享后台写数据**的功能，所以：

- 表单必填项（标题 / 昵称 / 至少一首歌）在**仓颉侧再校验一遍**，不合格直接 reject；
- 提交失败**不关弹窗**、回显后台的 message，用户可以改完重试；
- 自检里这一项**默认跳过**（`run.bat selfcheck` 会打印一条 SKIP），只有 `selfcheck2` 才真的提交——
  默认行为不该去动别人的共享数据。

## 6. 页面自检：两档，读写在文件里分家

`CJ_MUSIC_SELFCHECK=1`（或 `2`）时，页面启动后自动走一遍全链路，每条结论经 `report` 回投仓颉侧 stderr；
跑完自己调 `music:quit` 退出，`run.bat selfcheck` 才有终点（这里照搬了 `typing-poem` 的收尾方式）。

| 等级 | 覆盖 | 会写什么 |
| --- | --- | --- |
| —— | ①～⑩：榜单 / 可播地址 / 封面 / **真的在解码播放** / 歌词行数 / 高亮跟随 / 收藏落盘与读回 / 最近播放 / 后台歌单列表 | 只写本机收藏库（临时的收藏会撤掉），后台只读 |
| `2` | 追加 ⑪ 分享歌单到后台、⑫ **写后读回**（在后台列表里读到刚提交的标题） | 会往后台提交一条歌单 |

⑫ 存在的理由：只断言 `code=0` 证明不了「别人也能看到」。后台这条链路的承诺是「提交完出现在歌单页」，
所以取 50 张列表、按标题精确比一遍。实测新提交的**排在列表尾部**，一开始按 20 张取差点刚好漏掉。

实测结果（2026-10-08，Windows 实机）：

```text
[frontend] [自检] PASS ③ 封面经宿主代理取回 — 5615 字节，前缀 data:image/jpeg;base64…
[frontend] [自检] PASS ④ 音频真的在解码播放 — paused=false currentTime=0.44s duration=180.2s readyState=4
[frontend] [自检] PASS ⑥ 歌词高亮跟随播放位置 — 跳到第 5 行（35220ms）后 lyricIdx=4
[frontend] [自检] PASS ⑩ 后台歌单列表取回 — 7 张；首张「猫哥的收藏」（30 首，分享者 王工）
[music] share title=自检歌单 10/8 22:03 songs=1 skipped=0 -> code=0 message=Success
[frontend] [自检] PASS ⑫ 分享的歌单能在后台列表里读到 — 第 8/8 张，含 1 首
[frontend] [自检] 汇总：10 passed / 0 failed      ← 等级 1
[frontend] [自检] 汇总：12 passed / 0 failed      ← 等级 2
```

### 想自己取证、又不想打扰正在跑的窗口

自检会**写本机收藏库**、还会共用同一个 WebView2 用户数据目录，所以别在用户正听歌时直接起第二个实例。
本仓的做法是在 `.atomcode/probe/` 里放一份**独立副本**：拷 `ui/` + `capabilities/` + `main.exe`，
再写一个纯 ASCII 的 `check.bat`（设 `PATH`、起应用、stderr 落本地 `err.log`）。
副本目录自己带 `music-library.local.json` 与 `main.exe.WebView2/`，跟真实示例完全隔离——
档案级的取证建议都这么跑。

## 7. 踩坑清单（本示例新增的、可复用的）

1. **百度图片代理按 `Referer` 放行，失败形状是「200 + 0 字节」**——不是 403、不是 404，日志里看着像成功。
   取图必须同时看 `bytes=`：这个示例的 `[music] image …` 每行都带字节数。
2. **网易图床的缩略参数是 `?param=WxH`（`y` 分隔）**，不是常见的 `?w=&h=`；而且**必须先剥掉百度代理**，
   直接对代理串拼参数没用。只对实测过的图源做缩略，别的保持原样。
3. **`GET /api/v1/getsongmenu` 不带 `start` 直接 400**（`field start is not set`），
   参数要一次给全（`start` + `count`）。
4. **`/api/v1/musicmenus` 只有 `kind=topWyMusic` 有数据**，其余 kind 一律 400 `mongo: no documents in result`。
5. **三栏布局里标题会被挤成两行**：`.view-head` 是 flex 行，标题默认可以收缩，
   中间那栏一窄就把「热门歌曲」折成「热门歌 / 曲」。修法是标题 `flex: 0 0 auto; white-space: nowrap`，
   让说明文字那一段（`min-width: 0; flex: 1 1 auto`）去收缩截断。这条是**抓图时人眼发现的**，
   自检的断言全绿也照样有这种毛病。
6. **分享标题的时间戳要两位补零**：第一版拼出 `自检歌单 10/8 22:0`，看着像时间算错。
7. **写后读回要取够条数**：后台列表是「旧的在前、新提交的在尾部」，按 20 张取差点刚好漏掉刚提交的那张；
   现在取 50 张再按标题精确比对。
8. **内联页面里的 JS 不要写反斜杠**：这是仓颉三引号字符串的坑（`AGENTS.md` §4）。
   本示例干脆把整个界面放进独立的 `ui/index.html`（启动时读文件），绕开转义与 `${}` 插值的全部问题；
   改完用 `node --check` 验一遍（把 `<script>` 内容抽出来检查即可）。
9. **别在用户正听歌时起第二个实例取证**：两个实例会共用同一个 WebView2 用户数据目录，
   而且都要写同一个收藏库。要跑自检就复制一份独立副本（见 §6 末尾）。
10. **封面被「拉伸」，根因是给 `div` 写了 `object-fit`**：`fillCover` 是用 `innerHTML` 插进去的 `<img>`，
    **没有类别、也没有内联尺寸**，所以只写 `.hero .art { object-fit: cover }` 是写在 `div` 上的死规则——
    换来的是每张封面都被拉长。正确做法是给**每个容器各配一条 `img` 规则**
    （`.banner .art img { width: 100%; height: 100%; object-fit: cover }` 这类）。
    这条同样是**抓图后我人眼发现的**：自检断言全绿（图能解码、能渲染）不影响它在视觉上被拉扁；字号 / 版面
    这类只能靠眼睛的东西，断言证明不了。

## 8. 打包

和 `examples/movie` 一样，可以直接用仓库脚本打成**免 SDK 的便携包**：

```bash
bash scripts/pack-win.sh            # 目录式便携包
bash scripts/pack-win-single.sh     # 单文件 exe（loader 内嵌释放）
```

注意便携包必须自带 `WebView2Loader.dll` 与 `libssl-3-x64.dll` / `libcrypto-3-x64.dll`（仓颉运行时的
TLS 加载器），它们**不在 PE 导入表里**，手工抄 DLL 清单一定会漏——直接用脚本，别手写（`AGENTS.md` §4）。

## 9. 相关

- 本文件的「什么是 cj-tauri」「用 cj-tauri 生成本项目」两节——框架三件套速览 + 脚手架复刻路径
- `AGENTS.md` §2（架构契约）/ §4（禁止重踩的坑清单）
- `examples/movie`——「宿主侧代理取图 + 命令 worker + stderr 取证」这套做法的另一个样本
- `examples/typing-poem`——`QuitCommand` 收尾、自检脚本退出码约定
- `cli/`——仓颉原生脚手架（`create` / `dev` / `build` / `run` / `info`）与
  `cli/templates/` 三套模板（`app` 内联单文件 / `app-vue` / `app-react`）
- `docs/使用文档.md`——框架整体用法；`docs/RFC-插件体系.md`——插件与命名权限集的设计


