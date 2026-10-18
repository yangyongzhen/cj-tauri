# 鸿蒙 ArkWeb 接入踩坑（第一段：框架核心在真机跑通）

> 记录日期：2026-10-18　探针工程：`E:/test/harmonyos/TestCj2`　真机：`3QC0124B20000048`（bundle `com.yang.testcj`）
> 配套阅读：`docs/进度记录.md` §四（本轮结论与证据表）、`AGENTS.md` §4（只留最锋利的两条）、
> `native/platforms/harmonyos/README.md`（宿主契约）、`docs/TAURI_TO_HARMONYOS_PORTING_GUIDE.md`（上游 Tauri 移植指南）
>
> 本文的定位：**AGENTS §4 是「一句话判据」，本文是「那天到底发生了什么」**——现象、误导性在哪、
> 试过什么、哪条路被数据否定、下次该按什么顺序查。凡标注「实测」的都有可复现命令或日志行；
> 凡是推断的会写明「未验证」。

---

## 0. 一句话结论

鸿蒙这一轮**不是**在接 ArkWeb 宿主（宿主与 C 桥都还没写），而是解决了一个更前置的问题：
**框架包能编进鸿蒙模块、在真机上初始化不崩、函数调用能通**。

白屏三轮的根因不在架构、不在 stdx、不在静态/动态链接形态，而在
`src/log_bridge.cj` 的三个核心包 `foreign func` —— 鸿蒙侧**没有 C 桥产物**，这些符号在模块 `.so` 里是 `U`，
模块加载期直接 SIGSEGV。修法是给它们加 `@When[arch != "aarch64"]` 门禁并在鸿蒙侧如实降级。

当前鸿蒙侧能力位一律为 0，`system:host` 如实报 0；这是 scaffold 阶段的正确状态，不是缺陷。

---

## 1. 根因与判据：核心包的裸 `foreign func` 在无桥平台上是加载期崩溃

### 1.1 现象

| 观察点 | 表现 |
|---|---|
| 应用 | 启动后**白屏**（窗口在，页面不出现），或秒退 |
| hilog | **一行 `AbilityStage.onCreate` 都没有**；只有 Cangjie 运行时自己的 `CANGJIE-RUNTIME` 行 |
| 崩溃记录 | `exit with signal:11`、`SIGSEGV(SEGV_MAPERR)`（地址看着像野指针，不是空指针），设备生成 `cppcrash-com.yang.testcj-*.log` |
| 构建 | **完全成功**，无警告、无错误——`cjpm build` / `hvigor` 都说 ok |

### 1.2 为什么极具误导性

1. **崩溃发生在仓颉包初始化阶段**，早于 `AbilityStage.onCreate`，所以任何「生命周期」日志都没有——
   看着像 ability 卡死、包 init 死锁、`LIFECYCLE_TIMEOUT` / `APP_FREEZE` 一类问题（实际上一轮排查里
   这两种结论都被写进了中间笔记）。
2. **运行时自己的日志照打**：`CANGJIE-RUNTIME` 行正常出现，会让人以为「运行时加载没问题，是框架的事」，
   而真相恰恰是**框架模块的符号没解析**——两者是同一件事，但日志上看不出因果。
3. **构建链完全沉默**：`foreign func` 没有函数体，编译器不校验「这个平台有没有实现」；
   未解析符号是**链接成 `.so` 之后**才留在动态度量里的。

### 1.3 判据（唯一可靠、且比任何运行期日志都直接）

```bash
# 模块 .so 里不该有任何 cj_bridge_ 未定义符号：必须是 0 行
llvm-nm -D --undefined-only \
  entry/target/aarch64-linux-ohos/release/ohos_app_cangjie_entry/libohos_app_cangjie_entry.so \
  | grep cj_bridge
```

- 健康：**0 行**。此时 297 个未定义符号**全是**运行时的 `CJ_MCC_*`——那是正常的，别跟着一起改。
- 中招：出现 `U cj_bridge_set_log_file` / `U cj_bridge_log_file` / `U cj_bridge_log_write`。
- 同一条命令也用于确认「动态依赖齐全」：`llvm-readobj -d` 里该有的 `.so` 都在就说明不是依赖问题。

修完的复验口径：**同一命令 0 行 + hilog 里 `MyAbilityStage onCreated` 重新出现**（两条缺一不可，
只看 0 行可能只是把代码删了）。

### 1.4 修法（已落地：`src/log_bridge.cj`）

FFI 声明与薄包装**同一口径**加门禁，鸿蒙侧如实降级，**不假装成功**：

