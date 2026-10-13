# 更新日志（CHANGELOG）

本文件记录 cj-tauri 的对外可感知变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)：0.x 阶段只递增中间位（能力）与末位（修复），
打到 1.0.0 后才固定对外 API。

- 分类用 `Added` / `Changed` / `Fixed` / `Removed` / `Security`，中文描述；
- 每条写**能观测到的行为**（命令、API、文件、日志），不写内部重构流水账；
- 发版时更新的文件清单与校验方式见 `AGENTS.md` 的「版本与发版」一节；
  一致性用 `scripts/check-version.sh` 自检。

### Added

- **Windows 实机 E2E 入口（`scripts/e2e/test-windows-bridge.sh`）**：与 Linux 入口同构（同一
  fixture 探针、同一套公共层与证据 JSON），断言随能力位落地扩到 **11 条**：能力清单加载 / 桥注入 /
  页面→宿主 IPC / 端到端往返 / 未授权命令被拒 / `system:host` 能力位如实上报（`host=windows
  menu=true tray=false dragDrop=true`）/ 剪贴板写读回环（值一致）/ 拖放目标已挂载
  （`drag dest attached (CF_HDROP)`）/ 通知 toast 已投递（`notification SENT-OK`）/ 串口枚举链路
  （`serial:list ports=`）。探针应用同步扩面：装配 `ClipboardPlugin` / `NotificationPlugin` /
  `SerialPlugin` 并 `setDragDrop(DragDropPolicy(true, true))`，再调 `system:host`——能力位的
  「真实现能通、桩如实拒」两平台各有一份对账 JSON。
- **Windows 拖放真实现（OLE `IDropTarget`）**：同名桩转正，平台能力位置 `dragDrop` 位
  （`[cj-bridge] host capabilities: 0x5 (menu=1 tray=0 dragDrop=1)`）。照 wry 的两条要点写：
  装配期先 `put_AllowExternalDrop(FALSE)` 关掉 WebView2 自带的外部拖放（不关它先吃掉 drop，
  默认行为是导航到那个文件），再 `EnumChildWindows` 逐子窗口 `RevokeDragDrop` / `RegisterDragDrop`
  挂上我们的目标；`Drop` 只认 `CF_HDROP`（其余格式如实不收），URI 解析仍在共享层
  （`native/core/bridge_core.c`），报文 `drop` → 前端 `dragdrop:files` 与 Linux 侧同一形状。
  链接行补 `-lshell32`（`native/build_win.bat`）。**改了 C 桥：拉取后先重建平台桥**。
- **Windows 通知真实现（PowerShell Toast）**：同名桩转正，`notification:notify` 在 Windows 上真投递
  ——一句 PowerShell 借 `Windows.UI.Notifications.ToastNotificationManager` 弹 toast（AUMID 用
  PowerShell 自己的，未注册 AUMID 的 toast 在 Win10+ 不显示），标题 / 正文经 base64 传给
  `-EncodedCommand`（避开命令行引号与编码），XML 转义在桥内做。发送语义仍是 **fire-and-forget**
  （`CreateProcessW` 成功即返回 0，toast 可不可见由系统托盘设置决定），投递前照旧先查
  `CJ_CAP_NOTIFICATION` 能力位，未声明当场回 `-4`。
- **`WebViewHost.showFileDialogPreset(save, title, filter, defaultName)`**：带默认文件名的文件对话框，
  与 `showFileDialog` 完全同语义、多一个预置名。用途是**自动化取证**——对原生框发 IDOK 时框里得已有
  名字才能关，返回值因此可预期（预置什么回什么）。Windows 侧经已有的 `message` 参数通道把名字交给桥
  （文件类对话框把它当预置名）；GTK 轮未接，如实降级为普通文件框（接口成员增删，测试桩 `FakeHost`
  同步实现）。配套用例：`examples/multi-window` 两窗**同时**开文件框、各预置 `probe-<label>.txt`，
  经 `dismiss-dialogs.ps1` 自动确认后各窗必须拿回自己的名字（`FILE-DONE which=main ok=true
  path=…\probe-main.txt`）——文件框结果不是调用返回值，而是桥按**宿主句柄**经 `onDialog` 写进
  **本宿主自己的** `dialogResult`，串台会当场现形（27 项断言、`exit=0`）。
- **`dist-report.sh` 的 Windows 冷启动数据**：单文件 exe（modbus-poll）中位数 **704 ms**
  （3 次：8467 / 675 / 704；首跑含磁盘缓存冷态），口径与 Linux 侧一致（同一行 needle）。
- **npm 元数据与配图口径**：npm 包 `keywords` 从 7 个扩到 16 个（下次发布生效），AtomGit 仓库介绍换成
  可检索文案。并实测确认**仓颉官方社区的入口**：邮件列表在 `lists.cangjie-lang.net`（Mailman 3 /
  Postorius，网页注册即可订阅），`dev@` 用于社区开发讨论、`core@` 用于整体技术治理与管理；参与贡献需先
  签 CLA（`clasign.cangjie-lang.cn`）。配图口径上，**AtomGit 的 raw 直链取不到文件**（`/raw/`、`/-/raw/`、
  `/blob/`、`raw.atomgit.com/` 四种形态都只返回前端 HTML），对外发文配图改用 GitHub 镜像的 raw
  （实测 `200 image/png`，示波器截图 92686 字节、架构图 379460 字节，与仓内文件一致）。
- **入门文章（`docs/仓颉版Tauri-入门与串口波形示波器实战.md`）**：把「npm 起工程 → 串口实时波形示波器
  → 实机取证」写成一篇可对外发表的长文。里面讲的是**实际行为**而不是设想：`npx cj-tauri create/dev` 的
  SDK 前置与三级 CLI 解析、缺 SDK 时给的是可操作提示（`--version` 无 SDK 也能查）、能力清单与命名权限集
  （`serial:default`）、行协议与页面短读循环、探针模式（配置经 document-start 注入）、以及 Linux 实机那份
  数据（404.2 样本/s、上穿 8、丢帧 0、`verdict=ok`）和**边界**（串口 Windows 侧未取证、鸿蒙预留、
  托盘暂缓、示例未接单文件打包）。文中代码片段与截图逐条取自仓内文件，没有量过的数不写。
- **仓内 E2E 基建（`scripts/e2e/`）**：实机验证从「每轮现写临时脚本」收进仓库——
  `lib.sh`（平台守卫 / 断言收集 / 证据收口 / 应用启停）、`fixture-app/`（探针应用：页面从磁盘读，
  改探针页不用重编译仓颉）、`test-linux-bridge.sh`（Linux 真机入口，6 条断言覆盖能力清单加载 /
  桥注入 / 页面→宿主 IPC / 端到端往返 / 未授权命令被拒）、`run-all.sh`（把**通过 / 跳过 / 失败**
  分开计数——「全跳过」与「全通过」在退出码上同形，那是假绿最爱的形状）。
  **平台守卫**：入口声明目标平台，宿主不匹配时默认 **FAIL 而不是跳过**；需要在别的机器上跑全套时
  显式 `CJ_TAURI_E2E_SKIP_OTHER=1`，CI 用 `CJ_TAURI_E2E_REQUIRE=linux` 声明「本机必须跑」。
  另修一处真实坑：`DISPLAY` 存在 ≠ 显示器可用（SSH 转发失效时变量仍在），改为**真探测**
  （xdpyinfo / xdotool / xset）后再决定是否回落 Xvfb，并补上 stdx 动态库探测
  （漏它时应用启动即退、只留一行 `cannot open shared object file: libstdx.encoding.json.so`）。
- **IPC 报文协议版本字段**：事件 / 回执信封加 `protocol` 字段，`system:version` 返回同一常量
  （`CJ_IPC_PROTOCOL`，`src/version.cj` 单一来源）。**旧报文形态只增字段、语义不变**，页面侧解析不受影响；
  协议字段自此是跨层契约的一部分（C 桥注入脚本的页面侧解析、CLI 的清单消费、将来跨进程形态），
  删字段 / 改语义必须抬版本。
- **`cj-tauri doctor` 子命令**：环境自检**逐行给结论**（`ok` / `warn` / `FAIL`），每条失败自带
  「缺了就怎么办」——cjc / cjpm 以**命令自身退出码**判定（二进制在 PATH 里但运行时加载不了时
  报 exit=127 并指出 `LD_LIBRARY_PATH`）、仓颉运行时是否已进 `LD_LIBRARY_PATH`、`CANGJIE_STDX` 指向、
  框架根 / 项目根、C 桥产物与框架源码的新旧比较（改了 C 桥没重建会给出重建命令）、
  Linux 图形栈（webkit2gtk-4.1 / gtk+-3.0 / gcc）。退出码 0 = 必需项全过（warn 不算失败），1 = 有失败项。
- **E2E 证据 JSON 化（`scripts/e2e-evidence.sh`）**：把一次实机验证落成机器可对账的
  `dist/e2e-evidence/<平台>-<名字>.json`——平台、Runtime 版本（Linux 取 pkg-config 的
  webkit2gtk / gtk3，Windows 从桥日志读 WebView2）、每条断言的**命中次数**、UTC 时间、命令退出码。
  断言按「整行前缀」grep 日志，未命中即退出码 1（`--allow-missing` 可放宽）。
  `scripts/check-static.sh` 新增第 7 项：证据文件结构合法且 `summary.ok` 为真，否则门禁 FAIL
  （`supported` 的门槛是「可复核证据」，那这份证据自己也得过关）。
