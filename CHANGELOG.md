# 更新日志（CHANGELOG）

本文件记录 cj-tauri 的对外可感知变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)：0.x 阶段只递增中间位（能力）与末位（修复），
打到 1.0.0 后才固定对外 API。

- 分类用 `Added` / `Changed` / `Fixed` / `Removed` / `Security`，中文描述；
- 每条写**能观测到的行为**（命令、API、文件、日志），不写内部重构流水账；
- 发版时更新的文件清单与校验方式见 `AGENTS.md` 的「版本与发版」一节；
  一致性用 `scripts/check-version.sh` 自检。

## [Unreleased]

（尚未发版的下一个版本，按 Added / Changed / Fixed / Removed 就地累积，
发版时把本段整体改名为 `[x.y.z] - YYYY-MM-DD`，并在下方新开一个空的 Unreleased。）

### Added

- **观影应用示例 `examples/movie`**：仓颉后端 + WebView 前端的完整业务样例（榜单 6 个 tab / 搜索 /
  详情 / 播放四个视图），`movie:list` / `movie:search` / `movie:detail` / `movie:source` / `movie:image`
  五命令与 `capabilities/default.json` 三处联动齐全，`run.bat` 一键跑并把 `[movie]` / `[frontend]` 留证。
  Windows 实机（2026-10-05）验证：桥 + 榜单 20 条 + 详情 + **未授权对照组被拒** + 53 次封面取图 40 次成功，
  stderr 无 `hr=` 非 0。
- **`movie:image`：宿主侧取图（`{url} → data:image/…;base64,…`）**：上游封面是防盗链资源——
  `image.baidu.com/search/down` 只在 `Referer: https://image.baidu.com/` 时给图，其它情况回
  **HTTP 200 + 0 字节**（不是 4xx），而 WebView 页面无法伪造 Referer（来源 opaque，且浏览器只允许
  *减少* Referer），故封面只能由仓颉侧带正确 Referer 取回。命令对地址做白名单（SSRF 防护）；
  页面侧以「并发 4 / 同址去重 / 失败不留缓存」的队列填充，取不到则回落到**生成式占位**
  （标题首字 + 按标题散列的色相渐变）。踩坑与实测数据见 `examples/movie/README.md`。
- **观影示例支持剧集（`tvurls`）**：后台 `mvsource` 对电视剧返回 `urls:[""]`（占位空串）+ `tvurls:[…]`，
  `urls` 有内容的才是电影。页面据此分流——`tvurls` 有值时播放器下方出「第一集 / 第二集 …」集数按钮
  （**下标即集数**，0 = 第一集），点集数切集并留 `[frontend] 切集：第 N 集` 日志，下面一行跟着显示
  当前集地址 + 复制；`tvurls` 为空、`urls` 有值仍走原线路列表。空串按位置占位丢弃。
  顺带修掉 `#source-list` 漏了 `class="source-list"`、导致该容器的行样式一直是死规则的问题
  （`markActiveSource` 改为按「电影 / 剧集」两种下标分别高亮）。
  Windows 实机（2026-10-06）验证：`凡人修仙传` 详情 → `movie:source(35861087) 剧集模式：112 集，
  从第一集起播` → 连续切集至第 112 集，`hr=` 全 0。
- **观影示例支持切换播放源（新命令 `movie:sourceitem`）**：后台 2026-10-06 改版把「一部片的全部播放源」
  与「某个源的剧集」拆成两个接口——`mvsource/{sid}` 只回**主源**的 `tvurls` / `urls`，另附全 20 个源的
  元信息（`items[]` 全字段 / `sources[]` 精简版，`primary` 标出主源），非主源的剧集要按 `note` + `aid`
  单独取 `mvsourceitem/{sid}?note=&aid=`（同一片实测 18738 字符 vs 改版前 ~139KB，主源 194 集）。
  示例据此在播放页剧集按钮**上方**新增「播放源」胶囊区（源名 + 分类 + 集数，当前源高亮，同名不同版本
  如「优酷 动漫 194 集」与「优酷 国产剧 30 集」靠分类区分；只有 1 个源时整区不显示），点源即切：
  `movie:sourceitem` 取回该源 `tvurls` 后**保留当前集数**重渲染集数按钮并从同一集起播（新源集数不够
  则落到它最后一集），播放页标题也跟着换（切到极速那个源会变成《凡人修仙传 重制版》）。
  命令按项目契约三处联动（`src/commands.cj` + `src/main.cj` + `capabilities/default.json`）；
  `note` / `aid` 是页面可控串，命令层做白名单（`note` 限 `[a-z0-9_-]` 且 ≤32，收窄到无需百分号转义；
  `aid` 只许数字、允许空串——单文件源的 `aid` 实测就是空）。真实失败形状：源不存在时后台回
  **HTTP 200 + `code:404` + `message:"source not found"`**（不是 4xx），页面因此判 `code` 而不是
  只看 invoke 是否被拒。离机自检（跑页面真函数 + DOM 桩）58 项全过；实机日志见
  `examples/movie/README.md` 的验收表。
- **文档：新增《`docs/cj-tauri-介绍与movie实战.md`》（666 行）**：面向「第一次听说 cj-tauri」的读者，
  按「它是什么 → 装环境 → 起一个工程 → 拿 `examples/movie` 当案例」的顺序讲，`movie` 那一半逐块拆
  命令层 / HTTP 层 / 前端（含防盗链取图、HLS 按源可播性、剧集与切源三个设计点），末尾给「看日志验收」
  的办法与三个真踩过的坑；根 `README.md` 的文档入口已挂链接。
- **应用层菜单 API（`TauriApp`）**：`setMenu` / `setMenuTo`（默认窗 / 指定窗）、`setMenuItemState(To)`、
  `setMenuItemEnabled(To)` / `setMenuItemChecked(To)`——菜单从「只能直接摸宿主」变成应用层可配。
  应用层留一份菜单模型，所以「只改启用 / 只改勾选」能拿**另一维**补齐：平台侧一次调用会同时写两维，
  补齐不到就会把用户刚点出来的勾选抹掉；id 在模型里找不到时抛 `CommandException`（不静默按 false 写）。
  宿主层接口（`WebViewHost.setMenu` / `setMenuItemState` / `setShellHandler`）一行未改。
- **shell 事件分发到应用与前端**：应用层新增**可叠加**钩子 `app.onShellEvent((json, label) => …)`
  （宿主层 `setShellHandler` 仍是单槽，由框架装一次做分发，取代「应用自己抢宿主槽位」），
  并按事件类型把事件投给前端：`menu` → `menu:click`、`tray` → `tray:click`、`drop` → `dragdrop:files`
  （需在能力清单的 `events` 里声明）。信封解析抽成纯函数模块（`src/shell_event.cj`）并补单测：
  坏报文只在 stderr 提示一次，不抛异常穿 FFI 边界。
- **内置命令 `system:host`**：返回宿主能力位 JSON `{platform, menu, tray, dragDrop}`——页面/CLI 可以先进
  它再决定要不要显示菜单入口，而不是「调了报错才知道平台不支持」。三处联动齐全（`src/api_system.cj`
  实现 + `TauriApp.run()` 注册 + 能力清单声明）。
- **官方插件 `menu`**：`menu:setEnabled` / `menu:setChecked` 两个命令 + 事件 `menu:click` +
  命名权限集 `menu:state`（集声明 ≠ 放行）；前端 shim 挂 `window.__CJ_TAURI__.menu.setEnabled / setChecked`，
  经 document-start 注入通道交付（`runUrl` 与内联 HTML 时序一致）。
- **脚手架模板带菜单示范**：`app` / `app-vue` / `app-react` 三个模板都装配 `MenuPlugin` + `setMenu()`，
  页面里给出两个调用点——`listen("menu:click")`（菜单 → 页面）与 `menu.setChecked(...)`（页面 → 菜单）；
  能力清单同步加 `"permissions": ["menu:state"]` 与 `"events": [..., "menu:click"]`。
- **Windows 便携包脚本 `scripts/pack-win.sh`**：`bash scripts/pack-win.sh [示例] [输出目录]` 把示例打成
  「解压即用」的目录 + zip（改名后的 exe、递归收集的运行期 DLL、`ui/`、`capabilities/`、
  自动生成的纯 ASCII `run.bat` 与面向最终用户的 `README.txt`）。依赖清单不手工维护：从 `main.exe`
  出发递归解析 PE 导入表取闭包，再补两个**导入表里没有**、运行期按名字 `LoadLibrary` 的组件——
  `WebView2Loader.dll` 与 `libssl-3-x64.dll` / `libcrypto-3-x64.dll`（缺后者时 http 正常、https 全灭）。
  `examples/movie` 已实测：干净目录 + 只留 `C:\Windows` 的 `PATH` 下窗口 / 页面 / 封面取图全部正常
  （`TlsException` 0 次），产物 16 MB（zip 7.9 MB）。`.gitignore` 增 `dist-win/` 与 `*.zip`。
- **菜单能力位补上 Linux 实机验证（新增 `examples/menu/run.sh`）**：此前只有 Windows 的验收
  （`run.bat` 14/14），Linux 侧 `native/bridge_linux.c` 一直是「写了、没跑过」。本轮在 GTK 3.24.41 +
  WebKitGTK 2.52.3 上补齐：`run.sh` 用 `xvfb-run` 隔离显示 → 起单窗探针 → 用 **`xdotool` 在原生
  `GtkMenuBar` 上发真实 X 鼠标事件**（对应 Windows 侧 `click-menu.ps1` 的 `PostMessage WM_COMMAND`）→
  判据全部取自桥的 stderr 日志，**三轮连跑同 21 条断言全绿、`exit=0`**。取证行：
  `menu applied: items=4 … bar_children=5 visible=1`（菜单栏真挂进竖向 `GtkBox`，5 个子件含分隔线）、
  `menu clicked: id=file.new` / `id=view.sidebar enabled=1 checked=1` / `id=edit.toggle`（鼠标事件走通
  GTK → core → 仓颉回调，`window=main shell {…}` 每下一条）、`set menu item: id=view.sidebar enabled=0
  checked=1` 紧跟 `menu item readback: id=view.sidebar sensitive=0 active=1`（应用回手改状态后由
  **GTK 侧读回**，与 Windows 的 `GetMenuState` 同口径），收尾 `single mode: quit requested` →
  `host destroyed` → `exit=0`。
  Linux 桥同时补了两处**可观测性**（Windows 侧已有对应物）：`menu item readback:` 读回真生效值；
  菜单几何**事后读回**——建完菜单、以及每次点击之后再从 GTK 读一次 `id=x+w+h` 打进日志，
  供驱动脚本把点击落在项中心。为什么要读而不是写死偏移：窗口位置每轮都不同（实测三轮分别
  0,0 / 34,57 / 216,239），写死像素偏移会点到隔壁项（第一版实机就点歪了）。
  **两窗路由这一维仍留在 Windows**：GTK/WebKitGTK 不能被两条线程各自使用，第二宿主一装配就 segv
  （见 `docs/架构演进-多平台与多窗口.md` §8），故 Linux 侧跑单窗模式。
- **探针 `examples/menu` 支持单窗模式**：`MENU_MODE=single` 只装配主窗，收尾由探针自己走
  `app.quit()`（应用级退出路径），因而 Linux 也能一并断言 `exit=0` 与 `host destroyed`；
  清单同时补上 `"events": ["menu:click"]`（菜单事件要投前端就必须声明）。Windows 侧双窗行为不变。
- **`WebViewHost.setDestroyHandler(handler)`：宿主级窗口销毁钩子**（每扇窗各装各的，回调不带参数
  ——「是哪扇窗」在装配时就已确定，应用可经 `app.hostOf(label)` 逐窗安装）。此前 `onDestroy`
  只是两个宿主实现的 `public var`、不在接口上，框架与示例都没装过，是个恒 no-op 的死钩子
  （框架退出靠轮询 `shouldQuit()`）；现在与 `setShellHandler` 一样可装配、且按宿主句柄派发。
