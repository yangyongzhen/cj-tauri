# HarmonyOS ArkWeb 平台适配

状态（2026-10-24）：**宿主已在仓颉侧落地并在真机跑通完整闭环；C 桥未落地；宿主能力位已有 1 项
（菜单）取证落地，其余仍全 0**。

判据分三层，别混为一谈：

- **宿主基元已落地并真机验证**——建窗标签、页面装载（内联 HTML / URL）、document-start 桥脚本注入、
  报文接送（`post`）、结果回投（`runJavaScript` 推送）、页面事件回投、退出标志。
  真机闭环的判据是**页面自己发起**的一次往返：`system:version` 回到页面拿到
  `{"name":"cj-tauri","version":"1.0.0","protocol":"1","cangjie":"1.0.5","platform":"ohos"}`，
  应用自注册命令（`probe:log`）同链路返回 `"logged"`，同轮 hilog `SIGSEGV` 计数 0。
- **C 桥（`cj_core_*`）/ NAPI 层未落地**——鸿蒙侧不走 C 桥：宿主直接由仓颉侧 `src/host_arkweb.cj`
  实现，`@When[env == "ohos"]` 一平台一份。按 AGENTS §2，新增宿主能力仍是「先扩 `WebViewHost` 接口、
  再改各平台实现」，但不要求鸿蒙侧补同名 `cj_bridge_*` 导出（无 C 桥平台：核心 FFI 一律
  `@When` 门禁 + 如实降级，见 §4）。
- **宿主能力位：只有菜单置 1，其余全 0**——`CJ_CAP_MENU` 已于 2026-10-24 真机取证
  （点得动菜单项、原生回投 `{"kind":"menu","id":…}`、页面收到 `menu:click`，见文末「菜单能力位」）；
  托盘 / 全局快捷键 / 拖放 / 原生对话框 / 通知 / 标题栏副标题一律如实拒绝（对应位为 0）。
  按 AGENTS §1 门禁 4：**没有实机证据的能力位不许上报**，所以它们不会因为「代码里写了」就变成 1。
  注意「对话框」一项的边界：应用侧用声明式 overlay 能弹框（见 §4 踩坑清单），但那不是宿主能力，
  所以这个位仍是 0。
  另：**剪贴板没有能力位**（`native/core/bridge_core.h` 里只有 menu / tray / hotkey / dragdrop /
  dialog / notification / subtitle 那几位），所以下面「剪贴板」一节的落地**不改任何位**——
  插件可用与否只看宿主有没有实现 `clipboardWriteText` / `clipboardReadText`。

⚠️ **两条与桌面平台不同的硬约束**（真机踩过，改动前务必看）：

1. **`@Component` / `Web` / `javaScriptProxy` 属应用侧**，框架包不得引用 ArkUI——
   框架包作为独立编译单元引用 `kit.ArkUI` 会让鸿蒙包初始化链跳坏地址、启动即 SIGSEGV。
   框架只导出 ArkUI-free 的桥接函数（`src/arkweb_proxy.cj`）。
2. **`javaScriptProxy` 的返回值传不回页面**（实测恒 `null`）。回投必须**由原生推**：
   页面发 `{"type":"pull"}` 心跳，应用侧 proxy 回调（UI 线程）取 `takePendingScripts()`
   用 `controller.runJavaScript` 推送。详见 `docs/鸿蒙ArkWeb接入踩坑.md` §8.1。

## 形态：宿主在仓颉侧，不是 ArkTS + NAPI

本目录最初的设计假设是「ArkTS 托管 Web 组件 + NAPI 模块回投」，那条路**没有采用**。
实测结论：仓颉的 ArkUI 绑定（`kit.ArkUI` / `ohos.arkui.component.common`）能直接声明
`Web(src: controller:)` 组件、拿到 `WebviewController`，因此整个宿主可以写在仓颉里，
与桌面两平台共用同一套 `WebViewHost` 接口（`src/host.cj`）与同一层 IPC / 能力校验。

所以 `native/platforms/harmonyos/` **暂时没有 C 实现，也不需要**：

- framework 核心包在鸿蒙侧已无任何未解析的 `cj_bridge_*` 符号——所有核心 FFI 都带了
  `@When[env != "ohos"]` 门禁并在鸿蒙侧如实降级（`src/log_bridge.cj` 的日志落盘、
  `src/clipboard_bridge.cj` 的剪贴板/通知）。判据是一条命令：
  `llvm-nm -D --undefined-only <模块.so> | grep cj_bridge` 必须 **0 行**。
