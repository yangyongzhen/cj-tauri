# HarmonyOS ArkWeb 平台适配

状态（2026-10-19）：**宿主已在仓颉侧落地并在真机跑通完整闭环；C 桥未落地，宿主能力位仍全 0**。

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
- **宿主能力位全 0**——菜单、托盘、全局快捷键、拖放、原生对话框、剪贴板、通知、标题栏副标题
  一律如实拒绝（`hostCapabilities()` 返回 0）。按 AGENTS §1 门禁 4：**没有实机证据的能力位
  不许上报**，所以它们不会因为「代码里写了」就变成 1。

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

- [ ] HAP 能构建（DevEco 工程的 cangjie 插件装配目前仍未打通）
- [ ] 应用启动到 ArkWeb 页面，hilog 里没有 panic / fatal
- [ ] 前端 `invoke('system:version')` 往返成功，返回 `platform=ohos`
- [ ] 多窗口下宿主事件按 label 路由、不串台
- [ ] `llvm-nm -D --undefined-only <模块.so> | grep cj_bridge` 为 0 行

上面的勾**目前一个都没有**——这是 scaffold 阶段的正常状态，别把「代码写了」读成「验收过了」。