- **打字练习示例题库扩到 108 首：覆盖全部小学古诗词**（`examples/typing-poem`，第三批实机反馈「古诗要多一点，
最好把小学该背的都收进来」）：21 → **108 首**（共 **2996 个音节**），取两套清单去重——「小学生必背古诗词 75 首」
+「部编版小学语文 1–6 年级古诗词汇总」；最短《采薇（节选）》16 字、最长《闻官军收河南河北》56 字，
选诗面板按音节数**升序**（难度递增，`stars()` 仍是 1★≤18 / 2★≤24 / 3★ 更长）。仓颉侧素材自检启动即报
「108 首、共 2996 个音节」，并逐字校汉字与拼音对齐（漏一字当场报错、列出诗名）。
- **`CJ_TYPING_POEM=<诗 id>`：打字练习开窗直奔某一首**（人眼验收钩子）：`set CJ_TYPING_POEM=changgexing`
再跑 `run.bat`，页面跳过选诗面板直接进那一首，`typing:config` 的日志也会写明「指定诗（id）」。
加它的理由是**版面只能靠眼睛**：几何断言能证明「放得下、不重叠」，证明不了「好看、不串行」——
有了这条通路，长诗分栏一开窗就是那一首，截图即可归档对比。写错 id 不算错：退回选诗面板并提示一句。
- **古诗打字练习示例 `examples/typing-poem`（小学生向）**：仓颉侧提供十首小学常背古诗（五言 / 七言共
  18–28 字，**逐字拼音**随诗一起收在 `src/poems.cj`）与本机最好成绩落盘（`typing-scores.local.json`，
  按首累计次数、只增记录），`poem:list` / `score:save` / `score:list` / `typing:config` / `typing:quit` /
  `report` 六命令按项目契约三处联动齐全；前端单文件 `ui/index.html` 用 **three.js r160**（UMD，
  连许可证收在 `ui/vendor/`，已在 AGENTS §5 登记）做 3D 星空与诗词卡片——照着拼音敲字母，
  打对一个字点亮一个字并冒星光、整首打完放礼花并结算速度 / 正确率 / 星级。three.js 经宿主的
  **预执行脚本**通道（`addInitScript`）注入：内联页面没有真实来源，相对 `<script src>` 与 ESM 都不成立
  （完整形状见 AGENTS §4）。
- **`examples/typing-poem` 玩法重设计：把「打字」变成「演奏 + 写诗」**（2026-10-07 第二轮，改动只在
  前端 `ui/index.html`，仓颉侧与能力清单一行未动）。起因是实机反馈「效果不好玩」，逐一诊断出六条根因——
  反馈无梯度（每键同音同粒子）、场景是死的、没有目标与张力、错误没痛感、结算是一张数字表、音效是单音提示音——
  据此重做反馈层：① **连击**：按「字」计（一个字打完才算写下一笔），连对越多音高沿**五声音阶**上行、
  纸面当前字的金框与星光换档、场景亮度随之上升，断连**只减半不归零**（对小学生宽容）；
  ② **世界随输入变化**：场景主题按诗 id 选——咏鹅→绿水白鹅、静夜思→月亮与霜、望庐山瀑布→瀑布水雾，
  其余走通用墨卷星云，每打完一整句推进一幕（`progress 0 → 0.25 → … → 1`）；
  ③ **每句高潮**：该句从纸上浮起成一块独立的 3D 文字（现做现销毁，不常驻）+ 一道墨光扫过 + 一声磬；
  ④ **错误有痛感**：朱砂墨点溅在**出错的那个字**上 + 卡片边框转红 + 全屏边缘红晕 + 一声低钝音；
  ⑤ **结算仪式**：礼花 + 卡面转成「整首写完」并盖朱砂印 + 三颗星逐个落下（每颗配一声），之后才亮结算面板。
  音效全部用 WebAudio 按五声音阶**现场合成**（零音频资源，也就不新增任何许可证义务）。
  页面里那份星级门槛只是**显示副本**，真值仍只在仓颉侧 `starsFor()`：自检有一条断言拿 `score:save`
  的回投反推它，两边漂移即 FAIL。
- **`examples/typing-poem` Windows 实机自检 46/46、`exit=0`**（2026-10-07，`run.bat selfcheck`，
  日志 `%TEMP%\cj-typing-poem.log`）：页面自己把《咏鹅》打完并把逐条断言回投 stderr。
  除原有通路外，新增的机制断言覆盖连击计数与「减半不归零」、五声音阶逐级上行、句末高潮（浮起 / 墨光 / 磬）、
  世界推进、结算仪式的亮相与三颗星；凭证如 `three.js 已注册为预执行脚本（669884 字节）`、
  `咏鹅切到专属场景 parts=root,water,goose,ripple`、`进度条由灰转绿 before=g107 after=g195`、
  `score:save … ★2 94.5% 落盘=true`、`poem:nope -> command not registered`、`46 passed, 0 failed`，
  桥 `hr=` 全 `0x00000000`（逐轮行数随渲染次数浮动，本轮 60 余行、无一条非零）。本轮自检还当场暴露过一次**断言自身写错**（连击 HUD 的亮相门槛
  是 3 连对，第一版断言按 2 写），已改成「按规则摆一次状态验门槛」——是断言错、不是产品错，如实记在这里。
- **（同上一轮）自检当场抓出两个真 bug 并已修**：① `score:save` 的用时经 `Int64()` 截断（一秒内打完 → 用时 0 →
  速度 0、星级被拖到最低）改按浮点算；② **画布尺寸停在初始化时的 961×1032**——WebView2 建 WebView 时
  视口还是临时尺寸，随后窗口定到 1164×741 却没有 `resize` 事件送到页面，3D 场景因此走样，
  改为每帧比对视口并补一条「画布 == 视口」的断言。
- **AGENTS §4 更正「迭代 `String`」那条坑**：原文写「得到的是 `UInt32` 码点」，实测是 **`UInt8` 字节**
  （`String.size` 同样是字节数）；按码点数汉字要自己判 UTF-8 首字节（`(b & 0xC0u8) != 0x80u8`）。
  新示例的素材自检正是踩在这条上：3 个字的「鹅鹅鹅」被数成 9，汉字 / 拼音对齐检查整条失效
  （ASCII 的检查——空格、制表符——照样对，所以只错汉字）。

### Changed

- **打字练习示例：长诗自动分左右两栏 + 弹层滚动条重配色**（第三批反馈「字够大了但长诗挤」「滚动条颜色不好看」）：
  此前一律单栏，靠 `vScale()` 按行数收字号——4 行的《咏鹅》满字号，10 行的《长歌行》被压到汉字 64px。
  现在**按字号算、不拍行数阈值**：每首**单栏与两栏各排一遍，谁算出的字大用哪套**（`cardLayout()`），
  于是《长歌行》10 行 → 两栏 5+5、汉字 **128px**（单栏只有 64px），4 行七言仍走单栏；
  全库 94 首单栏 / 14 首分栏。分栏是**竖切**：句序**先左栏后右栏**（上到下、左到右），行数多出的一栏补空行。
  卡面几何也收成一套（`rowTop` / `pinyinBaseY` / `charBaseY` 供排版与落点共用，`cardPoint()` 按纹理坐标换算），
  星光与朱砂点的落点由同一套几何**算出来**。弹层 `.panel`（选诗 / 结算面板，也是页面唯一的滚动区）的滚动条
  按纸墨重配色：深色玻璃轨道 + 淡金轴头、宽 12px（`::-webkit-scrollbar`，WebView2 = Chromium），
  自检里加了一条「规则确实生效且弹层可滚」的断言。
- **打字练习示例：卡面字号放大 + 诗库 10 → 21 首**（`examples/typing-poem`，按实机反馈「拼音和字体不够大、
  不够醒目，想再要多几首小学古诗」）：卡面格子 108 → 250px、汉字 104 → 156px、拼音 40 → 66px（**当前字
  80px**，另加一条浅金底衬把眼睛先拉到要打的那串字母上），标题 / 朝代作者 / 进度文字同步放大；
  **字号按行数自适应**（`vScale()`：4 行以内满字号，行数再多就按行高同比收，避免汉字压到下一行拼音），
  长音节（`chuang` 这类）按可用宽度自动收字号，不再顶到邻格。诗库从十首扩到**二十一首**：新增《画》《池上》
  《赠汪伦》《咏柳》《望天门山》《山行》《九月九日忆山东兄弟》《清明》《春日》《题西林壁》《游子吟》
  （6 行 30 字，唯一非四行的篇目），共 **524 个音节**、汉字与拼音逐字对齐（素材自检启动即校）。
  页面自检 46 → **52 条**，新增的 5 条是版面断言：字号确实放大、行内几何不串行、最长音节收得进格子、
  最宽一行留得住两侧墨边、星光落点与排版共用同一套几何。
- **观影示例的播放失败提示改为「不判因」**：播放器上原有文案断言「源站可能不允许跨域取流」，
  实机复核（2026-10-06）证明这话不成立——**多数源正常起播**（主源 `uku` 的 `ukzy.ukubf4.com`
  拿到 20:07 的 manifest 并出画面、可切集），失败的源里既有域名解析不了的（`cdn.wlcdn99.com`
  无 A/AAAA 记录）也有源站失效的。现在只给方向「原因可能是域名解析、跨域限制或源站失效」，
  保留「地址已列在下方，可复制到 VLC 等播放器」的可操作指引。
- **文档：`examples/movie/README.md` 重写为新手教程 + 3 张实机截图**：截图入
  `docs/images/example-movie{,-search,-detail}.png`（首页榜单 / 搜索 / 详情；播放页与剧集区两张
  后续按「不宜展示」撤下，`git rm` 并清掉两处 README 的引用）；README 按
  「三件套定位 → 5 分钟跑起来 → 一步步搭出来（命令三处联动 / 参数白名单 / 前端只走 invoke）→
  三个设计要点（防盗链取图 / HLS 与按源可播性 / 剧集分流与切源）→ 实机验收 → 踩坑 → 文件」组织，
  根 `README.md` 的示例区同步补 movie 入口与截图。顺带更正此前文档里「画面出不来」的旧结论
  （**播放链路是通的**，失败只是个别源）。
- **观影示例补「用途与免责声明」**：`examples/movie/README.md` 新增置顶声明（**仅用于技术学习与研究，
  请勿用于其他用途**；影视数据与播放地址均取自第三方公开接口、本示例不提供也不存储任何影视资源，
  请勿批量抓取或二次传播），根 `README.md` 的示例表条目与该小节前各加一条同样的提示并链过去。

### Fixed

- **命令失败不再「无声」：`IpcHub.runCommand` 的两处 catch 补 stderr 日志**：此前 handler 抛异常
  （业务级的 `CommandException` 也好、别的异常也好）只回一条 `reject`，仓颉侧**一行日志都不打**——
  前端要是没接 `catch`，这次失败就完全无痕（事件监听器那条路一直有 `event listener failed`，
  两条路不对称）。现在分别打 `[cj-tauri] command rejected (<命令>): <message>`（应用级拒绝）与
  `[cj-tauri] command failed (<命令>): <异常>`（非预期失败），前缀不同便于分流检索；
  **回投给前端的报文一字未变**，只多一条 stderr 行。`scripts/test.sh` 132/132 仍全绿。