- **`docs/设计决策记录.md`（ADR）**：12 条已生效的架构与工程决策——每条写「结论 / 备选方案 /
  为什么 / 真实代价（含已踩的坑）/ 复评触发条件」（同进程桥、协议版本、平台差异收敛、能力分级、
  证据 JSON、scope 语义、异步分发、插件声明与放行分离、插件子包边界、CLI 判据、托盘暂缓、文档双轨）。
  README 文档索引与 `AGENTS.md` §2 已挂入口：做出或推翻长期决策时同轮更新对应条目。

### Fixed

- **通知「发后即忘」在未声明 `CJ_CAP_NOTIFICATION` 的平台被读成成功**：core 投递成功即返回 0，
  UI 线程里平台实际失败（`-> failed`）没人带回命令层——Windows 桩阶段页面侧拿到的是「发送成功」。
  现 core 在投递前查能力位，未声明当场回 `-4` 并打
  `[cj-bridge] notification rejected: platform does not declare CJ_CAP_NOTIFICATION`；桩自检补 2 条
  （未声明能力位如实回 -4 且不触达平台，162 → 164）。**改了 C 桥行为：拉取后先重建平台桥**。
- **`host_webkit.cj` 的 `cj_bridge_set_drag_drop` 声明漏 `@When[os == "Linux"]` / `@C`**：Windows 侧
  与 webview2 文件的同名声明重定义、编译失败（Linux 上无感）——「跨平台文件别按单平台编译结果清
  条件编译」的 FFI 声明变体。
- **`e2e-evidence.sh` 脱 python3 依赖**：Windows 机上没有 python3 时 JSON 转义全空、证据成了坏 JSON
  （断言名 / needle 为空、runtime 版本断行成 `"2\n0"`）——改纯 bash 转义；JSON 自检回退
  `python3 → python → py -3`；WebView2 版本改认 `ver=` 字段（那一行里先出现的是 `hr=`，泛匹配抓回 "2"）。
- **`lib.sh` 的 Windows 收尾与环境三处**：① `pgrep -P` 看不见原生进程，WebView2 的
  `msedgewebview2.exe` 杀不干净，下一实例撞 `0x800700aa`（用户数据目录被占用）——改 `ps -W` 映射
  Windows pid 后 `taskkill //F //T` 整树杀；② 每轮运行给独立 `WEBVIEW2_USER_DATA_FOLDER`，
  实例间互不锁；③ `CANGJIE_STDX` 常是盘符形式（`D:/...`），进 PATH 前 `cygpath -u` 转 POSIX。
- **两条软链接 scope 单测在无符号链接特权的 Windows 上如实跳过**：建链被系统拒（错误 1314）时
  打一行 `[skip]` 说明后返回，不再误报 ERROR（判定面由 Linux 轮覆盖）。
- **`host_webkit.cj` 的 `std.collection.*` import 改限定名**：Windows 侧报 unused 警告、Linux 侧
  必须要用——文件级 import 改 `std.collection.ArrayList` 限定名，两平台都零警告。

## [Unreleased]

（尚未发版的下一个版本，按 Added / Changed / Fixed / Removed 就地累积，
发版时把本段整体改名为 `[x.y.z] - YYYY-MM-DD`，并在下方新开一个空的 Unreleased。）

### Added

- **官网落地页（`website/`）**：单页深色站点，**中英双语**（中文即页面正文，英文放 `data-en*` 属性上，由
  `assets/app.js` 切换；断网、`file://` 直开、关掉 JS 三种情况下页面都完整）、**零外部依赖**（不引 CDN、
  不引 Web Font、无统计脚本，图标一律内联 SVG）。发布走 `.github/workflows/pages.yml`：`main` 上任何
  改动 `website/**` 的提交都会把该目录整份推到 `gh-pages` 分支（每次一个孤儿提交，历史不累积），
  GitHub Pages 认这个分支——推上去即发布，不需要人去动仓库设置。
  配套 **`scripts/site-check.sh` 站点自检**（不需要 SDK / 浏览器：引用存在性、零外部依赖、中英文案覆盖、
  死锚点、标签页与面板配对、class 与 CSS 对齐、OG 卡片尺寸），其快速档已并入 `scripts/check-static.sh`，
  官网改动因此同样被常规门禁拦住；`--shots` 抓中英两态截图（需本机有 firefox）、`--links` 联网核对外链。
  站内数字全部取自 `docs/分发形态实测.md` 的现场实测，没量到的格子如实留空。
- **官方插件 `sqlite`（`src/plugins/plugin_sqlite.cj` + `src/plugins/sqlite_ffi.cj`）**：
  **仓库首个「`foreign func` 直连第三方原生库」**的样板——不经 C 桥，仓颉侧直接调系统 `libsqlite3`
  （示例 `cjpm.toml` 的 `link-option` 加 `-lsqlite3`）。七条命令 `sqlite:env` / `info` / `tables` /
  `schema` / `page` / `query` / `exec`，两个命名权限集 `sqlite:readonly`（六条只读）与 `sqlite:default`
  （加 `exec`）——**集声明 ≠ 放行**；`scopeAware()` 为真，库文件路径一律过共享层 scope
  （**命令放行 ≠ 参数放行**）。三条护栏：浏览类命令用**内核级** `SQLITE_OPEN_READONLY`（写语句的拒绝原文
  来自 sqlite 自身，不是我们写的检查）、`ATTACH` / `DETACH` / `load_extension()` 由 authorizer 按语句拒
  （并另关扩展加载）、SQL 里的表名 / 列名先过 `sqlite_master` / `PRAGMA table_info` 白名单再拼。
  回投**如实**：页上限 500 行（夹紧带 `limitClamped`）、单元格 65536 字节（截断带 `bytes` + `truncated`）、
  BLOB 只报字节数不回投本体；每条命令**短连接**（开 → 装护栏 → 干活 → 关），`busy_timeout` 3000 ms。
  单测 +7 例（真库 FFI 往返，`src/tests/plugin_sqlite_test.cj`）。
- **SQLite 浏览器示例（`examples/sqlite-browser/`）**：库对象清单 / 数据分页网格（排序、类型上色、
  超长单元格截断标记）/ SQL 调试台（**只读**与**可写**两个按钮分开——「运行」走只读连接，被内核拒的那句
  原文故意显示给用户看）。E2E 入口 `scripts/e2e/test-linux-sqlite-browser.sh`：**49 条断言全过**，
  页内自检 **36/0**、夹具对端 `fixture.py` 自检 **12/0**，另有**进程外核对**——应用退出后由另一个进程
  （python3 的 `sqlite3`，与仓颉侧链接的是同一个系统库）以 `mode=ro` 只读打开**同一个库文件**，
  确认页面经 `exec` 写的那一行真的落盘。负向证据：**无** `command not allowed` / `not registered` 误报、
  `scope denied (sqlite)` 恰好 1 次（自检故意越界那条）、authorizer 只拦 1 次（其余语句照常执行）、
  被拒命令都在桥侧留了原因。**Windows 侧未落地**（要自带 `sqlite3.dll` 并补 `scripts/pack-win*.sh` 的
  DLL 清单，D-018 第 8 条），如实标注。
- **HTTP API 客户端示例（`examples/http-client/`）**：Postman 那一类的调试客户端——**左拼请求 / 中看响应 /
  右管集合与历史**三栏，零 Node、零前端库、**页面里一次 `fetch` 都没有**（网络请求全在仓颉侧直发：
  `stdx.net.http` + 显式 `TlsClientConfig()`，TLS 走**系统证书库校验**，没有「关校验」的开关）。
  命令是**示例自己注册**的（`http:send` / `http:allow`）、**不是插件**：HTTP 客户端的能力面就是「任意 URL」，
  做成插件等于给所有应用开一条通用出网通道（理由见 `docs/设计决策记录.md` D-017）。语义上有三处刻意选择：
  **4xx/5xx 当结果而不是异常**（三分 `Exchange` / `Refused` / `Failed`，只有 scheme 不支持、host 不在白名单、
  传输层失败才 reject）、响应头**逐条不合并**（同名出现两次就渲染两行并标记）、
  二进制体**只报字节数不回投原始字节**（把非法 UTF-8 塞进 IPC 只会变成乱码）。大响应体按 `CJ_HTTP_BODY_LIMIT`
  （默认 1 MiB）截断并如实回投 `bodyTruncated` / `bodyLimit` / `contentLength`；出网白名单 `CJ_HTTP_ALLOW`
  缺省**只放本机**（fail-safe，不配就发不出对外请求）；集合 / 历史 / 变量集落 `data/` 且受清单 `scopes.fs` 约束
  （`../etc/hostname` 这类越界读由共享层拒）。示例自带**自写的** mock 对端（`mock-http.py`，python3 标准库、
  零第三方依赖，9 条路径分支、`--selftest` 16/16 自证）。示例说明见 `examples/http-client/README.md`。
