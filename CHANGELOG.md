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

## [2.1.0] - 2026-10-25

### Added

- **附庸窗（owned window）：`WebViewHost.setOwnerWindow(label)` + C 桥 `cj_bridge_set_owner_window`**：
  把一扇窗挂到另一扇窗下——Windows 落 `GWLP_HWNDPARENT` 并补 `WS_EX_TOOLWINDOW`，Linux 落
  `gtk_window_set_transient_for` + `skip_taskbar_hint`/`skip_pager_hint`，于是这扇窗**不再单独占
  任务栏与 Alt-Tab 一格**（Windows 实机读数：`WS_EX_TOOLWINDOW` 置位，且 `GW_OWNER` 回读等于主窗句柄，
  见 `examples/ai-chat/docs/evidence-webtab-owner-windows.md`）；最小化/隐藏时的联动交给系统对 owned window
  的既有处理，**Windows 侧未单独取证**——想依赖它就得先补一次同调用内的 A/B。**在 `load()` 之前调**（与 `setWindowConfig` 同段）：
  属主状态记进宿主，平台建窗装配期一次挂好，任务栏从头到尾只一格；`load()` 之后调也支持
  （投 UI 线程），代价是按钮先出现再消失。属主尚未建窗 / 未登记时只打一行 stderr 并跳过——
  它是外观修饰，不该拦住开窗。两平台同名同签名（§2），鸿蒙走接口默认实现（无系统任务栏语义）。
  事后复核打在同一行：Windows `GetWindow(hwnd,GW_OWNER)=…`、Linux `gtk_window_get_transient_for`，
  免得只有「我调过了」而没有凭证。**ai-chat 的网页版已改用同窗内嵌视图**（见下条），这条能力保留为
  公开 API——「独立窗口但不占任务栏」的场景还要它。

- **内嵌视图（同窗多视图）：`WebViewHost.createEmbeddedView` 等五个成员 + C 桥 `cj_bridge_view_*`**：
  在**已存在的宿主窗口**的指定矩形里再放一个 WebView——`createEmbeddedView(label, url, bounds)` 返回句柄，
  之后 `setEmbeddedViewVisible` / `setEmbeddedViewBounds` / `navigateEmbeddedView` / `destroyEmbeddedView`
  各按句柄操作。这是「一个窗口里放多个页面、像浏览器标签那样切」的底座（此前一个 `WebViewHost` 只能
  独占一扇系统窗口，`PageSource.Url` 就必须开新窗）。Windows 落法是每个视图独占一个载体子窗口
  （`CoreWebView2Controller` 与 HWND 1:1），共用同一个 `environment` / 用户数据目录，所以登录态在视图之间
  是通的；Linux 落法是 `GtkOverlay` 打底 + `GtkFixed` 覆盖层里多个 `WebKitWebView`。**矩形用 client 坐标
  （DIP）**，由页面按自己的布局上报，主窗 resize / 侧栏折叠 / DPI 变化都要重报（页面侧节流 80ms）。
  三条实机踩过的坑：① 内嵌视图与主页面视图在 Windows 上是同一父窗口的子窗口，**先建的反被压在下面**——
  必须显式把当前视图置顶，否则日志明明有 `visible=1`、界面上什么都看不见；② **必须在 worker 线程建**
  （同步命令 / UI 线程 / 事件回调里建 WebView2 会死锁，官方 known issue）；③ 视图操作要回到**宿主自己的
  UI 线程**，因此每个原语首参都是 `cj_host *`（非 UI 线程走 `PostMessage` 投递，与 `cj_plat_set_owner_window`
  同款）。桩平台补了同名桩，`native/tests/test_bridge_core.c` 覆盖（247/247 全过）。
  鸿蒙侧无 C 桥，走接口默认实现：**如实降级**，不假装支持。Linux 侧**未实机验证**。

- **ai-chat 网页版：同窗标签页（`webtab:list` / `webtab:show` / `webtab:hide` / `webtab:close` / `webtab:bounds`）**：
  侧栏「网页」tab 以卡片列出 DeepSeek / Kimi / 豆包 / 通义千问 / 智谱清言 / 腾讯元宝 / 文心一言 / ChatGPT
  八家网页版；点一张卡片 = 在**当前窗口的内容区**开一个标签页（上一条的内嵌视图），**不再是新窗口**——
  上一版的附庸窗形态已撤（用户实机反馈「弹一个新窗口体验不好」）。站点标签条住在**顶栏右侧**那一排
  （侧栏里不再有标签条，侧栏只留站点库卡片），切 tab 只是换谁露出来，不重载、不丢滚动位置；切到别的
  侧栏面板把视图藏起来、切回来还是那一页（不重新加载）。**同时存在的视图上限 4、LRU 淘汰**——每个视图
  背后一个渲染进程，八家全开约 300–600 MB；淘汰最久没用过的那个、**绝不淘汰本次要显示的**，标签条本身
  可以多于 4 枚，点回去时重建视图、登录态仍在（同一个用户数据目录）。网页视图下顶栏那几枚**会话态控件**
  （会话标题「新会话」/ 服务商 / 模式 / 主题 / 紧凑）自动隐藏——`body.web-live` 上做 `display:none`，
  回会话态即恢复。默认窗口从 1080×760 调到 **1320×860**（实机看过之后觉得偏小）。
  **不做 iframe 嵌入**：iframe 里是第三方上下文，WebView2 默认拦第三方 cookie 导致登录态存不住，
  站点跳 OAuth 时多自带 `X-Frame-Options` 直接白屏，弹窗也会被拦——表现是「页面看得见、登录过不去」。
  安全设计：命令**只认站点 id**（页面不能传 URL，否则等于把「加载任意网页」交给页面，可钓鱼 / 可探内网）；
  站点表只在 `src/webtab.cj` 的 `WEB_TAB_SITES` 维护，前端卡片由 `webtab:list` 驱动渲染，加一家不用改页面。
  面板不受模式显隐约束（纯前端服务入口，与 cjh 无关），聊天模式下同样常显；站点表在**页面启动时**就预热
  一次（`waitForBridge()` 之后），切到「网页」只是把面板 display 打开——不必等到那一刻才发 IPC 往返 +
  8 张卡片的首次合成（从托盘隐藏恢复后首次切换尤其明显：WebView2 还在唤醒，整段等待都压在用户眼皮底下）。
  `webtab:list` 3.5 秒仍未回则把占位文案换成「还没回来 + 怎么重试」——它是一张静态表，毫秒级就该回来，
  迟迟不回本身就说明桥没把结果投回来，这一点该如实说出来。
  取证：`examples/ai-chat/docs/evidence-webtab-embedded-windows.md`（Windows 实机截图 + 视图日志：
  建/切/隐/重建、bounds 跟随、上限 4 的 LRU 淘汰）；Linux 同契约实现但**未实机验证**，鸿蒙如实降级。

- **鸿蒙真机 E2E 入口 `scripts/e2e/test-ohos-capabilities.sh`**：驱动 `examples/ohos/ohos-capabilities`
  探针应用（页面自跑全量断言、经 `probeLog` 写设备 hilog tag `CjProbe`），脚本负责装机、
  流式抓 hilog、按断言名取命中次数，产出 `dist/e2e-evidence/windows-ohos-capabilities.json`。
  非 Windows 宿主默认跳过（真机取证依赖 Windows 侧 hdc + DevEco 签名），`CJ_TAURI_E2E_REQUIRE=windows`
  可让「错机」判失败；`check-static.sh` 第 9 项守它的入口形态（platform 守卫 + 驱动 fixture）。

- **多窗口 × sqlite/store 组合鸿蒙真机取证通过（47 PASS）**：第二窗（label `second`，
  业务侧 `addWindow` 内联页面）与主窗在同进程并行跑——两窗各自登记、各自落
  `cj-tauri-<label>.html`、页面自认 `me=second` 与原生报文 `window=` 恒等；
  第二窗的 `sqlite:exec/query`（自己的库 `second-window.db`）与 `store:set/get` 往返逐字回读；
  **跨窗定向投递成立**：第二窗 `invoke('probeEmitTo', {target:'main'})` → 业务侧
  `app.emitToWindow(...)` → 主窗 `crosstalk:probe` 监听收到（`PASS main got directed event
  payload=from-second`）——定向投递发给**对面**窗口才算测了路由。
  零框架代码改动。同轮修掉两处探针侧写法：`AppSpec.wire` **单槽**导致分次 `.wire()` 静默丢弃
  （`addWindow` 从未执行、第二窗白屏且无提示，落法是并进同一个 lambda）；内联页 SQL 字面量
  用了裸词 / 双引号 → SQLite 当标识符解析报 `no such column: cj`，改单引号。
  见 `examples/ohos/ohos-capabilities/docs/evidence-multiwindow-verify.md`。

- **`store` 插件鸿蒙真机取证通过（7 PASS + 跨重启持久化）**：set（嵌套 JSON）→get 逐字
  回读→keys→delete→get 缺省值→clear 全 PASS，persist-key 跨 force-stop 存活
  （store.json 落 `<cwd>/store.json`，鸿蒙 cwd = 应用 el2 files 目录）。零平台代码改动。
  同轮修掉 assets 同步段首版的**嵌套拷贝坑**：`cp -r src dst` 在 dst 已存在时会把 src
  拷成 `dst/ui/ui/`（页面静默变旧），先清再拷。见
  `examples/ohos/ohos-capabilities/docs/evidence-ws-log-sqlite-verify.md`。

- **`sqlite` 插件鸿蒙真机落地（amalgamation 随包编 so，ohos 桩退役）**：设备与 NDK 都没有
  sqlite 库（`stat -L` 五个候选路径 ENOENT、sysroot 无 aarch64 libsqlite），改走
  amalgamation（SQLite 本体 public domain，随包不产生附许可证义务）用 NDK clang 编
  `libsqlite3.so` 放 `entry/libs/arm64-v8a/` 随 hap 分发，entry link-option 加
  `-L/-lsqlite3` 生成 DT_NEEDED；`sqlite_ohos_stub.cj` 整文件删除，
  `plugin_sqlite.cj` / `sqlite_ffi.cj` 的 10 处 `@When[env != "ohos"]` 门禁摘除——
  **真实现三端共用**。真机（2026-10-25）exec 建库建表→query 回读逐字一致→info
  （`sqliteVersion 3.50.4`）→tables 全 PASS，越界 path 如实拒绝。两个形状：
  只读命令对不存在的库如实报错（先 exec 再查）；`query` 每格是 `{type,value}` 对象。
  见 `examples/ohos/ohos-capabilities/docs/evidence-ws-log-sqlite-verify.md`。

- **`ws` 插件鸿蒙侧如实降级**：stdx WebSocket 依赖 OpenSSL（帧掩码随机数走 RAND_bytes），
  仓颉运行时设备上装不了 OpenSSL 3（真机 connect 实测死于此），SDK 也无
  `ohos.net.websocket` 绑定（183 个绑定逐一确认）。`connect` 现在**在 scope 判定之后**
  当场拒绝并说明原因（`wsUnavailableOnOhos` 双平台分支，desktop 空实现）——安全判定
  先于可用性判定，越界请求报 scope 错而不是平台错。真机 2 PASS（降级拒绝 + 越界拒绝）。

- **`log` 插件鸿蒙降级契约真机取证**：`log:path` 回空串、`log:write` 返 false
  （不伪装成功）2 PASS（2026-10-25）。

- **`fs` 单测基座目录前置清理进 `scripts/test.sh`**：`/tmp/fs-unit-test` 按固定名复用、
  基座还在就撞「already exists」（会话交接 §四十五 留的欠账），入口处统一清掉。

- **骨架 `build-hap.sh`（`cli/templates/ohos-skeleton/`）加 assets 自动同步段**：
  构建前把工程根 `assets/ui`、`assets/capabilities` 拷进 rawfile——消除「改了 assets
  不 sync 直接构建、hap 装旧页且改动静默丢失」的坑（探针工程实测踩过：探针行全无、
  又无失败行）。

- **`fs` / `mqtt` / `redis` 插件鸿蒙真机核验通过（2026-10-25，探针应用 `ohos-capabilities`）**：
  三条命令面跨平台共用、无平台代码改动——`fs` 沙箱内九条命令全链（write/read/stat/mkdir/copy/
  rename/list/remove + exists），scope 口径定案：鸿蒙进程 cwd = 应用 el2 沙箱 `files` 目录，
  清单 allow 走 `$CWD` 前缀；`mqtt` 经 `hdc rport` 反向转发连本机 mock broker，全链 PASS
  （CONNACK / SUBACK QoS1 / PUBLISH 回推 / PUBACK / status / disconnect，got=10 条报文逐条留证；
  公网明文 broker 1883 实测被设备网络拦，取证对端走 rport + 本机 mock）；`redis` 同法连本机
  mock-redis，connect→SET→GET 逐字对账→status→disconnect 全链 PASS。
  取证与坑（`**` 不匹配裸目录、`writeText` 不自动建父目录、`redis:value` 的 value 是展示对象）见
  `examples/ohos/ohos-capabilities/docs/evidence-fs-mqtt-redis-verify.md`。
  **notification 鸿蒙侧评估为 blocked**：仓颉 SDK 无 `ohos.notification` 绑定（183 个绑定逐一确认），
  ArkTS 通道被 D-022 封死，剩 NDK 直连 C API 一条未验证的路。

- **`http` 插件打通鸿蒙（系统网络栈 `ohos.net.http`）**：仓颉运行时在鸿蒙上装不了 OpenSSL 3
  （真机 `MUSL-LDSO: load libcrypto_openssl.z.so failed … errno=2`），stdx 的 TLS 从第一步就失败，
  于是此前 `http:get` 在鸿蒙上是「https 全灭、http 照旧」的半死状态。现在把传输层抽成契约
  （`http_backend.cj` 的 `HttpReply` / `HttpResponseStream` / `parsePageHeaders`）：
  桌面两侧（`http_desktop.cj`，`@When[env != "ohos"]`）继续走 stdx + 显式 SNI，
  鸿蒙（`http_ohos.cj`，`@When[env == "ohos"]`）走系统网络栈，TLS / 证书链 / 代理交给 OS。
  **命令名、入参、返回值、主机白名单判定两平台完全一致**（判定只在 `plugin_http.cj` 与
  `parsePageHeaders` 各一份，不在平台实现里重判），前端一行都不用改。
  两处如实边界：① `http:postStream` 在鸿蒙**当场拒绝**并说明原因（系统栈一次回整包、无增量块，
  仓颉绑定上的 `requestInStream` 未验证），不返回假句柄。真机核验（2026-10-25，ohos-capabilities
  探针，4/4）：https GET 走系统栈 TLS 回 200、http GET 照旧、POST 体经 `extraData: StringData(body)`
  回显成功、`http:postStream` 拒绝报文原样带回原因；两处待核形状定案——`RequestMethod.Post/Delete`
  成员名正确，`extraData` 实际收 `HttpData` 枚举（真机首编即报，已修）。框架因此新增
  `ohos.net.http` 依赖：鸿蒙入口（最终链接侧）link-option 补 `-lohos.net.http`
  （`cli/src/manifest.cj` 两个 arch 段），缺了应用启动即
  `relocating failed: ohos.net.http:*_ti`。取证见 `examples/ohos/ohos-capabilities/docs/evidence-http-verify.md`。

- **`fs` 插件补齐目录/移动/复制/元信息四条命令**：`fs:mkdir`（`{ path, recursive? }`，目标已存在
  如实报错，不伪装成幂等成功）、`fs:rename` / `fs:copy`（`{ path, newPath, overwrite? }`，
  **两个路径都过 scope 校验**——`newPath` 同样是页面可控路径；`overwrite` 缺省 `false`）、
  `fs:stat`（`{ name, dir, size, lastModified }`，mtime 给可读字符串）。命名权限集同步扩容：
  `fs:stat` 进 `fs:readonly`（仍零写能力），三条写命令进 `fs:default`；前端 shim 补四个入口。
  单测 7 条真实落盘用例（建目录/重复拒/逐级递归、改名与 overwrite、整树拷贝、stat 元信息、
  参数校验），`scripts/test.sh` 339 PASSED。
- **`serial` 插件支持鸿蒙（NDK FFI 直连 musl libc）**：新增 `src/plugins/serial/serial_ohos.cj`，
  取代此前的 P-1 桩——`open` / `tcgetattr` / `tcsetattr` / `cfsetispeed` / `poll` 等 POSIX 串口面
  按 `@C foreign` 直连（`termios` 按 musl aarch64 的字节布局手工读写，不做 `@C` 结构体映射），
  不经 C 桥、与 `clipboard` 插件同模式。端口枚举覆盖鸿蒙特有的 `/dev/bus/ttyUSB*` 落点；
  **白名单在鸿蒙侧就是本文件**（桌面真正边界在 C 桥 core，这里镜像 `serialPathLooksAllowed`，
  页面可控字符串绝不只靠上层命令层校验）。读超时用 `poll`（有数据才 `read`，与桌面 Linux 桥同口径）。
  边界如实：设备节点访问可能要求 DDK/USB 权限乃至系统签名（`ohos.permission.ACCESS_DDK_USB*`
  用普通调试证书装包报 `9568289`，骨架模板里已注释、按需启用），打不开时如实报错不伪装成功。
  `ohos-skeleton` 的 `module.json5` 同步补了这两条权限的注释块。**当前状态（2026-10-24 更新）：
  FFI 通路已真机取证通过**——`examples/serial-assistant` 在 HarmonyOS PC（3QC0124B20000048）上装启，
  启动链 `startApp begin (business = serialAssistant.build())` → `page begin/end label=main` 完整，
  页面自检经 `probeLog` 进 hilog（tag `CjSerialProbe`）留证：`serial:list` 回 0 个端口，
  6 条候选路径的 errno 如实分流（`/dev/bus/ttyUSB*` = `Permission denied` 即 DDK/系统签名门槛、
  `/dev/ttyUSB*` = `No such file or directory`、`/dev/ttyS0` = `tcgetattr failed: I/O error`），
  即「FFI → musl libc → 内核 open → errno 回页面」这条链路成立。**真实串口的收发回环仍未取证**
  （需接真实设备且具备节点权限），故仍不标「可用」（`docs/需求追踪.md` PLG-004 与
  `docs/平台能力矩阵.md` 同口径）。
  **同日权限取证（决定后续路线，重要）**：`/dev/ttyS0` 是 `0666 root:root`——`open` 通过、`tcgetattr`
  才报 `I/O error`，说明卡点不在文件权限位；`/dev/bus` 与 `/sys/bus/usb/devices` 连 `hdc shell`
  （uid 2000 / `u:r:sh:s0`）都 `ls`/`stat` 皆 permission denied；`ohos.permission.ACCESS_DDK_USB_SERIAL`
  的 `grantMode` 是 `SYSTEM_GRANT`、`availableLevel` 是 `SYSTEM_BASIC`，**普通调试证书拿不到**。
  而 SDK 里 `@ohos.usbManager.serial`（namespace `serialManager`，**无 `@permission` 注解**）提供
  `getPortList` / `requestSerialRight` / `open` / `setAttribute` / `read` / `write` / `close`，
  是三方向 USB 串口的正路（框架代管节点，不必碰 `/dev/bus`）；仓颉 SDK 无该绑定，要用得走
  Cangjie↔ArkTS 互操作。**结论：`serial_ohos.cj` 现有裸 `open` 路线只对已授权/系统签名环境成立，
  对普通三方应用不成立**——要真机可用需改走 `serialManager` 或补 ACL 签名，二者都需要一次架构选择。
- **`serial` 插件补上鸿蒙的 `serialManager` 后端（路线 A 落地，2026-10-24）**：新增
  `src/plugins/serial/serial_manager_ohos.cj`，把上面那条结论落实到代码——USB 串口改走 ArkTS 的
  `@ohos.usbManager.serial`（`getPortList` 枚举 / `open` 前 `requestSerialRight` 取用户授权 /
  `setAttribute` 下发波特率与帧格式 / `readSync`·`writeSync` 收发 / `close`），**全程不碰 `/dev/bus`**，
  因此不需要 `ACCESS_DDK_USB_SERIAL` 那条 `SYSTEM_GRANT`+`SYSTEM_BASIC` 的门槛。
  接入点完全落在既有入口上，页面无感：`serialOpen` 先走 POSIX，打不开才转 `serialManager`；
  `serialRead/Write/Close` 按句柄空间分流（USB 句柄 = `1_000_000_000 + portId`，与 POSIX 的 `fd + 1`
  不重叠）；`serialPortList` 把 `serialManager` 认得的端口合并进 `/dev` 扫描结果并去重。
  三条实现约束（都是互操作库的形状，写死在注释里免得后来者重踩）：① `JSRuntime` **线程绑定**——
  所以起**一个专用 owner 线程**持有 runtime，其余线程投作业队列等结果，不做「谁调谁建」的共享单例；
  ② `JSBoolean` **没有取值接口**（只暴露 `toJSValue()`），所以「有没有授权」不查 `hasSerialRight`，
  而是「直接 `open`，抛错就 `requestSerialRight` 再按窗口重试」；③ `JSFunction` **只能 `call` 不能 `new`**，
  构造不出 `Uint8Array`，故借 `@ohos.buffer` 的 `buffer.from(arrayBuffer)` 拿到共享内存的 Buffer 视图，
  写完再用 `JSArrayBuffer.readBytes()` 取回字节。**取证状态：编译侧已过、运行期未验**——
  桌面 `cjpm build` 零警告；鸿蒙侧 `hvigor` 的 `CompileCangjie` 通过（hap 重打 2 097 601 字节），
  确认 `ohos.ark_interop` 在纯仓颉 entry 里可用（互操作不需要混合工程）。**运行期三项仍待真机**：
  `requireArkModule("@ohos.usbManager.serial")` 能否在仓颉自建的 runtime 里加载、无事件循环时
  `requestSerialRight` 的 Promise 能否推进、owner 线程绑定在设备上的实际表现；因此 PLG-004 仍不标「可用」。
- **`examples/serial-assistant` 迁移到新形态工程（RFC-002 §7）**：新增 `cj-tauri.toml` 清单
  （`[app]` 含 id/package、`[[windows]]`、`[assets] page="ui/index.html"`、`[capabilities] dir="assets/capabilities"`），
  业务包改为 `output-type = "static"` 并补 `[target.aarch64-linux-ohos]` 交叉编译段，页面与能力清单
  移入 `assets/`，`src/main.cj` 只留 `public func build(): AppSpec`（窗口/页面/能力目录一律由清单派生，
  桌面与鸿蒙共用这一份）。旧形态的链接选项（`-lcjtbridge`、`--subsystem=windows`）移交给派生骨架，
  业务包不再自带。同时补了**设备侧自检通道**：设备上没有环境变量，故 `build()` 按平台注入
  `window.__SERIAL_PROBE__ = { …, deviceProbe: true }`，页面改为「枚举 → 逐个尝试 open → 如实报 errno」，
  每条经 `probeLog` 命令写进 hilog——`eprintln` 在设备上不进 hilog，这是唯一能逐条对账的通道。
  新增 `cj-tauri sync desktop|ohos` 派生骨架 + `cj-tauri check` 全绿。
- **新增「平台能力矩阵」文档**（`docs/平台能力矩阵.md`）：一张表回答「某命令 / 插件 / 宿主能力
  在我的目标平台上能不能用」——宿主能力位（菜单 / 托盘 / 快捷键 / 拖放 / 对话框 / 通知 / 剪贴板）、
  全部官方插件、内置命令与核心机制，按 Linux / Windows / 鸿蒙三列标注实机取证、桩、未验证与不支持，
  口径与 `docs/需求追踪.md` 一致（没有实机证据的状态不标可用）；「未验证 ≠ 不支持」在文首写明。
- **`CONTRIBUTING.md` 新增「想做什么，改哪几处」小节**：把贡献者要动的位置按任务类型给成地图
  （加命令三处联动 / 加插件三处联动 / 加宿主能力 / 适配新平台 / 只改文档），细节契约仍指向 `AGENTS.md` §2。
- **issue 标签体系**：AtomGit 仓库建 `bug` / `good-first-issue` / `平台适配` / `插件开发` 四个标签，
  让潜在贡献者能按门槛找切入点。
- **`doctor` 失败项的提示补「去哪下载」**：缺 `CANGJIE_HOME` / `stdx` 的 FAIL 行现在直接给出
  下载入口（cangjie-lang.cn/download，注明需登录华为账号）与版本配套要求（SDK 1.2.0 配 stdx 1.2.0.1），
  第一次接触仓颉的人不用再另查文档。
- **极简模板（`cli/templates/app`）加「改三处变成你的应用」导航注释**：`src/main.cj` 顶部写明
  写命令 → 能力清单放行 → 页面 invoke 三步，命令注册点与页面脚本入口各有一处就地标记，
  模板 README 同步；`cj-tauri create` 生成的工程带同样注释（create 冒烟验证过）。