- **打字练习示例：`score:save` 的 `bestAccuracy` 读写单位不一致，成绩从某一轮起再也存不下**（自检第 12 轮才抓到）：
  落盘按**百分比**写、读回按**分数**用，于是每轮**复利式 ×100**——实测该字段已涨到 `9630000000000000`
  （约 9.63e15），命中 `round1()` 里 `Int64(x * 10.0)` 的越界 → 命令抛异常，`score:save` 就此全废
  （页面只看到 `Cannot read properties of null (reading 'stars')`）。三处修：① 仓颉侧内部**一律用分数**
  （0..1），只在吐给页面与落盘时 ×100，**读写同口径**；② `round1()` 加范围兜底，脏数据不再把整条命令带走；
  ③ 页面侧加两条回归断言（`score:save` 回投的正确率必须与落盘值一致、且不得越界）。修完 `bestAccuracy`
  回到 `94.5`，自检 **57/0**（该文件 `attempts=14` 可对照这累计了十几轮的异常）。
  ⚠️ 定位过程顺带暴露的**诊断面缺口已在本版补掉**：命令 handler 抛异常时框架只回 `reject`、
  仓颉侧 stderr 一行都不打（`IpcHub.runCommand` 的两个 catch；事件监听器那条路则有
  `event listener failed` 日志，两者不对称）。本轮正是靠页面自己把错误回投才定位到的——
  两个 catch 现已各自补日志，见本节 `IpcHub.runCommand` 那条。
- **窗口销毁 / 文件对话框结果回调改按宿主句柄路由（多窗口下不再串台）**：三个宿主级回调里，
  消息回调的报文自带 window label，**销毁与对话框结果却不带宿主身份**，仓颉侧只能写进静态单槽
  （`HostGlobals.onDestroy` / `HostGlobals.dialogResult`）——后装配的窗口覆盖先装配的，于是
  「哪扇窗关了」认错、两扇窗同时开文件框时结果串台（单窗口下看不出）。现在与 shell 事件同一套
  按句柄认领：C 侧 `cj_on_destroy_fn` / `cj_on_dialog_fn` 首参加 `cj_host *`（`cj_on_message_fn`
  **有意不动**），仓颉侧三张单槽合并成一张宿主级路由表（`HostRoute` / `HostGlobals.registerHostRoute`
  / `hostRouteOf`，逐条认领自己的句柄）。单窗口行为不变。
  ⚠️ **FFI 签名变了：拉取本提交后必须先重建两平台 C 桥**（`native/build_win.bat` /
  `native/build_linux.sh`），否则链接期报 `undefined reference`（与 AGENTS §4 那条同源）。
- **路由与回调身份补齐用例**：新增 `src/tests/host_route_test.cj` 5 条（两宿主销毁不串 /
  对话框结果落发起窗口 / shell 事件按句柄认领 / 未登记句柄静默且不改表 / 同句柄重复登记＝替换），
  用例数 127 → 132；`native/tests/test_bridge_core.c` 加 8 条断言（回调带回被销毁者自己的句柄），
  91 → 99 项。Windows 双窗实机（2026-10-07，`examples/multi-window/run.bat`）18/18 断言、`exit=0`，
  桥 stderr 两宿主各 `created` / `destroyed` 一次、无「未登记宿主句柄」、`hr=` 全 `0x00000000`。

## [0.7.0] - 2026-10-05

### Added

- **菜单栏能力位（RFC-002 §5 先落「菜单」，托盘 / 拖放仍未做）**：`WebViewHost` 新增四个方法——
  `setMenu(wire)`（线路文本，空串 = 清空；`start()` 前后都能调，未就绪的文本由桥记着、建窗时一次建好）、
  `setMenuItemState(id, enabled, checked)`（运行期改单项状态，按 id 找）、`hostCapabilities()`
  （`CJ_CAP_MENU` / `CJ_CAP_TRAY` / `CJ_CAP_DRAG_DROP` 位掩码，未建宿主返回 0）与
  `setShellHandler(handler)`（菜单点击等 shell 事件，载荷是桥的 JSON 信封）。
  **两平台都实现**：Windows 走 `HMENU` + `SetMenu` + `WM_COMMAND`，Linux 走 `GtkMenuBar` 并把窗口内容
  改成「竖向 `GtkBox`：菜单栏 + view」；跨线程一律投递到宿主 UI 线程（Windows `PostMessage`，
  Linux `g_idle_add`）。C 桥侧共 5 个导出：`cj_bridge_set_menu` / `cj_bridge_set_menu_item_state` /
  `cj_bridge_set_shell_callback`（**单一 `cj_on_shell_fn(host, json)`，kind 分派**） /
  `cj_bridge_host_capabilities` / `cj_bridge_host_eq`。最后一个是为了**按窗口路由**：仓颉的
  `CPointer<Unit>` 不支持 `==`（编译器直接报 invalid binary operator），也没有可靠的指针→整数转换，
  多窗口下「这个回调属于哪个窗口」只能交回拥有句柄的 C 侧判定——这是「回调一开始就带宿主身份」
  真正落地的那一步。
  证据：`scripts/test-bridge-core.sh` 91/91（桩平台，含 `set menu` 透传与 `menu clicked` 带宿主）、
  `scripts/test.sh` 108/108、`cjpm build` 通过、Windows 桥 `native/build_win.bat` 重建通过。
  **Windows 实机点选已通过（2026-10-03，`examples/menu/run.bat` 14/14 断言、`exit=0`）**：菜单栏在宿主
  UI 线程建好、`WM_COMMAND` 点选走通全链、`setMenuItemState` 的运行期改状态由 Win32 侧 `GetMenuState`
  读回确认（`sidebar disabled=True checked=True`），且**事件只到被点的那一扇窗**（`window=second shell`
  3 条 / `window=main shell` 0 条）。
  ⚠️ **仍未验证（截至本版发布时）**：Linux 侧本机没有 GTK / WebKitGTK 工具链，`bridge_linux.c`
  **未编译、未实跑**；托盘与文件拖入尚未实现（能力位不含），前端也还没有 `setMenu` 的调用点——应用侧装配只到宿主接口层。
  （**后续已补齐**：前端 `setMenu` 调用点与应用层菜单 API 见本节 `setMenuTo` / 模板两条；
  Linux 侧 2026-10-06 换机编译并实机跑通，见 `[Unreleased]` 的「菜单能力位补上 Linux 实机验证」。）
- **菜单能力位的实机探针（入库的复现器）**：`examples/menu/`——两个窗口各装一份同样的菜单模型
  （同一份线路文本、各自独立的 `HMENU`），应用侧只做「把事件原样打进 stderr + 点击某一项后回手
  `setMenuItemState`」；真正点菜单的是 **Win32 驱动脚本** `click-menu.ps1`：从窗口的 `HMENU` 里读命令 id、
  `PostMessage(WM_COMMAND)`，再用 `GetMenuState` **读回**状态——「应用说自己设好了」不算证据，平台必须同意。
  `run.bat` 逐字断言 14 条，其中包含路由断言：三下点击**只**打在第二个窗口，第一个窗口 **0** 条 shell 事件。
- **多窗口缝（label 化 + 第二窗口登记；本轮只到缝，未上窗口 UI）**：`WebViewHost` 的 label 改由
  **构造参数**给定（`WebKitHost(label)` / `WebView2Host(label)`；无参构造仍回落 `"main"`，
  `createHost(label)` 跟随），`TauriApp` 新增 `addWindow(label, config, html)`
  （**必须在 `run()` / `runUrl()` 之前调用**，晚了抛异常——页面加载前窗口表要定稿）与
  `emitToWindow(event, payload, label)`（应用级定向投递，空串 = 广播）；`run()` / `runUrl()`
  改为按注册表逐个启动宿主。**单窗口行为不变**：`examples/multi-window` 的单窗对照 7/7 断言通过、
  `scripts/test.sh` 101/101。⚠️ **本机 Linux 实测：现有装配起不了第二个窗口**（双窗 3/3 次 `exit=134`；
  根因是 **WebKitGTK 不能被两条线程各自使用**，纯 GTK 双主循环则干净通过），Linux 的多窗口 UI 需先做
  「单主循环 + 多窗口」重构；判定与证据见 `docs/架构演进-多平台与多窗口.md` §8。
  **Windows 侧已实机验证（2026-10-03）：同一份装配双窗通过**——这条约束只对 WebKitGTK 成立，属平台分叉，
  Windows 不需要单主循环重构（见下方 Changed 段）。
- **多窗口可行性探针（入库的复现器）**：`examples/multi-window/`（同一份 HTML 起两窗、角色由自己的
  label 推出；驱动窗等两窗都 boot 后触发 1 条广播 + 2 条定向，两窗各自把收到的条数报回；
  `MW_MODE=single` 是单窗对照开关，`run.sh` 自带断言）、最小对照
  `native/tests/gtk_threading_probe.c` + `scripts/test-gtk-threading.sh`（纯 C，**不需要仓颉 SDK**，
  跑纯 GTK / GTK+WebKit 的 N=1 / N=2 四组并与 §8 的结论对齐；缺 gcc / GTK / WebKit / xvfb 时自行跳过）。
- **多窗口探针的原生框自动确认脚本**：`examples/multi-window/dismiss-dialogs.ps1`——按「窗口类 `#32770`
  **且**属于目标进程」双重筛选后 Post `WM_COMMAND/IDOK`（不注入全局键盘、不碰其他进程的窗口），并在看到
  第一个框后**等 4 秒**再作答，好让两个窗口的框真正重叠（`run.bat` 的双窗模式自动起它，单窗对照不启）。
  日志按状态变更记 `POLL pids=… dialogs=…`，答不上时能直接区分「没进程 / 有进程没框 / 出错」。

### Fixed

- **Windows 桥构建漏编译 `native/bridge_core.c`**：批次 1 把平台无关部分抽进 core 后只改了
  `native/build_linux.sh`，`native/build_win.bat` 仍只编 `bridge_win.c`——Windows 桥里 `cj_core_*`
  符号一个都没有（本机跑的是批次 1 之前的旧 DLL，所以一直「看起来能用」）。已补进编译行；重建后
  `libcjtbridge.dll` 导出 17 个，与源码一致。
- **Windows 建窗失败（`CreateWindowExW failed: 0`、`GetLastError()` 也是 0）**：`native/bridge_win.c`
  的 `wnd_proc` 在 `switch` 之后缺 `return DefWindowProcW(...)`；批次 1 新加的 `WM_NCCREATE` 分支
  `break` 后落到函数末尾，返回值不确定，Win32 据此判窗口创建失败**且不设错误码**（症状是窗口根本不出现、
  页面从不 boot，几乎无从定位）。补上 return 后建窗正常——该处正是 mingw `-Wreturn-type` 警告
  （`bridge_win.c:596`）所指。
- **`examples/multi-window/run.bat` 直接解析失败**：`if` 块里 `echo … (cjpm build) …` 的括号未转义，
  cmd 把括号当块边界，报「此时不应有 ...」后退出。
- **`examples/multi-window/run.bat` 在 Git Bash 的 PATH 下会挂到超时**：行数统计写成
  `findstr … | find /c /v ""`，而 `find` 在 MSYS 的 PATH 里命中 **GNU find**（Windows 的 `find.exe` 被排在
  后面），它把 `/c` 当路径去遍历整个盘（实测跑满 300s 超时，输出里全是 `Permission denied`）。
  改为 `findstr` + `for /f` 计数；文件末尾那条 `pause` 守卫也从 `find` 换成 `findstr`。
