# {{PROJECT_NAME}}

基于 [cj-tauri]({{FRAMEWORK_ROOT}})（仓颉版 Tauri）的应用：**仓颉后端 + 系统 WebView 前端**，
通过 `window.__CJ_TAURI__` 做 invoke/listen 双向 IPC，并由 capabilities 清单做最小权限管控。

## 目录结构（一份业务代码，骨架按目标派生）

```
{{PROJECT_NAME}}/
├── cj-tauri.toml           # 应用清单——单一真相（id/version/窗口/资产/能力目录）
├── cjpm.toml               # 业务包（static 库；骨架以 path 依赖引用）
├── src/main.cj             # 业务装配点 build(): AppSpec（零平台知识）
├── assets/
│   ├── ui/index.html       # 前端页面（任意 Web 技术栈）
│   └── capabilities/default.json   # 能力白名单（命令 / 事件 / 权限集）
└── targets/                # cj-tauri sync 生成的骨架（勿手改；check 判漂移）
    ├── desktop/            #   桌面可执行（launcher 调 build()）
    └── ohos/               #   鸿蒙 hap 工程（DevEco + build-hap.sh）
```

## 运行

```bash
cj-tauri sync     # 派生 targets/ 骨架（首次；重跑幂等）
cj-tauri dev      # 构建 C 桥 + 编译 + 启动窗口
cj-tauri build    # 仅构建
cj-tauri run      # 运行已构建产物
cj-tauri check    # 清单校验 + 骨架漂移 + 插件三方比对
```

## 鸿蒙端（PC / 2in1）

```bash
export CANGJIE_STDX_OHOS=<鸿蒙版 stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx
cd targets/ohos && bash build-hap.sh            # 编 hap
cd targets/ohos && bash build-hap.sh --install  # 编完装到设备并拉起
```

提示：模板不带签名证书——首次在 DevEco 里 File → Project Structure → Signing Configs
勾「Automatically generate signature」（要登录华为账号）；不签名只能编出
*-unsigned.hap，装不进设备。

## 命令与能力

**把骨架变成你的应用，改三处**：① `src/main.cj` 照 `GreetCommand` 写命令并在 `build()` 里 register；
② `assets/capabilities/default.json` 的 `commands` 里放行；③ `assets/ui/index.html` 里 `tauri.invoke`。

命令在 `src/main.cj`（`greet` / `timer` + 演示菜单），白名单在 `assets/capabilities/default.json`——
两边必须对齐：`cj-tauri check` 的三方比对会交叉核对「能力声明 × 插件自描述 × 实际装配」。
插件在某端没有实现时（如 shell/sqlite 在鸿蒙端），骨架照样编得过，运行期调用得到
可照做的「端不支持」错误（RFC-002 §4.6.4 的 P-1 桩）。