- **HTTP 客户端页内自检 34 条 + 实机 E2E 入口 `scripts/e2e/test-linux-http-client.sh`（55/55 断言全过）**：
  验的是完整一跳「页面 → 桥 → IPC → 能力校验 → `http:send` → 仓颉侧 HTTP → mock 对端 → 回投 → 渲染」，
  且**三侧证据合一**（页面 `[frontend] SELFCHECK PASS|FAIL …`、桥 `[http-client] GET … -> 200 78B truncated=false`、
  对端 `[mock-http] REQ/RESP …`，收尾时对端日志并入同一份证据日志）。四条**外部对账**（判据不是「页面说自己成了」）：
  自检计数 **34/0**；**截断三侧**（对端说发出 2097152 字节 / 桥侧说只读了 1048576 且 `truncated=true` /
  页面说 `bodyBytes` 同值且 `contentLength` 报全量）；**对端 `REQ=11 RESP=10`**（差的那 1 条正是被超时中断的
  `/slow`，超时路径在对端侧看得见）；**请求体字节数双侧一致**（页面按 UTF-8 自算 22 字节 = 对端 `Content-Length`）。
  负向断言：`command not allowed` / `not registered` 误报零条、`scope denied` 恰好 1 次（自检里那次故意越界）、
  被拒的 `http:send` 都在桥侧留了原因。证据 `dist/e2e-evidence/linux-linux-http-client.json`。
  **Windows 侧未验证**（未实机跑、未进单文件打包）。
- **文档：`docs/工具计划.md` 的 ② 标为已交付**（连同与当初设想的差异一起记档：体只做 raw 文本、查询串直接写在
  地址里、白名单是示例自己的而不是框架能力位、E2E 对端是自写的 `mock-http.py` 而非 `http.server`）。
- **新示例 `markdown-notes`（Markdown 笔记）+ `fs` 插件补 `list` / `remove`**：示例是
  **左文件树 / 中编辑 / 右实时预览**三栏，工作区就是一个目录（`notes/`），零 Node、零前端构建、
  **不引第三方 Markdown 库**——渲染器与界面都在一份 `ui/index.html` 里（**独立文件**、不内联进仓颉
  三引号字符串：AGENTS §4 那条「三引号先吃反斜杠转义」会让整段 `<script>` 静默语法错误，
  独立文件还能被 `node --check` 静态验语法）。支持标题 / 强调 / 行内码 / 删除线 / 链接 / 无序与有序
  列表 / 引用 / 围栏代码块 / 分隔线；**表格、任务清单、原始 HTML 透传、图片渲染有意不做**
  ——正文因此不构成注入点：渲染全走 `createElement` + `textContent`、不拼 `innerHTML`
  （页内有一条断言拿 `<img src=x onerror=…>` 验这个），图片在 `run(html)` 的内联来源下取不回来，
  故显式降级成一行说明而不是留个白框。保存 `Ctrl+S`、重命名 = **写新 + 删旧**（插件的面里没有 rename）、
  删除要按两次确认；全程不用 `window.prompt`/`confirm`（WebKitGTK 的脚本对话框要宿主接
  `script-dialog` 信号才弹得出来，没接就是「点了没反应」），改成页内行内输入框与按钮二次确认；
  `store` 记住上次打开的笔记。
  **路径 scope 是这一款的展示点**：清单 `scopes.fs` 只放行 `$CWD/notes` 及其下，越界读、越界列目录、
  `notes/../src/main.cj` 三种形状**都由共享层**（`src/scope.cj`）拒，页面自己不做任何路径判定
  （命令放行 ≠ 参数放行）。为支撑示例，框架 `fs` 插件补两条命令：`fs:list`（列目录，返回
  `name` / `size` / `isDirectory`，按名字排序）与 `fs:remove`（可选 `recursive`）——两条都
  **scope 感知**，并加入命名集 `fs:readonly`（3 成员，只读）/ `fs:default`（5 成员）；`fs:remove`
  对**目录**默认拒（调用前先 `isDirectory()` 挡，避免 `std.fs.remove` 能删空目录这件事变成静默删树）。
  **页内自检 21 条**（`CJ_MARKDOWN_SELFCHECK=1`，开关经 `notes:env` 命令交给页面——页面读不到进程环境）
  与实机 E2E 入口 `scripts/e2e/test-linux-markdown-notes.sh` **25/25 断言全过**，两侧都有证据：
  页面侧明细经 `report` 回投成 `[frontend] SELFCHECK PASS|FAIL …`，桥侧留同一次拒绝的
  `[cj-tauri] scope denied (fs): …`。证据 `dist/e2e-evidence/linux-linux-markdown-notes.json`。
  **Windows 侧未验证**（未实机跑、未进单文件打包）。示例说明见 `examples/markdown-notes/README.md`。
- **文档：新增 `docs/工具计划.md`（工具类示例选题与顺序）**：四条选型判据 + 八款总表——
  入选 **Markdown 笔记/编辑器**（`fs` 路径 scope + `store`，自写 Markdown 子集）/ **HTTP API 客户端** /
  **SQLite 数据库浏览器**（FFI 到原生库）/ **剪贴板历史管理器**（需先补全局快捷键与托盘两个能力位），
  备选系统资源监视器 / 双栏文件管理器 / 托盘常驻小工具 / 消息队列调试台；每款入选项含形态、复用与新增、
  展示点、无人值守验收判据与「不做」清单。本轮只有文档，无代码与能力位变更。
- **Redis 客户端调试工具（`examples/redis-client/`）+ `redis` 官方插件**：框架侧新增 **RESP2 客户端**
  （`src/plugins/plugin_redis.cj`，纯仓颉 `std.net` TCP 自实现；协议编解码单独一层
  `src/plugins/redis_codec.cj`——五种 RESP2 类型 + **三态读取**「有值 / 尚不完整 / 畸形」，TCP 粘包靠它兜住）。
  插件命令 **19 条**：`redis:connect` / `disconnect` / `select` / `status` / `info` / `dbsize` / `slowlog` /
  `scan` / `keyInfo` / `keyRename` / `keyDelete` / `keyExpire` / `keyPersist` / `value` / `valueWrite` /
  `subscribe` / `unsubscribe` / `publish` / `messages`，事件 `redis:message` / `redis:state`，
  命名权限集 `redis:default`（19 条）与 `redis:readonly`（13 条只读）。
  **两条 socket**：命令侧一问一答，发布订阅另占一条（订阅后按协议只能收推送）；消息同样走**双通道**
  （事件实时推 + `messages` 取走即清，上限 500 条，页面按 `seq` 去重）。
  `value` 的返回**跟着类型走**：`string` 给 `value{bytes,truncated,text,hex}`（二进制逐字节保真，单值文本上限 64 KiB）、
  `hash`/`set` 走游标分页（`entries`/`members` + `cursor`）、`list`/`zset`/`stream` 走区间（`items`/`entries` + `total`）。
  设计取舍见 `docs/设计决策记录.md` 的 D-016。边界：只做 **RESP2 与单实例**，不做 Cluster / Sentinel /
  TLS（`rediss://`）/ ACL 管理 / MULTI / EVAL；**控制台式「任意命令直发」有意不做**（等于把整台服务器的
  权限面摊给页面）；连不上给明确错误、不静默重试。示例自带**自写的** mock redis 对端（`mock-redis.py`，
  标准库 socket，启动 seed 14 键 + `--selftest` 12/12 自证）与调试台页面（连接 / 键列表 /
  类型化值面板 / 发布订阅消息流 / INFO·DBSIZE·SLOWLOG），一键 `bash examples/redis-client/run.sh`。
- **Redis 实机 E2E（`scripts/e2e/test-linux-redis-client.sh`）47 条断言全过**：验的是完整一跳
  「页面 → 桥 → IPC → 能力校验 → `redis:*` → 仓颉 RESP2 客户端 → TCP → 对端 →（回推）→ 订阅读线程
  → 事件 + 缓冲 → 页面」，且**两侧都有证据**（收尾时对端日志并入同一份证据日志，靠 `[mock-redis]` 前缀分流）：
  应用侧 `scan all keys=14 done=true enriched=14`（每键都补了 TYPE/TTL）/ `scan match=user:* keys=3` /
  `scan type=hash keys=1` / 六种类型取值（`value … hex=0001FFFE` 二进制逐字节保真、`read back … bytes=16`
  写后回读一致）/ `keyPersist applied=true` / `keyRename newKey=probe:renamed` / `keyDelete requested=2 deleted=2` /
  `subscribe ok=true channels=1 patterns=1` / `message seq=1 kind=message` 与 `seq=2 kind=pmessage`
  （频道与模式两条路都收到）/ `messages count=2 seen=2 dropped=0` / `disconnect hadSub=true droppedChannels=1` /
  `reconnect ok state=connected`；对端侧 `client connected`（一轮 3 次：命令连接 + 订阅连接 + 重连后的命令连接）/
  `HSCAN`·`SSCAN`·`DEL`·`EXPIRE`·`RENAME`·`SUBSCRIBE`·`PUBLISH` 的 `rx` / `PUBLISH push ch=… subscribers=1`。
  负向断言：`command not allowed` / `not registered` 零条，取值失败行零条。
  证据：`dist/e2e-evidence/linux-linux-redis-client.json`。**Windows 侧未跑**（协议与 socket 无平台分支，但未验证就写未验证）。