- **Windows 菜单栏根本挂不上窗口（实机点选第一轮暴露的四个真 bug）**：
  ① `native/bridge_win.c` 的顶层菜单栏用 `CreatePopupMenu()` 建，而 `SetMenu` **只接受 `CreateMenu()`
  的菜单栏句柄**——塞 popup 句柄进去会以 `ERROR_INVALID_PARAMETER(87)` **静默失败**：`SetMenu` 返回
  FALSE、平台日志照样打 `menu applied: items=4`，窗口上却一直没有菜单（`GetMenu` 恒为 NULL）。已改用
  `CreateMenu()`，并把 **`SetMenu` 返回值检查 + 事后 `GetMenu` 复核**打进同一行日志（Windows 上
  「真挂上了」的唯一凭证）。
  ② `HostGlobals.onShell` 是**静态单槽**，两窗各自在 `prepareHost` 里覆盖它 → 后装配的窗口把前一个的
  回调挤掉，先装配的窗口再也收不到自己的菜单点击（两窗探针一跑就露）。改为**路由表**
  （`ShellRoute` + `HostGlobals.registerShellRoute`，按句柄认领；同一句柄重复登记＝替换，不叠加）。
  ③ `TauriApp.hostOf(label)` 在 `run()` 之前查默认窗返回 `None`（默认窗的注册表登记发生在 `prepare()`），
  而 RFC-002 §5.2 要求 `setMenu` / 拖放策略必须在 `start()` 之前调 → **默认窗这条通路等于不存在**。
  已让 `hostOf` 对 `DEFAULT_WINDOW_LABEL` 回落 `Some(this.host)`。
  ④ 探针驱动脚本一次性 `GetMenu()` 是竞态（窗口标题先出现、菜单随后才挂上），改为有界轮询。
  证据：`examples/menu/run.bat` 14/14 断言、`exit=0`（驱动侧 Win32 读回 + 应用侧按窗口计数）。

### Changed

- **多窗口探针改为顺序无关**：原判定依赖「两窗都上报 `boots=2`」，对启动顺序与各窗耗时敏感；现改为
  页面一 boot 就上报、驱动窗**有界等待**对端（超时才判失败），判定不再依赖固定延迟与启动顺序
  （`examples/multi-window/src/main.cj`、内联页面 JS、`capabilities/default.json`、`run.bat`）。
- **Windows 多窗口 PoC 实测通过 → 平台分叉结论成立**：`examples/multi-window/run.bat` 双窗
  **8/8 断言全过、`exit=0`**（两窗各自 `BOOT jsLabel=<自己的 label>`、`GATE boots=2`、两条 `COUNTS`
  的广播 1 条 / 定向只到目标窗逐条正确），单窗对照 **7/7 通过**（`exit=0`）。即**同一份「一宿主一 UI 线程
  一消息循环」的装配在 Windows 上支持多窗口**，Linux 那条「WebKitGTK 不能被两条线程各自使用」的约束
  **不跨平台**。据此 `docs/架构演进-多平台与多窗口.md` §8 补了平台修正：多窗口 UI 的「单主循环」
  重构是 **Linux 专属前置**，Windows 不需要。
- **多窗口探针补齐「两窗回调并发」用例**（`examples/multi-window/`，2026-10-03 Windows 实机）：
  `run.bat` 默认模式在原 8 条断言之后新增两个阶段——阶段 2 两窗**同时**向各自宿主开原生消息框
  （硬证据 `window=main ASK … inflight=2`：第二条 ask 进栈时第一条尚未出栈；自动确认脚本日志
  `FIRST batch: 2 dialog(s) open` 独立佐证），阶段 3 **只关 `second`** 并证明应用不跟着返回
  （`CLOSE-WINDOW which=second requested` → `ALIVE second=1 main=0`）。双窗 **18/18 断言全过、`exit=0`**
  （单窗对照 **6/6、`CONTROL PASS`**）。对话框状态在 C 核里是 per-host（跨宿主本就不互斥）、退出是
  逐窗判的——这两条由「潜在」变实测事实；`HostGlobals.onDestroy`（静态单槽，且不在 `WebViewHost`
  接口上、应用侧装不进去）与文件框结果槽 `HostGlobals.dialogResult` 的共享缺陷**仍未清**，
  留待与「回调带宿主 id」一起做，见架构文档 §8.3 第 4 条。

## [0.6.0] - 2026-10-02

### Added

- **窗口注册表与 label 路由（批次 2）**：`TauriApp` 持 `WindowRegistry`（`src/window_registry.cj`：
  `label → WindowRecord`＝宿主 + 窗口配置；**重复 label 抛异常**而非静默覆盖），`run()` / `runUrl()`
  在启动前登记默认窗口 `"main"`。上行报文现在带发起窗口的 label：桥 JS 用**懒读**的 `labelOf()`
  （首次用到才取 `window.__CJ_TAURI_LABEL__`、取到即缓存，缺省仍是 `"main"`；注入脚本与桥 JS 谁先执行
  都无所谓），宿主在 start 之前把这句注入为**预执行脚本**（document-start，两平台同一通道）；
  `InvokeRequest` / `EmitRequest` 各多一个 `window` 字段，`IpcContext.window` 随之成为发起窗口的 label
  （此前恒为 `"main"`）。**协议是增量的**：`parseEnvelope` 只认已知字段，旧前端不受影响；上行 `window`
  缺失 / 非字符串 / 空串一律回落 `"main"`——上行没有「广播」语义，回落错了前端那条 promise 会永久 pending。
- **事件 / 回执按窗口投递**：`IpcHub.jsSink` 由 `(String) -> Unit` 改为 `(String, String) -> Unit`
  （json + 目标 label；空串 = 广播）；`TauriApp` 按注册表派发，`emitToWindow(..., label)` 现在真的只投给
  那一个窗口，**未注册的 label 打一条 stderr**（此前静默丢弃，写错 label 只能看到「前端什么都没收到」）。
  单窗口下与旧行为逐字等价；「事件只投后端监听器、不回投页面」的原则不变。
- **应用级宿主接口 `AppHost`**：由 `TauriApp` 实现——`quit()`（收掉注册表里所有窗口的事件循环）、
  `waitForExit()`（阻塞到退出，由私有转公开）、`hostOf(label)`（对标 `app.get_webview_window(label)`，
  未注册返回 `None`）；`WebViewHost` 新增 `label()`（本窗口的 label，缺省 `"main"`）。
  `WebViewHost.quit()` / `shouldQuit()` **保留**为「本窗口循环」的低层原语（只有实现方知道怎么收尾），
  应用级入口只有 `AppHost`。

### Changed

- 单测 91 → **101**：新增 `WindowRegistry` 用例（重复 label 抛异常 / 查不到返回 `None` / 空串按登记顺序广播 /
  定向单投 / 未注册 label 不回落成广播）与测试替身 `src/tests/fake_host.cj`（不创建原生窗口就能测装配路径）。

## [0.5.0] - 2026-10-02

### Added

- **C 桥公共核心的桩平台自检**：`native/bridge_core.c`（两平台逐字相同的回投队列与批处理、对话框单槽状态机、
  窗口配置与预执行脚本存储、生命周期标志、全部 `cj_bridge_*` 导出）此前只有实机验证、没有单元测试。新增
  `native/tests/test_bridge_core.c`——用「只记录调用」的桩平台实现 `bridge_core.h` 里的 18 个 `cj_plat_*` 原语，
  把 core 与桩一起编译成单文件程序，**链接期即可证明** core 只经平台原语触达平台（批次 1 的分层契约）。61 项断言
  覆盖：单条快路径 / 多条拼批（顺序 + 换行分隔）/ `CJ_JS_BATCH_MAX`=64 上限与「没取空就自续唤醒」、
  未就绪时对话框被拒 / UI 线程快路径（**不**投递不阻塞）/ `dialog_abort` 幂等、`quit` 与窗口销毁的标志位与
  「`onDestroy` 恰好一次」、窗口配置与脚本存储的边界（空串忽略、非法尺寸不覆盖）、全部导出对 NULL 安全。
  入口 `scripts/test-bridge-core.sh`（只需要 C 编译器，本机没有就跳过），已接入 `scripts/test.sh` 与
  `scripts/check-static.sh`。
- **IPC 通信机制技术文档 + 性能探针**：新增 `docs/IPC-通信机制.md`——写清三层结构（页面 JS → 宿主桥 C → 仓颉 IPC hub）、
  四种报文（`invoke` / `emit` / `resolve`（成功或失败）/ `event`，外加宿主侧控制消息 `__cj_tauri_reload__`）、
  一次 invoke 的十步时序与两平台差异，并给出**实测数字**；正面回答「比起 WebSocket 如何」：
  两者不在同一层（webview 消息通道是 webview 自带的，WebSocket 是传输层），本机 loopback 对照
  （WebSocket 0.151 ms、裸 TCP 0.077 ms）与本框架进程内往返（0.39 ms 成功 / 0.35 ms 拒绝）同处
  0.1–0.5 ms 一档——换传输方式不是数量级差异，开销在报文编解码与调度上。实测（Linux / WebKitGTK /
  2 vCPU / Xvfb，**三轮取中位**，原始日志 `/tmp/ipc-bench-round{1,2,3}.log`）：顺序往返 390.5 µs/次（2561 ops/s）、
  未授权命令同步拒绝 350 µs/次、管线化 10000 ops/s、1 KB → 64 KB → 1 MB 回显 0.49 ms → 1.65 ms → 14.6 ms
  （2.0 → 37.9 → 68.5 MB/s）、事件推送 0.02 ms/条。配套两件可复现工具：探针 `examples/ipc-bench/`
  （4 组基准，结果回传仓颉侧 stderr）与对照脚本 `scripts/bench-ws-vs-tcp.js`（Node 22 内置 `WebSocket`
  客户端 + 手写最小服务端，零依赖）。文档同时如实记下限制：**捞不出 `id` 的非法报文仍只打 stderr**
  （捞得到 `id` 的已能回 `ok:false`，见 `Fixed`——此前前端 promise 会永久 pending）、无超时 / 取消 / 背压策略
  （前端 `emit()` 已由本段的 `emit` 条目打通，不再是空转）。
- **机器可读的插件清单 `describePluginsJson()`**：框架侧函数（**不动 `Plugin` 接口**，仍是 6 个方法）返回
  `[{name, commands, events, permissions, hasShim}]`——`commands` / `events` 是全名数组，`permissions` 是
  「集全名 → 成员全名数组」（框架展开后的样子，也就是清单里能引用的名字），`hasShim` 表示该插件是否带前端
  JS 片段。数组与权限键都按字典序排序：HashMap 迭代顺序不定，工具的输出 / diff 需要稳定。给第三方工具 / CI
  消费用；`cj-tauri info` 已接入它（见下一条）。单测 71 → 74。
- **`cj-tauri info` 打印插件清单（`--json` 给机器读）**：CLI 进程里没有应用那份 `TauriApp`，所以做法是让应用
  「跑到装配完成、但**不创建窗口**」一次——框架认环境变量 `CJ_TAURI_MANIFEST`（`json` / `text`），
  `run()` / `runUrl()` 在 `prepare()` 之后据此把清单打到 stdout 并直接返回。于是没有 X 显示、
  也没装 WebView2 Runtime 的机器上照样能取到真实装配结果（前缀名、权限集展开、`hasShim`）。
  `cj-tauri info` 末段打印人读表，`cj-tauri info --json` 只输出 `describePluginsJson` 的 JSON
  （stdout 不含诊断，可直接喂工具 / CI）。两道守卫缺一则跳过导出：框架源码里没有这个变量名（旧框架）、
  或应用产物早于 `src/app.cj`（陈旧产物）——这两种情况下跑应用会真去开窗口，把 `info` 卡住。单测 74 → 78。
  Linux 实机（无 `DISPLAY`）：`info` 末段 `shell  shell:open, shell:exec`；`info --json` 解析出 `['shell']`；
  直跑应用 stderr 为 `已导出插件清单（mode=json）：本轮未创建窗口` 且 `set window:` 行数 = 0。
