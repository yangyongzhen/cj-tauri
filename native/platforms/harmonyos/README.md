# HarmonyOS ArkWeb 平台适配（预留，未实现）

状态：**scaffold——只有契约，没有实现**。本目录为鸿蒙 ArkWeb 后端预留，当前框架的
平台实现只有 Linux（WebKitGTK）与 Windows（WebView2）；能力位如实上报的纪律从桩阶段
就开始遵守，所以在实现落地之前，`system:host` 对本平台的能力位应报 0，任何「实现了」
的说法都必须有实机证据（AGENTS §1 门禁 4）。

## 定位

按「scaffold 先行、契约驱动」的平台接入惯例组织（HarmonyOS 侧
不是又一个 `bridge_*.c`——ArkWeb 宿主运行在 ArkTS/ArkUI 世界里，仓颉侧经 NAPI 互操作，
因此本平台的形态预计是：

- `bridge_hos.c`（或 NAPI 模块）：实现与 `bridge_core.h` 相同的 `cj_core_*` 调用点，
  对上承接 `cjTauri` 框架包的 `foreign func` 导出约定；
- ArkTS 侧 Web 组件托管 + `javaScriptProxy` 注入桥（ArkWeb 的标准桥接形状：
  原生对象暴露 `invoke`，页面侧 `runJavaScript` 装 `window.__CJ_TAURI__` 门面）；
- 生命周期与页面加载事件回投（对应 Linux/Windows 的 shell 事件 / 销毁回调，**回调签名
  首参必须带 `struct cj_host *`**，见 AGENTS §2）。

## 共同契约（必须实现或明确拒绝，不得静默降级）

与 Linux/Windows 一致（AGENTS §2 硬约束：两平台导出名同名同签名，本平台加入后是三平台）：

- native window / local resource（`run(html)` 与 `runUrl`，含 `file://`）/ dev URL
  （`CJ_TAURI_DEV_URL`）；
- WebView 生命周期 + JS 桥（document-start 注入，早于页面脚本）；
- 宿主回调按句柄路由（`HostGlobals.hostRoutes`），消息回调例外（报文自带 label）；
- 能力校验、命令分发、scope 判定**不走平台代码**——它们在共享层（`src/capability.cj` /
  `src/ipc_hub.cj` / `src/scope.cj`），平台只做窗口与注入；
- 未实现的能力返回结构化失败（对齐 Windows 桩先例：通知返回 `-4` + 能力位报 0），
  禁止「看起来成功」的假实现。

## 验收出口（按平台支持分级惯例）

DevEco 工程可生成并打开 → ArkWeb 加载本地资源与 dev URL → IPC 往返（`system:version`）
→ 宿主回调按句柄路由不串台 → HAP 真机（平板 / 2-in-1，手机须单独声明）→ 桥 stderr
取证链路照旧（`js -> native` 计数吻合、`ExecuteScript -> hr=0x00000000` 同款证据）。

## 构建依赖（届时补充）

DevEco Studio / HarmonyOS SDK / NAPI 工具链；`build_harmonyos.sh`（命名对齐
`build_linux.sh` / `build_win.bat`）与 `cjpm.toml` 的 target 段在实现轮补，不提前发明
未验证的平台标识（AGENTS §4：`@When` 只写已验证的取值）。