- **MQTT 客户端调试台示例（`examples/mqtt-client/`）+ `mqtt` 官方插件**：框架侧新增 **MQTT 3.1.1 客户端**
  （`src/plugins/plugin_mqtt.cj`，纯仓颉 `std.net` TCP 自实现；协议编解码单独一层
  `src/plugins/mqtt_codec.cj`，畸形报文解码返回 `None`）。插件命令
  `mqtt:connect` / `subscribe` / `unsubscribe` / `publish` / `disconnect` / `status` / `recent`，
  事件 `mqtt:message` / `mqtt:state`，命名权限集 `mqtt:debug`（一次放行七个命令）。
  报文走**双通道**：事件实时推 + `recent` 取走即清（上限 500 条、单条正文按 256 KiB 截断，
  高吞吐下如实上报丢弃计数，页面按报文里的 `seq` 去重）。设计取舍见 `docs/设计决策记录.md` 的 D-014 / D-015。
  边界：只做 MQTT 3.1.1（级别 4）明文 TCP，不做 TLS（MQTTS）/ WebSocket 传输 / MQTT 5.0 属性与原因码；
  连不上给明确错误、不静默重试。示例自带**自写的** mock broker 对端（`mock-broker.py`，标准库 socket，
  `--selftest` 10/10 自证）与调试台页面（连接 / 订阅 / 发布 / 报文流时间线 / 状态与订阅表），
  一键 `bash examples/mqtt-client/run.sh`。
- **MQTT 实机 E2E（`scripts/e2e/test-linux-mqtt-client.sh`）27 条断言全过**：验的是完整一跳
  「页面 → 桥 → IPC → 能力校验 → `mqtt:*` → 仓颉 MQTT 客户端 → TCP → 对端 broker →（回推）→ 读线程
  → 事件 + 缓冲 → 页面」，且**两侧都有证据**（收尾时对端日志并入同一份证据日志，`[mock-broker]` 前缀可分流）：
  应用侧 `[cj-tauri] mqtt: state=connected` / `[frontend] MQTT connect ok state=connected` /
  `publish ok topic=demo/tx` / `probe recent count=35` / `probe reconnect state=connected`；
  对端侧 `CONNECT proto=MQTT level=4` **同一轮出现 2 次**（重连被对端看见）/ `CONNACK tx rc=0` /
  `SUBACK tx pid=` / `PUBLISH rx topic=demo/tx qos=1 retain=False` 与 `qos=2`（载荷逐字
  `hello-mock` / `hello-qos2`）/ `PUBREC tx` → `PUBREL rx` → `PUBCOMP tx`（QoS 2 发送侧整条状态机）/
  `PUBACK rx`（客户端对回推的 QoS 1 回了确认）/ `PINGRESP tx`（1 秒保活心跳）/ `DISCONNECT rx`。
  证据：`dist/e2e-evidence/linux-mqtt-client.json`。**Windows 侧未跑**（协议与 socket 部分无平台分支，
  但未验证就写未验证）。
- **`serial-waveform` 接上单文件打包（`bash scripts/pack-win-single.sh examples/serial-waveform`）**：
  示例新增 `src/packed_assets.cj`（空存根）与 `src/packed_resources.cj`（`decodeBase64` / `splitBy` /
  `textOrFile`），页面与能力清单改成「**内嵌优先、否则读盘**」——把 `ui/` 与 `capabilities/` 搬走也照跑
  （隔离目录实测：窗口起得来、能力清单来自内嵌资源、页面正常加载）。产物
  `examples/serial-waveform/dist-single/serial-waveform.exe`：**4 914 688 字节**
  （sha256 `c26f4dfee2bc…`）、`Subsystem 00000002 (Windows GUI)`、PE 导入表逐项都是系统 DLL。
  打包器同轮修两条（详见 `AGENTS.md` §4）：gcc 行补 `-I"$NATIVE/core"`——`native/` 按平台重整后
  `bridge_core.h` 不再是 `bridge_win.c` 的同目录，报的是 `bridge_core.h file not found`；
  生成 `cjpm.toml` 的 heredoc **不加引号**（要展开变量），故注释里的反引号必须写成 `\``，
  否则 bash 把注释正文当命令执行。
- **`serial-waveform` 的「设备」从手输路径改成端口下拉（Windows 实机验收）**：页面启动即调
  `serial:list` 枚举本机串口填下拉（Windows 经 C 桥 `QueryDosDeviceW` 得到 `COM*`，Linux 为设备节点类
  前缀与 `/dev/serial/by-{id,path}/`），加「↻ 刷新」按钮供热插拔后重枚举；默认选中第一项——
  所以 Windows 打开先是 `COM1`，不再是写死的 `/dev/ttyUSB0`。伪终端不在枚举范围内，
  探针路径（`CJ_SERIAL_PROBE_PATH`，Linux 侧是 pty 从端）仍会被补进下拉并选中，探针链路不受影响。
  实机取证：单文件包 `examples/serial-waveform/dist-single/serial-waveform.exe` 窗口默认选中 `COM1`，
  stderr `[frontend] [wave] port enum: 2 item(s) picked=COM1`（本机 `COM1` / `COM2` 两口）。

- **架构图（`docs/images/architecture.svg` + `.png`）**：README 的架构段不再只有字符画——分层图覆盖
  前端桥 → IPC 消息桥 → 能力安全模型 → 内置 / 插件命令 → WebView 宿主（Linux / Windows / 鸿蒙）→ 共享 C 层，
  并把最容易看错的几条语义标在图上：**授权在调用线程同步拒绝、命令在 worker 线程执行、结果 / 事件异步回投**。
  鸿蒙一格按如实状态画（能力位报 0、未实机验证），不画成「已支持」。
- **新示例 `serial-waveform`（串口实时波形示波器）**：`serial` 插件 + canvas 双缓冲自绘（网格 / 零线 /
  量程刻度 / 滚动窗口），页面按行协议 `<序号>,<值>` 解析样本并**自己算**速率、上穿次数、丢帧数，
  探针跑完只有 `verdict=ok` 才算过。Linux 实机（Xvfb + `os.openpty()` 造的内核 pty 对端按 400 Hz 出样本）：
  对端侧落盘 `SCAN\n`（进程外证据）、页面 `rate=404.2/s`（400 Hz 兑现）、`upcross=8`、`gaps=0`、
  统计行 样本 2002 / 画布 1148x566；截图见 `docs/images/example-serial-waveform.png`。零告警构建，产物 4.7 MB。
- **E2E 入口 `scripts/e2e/test-linux-serial-waveform.sh`**：把示例收进仓内 E2E 基建，10 条断言走完
  **页面 → 桥 → IPC → 能力校验 → `serial:open/write/read` → C 桥 → 内核 pty** 全链路；
  并额外拿对端写下的原始字节 `~-rx.bin` 作**进程外**凭证——页面那句「已写出」不算数。
  `bash scripts/e2e/run-all.sh` → 通过 2 / 跳过 0 / 失败 0，证据 `dist/e2e-evidence/linux-linux-serial-waveform.json` 10/10。
- **`scripts/dist-report.sh` 与 `docs/分发形态实测.md`（分发形态实测）**：把「产物多大、带不带依赖、
  开窗多快」变成可复核的数——现场量入库单文件 exe 的体积 / sha256 前 12 位 / PE 导入表（按系统 DLL
  白名单分类，非系统项单独列出），Linux 侧量「可执行文件 + 随包共享库」与冷启动，
  `--svg` 直接从同一份数据出对比图（`docs/images/dist-size-compare.svg`）。
  本轮结论：四份 exe **5.5–9.5 MB**、导入表 **8–9 项全为 Windows 系统 DLL（非系统 0）**、
  子系统为 `Windows GUI`（双击不弹控制台）；Linux 目录式 11.31 MB、冷启动中位数 **54 ms**。
  口径与**未验项**（Windows 冷启动、单文件形态下 openssl 的落法）都写在文档里，不含糊。
- **文件拖入（RFC-002 §7.B / RFC-003 第 1 期，核心能力位收口）**：`TauriApp.setDragDrop(DragDropPolicy.filesEnabled())`
  一行打开（**必须在 `start()` 前调**；不设 = 不注册 drop target，现有应用零改动）。拖入文件以
  `dragdrop:files` 事件投给页面（载荷 `{paths: [...]}`，需在能力清单 `events` 里声明）。
  URI 解析在 C 桥 core（`cj_bridge_set_drag_drop` + `cj_core_drop_files`：`file://` 剥前缀、%XX 解码、
  注释/空行跳过、32 个/4096 字节上限），报文经 on_shell **按句柄路由**（多窗口不串台）；
  Linux 走 `gtk_drag_dest_set` + `drag-data-received`，Windows 为同名桩（能力位如实不置位）。
  Linux 实机（Xvfb + pygobject drag source + xdotool 合成拖拽）：`drop: paths=2`（含空格文件名
  %20 解码正确）→ 页面 `drop-received paths=2`；`system:host` 报 `dragDrop=true`。
  **托盘暂缓**（用户裁定：Linux 依赖 libayatana-appindicator3 三方库；Windows 侧也未做，`tray=0` 如实）。
  桩自检 151 → **162**（drop 解析/策略透传/句柄路由 11 条断言）。