- **npm 包**：`npx cj-tauri` / `npm i -g cj-tauri` 成为跨平台统一入口（`npm/bin/cj-tauri.js`）——
  自动定位仓颉 SDK（`CANGJIE_HOME` 或平台默认路径）、拼 `PATH` / `LD_LIBRARY_PATH`、注入 `CJ_TAURI_ROOT`；
  CLI 本体优先用包内预编译二进制（`prebuilt/<平台-架构>/`），缺失则把 `cli/` 拷到缓存目录用本机 `cjpm build`
  构建一次并复用（`~/.cache/cj-tauri/<版本>/`，Windows 为 `%LOCALAPPDATA%\cj-tauri`），不往安装目录写产物；
  找不到 SDK 时打印安装说明与 `CANGJIE_HOME` 示例并以退出码 1 结束，`--version` 不依赖 SDK。
  打包脚本 `scripts/npm-pack.sh`（默认只打包，`--publish` 发布；发布固定走官方 registry
  `https://registry.npmjs.org/`（`NPM_PUBLISH_REGISTRY` 可覆盖）并先做登录预检——本机 npm 常配着镜像
  （`registry.npmmirror.com`），镜像不接收 publish，直接 `npm publish` 会报错或发错地方；未登录时打印确切的
  `npm login --registry=…` 命令并以退出码 1 结束）；包内容 = 框架源码 + CLI 源码与三个模板 +
  本机 CLI 产物（1.2 MB tarball / 55 文件）。Linux 实测：预编译分支、源码构建回落与缓存命中、`create` 生成的工程
  再跑 `info`、缺 SDK 提示路径全部走通。
- **npm 自动发布（GitHub Actions + trusted publishing）**：`.github/workflows/npm-publish.yml` 在推 `v*` tag 时
  依次跑「版本五处一致性 → tag 必须等于包版本 → 静态门禁 → `scripts/npm-pack.sh` → `npm publish`」，
  用 OIDC 换取短期发布凭据，**不需要任何长期 token**，并自动附带 provenance（公开仓库 + 公开包）。
  CI 里没有仓颉 SDK，故 CI 打的包不含预编译 CLI（用户首次运行在本机源码构建），与既定的
  「优先预编译、缺失回落源码构建」一致；要带 `prebuilt/` 仍用本机打包。
- 示例工程入库：`examples/vue_todo/` —— `examples/todo_check` 的 **Vue 3 版**，命令与事件完全同名
  （`todo:add` / `todo:remove` / `todo:list` + `todo:changed` 广播），后端 `src/main.cj` 两份可直接对照；
  前端是 Vite 工程（Vue 3 `script setup`），`cj-tauri dev` 接管 dev server 换 HMR，
  `cj-tauri build` 经 `vite-plugin-singlefile` 产出单文件 `ui/dist/index.html`（70.2 KB）。
  前端取桥用**等桥出现再初始化**（`waitForBridge`，与两个模板一致；宿主注入时机的修复见 `Fixed`）；Linux 实机（WebKitGTK）已验证：
  界面显示「已注入 __CJ_TAURI__」与 `system:version` 的后端 JSON（`0.4.0` / `cangjie 1.0.5` / `linux`），
  两条待办由后端保存并经 `todo:changed` 回投渲染（共 2 条 / 收到事件 2 次 / `todo:add 返回 2`）。
  另带 `run.bat`（Windows 一键跑：先检查已构建的 `main.exe` 与 `ui/dist/index.html`，再切到工程根启动，
  与 `examples/todo_check` 同款）。
- **插件体系 v1**：`.plugin(FsPlugin())` 一行接入插件——`src/plugin.cj` 定义 `public interface Plugin`，
  必写 `name()` + `commands()`，可选 `events()` / `jsShim()` / `setup()`（都有默认实现，样板插件只写两个方法）。
  插件命令统一注册为 `<插件名>:<短名>`，与内置 `system:*` 同形，所以 IPC 分发与能力校验**零改动**；
  **权限仍由 `capabilities/` 决定**（插件只声明「我提供什么」，不自动放行）：启动时打印已装配插件清单，
  清单里缺哪条就提示哪条（`插件 fs 的命令 fs:writeText 尚未授权，请在 capabilities 目录的 json 里把 … 加进 commands`）。
  插件的前端 `jsShim()` 由框架汇总成一个 `<script>` 块、插到第一个 `</head>` 之前（早于页面脚本），
  页面第一行即可用 `window.__CJ_TAURI__.<插件名>`；`runUrl`（dev server / 远程页面）模式下 HTML 不在本进程，
  shim 无法并入，框架会在 stderr 明确提示（前端照模板的 `waitForBridge` 等桥）。
  随框架带官方 `fs` 插件（`src/plugin_fs.cj`）：`fs:readText` / `fs:writeText` / `fs:exists`，
  前端 `window.__CJ_TAURI__.fs.readText({ path: "ui/index.html" })`。
  示例 `examples/plugin-fs/` 演示一行接入与**未授权对照组**（能力清单故意只放行 `fs:readText` / `fs:exists`）：
  启动提示缺 `fs:writeText`，前端调用被拒 `command not allowed: fs:writeText`，而放行过的命令正常返回。
- **命名权限集（v1.1）**：能力清单新增可选字段 `permissions`，可以按**集名**一次放行一组命令：
  `"permissions": ["fs:readonly"]`。插件用 `Plugin.permissions()` 声明「短集名 → 成员」（写短名自动补
  `<插件名>:`，写全名则原样保留），框架在装配时注册；清单引用后，集内成员与写在 `commands` 里的明文名字同权。
  **集声明不等于放行**——清单不引用它一条也不生效；旧清单（全写明文）行为完全不变，两种写法可混用、并集生效。
  官方 `fs` 插件自带 `fs:readonly`（`fs:readText` + `fs:exists`）与 `fs:default`（另含 `fs:writeText`），
  只想读文件的应用引用 `fs:readonly` 即可，**写能力不会被顺带打开**；启动时打印可用集清单，
  清单里引用了没有插件提供的集名会明确提示（只提示、不改其它权限，多半是拼错）。
  Linux 实测（`examples/plugin-fs` 清单从明文改成 `"permissions": ["fs:readonly"]`）：启动打印两个集、
  只对 `fs:writeText` 报未授权（`fs:readText`/`fs:exists` 不再误报），页面自检
  `fs:readText OK => 147 chars; 清单用集 fs:readonly=true; 清单未写死 fs:readText=true`、
  `DENY-OK fs:writeText: command not allowed: fs:writeText`、`[verify] ALL DONE`（日志 `/tmp/cj-plugin-fs-permset.log`）。
  Linux 实机（WebKitGTK / Xvfb）已验证：`shim-ready-at-script-start=true`、`fs:readText OK => 141 chars`、
  `fs:exists => true`、`fs:writeText` 被拒、`[verify] ALL DONE`。单测 23 → 38 个（`src/tests/plugin_test.cj`）。
- **官方 `dialog` 插件（系统原生对话框）**：`.plugin(DialogPlugin())` 一行接入，三条命令——`dialog:open`
  （选文件）/ `dialog:save`（选保存路径）/ `dialog:message`（`kind` = `info` / `warning` / `error` / `confirm`
  的模态提示框）。弹的是**系统原生**对话框：Windows 走 Win32 通用对话框（`GetOpenFileNameW` /
  `GetSaveFileNameW` / `MessageBoxW`），Linux 走 GTK（`GtkFileChooserDialog` / `GtkMessageDialog`）；
  平台差异全部落在 C 桥（`cj_bridge_show_dialog` / `cj_bridge_set_dialog_callback`），插件与宿主接口没有
  运行期平台分支（照 `AGENTS.md` §2 的规矩：先扩 `WebViewHost`（`showFileDialog` / `showMessageDialog`）、
  再改两平台实现、最后 C 桥导出同名同签名）。与 `fs` 插件一样**不自动放行**：清单里写
  `"commands": ["dialog:open", …]` 或引用命名权限集 `"permissions": ["dialog:files"]`（= `open` + `save`）/
  `"permissions": ["dialog:default"]`（另含 `message`）——只想挑文件的应用不必顺带拿到「弹任意提示框」的能力。
  文件类命令返回选中路径（取消返回空串），提示框返回 `true`/`false`（`confirm` 才可能为 `false`）。
  **实机抓到的坑并已修**：两平台的 JS→native 回调**本来就跑在宿主 UI 线程上**（Linux 是 GTK 线程，Windows 是跑
  WebView2 消息循环的线程），所以对话框若一律走「投递到 UI 线程 + 阻塞等结果」，UI 线程会卡在这次调用里、
  那个投递的任务永远没机会执行——现象是日志停在 `[cj-bridge] dialog: kind=…` 而对话框永不出现（第一次实测就是
  这个结果）。现在两条路径都留着：调用方已在 UI 线程就直接弹，在别的线程才投递+等待。
  示例 `examples/plugin-dialog/`（内联 HTML：三个按钮 + 启动后自动依次弹窗的自检）Linux/WebKitGTK 实机验证：
  `dialog: kind=2 title=… (caller on GTK thread)` → `dialog closed: kind=2 ok=1` →
  `dialog:message(info) => confirmed=true` → 原生文件框选中路径回传
  `dialog closed: kind=0 ok=1 path=/tmp/dialog-pick.txt` / `dialog:open => path="/tmp/dialog-pick.txt"` →
  对照组 `DENY-OK system:devtools: command not allowed: system:devtools` → `[verify] ALL DONE`；
  截图 `docs/images/example-plugin-dialog.png`。单测 50 → 57 个（新增 `src/tests/plugin_dialog_test.cj`）。
  Windows 侧**未实机验证**（开发机只有 Linux）：桥里新增的对话框代码用 mingw 单独编译校验通过，实机待 Windows 机。
- **官方 `shell` 插件（交给系统默认程序 + 执行子进程）**：`.plugin(ShellPlugin())` 一行接入，两条命令——
  `shell:open`（把 URL / 本地路径交给系统默认程序）与 `shell:exec`（跑一个程序，回收 `{ code, stdout, stderr }`）。
  **不经过 shell**：`program` 与每个参数都作为独立 argv 元素直传子进程，没有 `cmd /c` / `bash -c` 的字符串拼接，
  所以参数里的空格、引号、`&&`、`>` 都只是普通字符，页面拼不出命令注入（实机对照：跑
  `echo "a b" "&&" "echo INJECTED"` 的输出就是字面量 `a b && echo INJECTED`）。平台差异照 `AGENTS.md` §2 只出现在
  `@When`：Linux 走 `xdg-open`，Windows 走 `rundll32 url.dll,FileProtocolHandler`，两平台都不必经过 `cmd.exe`
  （省掉一层引号解析）。与其它插件一样**不自动放行**：命名权限集 `shell:allow-open`（只放行「打开」）与
  `shell:default`（另含 `exec`）——**放行 `exec` 等于把「执行任意程序」交给页面**，清单是唯一闸门，所以
  `allow-open` 刻意不含它。输出每个流各截到 256 KiB 并标注（避免一条命令把几十 MB 灌进一条 IPC 消息），
  非 UTF-8 的输出退化成摘要而不是抛异常（子进程往 stdout 写什么我们管不着）。
  示例 `examples/plugin-shell/`（清单刻意混用命名集与明文两种写法）Linux/WebKitGTK 实机验证：
  `shell:open(url) => true`，且冒充系统默认程序的假浏览器收到 `argv=https://atomgit.com`（证明目标真到了系统
  处理器手里，不只是 invoke 返回了 true）；`shell:exec(uname) => code=0 stdout=Linux …`、
  `shell:exec(exit7) => code=7 stderr=to-stderr`（退出码与 stderr 分流）、程序不存在时
  `shell:exec(missing) OK => shell:exec failed: … No such file or directory`（可读错误而非崩）、
  对照组 `DENY-OK system:devtools: command not allowed` → `[verify] ALL DONE`；截图
  `docs/images/example-plugin-shell.png`。单测 57 → 68 个（新增 `src/tests/plugin_shell_test.cj`，11 个用例）。
  **限制已解除**：此前 `shell:exec` 同步阻塞在宿主 UI 线程上（跑长驻程序会把窗口钉住）；本版「命令执行改为
  异步分发」后它跑在 worker 线程上，命令期间窗口照常响应（对照取证见 Changed 首条）。仍不建议用它跑长驻 /
  交互式程序——没有流式输出，也没有超时 / 取消。Windows 侧**未实机验证**（开发机只有 Linux），
  `@When` 的 Windows 分支只做了编译校验，实机待 Windows 机。