```cangjie
@When[arch != "aarch64"]
@C
foreign func cj_bridge_log_file(): CString

@When[arch == "aarch64"]
public func writeLogLine(line: String): Bool {
    let _ = line
    return false          // 没有出口可写，如实回报
}
```

三处降级语义（`src/log_bridge.cj`，71 → 104 行）：

| 函数 | 鸿蒙侧行为 |
|---|---|
| `enableLogFile` | 返回 `false`，并打一行 stderr 说明「哪条路没走通」——**不抛异常**（调用方本就是尽力而为语义，抛了会把启动带走） |
| `currentLogFilePath` | 返回 `""`（与「未开启」同口径，调用方无需分支） |
| `writeLogLine` | 返回 `false`，不冒充已写入 |

### 1.5 同族风险面（落地新能力前先问一句「这个平台有桥吗」）

- `src/clipboard_bridge.cj`：**同类裸 FFI，尚未加门禁**。任何走剪贴板插件的鸿蒙应用会**原样复现本次崩溃**，
  所以剪贴板落地鸿蒙之前，第一件事是给它补 `@When`。
- 判据推广成一句话：**「谁调用谁包内的核心 FFI，在无 C 桥平台上就是一颗加载期地雷」**。
  `native/platforms/harmonyos/` 只有契约的期间，所有核心包 FFI 默认按「存在无桥平台」来写门禁。

### 1.6 下次崩溃排查顺序（照这个走，别再绕路）

1. `llvm-nm -D --undefined-only <模块.so> | grep cj_bridge` —— 0 行是前提，先确认；
2. hilog 里找**第一个**仓颉侧标记（`MyAbilityStage onCreated` / `MainAbility OnCreated`）：
   完全没有 → 崩溃在包初始化，不是生命周期；
3. `cppcrash-*.log` 看 `signal` 与 `SEGV_MAPERR` 地址（野指针形态倾向「未解析符号」而非空指针）；
4. 以上三步不通再看依赖（`llvm-readobj -d`）、再看 stdx、最后才怀疑链接形态。

---

## 2. 走过但被数据否定的三条路（别再走）

| 曾经的方向 | 怎么被否定 | 结论 |
|---|---|---|
| 「静态框架包硬链进动态根包 → 包初始化登记链不完整」 | 改 **cjpm 源码依赖**后症状**一模一样**（HAP 1387673 B，同样无 `onCreate`、同样 signal:11） | 否。链接形态不是因 |
| 「stdx 静态 + 动态重复链接」 | 产物里只有 51 个泛型 `.ti` 符号，没有第二份 stdx 实例 | 否。它在计数上不像 |
| 「`libcjTauri.a` 里只有一个 `cjTauri.o`（整包塞进单对象）是根因」 | 单对象只是链接粒度事实：一引就整包进来，与崩溃无因果关系 | 不是本次原因（但它是「手工 `-lcjTauri` 会把整包拉进来」的原因，见 §3） |

**方法论上的收获**：这三条都是「架构层听起来最像」的解释，而真因在一个**没人会去看的小文件**
（`log_bridge.cj`）里的**三个符号**。所以后面加了硬判据（§1.3），把「猜」换成「查」。

顺带记下的两条取证纪律（本轮实际吃过亏）：

- **锁屏 / 灭屏期间的应用运行状态与解锁后不可比**：灭屏时 `snapshot_display` 拍到的是锁屏时钟，
  A/B 对照前必须确认屏幕已解锁（`power-shell wakeup` + 上滑，或请人手动解锁）。
  解锁前的「白屏」截图不能当证据。
- **管道尾部的 `tail` 会掩盖真实退出码**：`cjpm build … | tail` 之后 `$?` 是 `tail` 的。
  判据一律落在**产物与日志里的具体行**，不看管道退出码。

---

## 3. 工程接法：cjpm 源码依赖（已验证）

`entry/cjpm.toml`（探针工程，38 行）：

```toml
[dependencies]
cjTauri = { path = "E:/test/harmonyos/test/cj-tauri" }
```

- `hvigor` 的 `CompileCangjie`（约 30–45 s）会按本模块（`output-type = "dynamic"`）需要的形态
  把框架各包编进来，**零额外配置**；产物里可见 330 个框架符号。
- 手工 `-L… -lcjTauri` 也能链（框架是单对象 `libcjTauri.a`，一引就整包进来），但
  **包初始化登记链不由 cjpm 负责**——那是没人维护的路径，**别再走**。
- 框架 `cjpm.toml` 保持 `output-type = "static"`（桌面包形态），不要为鸿蒙改成 dynamic。