- **scope 边界补强（SEC-003）**：`scope_test.cj` 新增 3 条——白名单内软链接指向外面**必拒**
  （规范化解析软链接）、软链接落点在白名单内**放行**（对照组）、`%2e%2e` 是字面量文件名
  **不做 %XX 解码**（反转义归插件/桥的 URI 层，scope 层不重复解码）。单测 189 → **192**。
- **native 层按平台分目录 + 需求追踪矩阵（按「每平台一目录 + 契约 README」的通用平台组织惯例）**：`native/` 拆成
  `core/`（bridge_core.c/.h + bridge_js.h，跨平台共享层，桩自检就编它）、
  `platforms/linux/`（bridge_linux.c）、`platforms/windows/`（bridge_win.c）、
  `platforms/harmonyos/`（**只有契约 README 的 scaffold**：共同契约「必须实现或明确拒绝」、
  能力位如实报 0、禁假实现、验收出口——为鸿蒙 ArkWeb 预留）；`native/tests/` 桩自检不动。
  构建脚本留在 `native/` 根、源路径改指子目录，**产物路径不变**（`cjpm.toml` 的 `-Lnative`
  与打包脚本零改动）。全部复跑：桩自检 151/151、单测 189/189、check-static 全绿。
  新增 `docs/需求追踪.md`：按能力组织的矩阵（CORE/SEC/PLG/PLT/ENG 五组，ID / Owner 文件 /
  验收场景 / 五级状态 / 证据），状态词 planned → validation-only → experimental →
  implemented → supported，与 `进度记录.md`（时间线）、RFC-003（分期）互补；行为变更同轮更新。
- **插件物理隔离：`src/plugins/` 子包（重构）**：9 个 `plugin_*.cj` 与串口 FFI 声明从 `src/` 顶层
  迁入独立子包 `package cjTauri.plugins`，`src/` 顶层只留框架核心（16 个文件）。依赖方向不变：
  插件 import 核心（父包 `public` 符号），核心零引用插件——`check-static.sh` 的边界断言随之从
  「按 `plugin_` 前缀文件名 grep」升级为「按包路径查」，并新增「`src/` 顶层不得回流插件实现文件」
  一项。随迁要点：`clipboard_bridge.cj` 的 FFI 声明是**核心宿主消费**的，留在核心包
  （判定标准「谁调用谁包内」，`foreign func` 不能跨包）；单测/示例直接构造的命令 handler
  （`MenuCommands` / `ClipboardCommands` / `NotificationCommands`）与辅助符号改为 `public`（跨包
  不再同包可见）。全部门禁复跑通过：单测 189/189、桩自检 151/151、框架/CLI/示例构建零警告、
  `examples/plugin-fs` 实机（scope 放行/拒绝对照）不回归。
- **官方 `clipboard` 插件（系统剪贴板，RFC-003 第 3 期）**：`clipboard:write` / `clipboard:read`
  两条命令，命名权限集 `clipboard:readonly`（read）与 `clipboard:default`（write + read）。
  读空剪贴板 / 非文本回 `null`（合法结果，不是失败）。平台差异落在 C 桥
  （`cj_bridge_clipboard_*`：core 校验 + 平台层按调用线程分流），仓颉侧共享层只做参数校验；
  文本超 8 MiB 在 core 即拒并打 stderr。Linux 实机验证：应用存活时外部回读的 token 与写入一致。
- **官方 `notification` 插件（系统通知，RFC-003 第 3 期）**：`notification:notify`（`{title, body?}`），
  命名权限集 `notification:default`。**发后即忘**（投 UI 线程，不占等待槽）；Linux 走 freedesktop
  通知规范（会话总线 GDBus），Windows 侧桩返回平台未实现。没有通知服务时命令**失败并给可读原因**
  （发不出去要知道，不静默）；能力位 `CJ_CAP_NOTIFICATION` 如实上报。Linux 实机验证：会话总线上的
  通知桩实收 NOTIFY。
- **`fs` 插件路径 scope（RFC-003 第 4 期，安全补齐）**：capability 清单新增 `scopes` 字段
  （`"scopes": { "fs": { "allow": [...], "deny": [...] } }`）——命令放行之后**路径再收一层白名单**，
  堵住「页面能读任意可读文件」的缺口。判定**先 deny 后 allow**（deny 命中即拒，allow 必须显式命中，
  空 allow = 该插件路径全拒）；模式支持 `*` / `**` / `?` 与 `$HOME` `$TEMP` `$CWD`（变量认不出即原样保留、
  随之匹配不上＝拒）；匹配前规范化（存在的路径走 canonicalize 顺带解析软链接，不存在的路径词法折叠
  `.` 与 `..`），`../../` 绕不过。**没写 scope 的旧清单一律维持原行为**（全量放行，只在启动时打一行
  stderr 提示）；越界被拒时 stderr 有 `[cj-tauri] scope denied (fs): <原文> -> <规范化路径>`。
  `examples/plugin-fs` 加上 scope 对照组（白名单内读回、越界与 `..` 绕行均被拒，Xvfb 实机取证）。
  单元测试 175 → **189**（14 条 scope 用例：模式解析 / deny 优先 / 变量展开 / 规范化 / 未授权对照组）。
- **官方 `store` 插件（持久化键值，RFC-003 第 2 期，对标 tauri-plugin-store）**：`store:get` /
  `store:set` / `store:delete` / `store:keys` / `store:clear` 五条命令，值是**任意 JSON**；
  命名权限集 `store:readonly`（get + keys）与 `store:default`。纯仓颉零 C 桥：内存 JsonObject +
  Mutex + **原子写**（先写 `path.tmp` 再 `rename(overwrite:true)`，中途被杀不留半个 JSON；rename
  失败回落直写并打 stderr）；损坏文件不是致命错误（一行 stderr + 从空开始，下次写覆盖）。
  落盘默认 `<工作目录>/store.json`（`StorePlugin(path)` 可自定义）。`examples/music` 已从手搓
  JSON 存储迁到它（`fav:get` / `fav:set` 对外契约与收藏文件形状不变，老文件无缝迁移），Linux
  实机两轮回归：全新启动自检收藏落盘 + 原子写无 tmp 残留 + 重启后数据从盘上回来。
  顺带修掉一个跨平台编译坑：`host_webkit.cj` 的 `std.collection.*` import 在 Linux 侧必需
  （Windows 侧看是 unused——按单平台 warning 清理跨平台文件的 import 会把另一平台编炸）。
  单元测试 143 → **155**（12 条 store 用例：读写删 / keys 排序 / 原子写残留 / 损坏回落 /
  8 worker 并发写 / 命令校验 / 权限集闸门）。
- **示例 `examples/modbus-poll`（Modbus Poll 调试工具，Modbus TCP）**：多面板并行监控（对标原版
  MDI 多窗口、一屏任意多组）、FC 01/02/03/04 读 + 05/06/15/16 写、双击写入（线圈取反 / 寄存器
  改值 / Float32-Int16 按显示类型对写）+ 写前模态确认（旧值回显）、FC16 批量写（留空保持、连续段
  自动合并）、报文监视（Tx/Rx 十六进制环形缓冲，`mb:trace` 取走即清）、Modbus TCP 连接池（按
  host:port 复用 + 互斥串行 + 自动重连）、内置从站模拟器（`CJ_MB_SLAVE=1`，自检读写闭环）。
  另加 **Modbus RTU 串口**传输层（复用框架 serial 桥 + CRC16 帧层，与 TCP 同一个 `MbTransport`
  契约；串口链路待真实设备验证，CRC 已用标准向量 `123456789 → 0x4B37` 在自检中断言）。
  已对真实 Modbus Slave（modbustools）实测：FC03/FC06/FC16 原始帧互通 + GUI 轮询 15+ 次零失败。
  后续增强：**数据记录**（每面板记录开关 + CSV 导出）、**Float32 字节序选项**（ABCD/CDAB/BADC/DCBA，
  读写同一张表）、**报文监视增强**（相对时间戳 + 过滤框 + 导出文本）、**点位表导入导出**
  （面板定义 + 别名 + 连接参数整份 JSON，`mb:export` / `mb:import` 落 `logs/`，文件名白名单）。

- **AtomCode skills（`skills/`，已 marketplace 化）**：把框架的开发工作流、实机取证、踩坑速查与
  回贡献流程沉淀成 AI 可复用的指令，`atomcode plugin install cj-tauri-skills@cj-tauri-skills` 一行装上
  （或 `bash scripts/install-skills.sh` 只装 skills）。四个 skill：`cj-tauri-app-dev`（起工程 /
  命令与插件三处联动 / 前端 / 门禁）、`cj-tauri-verify`（桥 stderr 取证 / Xvfb / pty 虚拟设备 /
  断言截图）、`cj-tauri-troubleshoot`（实测坑速查表）、`cj-tauri-contribute`（问题→issue、修法→PR 的
  自进化入口）。使用指南见 `docs/cj-tauri-skills-使用指南.md`。