- **前端 `emit()` 打通（JS → 仓颉方向的事件，此前是空转的死 API）**：`__CJ_TAURI__.emit(event, payload)`
  现在返回 Promise——报文经 `EmitRequest.parse` → `canEmit(event)`（调用线程同步校验）→ `spawn` 到 worker，
  交给后端监听器。配套新增 `TauriApp.listenEvent(event, handler)`（对标 Tauri 的 `app.listen`，插件在
  `setup()` 期注册一次）。语义**有意与 Tauri v2 不同**：前端 emit 只投后端监听器、**不回投任何页面**
  （单窗口下「广播」等于自己发自己收——Tauri 用户真实踩过的坑、官方 issue 是 won't fix；多窗口寻址还没实现，
  页面内广播继续用原生 `CustomEvent`）。事件报文加了 `window` 字段（`{"type":"event",…,"window":"main"}`，
  空 = 广播），桥的 `_dispatch` 按 label 过滤——将来接投递侧时协议与前端都不用改。未授权事件现在以
  `reject("event not allowed: <event>")` 回到前端，而不是只在 stderr 里丢；某个后端监听器抛异常只记 stderr，
  不影响同事件的其它监听器与发送方（事件是广播语义）。Linux 实机（WebKitGTK / Xvfb，探针 `/tmp/probe-emit`）：
  `PROBE-1 emit-allowed-resolved=true data={}`、后端侧 `backend-listener payload={"from":"ui","n":1}`、
  页面侧同名监听器命中 **0** 次（`PROBE-2 frontend-loopback-hits=0`）、未授权事件
  `PROBE-3 emit-denied-rejected=true msg=event not allowed: probe:denied`。单测 78 → 87。
- **高频事件的「只保最新」投递 `emitLatest`（显式 opt-in）**：新增 `IpcHub.emitLatest` /
  `IpcContext.emitLatest` / `TauriApp.emitLatest`——同一帧内同名事件只投最后一次 payload（中间值丢弃，
  **尾值必达**），报文因此多一个 `coalesce: true`，而页面监听器写法不变（`listen` 照旧）。
  **默认的 `emit` 一行没改**：不合并、不丢回执、队列也不设上限——静默丢数据比慢更难排查，
  而丢 `resolve` 会直接破坏 request/response 契约。合并落在桥 JS（`native/bridge_js.h`，两平台单源）：
  本帧槽位 + `requestAnimationFrame`，并用 `setTimeout(…, 50)` 兜底（窗口不可见、rAF 不来时也能送出尾值）。
  与 Tauri v2 的源码级对照：它的事件投递是 `self.eval(emit_js_script(...))`
  （`crates/tauri/src/webview/mod.rs:2230`）——一条事件一次 eval，无批处理、无合并、队列无上限；
  官方立场是高吞吐走 `Channel`，社区答案是应用层自己限流。单测 87 → 91。
  实机（Linux/WebKitGTK/Xvfb，探针 `examples/ipc-coalesce`，日志 `/tmp/probe-coalesce-run.log`）：
  `emitLatest × 50 → listener-hits=1 last-n=50`（连跑 4 次里 3 次为 1、1 次为 2：**合并以「一次批刷窗口」为界**，
  窗口数随分发节奏变，尾值恒 50，所以断言是 `hits<50` + 尾值必达而非 `hits==1`）、
  对照 `emit × 50 → listener-hits=50`、`emitLatest × 1 → listener-hits=1`，桥侧 `run js failed` 计数 0。
  Windows（WebView2）未实机（本机是 Linux），但报文与仓颉侧两平台共用、桥 JS 本就同源。
- **`WebViewHost.dispose()`：宿主句柄显式释放**：`run()` / `runUrl()` 返回前框架自己会调一次（幂等）。
  C 桥侧同步把 15 个 `cj_bridge_*` 导出改成**首参句柄**（`cj_host *h`，不透明指针，仓颉侧 `CPointer<Unit>`），
  平台无关的部分抽到共用的 `native/bridge_core.h` / `bridge_core.c`，平台文件只留原语——多窗口与新增平台的
  地基。**单窗口行为不变**（Linux 有现成回归探针：ipc-coalesce 三条对照全过、ipc-bench 三轮无 SIGSEGV，
  四组数字与基线同量级）。

### Changed

- **回投路径改为「一次调度合并成批 + 单条快路径」**：原生 → JS 的回投脚本从
  `window.postMessage(<json>, '*')` 改为直派 `window.__CJ_TAURI__._dispatch(<json>)`（桥 JS 里那个
  `message` 监听器随之删除），并且一次空闲回调（Linux `g_idle_add` / Windows `WM_CJT_FLUSH`）把队列里
  最多 64 条响应拼成一段脚本、只执行一次 eval，没取空就自续再排；队列里只有一条时走**快路径**
  （直接用原字符串，不拼批）。实测（Linux / WebKitGTK / Xvfb，同机、同一份应用二进制只换 C 桥，
  各 3 轮取中位）：**管线化吞吐 6024 → 11905 ops/s（≈2.0×）**、**事件推送 0.105 → 0.04 ms/条（≈2.6×）**、
  顺序往返 386.5 → 390.5 µs（噪声内）、1 MB 回显 49.5 → 51.8 MB/s（噪声内）。只做拼批不做快路径时
  顺序往返中位 414.5 µs（比基线慢约 7%），所以快路径是这条改动的必需部分而不是可选优化。
- **两平台桥的前端 JS 收敛为单份 `native/bridge_js.h`**：原先 `bridge_linux.c` / `bridge_win.c` 各内联
  一份 `BRIDGE_JS`（除 `char`/`wchar_t` 与原生投递 API 名之外逻辑逐字重复），现在只留一份、两桥
  `#include`，平台差异点仍留在各自文件里——避免以后改一处漏一处。
- **`docs/IPC-通信机制.md` 的性能数字随本轮优化刷新**：§6 的两项优化候选改成「已实施」并附前后对照
  （含中间态数据），§8 同时保留改动前 / 改动后的原样输出，§7 补齐已修项与仍存在的限制。

- **插件 JS 的注入通道换成宿主层「预执行脚本列表」（破坏性变更）**：插件 `jsShim()` 不再由框架拼成
  `<script>` 块塞进 HTML，改为经 `WebViewHost.addInitScript(js)` 注册、由 C 桥在 document-start 注入
  （排在 `BRIDGE_JS` 之后）。收益：`runUrl()`（dev server / 远程页面）的页面 HTML 不在后端进程里，
  以前根本拿不到 shim，现在与内联 HTML 走同一条链路、时序一致。`pluginInitScripts(plugins)` 返回
  「一个插件一段」的脚本列表（某个插件的 shim 写坏了不会带崩别的命名空间），`app.run` / `app.runUrl`
  在 start 之前逐段注册；启动时 stderr 打印 `插件 JS 已注册为预执行脚本：N 段`，桥侧打印
  `init script queued: N bytes` / `init scripts injected: N`。Linux 实测（WebKitGTK / Xvfb，
  脚本 `/tmp/run-init-verify.sh`）：内联 HTML 与 `file://` 两种来源，页面第一行都读到
  `shim-ready-at-script-start=true`、`__CJ_TAURI__.fs` 为 `object`（`[verify] ALL DONE`）。
- **命令执行改为异步分发（破坏性变更）**：`IpcHub.handleInvoke` 把通过校验的命令 `spawn` 到 worker 线程执行
  （此前 handler 直接在宿主 UI 线程上跑完），慢命令不再钉住窗口——`shell:exec` 跑一个进程、等原生对话框期间，
  窗口照常重绘、JS 定时器照常回调、其它 invoke 照常处理。语义上有三点要知道：① 未授权 / 未注册仍在**调用线程上
  同步拒绝**（前端拿到的报错即时、顺序确定）；② 同一命令被并发调用**不保证执行顺序**（前端按 promise id 匹配，
  不会串包）；③ 命令内调用宿主能力（弹窗等）现在发生在非 UI 线程——`dialog` 插件早已「按调用线程分流」，无需改动。
  结果回投仍走既有桥函数（两平台本就是「加锁入队 + 投递宿主 UI 线程」），没有新增 C 导出，worker 里也不要绕过桥
  直接碰 GTK / WebKit。Linux 实机 A/B 取证（同一演示、同一 X11 转发显示，只切换分发方式；演示按钮见
  `examples/plugin-shell/` 的「长命令 3 秒 + 心跳」）：**同步臂** 6 次心跳全部堆到命令结束之后
  （`slow: done ok=true +3124ms`，心跳 +3126…3133ms）；**异步臂** 首跳 +503ms，+1002 / +1503 / +2003 / +2503ms
  贯穿 3 秒命令全程（异步臂截图 `docs/images/example-plugin-async.png`，同步臂对照留在
  `/tmp/cj-tauri-shots/async-A-sync-arm.png`）。单测 68 → 71 个（新增「不阻塞调用方」「并发恰好回投一次」
  「拒绝仍同步」三个契约用例）。
- README 增「示例一览」章节：三个示例（`examples/hello` / `todo_check` / `vue_todo`）与三个工程模板
  （`cli/templates/app` / `app-vue` / `app-react`）的说明表，各配**发行态实机截图**
  （`docs/images/example-hello.png`、`docs/images/example-todo-check.png`、`docs/images/example-vue-todo.png`、
  `docs/images/template-app-vue.png`、`docs/images/template-app-react.png`，Linux / WebKitGTK，2026-10-02）；
  并修正首页两处陈旧信息：版本号 `0.3.0` → `0.4.0`、`cli/templates/` 目录说明补全三个模板。
- 版本一致性校验由四处扩到五处：`scripts/check-version.sh` 增加 `npm/package.json` 的 `version`
  （npm 包版本 = 框架版本，`npx cj-tauri --version` 在无 SDK 时读它），`AGENTS.md` 的「版本与发版」同步改写。
- `npm/package.json` 的 `repository.url` 改指 GitHub 仓库：trusted publishing 要求它与发布来源仓库**精确一致**
  （大小写敏感），否则 npm 以 `E422` 拒绝发布。`homepage` / `bugs` 仍指 AtomGit。
- `scripts/npm-pack.sh` 支持 `--otp <6 位码>` / `NPM_OTP`：账号开启「写操作需 2FA」时，`npm login` 的浏览器
  登录态只证明身份，发布仍要一次性动态码，否则 registry 回
  `E403 … Two-factor authentication or granular access token with bypass 2fa enabled is required`；
  脚本在发布前校验 OTP 形态（6 位动态码，或 ≥6 位的未用过恢复码——registry 的 `npm-otp` 两者都收），
  未发布时的提示也带上该参数；只绑了安全密钥/passkey 的账号没有动态码，那就改走勾了 Bypass 2FA 的
  granular token（临时写进用户级 `~/.npmrc`，发完即删）。
- 更正此前「首版可自动化」的预期：npm 只允许给**已存在**的包配置 trusted publisher（入口在该包的 settings 页），
  `npm stage publish` 也不能创建新包，因此 `v*` tag 触发的 OIDC 自动发布**只能从第二个版本开始**，
  首个版本必须本机手工发（带动态码，或用勾了 Bypass 2FA 的 granular token）。

### Removed

- `assemblePluginJs()` / `injectPluginJs()`（v1 那套「把 shim 拼进 HTML 字符串」的取巧做法）随上述注入
  通道切换一并删除，等价能力是 `pluginInitScripts()`（返回脚本列表，交给 `WebViewHost.addInitScript`）；
  框架不再改写你传进来的 HTML。

### Fixed