- **README 新增「安全模型：可被外部审视的证据」**：十条威胁 → 防线 → 测试用例的对照表，
  每条都指向 `src/tests/` 里的真实用例（`bash scripts/test.sh` 可复跑，329 条全绿）。
- **新增「安全模型」文档**（`docs/安全模型.md`）：威胁模型（页面不可信，四类入口各自防线）、
  分层防线（默认拒绝 / 命名权限集 / 路径 scope / 运行期加白收口 / 出网收口 / 进程与包边界）、
  与 Tauri 2 安全模型的对比、已知边界（未审计、CSP 归应用）。
- **新增「与 Tauri 的差异清单」**（`docs/与Tauri的差异.md`）：概念映射、行为差异
  （异步分发 / 注入时机 / 声明 ≠ 放行）、平台能力差异与迁移清单。
- README 文档索引同步收录上述两份与「平台能力矩阵」。

- **清单新增 `[links]` 段：应用自己给目标端追加链接选项**（`desktop-linux` / `desktop-windows` / `ohos`）。
  要用 SDK 没有仓颉绑定的原生能力时只能 FFI 直连系统 `.so`，而符号必须出现在**最终链接**那一侧——
  桌面是 `targets/desktop`（`output-type = "executable"`）、鸿蒙是 `targets/ohos/entry`（`dynamic`，
  框架自己的 `cjpm.toml` 写了不生效），这两份 toml 都是 `sync` 生成的、按约定不能手改。
  此前用户加一个原生库只能改框架生成器（等于 fork 框架），现在写在清单里即可：
  `[links] ohos = "-lohbattery_info"` → 生成物 `link-option = "-lpasteboard -ludmf -lohbattery_info"`。
  语义是**追加**在框架默认值之后（顶不掉 `-lcjtbridge` / `-lpasteboard` 这些必需项）；三端分开写是因为
  同一个库在三端上名字通常不同（`-lfoo` / `foo.lib` / `-lfoo_ndk.z`）。
  **未写该段时生成物逐字节不变**，老工程 `cj-tauri check` 不判漂移——实测两份工程（写 / 不写 `[links]`）
  `check` 均 EXIT=0，两份生成的 `entry/cjpm.toml` 唯一差异就是追加项那一行。
  值里含双引号或换行会在 `validate()` 当场拒（否则拼出坏 toml，报错点会漂到 cjpm 的解析里，看不出是清单写错），
  拼错的键同样报错。CLI 侧补了 5 条单测（`cli/src/manifest_test.cj`；CLI 是 executable 工程，
  子包不能 import 根包，测试只能放根包内）。用法与实战教程见
  `docs/实战-自定义插件读取设备电量.md` 与 `docs/扩展系统插件指南.md`。
- **鸿蒙（ArkWeb）宿主能力位落地第一项：菜单**。框架新增 `src/arkweb_menu.cj`（`MenuModel` /
  `MenuItem` / `MenuItemKind` → 扁平菜单，解析宿主回投的 `{"kind":"menu","id":…}`），
  `src/host_arkweb.cj` 的 `setMenu` / `setMenuItemState` 由「如实拒绝」改为真落地，
  `hostCapabilities()` 的 `menu` 位在真机取证后置 1（其余四位仍为 0，如实拒绝）。
  渲染留在应用侧：`cli/templates/ohos-skeleton/entry/src/main/cangjie/index.cj` 用
  `Button("菜单").bindMenu(...)` 画菜单、点选回调 `noteMenuClick` 交回宿主，顺带一行
  `menu click label=… id=…` 的 hilog（设备上框架 stderr 不进 hilog，这是原生抽点的唯一凭证）。
  新形态工程（`cj-tauri create --template ohos`）一律继承这套渲染。
  实机凭证：`examples/ohos/ohos-capabilities` 一轮 hilog —— `menu click label=main id=view.sidebar`、
  `PASS menu click id=view.sidebar enabled=true checked=false`、`PASS cap menu expect=true actual=true`、
  `PASS menu setChecked view.sidebar=true`（原文见该工程的 `docs/device-evidence.txt`）。
  **限制**：鸿蒙 `bindMenu` 只有一层、没有禁用位，`Separator` / `Submenu` 被拍平，`setMenuItemState`
  的 enabled 改动只能改灰、不能真正禁用——判据与原因见 `native/platforms/harmonyos/README.md`。
- 新增探针工程 `examples/ohos/ohos-capabilities`（新形态：`cj-tauri.toml` + 业务 static 包 +
  `assets/`）：页面向 `system:host` 要能力位并与期望值逐项对账，每条断言经业务包 `probeLog`
  写进 hilog（tag `CjProbe`），配套 `tools/apply-signing.sh` 把本机调试证书注入 `sync` 派生的
  `targets/ohos/build-profile.json5`（生成物不入库，sync 后重跑一次即可）。
- **鸿蒙（ArkWeb）剪贴板宿主能力落地：写完整可用，读如实返回空**。仓颉 SDK 6.1 没有
  `ohos.pasteboard` 绑定，`src/clipboard_bridge.cj` 的鸿蒙段改走系统原生 C API——`foreign func`
  直连 `libpasteboard.so`（`OH_Pasteboard_Create/Destroy/SetData/GetData`）与 `libudmf.so`
  （`OH_UdmfData_*` / `OH_UdmfRecord_*` / `OH_UdsPlainText_*`），`src/host_arkweb.cj` 的
  `clipboardWriteText` / `clipboardReadText` 由桩改成真实现。
  链接开关落在**入口模块** `entry/cjpm.toml`（`link-option = "-lpasteboard -ludmf"`，
  `output-type = "dynamic"`，最终链接在那儿）：`cli/src/manifest.cj` 的 `renderOhosEntryToml`
  同步补齐，此前骨架里写了、生成物里没有，产物 `DT_NEEDED` 缺这两个库、`U OH_Pasteboard_*`
  无处解析，应用**启动即 SIGSEGV**。真机判据：`readelf -d <模块.so>` 含 `libpasteboard.so` /
  `libudmf.so`，一轮 hilog 9 PASS / 0 FAIL，`PASS clipboard write cj-tauri-clip-<时间戳>`。
  **限制**：读要 `ohos.permission.READ_PASTEBOARD`（设备定义 USER_GRANT + SYSTEM_BASIC），
  普通调试证书声明它会让**装包直接失败**（`9568289 grant request permissions failed`），
  所以框架如实返回 `null`、探针记 `SKIP clipboard read denied-by-platform`；
  不把这条权限写进骨架 `module.json5`（否则所有生成工程装不上）。
  真机证据见 `examples/ohos/ohos-capabilities/docs/device-evidence.txt`，
  平台说明见 `native/platforms/harmonyos/README.md` 的「剪贴板」一节。

- **鸿蒙 `serial` 后端的 `serialManager` 互操作路线撤销，改为如实降级**：
  `src/plugins/serial/serial_manager_ohos.cj` 不再 import `ohos.ark_interop`，
  六个同名导出（`usbSerialOpenByPath` / `usbSerialReadHandle` / `usbSerialWriteHandle` /
  `usbSerialCloseHandle` / `usbSerialListNames` / `usbSerialIsHandle`）一律返回「不可用」
  并把原因写进错误槽。**真机 A/B 三组对照**（同机同业务码，只换后端）：真有互操作并去用
  → 启动即 `signal:6`（SIGABRT，日志停在 `startApp begin`）；只链不用 → 正常启动；
  整段摘掉 → 正常启动。`llvm-objdump -p` 确认第二组仍链着 `libohos.ark_interop.so`（`NEEDED` 在）、
  4 个 `JSRuntime` 未定义符号——**链接无害、执行 `JSRuntime()` 才 abort**；把创建点挪到 UI 线程
  （`onWindowStageCreate`）同样当场消失，故根因是**纯仓颉进程里没有 ArkTS VM**，不是线程选错。
  结论：`serialManager` 只能由真正的 ArkTS 侧调用（混合工程/应用自宿主 ArkTS），
  框架不绑 ArkTS。降级版真机复验：启动正常、`page end label=main`、自检 6 条路径 errno 照旧。
  决策全文见 `docs/设计决策记录.md` D-022 附段。

- **鸿蒙骨架的宿主对话框抽成 `CjDialogHost` 组件（应用侧 overlay，框架仍不引 ArkUI）**：
  `cli/templates/ohos-skeleton/entry/src/main/cangjie/dialog_host.cj` 承载此前内联在 `index.cj`
  里的 overlay——父组件只负责取请求、传 `requestId` / `kind` / `title` / `message`，卡片渲染与
  「点击后自己收起」都归组件（`answered` 记住已回填的 id，与 `requestId` 不等时才画）。
  视觉按真机反馈重做：遮罩由不透明黑改为**半透明带 alpha**（能透出页面原有内容）、卡片宽度收敛上限、
  标题加粗 + 正文分级、按钮右对齐、确定键按 `kind` 上色。单键（`info`）与双键（`confirm`）同一套。
  判据：真机 `dialog take` → `dialog present` → 点确定 → `dialog answer … confirmed=true` →
  页面 `resolved`，且关闭之后页面**可继续交互**（点顶栏「编辑」即切换视图）。

- **`ai-chat` 的网页站点库新增 MiniMax（`https://agent.minimax.cn/`），并把常用的四个站前置**：
  站点表仍只在仓颉侧维护一份（`examples/ai-chat/src/webtab.cj` 的 `WEB_TAB_SITES`），页面经 `webtab:list`
  拉取，不抄第二份。当前顺序（实机截图核对）：DeepSeek → 智谱清言 → 文心一言 → 腾讯元宝 → Kimi →
  豆包 → 通义千问 → **MiniMax** → ChatGPT。新条目的 `note` 为「MiniMax 官方 Agent…」、站点色沿用
  `#ff5a1f`（橙），卡片在侧栏「网页」面板里可见可点。单文件包同轮重打，
  `examples/ai-chat/dist-single/ai-chat.exe` 10 789 376 字节 / 10.29 MiB（较上一轮 +1 024 字节）。
  **取证范围**：卡片顺序与 MiniMax 入口是在**包内产物**上抓图核对的；点开 MiniMax 之后第三方页面本身
  的渲染**本轮未单独截图取证**——它走的是与 DeepSeek 相同的 `webtab:show` 通路（那一条前轮已实机取证），
  但「能打开卡片」与「站点自身正常渲染」是两件事，别把前者当后者的凭证。

### Changed

- **`ai-chat` 的窗口标题改成产品名 `ai-chat, made by cj-tauri`**（页面 `<title>` 同步）：原先只写
  「AI 对话」，从标题栏看不出这是 cj-tauri 的示例，推广时不好认领。实机读回
  `(Get-Process ai-chat).MainWindowTitle` 即新名字；单文件包同轮重打
  （`examples/ai-chat/dist-single/ai-chat.exe` 10 788 352 字节 / 10.29 MiB，子系统仍 `00000002`）。
  **同轮把页面内文案也一并改成同名**：左上角标识由「AI 对话」改为 `ai-chat`，首屏大标题改为 `ai-chat`
  + 下一行 `made by cj-tauri`（页面自检断言里的旧文案同步替换，否则自检当场变红）。
  实机截图（`1320×860`，包内产物）确认标题栏、左上标识、首屏三处一致。
- **重打 `cjnote` / `ai-chat` 的 Windows 单文件包**：`cjnote.exe` 34 352 640 字节（32.8 MiB）、
  `ai-chat.exe` 10 711 040 字节（10.2 MiB），两者子系统均 `00000002`（GUI，双击不弹控制台）、
  导入表只有 Windows 系统 DLL。同轮移除误入库的 `examples/cjnote/dist-single/cjnote`——那是 **Linux ELF**
  产物（无 `.exe` 后缀，Windows 上根本执行不了），单文件包目录只该有 `<名字>.exe`。
  打包前必须 `export CANGJIE_STDX=<stdx>/<三元组>/dynamic/stdx`（框架 `cjpm.toml` 的
  `bin-dependencies` 靠进程环境变量展开，漏设报的是「框架缺依赖」）。
- 官网架构小节接入**多端总图**（`docs/images/architecture-multiplatform.png` → `website/assets/`）：
  讲清工程根只有一份业务代码、`cj-tauri.toml` 是单一真相、`sync` 据此派生 `targets/desktop` 与
  `targets/ohos`，分别落到 WebKitGTK / WebView2 / ArkWeb。`scripts/site-check.sh` 的「同源拷贝不许漂移」
  清单同步扩到这张图——只改 `docs/` 时官网不会再静默停在旧图上（判据：自检那一行同时列出
  `architecture.svg` 与 `architecture-multiplatform.png`）。
- **撤除鸿蒙侧「选择 / 打开外部文件」的实验通路（能力本身仍不可用，等官方修）**：`ohos-skeleton`
  不再带 ArkTS 助手（`CjPicker.ets` + `build-profile.json5` 的 `arkOptions.runtimeOnly`）、
  `arkts_picker.cj`（`requireArkModule` 惰性加载）、`file_picker.cj`（`DocumentViewPicker` 尝试与
  URI 导入）、`open_with.cj`（`viewData` want 过滤器与 `onNewWant` 接续），模板 `module.json5` 的
  `READ_WRITE_DOCUMENTS_DIRECTORY` 与配套 `docs_reason` 字符串一并撤回。真机取证结论：从文件管理器
  「打开方式」拉起本应用**成立**（want `action=viewData`、`uri=file://docs/...`、`flags=67` 含
  `FLAG_AUTH_READ_URI_PERMISSION`），但读取端一律 `13900012 Permission denied`（hilog
  `FILE-FS: Failed to open OpenFileByPath error -13`）——三条路全部堵死：ArkTS 侧 picker 调不到
  （仓颉 SDK 无 `ohos.file.picker` 绑定，且纯仓颉 hap 里 ArkTS 模块不产出 abc）、URI 直读不认授权位、
  `atm perm -g` 授权目录权限后 `access=true` 但 `open` 仍拒。已按两处缺口提 issue：
  #136（`FileIo.open` 与文档「支持使用 URI 打开文件」不符）与 #137（缺 `DocumentViewPicker` 绑定）。
  骨架恢复为「只保证沙箱内文件可用」，`cj-tauri test` 的静态检查与两端 `cjpm build` 均通过。

### Fixed

- **Linux C 桥编不过（`duplicate member 'h'`）**：内嵌视图那轮给 `view_op` 加几何字段用了 `int h`，
  与同结构体的宿主指针 `cj_host *h` 撞名（`view_slot` 的 `int h` 无重名不受影响）——Windows 侧
  字段布局不同所以没暴露，Linux 侧 `native/build_linux.sh` 直接报错、`cj_bridge_view_*` 五个导出
  落不了地，`cjpm test` 一串 `undefined reference`。高度字段改名 `hgt`，投递侧与 create / bounds
  两个消费分支同步；顺带修掉三处 pointer/integer 错位赋值的连带警告。
- **`ai-chat` 收起侧栏后内嵌网页视图不跟着变宽（右侧空出一条）**：内嵌视图的矩形只在
  `window.addEventListener('resize')` 上重报，而折叠侧栏是 `#side` 的 `display` 切换——不改窗口尺寸、
  也就不触发 resize，视图停在「侧栏还在」时的旧位置。`toggleSide()` 里补一次 `scheduleWebRect()`
  （节流 80ms，与 resize 同一条上报路径）。包内 A/B 取证：侧栏展开时 DeepSeek 页面从 x≈265 起，
  收起后铺到 x=0（同一份 exe、只差这一次点击）。
- **`system:host` 永远看不到通知能力位（两侧表漂了一位）**：`native/core/bridge_core.h` 早有
  `CJ_CAP_NOTIFICATION = 8`（Linux 的 freedesktop Notifications、Windows 的 Shell_NotifyIconW 都真的
  置了它，core 还会打 `notify=%d`），但仓颉侧 `src/host.cj` 既没有这条常量、`HostCapabilities` 也没有
  可读字段——于是 `system:host` 的返回里**根本没有 `notification` 键**（页面拿到 `undefined`，不是
  `false`），应用据此判断「这台机器能不能发通知」永远是错的，而两侧注释还各自写着「逐位对齐」。
  现已补上常量与 `notification` 字段（`fromBits` / `toJson`，字段顺序按 header 位序），返回值变为
  `{platform, menu, tray, dragDrop, notification, hotkey, subtitle}`。**根子是「契约只写在注释里、
  没有机制拦着」**，所以 `scripts/check-static.sh` 新增第 8b 项：按名字比对两边的 `CJ_CAP_*` 表，
  任一侧多一位 / 少一位 / 数值不同都红（反向验证过：人为删掉仓颉侧那一位即报
  `CJ_CAP_NOTIFICATION 8` 缺失）。单测补了「只置第 8 位时 `notification=true` 且左右邻居
  `dragDrop` / `hotkey` 仍为 `false`」，钉住位与位的独立性。
- **对话框关闭后整页点不动（鸿蒙骨架）**：overlay 外层是 100%×100% 的透明容器，卡片收起后它仍在，
  ArkUI 里照样参与命中测试、吞掉落在页面上的点击——真机表现就是「点完对话框，点哪都没反应」。
  修法是收起时整块 `.visibility(Visibility.None)`（`Hidden` 不够：不画但仍占位并响应事件），
  组件内按 `requestId != answered` 二选一。判据：点确定后点顶栏「编辑」，视图当场从分屏切成编辑。
- **同屏两条对话框请求会互相顶掉、前一条悬挂到 120s 超时**：父组件此前每轮轮询都无条件取请求，
  页面连发两条时 `dialog take id=1` 紧跟 `dialog take id=2`，只有后一条被回填。
  现在按「请求 id == 已回填 id」放行（`dialog_host.cj` 的 `dialogAnswered` / `dialogAnsweredIdOf`
  按窗口记录），上一条答完之前不再取新的。**判据别用 `dialogActive`**——它置起后不复位，
  拿它当闸门会把收起之后的第二次点菜单一并挡掉（只弹得出第一次）。

### Removed

- **ai-chat 不再驻留系统托盘**（用户裁定 2026-10-25）：网页版入口改成本窗内的标签页之后，
  「窗口藏进托盘再唤出」这套常驻形态就失去了理由——`setTray` / `minimizeToTray` /
  「唤出面板」全局快捷键（`Ctrl+Alt+A`）与配套的 shell 事件解析一并删除，窗口回归普通窗口
  （点关闭即退出）。框架侧的托盘能力位与 `clipboard-history` 示例不受影响，仍是完整可用的样板；
  `system:host` 里 `tray=1` 报的是**平台支持**，与某个应用有没有用它无关。

## [2.0.0] - 2026-10-23

**不兼容变更**：删除已失效的公开 API `setHostFactory` / `requireInjectedHost`（见 Removed）——源码里仍
调用它们的应用会编译失败（而那调用本来也不生效：单槽没有任何读取方）；仓内 `src/` / `examples/` /
`cli/templates` 均已确认无调用点。其余是 CLI 生成器修复、`cj-tauri check` 判定修复与文档路径对齐。

### Added

- `examples/ai-chat` 新增**单文件包**（`bash scripts/pack-win-single.sh examples/ai-chat` →
  `dist-single/ai-chat.exe`，实测 10.6 MB、`Subsystem = 00000002`、导入表只有系统 DLL）：
  页面、highlight.js 与主题、`capabilities/app.json` 全部 base64 编进二进制，运行时不再读 `ui/` 与
  `capabilities/`（补齐三件套 `src/packed_assets.cj` / `src/packed_resources.cj` /
  `ui/vendor/pack-files.txt`；判据仍是「base64 非空即内嵌、否则读盘」，仓库内构建行为不变）。
  实机凭证：单独拷进空目录启动，日志有 `[cj-ai-chat] 能力清单来自内嵌资源：1 份`、
  `[cj-bridge] host created`、7 个插件装配完成，窗口与页面渲染正常（含内嵌高亮配色）。
  **单文件包不含 cjh 安装包**（13 MB 的 zip 没有编进 exe），引导卡第 1 步会如实报「找不到 cjh 安装包」，
  按提示设 `CJ_AICHAT_CJH_BUNDLE` 或走手动指定；**双击启动时日志落盘不生效**（GUI 子系统下 stderr 句柄无效，
  C 桥 `dup2` 到日志文件写不进内容），要日志就用 `ai-chat.exe 2> ai-chat.log` 启动。
- `examples/ai-chat` 的**一键部署在 Windows 落地**（此前只有 Linux）：从仓库自带的
  `vendor/cjh/cjh-v1.5.3-windows-x64-selfcontained.zip` 解出 cjh——同一个 `SHA256SUMS` 校验口径、
  安装到 `%LOCALAPPDATA%\cj-ai-chat\cjh\`、解包走系统自带 bsdtar（`%SystemRoot%\System32\tar.exe`，
  **绝对路径**：从 Git Bash 起的应用 PATH 里 MSYS 的 GNU tar 排在前面且不认 zip）、拉起走框架
  `launchHidden`（GUI 子系统用 `launch` 会给 cjh 配一个控制台黑窗），并逐个点名核对 zip 里 4 个
  「按名字 LoadLibrary」的运行时 DLL（`libcangjie-runtime` / `libboundscheck` / `libssl-3` /
  `libcrypto-3`）。实机凭证：`CJH-DEPLOY PASS deploy ok=true reused=false … api=yes` +
  `CJH-DEPLOY PASS status state=running api=yes`；端口上已有 cjh 时同一探针 `reused=true`。
- `examples/ai-chat` 新增 **`CJH-DEPLOY` 页内探针**（开关 `CJ_AICHAT_PROBE_DEPLOY=1`，`main.cj` 注入
  `window.__AICHAT_PROBE_DEPLOY__`）：桥就绪后跑一次 `cjh:deploy`，把 `ok/reused/deployed/api` 与随后的
  `cjh:status` 三态回投到应用日志。它要真装一份 cjh 并起进程，与自检「先没有 cjh」的前提互斥，
  **必须与 `CJ_AICHAT_PROBE=1` 分两轮跑**（README「自检」一节写明）。
- 引导卡第 1 步的安装目录文案**按平台给**（Windows 显示 `%LOCALAPPDATA%\cj-ai-chat\cjh`，
  其余平台仍是 `~/.local/share/cj-ai-chat/`）：平台信息异步取回，先写无路径的通用文案再补全。

### Fixed

- `examples/cjnote` 聊天直连对「要求 SNI 的服务端」（CDN 前端常见）**握手必然失败**
  （`TlsException: alert handshake failure (1040)`，且极易被误判成证书校验问题）：stdx.net.http
  不把 URL 主机名填进 SNI（`TlsClientConfig.serverName` 默认 `None` = 不传该扩展），服务端
  直接回 alert 40。`aiTlsConfigFor()` 显式补上 `cfg.serverName = host` 作为 workaround——
  curl / openssl 带 SNI 同端点均正常，显式设置后同一端点立即打通；stdx 侧已准备向官方提 issue，
  修好后可撤。
- `examples/ai-chat` 一键部署**在 Windows 上必然失败**并错报成「解包/安装失败」：那句「安装目录可读」
  的检查拿 `File(Path(dir), OpenMode.Read)` 去开**目录**，Windows 对目录 open 直接回 `Access is denied`
  （Linux 上 `open(O_RDONLY)` 目录能过，所以这条只在 Windows 炸）。改用 `exists(Path(dir))`，两平台同一口径。
- 解包失败**不再只回一句笼统文案**：`cjhExtractBundle` 改为回传失败原因（找不到解包工具 / 解包工具起不来 /
  30s 未结束 / 解包后没找到二进制 / 缺哪个运行时库），由 `cjh:deploy` 的 `error` 字段原样带到引导卡——
  Windows 首轮正是卡在「看不出真因」上，应用自己的 stderr 在 GUI 子系统下收不到（重定向也是 0 字节）。
- **CLI 自身在 Windows 上编不出来**：`cli/cjpm.toml` 只声明了 Linux 目标的 stdx `path-option`，缺 mingw
  目标段，`cd cli && cjpm build` 报 `root package 'cli' imports package 'stdx.encoding.json' …
  not added as a dependency in cjpm.toml`（看着像 toml 漏配依赖，其实是目标段没写）。已补 mingw 段。
- **`cj-tauri sync` 在 Windows 上生成的工程必然编不过**（三处生成器缺陷，music-next 首轮实测暴露）：
  ① 写进 TOML 的路径保留反斜杠，`E:\…` 里的 `\a` / `\t` 被当成 TOML 转义序列 → cjpm 解析期
  `errLexEscape` 直接失败，现在一律经 `toTomlPath()` 转正斜杠（桌面 / 鸿蒙两份 toml 的 `path` 与 `-L`
  路径都过这一层）；② 鸿蒙 entry 的 `compile-option` 内层引号没转义（`--cfg="${…}"`、`-B "…"` 整串），
  生成的 TOML 引号提前闭合；③ 生成源码里 `url=\"…\"` 少一层转义，hilog 那行日志把字符串拆断。