- **skills 补充环境检测 skill `cj-tauri-env`**：一键检测 cjc / cjpm / stdx / gcc（Linux）/
  llvm-mingw（Windows）/ WebKitGTK / WebView2，缺哪样补哪样——安装指引含仓颉 SDK 与环境搭建教程
  （cangjie-lang.cn）、stdx 的 `CANGJIE_STDX` 指向要求、Linux gcc + WebKitGTK 一行 apt、
  Windows 推荐 llvm-mingw（免安装替代 MSVC）、WebView2 Runtime/SDK 规则，以及仓颉资料速查表
  （官网 / API / 中心仓 / 主库与三方库组织 / 社区优质项目 / 官方示例）与
  CangjieSkills 语言技能包安装；`cj-tauri-app-dev` 加「步骤 0：环境先过关」，
  `cj-tauri-troubleshoot` 速查表补环境类三条（127 无输出 / stdx 指错 / 不必上 MSVC）。
- **skills 跨生态兼容（Claude Code）**：新增 `.claude-plugin/marketplace.json`（AtomCode 的 plugin
  协议与 CC 兼容，同一仓两边都能装）；skills README 与使用指南补「其他市场」小节——
  skills CLI（`npx skills add yangyongzhen/cj-tauri`，vercel-labs/skills 跨 75+ agent）、
  自动索引公开仓库的目录站（Skill Navigator / agentskills.cc）、仓颉官方 SIG 技能包
  CangjieSkills（可 PR 贡献）。
- **文档：新增《`docs/RFC-插件路线图.md`》（RFC-003）**：对照 Tauri 2 官方插件清单与仓内实况逐项盘点
  常用插件缺口（P0：Store / Clipboard / Notifications；P1：Global Shortcut / Window State /
  Single Instance / Logging / fs scope 补齐；P2：HTTP 白名单代理 / OS Information；P3：SQL /
  Updater 等重型件），定五期落地顺序（先收口托盘 + 拖放能力位，Store 纯仓颉最快见效）与每期判据，
  架构红线（平台差异只进 `@When` 与 C 桥、回调按句柄路由、零第三方依赖优先）逐期适用。
- **官方 `serial` 插件（串口读写）**：`serial:list` / `serial:open` / `serial:read` / `serial:write` /
  `serial:close` 五条命令，前端 `window.__CJ_TAURI__.serial.*`（插件 shim 经宿主**预执行脚本**通道注入，页面第一行可读）。
  `list` 枚举本机串口设备节点（`/dev` 顶层按设备类前缀收 + `/dev/serial/by-{id,path}/` 整目录收录，
  伪终端不算「本机串口」不进列表），返回 `{ ports: ["…"] }`、按字典序——页面拿它填「端口」下拉；
  归入 `serial:readonly` 集（枚举是只读操作，且连接前的「选端口」离不开它）。
  设备参数在**打开时定稿**：`open { path, baud, dataBits?, parity?, stopBits? }` →
  `{ handle, path, baud, dataBits, parity, stopBits }`；之后 `read { handle, maxBytes?, timeoutMs? }` →
  `{ count, hex, text? }`（**超时无数据返回 `count=0`，不算错误**；不是合法 UTF-8 的二进制帧只给 `hex`）、
  `write { handle, data, encoding?, timeoutMs? }` → `{ written, bytes }`（`encoding` 收 `utf8` / `hex`，
  单次上限 4096 字节）、`close { handle }` → `true`。
  命名权限集 `serial:readonly`（`open` + `read` + `close`）与 `serial:default`（另含 `write`）——
  **只想读设备的应用引用前者即可，写能力不会被顺带打开**。
  分层按 `AGENTS.md` §2：C 桥新增五个同名导出 `cj_bridge_serial_{open,read,write,close,last_error}`
  （桥产物现 27 个 `cj_bridge_*`），**路径白名单 + 参数校验在 core 侧**（页面可控字符串的唯一闸门：
  只放行设备节点类前缀 `/dev/tty*` · `/dev/pts/*` · `/dev/serial/by-{id,path}/` · `COM<N>`，
  含 `..` 一律拒；baud / 数据位 / 校验 / 停止位越界即拒并给一句可读人话），
  平台侧只放句柄表与 termios，故两平台导出名一致、上层没有平台分叉。
  **零第三方依赖**：不链 `libserialport`，Linux 用 POSIX termios 自己开（`examples/plugin-serial`
  与桥都不新增外部库，MIT 口径不变）；错误串放**线程局部**缓冲——命令各自跑在 worker 线程上，
  静态单槽会被并发调用互相覆盖（`AGENTS.md` §4 那条坑的同类）。
  Linux 实机（2026-10-06，WebKitGTK + Xvfb）：新示例 `examples/plugin-serial`（`bash run.sh`）用
  python3 `pty` 造虚拟串口对，`serial:open => handle=1` → `serial:write => written=13/13` →
  对端回 `PONG:cj-tauri-ping` → `serial:read => count=18 hex=504f…6e67 text="PONG:cj-tauri-ping"` →
  `serial:close => true`，三轮 `exit=0`、断言全绿；**写方向的证据在应用进程之外**
  （对端日志 `[peer] rx=13 bytes, replied 18 bytes` + 落盘文件内容），不是应用自己说「我写了」。
  单元测试 132 → **143**（新增 11 条串口用例），C 桥桩自检 **136/136**。
- **`serial` 插件的 Windows 平台实现（实机跑通）**：`native/bridge_win.c` 的四个原语从同名桩换成真实现——
  `CreateFileW("\\\\.\\COMx", …, FILE_FLAG_OVERLAPPED)` 独占打开 + `GetCommState`/`SetCommState` 配 DCB
  （流控一律不替应用开，与 Linux 侧同一条铁律）+ 超时全部归零、等待交给 `OVERLAPPED` 的
  `WaitForSingleObject` 按剩余预算控制（**不用 `SetCommTimeouts` 的阻塞语义**：总超时只对「等到第一个字节」
  可控，预算耗尽时 `CancelIo` 撤销未完成请求再交回），读写返回码口径与 Linux 逐字一致，上层零平台分支。
  同批新增第六个导出 `cj_bridge_serial_list`：Windows 走 `QueryDosDeviceW` 扫全系统设备名收「`COM` + 全数字」
  （虚拟口也在其中，比翻注册表稳），Linux 返回 `-4` 未实现、`serial:list` 回落仓颉侧的 `/dev` 扫描
  （pty 与 `by-id` 仍能收）。桥产物现 **28 个 `cj_bridge_*`**；C 桥桩自检 136 → **141** 项。
  Windows 实机（2026-10-10，COM1↔COM2 虚拟对，`examples/serial-assistant/run.bat`）**rc=0、8/8 断言全绿**：
  端口枚举 `port enum: 2 item(s)`（C 桥路径生效）→ `serial win32: path=COM1 baud=115200 data=8 parity=0 stop=1`
  → 页面自检 open / write 13/13 / read 18 字节 / close 4/4 → **写方向的证据仍在应用进程之外**
  （对端 `[peer] rx 13 bytes: cj-tauri-ping`）。
- **串口调试助手补 Windows 一键探针 `run.bat` 与手测模式**：新增 `examples/serial-assistant/run.bat`
  （设 PATH → `cjpm build` → 先起 `serial-peer-win.ps1`（PowerShell 串口对端）→ 带探针变量跑应用 →
  8 条断言）与 `serial-peer-win.ps1`（收到什么回 `PONG:<原文>` 并落盘 rx 文件，即「字节真的上过线」的外部凭证）；
  `run.bat manual` 则不带探针、不起对端，开着窗口供人眼手测（日志照旧落 `%TEMP%\cj-serial-assistant.log`）。
  该示例的 Windows `link-option` 补齐 `-L../../native -lcjtbridge --subsystem=windows` 与 stdx 动态库路径
  （此前只有 Linux 段，Windows 下 `cjpm build` 根本链不上桥）。
  **修一处展示轮的 bug**：探针自己连的串口没接 `readLoop()`（接收循环只在用户点「连接」的 `connect()` 里起），
  于是 `CJ_SERIAL_PROBE_QUIT=0` 的展示轮窗口显示「已连接」、对端推帧却一个字节都收不到；现在展示轮同样接上
  接收循环（实机对照：修复前 `[rx]` 无条目，修复后对端三帧全部落到 `[rx]` 行）。