- **带 `id` 的非法报文不再让前端永久 pending**：解析失败的报文原先一律只往 stderr 打
  `invalid IPC message: …`，前端那条 promise 永远等不到结果、只能靠业务自己加超时。现在先用
  `IpcMessage.peekId` 尽量把 `id` 捞出来，捞得到就回一条 `ok:false` 的 reject。实机探针里页面直接投
  `{"type":"wat","id":9001}`，收到的回投报文是
  `{"type":"resolve","id":9001,"ok":false,"error":"invalid IPC message"}`（`PROBE-4`）。
  捞不出 `id` 的（不是 JSON / 缺 `id`）仍然只能打 stderr——没有 id 就对应不到任何 promise。
- **Linux 桥看不到入站消息**：`on_script_message` 直接回调仓颉、不打日志（Windows 一直有
  `js -> native (N bytes)`），Linux 上排查时无法从日志对数。现已对齐（实测日志出现 `js -> native (54 bytes)`）。
- **Linux 回投失败被静默吞掉**：`webkit_web_view_run_javascript(..., NULL, NULL, NULL)` 不接执行结果，
  eval 失败（脚本抛异常、JS 上下文失效）只会丢掉这一条回投，前端那条 promise 永久 pending。
  现挂 `on_js_done`（`webkit_web_view_run_javascript_finish` 取 `GError`）打 `run js failed: …`——
  实测把页面 `_dispatch` 换成必抛实现后再发一条 invoke，宿主日志出现
  `run js failed: about:blank:31:78: Error: probe-boom`。
- **页面可以伪造回投**：回投原先经 `window.postMessage(json, '*')` + 页面 `message` 监听器落地，
  任何拿得到 window 的脚本（包括被注入的第三方脚本）都能投一条假 `resolve` / `event` 冒充原生。
  改成直派 `_dispatch` 后该投递面消失——实测页面自己 `window.postMessage({type:'event',…}, '*')`
  时监听器被调 **0** 次。

- `cj-tauri dev` 退出后残留 vite / esbuild：收尾改为按「先子后父」递归收掉整棵 dev server 进程树
  （`npm → sh -c vite → node(vite) → esbuild`），此前只 terminate 直接子进程（`bash`）。Linux 实测：
  应用退出后日志出现 `dev server 已收掉（pid=… 及后代）`，`pgrep` 查不到 vite / esbuild 残留。
- 上一版把 dev server 放进独立会话（`setsid`）以便按进程组收尾，实测这会让它脱离终端的进程组：
  终端 Ctrl-C 只杀掉 CLI，dev server 照样漏跑。已改回让 dev server 留在 CLI 的进程组里
  （Ctrl-C 能一并带走），整棵树的收尾交给上面的递归 kill。
- Linux 启动器 `cli/cj-tauri.sh`：运行时目录改为按宿主平台挑（此前 `find | head -1`，SDK 里同时存在
  `linux*` 与 `windows*` 目录时可能挑错）；并补设 `LD_LIBRARY_PATH`——Linux 上动态库不查 PATH，
  只设 PATH 会以「找不到 libcangjie-runtime.so」直接起不来。
- 示例在 Linux 上可直接构建：`examples/hello/cjpm.toml` 的 Linux 链接段去掉失效绝对路径
  （改用相对本仓的 `../../native`），`examples/todo_check/cjpm.toml` 补上 Linux 链接段与 stdx 路径；
  `examples/todo_check/run.bat` 的中文注释改为纯 ASCII（`.bat` 由 cmd.exe 按 OEM 码页读取，中文会吞行）。
- **Linux 宿主桥接脚本的注入时机过早无效**：`native/bridge_linux.c` 原为文档**末尾**注入
  （`WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END`），而发行态单文件把 `<script type="module">` 内联进 HTML、
  解析完即执行，会抢在注入之前；前端在模块作用域 / `onMounted` 里读 `window.__CJ_TAURI__` 会拿到
  `undefined`（开发态从 URL 加载、模块要现下载，反而掩盖了这个竞态）。现改为
  `WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START`，与 Windows 的 `AddScriptToExecuteOnDocumentCreated`
  （页面脚本执行前）一致。用 `--template vue` 生成的工程在发行态前后对比验证：改前界面显示
  「未注入 / 未找到 window.__CJ_TAURI__」，改后**同一份前端**（未做任何等待）显示「已注入 __CJ_TAURI__」
  且 `greet` 返回 `invoke OK: Hello, world! 来自仓颉后端`。
- `cli/templates/app-vue` / `app-react` 的示例前端改为**等桥出现再初始化**（`waitForBridge`：每 20ms 探测、
  3s 上限），不再在模块作用域直接读 `window.__CJ_TAURI__` —— 注入时机是宿主实现细节，应用侧等待才与时序无关。
  Linux 发行态实测：两个模板生成的新工程均显示「已注入 __CJ_TAURI__」、`greet` 返回
  `invoke OK: Hello, world! 来自仓颉后端`、`timer` 触发的事件回投显示「事件 tick #3 来自仓颉后端」。
- `cli/templates/app-react` 的示例页面此前**完全没有样式**（`App.jsx` 用了 `card` / `row` / `ghost` 等 class，
  但模板里没有任何 CSS，发行态渲染出来是裸的 HTML；Vue 模板的样式写在 `App.vue` 的 `<style scoped>` 里，
  所以没这个问题）。现补一份 `ui/src/App.css`（与 Vue 模板逐条等价的样式），并在 `App.jsx` 里 `import`。
  Linux 发行态实测：页面出现卡片 / 圆角输入框 / 彩色按钮，且 `greet`、`timer` 仍返回
  `invoke OK: Hello, world! 来自仓颉后端` 与「事件 tick #3 来自仓颉后端」；Vue 模板同步复测视觉未变。
- `cli/templates/app-vue` / `app-react` 与 `examples/vue_todo` 的页面**没有整页底色**：三处 `index.html` 里
  一行样式都没有（组件样式在各组件里，页面级样式漏了），发行态是白底 + 浅青 `<h1>`，几乎看不清。
  零 Node 模板与 `examples/hello` / `todo_check` 本来就是深色，只有这两个模板漏了。现给三处补上页面级样式
  （`:root { color-scheme: dark }` + `#16161d` 深色 body，与其余示例同一套调色板）。实测：两个模板工程与
  `vue_todo` 均为深色底、卡片层次清楚，`greet` / `timer` / `todo:add` 等交互不受影响。
- `cli/templates/app-vue` / `app-react` 与 `examples/vue_todo` 的示例页面**没有整页居中**：内容
  （标题 / 提示行 / 卡片）贴着窗口左上角，卡片不居中，与零 Node 模板、`examples/hello` 的版面不一致。
  现把 body 改成 flex 列居中（`align-items` / `justify-content: center`；用 `min-height` 而不是 `height`，
  内容比视口高时不会被裁掉），再把挂载点 `#app` / `#root` 设成 `width: 100%` 的居中列 —— 光靠 body 的
  `align-items` 不够：挂载点只有一个子节点，提示行（页面来源 / 桥状态 / 后端版本）很长时会把整列撑宽，
  卡片反而贴在左边。Linux 发行态实测：三处均为整列居中，`greet`、`timer`、`todo:add` 交互未回退。
- **Linux：`quit()` 退出时进程偶发挂死**：宿主线程收尾要进仓颉运行时（窗口销毁回调），而仓颉线程阻塞在
  `cj_plat_fini` 的 `pthread_join` 上会与运行时的「停处理器」握手互等——实测 6 轮挂 1 轮（栈：
  `cj_plat_fini → pthread_join` ↔ `CJ_CJThreadMexit → CJ_ProcessorStopWithLastCheck`）。现改为
  `pthread_detach` + 宿主线程自己置「跑完」标记 + 有界轮询等待（不 join）；没等完就保留平台状态与句柄
  （`cj_plat_fini` 返回 `int`，返回 0 时 `cj_bridge_destroy` 不回收 `cj_host`）。复跑 6/6 干净退出。
- **Linux：`quit()` 退出以 SIGABRT 收尾（退出码 134）**：窗口若在主循环内被销毁，libwebkit2gtk 的**退出期
  析构函数**会在自己的 `g_object_unref` 里 abort（栈：`StartMainTask → exit → __run_exit_handlers →
  libwebkit2gtk … → abort`，与框架代码无关；AB 对照：不销毁窗口 5/6 干净、销毁窗口 5/6 abort）。现改为
  「`quit()` 只收主循环、窗口交给 `gtk_main` 返回后的收尾销毁」，清理照做，`onDestroy` 仍由 `destroy`
  信号触发一次。实测 6/6 干净退出。
- **Linux：收尾对已被父窗口销毁的 view 重复 `g_object_unref`**：`on_destroy` 原先只置空窗口指针、没置空
  view，主循环退出后的收尾仍去 unref 失效的 view。现收尾前判存活并一律置空。
  （注：探针日志里 `g_object_unref: assertion 'G_IS_OBJECT' failed` 的量级与批次 1 之前一致
  ——4449 → 4444~4455，主要来源是既有环境噪声，本条只消掉「重复 unref」这一条路径。）

### Changed

- 文档补 Linux 实测结论：README「验证结果」新增 Linux（2026-10-02）一节，`docs/进度记录.md`
  更新进度与后续项，`docs/使用文档.md` §6.6.1 第 5 步补两个平台的收尾语义与 Ctrl-C 行为。

## [0.4.0] - 2026-10-01

### Added

- 开源许可证：新增根目录 `LICENSE`（MIT）与 README 的许可证说明；开发规范里补「第三方代码需登记来源与许可证」。
- 仓库规范文件：新增 `README.OpenSource`（依赖与许可信息，OpenHarmony 7 字段格式）与 `CONTRIBUTING.md`（贡献指南）。
- 前端入门教程：新增 `docs/前端入门教程.md`（零基础，含一个完整的待办清单实战：桥 API、IPC 协议、事件、
  能力清单、调试入口），README 头部与使用文档 §6 增加入口；同时修正使用文档里 `emit` 的旧说明
  （它是占位实现，消息会被后端判为非法丢弃、也不会回投页面）。
- 教程示例工程入库：`examples/todo_check/`——把《前端入门教程》的待办清单实战落成可运行示例，
  前端 `ui/index.html` 由同目录 `extract.js` 从教程文档抽取，教程与代码同源（改教程可回灌示例）。
- 插件体系设计草案：新增 `docs/RFC-插件体系.md`（RFC-001），并开 issue 征求评审。设计要点是
  「插件 = 仓颉包，贡献命令集 + 事件名 + 前端 JS 片段，一行 `app.plugin(...)` 接入」，
  命令命名与内置 `system:*` 同构（`<插件名>:<命令短名>`），权限仍由应用的能力清单决定。
- 热重载与前端模板设计草案：新增 `docs/RFC-热重载与前端模板.md`（RFC-002）。要点是给宿主加
  `loadUrl`（`TauriApp.runUrl`）：开发时指向前端 dev server 换取 HMR，发布仍产出单文件 HTML；
  桥接脚本本来就是逐文档注入，换成真实 URL 后 `window.__CJ_TAURI__` 照样在页面脚本前就位。
  含七个待评审问题。（本项只是设计草案，实现尚未开始。）
- 框架单元测试：新增 `src/tests/ipc_hub_test.cj`、`src/tests/capability_test.cj`、`src/tests/version_test.cj`
  （23 个用例，覆盖 IPC 解析与分发、能力默认最小权限、版本常量与内置命令），以及入口脚本 `scripts/test.sh`
  （Windows Git Bash 与 Linux 通用）。测试不创建窗口，可在无 GUI 环境跑；`cjpm build` 不编译测试文件。
- 测试目录整理：单元测试从 `src/` 根挪进 `src/tests/` 子包（`package cjTauri.tests`），`src/` 根只留框架源码。
  理由：`cjpm` 只从包内源目录收集测试，顶层 `tests/` 不会被扫描（实测 `TOTAL: 0`），而 `src/tests/`
  作为子包既能被 `cjpm test` 正常收集，也能访问父包符号——23 个用例依旧全绿。