- 剩下的插件级 FFI（`src/plugins/serial/serial_bridge.cj`、`src/plugins/sqlite/sqlite_ffi.cj`）
  属于各自插件包，应用不引用就不链接；真要在鸿蒙用它们时，那是**插件**的事，不是本平台的桥。

什么时候才真的需要这座桥：某个能力**在仓颉 ArkUI 绑定里没有对应 API**、只能靠 NAPI 才能做到。
到那时按 AGENTS §2 补——导出名与桌面同名同签名（`cj_bridge_*`）、回调首参必须带
`struct cj_host *`、不要造新的静态单槽。

## 实现分布

| 文件 | 职责 |
| --- | --- |
| `src/host_arkweb.cj` | `ArkWebHost`（实现 `WebViewHost` 全部 31 个成员）+ `ArkWebRuntime`（运行时登记、沙箱目录、退出标志） |
| `src/arkweb_proxy.cj` | ArkUI-free 的两个代理函数（`arkWebProxyPost` / `arkWebProxyPoll`），由**应用侧** `@Component` 塞进 `javaScriptProxy` |
| `src/arkweb_script.cj` | 前端桥门面：`ARKWEB_BRIDGE_JS` + label 注入；回投靠页面 `setInterval` 发 `{"type":"pull"}` 心跳、原生推回去（**不是**返回值通道） |
| ~~`src/arkweb_view.cj`~~ | **已移出框架**：框架包一旦 `import kit.ArkUI.*`，鸿蒙上启动即 SIGSEGV（判据见踩坑文档 §9.2）。`@Component` / `Web` 只能由应用模块持有 |
| `src/host.cj` | 平台分叉点：`@When[env == "ohos"]` 下 `createHost` 取应用注入的宿主工厂 |

## 平台判据：只能用 `env`，不能用 `os` / `arch`

- 鸿蒙目标的 `os` **报 `Linux`**（实测），与桌面 Linux 撞车，分不开「GTK 宿主」和「ArkWeb 宿主」。
- `arch` 也不行：桌面 aarch64 Linux 同样是 `aarch64`，会把有 C 桥的桌面平台一起门禁掉
  （日志落盘能力会凭空消失）。
- 可靠判据是 `env`：`aarch64-linux-ohos` → `ohos`，桌面 → `gnu`。所以框架里所有鸿蒙门禁
  一律写 `@When[env == "ohos"]` / `@When[env != "ohos"]`。
- `system:version` 的 `platform` 字段在鸿蒙上如实返回 `ohos`（`src/version.cj`）。

## 与桌面宿主的行为差异（已知且有意）

1. **窗口配置不生效**：窗口归 Ability 的 `WindowStage`，`setWindowConfig` 只留一行 stderr。
   能力位里没有窗口控制位。
2. **内联 HTML 落沙箱文件**：ArkWeb 的 `WebviewController` **没有 `loadData`**，所以
   `run(html)` 先把页面写进应用沙箱再以 `file://` 装载；沙箱目录由
   `ArkWebRuntime.configure(filesDir)` 提供，未配置时**明确拒绝**而不是白屏。
3. **没有 UI 定时器**：ArkUI 绑定不暴露 UI 线程定时器，也没有 `UIContext`。页面到原生的
   回投改成「页面侧 `setInterval` 调同步 `javaScriptProxy` 的 `poll`」，页面求值在页面
   自己的线程上执行——避免把宿主 UI 线程当消息泵。
4. **`quit()` 只置标志**：窗口归 Ability，退出得应用自己 `terminateSelf()`；
   框架不假装关掉了窗口。
5. **宿主句柄没有跨平台相等语义**：`hostHandleEquals` 在鸿蒙侧返回 false 并留一行 stderr。
   多窗口路由在鸿蒙上靠 window label，不靠句柄——**绝不伪造相等**（伪造会让两个窗口串台）。

## 验收出口（未完成的都在这里）

真机（平板 / 2-in-1；手机需单独声明）上要拿到的证据，按 AGENTS §1：

- [x] HAP 能构建（`entry-default-signed.hap`）
- [x] 应用启动到 ArkWeb 页面，hilog 里没有 panic / fatal（同轮 `SIGSEGV` 计数 0）
- [x] 前端 `invoke('system:version')` 往返成功，返回 `platform=ohos`
- [x] 多窗口下宿主事件按 label 路由、不串台
- [x] `llvm-nm -D --undefined-only <模块.so> | grep cj_bridge` 为 0 行