- **生成的仓颉源码注释里出现 `capabilities/*.json`**，`/*` 触发仓颉的块注释嵌套 → 骨架编译报与位置
  无关的莫名错误；改写为「`rawfile/capabilities 下的各份 json`」，不再产生 `/*`。
- **单测 `guessTargetDesktopFields` 在 Windows 上一直是红的**：断言把桌面目标的宿主形态与系统名
  写死成 Linux 那套（`webkitgtk` / `Linux`），而 `guessTarget()` 在 Windows 上如实返回
  `webview2` / `Windows`。期望值改为随平台取（`@When[os == "Windows"]` 一份、其余桌面一份），
  `scripts/test.sh` 在 Windows 上从 328/329 变为 329/329。
- **`cj-tauri check` 的三方比对在 Windows 上恒被跳过**：探测路径写死
  `targets/desktop/target/release/bin/main`，而 Windows 产物是 `main.exe`（cjc 不补后缀），于是每次都打
  「桌面骨架未构建」并放过整轮比对——判定改为按平台取后缀（`exeSuffix()`），与构建侧同源。
- **`examples/modbus-poll` 自串口插件拆包后一直编不过**：RTU 传输层直接调 `serialOpen` / `serialRead` /
  `serialWrite` / `serialClose` / `serialLastError`，而这些原语随 `081c0c3` 迁进了
  `cjTauri.plugins.serial` 子包，`modbus.cj` 仍在用旧的 `import cjTauri.*` 找它们，编译期报 5 条
  `undeclared identifier`。补一行 `import cjTauri.plugins.serial.*`（与其余四个串口示例同口径）后
  单文件包重新打得出（5.7 MB）。

### Removed

- `src/host_factory.cj` 的单槽宿主注入 `setHostFactory` / `requireInjectedHost`：鸿蒙宿主已内置
  （`createHost()` 的 `@When[env == "ohos"]` 分支直接返回 `ArkWebHost`），多宿主入口统一走
  `registerHost(HostProvider)`（`src/platform_host_provider.cj`，带优先级，`resolveHost` 里优先于内置宿主）。
  删前它对调用方**已是空操作**——`HOST_FACTORY` 只有 `requireInjectedHost` 读，而后者没有任何调用方；
  仓内 `src/` / `examples/` / `cli/templates` 均无 `setHostFactory` 调用点。
- `src/arkweb_script.cj` 的 `arkWebDispatchScript`：鸿蒙侧回投改为「页面 pull 心跳 + 原生推脚本」后该
  拼装函数无人调用（同文件仍在用的 `arkWebLabelScript` 保留）。

## [1.1.2] - 2026-10-23

（修正 1.1.1 的打包瑕疵：包里的预编译 CLI 是 1.1.0 那次构建留下的产物，装上后 `npx cj-tauri --version`
回 `1.1.0`，看着像装错了版本。npm 的版本号发布即被占用、unpublish 之后同号不能重发，故顺延末位。）

### Fixed

- `scripts/npm-pack.sh` 在把预编译 CLI 塞进 tarball **之前核对它自报的版本**（`<cli> --version` 的末段
  vs `npm/package.json` 的 `version`）：不符即中止，并提示先 `cd cli && cjpm build` 重编；
  产物跑不起来（缺仓颉运行时库）时只告警不中止——宁可少一层校验，也不要把打包卡在环境问题上。
  此前完全不校验，而 `cli/target/release/bin/main.exe` 是上一次构建留下的，改了版本号却没重编就会发布错版本。
- 重编 CLI 后重发 1.1.2，`npx cj-tauri --version` 与包版本一致。

## [1.1.1] - 2026-10-23

（末位发布：只补文档与包元数据，不改行为。起因是 npm 包页面的介绍里，**鸿蒙 PC 工程怎么创建一个字都没提**——
正文取自随包分发的 `npm/README.md`，改它必须发一版才生效。）

### Fixed

- `npm/README.md`（也就是 npm 包页面的介绍正文）补「鸿蒙 PC（`--template ohos`）」一节：创建命令与
  `--bundle` / `--label`、生成物结构（`main_ability.cj` / `index.cj` / `rawfile/` / `build-hap.sh`）、
  前置（DevEco Studio 6.1 + 签名 + `DEVECO_WIN` / `CANGJIE_STDX_OHOS`）、桌面形态的两个配置
  （`deviceTypes: 2in1` + `checkDeviceTypes: false`）、窗口沿用系统默认、已知限制与真机 hilog 判据；
  `create` / `build` / `run` 三行说明补上鸿蒙工程转交 `build-hap.sh` 的行为。
- `npm/package.json` 的 `description` 补「鸿蒙 PC」（原为 Windows / Linux 双平台口径）。
- `examples/ohos/ohos-music` 与 `examples/ohos/ohos-movie` 的 README 仍记着已撤除的自定窗口尺寸
  （`86% × 84%` → `2683×1747`），改为当前口径：不调 `resize()`，沿用系统默认 `[515 281 2090 1394]`。

### Changed

- 新增四篇鸿蒙 PC 实战文档：`docs/鸿蒙PC实战-01-白屏三轮与一条llvm-nm.md`（加载期 SIGSEGV 与
  `llvm-nm` 判据）、`-02-窗口尺寸别再自己改.md`（三版自定尺寸与被撤回的理由）、
  `-03-音乐示例搬上鸿蒙PC.md`（业务代码单份 + 构建期同步）、`-04-观影示例与鸿蒙TLS.md`
  （鸿蒙上仓颉运行时装不了 OpenSSL，取图改走 `ohos.net.http`）。

## [1.1.0] - 2026-10-22

（自 1.0.0 起 75 个提交：鸿蒙 PC 从「架构预留」走到实机跑通——music / movie 两个示例工程
（`examples/ohos/`）加 `create --template ohos` 脚手架，宿主住在应用侧 ArkUI、页面与能力清单是
hap 的 `rawfile` 真文件、构建走工程自带的 `build-hap.sh`；窗口尺寸交还系统默认（不再 resize / 挪位）。
桌面两平台的 IPC、能力模型与插件体系不变。）

### Changed

- **README 与官网的鸿蒙 PC 口径从「预留」改为「已支持」，并补三张实机截图**（2026-10-22）：
  README 的平台徽章加 `鸿蒙 PC`、现状段由「双平台宿主」改成三平台宿主（平台差异仍只落在条件编译
  与 C 桥两处），「运行效果」与「示例一览」补 `ohos-music` / `ohos-movie` / `create --template ohos`
  生成物三张实机截图（`docs/images/example-ohos-{music,movie,template}.jpg`）；官网特性卡把
  "HarmonyOS ArkWeb has a reserved architecture slot" 改成 ArkWeb 实机跑通（2in1 桌面形态、宿主写在
  仓颉侧不走 C 桥、`card__meta` 补 `arkweb_proxy.cj`），示例轮播由 21 屏加到 24 屏（同样三张，落
  `website/assets/screenshots/ohos-*.jpg`），标题与提示行的数量一起对齐。截图按实机窗口矩形
  `[515 281 2090 1394]` 裁切并缩到 1240 px 宽——原图是整屏桌面快照，直接上站会带上用户桌面图标。

### Added

- **鸿蒙 PC 上的音乐播放器示例 `examples/ohos/ohos-music`**（2026-10-22）：把 `examples/music`
  的歌单 / 播放器 / 歌词搬到鸿蒙 PC（实机 HAD-W32 / HarmonyOS 7.0.0.107 / API 26 / aarch64），
  同一份前端页面与仓颉命令层，宿主侧换成 ArkWeb 组件。首轮实机：页面渲染正常、热门歌曲与后台歌单
  加载出来、播放进度在走（00:17 / 03:42），窗口为**桌面形态**（可拉伸、三栏铺开）。
  工程侧新增 `examples/ohos/` 作为「鸿蒙应用工程根」，`build-hap.sh` 每次构建把
  `examples/music/src/*.cj` 同步成 `musiclib/`（只改包声明）并把 `ui/index.html` 与能力清单
  base64 内嵌成 `musiclib/ohos_assets.cj`——**业务逻辑仍只有 `examples/music` 一份**。
  两处必须这么写的配置（否则表象都很误导）：`module.json5` 的 `deviceTypes` 要写 `2in1`
  （只写 phone/tablet 时系统按手机应用塞进竖屏兼容窗，约 600 宽）而仓颉构建插件默认禁它，
  放行开关是 `entry/build-profile.json5` 的 `cangjieOptions.checkDeviceTypes=false`；
  `requestPermissions` 必须有 `ohos.permission.INTERNET`（缺了所有请求死成
  `SocketException: Failed to create socket: Operation not permitted.`，页面显示的是「连不上后台接口」）。
  默认窗口按**屏幕像素**折算成 86%×84% 并居中——`resize()` / `moveWindowTo()` 收的是 px 不是 vp，
  写死 `1440×900` 在 3120×2080 的屏上只有 46% 宽（看着像小窗），实测稳定矩形 `[218 166 2683 1747]`。

- **鸿蒙 PC 上的观影示例 `examples/ohos/ohos-movie`**（2026-10-22）：`examples/movie`
  （榜单 → 搜索 → 详情 → 播放 → 换源）在鸿蒙 PC 上的落地，业务层仍是 `examples/movie` 一份
  （`build-hap.sh` 同步成 `movielib/` 只改包声明，页面与能力清单 base64 内嵌）。
  实机：列表页与详情页都正常、详情页可播放（6:42 / 2:22:33）、窗口为桌面形态（`2in1`）。
  两处工程配置与 music 同口径（`cangjieOptions.checkDeviceTypes=false` 放行 `2in1`、
  `ohos.permission.INTERNET`），另有一条 **movie 独有**的取舍见下面的 Fixed 条目。
  两个鸿蒙示例复用同一份调试签名（`com.yang.testcj`），**同一台设备只能装一个**。

### Fixed

- **鸿蒙侧 `movie:image` 的封面全灭：仓颉运行时装不了 TLS，改用系统网络栈**（2026-10-22）：
  `examples/ohos/ohos-movie` 首轮实机页面照常、**只有封面全是首字色块**——后台接口是 http
  （片单 / 搜索 / 播放全正常），封面却是豆瓣/百度图床的 https。真机 hilog 定死根因：
  `MUSL-LDSO: load libcrypto_openssl.z.so failed … errno=2`（`libssl_openssl.z.so` 同样），
  即仓颉运行时按名字 dlopen OpenSSL 3、设备上没有——与 Windows 侧「漏 `libssl`/`libcrypto`
  → 只有 https 全灭」同形。修法不是往 hap 里塞 OpenSSL（ABI/符号对不上就再炸一次），而是把取图换到
  **系统网络栈**：`ohos.net.http` 的 `createHttp()` + `HttpRequest.request`，命令名与契约与桌面版
  完全一致（`movie:image`、`{url}` → `data:image/...;base64,...`），白名单 / 浏览器 UA / 5 MB 上限
  复用 `examples/movie/src/api.cj` 那份（`imageSourceOf` 等改为 `public`，安全判定只留一份）。
  两个实现细节：`request` 只有回调形态、命令又跑在 worker 线程上，所以「回调 + sleep 轮询」收口；
  结果装在对象盒子里（仓颉 lambda 不能捕获可变局部变量）。取证：列表页 8 张可见封面里 7 张真实海报，
  取不到的那条图源回 **HTTP 200 + 0 字节**（防盗链），hilog 有 `image http=200 bytes=0 type=image/jpeg`，
  页面回退成色块——不会白屏、也不假装成功。
- **cjnote 聊天模式的回答会变成重复段落**（2026-10-22）：页面把同一句话叠七八遍
  （`你好！我是…` 之后每隔一段又从头来一遍），而 `ai:chat` 的收尾统计显示
  `chars` 只有几个字节、`received` 却有几十 KB。定位分两步：① `curl` 直连同一端点，
  原始流的 `content` 序列是标准增量（`"Hi"` / `" there"` / `"!"` …），说明**不是服务端在重放**；
  ② 把 `ai:chat` 收到的原始帧打出来，同一个 `chunk_index` 出现在多行、同一段 `content` 被反复解析，
  真因是宿主侧读流时用 `ArrayList.remove(at:)` 循环裁 `pending`，裁错后同一批字节被下一轮再读一遍。
  修法是逐字沿用框架 `http` 插件那份已跑通的 `takeCompleteUtf8`（`pending.remove(0..cut)`，Range 右开）；
  另加一层「delta 形态只判定一次」的兼容（累积式网关取已发长度之后的尾部当增量，标准增量流原样透传——
  逐帧猜会在相邻同内容帧上吞正文，所以判定后即锁定）。取证：修后 `content` 序列各帧互不相同、
  `inc == raw`、`chars` 等于真实回答长度（实测 98 字节的三句自我介绍一字不差）。
- **cjnote 聊天模式直连报 `unknown CA` 的问题有了可用出路**（2026-10-22）：服务商（实测
  `taotoken.net`）下发的链是 `叶 → Xcc Trust DV SSL CA（中间）→ Certum Trusted Network CA（自签根）`，
  中间证书不在系统证书库，而本机仓颉 stdx **不会用服务端下发的中间证书建链**，于是握手失败
  （`TlsException: … certificate verify failed (134), TLS alert unknown CA`；同机 curl/openssl 通过，
  baidu/deepseek 也通过）。探针确认 `CertificateVerifyMode.CustomCA(...)`（只给 CA 级证书或整条链）
  在本机 stdx 上**不起作用**，只有 `CustomVerify` / `TrustAll` 能连通——所以落成「按主机放行」：
  宿主侧白名单文件 `%LOCALAPPDATA%\cjnote\tls-allow.txt`（一行一个主机名，`#` 起为注释），
  环境变量 `CJNOTE_TLS_INSECURE_HOSTS=<host[,host]>` 作补充，两者合并生效；只对列出的主机跳过校验，
  启动时 stderr 明写一行 `注意：<host> 的证书链不做校验（由宿主侧白名单放行：<文件路径> …）`，
  失败时的错误文案也改为给出可操作提示（文件路径 + 环境变量两种落法）。**默认仍是严格校验**，
  且刻意不做进设置页：文件与变量页面都写不了（页面只有笔记库与 `store` 的权限），
  「要不要校验证书」始终只在用户手里；选文件而非纯变量是因为单文件 exe 双击启动读不到 shell 变量。

### Changed

- **cjnote 的 Windows 单文件产物重打**（2026-10-22，纳入 AI 面板折叠 / 拖宽上限 960）：
  `examples/cjnote/dist-single/cjnote.exe` 34 287 616 字节，GUI 子系统（双击不弹控制台），
  导入表只有系统 DLL，`.rsrc` 节 `0x0162df20` ≈ 22.2 MB 即内嵌的 cjh 与 4 个运行时 DLL。
  同一份 exe 在隔离目录实测：`CJNOTE_SELFCHECK=1` → **89 PASS / 0 FAIL / 1 SKIP**
  （汇总行 `passed=87 failed=0`）；cjh 自行释放到 `%LOCALAPPDATA%\cjnote\runtime\` 并
  `ws connected ws://127.0.0.1:8765/ws`，`8765` LISTENING。

### Added

- **cjnote 的 AI 面板新增「聊天 / Agent」双模式**（2026-10-22）：Agent 模式仍是原来的 cjh 通路
  （有工具、能读写文件）；**聊天模式**不做 agent 循环、也没有任何工具，由宿主侧直接向服务商的
  chat completions 接口发一次流式请求，增量逐块经 `ai:chunk` 回投页面（新命令 `ai:chat`，
  `examples/cjnote/src/ai_direct.cj`）。密钥与地址只在宿主侧取用（读 cjh 的 `auth.json`，与
  `cjh:config` 同一套脱敏口径），**页面拿不到明文**；两模式共用同一份服务商配置，切换偏好落 `store`。
- **`CJNOTE_SELFCHECK_AI=1`：聊天模式的宿主侧实网冒烟**（不开窗口，开窗前直接跑一次 `ai:chat`
  再退出）：`ok/status/chars/received/chunks/costMs` 一行打到 stderr，退出码 `0` 成功 / `1` 失败 /
  `2` 请求成功但一条 `ai:chunk` 都没回推（专指流式没生效）。与日常自检分开开关——它真的会打服务商接口。
- **cjnote 的 AI 助手面板可折叠了**（2026-10-22 用户反馈：不用 AI 时这块 320px 太占注意力）：
  三条入口走同一个 `applyAiVisible`——面板头「»」胶囊按钮、`Ctrl+4`、原生「视图」菜单勾选项
  「显示 AI 助手」（新增独立开关 `view.aipanel`，勾选态经新命令 `aipanel:sync` 与页面双向同步，
  仿 `linenos:sync` 的两条入口约定）；隐藏后中栏工具条右缘出「✦ AI 助手」把手唤回。
  实现只切 `body.ai-hidden` 一个类（CSS 藏 `#ai` 与左缘拖条，中栏自动占满），**不做宽度过渡动画**
  （收缩是布局重排，CodeMirror 要重新量宽）；偏好落 `store`（`ui.aipanel`）重启恢复；
  隐藏只影响可见性，cjh 连接与流式消息照常。能力清单放行 33 条（+`aipanel:sync`），
  沙盒自检 90 PASS / 2 FAIL（2 FAIL 为真实服务商聊天往返，厂商端点不可达）。
- **cjnote 的 AI 面板拖宽上限从 640 放宽到 960**（同轮用户反馈「拉不大」）：真正兜底的仍是
  「编辑区保底 320px」的动态夹取——1280 宽窗口实测能拉到 728px（撞窗口保底），大窗口可到 960。