- 窗口图标：新增 `WindowConfig.iconPath`（默认空串 = 系统默认图标，老应用行为不变）与两平台桥的
  同名导出 `cj_bridge_set_icon`。Windows 用 Win32 `LoadImageW` 从 `.ico` 文件加载大小两档图标，
  同时设置窗口类图标与 `WM_SETICON`（标题栏 / 任务栏 / Alt-Tab 一致）；Linux 走 GTK 的
  `gtk_window_set_icon_from_file`（png/ico 均可）。`examples/hello` 带上 `icon.ico` 作为样板，
  该文件由 `scripts/make-demo-icon.js` 生成、可重跑换图。Windows 端已实机验证；Linux 端未验证。
- 静态门禁与 CI：新增 `scripts/check-static.sh`（版本一致性、markdown 围栏成对、脚手架模板占位符
  都在渲染表内、`.bat`/`.ps1` 纯 ASCII、没有被跟踪的构建产物），不需要仓颉 SDK 即可跑；
  两条流水线 `.atomgit/workflows/ci.yml` 与 `.github/workflows/ci.yml` 在 push / PR 时执行它。
  需要 SDK 的 `cjpm build` 与单元测试尚未进 CI（缺 SDK 镜像）。
- URL 页面加载（热重载第一步）：新增 `TauriApp.runUrl(url)`、`TauriApp.devUrl()`（读环境变量
  `CJ_TAURI_DEV_URL`）与 `TauriApp.reload()`；宿主接口相应扩出 `startUrl` / `loadUrl` / `reload`，
  两平台桥各加同名导出 `cj_bridge_load_url` / `cj_bridge_reload`（Windows 走 `Navigate` 与整页 `Reload`）。
  前端桥新增 `__CJ_TAURI__.reload()`：作为宿主控制消息被拦截，不进 IPC hub。
  Windows 实机验证（本地 `http://127.0.0.1:8123/` 静态页 + 探针应用）：`load url:` → `Navigate -> hr=0x00000000`，
  URL 页面里 `window.__CJ_TAURI__` 照常就位、`invoke` 直接可用（`js -> native (101 bytes)`），
  前端调 `reload()` → `frontend requested reload` → `Reload -> hr=0x00000000` → 页面第二次加载并再次 invoke。
  权限模型不变：URL 页面同样受 capability 清单约束。Linux 侧实现同样写了，本机无工具链、未验证。
  CLI 的 `cj-tauri dev` 在同一版里已经接管 dev server 并注入该环境变量（见下一条）。
- 前端模板（Vue 3 + Vite）：`cj-tauri create <工程名> --template vue` 生成带 `ui/` 前端工程的仓颉应用，
  模板目录 `cli/templates/app-vue/`。前端用 Vue 3 + Vite，产物经 `vite-plugin-singlefile` 打成单个
  `ui/dist/index.html`——框架是把页面读成字符串交给 WebView 的，页面没有基准路径，所以发布态必须单文件。
  `create` 的模板参数化（`-t/--template`），缺省仍是 `app`（内联 HTML 的零 Node 样板，老用法不受影响）；
  未知模板名会明确报错。实机验证：`create --template vue` 生成 11 个文件、占位符 0 残留。
- 前端模板（React 18 + Vite）：`--template react` 生成同一套结构（`cli/templates/app-react/`），
  只把 `ui/` 换成 React——`@vitejs/plugin-react`、`src/main.jsx`、`src/App.jsx`，Vite 配置与单文件产物要求一致。
  实机验证：`create --template react` 生成 11 个文件、无残留占位符，`npm install` 与 `npm run build` 均 rc=0，
  产物目录里**只有** `dist/index.html`（145 KB，js/css 文件数 0）。React 版刻意不用 `React.StrictMode`：
  开发模式下它会把 effect 跑两遍，而这个模板的 effect 里要调 `invoke` / `listen`，双跑会让人误以为桥重复投递。
- 文档：`docs/使用文档.md` 新增 §6.6.1「交给 `cj-tauri dev` 自动做」（含 dev 接管 dev server 的 5 步、
  「没有 `ui/package.json` 就不碰 Node」的边界），`docs/前端入门教程.md` 新增 §8.4「官方的 Vue / React 模板」。
  两处都写了 HMR 的排查判据：Vite 的模块图是**客户端请求过页面之后**才建立的，没有客户端连上来时改文件，
  日志只会出现 `[no modules matched]`——那不代表 HMR 坏了；并给了 `DEBUG=vite:hmr` 的实测日志形态。
- `cj-tauri dev` 接管前端 dev server：工程里有 `ui/package.json` 才走这条路径——缺 `node_modules` 先
  `npm install`；再后台起 `npm run dev`（Vite 的输出重定向到 `ui/dev-server.log`）；等到日志里出现 Vite 的
  `Local:` 行（最多 180 秒，超时告警但不硬失败）再启动应用，并注入环境变量 `CJ_TAURI_DEV_URL`。
  应用侧 `TauriApp.devUrl()` 读到它就走 `runUrl`，页面直接来自 dev server；应用退出后收掉 dev server
  （Windows 用 `taskkill /F /T`，连 npm→node 整棵进程树；其他平台 `terminate`）。
  没有 `ui/package.json` 的工程完全不碰 Node，行为与 0.3.x 一致。
  Windows 实机验证（`examples/m2_verify/vueapp`，Vue 3 + Vite 6.4.3）：日志里 `load url: http://127.0.0.1:5173/`
  → `Navigate -> hr=0x00000000` → 页面两次 `js -> native`（第二次只在第一次拿到后端响应后才发出，
  等于「URL 页面 ↔ 仓颉」整条链路通了）→ 前端调 `reload()` → `frontend requested reload` → `Reload -> hr=0x00000000`
  → 重载后再次两次 invoke → 关窗口后 `应用退出` 与 `dev server 已收掉（pid=…）`，`node.exe` 无残留。
- `cj-tauri build` 先打前端发布包：有 `ui/package.json` 时先 `npm run build`，再检查 `ui/dist/index.html`
  确实产出（没装 `vite-plugin-singlefile` 会明确报错），然后才编译仓颉应用。该分支本轮未实机验证。

### Fixed

- `cj-tauri dev` 起 dev server 的命令行改用**相对文件名**重定向日志。`launch` 会给整条命令行加引号，
  绝对路径再自带引号会让 `cmd.exe` 拿到嵌套引号并直接报「文件名、目录名或卷标语法不正确」——
  结果是 dev server 从未启动、应用去连 URL 必然失败（`navigation failed: web status=9`）。
  已实机复现并修复。
- dev server 就绪阈值由 90 秒放宽到 180 秒：本机（Windows + Node 24 / npm 11）实测 `npm` 把 Vite 拉起来
  最慢约 85 秒（Vite 自身只用了 322 毫秒），贴着 90 秒走会误报「没就绪」。
- `create` 的收尾提示语写死了「改了 `.vue` 不重启应用就能看到效果」，React 工程下会误导用户；
  改成「改 `ui/src` 下的前端源码不重启应用就能看到效果」，两个模板都适用。

## [0.3.0] - 2026-10-01

### Added

- `WindowConfig(title, width, height, devTools)` 与 `TauriApp.window(cfg)`：窗口标题与尺寸可配置
  （对标 tauri.conf.json 的 `app.windows`）。默认值与此前 C 桥里的硬编码一致（标题 `cj-tauri`、
  900×640、开发者工具开启），不配置窗口的应用行为不变。
- `TauriApp.loadCapabilities(dir)` 与 `capabilities/` 目录自动扫描：`run()` 时若没有显式挂载任何清单，
  自动加载工作目录下 `capabilities/` 里的所有 json 文件（对标 Tauri 的 capability 目录）；
  显式挂载优先于自动扫描。新增框架源码 `src/capability_loader.cj`。
- `TauriApp.openDevTools()`、命令处理器里的 `ipc.openDevTools()`、内置命令 `system:devtools`，
  以及 `WindowConfig.devTools = false` 的禁用开关。新增框架源码 `src/window.cj`。
- 两平台 C 桥新增同名导出 `cj_bridge_set_window` 与 `cj_bridge_open_devtools`。
- 文档：`docs/仓颉版Tauri-介绍与使用指南.md`（指南体）与 `docs/仓颉版Tauri-博客稿.md`（博客体）。
- 工程文件：本 `CHANGELOG.md`、`AGENTS.md`（开发规范契约）、`scripts/check-version.sh`（版本一致性自检）。

### Changed

- 脚手架模板与 `examples/hello` 改用 `window()` + 能力自动加载；模板的能力清单加入 `system:devtools`。
- `examples/hello` 的能力清单从内联 JSON 改为独立文件 `capabilities/default.json`。
- `run_win.bat` 固定以 `examples/hello` 为工作目录——`capabilities/`、`ui/` 是按相对路径读取的
  （对标 Tauri 以项目根目录为工作目录的约定）。
- 桥与框架的诊断日志统一走 stderr：仓颉 `println` 的 stdout 有缓冲，进程被强杀时日志会丢失，
  而桥的 stderr 每行都即时落盘，端到端验证以此为准。
- Linux 桥 `native/bridge_linux.c` 的窗口尺寸改为可配置（原先硬编码 900×640）。

### Fixed

- `system:devtools` 没有注册进 IPC hub（只在 `SystemCommands.handle` 里加了分支），
  前端 invoke 会拿到 `command not registered: system:devtools`。
- `system:version` 返回的 `platform` 字段固定为 `linux`，在 Windows 上返回了错误的平台。

### Removed

- 端到端验证用的临时工程目录 `.e2e/`（验证完成后清理，不入库）。

## [0.2.0] - 2026-10-01

### Added

- Windows 后端：WebView2 宿主 `src/host_webview2.cj` + C 桥 `native/bridge_win.c`，
  Win32 窗口与消息循环在宿主线程运行（对标 Tauri 的 wry/windows 后端）。
- 仓颉原生 CLI `cli/src/*.cj`：`create` / `dev` / `build` / `run` / `info` / `help` / `--version`，
  外加启动器 `cli/cj-tauri.sh`、`cli/cj-tauri.bat`。
- 脚手架模板 `cli/templates/app/`：占位符渲染，按宿主平台注入依赖与链接段。
- Windows 桥构建脚本 `native/build_win.bat`（含 WebView2 SDK 与 x64 loader 同步）。
- 文档 `docs/使用文档.md`。

### Changed

- README 重写为「CLI 优先」的工作流，并标注 Windows 端到端已验证。
- 仓库改为双托管：`origin` 挂两条 pushurl，一次 `git push` 同时推送 AtomGit 与 GitHub。

### Fixed

- Windows WebView2 集成阶段的崩溃：`hr=0x8007139F`（COM 引用计数语义错误，
  桥内 `ctrl_AddRef`/`nav_AddRef` 改为返回 1 并显式 `AddRef`）。

## [0.1.0] - 2026-08-21

### Added

- 首个可用版本（MVP）：
  - `WebViewHost` 抽象与 Linux webkit2gtk-4.1 宿主（`src/host_webkit.cj` + `native/bridge_linux.c`）——
    GTK/WebKit 调用全部在 C 桥创建的原生 pthread 内执行，规避仓颉 M:N 轻量线程栈被
    JSC 的栈边界校验 abort 的问题。
  - IPC 协议与消息桥：`invoke` / `resolve` / `event`，命令注册、分发与校验中心（`src/ipc_hub.cj`）。
  - 能力安全模型：命令与事件白名单，默认最小权限（`src/capability.cj`）。
  - 内置命令 `system:version` / `system:ping` / `system:echo`。
  - 示例应用 `examples/hello`（greet + tick 事件推送 + 越权拒绝演示）。
