# {{PROJECT_NAME}} — 仓颉 + ArkWeb 鸿蒙 PC 应用

用 [cj-tauri](https://atomgit.com/qq8864/cj-tauri) 生成的鸿蒙 PC（2in1）应用工程：
**仓颉后端（静态编译）+ 系统 ArkWeb 前端（HTML/CSS/JS）**，IPC、能力校验、命令分发与桌面版同一套框架代码。

## 目录

```
{{PROJECT_NAME}}/
├─ AppScope/app.json5               应用级配置（bundleName = {{BUNDLE_NAME}}）
├─ build-profile.json5              工程级构建配置（签名留空，见下）
├─ build-hap.sh                     构建入口（编 hap / 装到设备）
├─ entry/
│  ├─ cjpm.toml                     cjTauri 依赖 + aarch64-linux-ohos 目标段
│  ├─ build-profile.json5           cangjieOptions.checkDeviceTypes=false（放行 2in1）
│  └─ src/main/
│     ├─ module.json5               deviceTypes: 2in1 / tablet / phone
│     ├─ cangjie/
│     │  ├─ ability_stage.cj        AbilityStage
│     │  ├─ main_ability.cj         UIAbility：沙箱、rawfile 读取、窗口尺寸、loadContent
│     │  ├─ index.cj                ArkWeb 宿主组件（javaScriptProxy 双向桥）
│     │  └─ app_host.cj             框架装配 + demo 命令（greet / timer）
│     └─ resources/rawfile/
│        ├─ index.html              页面（改这里）
│        └─ capabilities.json       能力清单（改这里）
```

页面与能力清单是 **hap 里的真文件**（rawfile），运行期由 Ability 读成字符串交给框架——
所以 DevEco 里直接点 Build 也能编过，不需要先跑生成脚本。

## 构建 / 装到设备

```bash
# 1) 鸿蒙版 stdx（构建期要链它）
export CANGJIE_STDX_OHOS=<stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx

# 2) DevEco 安装根（脚本会自动探测几个常见位置，探测不到就自己给）
export DEVECO_WIN='D:\Program Files\Huawei\DevEco Studio'

# 3) 编 hap
bash build-hap.sh

# 4) 编完装到设备并拉起（需要设备已连上、应用已签名）
bash build-hap.sh --install
```

改了鸿蒙侧仓颉代码却没生效时：`bash build-hap.sh --clean`（hvigor 与框架 cjpm 各有一份增量缓存）。

## 签名

模板**不带证书**（调试证书由每台机器的 DevEco 本机生成、与华为账号绑定，不该入库）。
首次打开请在 DevEco 里 File → Project Structure → Signing Configs，
勾上「Automatically generate signature」。不签名也能编（产物是 `*-unsigned.hap`），但装不进设备。

## 改应用

- **加命令**：在 `app_host.cj` 里写 `CommandHandler` → `.register("名字", XxxCommand())` →
  在 `entry/src/main/resources/rawfile/capabilities.json` 的 `commands` 里声明。三处缺一处就用不了
  （只缺注册 → `command not registered`；只缺清单 → `command not allowed`）。
- **改页面**：`entry/src/main/resources/rawfile/index.html`，前端只经 `window.__CJ_TAURI__`
  的 `invoke` / `listen`，并且要**等桥出现**（ArkWeb 没有 document-start 注入）。
- **联网**：`module.json5` 已声明 `ohos.permission.INTERNET`；用不到就删掉。
- **窗口尺寸**：`main_ability.cj` 的 `applyDesktopWindowSize()` 取**逻辑尺寸 1000×700 vp**，
  用 `display.densityPixels` 折算成像素（本机密度 190% → 1900×1330 px）并按屏幕 82% 封顶，居中。
  两处别踩：`resize()` 收的是**像素**不是 vp（写死 vp 量级会得到一扇很小的窗）；
  `densityPixels` 是 **Float32**，跟 `Float64` 直接相乘编不过，先化成整数百分比再算。
  想要别的默认大小就改 `targetWVP` / `targetHVP` 两个数。

## 已知边界

- 只做了单窗口：`index.cj` 的 `EntryView` 挂一扇窗（label = `main`）。多窗口要按 label 各挂一个宿主。
- 鸿蒙侧 `javaScriptProxy` 的**返回值传不回页面**，回投靠页面心跳 + `runJavaScript` 推送
  （已在 `index.cj` 的 `onProxyPost` 里做好，业务代码不用管）。
- `app.run(html)` 的 `quit()` 只置退出意图，进程仍归系统管（需要真退就 `hdc shell aa force-stop`）。
- 更多平台细节与踩坑：`docs/鸿蒙ArkWeb接入踩坑.md`（框架仓库内）。