**备份仍在探针工程里**（便于回头对照）：`entry-cjpm.toml.fwlink`（旧外部库版）、`entry-cjpm.toml.bak`（基线版）、
`index.cj.fwlink`（基线 43 行版）。注意 `cjpm` 会把 `src-dir` 下**每个子目录**当子包扫，
备份目录要放在源码目录**之外**，否则会被当成子包一起编译。

---

## 4. 平台判定：鸿蒙的 `os` 就是 `"Linux"`

这是本轮最容易被写错的一行条件编译：

| 写法 | 结果 |
|---|---|
| `@When[os == "ohos"]` | **编译期直接报** `error: builtin condition 'os' do not support 'ohos'…` |
| `@When[os == "HarmonyOS"]` / `"OHOS"` / `"OpenHarmony"` | 同样被拒；报错把支持列表原样吐出：`supported listed: 'Windows Linux macOS iOS'` |
| `@When[os == "Linux"]` | **命中**（鸿蒙目标下 `os` 取值就是 `Linux`，与桌面 Linux 撞车） |
| `@When[arch == "aarch64"]` | 命中鸿蒙；桌面 Linux 是 `x86_64` —— **当前唯一可用的判据** |

注意这条判据表达的是「架构」而不是「操作系统」，两个方向都会误伤：ARM64 桌面 Linux（鲲鹏 / 树莓派）
会落进鸿蒙分支，鸿蒙 x86_64 目标会落进桌面分支。它只是**在官方给出鸿蒙取值前的临时口径**——
`os` 的支持列表里已经有 `iOS` 却没有 `HarmonyOS`，属于遗漏而非取舍（cjnative 版手册反过来写着支持
`HarmonyOS`，文档与实现不一致），已提 [Cangjie/cangjie_compiler#1205](https://atomgit.com/Cangjie/cangjie_compiler/issues/1205)。
官方放开取值后，这里应收口成单条件、把 49 处两段写减半。

自定义条件（`--cfg "platform=ohos"`）能工作，但**未定义的自定义条件不是静默不命中、而是直接编译失败**
（`conditional compilation have not supported this condition: 'platform'`）——它会把平台判定变成对
应用 `cjpm.toml` / hvigor 构建 / 脚手架生成工程 / CI 每个入口的配置要求，漏一处即编不过，因此没被采用。

所以框架里所有「桌面 vs 鸿蒙」的分叉一律写成两段：

```cangjie
@When[os == "Linux" && arch != "aarch64"]   // 桌面 Linux：WebKit 宿主
@When[os == "Linux" && arch == "aarch64"]   // 鸿蒙：由应用注入宿主
```

配套的两条硬约束（`src/host.cj` / `src/host_factory.cj`）：

- **鸿蒙没有内置宿主**：`createHost()` 在 aarch64 分支走 `requireInjectedHost(label)`，
  应用必须在构造 `TauriApp()` **之前** `setHostFactory({ label => … })`；没登记就抛一条可照做的错误，
  **不静默回落到空实现**（宿主缺席时拿到一个永远开不出窗口的对象，比启动即失败更难查）。
- **句柄比较在鸿蒙侧不可用**：`hostHandleEquals` 没有 C 桥可问，只能如实判「按句柄路由不可用」
  并打一次 stderr——注入宿主自行管理回调，不要假装比较成功（假装会让多窗口事件串台）。
- 只在无桥平台用到的符号（如 `HOST_ROUTE_WARNED`）**声明也要放进同一门禁**：
  放在桌面分支会变成 `unused variable` 警告，而本仓要求**零警告**交付。

---

## 5. 构建与工具链（命令行打 HAP）

### 5.1 三件事必须分清

| 组件 | 本机路径 | 要点 |
|---|---|---|
| 鸿蒙版仓颉 SDK | `build-tools`（`CANGJIE_HOME` → `…\cangjie\build-tools`） | **交叉编译只能用它的 `tools/bin/cjpm`**；用桌面 cjpm 时 `--target=aarch64-linux-ohos` 会**静默回落**成 `x86_64-w64-mingw32` |
| 鸿蒙版 stdx | `/d/cangjie-stdx-ohos/linux_ohos_aarch64_cjnative/{dynamic,static}/stdx`（v1.1.3.1，dynamic 下 39 个 `.so`） | 用官方产物，**不要自编译**；路径写进 target 段的 `bin-dependencies` |
| OHOS native SDK | `D:\oh\DevEcoStudio\sdk\default\openharmony\native` | 只有 llvm + sysroot；指到纯 NDK 目录会报 `SDK component missing (00303168)` |

命令行构建需要的环境变量（`TestCj2/build-hap.sh` 与 `ohos-spike/build-ce.sh` 两处都把这一套写全了）：

```
CANGJIE_HOME          …\cangjie\build-tools
DEVECO_CANGJIE_HOME   …\cangjie
DEVECO_OH_NATIVE_HOME …\openharmony\native
DEVECO_SDK_HOME       …\openharmony
NODE_HOME             /d/oh/DevEcoStudio/tools/node        # 系统 node v24 不行
COMPILE_CONDITION_ENTRY APILevel_level=24,product=default,target=default
```

纯 cjpm 交叉构建的最小命令（用来快速验证框架本身编得动，不用等 hvigor）：

```bash
cd entry && cjpm.exe build --target=aarch64-linux-ohos -j10
```

### 5.2 hvigor：schema 与 daemon

- 模块的 `build-profile.json5` schema（`…\tools\hvigor\hvigor-ohos-plugin\res\schemas\ohos-module-build-profile-schema.json`）
  **没有 `cangjieOptions`** 段；报错形状是 `hvigor ERROR: 00303038 Configuration Error` +
  `Schema validate failed … entry\build-profile.json5`。
- DevEco **安装目录不可写**，也没有「schema 路径」的环境变量兜底；实测可用的补丁 schema 落在
  `%APPDATA%\Huawei\DevEcoStudio6.1\cj-plugin-cache\`，而它只在 **hvigor daemon 模式**下被读到。
  结论：**命令行构建走 hvigor 默认的 daemon 模式**，不要加 `--no-daemon`。
- 改 schema 属于「动了 IDE 的安装态」，**改前留备份、改后手动还原**。

### 5.3 签名：命令行打 HAP 的真实断点

这是本轮**唯一没打通**的一环，记清楚免得下次重走：

- `build-profile.json5` 里的 `storePassword` / `keyPassword` 是 **DevEco 机器绑定的密文**（前缀 `0000001B…`），
  而 `hap-sign-tool` 要的是**明文**——没有可用的口令就签名不出 p7b 包。
- 调试 profile（`*.p7b`）**绑死**这一个 `*.p12` + `keyAlias=debugKey`；换一套新密钥自签，设备直接拒装。
- 材料在 `C:\Users\yang\.ohos\config\default_TestCj2_*.{cer,p7b,p12}`。
- **不向任何人索取签名口令**；需要产物就走 DevEco 的 GUI 构建（或让 IDE 完成签名那一步），
  命令行只负责把 `.so`、HAP 产物路径与交叉构建验通。

### 5.4 `devecocli` 与 hdc 的关系

- `devecocli` 的设备管理器**初始化失败**（它自带的 `hdc.exe` 未数字签名）；本次改用 hdc 直连绕开，
  设备调试、日志、安装都不受影响。
- hdc 位置：`/d/oh/DevEcoStudio/sdk/default/openharmony/toolchains/hdc.exe`（**不在 PATH**）。
- Git Bash 下 hdc 的**远端绝对路径会被 MSYS 改写**：`hdc file recv /data/...` 要加 `MSYS_NO_PATHCONV=1`，
  或改用相对路径（截图拉取第一次就是这么丢的）。

---

## 6. 仓颉 ↔ ArkTS 互操作：已探到的形状（宿主尚未实现）

以下都是**编译探针时实测撞到**的约束，不是设计推演；宿主（ArkTS `Web` + `javaScriptProxy`）本身还没写。

| 报错 / 现象 | 含义 | 落法 |
|---|---|---|
| `error: 'javaScriptAccess' is not a member of class 'Web'` | 仓颉侧 ArkWeb 绑定的成员形状**不等于** ArkTS 文档上的属性名 | 以绑定的实际成员为准，别照 ArkTS 文档直写 |
| `error: undeclared type name 'LocalStorage'` | `@Entry` 宏生成的代码需要**通配导入**才可见 | 页面入口文件按通配导入写 |
| 绑定**没有 `loadData`** | `run(html)` 不能直喂字符串 | 落沙箱文件后走 `file://`（本次实测路径 `/data/storage/el2/base/haps/entry/files/probe.html`） |
| `String` 实现 `ResourceStr` | 资源参数可直接传字符串 | 无需额外转换 |
| `error: invalid binary operator '!=' on type 'CPointer<Unit>'`、`undeclared identifier 'hashCode'` | 句柄是 `CPointer<Unit>`，不能直接比较、没有 `hashCode` | 有 C 桥的平台走 `cj_bridge_host_eq`；无桥平台如实报「不可用」（见 §4） |
| `ability_loader.cpp73 failed:UIAbility` | 仓颉 UIAbility 的继承/签名与模板不一致 | 照官方仓颉模板的 Ability 形状写 |

**判据仍然按 AGENTS §1 第 4 条**：能力位在实现落地前一律报 0，未验证的能力写成「未实现」而不是「理论上可以」。

---

## 7. 真机取证方法（下轮直接复用）

### 7.1 流式 hilog（首选，别用一次性 dump）

```bash
hdc shell hilog > probe.log      # 流式落盘；进程起时就能看到的历史段也在
```

- 仓颉侧 `Hilog.info` 的 domain `1` + tag `Cangjie` 是可见的；应用自定义 tag（本次 `CjTauriProbe`）也在。
- 后台持续抓、前台做操作，事后按标记链 grep，比「先跑完再 dump」可靠得多（后者常常错过启动段）。

### 7.2 正常启动的标记链（八行，缺哪行就知道断在哪）

```
MyAbilityStage onCreated
MainAbility OnCreated.EntryAbility
probe page: file:///data/storage/el2/base/haps/entry/files/probe.html
MainAbility onWindowStageCreate.
CjTauriProbe: js -> native: ping
framework: platform=ohos version=1.0.0
CjTauriProbe: page end: file:///…/probe.html
```

- 前两行出现 = 包初始化没崩（本次修复的**直接凭证**）；
- `framework: platform=ohos version=1.0.0` = 框架函数在**页面里**真的执行了（IPC 往返成立）；
- 崩溃计数判据：同一窗口 `signal:11|SIGSEGV|LIFECYCLE_TIMEOUT|APP_FREEZE` 必须 **0**。

### 7.3 启动与截图

- `aa start` 要求**屏幕已解锁**；开发者模式下没法自动解锁，需要人工解锁后再测（灭屏时抓到的是锁屏时钟）。
- `snapshot_display` 出一张截图 = 人眼凭证；本轮 `fw-fixed.jpeg`（619 621 B）上能读到
  「cj-tauri · HarmonyOS ArkWeb 探针」与「往返成功: pong(ping) platform=ohos」——**这张图是本节的核心证据**。
- 截图与日志的判定都看**内容**，不看命令退出码；拉取时注意 §5.4 的 MSYS 路径改写。

---

## 8. 本轮门禁与判据清单（一条条能跑）

| 项 | 结果 / 判据 |
|---|---|
| 框架 `cjpm build` | **零警告**（含 `src/host.cj` 的 `unused variable:'HOST_ROUTE_WARNED'` 修复） |
| `bash scripts/test.sh` | **280/280** |
| `bash scripts/check-static.sh` | 全绿 |
| C 桥桩自检 | **221/221**（`native/tests/test_bridge_core.c`；须先重建 `libcjtbridge.dll`，陈旧桥会报一串 `undefined symbol: cj_bridge_*`） |
| 模块符号面 | `llvm-nm -D --undefined-only <模块.so> \| grep cj_bridge` → **0 行** |
| 真机 | HAP 安装成功、八行标记链齐全、崩溃行 0、截图人眼确认 |

**顺带修好的一个本机门禁缺陷**（与本 / 鸿蒙无关，但挡住过整条门禁）：`test_bridge_core.c` 的 `mkdir`
原先按 POSIX 两参写，本机 llvm-mingw 的 `mkdir` 是 MSVCRT 单参版，报
`test_bridge_core.c:1066 too many arguments to function` —— 已改成 `_WIN32` / POSIX 包装，两平台都能编。

---

## 9. 下一步（未完成，勿当成已完成）

1. **ArkWeb 宿主 + NAPI 桥**（按 `native/platforms/harmonyos/README.md` 的契约）：ArkTS `Web` 组件 +
   `javaScriptProxy` 注入 `window.__CJ_TAURI__`、生命周期与加载事件回投；C 桥按「同名同签名」承接 `cj_core_*`，
   **回调首参必须带 `struct cj_host *`**（AGENTS §2）。
2. **先给 `src/clipboard_bridge.cj` 加 `@When` 门禁**，再谈剪贴板插件——否则 §1 的崩溃原样复现。
3. 验收出口：ArkWeb 加载本地资源与 `CJ_TAURI_DEV_URL` → `system:version` IPC 往返 →
   宿主回调按句柄路由不串台 → HAP 真机（平板 / 2-in-1）→ hilog 无 panic/fatal → 桥 stderr 取证链路照旧。
4. 设备类型待确认：探针 `module.json5` 目前只声明 `phone` / `tablet`，**鸿蒙 PC（`2in1`）是否必须单独声明尚未验证**。
