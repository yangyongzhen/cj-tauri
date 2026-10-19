# ohos-probe —— 鸿蒙（ArkWeb）宿主实机探针

这个示例**不是**给人看的业务应用，是**鸿蒙宿主的验收台**：一装到真机上就自己跑一轮闭环，
把结论打到 hilog，用来回答「框架在鸿蒙上到底通没通」。

它与仓库里其他示例的区别：

| | 其他示例（`examples/hello` 等） | ohos-probe |
|---|---|---|
| 形态 | 仓颉工程（`cjpm run`），宿主走 C 桥 | DevEco 工程（hvigor 打 HAP），宿主**全在仓颉侧** |
| 平台 | Windows / Linux 桌面 | HarmonyOS 真机（`aarch64-linux-ohos`） |
| 入口 | `target/release/bin/main` | 桌面图标 / `aa start` 拉起 `EntryAbility` |
| 覆盖 | 桌面 GTK / WebView2 宿主 | `src/host_arkweb.cj`（ArkWeb）——桌面 e2e 够不到的那条路 |

## 它验什么

1. **桥注入**：页面里 `window.__CJ_TAURI__` 存在（document-start 注入赢了页面脚本）。
2. **命令往返**：页面 `system:version` → 原生返回值 → 页面再 `probe:hello` 回投，
   同时证明能力放行、命令分发、`post` 同步回调与 `poll` 回投都在工作。
3. **多窗口路由不串台**：两扇窗（`main` / `second`）各自报到，并定向给**对面**窗发
   `probe:ping`；判据是报文里「原生归属 `window=`」与「页面自认 `me=`」逐条恒等。
4. **原生对话框**（本轮新增，**只到编译级**）：页面 `dialog:message` → 框架排队 → 应用侧 `AlertDialog`
   弹出 → 用户点按钮 → 结果回投页面。这是「框架不碰 ArkUI、呈现交给应用」这条分工的样板。
   状态口径：HAP 构建通过（证明 `AlertDialog`、proxy 回调里取 `getUIContext()`、`ArrayList.remove(at:)`
   都能编），**真机呈现与点击回填未见证据**——判据是命令真的返回布尔值 + 对话框真的弹出来，
   按 AGENTS §1 不许先报通过。

## 前置

- DevEco Studio 6.1（自带 hvigor 与 node），并已配置仓颉（Cangjie）SDK `1.1.3`。
- 鸿蒙版 stdx（`linux_ohos_aarch64_cjnative`）。
- 真机已开开发者模式、能 `hdc` 连上（本仓验证机 `3QC0124B20000048`）。

## 环境变量

| 变量 | 用途 | 例子 |
|---|---|---|
| `DEVECO_WIN` | DevEco 安装根（Windows 形式）；不在默认路径才需要 | `D:\oh\DevEcoStudio` |
| `CANGJIE_STDX_OHOS` | 鸿蒙版 stdx 的 `dynamic/stdx` 目录 | `D:/cangjie-stdx-ohos/linux_ohos_aarch64_cjnative/dynamic/stdx` |

`entry/cjpm.toml` 里 stdx 那条写的是**相对路径** `../stdx`，指向工程根上的 `stdx` 联接
（Windows junction，不入库）。`build-hap.sh` 发现联接不存在时按 `CANGJIE_STDX_OHOS` 建一个，
之后 DevEco IDE 里直接点 Build 也能编——**这是相对路径 + 本机联接、而不是环境变量或占位符的原因**：

- 占位符 `${...}` 不行：hvigor 只替换它自己的模板变量（`${AARCH64_LIBS}` 那组），别的会被换成空串，
  而空串会让整条 `path-option` 一起失效，报错却是「imports package 'stdx.encoding.json' …
  not added as a dependency」，看着像 toml 漏配依赖（AGENTS §4 同款坑）。
- 本机绝对路径能编，但换机器要改文件，且 IDE 构建不经过本脚本，落地不了。

想手工建联接（等价于脚本那步）：`cmd /c mklink /J stdx <鸿蒙版 stdx>\linux_ohos_aarch64_cjnative\dynamic\stdx`。

`build-hap.sh` 还会自己补两件事，从命令行构建（headless）时缺一不可：