- **新增示例 `examples/cjnote`：AI 原生 Markdown 笔记**（从 [cjnote](https://atomgit.com/qq8864/cjnote) 移植进仓，
  随上游 `52c5afd` 同步）：三栏（笔记库 / CodeMirror 编辑 / AI 助手），笔记就是工作区 `notes/` 下的纯 `.md`；
  原生菜单（文件 / 视图 / 帮助）+ `setTitlebarSubtitle` 副标题（平台没这块能力位时回落页面顶栏）、视图三态与
  界面主题**与原生菜单勾选双向同步**、`Ctrl+O` 打开库外文件只进内存（首次保存才落成库里的新笔记，不改写磁盘原文件）、
  大纲页签与页内快速打开；笔记存取走应用自研的 `NoteStore`，**不引 fs 插件**。
  **AI 后端只有 cjh 一条路**（上游这一版把第三方直连整个移除）：⚙ 从弹窗改成整页设置，地址 / 密钥 / 模型 / 协议
  写进 cjh 的 `settings.json` + `auth.json` 并重启生效；密钥输入框**永远留空**（只有真输了新值才写，带 `****` 的
  掩码值一律跳过），所以打开设置页再保存不会把掩码写回配置文件。AI 走 cjh 的 ws（`ws:default`），不再有
  「某家服务商域名不在白名单」这类问题。另有编辑器「显示行号」开关与 AI 流式回复节流渲染。
  移植适配：框架依赖从仓外同级 `../cj-tauri` 改为仓内上两级 `../..`（`link-option` 的 `-L../../native` 同改）；
  清单里的 `store:del` 是笔误（store 插件真名 `store:delete`）已订正；`-lcjTauri.plugins.fs` 一并去掉——
  本应用只 import `std.fs`、不引 fs 插件（清掉 `target/release/incremental-cache.json` 强制重链后仍链得过）；
  `README.md` 的桥路径与 `LD_LIBRARY_PATH` 示例改回仓内口径。
  **随包分发 cjh 预编译产物**（`vendor/cjh/bin/<平台>/`——应用按路径直接找现成二进制，没有运行期解包，所以
  `bin/` 树必须真的在盘上；另带两个平台压缩包与 `SHA256SUMS`）：Windows 那份原样随上游，**Linux 两份已按 cjh
  `a3e1e6e` 的 `dist/cjh-linux-x64` 重建**——上游随包的 Linux 通道要求 `GLIBC_2.38`，本机（22.04 / 2.35）
  起不来；重建后 `GLIBC_2.34` 封顶。仓库**不提交 `*.dll`** 的规则对这里开口子：Windows 侧按名字加载的 4 个
  依赖 DLL 随包分发（与 ai-chat 的 `vendor/cjh` 同性质，见 `.gitignore` 的例外与 `AGENTS.md` §5）。
  **设置页的保存是「两条腿」**（2026-10-20 实测定案）：写 `settings.json` / `auth.json` 管下次拉起与协议字段，
  同时把 `baseUrl` / `model` / `apiKey` / `temperature` / `maxTokens` / `maxIterations` 经 `POST /api/settings`
  即时推给**正在运行的那只 cjh**——`cjh:restart` 只重启本应用 spawn 的实例（端口上是 ai-chat 拉起的 cjh 时
  它只回一句「需手动重启」，于是设置看着「保存了却不生效」），而这条 REST 通道对别人的实例同样有效。
  只有 `provider_protocol` 不在白名单（传进去静默忽略），那一项改动才如实提示需重启。
  设置页另加**「测试连通」**按钮：走 `chat` 帧的**帧级 `model` / `baseUrl` / `apiKey` 覆盖**（单次生效、
  不落盘）真发一条最小对话，测的就是「表单里这组值能不能用」且配置一字未动；探针不带 `session_id`
  （cjh 为这一轮另开会话），不污染当前对话、也不顶掉会话 id。前端库（marked / Highlight.js / CodeMirror）
  与已有示例的副本逐字节相同，来源与许可证见 `AGENTS.md` §5。
  Linux 实机：窗口 1280x800、原生菜单 13 项、页面自检 `SELFCHECK DONE passed=68 failed=0`（另有 1 条 SKIP）；
  Windows 侧页面自检 2026-10-21 跑通，**最终产物口径为 `passed=84 failed=0`**（明细 84 条 PASS / 0 条 FAIL /
  1 条 SKIP：真实 cjh 聊天探针那一刻 ws 未连上，不计入失败；取证行见本文件「OpenSSL 预加载」那条）。
- **cjnote 示例：AI 面板宽度可拖**（与左侧栏同一套交互）：面板左缘加 6px 拖条，拖动改宽
  （240~640px 夹取，双击复位 320），宽度写进 `--ai-w`、偏好落 store（`ui.aiw`）、下次启动回放。
  方向与侧栏相反（拖的是右栏左缘，往左拖变宽），上限还要跟窗口走：夹取里扣掉「侧栏 + 编辑区保底 320px」，
  并在 `resize` 后按新空间重夹一次，免得窄窗口下把编辑区挤成 0。页面自检补 4 条断言
  （拖条存在且 `col-resize`、往左拖真的变宽、超限夹取、双击复位），最终产物自检口径
  `SELFCHECK DONE passed=84 failed=0`（取证行见「OpenSSL 预加载」那条）；
  顺带修掉两条「后端给了绝对路径」断言只认 `/` 的 POSIX 假设——Windows 上后端给的是 `E:/…`，
  这两条此前在 Windows 恒红（判定写窄，不是后端没给）。
- **cjnote 示例：AI 后端的提示不再把「没配服务商」说成「cjh 没起来」**。实测随包 cjh 1.5.3 在
  **没有服务商密钥**时 `/api/health` 照样返回 200、`/ws` 端点也正常（只有 `/api/settings` 的 `apiKey` 是空串），
  旧实现只按「连没连上」判定，这种情况因此被报成「AI 后端未就绪 / cjh 没起来或连不上」——
  后端明明起着，用户却找不到原因、也没有任何地方提示他去填密钥。现在拆成两条轴：
  **cjh 在不在**（离线卡标题按卡点分「没找到 cjh」/「cjh 没能启动」/「连不上它的 WS」，不再一句话糊住），
  与 **服务商配没配**（连上后复判一次 `cjh:config`：缺密钥时状态胶囊显示「未配置密钥」、消息区给一张
  「去配置」卡，点一下直达设置页，并说明接入地址与模型名留空时用 cjh 内置默认值；输入框占位同步改成下一步动作；
  保存配置后复判一次，配置齐了把卡换回正常问候）。顺带修掉一个竞态：启动期的问候 / 未配置 / 离线卡
  此前会无条件清空消息区，**晚到的异步回调会把刚到的回复整个抹掉**（页面看着像「发出一问没回」，
  自检现场 `bubbles=0`）——现在三张卡只在空态绘制。空配置目录实机取证：
  `CJH-WARN 服务商密钥未配置（cjh 已连上 ws://127.0.0.1:8765/ws）`；页面自检 84 PASS / 0 FAIL / 1 SKIP。
- **cjnote 示例：从 Git Bash 启动时读不到 `~/.cjh`（配置页空白），已修**。Git Bash 的 `HOME`
  是 POSIX 形式（`/c/Users/yang`），而原生 Win32 API 会把它解释成「当前盘根目录下的
  `c/Users/yang`」——`cjh:config` 于是拿不到 `settings.json` 里的 model（配置页一片空白），
  自检里 `cjh:config returns model from settings.json` 恒红。**同一份 exe 从 cmd 里起就正常**
  （79 PASS / 0 FAIL），清理 `HOME` 后也正常，与构建无关。修法：`cjhConfigDir()` 的三个来源
  （`CJH_HOME` / `HOME` / `USERPROFILE`）都先过 `nativePathOf()`——只把 `/<盘符>/…` 与
  `/cygdrive/<盘符>/…` 规范成原生路径，其余原样返回（平台差异走 `@When[os == "Windows"]`，
  非 Windows 分支是恒等函数）。取证：同一份单文件 exe 在 Git Bash 下自检
  **84 PASS / 0 FAIL / 1 SKIP**（汇总行 `passed=84`、`SELFCHECK PASS` 明细 84 条、FAIL 0 条；SKIP 那条是
  真实 cjh 聊天探针当时没连上，不计入失败），空配置目录下仍如实报 `CJH-WARN 服务商密钥未配置`。
- **单文件产物里的 `ws://` 连不上（`Can not load openssl library or function RAND_bytes.`）已修**：
  仓颉运行时的随机数默认实现走 OpenSSL，而它按**裸名**找 `libcrypto-3-x64.dll` / `libssl-3-x64.dll`——
  SDK 与 stdx 都不带这两个，开发机上只是恰好命中 PATH 里 Git 自带的那份，于是**同一条 `ws://` 连接线
  本机全通、别人双击就挂**（RFC6455 升级要算 `Sec-WebSocket-Key` 的随机 nonce，明文 ws 也逃不掉；
  `plugin_ws.cj` 无条件给的 `TlsClientConfig` 还会让 TLS 后端提前实例化）。症状极具误导性：cjh 的
  `/api/health` 照常 200、页面显示「cjh 在运行」，**只有 ws 握手失败**。修法是**启动早期按绝对路径
  预加载一次**，之后运行时按裸名加载即命中已加载模块——不改系统 PATH、也不把 DLL 摆到 exe 旁边，
  单文件承诺不破；这两个 DLL 本来就在包里（随包 cjh 要用它们），**零新增体积**。
  新增桥导出 `cj_bridge_preload_library(path)`（1 = 已在进程内 / 0 = 失败，原因打 stderr）与仓颉侧
  `preloadEmbeddedLibrary(path)`（`src/embedded_assets.cj`；没有 C 桥的平台如实返回 false）；平台原语
  `cj_plat_preload_library` 按 `AGENTS.md` §2 落在 `bridge_win.c`（`LoadLibraryA`）与 `bridge_linux.c`
  （`dlopen`），`native/tests/test_bridge_core.c` 桩自检 232/232 通过。`examples/cjnote` 首个接入：
  随包资源释放完成后先加载 `libcrypto` 再 `libssl`（后者依赖前者的符号）。
  取证：另一台机器那条报错不再出现；最终产物默认日志里 `[cj-bridge] preload: …\cjnote\runtime/libcrypto-3-x64.dll` /
  `…/libssl-3-x64.dll` 两行之后紧跟 `[cj-tauri] ws: connected ws://127.0.0.1:8765/ws`，页面自检
  `SELFCHECK DONE passed=84 failed=0`（明细 84 条 PASS / 0 条 FAIL / 1 条 SKIP）。机制另有最小 C 探针
  单独证明（裸名搜不到 → 绝对路径预加载成功 → 同一裸名立刻命中），不依赖应用日志。
- **ai-chat 示例：聊天与 Agent 会话分离**：侧栏按当前模式只列本模式的会话
  （聊天 = 直连会话，Agent = cjh 会话及其镜像），各自记住自己的当前会话、切换模式互不顶掉；
  新建会话打上归属标签，存量存档按「有无 cjhId」归类。同步撤掉旧的「聊天模式隐藏镜像」
  补偿提示，页面自检探针改为钉住新行为（两组列表互不可见、切模式不新建会话）。
- **ai-chat 示例：Agent 模式引导卡新增「一键部署并启动」**：仓库自带 cjh 安装包
  （`examples/ai-chat/vendor/cjh/`），引导卡首选按钮走新命令 `cjh:deploy` 完成
  「SHA256 校验 → 解包到 `~/.local/share/cj-ai-chat/` → chmod → 拉起」全链路，
  不走网络、不需要手动下载；失败如实报错（校验不过不落盘，二进制与本机不兼容等
  原因各有一句话）并回落原手动路径（下载页地址在引导第 2 步明示）。服务商配置
  （地址 / 密钥 / 模型）本就随每轮对话帧下发给 cjh，引导文案同步说明。
  注意：vendor 里的 cjh 产物已按 cjh `a3e1e6e` 的 `dist/cjh-linux-x64` **重建**（cjh 仓当时的
  tar.gz 没跟着重打，里面还是要求 `GLIBC_2.38` 的旧二进制，Ubuntu 22.04 的 2.35 起不来）——
  重建后只需 `GLIBC ≤ 2.34`。换包必须同轮更新 `vendor/cjh/SHA256SUMS` 与 `src/cjh_host.cj` 的
  `CJH_BUNDLE_SHA256`，漏任何一处都是「校验失败，不部署」。
  另：`examples/ai-chat/dist-linux/ai-chat-linux-x64.tar.gz`（`scripts/pack-linux.sh --tar` 产物）
  随仓分发——不装 SDK / 不编仓颉的人解包即用，与 `dist-single/` 的 exe 同一约定；目录本体仍不入库
  （`.gitignore` 为此把 `**/dist-linux/` 改成 `**/dist-linux/*`，否则目录级排除会让 `!` 例外失效）。
- **ai-chat 示例：出网白名单补入实际要用的服务商主机**：`capabilities/app.json` 的
  `scopes.http.allow` 增列 `ai.novacode.top`（第三方聚合端点）。白名单读的是**启动时扫描的静态能力清单**，
  页面侧「添加模型」改不了它——填了名单之外的主机会被 scope 挡住并回业务错误
  `http: host is outside the authorized scope`；名单之外的主机走下面的**运行期加白**（人确认后放行）。
- **白名单的运行期加白（RFC-003 补充）**：新增 `TauriApp.allowScopePattern(plugin, pattern)` 与
  `TauriApp.isScopeAllowed(plugin, value)`——应用**取得用户明确确认后**当场放行一个不在清单里的主机 / 路径。
  判定口径不变（**先 deny 后 allow**，运行期加白掀不掉清单里的 `deny`），叠加项只在内存里、重启即空，
  持久化由应用自己决定；清单没给该插件写 scope 时不叠加（那种情况本来就是全量放行）。
  本仓首个消费者是 `examples/ai-chat` 的 `app:allowHost`：保存服务商时用 Base URL 的主机名问一次，
  弹**原生确认框**（页面调不了原生对话框，被注入的脚本也就无法自行加白）——确认即
  「本次会话立刻可用 + 追加到 `~/.local/share/cj-ai-chat/allowed-hosts.txt`」，启动时在 `run()` 之前重放。
  `allowScopePattern` 返回 `Bool`，**注册中心只收具体值**：空串或含 `*` / `?` 与制表/换行的模式当场拒并回
  `false`（一个通配透传进来就等于全放行——这条不变量由注册中心强制，应用绕不过去），应用侧再按主机名字符集校一遍；
  端口与路径不进名单（判定按主机名）。被 scope 挡住时页面会直接把确认框推到人面前，不必自己去找清单。
- **ai-chat 示例：Agent 模式下桌面端选中的服务商同步进 cjh 基线**：切到 Agent、保存服务商、
  切换到某个服务商，以及**每次连上 cjh** 时，都 `POST /api/settings` 把当前的 `baseUrl` / `model` / `apiKey`
  写进 cjh 自己的配置（cjh 侧立即生效，`base_url` / `model` 落盘 `~/.cjh/settings.json`）。
  原先只有「每回合 chat 帧带上这份配置」——帧只管桌面端发出的那一回合，cjh 自己发起的调用（后台任务、
  工具链里的补充请求）与 Agent 徽章显示的模型用的都是它自己那份，于是界面上并排出现「两套值」而没人知道
  （2026-10-20 用户提问推动：切 Agent 到底有没有同步）。载荷只带**非空**字段——cjh 侧 `baseUrl` / `model`
  是直接赋值，发空串等于把它的配置清空；`apiKey` 为空或含掩码时一律不发（GET 会把 Key 掩成
  `sk-e****493a` 这类，回写就等于把真 Key 换成几颗星）。自检 / 探针模式下一律不发（自检会拿假服务商
  走一遍保存与切模式的路，真发出去会污染用户 cjh 的配置），载荷形状另由纯函数断言守着。
  **cjh 侧的缺口已提 `cjh#6`**：`POST /api/settings` 的 `apiKey` 只进内存——`saveAll()` 只写
  `base_url` / `model`，而 `/provider` 命令走的 `saveApiKey()` 写的是 auth.json，两条路都不报错地回 `ok`。
  桌面端的兜底正是「每次连上都重推一次」，所以 cjh 重启后也自动收敛。
- **鸿蒙（HarmonyOS）ArkWeb 宿主真机落地**：`cj-tauri` 首次在 HarmonyOS 真机上跑通
  「仓颉后端 + ArkWeb 前端 + IPC 双向桥」闭环——页面 `system:version` 拿到
  `{"name":"cj-tauri","version":"1.0.0","protocol":"1","cangjie":"1.0.5","platform":"ohos"}`，
  应用自注册命令（`probe:log`）同链路可用，同轮 `SIGSEGV` 计数 0。
  三条硬约定随之确立：**框架包零 ArkUI 依赖**（`@Component` / `Web` 一律留应用侧，
  框架包引用 ArkUI 会让鸿蒙包初始化链跳坏地址、启动即崩）、**回投改由原生推**
  （`javaScriptProxy` 的返回值传不回 JS，页面改成发 `{"type":"pull"}` 心跳、
  原生在 `post` 回调里 `runJavaScript` 推送）、**`aboutToAppear` 同步宿主页面地址**
  （`build()` 组件字段还是空串，会白屏死锁）。判据与踩坑见 `docs/鸿蒙ArkWeb接入踩坑.md` §8.1。

- **鸿蒙多窗口 label 路由真机取证**：同一份 HAP 同时挂两扇 ArkWeb 窗口（`main` / `second`，
  页面按 label 分文件 `cj-tauri-<label>.html` 落盘），两窗各完成一次 `system:version` 往返；
  跨窗**定向**投递双向成立（`probe:hello` → 对面窗的 `probe:ping` → `probe:log`），
  每条报文里原生归属 `window=` 与页面自认 `me=` **逐条恒等**——这就是「不串台」的判据。
  同轮 `SIGSEGV` / `panic` / `fatal` 与 `command not allowed|registered|rejected` 计数均为 0。
  宿主能力位**仍全 0**（菜单 / 托盘 / 快捷键 / 拖放 / 对话框 / 剪贴板 / 通知都还没有实机证据）。
  过程与两条新踩的坑见 `docs/鸿蒙ArkWeb接入踩坑.md` §8.2。

- **鸿蒙对话框落法定稿：命令式 API 全部不可用，改用声明式 overlay**：真机实测确认
  `UIContext.showAlertDialog` 与 `PromptAction.showDialog`（含 `workerthread: true`）在
  `javaScriptProxy` 回调的同步栈上调用时**静默丢弃**——不抛异常、立即返回、不画窗、回调不来；
  同一个 `showDialog` 从原生 `Button.onClick` 调却正常弹出（同 tid `6549`，故与线程无关），
  把调用 `spawn` 到工作线程也无效。最终落法为 **`@State` + `build()` 条件渲染的声明式 overlay**
  （`examples/ohos-probe/entry/src/main/cangjie/index.cj`），同一台机器当场走通：
  hilog 出现 `dialog take` → `dialog present` → `declarative dialog answer` → `dialog answer` 完整链，
  页面回执 `confirmed=true`，`.buildlog/dlg8.jpeg` 实拍卡片在屏。
  框架侧 `hostCapabilities()` 的对话框能力位**仍报 0**（本轮通的是应用侧 overlay，不是宿主能力）。
  判据与两处 API 形状坑（`padding` 四参无默认值、`Text`/`Button` 按 class 声明）见
  `docs/鸿蒙ArkWeb接入踩坑.md` §10.11。

- **`examples/ai-chat` 一轮 UI 大改造（用户实测清单 11 项，全部落地）**：浅色主题下的「黑块」、
  看不见的工作区、停不下来的生成一并收口。改动与判据：
  - **Markdown 渲染修好**：代码块样式原先**写死暗色**（`#0c0e14`），浅色主题下就是一块黑——改走主题
    变量；块级解析补齐表格 / 有序无序列表 / 引用 / 分隔线 / 多级标题，行内码 / 加粗 / 链接白名单
    （`^https?://`）沿用「先转义再放行受控标记」的口径（模型输出是不可信内容）；
  - **代码高亮按真实类名重写**（原 `.k` / `.s` / `.c` / `.n` 是死规则，hljs 从不产这些类），语法配色
    全走变量；**紧凑模式与主题三态可共存**（合成后一次落盘）；
  - **接上 cjh 工作区 API**（`GET/POST/DELETE /api/workspaces` + `POST /api/workspaces/switch`）：
    `http` 插件为此新增 **`http:delete`**（带 body 的 DELETE），能力清单同步放行——不放行时点删除
    只会得到 `command not allowed`；cjh 侧工作区不可用时前端如实提示；
  - **安全加固**：`spawn` `cjh web` 显式 `--bind 127.0.0.1`——cjh 默认 `--bind 0.0.0.0` 且不带 token，
    不改等于把本机 agent 后端摊给整个局域网；
  - **停止生成**只置中断标记并把已到文本落地（cjh **没有** WS 中断消息，除断连之外没有真叫停服务端
    那一轮的办法，页面上就这么写，不假装能停）；工具调用 chip（running / done / error / stopped）与
    时间戳外挂在 body 之外，不被流式 `innerHTML` 冲掉；
  - **文件面板**：面包屑（点任意一级回跳）+ 点击预览（走自家 `fs:readText`——cjh 没有 `/api/fs/read`），
    预览读的是 `scopes.fs` 允许范围内的路径，越界由插件拒（实机断言 `pv-scope-deny`）；
  - **会话搜索 + 行内重命名**：搜索命中标题**与正文**（只搜标题会漏掉「标题还叫新会话」的会话）；
    改名 Enter 提交 / Esc 取消 / 失焦提交；**cjh 会话历史那组不给改名删**——`/api/sessions` 至今只读，
    与其摆个点不动的按钮，不如把口径写进分组 tooltip；
  - **侧栏收起（顶栏 ☰ / Ctrl+B，随存档持久化）、输入框按内容长到 200px 封顶、Ctrl+K 搜会话、
    Ctrl+Shift+N 新会话**；
  - 页面自检 **17/17 → 25/25**（新增 8 条：`conv-search` / `conv-rename` / `side-toggle` / `side-restore` /
    `input-grow` / `theme-auto-class` / `theme-os-wired` / `theme-compact-coexist`——断言完均恢复现场并落盘，
    免得探针把假数据写进 store），另有文件预览 5/5、`CJH-PANELS` 4/4、`CJH-CHAT` PASS；
    框架与应用 `cjpm build` 零警告、单测 277/277、静态门禁全 ok。应用链接期曾缺
    `-lcjTauri.plugins.fs`（插件包不进应用的 `-l` 列表，报一串 `undefined reference to
    _CGP18cjTauri.plugins.fs…`，看着像源码错、实为链接参数），本轮显式补进应用 `cjpm.toml`。
- **http 插件：页面可控的出网口终于有了白名单（RFC-003 HTTP 白名单收口）**：
  `http:get` / `http:post` / `http:postStream`（权限集 `http:default`），出网主机白名单写在
  能力清单 `scopes.http`（`"allow": ["api.deepseek.com", "*.openai.azure.com"]`——判定复用共享层
  `scopeAllows`/`globMatch`，**没写 scopes.http = 一律拒绝**，出网面不做「没写就放行」）；端口不参与
  匹配、userinfo 不许伪造、Host/Content-Length 头不许页面自带、**禁自动重定向**（3xx 原样回给页面，
  要跟就页面显式再过一遍白名单）、响应体上限 8 MiB 截断如实标记。`IpcContext.scopeRuleFor` 新增：
  scope 规则本体直达插件，给「匹配语义不是文件路径」的插件用（http 把模式当主机名匹配，不走路径
  规范化）。
- **`http:postStream`：SSE 流式（AI 对话客户端的管道）**：命令 worker 按块读响应体、每块经
  `http:chunk` 事件回投（**每条都 `emit`，不能用 `emitLatest`**——后者按「同帧只保最新」会把中间
  增量整块吞掉，实测流式只剩最后一截）；**UTF-8 多字节被块边界切开时尾字节留到下一块拼齐再发**；
  结束发 `done=true` 末条，命令 resolve 总字节数。SSE 帧解析留在前端
  （宿主只回投字节），OpenAI 兼容 `data:` 行 / `[DONE]` 由应用自己拼。
- **`ws` 插件：长连接出网口（与 `http` 插件同一套白名单语义）**：`ws:connect` / `ws:send` /
  `ws:close` 三条命令（权限集 `ws:default`）+ `ws:frame` / `ws:state` 两个事件；出网主机白名单写在
  能力清单 `scopes.ws`（**没写 = 全拒**，与 `scopes.http` 同构）；握手用 stdx 自带的
  `WebSocket.upgradeFromClient`——**不手写 RFC6455**（该函数的 scheme 必须原样是 `ws://` / `wss://`，
  最初自己把 ws 转成 http 再传，反被库以 "the scheme must be ws or wss" 拒掉，实测踩过）。
  主机提取与 http 插件共用核心共享层 `src/urlutil.cj` 的 `urlHostOf`（**一份实现**，禁止两个插件
  各写一份）；对端断开经 `ws:state`（`closed`）如实回投。单测 `plugin_ws_test.cj` 3 条。
- **示例 `examples/ai-chat` 升级为 cjh 的桌面客户端（第五款工具）**：
  多会话 + 多服务商（自定义 Base URL / API Key / 模型 / system 提示词，Key 存本机 store）、
  流式 Markdown 渲染（先转义再放行受控标记——模型输出是不可信内容，链接 href 只放行 http(s)）、
  托盘 + 全局快捷键 Ctrl+Alt+A + 最小化到托盘 + 日志落盘（`setLogToDefaultFile`），
  **零新命令**。升级后接上 **cjh**（用户的另一个 AI agent 项目）：`src/cjh_host.cj` 只管生命周期——
  发现二进制（`CJH_BIN` / PATH / 常见安装位，可配）→ HTTP 健康检查（**已在跑就复用，不重复起**）→
  不在跑才按需 `spawn` `cjh web` → 退出收尾只收自己启的那个；**数据面零新命令**，聊天流式走 `ws`
  插件、会话/技能/MCP/文件四面板全走 `http` 插件（`/api/sessions`、`/api/skills`、`/api/mcp`、
  `/api/fs/list`）。Linux 实机（Xvfb）跑通并截图 `docs/images/example-ai-chat.png`：页面自检 **17/17**，
  另加 `CJH-PANELS` 4/4 与 `CJH-CHAT` PASS（deltas=1 done=1 err=0）两条独立探针行；
  修掉 `loadFiles` 的一处形状错——cjh 的 `/api/fs/list` 回 `{dirs, files}` **两个数组**，早期只读
  `items`/`entries`/`files` 会把目录整个丢掉（文件区能列出文件、却一个目录都下不去）；
  MCP 面板**先做只读**（cjh 的 settings 暂不支持写 `mcpServers`，面板里如实注明）。
  Windows 未实机验证（如实说明）。
- **日志落盘：GUI 单文件产物终于有了「双击也能拿到凭证」的出口（RFC-003 第 5 期）**：
  `TauriApp.setLogFile(path[, maxKB, keep])` / `setLogToDefaultFile(appName)` 在 `start()` 之前开日志，
  仓颉侧 `eprintln`、C 桥与平台实现的诊断全落进**同一份文件**——接管发生在 **fd 级**，两侧上百处调用点
  一处都没改；另有 `CJ_TAURI_LOG` / `CJ_TAURI_LOG_MAX_KB` / `CJ_TAURI_LOG_KEEP` 三个环境变量兜底，
  已经分发出去的 exe 改不了代码，报障时带一个变量重启就能取证。超预算轮转 `.1` … `.keep`
  （**先拷贝再截断**，不 rename 打开中的文件，两平台同一套代码）；`system:host` 增 `logFile` 字段回读
  生效路径（空串＝未开）；**不新设能力位**（恒为真的位没有信息量），也不做按级别过滤（接管对所有
  stderr 写者一视同仁）。配套 `log` 插件（`log:write` / `log:path` + `log:default` 权限集）让页面
  `window.onerror` 也并进同一份文件。桩自检 214 项 + 框架单测 267 项全绿；Linux 实机 E2E 两轮 8 条断言
  （`dist/e2e-evidence/linux-logfile.json`、`linux-logfile-rotate.json`）。Windows 侧本轮只保证共享层与
  桩自检通过——**没有实机就写没有**。

- **新增《仓颉版串口调试助手开发记》**（`docs/仓颉版串口调试助手-开发记.md`）：这个示例的来路、
  串口与网络两条链路各自怎么落（枚举/参数面板/轮询收 vs 一个命令三种模式）、探针自检 11 步与
  「对端进程说的才算数」的取证方式，以及 Windows 实机上那处**串口读超时失效**的完整定位过程
  （小 C 程序复现 → 平台层修法 → 10/10 变 11/11）与免 SDK 单文件包的复核数字；面向读者，
  不替代示例 README。

- **`examples/cj-link` 可在 Windows 上直接运行并打成单文件 exe（免 SDK 分发）**：示例补 `run.bat`
  （`build` / 起窗 / `selfcheck` 三档，判绿口径是「日志里没有 FAIL 行」）与打包存根
  （`src/packed_assets.cj` 空存根 + `src/packed_resources.cj`，前端页面 `ui/index.html` 与能力清单
  统一「内嵌优先、否则读盘」——源码树里改页面即生效，打包后页面进二进制、产物只有一个 exe）。
  产物 `examples/cj-link/dist-single/cj-link.exe`（5,745,664 字节、`Subsystem=00000002`、
  导入表 8 个 DLL 全是系统库：msvcrt / KERNEL32 / WS2_32 / SHELL32 / dbghelp / comdlg32 / USER32 /
  ole32）实机验证：标题「cj-Link · 串口/网络调试助手」、1180x780、串口枚举 2 个端口，
  探针自检 **11/11**（串口 / CRC 标准向量 / TCP / UDP 全活）。**串口那侧走的是真线**：本机
  COM1↔COM2 是一对互通的虚拟串口，对端用 `System.IO.Ports` 拿 COM2「收什么回什么」，对端日志留
  报文级凭证（收到 12 字节 `cj-link-ping`）。Windows 的探针对端因此拆成两个进程（python 管
  TCP/UDP echo、PowerShell 管串口 echo）——Linux 那份 `cj-link-peer.py` 靠 pty 扮演串口，
  Windows 没有 pty。

- **`examples/leetcode-gui` 可打成单文件 exe（免 SDK 分发）**：打包侧新增 `src/packed_assets.cj`
  空存根与 `src/packed_resources.cj`，页面 / CodeMirror vendor / 能力清单统一改成「内嵌优先、
  否则读盘」；`scripts/pack-win-single.sh` 的 vendor 清单改为「示例自带 `ui/vendor/pack-files.txt`
  就按它逐行打，否则沿用默认 5 份」。产物 `examples/leetcode-gui/dist-single/leetcode-gui.exe`
  （10.2MB、`Subsystem=00000002`、导入表 0 个非系统 DLL）实机验证：标题「仓颉力扣  cj-tauri」、
  题库「100 题」、CodeMirror 带行号与高亮（未降级为 textarea）、「参考答案」载入编辑器（12 行）、
  判题 3/3 全过（`编译 + 运行 657ms`）。**包内不含 SDK，判题仍要求本机 `cjc`**；进度 / 题包缓存 /
  判题临时目录都落在**启动时的工作目录**下——放在任意空目录里跑即可，不与他人进度串数据。

- **新增《仓颉版力扣 GUI 开发记》**（`docs/仓颉版力扣-GUI开发记.md`）：这个示例的来路、判题链路、
  题库 19 → 100 的扩量与两层自检、题包号段，以及一路踩到的坑与判据；面向读者，不替代示例 README。

- **`examples/leetcode-gui` 内置题库 19 → 100 题，参考答案改为「随题内嵌」**：新增 81 道网络经典题
  （数组与双指针 / 字符串 / 二叉树 / 动态规划 / 哈希与计数 / 栈与队列 / 贪心 / 链表 / 递归与回溯 /
  二分与排序 / 位运算与数学共 11 个分类，难度 简单 45 / 中等 53 / 困难 2），每题带 `template`
  与 3 条用例；**参考答案从 `src/solutions.cj` 迁进题库 JSON 的 `solution` 字段**
  （`SolutionCommand` 按 id 从题库取，`solutions.cj` 退役），远程题包因此也能自带解答。
  远程题包 `advanced-1` 的 8 题 id 从 100–107 挪到 200–207（合并仍按 id 覆盖，避开内置 1..100），
  题包校验的 id 下限从 100 提到 200。108 题逐题过「模板 + harness 编译」与
  「答案 + harness 逐用例 PASS」两层批量自检（口径与脚本见示例 README §6）。

- **Windows 托盘 + 全局快捷键真实现（能力位如实置位）**：托盘走 `Shell_NotifyIconW`（图标按
  `SM_CXSMICON` 载入 `.ico`，png 载不动就回落系统缺省图标并出声；菜单是 `CreatePopupMenu`——
  托盘菜单只弹不挂窗口，避开「`SetMenu` 只收 `CreateMenu` 句柄」那条坑），点击按
  `{"kind":"tray","id":…}` 经 on_shell 回投（与 Linux 同信封）；全局快捷键走 `RegisterHotKey`，
  wire 词法与 Linux 同规（Ctrl/Alt/Shift/Super + 常用键名 + Enter/Esc 别名），注册失败（被占用）
  如实打 stderr 且不致命，`WM_HOTKEY` 回投 `hotkey:press`。窗口销毁前 `NIM_DELETE` 摘图标
  （漏摘会在系统托盘留幽灵图标）。至此 Windows 的 `system:host` 报
  `menu=1 tray=1 hotkey=1 dragDrop=1`。
- **窗口可见性 + 最小化到托盘（RFC-003 第 5 期收尾，两平台同时落地）**：新增宿主基元
  `setWindowVisible(visible)`（Windows `ShowWindow`、Linux `gtk_widget_hide/show` + 抬到前台，
  隐藏态 WebView 与页面照常活着）与策略位 `setMinimizeToTray(enabled)`
  （`WindowConfig.minimizeToTray`）：开启后点标题栏「最小化」不再缩到任务栏，而是把窗口藏起来，
  还原走应用自己的托盘菜单 / 全局快捷键。**平台会在最小化那一刻复核托盘是否真的挂上了**
  （能力位不含 `CJ_CAP_TRAY`，或应用压根没 `setTray`）：没装就如实降级为普通最小化并打一行
  stderr——「窗口藏起来却没有还原入口」比「不支持」更糟（Windows 拦 `WM_SYSCOMMAND`，
  Linux 拦 `window-state-event` 的 ICONIFIED）。
- **`examples/clipboard-history` 补齐还原路径**：托盘菜单加「显示面板」（点它或按 Ctrl+Alt+V
  经 `app.onShellEvent` → `setWindowVisible(true)` 把窗口唤回——**窗口级动作只能在原生做**：
  页面在隐藏态照样跑，却没有任何办法把自己显出来），窗口开 `minimizeToTray`；前端补
  「面板已唤出 / 快捷键唤出」状态行反馈（`tray:click` / `hotkey:press` 两条监听）。

- **示例 `examples/cj-link`：串口/网络二合一调试助手（cj-Link）**：串口走官方 `serial` 插件
  （参数面板 + 前端轮询收）、网络走应用级 `link:netConnect/netSend/netClose/netStatus`
  （`std.net`，**三种模式**：TCP 客户端 5s 建连超时 / TCP 服务器本机监听 accept 多客户端（上限 16，
  发送缺省广播可按通道定向）/ UDP 客户端 connect 型收发），收统一经 `link:tcpData` 事件推送
  （报文带 mode/channel/from 区分来源），串口与网络共用一块收发日志（HEX/ASCII 双显、方向分色、
  毫秒时间戳、按方向过滤、TX/RX 计数）；面板配置经 `store` 插件持久化。对端由 `cj-link-peer.py`
  一条进程扮演（串口 pty echo + TCP echo + UDP echo），`run.sh` 自动套 Xvfb 跑探针自检
  （串口 + CRC 标准向量 + TCP + UDP 共 11 步）与 33 条断言，
  两端证据都在应用进程之外。
- **cj-Link 发送增强三件**：**发送队列**（常用报文列表，HEX/TXT 各自标记，点条目即发，
  随 store 持久化）、**校验计算**（`link:crcCalc` 命令算 CRC16-Modbus（低前/高前）/CRC16-CCITT/
  累加和/异或和/LRC，可一键取「整帧+CRC」回填发送框，协议逻辑在仓颉侧）、
  **定时发送周期可调**（50ms–60s 输入框，原来固定 1s）。

- **源码仓 `cjpm.toml` 的 stdx 路径改为环境变量引用（机器无关，issue #3）**：根与 `examples/*`
  共 24 个 `cjpm.toml` 的 `[target.*.bin-dependencies] path-option` 不再写死本机绝对路径，
  统一写成 `${CANGJIE_STDX}`，由 cjpm 按进程环境变量展开——clone 后无需手工改文件即可构建
  （设 `CANGJIE_STDX` 指向 `<stdx>/<三元组>/dynamic/stdx`）。配套联动：`scripts/test.sh`、
  `scripts/e2e/lib.sh`、`scripts/pack-win.sh` 与 CI 的 sdk 作业均补了探测 + `export`;
  CLI 从 toml 读回 `path-option` 时同款展开 `${...}`（`resolve.cj` 的 `expandTomlEnv`）。
  `cj-tauri create` 生成的工程不受影响（脚手架仍把探测到的路径写死进 toml）。
- **Windows 实机 E2E 入口（`scripts/e2e/test-windows-bridge.sh`）**：与 Linux 入口同构（同一
  fixture 探针、同一套公共层与证据 JSON），断言随能力位落地扩到 **11 条**：能力清单加载 / 桥注入 /
  页面→宿主 IPC / 端到端往返 / 未授权命令被拒 / `system:host` 能力位如实上报（`host=windows
  menu=true tray=true dragDrop=true hotkey=true`）/ 剪贴板写读回环（值一致）/ 拖放目标已挂载
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

- **修：Linux 共享库桥编不过（`environ` undeclared）**：`cj_plat_spawn_hidden` 用 `posix_spawn` 收
  进程环境指针，而 glibc 的 `unistd.h` 只在 `_GNU_SOURCE` 下暴露 `environ`——单文件打包器的静态编译
  定义了它、`native/build_linux.sh` 的共享库构建没有，于是同一份源码一边能编一边报
  `'environ' undeclared`。按 POSIX 显式 `extern char **environ;` 声明（标准符号，两种构建都合法）。
- **修：`http` 插件流式分块每轮少移 1 字节，中文长回复偶发整条失败**（`Invalid utf8 byte sequence.`）：
  `takeCompleteUtf8` 把「完整 UTF-8 序列」取走后用 `remove(0..(cut - 1))` 清缓冲，而仓颉的 Range 是
  **右开**的——`0..(cut - 1)` 只移走 `cut - 1` 个字节，上一个序列的末字节留在缓冲里，下一轮拼出的
  字节序列非法，严格的 `fromUtf8` 当场抛异常。改成 `remove(0..cut)`，尾部 `fromUtf8` 补 `try/catch`
  （丢字节也不静默，打一行 stderr 留痕）。**形状值得记住：ASCII 结尾的块少移一字节照样合法，
  只有块边界切在汉字中间才炸**——所以它躲过了所有「跑一遍看看」的检查，是中英文长回复才逼出来的。
  `takeCompleteUtf8` 改 `public` 并在 `src/tests/plugin_http_test.cj` 新增 2 条边界用例
  （`cjpm test` 279/279 PASS）。
- **修：Windows 串口读的 `timeoutMs` 形同虚设（`serial:read` 不等数据、当场返回 0 字节）**：
  打开串口时设的 `ReadIntervalTimeout=MAXDWORD` + 两个 total 全 0 是「立刻交回已有字节」语义——
  缓冲里没数据时驱动当场把请求完成成 0 字节、`ReadFile` 返回 TRUE，C 桥里那条「等 OVERLAPPED 事件
  最多 timeout_ms」的分支**根本进不去**（按同一套参数写的小 C 程序复现：预算 1000ms 的读 0ms 就
  交回 `got=0`）。表象是 `serial:read` 只返回「恰好已经躺在缓冲里」的字节，前端只能靠高频轮询碰运气；
  示例自检里串口那步读回 0 字节、`rx text=` 与 `close` 两条明细直接消失（10/10 而不是 11/11）。
  修法：预算**按每次调用**用 `SetCommTimeouts` 逐次下发给驱动（`ReadIntervalTimeout=0` +
  `ReadTotalTimeoutConstant=预算`）——有第一个字节立刻完成、没有就等满预算，与 Linux 的 `poll`
  同一口径；只有预算为 0 才用「立即返回」那套，`WaitForSingleObject` 留作兜底。
  复现前后探针 10/10 → **11/11**（串口 `read` 拿回 `hex=636a2d6c696e6b2d70696e67`）。

- **修：`examples/leetcode-gui` 的判题产物在别的机器上「编译成功却起不来」**：判题产物原本是
  **动态链接**，运行期由 loader 按 PATH / 系统目录解析仓颉运行时 DLL——命中别代运行时时 ABI
  名字对不上，报「无法定位程序输入点 `CJMCC_ExclusiveScope`」（本 SDK 的运行时导出的是带下划线的
  `CJ_MCC_*`），进程连 `main` 都进不去、stdout 与 stderr 全空，页面上看着像「运行没反应」。
  同一份判题源码在本机跑出 3/3 PASS、换一台机器（或换一次 PATH）即失败。修法：判题编译显式带上
  `--static --static-std --strip-all`（`commands.cj` 的编译命令一处，示例 README §4/§5.1/§6
  同步），产物与运行期 DLL 彻底脱钩——实测只给 `C:\windows\system32;C:\windows` 也能跑出 3 条
  `RESULT PASS`；`--strip-all` 把静态产物从 25MB 压回 2.7MB（动态版 2.1MB），编译缓存体积与
  从前相当（冷编译约 0.4~1 秒）。

- **修：判题编译参数变了、旧缓存仍被回放（表象是「升级了版本还是同一个错」）**：判题产物缓存在
  `target/leetcode/cache/<哈希>/judge.exe`，而哈希只取**源码**——上面那条把判题改成静态链接之后，
  旧版本编出的**动态**产物在升级后的应用里照样命中，用户端看到与升级前一模一样的失败。现在缓存键取
  「源码 + 编译开关签名」，开关定义收敛到 `commands.cj` 的 `JUDGE_COMPILE_FLAGS` 一处（新增/调整
  开关不必再手工清缓存，旧条目自然失效）。判据（本机实测，隔离目录里把旧键的产物换成 31 字节的假
  文件）：不修时旧版本会 `compile cache hit` 到那个旧键，修后同一份提交**不再命中旧键**、重新编译出
  2753024 字节的静态产物（导入表只有 `KERNEL32/WS2_32/dbghelp/msvcrt`）、判题 3/3 通过，假产物
  毫发无损。

- **修：`examples/leetcode-gui` 的判题在单文件包上必失败（顶层 `target` 没建）**：判题工作目录是
  `target/leetcode/<题号>-<时间戳>-<序号>/`，建目录时只建了下面那一级，顶层 `target/` 依赖
  「构建树里本来就有」——示例正常构建时它天然存在，于是开发期从没暴露；从空目录启动的打包产物报
  `建判题目录失败：FSException: Failed to create directory 'target/leetcode/1-44097-1', parent
  directory 'target/leetcode' does not exist`（而第一层 `Directory.create` 的失败还被空 `catch`
  吞掉，报出来的是第二层，指向一个看起来不可能的原因）。现在逐级显式创建（先 `target` 再
  `target/leetcode`），仓库内行为不变；打包产物上复验判题 3/3 通过。

- **`examples/leetcode-gui` 的判题在 Windows 上静默全灭**：判题产物由 `cjc main.cj -o judge` 编译，
  而 cmd.exe 的命令解析只认「名字 + PATHEXT」——对无后缀的 `judge` 既不匹配裸名，也不认
  `.\judge` 这种带路径写法（实测两种写法都报「不是内部或外部命令」，与文件权限无关）。于是每次点
  「运行」都死在跑 harness 那一步、stdout 为空，页面只能显示「(程序输出，无判定行) / (空)」——
  而编译明明是成功的（耗时照常报出），失败毫无凭证。修法是把产物名按平台分叉
  （新增 `judgeExeName()`：Windows `judge.exe` / Linux 不变），**编译 `-o`、编译缓存路径、
  `cmd`/`sh` 的调用行三处同源**（三处漏一处即回归静默失败）。实测：题 1 参考答案
  `judge id=1 exit=0 stdoutBytes=45`（三条 CRLF 的 `RESULT n PASS`）且 `solved=true`；
  题 107. 课程表 参考答案 3/3 全过，页面逐条打出 `✓ 用例 n 通过 canFinish(…) == …`。
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
- **Windows 实机 E2E 入口的两处静默失败（跑起来才发现，断言全灭而看不出原因）**：
  ① `lib.sh` 只给 `CANGJIE_STDX` 转了 POSIX，`CANGJIE_HOME` 没转——本机环境给的是盘符形式
  （`D:\Program Files (x86)\Cangjie`），拼进 PATH 后被 MSYS 按「冒号即分隔符」切碎（拆成 `D` 与
  `\Program Files...`），依赖运行时 DLL 的产物**启动即退、一行输出都没有**；
  ② 同文件在 Windows 上只**在 `CANGJIE_STDX` 已导出时**才把 stdx 目录放进 PATH，没设环境变量时连
  探测都没有（Linux 分支本来就会探 `~/.cangjie/stdx/*`）——缺 `libstdx.*.dll` 的表象与①一模一样。
  现在两边都先探测再进 PATH，且探测不到时明确打一行「找不到 stdx 动态库目录」并失败，不再让
  「应用没起来」冒充「功能不对」。
- **`scripts/test.sh` 的 Windows 分支只把 stdx 放进 PATH、从没 `export CANGJIE_STDX`**：cjpm 按
  **进程环境变量**展开 `cjpm.toml` 里的 `${CANGJIE_STDX}`，没导出就收到空值，报的却是
  `root package 'cjTauri' imports package 'stdx.encoding.json' … not added as a dependency in cjpm.toml`
  （看着像 toml 漏配）。本机新开会话直接 `bash scripts/test.sh` 必炸，只有先手工导出过才过。
  现在探测到就 `export`，探测面也从写死一个路径改成 `/d/cangjie-stdx/*/dynamic/stdx` 与
  `~/.cangjie/stdx/*/dynamic/stdx`。
- **`scripts/e2e/test-windows-bridge.sh` 的产物新鲜度检查形同虚设**：`ls -t src/*.cj` 给的是**相对名**，
  拿它去比绝对路径的产物永远判「不比它新」（一条永不触发的检查）；且只盯探针自己的源码——探针静态链
  的是框架，改框架不动探针源码时照样跑旧产物（本轮 `src/host.cj` 给 `system:host` 补了 `hotkey` 字段，
  页面读到 `hotkey=undefined`、那条断言假红一轮）。改绝对路径比较，并把 `$E2E_ROOT/src/*.cj` 一并计入。
- **两条软链接 scope 单测在无符号链接特权的 Windows 上如实跳过**：建链被系统拒（错误 1314）时
  打一行 `[skip]` 说明后返回，不再误报 ERROR（判定面由 Linux 轮覆盖）。
- **`host_webkit.cj` 的 `std.collection.*` import 改限定名**：Windows 侧报 unused 警告、Linux 侧
  必须要用——文件级 import 改 `std.collection.ArrayList` 限定名，两平台都零警告。

### Added

- **鸿蒙 PC 脚手架 `cj-tauri create --template ohos`（`cli/templates/ohos-pc/`）**——桌面模板那套到了鸿蒙侧
  不成立：鸿蒙没有「自己起进程跑一个 main」这回事，窗口归 ArkUI、页面归 ArkWeb。新模板把这一层的正确形状
  固化下来：`main_ability.cj`（沙箱目录 → 非 UI 线程 `spawn { startTauriApp(...) }` → 等宿主登记 → `loadContent`）、
  `index.cj`（ArkWeb 宿主组件 + `javaScriptProxy` 双向桥，必须住在**应用模块**里）、`app_host.cj`（框架装配与
  demo 命令）、`entry/cjpm.toml`（源码依赖 `cjTauri` + `aarch64-linux-ohos` 目标段）、
  `module.json5`（`deviceTypes: 2in1` + `ohos.permission.INTERNET`）、`entry/build-profile.json5`
  （`cangjieOptions.checkDeviceTypes: false` 放行 2in1，否则插件只认 phone/tablet 并报 `01103012`）。
  **页面与能力清单是 hap 里 `resources/rawfile/` 的真文件**（Ability 用 `resourceManager.getRawFileContent`
  读成字符串交给框架）：不用像 `examples/ohos/` 那样在构建期把页面 base64 内嵌成生成物，DevEco 里直接点
  Build 也能编过。**签名与证书不入模板**（调试证书与华为账号绑定、跨机器不通用），首次在 DevEco 里配自动
  签名；`build-hap.sh` 会探测 DevEco / 校验 `DEVECO_SDK_HOME` 与 `NODE_HOME` 是否真存在、给 `--no-daemon`、
  建 stdx 联接、并逐条打失败口径，`--install` 追加 `hdc install` + `aa start`。
  CLI 侧：`create` 新增 `--bundle` / `--label`（缺省由项目名推导，见 `bundleNameFrom`），模板别名
  `ohos` / `ohos-pc` / `harmonyos`；`cj-tauri build|dev|run` 检出鸿蒙工程（`build-hap.sh` +
  `entry/cjpm.toml` 同时在）后**转交工程脚本**而不是自己拼 cjpm/hvigor（`run` = `--install`）；
  `copyTree` 对图片等二进制走字节拷贝——原来的文本通道读到 png 会抛
  `IllegalArgumentException: Invalid unicode scalar value`，create 直接崩且留下半成品目录。
  签名构建与 `hdc install` 已通过（`entry-default-signed.hap` 1 647 178 字节、`install bundle successfully`），
  未签名包 `entry-default-unsigned.hap` 1 576 126 字节。
  **装机开窗已补取证（2026-10-22 解锁后）**：`create --template ohos` 生成的工程 `hdc install` 后
  `aa start` 开窗、页面渲染，hilog 逐行齐全——`host registered after 0 polls label=main` →
  `host pageUrl label=main url="file:///…/cj-tauri-main.html"` → `host initScripts label=main count=1` →
  `page begin label=main` → `page end label=main`；窗口为桌面形态，**默认不干预尺寸**（2026-10-22 用户裁定）：
  系统本来就按桌面形态给一扇约 2/3 屏宽的窗，本机 3120×2080 上初始矩形 `[515 281 2090 1394]`
  （2090×1394 px ≈ 1100×734 vp），模板只打一行
  `main window keeps system default 2090x1394 px at density 190% on screen 3120x2080, rect=[515 281 2090 1394]`
  作凭证、不 resize 也不 moveWindowTo。此前两版自定尺寸一并撤除：屏幕像素 86%×84%（`2683x1747`，几乎占满屏）
  与逻辑 1000×700 vp ×密度（`1900x1330`）——除了「跟平台抢方向盘」之外，更直接的毛病是
  **系统先按默认建窗、resize 紧接着改**，屏上就是「先弹一个尺寸、随即跳成另一个」，观感很怪。
  自定尺寸时要记的两个坑仍在：`resize()` 收 px 不收 vp；`densityPixels` 是 **Float32**
  （`.cj.d` 里看着像 Float64），直接与 `Float64` 相乘报 `invalid binary operator on 'Float64' and 'Float32'`，
  取整数百分比（190）后全程整数运算即无碍。`examples/ohos/ohos-music` 与 `ohos-movie` 同口径同步
  （两示例日志同为单行 `keeps system default 2090x1394 …`，截图人眼确认窗口不再跳变）。
  三条交互在屏上都验过（截图人眼确认、`uitest uiInput click` 点击）：`greet` 往返
  （`invoke OK: Hello, world! 来自仓颉后端（鸿蒙 ArkWeb 宿主）`）、后端事件推送
  （`后端: timer started` + `收到后端事件 tick #5` → 隔几秒 `tick #21`，原生→页面持续推）、
  `system:version` 返回 `{"name":"cj-tauri","version":"1.0.0","protocol":"1","cangjie":"1.0.5","platform":"ohos"}`。
  同轮无 `command not allowed` / `command not registered`、无 SIGSEGV；页面默认态是「等待 invoke…」
  （模板页面没有自动调用，命令往返都是点出来的）——所以这条链路是页面主动发起的，不是宿主自说自话。
- **单文件包可以内嵌「外部程序」了（PE 资源释放，`cj_bridge_extract_assets`）**——cjh 这类
  **独立可执行文件**既并不进静态库、也不在 PE 导入表里，单文件产物过去只能让它落在包外。
  现在示例根放一份 `pack-assets.txt`（一行一个文件），Windows 打包器用 `windres` 把它们编成
  `RT_RCDATA` 资源链进 exe（资源名只能是数字 ID——llvm-rc 不认字符串资源名）；运行期应用调
  `extractEmbeddedAssets(dir)`（`src/embedded_assets.cj`）由桥取出来写盘，幂等：目标已在且大小一致
  就跳过（几十 MB 不必每次重解）。桥不认识任何应用文件名——ID → 文件名的表由打包器生成、
  编译期编进去（`-DCJ_PACK_ASSETS_EMBEDDED`），没有内嵌资源的普通构建如实返回 0。
  `examples/cjnote` 首个接入：`dist-single/cjnote.exe` **32.6 MB**，干净目录双击等价实测——
  cjh 从 `%LOCALAPPDATA%\cjnote\runtime\` 拉起（`spawn hidden: …\runtime\cjh.exe -> pid=…`）、
  `8765 LISTENING`、页面 `CJH ws connected`、可见控制台窗口 0 个。桩自检 228 → 232 项。
- **新增「后台静默子进程」能力：`launchHidden()` / `BackgroundProcess`（`src/process_hidden.cj`）**——
  起一个**控制台程序**但不要那个控制台窗口。C 桥新增三个导出
  `cj_bridge_spawn_hidden` / `cj_bridge_kill_pid` / `cj_bridge_pid_alive`（实现在 core、两平台同名同签名，
  分叉的只有平台原语 `cj_plat_spawn_hidden` / `cj_plat_kill_pid` / `cj_plat_pid_alive`：Windows 走
  `CreateProcessW` + `CREATE_NO_WINDOW` 并把三个标准句柄显式指到 NUL，Linux 走 `posix_spawn` + 自成会话 +
  `/dev/null`）。取舍是**拿不到子进程的 stdout / stderr**（要读输出得另走管道）；句柄口径只留 pid，
  `isAlive()` / `stop()` 都按 pid 走，Windows 的进程句柄当场关掉不占句柄表。桩自检 221 → 228 项。
  平台原语清单随之 21 → 24 个（`native/core/bridge_core.h`）。
- **新增通用单文件打包脚本 `scripts/pack-linux-single.sh`**（与 `scripts/pack-win-single.sh` 同设计：
  示例路径与输出目录都可传参，脚本内无任何示例专属逻辑）：静态链仓颉运行时与 std（`--static --static-std`）、
  框架各包（`--static-libs`），C 桥编成静态归档 `libcjtbridge.a` 直接链进可执行文件，并把页面、`ui/vendor`
  的前端库与能力清单 base64 编进二进制（生成示例的 `src/packed_assets.cj`）。示例侧前置三件套
  `src/packed_assets.cj`（空存根）/ `src/packed_resources.cj` / 至少一份 `capabilities/*.json`——缺哪样就 `die` 说明哪样。
  **判据看产物与启动日志**：`examples/cjnote/dist-single/cjnote` 11 698 576 B；`ldd` 里只剩系统
  WebKitGTK / GTK 那一套（无 `libcjTauri*`、无 `libcjtbridge.so`、无仓颉运行时 DLL）；刻意
  `env -u LD_LIBRARY_PATH` 启动照样起窗口——`set window: title=cjnote — AI 笔记 size=1280x800`、
  `menu applied: items=16 bar=0x… visible=1`、`[cjnote] 能力清单来自内嵌资源（1 份，共 1568 字节 base64）`，
  stderr 49 行无 `not found`。已在 cjnote 与 typing-poem 两个示例上跑通（后者自带 three.js，
  走 `PACKED_THREE_B64` 通道）。两条硬约束说清楚：**系统 WebKitGTK / GTK 没有静态库**
  （发行版里查无 `libwebkit2gtk-4.1.a` / `libgtk-3.a`），所以 Linux 上全静态 ELF 不成立，能静态下来的
  只是「本框架带来的依赖」；产物**不含 cjh**——cjh 是独立进程，按 `vendor/cjh/bin/<平台>/` 找现成二进制、
  运行期不解包，须与产物同级摆放且以该目录为工作目录。用法与两种交付形态的对比见
  `examples/cjnote/README.md` 的「单文件打包（可选）」一节。
- **鸿蒙（HarmonyOS ArkWeb）接入第一段打通：框架核心能在真机 HAP 里执行**——本轮只做到「框架代码跑起来」，
  宿主（`WebViewHost` 的 ArkWeb 实现）仍未落地，能力位如实报 0。实测证据（真机 `3QC0124B20000048`，
  bundle `com.yang.testcj`）：页面 `file://` 加载完成后经 `javaScriptProxy` 回调鸿蒙侧，仓颉侧调到
  `cjTauri` 包里的函数并回投 **`framework: platform=ohos version=1.0.0`**，hilog 里
  `MyAbilityStage onCreated` → `onWindowStageCreate` → `CjTauriProbe` 三条齐全，无崩溃行。
  落地要点：
  - **鸿蒙 entry 模块用 cjpm 源码依赖接框架**（`[dependencies] cjTauri = { path = … }`），
    `hvigor` 的 `CompileCangjie` 直接按 dynamic 根包形态编进来；手工 `-L… -lcjTauri` 也链得过，
    但包初始化登记链不归 cjpm 管，属未维护路径（AGENTS §4）；
  - **修掉一个会让应用一启动就 SIGSEGV 的旧缺陷**：`src/log_bridge.cj` 的三个 `cj_bridge_log_*`
    FFI 原本按「桌面两平台同名导出」口径不写 `@When`，而无 C 桥的平台（鸿蒙）没有实现，
    模块里就留成未解析符号、加载期直接崩（表象是白屏 / 秒退、hilog 里连 `AbilityStage.onCreate` 都没有）。
    现在 FFI 与薄包装统一按 `@When[arch != "aarch64"]` 门禁，鸿蒙侧如实降级：
    `enableLogFile` 返回 false 并留一行 stderr、`currentLogFilePath` 回空串、`writeLogLine` 返回 false
    （**不落盘就说没落盘**，能力位口径不变）。桌面两平台行为零变化；
  - `src/host.cj` 的「无 C 桥平台」提示变量 `HOST_ROUTE_WARNED` 的声明随其使用点一并进 `arch` 门禁，
    桌面侧不再有 `unused variable` 警告（零警告门禁）；
  - 完整踩坑过程（判据命令、被数据否定的三条弯路、hvigor 与签名断点、真机 hilog 取证方法）
    单独沉淀在 `docs/鸿蒙ArkWeb接入踩坑.md`，`AGENTS.md` §4 只留判据。
- **`examples/ohos-probe/`：鸿蒙宿主验收台入库**（此前是仓库外的临时 DevEco 工程 `TestCj2`，换机器就没法接着跑）：
  DevEco 工程（hvigor 打 HAP）+ 仓颉侧 ArkWeb 宿主，装到真机就自跑一轮闭环并只往 hilog 打结论
  （桥注入 / `system:version` 往返 / 多窗口 label 不串台 / 原生对话框）。入库只带源码、`README.md`
  与 `.gitignore`——实验备份、截图、hilog、本机 `local.properties` 与构建产物都不进仓库，
  框架走 `../../..` 源码依赖，stdx 与 DevEco 路径改用环境变量。
  配套 `build-hap.sh` 把 headless 构建的三个断点一次补上：`DEVECO_HVIGOR_CANGJIE_PLUGIN` 定位仓颉插件
  （缺它 hvigor 只报 `cangjieOptions` 不是合法属性）、环境里预置的无效 `DEVECO_SDK_HOME` 校验后回退、
  鸿蒙版 stdx 走**相对路径 + 工程内联接**（`entry/cjpm.toml` 写 `../stdx`、工程根的 `stdx` junction
  由脚本按 `CANGJIE_STDX_OHOS` 建且不入库）。最后这条是踩过一轮才定型的：hvigor 只替换自己的模板变量，
  写 `${CANGJIE_STDX_OHOS}` 会变空串、连带整条 `path-option` 失效，报错却是「stdx 未加进 cjpm.toml
  依赖」；而「脚本替换成绝对路径 + `trap` 还原」只治命令行那一路，DevEco IDE 点 Build 仍报同一条错。
  判据与弯路见 AGENTS §4 与 `docs/鸿蒙ArkWeb接入踩坑.md` §10.6 / §10.7。
- **宿主新增「标题栏副标题」能力（`WebViewHost.setTitlebarSubtitle` / `cj_bridge_set_titlebar_subtitle`，
  能力位 `CJ_CAP_SUBTITLE` = 32）**：一行文本画在原生菜单栏**同一行的右侧**，应用据此把自己的页面顶栏
  整行让出来（标题 / 保存状态 / 字数挂在原生那一行），界面高度少一层。语义与判据：
  - **Linux 真画出来了**：窗口第一层竖向 box 里套一层水平 box——菜单栏 pack 到左、label pack 到右；
    两者都没有时整行隐藏（空标题行不许凭空占高度，沿用「空菜单栏不留空条」的约束）。桥的凭证行
    `[cj-bridge] titlebar subtitle: "…" topbar_visible=1` 是**回读文本 + 整行显隐**，不是「我调过了」；
  - **Windows 如实降级**：系统菜单（`SetMenu`）那一行没有自绘区，导出同名同签名但返回 `-4`、能力位
    不置位、只打一行 stderr——应用据能力位决定画不画自己的顶栏，别在没这能力的平台上删了顶栏没替代；
  - **运行期能力、允许高频更新**：每次编辑都可能改（字数），调用方线程不限，Linux 侧一律投 `g_idle`
    到 GTK 线程再碰 widget；core 做参数校验（`NULL` / 超过 1024 字节返回 `-1`，且**不透传平台**），
    建窗之前调用返回 `-3`（不像 `setMenu` 那样记 pending）；
  - `system:host` 的 JSON 多一个 `subtitle` 字段；桩平台自检 187 → 221 项（超长拒绝、
    「被拒不透传」两条是新增判据）。
- **生态项目 `cjnote` 进 README 与官网**（独立仓库 <https://atomgit.com/qq8864/cjnote>，**不在 `examples/` 里**）：
  `README.md` / `README_EN.md` 的示例一览新增「生态项目」小节与两屏实机截图（`docs/images/example-cjnote.png` /
  `example-cjnote-menu.png`），官网示例轮播加一屏 `assets/screenshots/cjnote.png`（同时把该区标题与轮播提示的
  屏数 19 → 20 一并改掉，别让数字与实物对不上）。它不是框架能力的增量，而是能力面的**外部证明**：
  原生菜单 + 副标题（页面顶栏整行让出）+ 三态视图 + AI 流式 + 外部草稿，全部由 `examples/` 之外的应用
  自己走通——AGENTS §2 里「能力位与宿主回调」那套约定在第三方应用身上同样成立。

### Changed

- **`examples/cjnote` 随包 cjh 升到官方 v1.5.3**（Linux 二进制与 Windows 自包含包一起换，
  `vendor/cjh/SHA256SUMS` 按新件重写 16 行）：隔离 HOME 实测 `{"status":"ok","version":"1.5.3"}`、约 2 秒应答。
  随包口径不变——应用按 `vendor/cjh/bin/<平台>/` 找现成二进制、运行期不解包，所以 `bin/` 树必须真在盘上。
- **`examples/ai-chat` MCP 面板撤掉「编辑配置」入口，回到只读**（2026-10-20 用户裁定）：要改 MCP
  配置直接改 cjh 自己的 `settings.json` 更直接，也绕开 GET 掩码 `***` / POST 整体替换那套容易把
  真实密钥抹成三个星号的坑。`mcpEditGuard()` 留在页内自检里继续钉住「掩码拒发 / 坏 JSON 拒发」，
  但不再接任何入口——校验逻辑仍有价值，通道撤销。

- **鸿蒙侧的 JS 字符串转义下沉到共享层，并被单测锁住**：窗口 label 注入的转义逻辑原先叫
  `jsonQuote`、住在 `src/arkweb_script.cj` 里且带 `@When[env == "ohos"]` 门禁——**桌面 `cjpm test`
  根本编不到它**，而它失效是静默的（生成的脚本当场语法错误 → 页面里 `__CJ_TAURI_LABEL__` 停在
  默认值 `main` → 按 label 过滤的事件全部失灵，宿主与页面两边都不报错）。现下沉为
  `src/jsutil.cj` 的 `jsStringLiteral`（不带平台门禁、`public` 供跨包单测），
  `src/tests/jsutil_test.cj` 用 7 条用例钉住反斜杠 / 双引号 / UTF-8 字节 / 空串 / 两者相邻 / 控制字符不加工。
  **真机复验**（真机 `3QC0124B20000048`，框架改动后重编 HAP）：`page begin label=main`、
  `probe:log <- {"version":"…\"platform\":\"ohos\"}"`、同轮 `SIGSEGV` 计数 0——闭环未受影响。

### Fixed

- **鸿蒙模板的窗口尺寸取证行打的是过渡值**（2026-10-22 装机首轮发现）：`main_ability.cj` 的
  「事后查询复核」在 `resize()` / `moveWindowTo()` 之后**紧接着**读 `getWindowProperties().windowRect`，
  而平台回填矩形是异步的——实测请求 `2683×1747`，紧跟读到的是 `[515 281 2090 1394]`，
  同一时刻截图里窗口明明已经是 2683×1747 满幅居中。这行正是「我调过了 ≠ 生效了」的凭证，
  报过渡值反而会把排查带偏（第一轮据此怀疑过 resize 没生效）。现在改成**有界轮询**（最多 30 次 ×10ms）
  到与请求尺寸一致为止，等不到才如实报最后读到的值，行尾追加 `after N polls`；
  实测修正后为 `rect=[218 166 2683 1747] after 1 polls`，与页面上看到的窗口一致。
- **多窗口下 `clipboard:*` / `notification:notify` 也全发给默认窗那一个宿主**（与上一条 dialog 同源）：
  两个插件原先在 `setup()` 里只调 `handler.attachHost(app.webviewHost())`、`handle` 里 `let _ = ipc`，
  第二扇窗的剪贴板读写与通知一律落到默认窗宿主上。现在装配时注入
  `attachHostResolver({ label => app.hostOf(label) })`，命令按报文里的窗口解析（`requireHost(ipc)`），
  解析器在场而窗口未登记时**如实报错**、不回落单槽；单槽只留作单窗 / 单测兜底。桌面单窗行为不变。
  各补两条 resolver 单测（按窗口路由到对应桩宿主、未登记窗口 `"ghost"` 抛错且两个宿主都没被写过），
  框架 308 用例全绿。**鸿蒙真机（探针两窗各自动打一遍）**：两窗各自的 `platform-clipboard-write` /
  `platform-notification` 行里 `window=` 与页面自认 `me=` 相等，能力位为 0 时两窗**如实失败**
  （`clipboard: 写入失败（宿主未就绪 / 平台拒绝）`）。注意这两个宿主行为相同，**设备侧证据无法
  证伪串台**（共用单槽会打出同样的行），区分力在单测；详见 `docs/鸿蒙ArkWeb接入踩坑.md` §10.13。
- **多窗口下 `dialog:*` 全排进默认窗的队列（第二扇窗的框在别人窗口里弹出来）**：
  `DialogCommands.handle` 原先不收 `IpcContext`（第一行就是 `let _ = ipc`），宿主是装配时固定下来的
  `app.webviewHost()`——所有窗的请求都进同一个 `pendingDialogs`。真机实测（鸿蒙探针两半屏同时弹框）：
  `dialog take label=main` 连续两次、第二次的 `title` 却是 `second`，main 自己那次被覆盖成从未显示，
  而命令 promise 照常 resolve，所以页面显示 `confirmed=true`——**失败无声**。
  现在按报文里的窗口解析宿主（`DialogCommands.attachHostResolver`，`DialogPlugin.setup()` 传
  `{ label => app.hostOf(label) }`）；解析器在场而窗口未登记时**如实报错**、不回落到单槽。
  修复后两个宿主各自的 `id` 序列独立（`label=main id=1` 与 `label=second id=1`），
  取消 / 确定两条回填路径各窗恒等（`window=` 与页面自认 `me=` 同一行相等）。桌面两平台同走此插件，
  单窗行为不变。两条新单测钉住路由（框架 296 用例全绿）。
- **修：`examples/cjnote` 拉起 cjh 时桌面上会蹦出一个 DOS 黑窗口**（2026-10-21 实机看到）：
  应用产物是 GUI 子系统（`--subsystem=windows`）、父进程**没有控制台**，而 cjh 是控制台子系统程序，
  Windows 会给它**单独配一个控制台窗口**。`std.process.launch` 的签名里没有可以传创建标志的地方，
  所以拉起改走框架新增的 `launchHidden()`（C 桥 `CreateProcessW` + `DETACHED_PROCESS`）。
  **一开始用的是 `CREATE_NO_WINDOW`，不够**：它只是不显示窗口，子进程仍持有一个隐藏 console、
  `conhost.exe` 照样挂在它名下；改用 `DETACHED_PROCESS` 之后 cjh **根本没有 console**，
  单文件产物实测 `cjh` 的 `MainWindowHandle=0`、可见 `ConsoleWindowClass` 窗口 0 个、`8765` 照样 LISTENING。
  A/B 取证（**同一份 cjh.exe，只差创建标志**，数可见的 `ConsoleWindowClass` 窗口）：
  不给标志那轮 1 → 2 个，新增那只 pid=15740、`MainWindowHandle=525772`；
  应用内这轮 cjh `MainWindowHandle=0`、可见控制台只剩启动器自己的那一只（pid 16232），
  而对照组 `main.exe` 的 `MainWindowHandle=787648` 证明这个读数不是恒 0。
  连通性同轮成立：`[cj-bridge] spawn hidden: … -> pid=16068`、`cjh web 已就绪（port=8765，等了 0ms）`、
  `127.0.0.1:8765` LISTENING 属 cjh 且 4956 ↔ 16068 ESTABLISHED、页面 `CJH ws connected`。
- **修：`examples/cjnote` 在 Windows 上永远拉不起随包 cjh，界面一直显示「AI 后端未就绪」**（2026-10-21 首验抓到）：
  `cjhBinCandidates()` 是一张**不分平台**的候选表，`vendor/cjh/bin/linux-x64/cjh` 排在 `windows-x64/cjh.exe` 前面，
  而 Windows 的 `fileReadable` 对 ELF 同样回 true（它只是个「能打开的文件」），于是应用拿 Linux 那份去 `launch`，
  报 `ProcessException: Created process failed … The system cannot find the file specified`。
  **真因不是文件不存在**：`CreateProcess` 对**不带扩展名的名字会自动补 `.exe`**，它去找的是 `linux-x64/cjh.exe`；
  三个「看起来像」的嫌疑已用探针排除——`launch()` 的相对路径写法（console / GUI 子系统各编一份都成功）、
  以及从 `spawn` 轻量线程里调用（同样成功），所以问题只在候选表的平台顺序。修法是把候选表按平台拆成
  `cjhPlatformCandidates()` + `@When[os == "Windows"]` / `@When[os != "Windows"]`（AGENTS §2 的平台差异口径），
  环境变量 `CJNOTE_CJH` 的优先级不变；失败日志补上实际用的 bin（`启动 cjh web 失败（${bin}）：…`），
  下次同类问题一眼能看出挑的是哪份。Windows 首验取证：`[cjnote] cjh web 已就绪（port=8765，等了 0ms）`、
  页面 `CJH ws connected ws://127.0.0.1:8765/ws`、`/api/health` → 200。
- **`examples/cjnote` 设置页在「从没跑过 cjh」的机器上保存必然失败**：那种机器上 `~/.cjh` 整个目录都不存在，
  而 `File.writeTo` 只建文件、不建目录——报的是 `写配置失败 …/.cjh/settings.json：FSException`。
  修法是在写盘前补一次建目录，且**必须带存在性判断**：目录已存在时 `Directory.create` 会抛
  `The input path … is already exists`，而「已存在」才是绝大多数用户的常态（装过 cjh 就有），漏判等于
  把保存对所有老用户打红（第一版就是这么写的，靠隔离沙盒当场抓住）。写成 `if (!exists(dir))`，
  与 `main.cj` 建 `notes/` 的既有写法同款。隔离沙盒两种 HOME 各跑一轮：已配过 cjh → **68 PASS / 0 FAIL / 1 SKIP**；
  全新 HOME → **67 PASS / 1 FAIL**（那唯一一条 FAIL 是「本机 settings.json 里没有 model 可断言」，
  同轮里 `~/.cjh/settings.json` 被成功建出并写回，保存路径已通）。
- **`examples/music` 在 main 上编不过**（`error: undeclared type name 'StoreBackend'`，与打包脚本无关）：
  `88838f1` 把收藏库从手搓 `MusicStore` 迁到 store 插件的 `StoreBackend` 时只改了源码，没补子包导入，
  也没装配插件——`import cjTauri.*` 只带出核心包，插件子包不会随之可见（AGENTS §2「一个插件一个子包」）；
  而**仓颉的 import 按文件生效**，所以 `src/main.cj` 与 `src/commands.cj` 两处都要补
  `import cjTauri.plugins.store.*`，并在 `run()` 之前 `app.plugin(StorePlugin())`（页面前命令表要定稿）。
  修完 `cjpm build success`、产物 `target/release/bin/main` 7 655 320 B。
- **`examples/music` 的 29 条编译警告清零**（此前无人可见——基线编不过，警告根本没机会打出来）：
  23 条「未使用参数」按仓库惯例就地 `let _ = <参数>` 显式弃用（不改接口签名）、`api.cj` 里真未使用的
  `import std.collection.*` 删掉、4 条 `unsecure character` 出在搜索命令的文档注释里——那是一串
  **非法 UTF-8 字节**（`EF BF BD`×4 加一对残缺字节，即后台按 GBK 解出的乱码样例），改成文字描述
  「一串替换字符（U+FFFD）」，顺带把源码里那段无效字节清掉。零警告是 §3 的交付门禁。
- **`examples/cjnote` 的「引用当前笔记 / 问笔记库」两个勾选框都会静默空转**（用户实测：勾了笔记，AI 回复里
  还是看不到笔记内容）。两条独立成因，都已修：① **库外文件勾了等于没勾**——`Ctrl+O` 打开的库外文件走
  `openExternalPath()`，那里把 `current` 置成空串，而拼上下文的条件是 `current` 非空，于是整篇正文根本没附上、
  页面上也没有任何提示；现在按「当前文档」本身取内容（标签回落成文件名），正文超 2 万字才截断且如实标注。
  ② **「问笔记库」把整句自然语言当关键词**——`note:search` 是朴素大小写敏感 `contains`（标题 + 正文），
  实测「总结下笔记的内容」在全库 0 命中，附上去的上下文自然是空串；现在检索之外**再附一份「笔记库概况」**
  （新增命令 `note:brief`：最近改动的至多 8 篇，每篇标题 + 正文前 1200 字，按 UTF-8 字符边界截断），
  「总结 / 库里都有什么」这类问题有料可答。两条路径在**勾了却没有可附正文**时都改成打一条页面提示行
  （同时进 stderr 日志），不再静默。页面把拼装抽成 `buildAiContext()` 并补了 4 条自检断言（库外文件附正文 /
  空正文有提示 / 检索未命中走概况兜底 / `note:brief` 形状与 front-matter 剥离），沙盒自检 66/66
  （含 cjh 真连通探针 `reply=ok`）。
- **ai-chat 设置页的 Agent 横幅把行为说反了**：原文案写「下面这些字段只在聊天模式下生效，Agent 模式下改了
  不会影响这一轮对话」，而 `agentChatFrame()` 一直把当前服务商的 `model` / `base_url` / `api_key` 带进当回合的
  chat 帧，**改动当回合就生效**；现在还会同步进 cjh 基线（见 Added 段）。文案已改成实话，并把「连上 cjh」
  这个时机一并写明。
- **ai-chat 自检的 `conv-search` 变红是会话分离改动的连带**：侧栏改成按模式分组（`convsForMode()`）之后，
  探针夹具里的假会话没打 `mode` 标签、当场被滤掉，断言从「1 行」变成「0 行」。夹具补上 `mode: appMode`
  即恢复；同时新增 `cjh-sync-payload` 一条（锁住同步载荷「只带非空字段、掩码不发」的形状），本轮自检 73/73。

- **鸿蒙 headless 构建的 `opt.exe` 崩溃（`0xC000001D` + `EnumReflection format: operand numbers error!`）已解除，
  HAP 重新产得出来**：根因不是 LLVM pass，而是两件事叠加——① `cjc` 与 `opt` **两代混用**（`cjc` 不按
  `PATH` 找 `opt`，它按 `CANGJIE_HOME` 下到 `third_party/llvm/bin/opt.exe`；1.2.0 的 `cjc` 写 7 操作数的
  `*.ti`、1.1.3 的 `CJIRVerifier` 只认 6 个，IR 一定被判 Broken global value）；② **hvigor 常驻 daemon
  复用自己启动时的 env**，脚本里钉的 `PATH` / `CANGJIE_HOME` 根本进不去，于是长期表现为
  「手动跑 `cjpm build` 成功、`build-hap.sh` 一跑就崩」。`examples/ohos-probe/build-hap.sh` 现在同时
  钉 `CANGJIE_HOME=<SDK>/build-tools`、把 `cjc` / `opt` 的实际路径与版本打进日志当凭证、给 `hvigorw`
  加 `--no-daemon`。实测判据：`BUILD SUCCESSFUL in 46 s`，产出
  `entry-default-signed.hap`（1 760 473 B，mtime 本轮），`hdc install -r` 装机成功。
  对照实验（最小枚举程序 + 框架根/entry 两处直连 `cjpm`）与「别再查 `-debug-pass-manager`」的理由
  见 `docs/鸿蒙ArkWeb接入踩坑.md` §10.9 / §10.10。

- **鸿蒙示例的 headless 构建被 `cangjieOptions` schema 拦下：真因是仓颉插件「未启用」时主动删 schema**：
  `examples/ohos-probe/build-hap.sh` 现在会显式给 `DEVECO_CANGJIE_PLUGIN_ENABLED=true` 与
  `NODE_PATH=<工程>/node_modules`（两者缺一即失败）。查清的形状是：插件里的
  `handleCangjieSchema()` 在 `isPluginEnabled()` 为假时走 `deleteSchema()`——**不报错地把 cangjie 的
  schema 删掉**，于是表盘上只剩 `00303038 Configuration Error … propertyName: 'cangjieOptions'`；
  真因只在 `<工程>/.hvigor/outputs/build-logs/build.log`（debug 级）。同轮否掉四条解法
  （hvigor 安装目录建 junction 需管理员、单喂 `NODE_PATH`、`hvigor-config.json5` 声明依赖、
  `--preserve-symlinks` 会撞出两个 hvigor 实例），并记下两个把结论带偏的假线索：
  常驻 daemon 复用会被读成「环境正常」、陈旧 `*.hap` 会被读成「构建成功」。
  过程见 `docs/鸿蒙ArkWeb接入踩坑.md` §10.8。

- **鸿蒙 headless 构建的 `cjpm` 起不来（`0xC0000139`）：缺的是 SDK 自带的运行时目录，不是桌面 SDK 冲突**：
  退出码 `3221225785` = `0xC0000139`，表象是 hvigor 只报 `01101000 Tools execution failed.`
  而命令 21 ms 就「跑完」。真因是鸿蒙 SDK 的 `cjpm.exe`（1.1.3）硬依赖 `libcangjie-runtime.dll`，
  这份 DLL 在 `<SDK>/build-tools/runtime/lib/windows_x86_64_cjnative` 里、不在 `cjpm.exe` 旁边，
  而 `PATH` 上的桌面 SDK 那份是另一代 ABI（往 `PATH` 里加它无效）。`examples/ohos-probe/build-hap.sh`
  现在把该目录前置进 `PATH`（`CANGJIE_SDK` 可覆盖），修后同一构建从「21 ms 崩」推进到真实编译阶段。
  **仍未解决**：编译期 `opt.exe --cangjie-pipeline` 在真实 bitcode 上以 `0xC000001D`（trap）退出，
  6/6 必现，喂玩具 IR 则正常——本轮未定位根因，HAP 因此仍未产出，对话框能力位的真机取证仍未完成。
  **DevEco IDE 的 Build Hap(s) 报一字不差的同一条**（`Failed :entry:default@CompileCangjie` → 同一条
  `opt.exe` 命令、同一退出码），所以「换 IDE 构建」不是绕法。四条待跑的诊断路线（`-debug-pass-manager`
  定位 pass / `llvm-reduce` 缩最小复现 / 试 5.0 工具链 / 查 `opt.exe` 其他按名字加载的依赖）列在
  踩坑文档 §10.9 末尾，进度与会话交接分别在 `docs/进度记录.md` §六、`docs/会话交接.md` §35。
  取证细节与「`-o /dev/null` 会让退出码变 0」的坑见踩坑文档 §10.9。

- **测试编译恢复零警告、用例数同步**：`scripts/test.sh` 此前会刷 16 条「未使用变量」+
  1 条 deprecated（`ArrayList.sort`）+ 1 条未使用 import——按 AGENTS §3 就地 `let _ = <参数>` 弃用参数、
  改走 `std.sort.sort` 短名调用、删掉失效 import（`std.sort` 必须显式 `import` 并用短名，本机 cjc
  不支持 `std.xxx` 限定名写法，见 §4）。修后 **287/287 全绿、零警告**；AGENTS §1 里过期的
  「当前 193 个用例」一并订正为 287。

- **C 桥桩自检（`native/tests/test_bridge_core.c`）在 Windows / llvm-mingw 下编不过**：
  用例按 POSIX 写 `mkdir(dir, 0700)`，而 mingw 的 `<io.h>` 把 `mkdir` 声明成单参（MSVCRT 语义、
  且已标 deprecated），报 `too many arguments to function call, expected 1, have 2`——
  于是 `scripts/test-bridge-core.sh`（以及 `test.sh` / `check-static.sh` 里那一步）在这台机器上
  连着整条门禁一起红。改为统一走 `_WIN32` 分支的 `cj_test_mkdir()` 包装，两边语义都是「建一级目录」；
  修后桩自检 **221/221** 通过。

- **TLS 握手在部分端点上必然失败（`sslv3 alert handshake failure`）：客户端此前不发 SNI**：
  `http` / `ws` 插件建 TLS 客户端时都没设 `serverName`，而**多租户边缘**（同一 IP 上按 SNI 分流；
  实测 `ai.novacode.top` 就在 Cloudflare 后面）拿不到 SNI 就选不出证书与套件，直接以 alert 40 拒掉，
  页面只看到 `TlsException: TLS handshake failed (client): sslv3 alert handshake failure`——**看着像
  白名单或网络问题，实际请求已经出网到达对端**（scope 层早已放行）。现在按「**域名显式带 SNI、
  IP 字面量不带**」修（对 IP 发 SNI 不合规范、TLS 本身也不允许）：主机名判定落在核心
  `src/urlutil.cj` 的 `urlHostOf`（新增 IPv4 / IPv6 字面量识别，IPv6 认 `[…]` 括号形式），
  `src/plugins/http/plugin_http.cj` 与 `src/plugins/ws/plugin_ws.cj` 在建客户端处按主机名设 SNI。
  新增 3 条单测锁住口径（域名带、IPv4 与 IPv6 字面量都不带），框架单测 **294/294**。

## [1.0.0] - 2026-10-17

（首个 1.0.0：自 0.8.0 起 146 个提交——9 个新官方插件、托盘 / 全局快捷键 / 文件拖入三个能力位、
路径 scope、native 按平台分目录、官网与三套打包脚本、ai-chat 整个应用与一半示例。能力面已齐、
双平台实机、有 ADR 与需求追踪背书，对外 API 自此进入稳定承诺。）

### Added

- **`dialog` 插件新增 `dialog:pickFolder`（选目录）**：宿主接口 `WebViewHost.showFolderDialog(title)`
  独立成方法，不是给 `showFileDialog` 加开关——GTK 是另一个 chooser action，Windows 更是另一套
  （`IFileOpenDialog` + `FOS_PICKFOLDERS`，`GetOpenFileName` 没有这个能力）；桥侧两者共用**同名同签名**
  的 `cj_bridge_show_dialog`，以 `kind=6` 与文件类 / 消息类并列（`dlg_req`）。返回选中目录路径，
  **取消 / 宿主未就绪返回空串**，与 `open` / `save` 同口径。命名权限集 `dialog:files` 现含它
  （`open` + `save` + `pickFolder`）。实机（Linux/GTK，隔离副本）：框标题取自入参、动作是**选目录**
  （没有文件名输入，按钮「选择」），选中 `/root/test` 后 cjh 侧 `/api/workspaces` 真出现该路径、
  cjh 进程 cwd 真 `chdir`——判据取 cjh 侧状态，不看页面徽章。
- **`examples/ai-chat` 工作区改用原生目录框**：工作区菜单的「浏览…」把手输绝对路径换成
  `dialog:pickFolder`（`capabilities/app.json` 放行 + 装配 `DialogPlugin`——此前漏装，点了只会得到
  `command not registered`）；手输框保留，取消选择时不动输入。
- **`examples/ai-chat` MCP 面板改为可编辑**（写 cjh `POST /api/settings` 的 `mcpServers`）：cjh 侧是
  **整体校验、一处不合法即整批拒绝**（不落半截），成功回 `note`「需重启 cjh 才建连接」——面板原话照抄，
  不假装热加载。两处刻意不做：① 单个服务器不加启停 / 重启开关（cjh 没有这个接口，要停就从数组里删）；
  ② **不把 GET 回来的 `env` 原样回写**——GET 侧一律掩成 `***`，而 POST 侧是整体替换（没有 apiKey 那种
  「`***` 跳过」语义），回写等于把真实密钥抹成三个星号；`mcpEditGuard()` 检出掩码文本直接拒发。
- **Linux 目录式便携包 `scripts/pack-linux.sh`（cjh 预编译产物随仓 vendor）**：一条命令产出
  `examples/ai-chat/dist-linux/ai-chat-linux-x64/`（`run.sh` + `bin/main` + 41 个共享库 + `bin/cjh`，
  39 MB；归档 tar.gz 12 MB），照 `pack-win.sh` 的风格收依赖。cjh 的来源是**仓内 vendored 的预编译包**
  `examples/ai-chat/vendor/cjh/`（linux `tar.gz` + windows self-contained `zip` + `SHA256SUMS`）——
  启动时**不做联网下载**，更新就是手动替换包；解出来的 `bin/cjh` 逐字节等于官方 `cjh-linux-x64`
  （sha256 `56ebf47c…`），来源与校验值同时记进包内 `bin/cjh.src.txt`。`.gitignore` 放行 vendor 下的
  zip/tar.gz、忽略 `**/dist-linux/`。
- **`examples/ai-chat/README.md`**：这个示例此前**没有 README**（其余示例都有）。补上「两条管道」的
  说明、Agent 模式怎么接 cjh（发现 → 探活复用 → 按需 spawn → 只收自己拉起的）、两处 scope 的口径、
  自检对账方式与四条已知限制。
- **托盘能力位（PLG-009）**：`TrayModel`（`src/tray.cj`，图标 + 提示 + 平铺一层菜单，复用 `MenuItem` 与菜单 wire 格式）→ `TauriApp.setTray()` → `WebViewHost.setTray()` → C 桥 `cj_bridge_set_tray`（core 记 pending，两头都能用：装配前调由宿主线程装配时创建，运行期调整表重建）。Linux 走 **libayatana-appindicator3**（可选编译 `CJ_HAVE_TRAY`，`build_linux.sh` 用 pkg-config 探测；点击经 `cj_core_tray_clicked` 以 `{"kind":"tray","id":…}` 走 shell 通道，前端事件 `tray:click`）；Windows 桩如实报未实现。托盘菜单行走 `cj_core_menu_walk` 同一遍解析，Submenu 整条出局并打 stderr。
- **全局快捷键能力位（PLG-010）**：`HotkeyModel`（`src/hotkey.cj`）→ `TauriApp.setGlobalHotkeys()` → C 桥 `cj_bridge_set_global_hotkeys`。Linux 走 **X11 XGrabKey**（可选编译 `CJ_HAVE_X11`；独立 grab 线程独占 X 连接、按键经管道送 GTK 线程，NumLock/CapsLock 四组合都 grab；Wayland 如实报不支持），点击以 `{"kind":"hotkey","id":…}` 走 shell 通道（前端事件 `hotkey:press`）；Windows 桩。能力位 `CJ_CAP_HOTKEY`/`CJ_CAP_TRAY` 按编译期开关如实上报（`system:host`），桩自检 182 项（含托盘接线 8 项）。
- **新示例 `examples/clipboard-history`**（剪贴板历史管理器）：托盘 + 全局快捷键的首个消费者——**历史捕获零新命令**（前端 500ms 轮询 `clipboard:read` 去重入史，store 持久化上限 200 条），点击条目 `clipboard:write` 回写。Linux 实机 E2E **15/15**（`dist/e2e-evidence/linux-clipboard-history.json`）：托盘真建（tray applied）、grab 注册、轮询捕获、回写后 `xclip -o` **外部回读**对账。已实测的坑入档：剪贴板 core 层单槽防并发（read/write 撞车返回 code=-3），前端探针带退避重试。
- **`examples/ai-chat` Agent 模式：桌面端选中的服务商随帧带给 cjh（会话级覆盖，cjh#3 契约）**：
  Agent 模式发给 cjh 的 `chat` 帧现在带 `model` / `base_url` / `api_key`（取当前选中的服务商，
  字段为空则**不发**该字段），cjh 侧（`7bcc097`）只对本回合生效、不落盘、不粘住；三者全缺时与旧客户端
  行为一字不差。为什么必须连 **api_key** 一起给：不同厂家的 Key 不通用，只带 `model` + `base_url`
  会让 cjh 拿自己的 Key 去打别的端点，失败形状是 provider 报错、「桌面端选的服务商」等于没生效
  （用户 2026-10-16 报的就是这个）。桌面端的对应承诺是**这把 Key 不进任何日志行**（trace 与页内自检
  日志都不带），断言 `cjh-key-not-logged` 守着。构造逻辑抽成 `agentChatFrame()`，好让自检能断言
  「选中的模型真进了帧」——不抽就只能发一条真消息去验，那是拿用户的会话做实验。
  实机对照（Xvfb + 隔离副本 + HEAD 构建的 cjh 另起 18899 端口）：**旧 cjh + 打不通的 `base_url` = 有文本
  回复**（旧服务端整帧忽略）、**新 cjh + 同一份帧 = 空回复**、**新 cjh + 不带覆盖字段 = `OK`** ——
  第三条钉住「服务端与它自己的配置都是好的」，于是第二条的空回复只能来自「帧内服务商被消费」，
  透传在实机成立（三条的判据都是副本 `store.json` 里那一轮落盘的正文，不是退出码）。
- **`examples/ai-chat` 补齐 cjh 新帧的落点**（对齐 cjh `7bcc097` 的帧身份 / 审批通道 / 结构化收尾）：
  `ack`（请求已受理）、`cancelled{was_running}`（中止回执——本回合是被取消，不是失败）、
  `error{code,retryable}`（按 code 映射成人话提示，并标明可否重试）、`approval_request`（工具待批准的
  落点）、`done.finish_reason`（收尾原因：`length` / `content_filter` / `error` 各给一行说明，
  空回复不再无声）。页内自检 **66 PASS / 0 FAIL**（本轮新增 `mode-chat-hides-cjh` / `mode-chat-badge` /
  `mode-chat-tab-collapse` / `mode-frame-passthrough` / `mode-agent-shows-cjh` / `cjh-key-not-logged`），
  `scripts/check-static.sh` 全绿。
- **`examples/ai-chat` 的审批请求补上「能答的入口」**（对齐 cjh 的审批通道，cjh 侧 `7bcc097` 已落地）：
  `approval_request` 此前只 `appendNote` 一行说明——用户看得见「有工具在等批准」，却**没有任何入口能答**，
  只能干等 cjh 超时（默认 5 分钟）。现在渲染一张待批准卡片（工具名 / 入参 / 命中规则 + 与
  `expires_in_ms` 同步的倒计时），「批准 / 拒绝」经同一条 WS 回
  `{"type":"approval_response","request_id":…,"approved":bool}`；卡片落定后按钮禁用、倒计时停，
  **结论同时写进会话正文**（卡片是 DOM，刷新即失——只留 DOM 的话重开就看不到这轮批过什么）。
  cjh 侧超时 / 断连一律按「拒绝」收场并让回合继续，页面照它的口径写「秒后按「拒绝」收场」，
  不假装能替 cjh 续期；已决卡片不重发回执（`request_id` 不匹配即返回）。页内自检新增
  `approval-card` / `approval-buttons` / `approval-response-frame` / `approval-settled` /
  `approval-recorded`。
- **`examples/ai-chat` 流式截断标记落进正文**：宿主单次接收有上限（`http` 插件 `CJ_HTTP_MAX_BYTES`
  = 8 MiB），撞上限时流被掐断、`stat.truncated = true`。此前只在页面上 `appendNote` 一行提示——
  **没进存档**，刷新后那条回复看起来就是完整的一整段（痕迹只活在 DOM 里，AGENTS §4 那类最贵的失败形状）。
  现在由 `truncNote()` 把标记连**已收字节数**一起拼进正文再落盘。断言 `truncated-note`。
- **`examples/ai-chat` 缺 cjh 时给一条「能走完的引导」，不再只报一句未连接**：此前页面只把连接行涂成
  「未连接」，用户没有任何下一步可走——而 `__CJH_API__` 是 document-start **一次性**注入的（启动那刻
  cjh 不在，此后永远拿不到端点），Windows 双击 GUI 更是连设环境变量的地方都没有。现在切 Agent 模式先问
  一次 `cjh:status`，按三态分流：**已经在跑**（含用户自己起的）直接接上；**有路径**（上次挑过的 >
  `CJ_AICHAT_CJH`）当场拉起并接上；**都没有**才出引导卡——一页说清 cjh 是什么、为什么装在本地
  （只听 `127.0.0.1`，Key 与工作区不出本机）、**按当前平台**给该下的产物名与下载页
  （linux-x64 / windows-x64-selfcontained.zip——写死一个平台，另一种系统的用户会照着下错包，自检
  `guide-artifact-linux` / `guide-artifact-win` 钉住），出口是「选择 cjh 可执行文件… / 重新检测 /
  回到聊天模式」。第三个按钮背后是新命令 `cjh:start {path}`（**运行期**指定 cjh 可执行文件，这就是
  「应用自己接住安装结果」那一步），挑过的路径记进存档，下次进 Agent 不再问。引导卡走
  `guide-on-missing` / `no-fake-endpoint`：没装 cjh 时页面**不得**假装端点已就绪。实机（Xvfb 隔离副本 +
  独立 cjh，不碰用户存档与在跑的 8765）：run1 缺 cjh → 引导出卡、产物名 `cjh-v1.5.1-linux-x64`、
  自检 **71/71**（比上一轮 67 多出 `guide-artifact-linux` / `guide-artifact-win` / `guide-card` /
  `guide-hidden`）；run2 给一条路径 → `start ok reused=false` → `state=running api=yes ws=up` →
  `guide-hidden-after-start` → `bin-remembered`，随后面板 4/4、文件预览 5/5、WS 聊天
  `deltas=1 done=1 err=0`。**如实记**：引导卡上「选择…」那一跳是原生文件框（阻塞模态），无人值守点不了，
  自动化取证走的是它背后同一个 `cjhStartWith()`、命令链路一致，对话框本身留人点验。
### Changed

- **`examples/ai-chat` 撤回「窗口随屏幕 + 页面等比缩放」两件（用户实测反馈：等比放大后不如原样）**：
  页面按 `screen.availWidth` 定档的 `--z`、`html { zoom: var(--z) }` 与全部视口单位补偿（`100vh` / `86vw` /
  `70vw` / `92vw` / `86vh`）一并撤掉，`WindowConfig` 回到固定 `1080x760`。**随后框架侧这套基元也整体撤除**
  （`WindowConfig.autoSize` / `WindowAutoSize` / `cj_bridge_set_window_auto` / core 的 `cj_core_window_size`
  与两平台建窗换算全删，桩自检相应 10 项一并取消——留着只会让后续应用再照着接一遍）。取证：
  `set window: title=AI 对话 size=1080x760`
  （用户实例 22:17:25 与 Xvfb 副本 22:19:34 两次）、页内自检 **56/56 断言、FAIL 0**（明细 65 条 PASS，
  其中 9 条 CJH-* 不并入计数）、截图 `/tmp/cj-tauri-shots/after-unscale-1280-root.png`（1280x800 窗口、
  字号回原口径、输入区仍贴底部）。
- **`examples/ai-chat` 设置面板（`#cfg`）重排——用户实测反馈「又窄又不好看」**：
  - **宽度不再写死**：`540px` → `min(920px, 94vw)`（与文件预览面板同口径），窗口变小自动收窄；面板拆成
    头 / 体两段，标题与动作条固定、只滚中间——服务商多起来不再把标题顶出视野；
  - **表单单列改两列**：名称 / 模型并排，Base URL 与 Key 各占满宽；system 提示词从单行 `input` 换成三行
    `textarea`；窄于 720px 自动回单列（按窗口宽度回退，不看设备）；动作条（删除 / 取消 / 保存）**吸在
    面板底部**——此前表单长于一屏时「保存」被压在折叠线以下（截图实测）；
  - **连上 cjh 时面板顶部给横幅**：说明这轮对话由 cjh 侧执行、Key 与模型来自 cjh 自己的配置，下面这些
    字段只在「未连上 cjh」的直连模式下生效——改完没反应时至少不用猜；面板底部补「生效时机」：保存后
    **下一次发送**即生效、不需要重启，同时写入本机存档；
  - **三处「静默失败」收口**（均实测复现）：① 保存时 Base URL 为空只 `focus()` 一下就 `return`，
    用户会以为存上了——现在表单里给红字原因且不动数据；② `sysPrompt` 原先在校验**之前**赋值，一次失败
    的保存也会把生效中的 system 提示词换掉（未落盘，但这一轮请求已经变了），改为校验通过后才写；
    ③ 预设名兜底那两行写在 `return` 之后（`!p.baseUrl` 恒为 false，等于死代码）——移到校验前，
    只填「DeepSeek」这类预设名即可自动补出端点；
  - **补全关闭出口**：右上 ✕ / 点遮罩空白 / `Esc`。此前只有表单里的「取消 / 保存」，服务商列表为空或
    表单被隐藏时**面板关不掉**（无服务商时实测如此）；
  - 页面自检 27/27 → **35/35**（新增 8 条：`cfg-width-fluid` / `cfg-two-col` / `cfg-acts-in-view` /
    `cfg-err-visible` / `cfg-preset-fill` / `cfg-close-paths` / `cfg-close` / `cfg-cjh-banner`；
    断言期间会临时改 `providers` / `sysPrompt` / `CJH.up`，用完均还原并 `saveState()` 写回真现场）。
- **Windows 用户数据档案挪出 exe 目录（`%LOCALAPPDATA%\cj-tauri\<exe名>.WebView2`）**：
  此前桥不传 `UserDataFolder`，WebView2 按默认规则在 exe 旁边生成 `<exe名>.WebView2/`
  （约 10-15 MB 的缓存堆）——对单文件分发目录是纯噪音。现在桥显式选目录：
  env `WEBVIEW2_USER_DATA_FOLDER` 优先（E2E 每轮独立目录防实例互锁的机制不变），
  默认落 `%LOCALAPPDATA%\cj-tauri\`（Windows 应用惯例位置；localStorage 里的主题 /
  「上次打开」照常持久）。另经 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` 把 HTTP 磁盘缓存
  限到 32MB（loader 原生认该变量，免去手写 COM options——WebView2.h 的 C 模式不声明
  coclass 的 CLSID）。旧 exe 旁的 `.WebView2/` 可整目录删除，下次启动不再生成。
  取证：干净副本自检 25/25，exe 目录无 `.WebView2`，env 覆盖探针按给定路径生效。
- **路径 scope 修复（Windows）：清单模式补分隔符归一，`$HOME/**` 不再形同虚设**：
  清单里的模式此前只做变量展开——`$HOME` 在 Windows 展开出 `USERPROFILE` 原值（`C:\Users\...`，
  反斜杠），而页面路径经 `normalizeScopePath` 归一成正斜杠，两侧逐字节比较永远不相等，
  结果 `allow: ["$HOME/**"]` 写了等于没写（markdown-notes 实测：打开桌面文件被拒）。
  修复后清单模式与页面路径走同一套分隔符口径（`parseScopeRule` 内补 `toScopeSlashes`），
  防回归用例 `testScopeRuleNormalizesManifestSlashes` 锁住该口径（两个平台都成立）；
  Linux 行为不变。全量测试 262/262 通过。
- **插件体系拆包：一个插件一个子包（`cjTauri.plugins.<名字>`），应用只链接用到的插件**：
  此前全部插件挤在一个 `cjTauri.plugins` 包里，仓颉的链接粒度是「包 = 静态库」——应用装配任何
  一个插件就会把整包对象拉进链接：只用 fs/store 的示例被 sqlite FFI 连坐，Windows 构建也要链
  `-lsqlite3`（markdown-notes 首次在 Windows 构建时实测暴露）。拆分后 11 个插件各自独立成
  `libcjTauri.plugins.<名字>.a`（codec/FFI 随各自的插件放同子包），导入改成显式
  `import cjTauri.plugins.<名字>.*`——markdown-notes 的 Windows 产物导入表已核实不含 `sqlite3.dll`。
  联动：`src/plugins/plugins.cj` 为 cjpm 扫描锚点（目录里没有 `.cj` 文件时子包不被扫描）；
  `serialHexToBytes`/`serialBytesToHex` 三插件共用，迁入核心 `src/hexutil.cj`
  （更名 `hexToBytes`/`bytesToHex`）；插件间禁止互相引用（`check-static` 新增 6b-2
  「src/plugins/ 根禁止平铺」门禁）；框架 mingw `link-option` 补 `-lsqlite3`（导入库由
  `sqlite3.def` 生成、本机自备，不引用 sqlite 插件的应用不会被链到）。
  全量测试 261/261 通过。
- **示例 `markdown-notes` 渲染升级到 marked + Highlight.js，工具栏收进菜单**：
  - **渲染质量**：自写的 Markdown 子集渲染器换成 **marked v12.0.2 + Highlight.js v11.9.0**
    （vendor 进 `ui/vendor/`、装配期读盘内联——`run(html)` 的页面没有真实来源，`<script src>`
    相对路径取不到文件；库经 `<template>` 解析 + 白名单清洗：脚本/iframe/事件属性/
    `javascript:` 一律剥掉，外链补 `noopener`，图片仍降级为占位说明）；
    排版升级（GFM 表格 / 嵌套列表 / 任务清单等 marked 全集）+ 代码语法高亮。
    许可证已按 §5 登记（marked MIT、Highlight.js BSD-3-Clause）。
  - **工具栏撤掉**：新建 / 重命名 / 删除 / 刷新 / 保存五个按钮不再显示在右上角——动作全部
    收进「文件」菜单（保存走 `Ctrl+S`），删除二次确认改在状态栏提示；页内自检 21 条同步
    （注入断言改为「script 剥净 + img.onerror 剥净」，渲染断言全数通过 `SELFCHECK DONE passed=21 failed=0`）。
  - **两个新踩的坑**：① 主脚本注释里出现「脚本结束标记」的字面量会把 `<script>` 块提前终止、
    整个主脚本不执行（页面停在「等待桥」，注释漏成正文）；② 仓颉块注释里写占位符字面量
    （星号斜杠）触发嵌套注释 `unterminated block comment`（AGENTS §4 第一条坑的变体）。
- **示例 `markdown-notes` 用上宿主菜单与选择框（界面观感向 Typora 靠拢）**：
  - **原生菜单栏**（文件 / 视图 / 帮助）：文件操作（新建 `Ctrl+N` / 保存 `Ctrl+S` / 重命名 / 删除 /
    刷新）进菜单，与工具栏按钮收敛到同一批页面动作函数；「视图 → 预览窗格」是**勾选菜单项**
    （`MenuItem.checkbox`），关掉后编辑栏独占整行（专注编辑）。装配走应用层 API
    （`setMenuTo` + `onShellEvent`，`run()` 之前），能力清单 `events` 放行 `menu:click`；
    点击全链路实机取证：桥 `menu clicked: id=…` → 仓颉钩子 → 前端 `[frontend] UI menu:click …`。
  - **侧栏排序选择框**（`<select>`，按名称 / 大小 / 修改时间）：WebKitGTK 原生 combo 会用浅色样式
    盖掉深色页面（AGENTS §4 老坑），按 `-webkit-appearance:none` 自绘 + 渐变三角箭头；
    换排序只重排现有列表，不重新列目录。
  - **关于走原生对话框**：菜单「帮助 → 关于」从页面 toast 改为 `dialog:message` 模态对话框
    （`DialogPlugin` 装配 + 清单放行 `dialog:default`）；实机取证 `dialog: kind=2 title=关于`
    → `dialog closed: ok=1`。
  - **输入卡顿修复**：此前每个按键同步跑一次全量 Markdown 重渲 + 全文字符串比较；现在预览渲染
    节流 150ms（连续输入最多一帧一次）、脏标记防抖 300ms。
  - **侧栏页签「文件 / 大纲」**：大纲从编辑器原文抽 `#/##/###` 标题（跳过代码围栏），点击滚动到
    对应行；排序选择框只属于文件页签。
  - **预览排版（Typora 式）**：内容居中收成约 46em 阅读栏，标题紧凑、行距放宽、引用 / 代码 /
    表格配齐；预览窗格可用菜单整体关掉。
  - **文件 → 打开…（`dialog:open`）**：菜单与 `Ctrl+O` 弹**原生文件选择框**，选中路径读回编辑器
    （`state.current` 泛化成完整路径——工作区内按 `notes/<名>`、外部按绝对路径统一处理）；
    scope 相应放宽为**工作区 + `$HOME`**（deny 兜 `*.secret.md` / `.ssh/**` / `.git/**`），
    页内自检的反面素材同步改成 `/etc/hostname` 与「超量 `..` 攀升」（词法规范化在根处截断，
    层级与 `$HOME` 深度无关），E2E 断言 needle 对齐；Xvfb 实机取证：
    `menu clicked: id=file.open` → `dialog: kind=0` → `dialog closed: ok=1 path=/root/hello-dialog.md`，
    截图确认路径上头部、内容进编辑器与预览。
  - **代码高亮主题换 `github-dark-dimmed`**（替代 `github-dark`，冷灰底更贴页面深色面板），
    预览阅读栏 46em → **58em**。
  - **视图三态切换 + 代码主题选择**：菜单「视图」从单一「预览窗格」勾选升级为**仅编辑 /
    编辑 + 预览 / 仅预览**三态（快捷键 `Ctrl+1/2/3`，Typora 式全程只盯预览）；三态互斥由
    应用层按 `menu:click` 报文的 id 成组回写勾选态（`setMenuItemStateTo`），前端只改
    `display` 不重渲。新增三份 hljs 主题勾选切换（GitHub Dimmed 默认 / GitHub Dark /
    Atom One Dark）：主题内联成三份独立 `<style id="hljs-theme-*">`，切换 = 改 `media`
    属性（`not all` 禁用 / `all` 启用），不重渲、不读盘。
  - **修链接失败**：SQLite 插件并入框架静态库后，示例 `cjpm.toml` 的 Linux `link-option` 必须带
    `-lsqlite3`（与 sqlite-browser 同款），否则 `undefined reference to sqlite3_column_bytes`。
- **`examples/ai-chat` 的模型选择真的生效了：新增「聊天（直连）/ Agent（cjh）」模式开关（默认聊天）**：
  此前管道由「cjh 连没连上」决定（`if (CJH.up)`），而本机默认就把 cjh 跑着，于是聊天模式里换服务商 /
  换模型都**静默失效**——用户实测报的形状就是「选了别的模型，回复仍来自 cjh 侧模型」。改动与判据：
  - **管道按模式分流**：聊天模式一律走直连（顶栏选的服务商与模型、Key 也直连），Agent 模式才连 cjh、
    模型与工具全由 cjh 决定；Agent 模式未连上 cjh 时**当场如实拒绝**，不悄悄退回直连；
  - **cjh 的面在聊天模式整体隐去**（工作区徽章 / 技能 / MCP / 文件 + 侧栏连接行），侧栏品牌随模式改口
    （`cjh 客户端` ↔ `AI 对话`），停在 cjh 面板上切模式自动收回会话页——否则界面停在「什么都不显示」；
    聊天模式也不拉 cjh 会话历史、不建 cjh 连接（连接只在 Agent 模式建立，切回即断开入口）；
  - **Agent 模式给 cjh 的 `chat` 帧前向兼容带上选中的 `model` / `baseUrl`**：cjh 现忽略未知字段，
    会话级 model 落地后桌面端一行不用改即生效（`apiKey` 暂不带——是否接受由 cjh 侧裁）；
  - **徽章按模式说各自的事实**：Agent 模式显示 **cjh 侧 `GET /api/settings` 的真实模型**（取不到就写
    「未取到」），点它不再弹「改了也不生效」的服务商菜单；设置面板横幅改按**模式**出现（原先按连接态）；
  - 页面自检新增 6 条 `mode-*`（显隐 / 品牌改口 / 面板收敛 / 帧透传 / 存档落盘 / 徽章口径），断言完恢复
    现场并**拦下探针期的 `store:set`**（此刻内存里是探针服务商，真写就把假数据存进用户存档）；
    实机一轮 **49 PASS / 2 FAIL**，对照「同一存档 + 改动前页面（HEAD 版）」的基线 **41 PASS / 4 FAIL**：
    条数差（+8）与明细差（+6 条 `mode-*`，另 2 条 `hl-*` 是基线副本缺 `ui/vendor` 所致）逐条对得上，
    余下 `theme-light` / `theme-dark` **两侧同样红**＝与本次改动无关（旧断言拿 `className` 全等比较、
    写死 `'light'` / `''`，而用户开着「紧凑模式」时合成类名是 `light compact` / `compact`，必然假红）；
    成因确认后已顺手改成按紧凑态拼期望类名，亮暗两个模式各断一遍。
- **`examples/ai-chat` 设置由「居中弹层」改成「内联设置页 + 常驻底栏」**（用户反馈：打开设置还得先往下拉，
  保存按钮在最下方，很不方便）。改动与判据：
  - 设置块整体搬进主区当一个页面——`#mask` 由 `position:fixed` 遮罩改为铺满 `#main` 的 `absolute` 面板，
    id 一个没改（`#mask` / `#cfg` / `#cfgClose` / `#btnCfgSave`…），既有接线与页内自检照旧；
  - **动作条与错误行移出滚动体**（`.cfg-acts` 进 `.cfg-foot`）：上一版的 `position:sticky` 吸底在
    `#provForm` 内部、受父盒约束，表单没滚进视野时**根本够不着**——这才是「保存在最下方」的真实成因，
    现在底栏不参与滚动，任何滚动位置都看得见；
  - **打开即定位当前服务商的表单**（`scrollIntoView`）；服务商为空时开一张空表单而不是把表单藏起来
    （动作条常驻却看不见表单更费解）；保存后给回执 toast；错误行跟着底栏常驻；
  - 侧栏动作（点会话 / 新会话 / 恢复 cjh 会话）先让位回对话——它不再是弹层，不会自己关；
    设置页开着时切模式，cjh 的诚实横幅**跟着刷新**（原来只在打开那一刻设一次，停在旧口径＝反过来误导）；
  - 页内自检撤掉弹层时代的三条（`cfg-width-fluid` / `cfg-acts-in-view` / `cfg-close-paths`），
    换成 `cfg-fills-main`（铺满主区且定位是 absolute）/ `cfg-acts-outside-scroll`（动作条与错误行都不在
    滚动体内）/ `cfg-acts-pinned`（滚到顶与滚到底，保存按钮位置差 ≤1px 且落在视口内）/ `cfg-exit-paths` /
    `cfg-banner-live`（切模式横幅跟着翻），实机 **58 PASS / 0 FAIL**（总数 = 去重数 = 58，每条恰好一次）。
- **`examples/ai-chat` 切到「聊天」模式时真的断开 cjh 的 WS**（此前只清空会话列表、把面板藏起来，
  连接照旧活着）：切模式那一刻若正有一轮 agent 在执行，`delta` / 工具帧会继续往当前气泡里写，
  而顶栏已经写着「聊天」——界面口径与后台状态不一致，事后也说不清那条回复是谁给的。
  断开前先给这轮收尾（已收到的部分保留，不留永远转圈的气泡），且**只收尾 cjh 轮次**
  （`streaming && cjhTurnPending`）——HTTP 直连流不归这儿管，误收会把一条正在流式输出的直连回复
  当场掐断（实现时正是这么踩到的）。页内自检 `mode-chat-drops-ws` 三条子判据分别盯：确实下发
  `ws:close` 且 `wsUp` 归零 / HTTP 直连流不被掐断 / cjh 轮次被收尾。
- **`examples/ai-chat` 消息列由「限宽 + 左对齐」改成「铺满可用宽 + 左贴边」**（用户三轮实机反馈：先「最大化后没有
跟着铺开」，居中后又「两边留的空白还是很难看，不能铺满吗」）。顺着窗口链路查下去，**窗口到 WebView 这一段
本来就是好的**——最大化确实生效（实测 1920x1017），C 桥 `gtk_box_pack_start(..., TRUE, TRUE, 0)` 的
expand/fill、页面 `100vh` 与外层 flex 都跟着变（隔离副本在 Xvfb 里改窗口尺寸抓图对照可证）；真正不跟窗口走的
是**消息列**。这条改了三轮才落到最终口径：① `.msg` 只写了 `max-width:min(1080px, 94%)` 且**左对齐**，
余量全堆在右边（1920 宽窗里可用宽 1538px、正文占 1080px，右侧空出 458px），观感上正好像「页面没铺开」——
先补 `margin-inline:auto` 居中（左右各留 ~109px）；② 用户再反馈「两边空白还是难看、要铺满」，于是**撤掉整个上限**，
宽度上铺满了；
③ 撤上限后仍留 `3.5vw` 水平内边距，1920 宽窗下正文离侧栏 76px，而顶栏（`#topbar`）与输入区（`#inputBar`）
都只有 18px——三处左边缘不齐，看着像「聊天区居中、跟侧栏留了一道空隙」（用户原话「不要居中，应该左对齐」）；
④ 定稿＝`#msgs` 的 `3.5vw` 换成 **18px**，与顶栏、输入区同值，铺满且左贴边、三处左边缘对齐。`.msg` 上一句注释「最大化不再留大片空白」
也一并改成实话——`min()` 在窗口 ≥1150px 宽时恒取 1080px，那句意图从来没生效过。要恢复阅读行长上限
（一行超 ~90 汉字回行易串行）只需加回 `max-width`，居中与否另配 `margin-inline:auto`。
判据＝**同参抓图**（同一合成存档 + Xvfb，只差这一条 CSS）：限宽左对齐时正文列左贴边、右侧空 216px（1660x960），
居中后左右各约 108 / 110px，**撤掉上限后 1920x1017 下气泡铺满（316→1913px）与输入框同宽**、700x760 窄窗
两侧只留标准内边距不贴边；另按「应用默认 1080x760」与「拉宽到 1920x1017」各拍一张对齐图：消息列左边缘与顶栏菜单按钮、输入框同处 18px，与侧栏之间无额外留白；页内自检 **58 PASS / 0 FAIL**（49 条页内断言 + 4 条 `CJH-PANELS` + 5 条 `PREVIEW`，
断言名集合与改动前基线 `diff` 逐字一致），`scripts/check-static.sh` 全绿。
**顺带修掉一条绑死旧实现的断言**：`layout-fluid` 原先断言 `getComputedStyle('.msg').maxWidth` 里必须含 `min(`，
撤掉上限后它取到 `none` → 当场假红（本轮实测 57 PASS / 1 FAIL）。它的**意图**是「内容区宽度跟随窗口、
不许写死像素上限」，现改为按意图判——放行 `none` 与比例 / 自适应上限，仍拒任何固定像素上限
（比原写法更严，820px 那种回归照样拦得住）。

### Fixed

- **修：`examples/ai-chat` 收口时一个 delta 都没有的回复，页面上一个字都不画**（2026-10-16 实机踩到）：
  正文其实**已经落盘**（刷新就出现），但 `finishCjhTurn` 原先只在「已有流式气泡」时才渲染正文，
  于是页面上只剩用户那条消息，看着像「发出去了没反应」——最容易把服务端的失败读成「桌面端卡住了」。
  收口前先补一个助手气泡再写正文。触发它的正是本轮那轮实机：新 cjh 用了帧内服务商、请求打不通，
  收尾只有一个 `done`、没有任何文本（**cjh 侧这时也没回 `error` 帧**，已另提 issue `qq8864/cjh#4`
  附 A/B/C 对照；桌面端这边至少不再无声）。
- **修：`examples/ai-chat` 左栏同一个 cjh 会话出现两次，点一次「⟳ cjh 会话历史」就多一份本地会话**
  （用户实况）：两个来源各列各的——本地会话里走过 agent 的那条带 `cjhId`，`⟳` 组又是 `/api/sessions`
  的全量，同一个会话于是排成两行；而 `resumeCjhSession()` 无条件 `newConv()`，每点一次 ⟳ 就多一条本地
  记录（多出来的还是空壳，越点越多）。两处收口：① `renderConvs()` 的 `⟳` 组按 `cjhId` 过滤掉已被本地
  镜像的会话（分组标题也只在真有未镜像会话时才出现，免得挂着空标题），本地那条打 `⟳` 标记、tooltip
  写明是 cjh 会话镜像；② `resumeCjhSession()` 命中已有 `cjhId` 时**接着那条聊**、不再新建。
  回放口径不受影响——`history_messages` 帧走 `replayCjhHistory`，那里是**清空重建**、不是追加。
  页内自检新增 `conv-cjh-dedupe`（重复项不列、未镜像项照列）与 `conv-cjh-marker`（本地镜像带 `⟳`）。
- **修：`examples/ai-chat` 左栏同一 cjh 会话的**存档历史**重复镜像堆成一串「新会话」**（用户 2026-10-16
  实况：「从 agent 切到聊天模式，左侧栏的会话竟然会一直增加」）。上一条只挡住了**新**的重复
  （`resumeCjhSession` 复用 + `⟳` 组按 `cjhId` 过滤），**已经堆进存档的**没管：本机存档 13 条本地会话里
  7 条是 2 个 cjh 会话的重复镜像（`s1787819737.801` 4 条、`s1788053775.928.3` 3 条），而 cjh 侧当时只剩
  1 条会话；聊天模式又整体隐去 `⟳` 组，于是左栏只剩一串同名「新会话」，看着像会话在凭空增长。
  **先查实再改**：切模式本身不新增会话——能往 `convs` 加记录的只有 `newConv()`，`applyMode` /
  `toggleMode` 都不调它，新增断言 `mode-switch-no-new-conv`（两个来回）把它钉住；堆的是历史镜像。
  处理落在**渲染层折叠**、不删存档：同一 `cjhId` 只渲染一条（当前会话优先保住——否则用户停在被折叠的
  那条上，左栏连选中行都没有；其次留消息最多的），并显示「已合并 N 条重复的 cjh 会话镜像」把折叠条数
  说出来（不说的话用户只看到会话变少，会以为被删了；存档一条没动，要清仍可在会话上点 ×）。
  **聊天模式干脆不列镜像**（同日用户裁定：镜像属于 Agent 的面，与「cjh 四面在聊天模式整体隐去」同一
  口径），换成一行「cjh 会话镜像 N 条只在 Agent 模式列出」——不挡的话左栏就是那十来条只跟 cjh 有关的
  行（用户「一直在增加」的观感正来自此）；当前会话本身是镜像时提示里补一句「当前这条也是镜像，正文
  照常显示」，否则「列表里没有、正文偏偏是它」看着像 bug（模式只换管道、不切会话，见 `applyMode`）。
  判据＝**本机存档副本实机抓图**（隔离副本自带 `store.json`，不动用户那份）：折叠前 13 行 → Agent 模式
  8 行 +「已合并 5 条」、聊天模式 3 行 +「镜像 10 条只在 Agent 模式列出」；页内自检 **58 → 63 条全绿**
  （新增 `cjh-mirror-reuse` / `cjh-mirror-fold` / `cjh-mirror-fold-hint` / `conv-chat-hides-mirrors`），
  `scripts/check-static.sh` 全绿。
  **顺带踩到一条探针自身的坑**：`conv-cjh-marker` 与折叠探针原先不指定模式，默认的聊天模式下镜像已被
  过滤、折叠数归零 → 三条断言当场假红（那轮 3 FAIL）；修法是探针显式 `appMode = 'agent'` 并在收尾还原。
  断言名集合与改动前基线 `diff` 仍逐字一致。
- **修：`examples/ai-chat` 发送按钮把 `send` 直接当回调绑，MouseEvent 被当「用户正文」写进存档
  （一条非字符串正文就能让整页脚本停摆）**：`$('btnSend').onclick = send` 会把 `MouseEvent` 传进去，
  而 `send(text)` 只看 `text` 真不真，于是事件对象进了会话历史、被序列化成 `{"isTrusted":true}`
  （实测：当时那个会话 10 条里 5 条长这样）。真实后果不是「多发了一条」而是**下次加载就崩**——
  渲染历史时 `renderMd(src)` 对非字符串调 `src.replace`，抛
  `TypeError: src.replace is not a function`，页内整段脚本随之停摆：聊天区停在半渲染状态，
  **页内自检一条都跑不出来**（日志里只有一行 `unhandled rejection`，表象极易被读成「应用没起来」）。
  三处收口：① 按钮改绑 `function () { send(); }`；② `send()` 只认字符串，非字符串（`undefined`、
  被误传的事件）一律回落到输入框内容；③ `renderMd` 入口对非字符串按空串处理——存档是外部文件，
  旧版本写下的脏数据也要能打开。另加一条**一次性清洗**：`loadState()` 剔掉非字符串正文的消息并落一行
  `loadState: dropped N message(s) with non-string content`（本机存档由此从 10 条清回 5 条，
  该行日志第一次没出来是因为清洗处误调了 `send()` 里的局部 `trace`——`ReferenceError` 被本函数末尾
  那个「存档坏了就当没有」的 `catch` 吞掉，连后面的 curId / 主题 / 模式应用都一并跳过，已改为直写日志通道）。
  页面自检 **52 → 53 条全绿**（新增 `renderMd-nonstring-guard`：对 `undefined` / `null` / 事件对象调
  `renderMd` 不得抛；崩溃未修时那一轮是 0 条——脚本在渲染期就停了）。

- **修：`examples/ai-chat` 的 Enter 提交不挡输入法合成态（装了输入法就会「选词即发送 / 选词即改名」）**：
  聊天输入框、会话行内改名框、工作区路径框三处都是「按 Enter 提交」，而中文输入法**选词 / 确认候选
  用的也是 Enter**（此时 `isComposing` 为真，老 WebKit/Safari 走 `keyCode 229`）——不挡的话，中文用户
  按下第一个候选词，半句话就被当消息发出去、半句就被当新会话名提交了；连带把文档级快捷键
  （Ctrl+K / Ctrl+B / Ctrl+Shift+N）也一并挡掉合成态（那些键在合成期归输入法）。
  **这条路径在没装输入法的机器上永远走不到**，所以自检全绿也发现不了：本机取证的 Xvfb 里根本没有
  输入法通路（`fcitx` / `ibus` 均未安装、X 无 XIM 服务、应用进程无 `XMODIFIERS` / `GTK_IM_MODULE`），
  直接注入字符能正常进输入框（另经 `xclip` + `Ctrl+V` 走剪贴板粘贴亦已验证中文可进输入框），
  但「合成态 + Enter」这个组合从没被真实触发过——属「自检全绿 ≠ 这条路径没问题」。
  页面自检 35/35 → **36/36**（新增 `ime-enter-guard`：合成 `KeyboardEvent` 打给 `#input`，
  断言既不发送、也不被 `preventDefault`、输入框内容原样保留）。

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

- **对外口径统一为「仓颉语言的 Tauri」**：README / 官网 / npm 描述 / skills / 示例 README 与 `docs/` 各篇文稿
  里的定位表述，一律改成「**仓颉语言的 Tauri**」「Tauri 那套架构在仓颉里独立实现」「与 Tauri 对应 / 同构」——
  讲的是同一套架构在仓颉里的实现，而不是指向某个项目的来源。
  文档中原先把各处设计与 Tauri 逐条对照的「对标」措辞，也按语境换成「对应 / 对齐 / 沿用」；**只保留两处**
  （`docs/进度记录.md` 与 `docs/会话交接.md` 中引用该命名约定本身的元语句，去掉那里等于删掉约定本身）。
  **源码注释里的「对标 tauri …」同样保留**：它解释的是「这一处代码与 tauri 的哪个 API 对应」，是给贡献者
  的对照说明。
- **`npm/package.json` 的 `description` 同步**（下次 `npm publish` 生效）；官网 7 处、`README.md` 6 处、
  `npm/README.md`、`skills/` 三处、`examples/music/README.md`、`AGENTS.md` 两处，以及 `docs/` 下各篇文稿
  一并对齐。
  注：已发布到 CSDN 的那几篇线上正文标题仍是旧措辞，需人工同步（本仓库只改本地稿）。
- **官网示例区改成大图轮播（`website/`）**：原先只有 6 张实机大图，SQLite 浏览器 / HTTP 客户端 /
  Redis / MQTT / Markdown 笔记这几个只能排成一行文字（反馈原话是「后面的示例没有截图」）。现在
  **14 屏全是大图**，为此补抓 8 张实机截图入库（Xvfb + `xdotool` + ImageMagick 整屏抓后裁边再
  无损压缩；`website/` 合计仍只 1.7M，全部随仓库分发）。
  实现取**原生横向 `scroll-snap` 轨道**：脚本不跑也能拖能滚，`assets/app.js` 只往上加箭头 / 圆点 /
  序号 / 自动播放（跟随系统「减少动态效果」，悬停或聚焦即暂停），后建的按钮会把自己登记进语言
  切换表——否则英文态下这些按钮的 `aria-label` 还是中文。
  同时放宽整站宽度体系：容器 1140 → **1680**（1920 屏上左右留白从约 370px 降到约 120px），侧边距
  改成 `--gutter: clamp(20px, 2.4vw, 56px)` 跟着视口走；≥1600 视口再抬一档根字号（17px，
  ≥2100 → 18px 且容器 1980），免得容器宽了反而「字小框大」。轮播图宽度封顶 1180——容器放宽后
  16/10 会算出一屏塞不下的高度，封顶后图片接近自身比例，两端也不留黑边（该封顶值在本轮外观
  打磨里随「露一角」一起调到了 1320）。
  外观再打磨一轮（纯样式，无结构变动）：首屏放大（首屏 padding 104/112、标题 clamp 上限
  3.55 → 4.35rem、窗口与悬浮数据卡加大、标题区背后一层柔光聚焦）；分区节奏拉开（`section`
  92 → 112px、`sec-head` 下距 44 → 56px、kicker 与 `sec-title` 加力度、`.border-top` 叠一条
  淡渐变做章节落点）；宽屏密度（≥1400 卡内边距与正文字号跟着长、更多示例 3 项排 3 列）；
  轮播改「露一角」式（track `gap: 18px` + 每屏
  `calc(100% - 76px)`，图片封顶 1320 并加 `max-height: 78vh` 兜矮窗口）；配色质感（面板 /
  描边对比度各抬一档，卡片 / 特性 / 插件块补 hover，主按钮光晕 + 内高光，`--alt` 区渐变加深）。
  外观收口（仍只动 `style.css`）：首屏两列断点从 1080 提到 **1440**——1440 以下改单列堆叠
  （两列时文字栏只剩约 600px，中文标题会在词组中间断行、悬浮卡压正文），窗口图居中封顶 940；
  整个轮播封顶 **1360** 居中，让「露一角」的露出量与图片封顶对齐、两侧不留黑带；特性区
  （`.grid--3`，6 张卡）**不随大屏加列**——3 列正好两整行，加列会剩一张孤卡；架构区 4 项在
  1440 以下排 2 列；「更多示例」三张卡从左右两栏改上下两行（名字一行、说明一行），说明不再被
  名字占位挤成碎断行。
  验证：`scripts/site-check.sh` 新增 5 条轮播结构断言（屏数、每图 `width`/`height`、视口 / 轨道 /
  提示行、提示行英文、控件构造），jsdom 交互探针新增 20 条（点圆点 / 箭头 / 方向键 / `End` 回绕 /
  切换语言后控件标签），两处全绿。

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
- 文档：`docs/promotion/仓颉版Tauri-介绍与使用指南.md`（指南体）与 `docs/promotion/仓颉版Tauri-博客稿.md`（博客体）。
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