前四项与最后一项是 2026-10-19 两轮真机闭环的取证结果（过程见
`docs/鸿蒙ArkWeb接入踩坑.md` §8.1 / §8.2）。多窗口那条的判据（同一台真机、同一份 HAP）：

- 两个 `@Component` 实例各带自己的 label（`main` / `second`），上层宿主登记里出现两行
  `host pageUrl label=main url="…/cj-tauri-main.html"` 与 `…cj-tauri-second.html`
  ——**页面文件按 label 分开**，两窗看的不是同一份 HTML；
- 两窗各自 `page begin label=main` / `label=second`，两窗各完成一次 `probe:hello`；
- 跨窗**定向**投递双向成立：`probe:hello window=main -> probe:ping target=second` 之后是
  `probe:log window=second <- {"kind":"ping-recv","me":"second","from":"main"}`，反向同理；
  每条报文里 `window=`（原生侧归属）与 `me=`（页面自认的 label）**逐条恒等**——这就是「不串台」；
- 同轮 `SIGSEGV` / `panic` / `fatal` 计数 0，`command not allowed|registered|rejected` 计数 0。

## 菜单能力位（2026-10-24 真机取证）

**结论：`CJ_CAP_MENU` 置 1。** 分工与桌面两平台一致——框架只管「模型 → 宿主」的翻译与报文回投，
**渲染在应用侧**（鸿蒙的 `bindMenu` 只接受应用侧组件上的 `Array<MenuElement>`，框架包不能碰 ArkUI，
见上面的硬约束 1）：

| 环节 | 位置 | 做什么 |
| --- | --- | --- |
| 模型 | 框架 `src/arkweb_menu.cj` | `MenuModel` / `MenuItem` → 扁平 `Array<MenuElement>`（标题、勾选标记、分隔线），并解析宿主回投的 `{"kind":"menu","id":…}` |
| 渲染 | 应用侧 `cli/templates/ohos-skeleton/entry/src/main/cangjie/index.cj` | `Button("菜单").bindMenu(...)` + 点击回调 `noteMenuClick(id)`，顺带一行 hilog `menu click label=… id=…` |
| 回投 | 框架 `src/host_arkweb.cj` | shell 报文 → 应用 `onShellEvent` → 页面 `menu:click` 事件（需在能力清单 `events` 声明） |
| 状态 | 应用侧 + `menu` 插件 | `menu:setChecked` / `setEnabled` 命令 → 宿主 `setMenuItemState`，应用侧留存「另一维状态」后重新 `bindMenu` |

真机判据（`examples/ohos/ohos-capabilities`，`hdc shell hilog` 原样摘录）：

```
CjTauri: menu click label=main id=view.sidebar
CjProbe: PASS menu click id=view.sidebar enabled=true checked=false
CjProbe: PASS cap menu expect=true actual=true
CjProbe: PASS menu setChecked view.sidebar=true
```

- **原生侧真的收到点击**：`menu click` 那行由应用侧组件在 `bindMenu` 回调里打印（设备上框架 stderr
  不进 hilog，只有应用侧 `Hilog.info` 抓得到）；
- **回投真的到了页面**：`PASS menu click id=…` 是页面在 `menu:click` 回调里发出的断言，
  `enabled` / `checked` 与弹窗里看到的状态一致；
- **两个方向都通**：页面 `menu:setChecked` → `menu` 插件 → 宿主 `setMenuItemState` → 下一次 `bindMenu`
  的勾选态，所以页面那行 `PASS menu setChecked` 不是自说自话。

**已知限制（`bindMenu` 的形状决定，不是没实现）**：菜单是**一层扁平**结构——`MenuElement` 没有
禁用位、也不能嵌套子菜单，所以 `MenuItemKind.Separator` 与 `Submenu` 在鸿蒙侧被**拍平**成普通项
（分隔线渲染成一条横线项，子菜单的项按顺序平铺）；`setMenuItemState` 的 enabled 改动在鸿蒙侧
**只能改灰（不参与点击高亮）**，不能真正禁用。要完整的层级/禁用语义得等宿主侧自绘菜单，
在那之前文档与示例按「扁平菜单」表述，别照桌面示例的嵌套树写。其余四项能力位（托盘 / 快捷键 /
拖放 / 对话框）仍为 0，各有各的阻断原因：

- **托盘 / 全局快捷键**：鸿蒙没有桌面级托盘与系统级热键 API（`2in1` 也没有），如实拒绝；
- **原生对话框**：`showAlertDialog` / `getPromptAction().showDialog` 在 `javaScriptProxy` 回调的
  同步栈上会被**静默丢弃**（真机四轮对照，见 §4 与 `docs/鸿蒙ArkWeb接入踩坑.md` §10.11），
  应用侧只能用声明式 overlay——那不是宿主能力；