- `DEVECO_HVIGOR_CANGJIE_PLUGIN` → 自动在 DevEco 用户目录里找
  `plugins/devecostudio-cangjie-plugin-*/lib/hvigor/cangjie-build-support`。**缺它 hvigor 加载不到
  仓颉插件**，报的是 `entry/build-profile.json5` 里 `cangjieOptions` 不是合法属性（schema 校验失败），
  很像工程配置写错。DevEco IDE 里构建时由 IDE 喂，命令行构建必须自己给。
- `DEVECO_SDK_HOME` / `NODE_HOME` → 环境里预置的旧值若指向不存在的安装（本机就有一条
  `D:\Program Files\Huawei\DevEco Studio\sdk`），hvigor 直接判 `Invalid value of 'DEVECO_SDK_HOME'`；
  脚本会校验目录、无效就回退到 `$DEVECO_WIN` 下的路径并打一行提示。

框架侧（仓库根）另有 `AARCH64_LIBS` / `AARCH64_MACRO_LIBS` / `AARCH64_KIT_LIBS`，
由 hvigor 在编仓颉模块时注入，手搓 `cjpm` 命令才需要自己给。`AARCH64_LIBS` 这一组**不含 stdx**，
所以 stdx 那条必须留着。

## 构建 / 安装 / 启动

```bash
# 构建（产物：entry/build/default/outputs/default/entry-default-signed.hap）
bash build-hap.sh

# 安装 + 拉起（hdc 不在 PATH 时用绝对路径）
HDC=/d/oh/DevEcoStudio/sdk/default/openharmony/toolchains/hdc.exe
"$HDC" install -r entry/build/default/outputs/default/entry-default-signed.hap
"$HDC" shell aa start -a EntryAbility -b com.yang.testcj
```

签名：DevEco 自动签名（`build-profile.json5` 里的 `signingConfigs`）随本机生成，**不入库**；
换机器第一次请用 DevEco 打开工程、在 Project Structure → Signing Configs 里点一次自动签名。

## 怎么读证据

诊断只认 hilog（鸿蒙上 stderr 不可见），探针的 tag 是 **`CjTauriProbe`**：

```bash
# 先起日志流，再装/拉起应用——hilog 缓冲会滚动挤掉启动瞬间行，事后抓会缺
"$HDC" shell hilog > /tmp/ohos-probe-hilog.txt &
"$HDC" install -r entry/build/default/outputs/default/entry-default-signed.hap
"$HDC" shell aa force-stop com.yang.testcj
"$HDC" shell aa start -a EntryAbility -b com.yang.testcj
# 取证完停流
kill %1
grep -c "CjTauriProbe" /tmp/ohos-probe-hilog.txt
```

正常启动链（顺序稳定，缺哪行就卡在哪）：

```
CANGJIE-RUNTIME started
MyAbilityStage onCreated.
MainAbility OnCreated.EntryAbility
START_ABILITY
onWindowStageCreate.
host registered after 0 polls label=main
host pageUrl="file:///…/cj-tauri-main.html"
page begin label=main
```

判定口径：`page begin` / `page end` 各 2 条（两扇窗）、`probe:hello window=… -> target=…` 与
反向 `ping-recv me=… from=…` 成对、无 `SIGSEGV` / `panic` / `fatal`、
无 `command not allowed` / `command not registered`。

## 已知边界

- **不走 C 桥**：`native/platforms/harmonyos/` 目前只是契约（桌面 C 桥的实现与桩自检在那里），
  鸿蒙宿主是 `src/host_arkweb.cj` 一份仓颉实现；所以 `cj_bridge_*` 在这条路径上不出现。
- **框架包不许引用 ArkUI / ArkWeb kit**：`@Component` / `Web` / `javaScriptProxy` / `AlertDialog`
  全留在本示例的 `index.cj`，框架只经公开 API 与队列交接（引用 kit 会让静态包初始化链跳坏地址、启动即 SIGSEGV）。
- **URL 页面只能晚注入**：`run(html)` 的页面是框架先写沙箱文件再 `file://` 加载（能在 document-start 注入）；
  `startUrl` 加载远端页面时注入只能等到 `onPageBegin`，已在 stderr 说明一次。
- 更多真机踩坑（白屏死锁、hilog 与 eprintln 的差别、`@When` 的 `env` 口径等）见
  `docs/鸿蒙ArkWeb接入踩坑.md`。

## 和本机临时工程的关系

本目录是 `TestCj2`（此前用来打通鸿蒙宿主的临时 DevEco 工程）的入库版：源码一致，
路径改成了相对/环境变量（框架走 `../../..` 源码依赖）。以后再验鸿蒙，直接拿这份。