- **串口调试助手示例 `examples/serial-assistant`**：`cj-tauri create` 脚手架（app 模板）+ 官方 `serial`
  插件拼出的**业务向小工具**——参数面板（**端口下拉自动枚举** + ↻ 刷新，/ 波特率 / 数据位 / 校验 / 停止位）、
  收发日志（TX/RX 分色、时间戳、字节数、HEX 显示开关、按方向过滤）、TX/RX/错误计数、连接态徽标与计时；
  发送区支持 HEX 与「追加 CRLF」、**定时发送**（间隔 ≥50ms 可调，框空跳拍，断开自动停）、Enter 直发。
  页面独立在 `ui/index.html`（与 movie 同一套做法，避开三引号字符串的两个坑）；探针模式照 plugin-serial
  （`CJ_SERIAL_PROBE_PATH` 注入配置，页面自动跑一轮 open→write→read 自检并经 `report` 回传 stderr，
  对端端口会补进下拉），`bash run.sh` 自带 pty 虚拟对端与断言。
  实测抓到两条坑（均已记 `AGENTS.md` §4）：**WebKitGTK 的 `<select>` 会被原生 combo 的浅色样式盖掉页面配色**
  （已用 `-webkit-appearance:none` 自绘修复）；**仓颉 `const` 只收编译期常量、`Array` 字面量不合法**
  （顶层可变量要用 `let`）。
  Linux 实机探针自检多轮全过（v3 起断言含「端口枚举」两条）；**如实记**：期间多轮进程在 `after run`
  **之后**以 134 收尾——同日对照跑一行未动的 `examples/plugin-serial` 也崩，属既有 Linux 退出期偶发
  频率升高，与示例代码无关（不判因，见进度记录 §3.2.17）。

### Changed

- **对外口径统一为「仓颉语言的 Tauri」**：原先散在 `README.md` / 官网 / npm 描述 / skills / 示例 README
  与 6 篇发表稿里的**「类 Tauri」「Tauri-like」「对标 Tauri」「照搬 / 复刻 / 模仿 Tauri」**等措辞，全部改为
  「仓颉语言的 Tauri」「Tauri 那套架构在仓颉里独立实现」「与 Tauri 对应 / 同构」——避免被读成对 Tauri 的
  简单翻版。**源码注释里的「对标 tauri …」保持不变**：它解释的是「这一处代码与 tauri 的哪个 API 对应」，
  是给贡献者的对照说明，不涉及来源主张。
- **`npm/package.json` 的 `description` 同步**（下次 `npm publish` 生效）；官网 7 处、`README.md` 3 处、
  `npm/README.md`、`skills/` 三处、`examples/music/README.md`、`AGENTS.md` §0 定位句，以及
  `docs/` 下 6 篇发表稿的同类措辞一并对齐。
  注：已发布到 CSDN 的那几篇线上正文标题仍是旧措辞，需人工同步（本仓库只改本地稿）。

## [0.8.0] - 2026-10-08

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
- **示例可打成单文件包（`scripts/pack-win-single.sh`）**：把示例编译成**一个 exe**——仓颉运行时 / std / stdx
  静态链接（`--static --static-std --static-libs` + stdx 的 static 包）、C 桥编成静态归档 `libcjtbridge.a`
  直接链进去、`WebView2Loader.dll` 的字节编进桥（首次运行释放到 `%TEMP%\cj-tauri-loader\` 再加载）、
  页面 / three.js / 能力清单 base64 内嵌（打包脚本生成 `src/packed_assets.cj`，仓库里那份是空存根，
  正常构建照旧读盘）。脚本末尾**自检导入表**：还依赖 `libcangjie-runtime.dll` / `libcjtbridge.dll` /
  `WebView2Loader.dll` / `libboundscheck.dll` 就直接失败。`examples/typing-poem` 实测（2026-10-07，Windows）：
  28.8 MB → strip 后 **5.5 MB**，导入表只剩 msvcrt / KERNEL32 / SHELL32 / dbghelp / comdlg32 / USER32 /
  ole32 / WS2_32；实机自检 `57 passed, 0 failed`，窗口创建（`set window: … size=1180x780`）、
  `ExecuteScript -> hr=0x00000000`，内嵌资源字节数与源文件**逐字节吻合**（页面 107962 / three.js 669884）。
  用法与两条坑见 `docs/使用文档.md` §11、`AGENTS.md` §4。仓库里同时跟一份打好的
  `examples/typing-poem/dist-single/typing-poem.exe`（`work/` 临时构建副本与 WebView2 用户数据不入库），
  不装 SDK 也能直接拿到。

- **音乐播放器示例 `examples/music`（深色三栏播放器 + 两档无人值守自检）**：网易热歌榜 / 搜歌 / 点播 /
  同步歌词滚动 / 收藏与最近播放 / 把收藏当歌单分享到后台（教学接口 `http://49.235.52.102:8000`，
  可用 `CJ_MUSIC_API` 覆盖）。**数据与封面全部经 `invoke` 由仓颉侧取回，页面一次 `fetch` 都不发**：
  封面走宿主侧带 `Referer` 的代理（后台封面是百度图片代理，不带 `Referer` 的失败形状是
  「**HTTP 200 + 0 字节**」，页面侧无解），并对网易图床做缩略——同一张封面 **709 326 → 4 194 字节**
  （列表按 200、主视觉按 500，取不到回退原图）；歌词在仓颉侧解成「毫秒 → 行」数组；收藏落本机
  `music-library.local.json`。界面放在独立的 `ui/index.html`（3287 行），顺带绕开三引号字符串里
  JS 反斜杠与 `${}` 插值的全部坑。自检分两档、**读写在文件里分家**：`run.bat selfcheck` 只读后台 +
  只写本机收藏（①～⑩ 十项），`run.bat selfcheck2` 追加「分享歌单到后台 + **写后读回**」两项。
  Windows 实机（2026-10-08）：两档全绿（`10 passed / 0 failed` 与 `12 passed / 0 failed`），
  `ExecuteScript -> hr=0x00000000`；封面那项的判据是「真的在解码播放」
  （`paused=false currentTime=0.44s duration=180.2s readyState=4`）。另修一处**只有抓图人眼才看得出**
  的三栏布局缺陷（标题被挤成两行）。用法与坑见 `examples/music/README.md`——该 README 还带
  **cj-tauri 三件套速览**与**「用 `cj-tauri create` 复刻本项目」的完整步骤**
  （CLI 准备 / `create` 的真实输出与 6 个生成物 / `dev`·`build`·`run`·`info` /
  「空模板 → 本项目改了哪几处」对照表 / 新增能力的「三处联动」）。
- **`examples/music` 界面重做与首页改版（2026-10-08 第二轮，改动只在前端 `ui/index.html`，仓颉侧与
  能力清单一行未动）**：① 主角位大图换成**榜单 Top 5 轮播**——拿同一张封面做模糊底衬 + 方形裁切
  （`object-fit: cover`），5 秒自动换页、悬停暂停、`prefers-reduced-motion` 下退化为手动、圆点与左右箭头
  可点、点封面即播；② 首页新增**横向滚动的「后台歌单」行**（卡片一行横滑，`music:menus` 懒加载，右侧
  「查看全部 ›」进完整列表）；③ 删掉页面里全部**调试信息**（左下「后台地址 / 榜单 kind / 收藏文件 / 自检开关」
  那一栏与右上「后台正常 · 热门 30 首」角标，配套的 `hero-*` / `svc-*` / `side-meta` DOM 与
  `setService` / `syncHeroFav` 一并清掉）；④ 修掉封面**被拉伸**的根因——容器里 `fillCover` 插进去的 `<img>`
  **没有类别也没有内联尺寸**，只给容器写 `object-fit` 是写在 `div` 上的死规则，现在每个容器各配一条 `img` 规则。
  判据：等级 1 / 等级 2 自检仍 `10 passed / 0 failed` 与 `12 passed / 0 failed`（同一份 `ui/index.html`），
  `ui/index.html` 2891 → **3287 行**，两张文档截图按新界面重抓（`docs/images/example-music*.png`，抓图人眼验收）。