- **文件拖放**：组件有 `onDrop`，但路径来自系统 drag 事件而非桥，且没有 `DragDropPolicy`
  的「start 前定稿」语义，未做能力位。

## 剪贴板（2026-10-24 真机取证：写通，读被平台门槛挡住）

鸿蒙的仓颉 SDK 6.1 **没有 `ohos.pasteboard` 绑定**（340 个 ohos 包里一个都没有，只有旧的 5.0 Beta 带），
所以走系统原生 C API：`src/clipboard_bridge.cj` 的 `@When[env == "ohos"]` 段用 `foreign func` 直连
`libpasteboard.so`（`OH_Pasteboard_*`）与 `libudmf.so`（`OH_Udmf*` / `OH_UdsPlainText_*`）。

### 链接：开关必须落在 entry 模块，不是框架

`OH_Pasteboard_*` 与 `OH_Udmf*` 分属两个库，**两个都要链**：

```toml
[target.aarch64-linux-ohos]
  link-option = "-lpasteboard -ludmf"
```

落点是**入口模块的 `entry/cjpm.toml`**（`output-type = "dynamic"`，最终链接发生在那儿）。
写进框架自己的 `cjpm.toml` 不生效——生成器 `cli/src/manifest.cj` 的 `renderOhosEntryToml` 会重写
`targets/ohos/entry/cjpm.toml`，漏了这条的表现是：`libohos_app_cangjie_entry.so` 里留一堆
`U OH_Pasteboard_*`、`DT_NEEDED` 里**没有** `libpasteboard.so`/`libudmf.so`，应用**启动即 SIGSEGV**
（模块加载期解析不到符号，表象与「白屏 / 秒退」同形，见 AGENTS §4）。
判据两条，缺一不可：`readelf -d <模块.so> | grep -E "pasteboard|udmf"` 有输出、`nm -D --undefined-only`
里的 `OH_*` 能被 NEEDED 解释。设备侧这两个库在 `/system/lib64/ndk/`（`ls` 该目录本身是 Permission
denied，用 `hdc shell stat -L /system/lib64/ndk/libpasteboard.so` 查）。

### 写能通，读要权限，而普通应用拿不到那个权限

| 方向 | 原生 API | 权限要求 | 真机结果 |
| --- | --- | --- | --- |
| 写 | `OH_Pasteboard_SetData` | 无 | **PASS** |
| 读 | `OH_Pasteboard_GetData` | `ohos.permission.READ_PASTEBOARD`（头文件注明） | 状态码 **201**（`ERR_PERMISSION_ERROR`），框架如实返回 `null` |

`ohos.permission.READ_PASTEBOARD` 在设备上的定义是 `USER_GRANT` + `SYSTEM_BASIC`（`atm dump -d -p` 可查）。
它是 `user_grant`，所以 `module.json5` 里必须带 `reason` + `usedScene` 才过 schema；但更关键的是
**`SYSTEM_BASIC` 要签名 profile 里有 ACL**——普通调试证书把这条写进 `requestPermissions` 之后，
**连装包都失败**：

```
code:9568289 error: install failed due to grant request permissions failed. PermissionName: ohos.permission.READ_PASTEBOARD
```

所以**不要把这条权限写进骨架模板**（`cli/templates/ohos-skeleton/entry/src/main/module.json5`）：
那会让所有 `cj-tauri sync ohos` 的工程装不上。当前的落地是「写完整可用、读如实返回 `None`」，
探针页把读被拒记成 `SKIP clipboard read denied-by-platform`（不是 `FAIL`：这是平台准入门槛，
不是框架回归；也不是 `PASS`：没读回内容就不许说通）。
要真正读到内容，得由应用方自己拿带 ACL 的签名 profile，再按平台要求做运行时授权——
框架不替应用做这条确认，也不假装读到。

真机判据（`examples/ohos/ohos-capabilities`，`hdc shell hilog` 摘录）：

```
CjProbe: PASS clipboard write cj-tauri-clip-<时间戳>
CjProbe: SKIP clipboard read denied-by-platform (needs READ_PASTEBOARD; write verified)
```

一轮 9 PASS / 0 FAIL（含菜单那三条与能力位对账）。读的状态码用一次**临时诊断**取得
（把 `statusBox.read()` 拼进返回值），取证后已撤——现在框架返回的就是契约里的 `None`。