- **`examples/music` 界面第三轮打磨：主题色 / 播放条 / 空错态（2026-10-08 同日，改动只在前端
  `examples/music/ui/index.html`，仓颉侧与能力清单一行未动）**：① **修掉宽屏下轮播被拉高**——`.banner`
  此前只有 `aspect-ratio: 16/6`、没有高度上限，窗口拉宽 / 全屏时高度跟着宽度涨（整屏都是轮播），现在**封顶 268px**
  并给宽度一个确定值（`width: 100%`，见本条末尾补修），只变宽不变高；② 歌曲列表行改成**五列网格**（排名 / 缩略图 / 曲名歌手 / 时长 / 操作），悬停出行内 ▶，
  **时长只在听过之后才显示**——后台 song 对象只有 `sid`/`song`/`sing`/`url`/`cover`，没有 duration，页面不编造
  （骨架屏的列数与新网格同步，修掉按旧列数渲染的回归）；③ 封面卡片悬停放大 + 阴影加深；④ 空态 / 无结果 / 错态
  统一成「**光晕圆盘插画 + 标题说明 + 重新加载按钮**」，按钮按当前视图重拉（搜索页没输关键词时不给按钮）；
  ⑤ 播放中右侧唱片外圈加**呼吸光环**（`.now .art.spin::before` + `@keyframes halo`）；⑥ 播放条精修
  （主播放键双层发光、进度条悬停 / 按住加粗 + 把手浮现、音量条改白→主题色渐变）；⑦ 强调色改成 `--accent` /
  `--accent-rgb` 双形态变量（29 处硬编码 `rgba()` 变量化），顶栏加 🎨 按钮轮换 **4 套主题色**（默认蓝紫 / 日落 /
  森林 / 深海，选择落本机存储）；⑧ 补 `prefers-reduced-motion` 降级：动画时长压到最短、唱片停转、
  歌词平滑滚动关闭。宽屏护栏那项核实**无需改动**（`.app` 既有 `max-width: 1560px`，中间栏 ≤ 1028px）。
  判据：隔离副本跑 `selfcheck` 仍 **10 passed / 0 failed**（第 12 项按设计 SKIP，未写后台）、内联脚本
  `node --check` 通过、探针实机人眼验收 3 套配色（蓝紫 / 日落 / 深海，走真实点击链路）与播放态
  （唱片光环、歌词高亮、真实时长 `00:29 / 03:00`），`ui/index.html` 3287 → **3657 行**，两张文档截图
  按新界面重抓并人眼验收（`docs/images/example-music*.png`）。
  **末尾补修（同日，用户实机反馈「点最大化后界面没有拉伸」）**：查出并修掉一处**真缺陷**——① 的护栏写法有副作用：
  `.banner` 宽度是 `auto` 时，为同时满足 `aspect-ratio: 16/6` 与 `max-height`，浏览器会**反过来把宽度缩到
  268×16/6 ≈ 714px**，于是大屏下横幅右侧空出一条豁口、与下面的列表区对不齐（实测 1920 最大化：中栏 1028px，横幅
  只有 714px），与这条护栏自己注释里写的「宽度过了 ~715px 之后高度不再跟着涨」**正好相反**；补一行
  `width: 100%`（宽度成确定值）才是想要的行为：**宽度铺满 + 高度封顶 268px**。
  ⚠️ 同时记一条**不是问题**的观察，免得下轮误改：最大化后整体不铺满窗口（1920 下两侧各留 ~184px）是**有意护栏**
  （`.app { max-width: 1560px; margin: 0 auto }`）。页面确实按视口重排：同一实例 1280×820 → 1936×1048 后中栏
  628 → 1028px、横滑歌单 4 → 6 张、右栏 320 不变；宿主侧 `native/bridge_win.c` 的 `WM_SIZE → GetClientRect +
  put_Bounds` 也确实重设了 WebView2 边界，留白被 `body` 背景光晕填满、不是死黑。判据：`PrintWindow`
  （`PW_RENDERFULLCONTENT`）抓最大化窗口（`IsZoomed=True`，1280×820 → 1936×1048），横幅右缘与下方列表区对齐
  （修前 ≈1140 / 修后 ≈1400 @ 中栏 1028px），稳定态帧里标题与按钮均为实心；`ui/index.html` 3652 → **3657 行**。
- **音乐播放器示例接上单文件打包（`bash scripts/pack-win-single.sh examples/music`）**：`examples/music` 新增
  `src/packed_assets.cj`（空存根）与 `src/packed_resources.cj`（`decodeBase64` / `splitBy` / `textOrFile`），
  `src/main.cj` 的页面读入与能力清单挂载改成**内嵌优先、否则读盘**——仓库内构建行为一行不变（存根为空时
  仍按 `ui/index.html` 读盘，能力清单仍由 `run()` 自动扫 `capabilities/`）。产物
  `examples/music/dist-single/music.exe`：**9 956 864 字节**（sha256 `be8d954ab40a13b1…3bb52c9`），页面
  （126 350 字节）与 1 份能力清单都编在二进制里，导入表只剩系统 DLL（`KERNEL32 / WS2_32 / SHELL32 / USER32 /
  ole32 / CRYPT32 / comdlg32 / dbghelp / msvcrt`），运行时 / stdx / OpenSSL 一个都不随行；比打字游戏那份
  （5.5 MB）大，是因为封面走 https，静态链接把 `stdx.net.tls` 与 OpenSSL 链了进来。打包脚本同步泛化：
  **内嵌哪几个常量以示例存根的声明为准**（typing-poem 3 个、music 2 个，没有 three.js 就不生成那条），
  包名改从 `cjpm.toml` 的 `package.name` 取，并补上 `-lcrypt32`（见 `Fixed`）。实机取证（2026-10-08，
  任意空目录、无 `ui/` 无 `capabilities/`、不装 SDK）：`CJ_MUSIC_SELFCHECK=1` → `[自检] 汇总：10 passed /
  0 failed` 且退出码 0，`=2` → **12 passed / 0 failed**；stderr 含
  `能力清单来自内嵌资源（1 份，共 408 字节 base64）`、`前端页面已载入：ui/index.html（126350 字节）`、
  `set window: title=仓颉爱音乐 · cj-tauri size=1280x820`。用法见 `examples/music/README.md` §8。

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

- **单文件打包链接期补 `-lcrypt32`（示例第一次用上 https 才暴露）**：`scripts/pack-win-single.sh` 的
  `link-option` 原来只链 `ole32 / oleaut32 / uuid / user32 / gdi32 / advapi32 / comdlg32`，打
  `examples/music` 时在链接期炸出一串 `undefined symbol: __declspec(dllimport) CertOpenSystemStoreA`
  （连同 `CertEnumCertificatesInStore` / `CertCloseStore`）——它用 `stdx.net.tls`，静态链接下读根证书要走
  Windows 证书库（`crypt32.dll`）。补上 `-lcrypt32` 后链接通过，exe 导入表里出现 `CRYPT32.dll`；
  不碰 TLS 的示例（typing-poem）多链一个系统库无副作用。判据仍是**导入表里只该有系统 DLL**。

- **单文件产物改成 GUI 子系统：双击不再弹 DOS 黑窗口**（`scripts/pack-win-single.sh`，交付后的第一条实机反馈）：
  脚本生成的 `cjpm.toml` 里 `link-option` 补 `--subsystem=windows`，产物 PE 头从 console(3) 变 GUI(2)——
  此前双击 `music.exe`，Windows 按 console 程序给它分配一个控制台，黑窗口就跟着应用窗口一起出来。写法必须是
  **链接器的说法**：cjc 的 `--link-options` 直通 ld.lld（不是交给 gcc 驱动），所以 `-mwindows` 会被当面拒
  （`lld: error: unknown parameter: -mwindows`），取值也只有 GNU 那套（写 `gui` 报
  `ld.lld: error: unknown subsystem: gui`）。子系统只管「分不分配控制台」，**日志链路不变**：从终端带重定向
  启动时 stderr 照旧落到文件，无人值守自检与实机取证一行没改；代价是双击时看不到 stderr。脚本末尾另加
  **事后复核**（`objdump -p` 的 `Subsystem` 必须是 `00000002`，否则 `die`），回归成 console 不靠人眼发现。
  `examples/music` 重打实测：`dist-single/music.exe` 9 956 864 字节（sha256 `7926f25bfcb5d5ff…f356ea92`）、
  `Subsystem 00000002 (Windows GUI)`、导入表仍只有系统 DLL、重定向下自检 **10 passed / 0 failed** 与
  **12 passed / 0 failed**（均 `exit=0`）；再用 ShellExecuteEx（等同双击、不继承任何句柄）起进程，窗口正常
  出现（标题 `仓颉爱音乐 · cj-tauri`）、进程存活、收尾无残留。
  同一开关也加进了 **13 个示例的 mingw `link-option`**（逐文件统一替换，Linux 段那串 `-lwebkit2gtk-4.1`
  不动；另有 2 处命中在打包器临时生成的 `dist-single/work/app/cjpm.toml`，不入库），于是
  `scripts/pack-win.sh` 的目录式便携包同样是 GUI 产物；
  `examples/typing-poem/dist-single/typing-poem.exe` 一并重打（5 766 656 字节、`Subsystem 00000002`、
  内建自检 `57 passed, 0 failed`、双击路径窗口正常）。补充实测：GUI 产物**不显式重定向也能抓到 stderr**
  （未重定向跑 `CJ_MUSIC_SELFCHECK=1 music.exe`，228 行日志照落），各示例 `run.bat` 的取证流程无需改动；
  `examples/music` 与 `examples/typing-poem` 仓库内 `cjpm build` 均 `exit=0`、产物 `Subsystem 00000002`。

- **脚手架生成的工程也带 `--subsystem=windows`（新 `create` 出来的应用双击同样不弹黑窗）**：`cli/src/scaffold.cj` 的
  `buildTargetSection` 在 **Windows 分支**（`hostIsWindows()`）补上同一个开关，Linux 分支一行未动——
  此前只有仓库内示例拿到了它，用户 `cj-tauri create` 出来的新工程仍旧是 console 产物。重建 CLI 后实测：
  新建工程 `cjpm.toml` 仍是 22 行（开关写在既有那行里）、带 `--subsystem=windows`、不含 `-lwebkit2gtk*`，
  其余生成物行数 88 / 118 / 80 / 7 / 13 不变；生成工程 `cjpm build` `exit=0`、产物
  `Subsystem 00000002 (Windows GUI)`。两处踩坑已记 `AGENTS.md` §4：**Cangjie 的 `#` 不是注释符**
  （是 raw string 前缀，行内 `#` 注释会让 `cjpm build` 报 `expected '#' or '"' in raw string, found ' '`）；
  **`CANGJIE_STDX` 要指 `…/dynamic/stdx`**（指成包根时 `create` 能成功，但生成工程 `cjpm build` 报
  `imports package 'stdx.encoding.json' … dependency info is missing`）。

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
