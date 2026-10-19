# 鸿蒙 ArkWeb 接入踩坑（两段：框架核心跑通 + 宿主落地真机闭环）

> 记录日期：2026-10-18（§1~§8）；2026-10-19 补记（§8.1 组件接入、§9 失败总账、§10 构建链假阴性、§11 语言差异）
> 探针工程：`E:/test/harmonyos/TestCj2`　真机：`3QC0124B20000048`（bundle `com.yang.testcj`）
> 配套阅读：`docs/进度记录.md` §四（本轮结论与证据表）、`AGENTS.md` §4（只留最锋利的两条）、
> `native/platforms/harmonyos/README.md`（宿主契约）、`docs/TAURI_TO_HARMONYOS_PORTING_GUIDE.md`（上游 Tauri 移植指南）
>
> 本文的定位：**AGENTS §4 是「一句话判据」，本文是「那天到底发生了什么」**——现象、误导性在哪、
> 试过什么、哪条路被数据否定、下次该按什么顺序查。凡标注「实测」的都有可复现命令或日志行；
> 凡是推断的会写明「未验证」。

---

## 0. 一句话结论

> 本节是**第一段（2026-10-18）**的结论；第二段（2026-10-19 宿主落地 + 真机闭环）见 §8.1，
> 两段合起来的**失败尝试总账**见 §9（16 条，含每条被什么数据否定）——那张表才是「下次别再走」的入口。

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
@When[os == "Linux" && env != "ohos"]   // 桌面 Linux：WebKit 宿主
@When[env == "ohos"]   // 鸿蒙：由应用注入宿主
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

## 6. 仓颉 ↔ ArkTS 互操作：已探到的形状

以下都是**编译/真机时实测撞到**的约束，不是设计推演。本节写于宿主尚未实现时（2026-10-18），
其中「绑定形状 ≠ ArkTS 文档」那几条到宿主落地（2026-10-19，见 §8.1 / §9.2）时仍然成立。

| 报错 / 现象 | 含义 | 落法 |
|---|---|---|
| `error: 'javaScriptAccess' is not a member of class 'Web'` | 仓颉侧 ArkWeb 绑定的成员形状**不等于** ArkTS 文档上的属性名 | 以绑定的实际成员为准，别照 ArkTS 文档直写 |
| `error: undeclared type name 'LocalStorage'` | `@Entry` 宏生成的代码需要**通配导入**才可见 | 页面入口文件按通配导入写 |
| 绑定**没有 `loadData`** | `run(html)` 不能直喂字符串 | 落沙箱文件后走 `file://`（本次实测路径 `/data/storage/el2/base/haps/entry/files/probe.html`） |
| `String` 实现 `ResourceStr` | 资源参数可直接传字符串 | 无需额外转换 |
| `error: invalid binary operator '!=' on type 'CPointer<Unit>'`、`undeclared identifier 'hashCode'` | 句柄是 `CPointer<Unit>`，不能直接比较、没有 `hashCode` | 有 C 桥的平台走 `cj_bridge_host_eq`；无桥平台如实报「不可用」（见 §4） |
| `ability_loader.cpp73 failed:UIAbility` | **曾经的归因写错过**：不是「UIAbility 继承/签名与模板不一致」，真正同轮出现它的时候 `entry/libs/arm64-v8a/ohos/` 里放着 SDK 的 `kit.*` mock，而 mock 的 `libkit.AbilityKit.so` NEEDED `libcangjie-std-core.so`（§9.3） | 先清 mock 目录再排查 Ability 形状；Ability 名与 `module.json5` 对齐（§10.4） |

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

## 8.1 组件侧接入与取证的新坑（2026-10-19 真机实测）

### 8.1.1 `build()` 读到的页面地址是空串 → 白屏死锁

`@Component` 的 `build()` 是**声明式的一次性求值**，而宿主把内联页面落盘后的 `file://` 地址
只存在**宿主对象**上；组件自己那个字段初值是 `""`。于是首帧 `if (pageUrl.size > 0)` 不成立 →
不建 `Web` → `onPageBegin` 永远不来 → 而原设计的「地址同步点」恰好就在 `onPageBegin` 里 →
**死锁，页面永远白屏**。

判据（两个信号必须一起看）：
- hilog 有 `BindWebTagToWebInstance webTag:arkweb:0`（Web 组件**确实**建过）
- 但 `page begin` / `page end` **一条都没有**，截图是纯白

修法：在 `aboutToAppear()`（首次 `build()` 之前调用一次）里从宿主取 `currentUrl()` 写进 `@State`。
**不要**指望 `@State` 自己从宿主刷新——它只在**组件自己赋值**时触发重绘；
宿主在别的线程改自己的字段，组件永远是旧值。先打印一次 `h.currentUrl()` 确认地址确实非空
（本机是 `file:///data/storage/el2/base/haps/entry/files/cj-tauri-main.html`）。

### 8.1.2 `@State` 不允许带 `private` / `public`

`@State private var pageUrl: String = ""` 直接编译失败，去掉修饰符写 `@State var pageUrl` 即可。
宏对装饰器与访问修饰符的组合有硬约束，报错文案指向修饰符那一条。

### 8.1.3 `Hilog.info` 带**整型**插值会落到 4 参数重载

`Hilog.info(1, "tag", "len=${result.size}")` 报「缺少第 4 个参数 `Array<String>`」——
`result.size` 是整型，插值后编译器选了 4 参重载。同一行里换成固定串
（`Hilog.info(1, "tag", "runJavaScript ok")`）就编过。字符串插值（`${e.message}`）没这个问题。

### 8.1.4 一次性 `hilog -x` 会把启动瞬间那几行滚掉

`hilog -r` 清空 → 启动应用 → 等十几秒 → `hilog -x`，这中间系统日志能刷到三千多行，
把我们的 5~10 行挤出环形缓冲；**`hilog -x -T Cangjie` 也一样取不到**（`-x` 导出的就是已经滚动的缓冲，
过滤发生在导出之后）。

判据：同一轮 `ps` 显示进程活着（`:gpu` / `:render` 都在），但 `Cangjie` tag 计数 **0** ——
不是没打日志，是滚掉了。取证一律**流式**：先起 `hdc shell hilog > file`（后台作业）→ 再启动应用 →
等 15 秒 → 停掉抓取 → 再 grep 文件。本轮靠这条才看到 `page begin` / `runJavaScript ok`。

### 8.1.5 桥脚本的 `post` 是静默的，抛异常要靠页面自己暴露

`ARKWEB_BRIDGE_JS` 里 `post()` 用 `try { ... } catch (e) { }` 吞掉一切异常——`javaScriptProxy`
调用若失败，页面完全无感，那条 `invoke` 的 promise **永久 pending**（页面停在 `-`，既不 resolve 也不 reject，
看起来像「命令没执行」，其实可能是通道根本没通）。

诊断要在页面里**绕过桥**做三件事，并把结果写进 DOM（截图即证据）：
1. `typeof window.__CJ_TAURI_HOST__` 与 `typeof window.__CJ_TAURI_HOST__.post` —— 判 `javaScriptProxy` 有没有注入；
2. 直接 `post('{...}')` 并用 try/catch 抓异常 —— 判同步调用本身是否可用；
3. `setTimeout` 后打一次 `poll()` 并把返回值截断显示 —— 判仓颉侧队列里有没有回投脚本。

本轮实测：前两项**都是好的**（`host=object / post=function / manual post ok`），
所以问题不在注入通道，得继续往 `messageHandler` → `IpcHub` → 回投这条线上查。

### 8.1.5.1 **`javaScriptProxy` 的返回值传不回页面**（决定性，2026-10-19 真机）

按桌面 C 桥的形状，鸿蒙侧原本用「页面 `setInterval` 调 `poll()` 取回待执行脚本」当回投泵。
真机上**收不到**：页面显示 `poll -> null`，而页面 → 原生方向的 `post` 一切正常
（`host=object / post=function / manual post ok`）。

隔离实验（不碰框架，只改应用侧 `javaScriptProxy` 的 `funcList`）：
把 `poll` 换成**无条件返回固定串** `{ _ => "poll-probe" }`，页面拿到的仍是 `null`。

结论：**仓颉侧 `funcList` 的返回值不会回到 JS**——参数能进去、枚举顺序也对（`methodList`
里的 `post` / `poll` 都能调），但返回值是 `null`。所以「页面拉、原生答」这种同步取数模型在
鸿蒙侧不成立，`ARKWEB_BRIDGE_JS` 里那个 `poll` 泵必须换掉。

可行的方向：**反过来由原生推**。`controller.runJavaScript(script, cb)` 是通的
（`onPageBegin` 里注入桥脚本就是这条，日志有 `runJavaScript ok`），且 `post` 的回调本身
就在 UI 线程上——所以让页面 `setInterval` 发一条 `{"type":"pull"}` 心跳，仓颉在 `post` 回调里
（UI 线程，可安全碰 controller）把队列里的脚本用 `runJavaScript` 推出去即可。
**注意返回值的教训是通用的**：不要把「同步方法有返回值」当成可用通道，先用一个固定串验一遍。

### 8.1.6 `hdc file recv` 的**本地**路径也要 Windows 形式

远端路径加 `MSYS_NO_PATHCONV=1` 只解决了远端那一半；本地目标写成 `/e/test/...` 会被 hdc 拼成
`E:\test\...\test\cj-tauri\e\test\...` 之类，然后 `FileTransfer finish` 照报成功、文件却不在预期位置。
本地路径用 `'E:\test\harmonyos\.romdump\shot.jpeg'` 这种**带盘符的 Windows 形式**。

---

## 9. 失败尝试总账（每条都写清「被什么数据否定」，别再重走）

> 这一节是全文的索引：**凡走过的错路都在这里**，包括那些「架构层听起来最像」的方向。
> 已有专节的不重复细节，只给交叉引用；§9.2~§9.4 是之前没落成文字的三段。

### 9.1 全表（16 条）

| # | 曾经的方向 | 怎么被否定（可复现的数据） | 结论 |
|---|---|---|---|
| 1 | 「静态框架包硬链进动态根包 → 包初始化登记链不完整」 | 改 **cjpm 源码依赖**后症状**一模一样**（HAP 1387673 B、同样无 `onCreate`、同样 signal:11） | 否，链接形态不是因（§2） |
| 2 | 「stdx 静态 + 动态重复链接」 | 产物里只有 51 个泛型 `.ti` 符号，没有第二份 stdx 实例 | 否（§2） |
| 3 | 「`libcjTauri.a` 里只有一个 `cjTauri.o`（整包单对象）是根因」 | 单对象只是链接粒度事实，一引就整包进来，与崩溃无因果关系 | 不是本次原因（§3 解释了「手工 `-lcjTauri` 会把整包拉进来」） |
| 4 | **核心包裸 `foreign func`（真因）** | `llvm-nm -D --undefined-only` 里 `U cj_bridge_*` 三个；加 `@When` 门禁后同一命令 **0 行** + `MyAbilityStage onCreated` 回归 | **是**（§1） |
| 5 | 「让框架包直接持有 `@Component` + `Web`」（`src/arkweb_view.cj`） | 三组对照：入口包自写组件**正常启动**；入口包只引框架一个字符串常量**照样崩**；把唯一碰 ArkUI 的文件移出编译**立刻正常** | 否：**ArkUI 声明式组件只能由应用模块持有**（§9.2） |
| 6 | 「把框架改成 `output-type = "dynamic"` 绕开崩溃」 | 同样崩，且落点更糟：`[anon:cangjie_heap]` 里 `SEGV_ACCERR` | 否，形态不是因（§9.2） |
| 7 | 「把 SDK 的 `kit.*` mock 拷进 `entry/libs/arm64-v8a/ohos/` 补上符号」 | SDK mock 只有 `_CGP9ohos.mock*`，**没有** ROM 的 `_CGP9kit.ArkUIiiHv`；mock 的 `libkit.AbilityKit.so` 还 NEEDED `libcangjie-std-core.so` | 否：**别把 kit.* mock 塞进包**（§9.3） |
| 8 | 「页面 `setInterval` 调 `poll()` 从原生同步取数」 | 固定串隔离实验：`poll` 换成 `{ _ => "poll-probe" }`，页面拿到的仍是 `null` | 否：返回值通道不可用，改「原生推」（§8.1.5.1） |
| 9 | 「在 `build()` 里同步宿主页面地址」 | `build()` 是一次性求值、组件字段还是初值 `""` → 不建 `Web` → `onPageBegin` 永不到 → 白屏死锁 | 否，改 `aboutToAppear()`（§8.1.1） |
| 10 | 「自定义编译条件 `--cfg platform=ohos`」 | 未定义的自定义条件**不是静默不命中、而是直接编译失败**，等于要求应用 cjpm.toml / hvigor / 脚手架 / CI 每个入口都配 | 否，用 `env`（§4） |
| 11 | 「`@When[os == "HarmonyOS"]` / `"ohos"` / `"OpenHarmony"`」 | 编译器一律拒，并把支持列表原样吐出：`Windows Linux macOS iOS` | 否，`os` 在鸿蒙下就是 `"Linux"`（§4） |
| 12 | 「手工 `-L… -lcjTauri` 塞框架 static 产物」 | 链得过（单对象一引整包进），但**包初始化登记链不由 cjpm 负责** | 否，走 cjpm 源码依赖（§3） |
| 13 | 「用 `devecocli` 的设备管理器」 | 它自带的 `hdc.exe` 未数字签名，初始化直接失败 | 否，`hdc` 直连（§5.4） |
| 14 | 「命令行 `hap-sign-tool` 打签名包」 | `storePassword`/`keyPassword` 是 DevEco **机器绑定密文**，工具要明文；调试 profile 绑死那一个 `.p12` + `keyAlias=debugKey` | 不通（唯一没打通的一环），走 GUI 签名（§5.3） |
| 15 | 「`hilog -x` 一次性 dump 取证」 | 启动那 5~10 行被三千多行系统日志挤出环形缓冲，`Cangjie` tag 计数 **0**，而进程明显活着 | 否，一律流式抓取（§8.1.4） |
| 16 | 「用桌面 `cjpm` 加 `--target=aarch64-linux-ohos`」 | 目标**静默回落**成 `x86_64-w64-mingw32`，编出来是 Windows 产物 | 必须用鸿蒙 SDK 的 `tools/bin/cjpm`（§5.1） |

**方法论（比任何一条单点结论都值钱）**：

- 每一条「听起来最像」的架构解释都被数据否掉了，真因先后落在**一个小文件里的三个符号**（§1）
  和**一行 import**（§9.2）上。所以定位顺序应当反过来：**先查「符号面 / 依赖面 / 诊断通道」，
  再谈架构**。
- 反过来说：凡是「改了 A 症状没变」的对照实验，**必须先把旧产物清干净再加 A**（§10.1 的假阴性就是这么来的），
  否则每次结论都建立在别人留下的 `.so` 上。

### 9.2 框架包一旦 import `kit.ArkUI.*`，启动瞬间死在包初始化

这一条是本轮**代价最大**的一段（多轮白屏、十几次重编、两套链接形态都试过）。

**现象**：窗口起不来（或秒退成白屏），hilog 里只有 `InitCJLibrary` 起头的一行
`SIGSEGV(SEGV_MAPERR)@0x0004exxx`，**我方一行日志都没有**（`eprintln` 也不进 hilog，见 §9.4），
`AbilityStage.onCreate` 同样没有——与 §1 的现象几乎一样，但根因完全不同。

**三组对照（都在真机上跑的，这是判据的核心）**：

| 实验 | 结果 |
|---|---|
| 入口包**自己**写 `@Component` + `Web`（不引用框架） | 正常启动，还拉起了 `:gpu` / `:render` |
| 入口包只引用框架的**一个字符串常量**（`DEFAULT_WINDOW_LABEL`），框架里仍有碰 ArkUI 的文件 | **照样崩**在包初始化 |
| 把 `src/arkweb_view.cj`（框架里唯一 `import kit.ArkUI.*` 的文件）移出编译 | **立刻正常**：`onCreated` / `onWindowStageCreate` 都有、`SIGSEGV` 计数 0 |

**机理**：框架包是**独立编译单元**（`output-type = "static"`），合并进应用的动态库之后，
`InitCJLibrary → cangjie_entry::package_global_init → cjTauri::package_global_init` 里那条
`bl _CGP9kit.ArkUIiiHv@plt` 跳进未映射地址。同一张 PLT 表在**入口包**里调用 `_CGP9kit.ArkUIiiHv`
是好的——所以这不是「ROM 缺库」，是**框架包这一侧的重定位/初始化链**问题。

**两种链接形态都崩，落点不同**（这就是当时「动态形态能绕开」被否定的原因）：

| 形态 | 崩溃落点 |
|---|---|
| `static`（框架现状） | 栈尾是 `package_global_init` → `cjTauri::package_global_init` → `0x72c88` → **未重定位的 `0x509c0`**，信号 `SEGV_MAPERR` |
| `dynamic` | 同样崩，但它落在 `[anon:cangjie_heap]` 里，`SEGV_ACCERR` |

**落法（已落地）**：框架侧只保留 **ArkUI-free** 的接线——`src/arkweb_proxy.cj`（两个 proxy 函数）、
`src/arkweb_script.cj`（桥脚本 + label 注入）、`src/host_arkweb.cj`（宿主实现，纯仓颉）；
`@Component` / `Web(...)` / `javaScriptProxy` 全部由**应用模块**持有。这与 ArkUI 自身的模型一致：
组件树属于应用的 UIAbility。根因注释就写在 `src/arkweb_proxy.cj` 文件头，改这块之前先读它。

> 注意 `native/platforms/harmonyos/README.md` 早期版本还把 `src/arkweb_view.cj` 当作框架文件列出——
> 那个文件**已经不在框架里**了，它以「应用侧样板」的身份只存在于踩坑文档与探针工程中。

### 9.3 SDK 的 `kit.*` mock 不是补符号的办法（它会把真实现遮蔽掉）

当时的现象是 `bl _CGP9kit.ArkUIiiHv@plt` 解析不了，很自然的一个想法是「把 SDK 里带 kit 的库拷进包」。
**这条路是死路，而且会引入新问题**：

- SDK 的 mock 桩在 `C:/Users/yang/.cangjie-sdk/6.1/cangjie/api/lib/linux_ohos_aarch64_cjnative/{kit,ohos}`，
  里面**只有 `_CGP9ohos.mock*` 前缀的符号**，根本没有 ROM 上那些 `_CGP9kit.ArkUIiiHv`；
- 拷进 `entry/libs/arm64-v8a/ohos/` 之后，mock 会**遮蔽** ROM 的真实现（同名库优先取包内的），
  而 mock 自己还带着 `NEEDED libcangjie-std-core.so` 之类的依赖——启动随即报
  `[Ability] failed:UIAbility`（同轮清空 mock 目录后该行消失；这一步没做严格 A/B 隔离，记为**强相关**，不是已证因果）；
- ROM 上的真实现位置（用来核对「谁该定义这个符号」）：
  `/system/lib64/platformsdk/cjsdk/` 下的 `libkit.ArkUI.so` 定义 `_CGP9kit.ArkUIiiHv`、
  `libkit.ArkWeb.so` 导出 `_CGP10kit.ArkWebiiHv`、`libohos.arkui.component.web.so` 导出
  `_CGP24ohos.arkui.component.webiiHv`、`libohos.arkui.component.custom_component.so` 导出 `CustomView.ti`。

**HAP 打包侧的事实**（解释了「不手动拷就没有 `ohos/` 目录」）：

- 打出来的 HAP 里**没有 `ohos/` 目录**；`extend_libs/.../cjbins/` 下只有三个库；
- 系统是按 `InitCJMockNS` 去 `libs/arm64/ohos` 找 mock 的——也就是说「手动拷进去」是唯一能让它出现在
  HAP 里的路径，**而这条路恰恰是不该走的**。

处置：mock 目录已清空，**勿恢复**。真要补符号，方向是让框架不依赖那个符号（§9.2），不是往包里塞桩。

### 9.4 `eprintln` 在设备上完全不可见（诊断通道选错，白查一轮）

桌面两平台的规矩是「诊断一律走 stderr」（AGENTS §4）。鸿蒙上这条**不成立**：
`eprintln` 不进 hilog，整轮日志里只剩两行系统自己的 `CANGJIE-RUNTIME`。
表象是「应用什么都没干就走了」，实际是**我们打的东西没人收**。

落法：鸿蒙侧诊断一律写 `Hilog`，并且**用显式的三参数**（`Hilog.info(1, "tag", "msg")`）——
带整型插值会落到 4 参数重载导致编译失败（§8.1.3）。取证仍靠 §8.1.4 的流式抓取。

## 10. 构建链的假阴性（最贵的一类失败：结论被旧产物污染）

这一类失败**不报错**，它让「对照实验」本身失真——你改了半天、症状没变，于是得出「改了没用」的
错误结论。本轮至少被它骗过两轮。

### 10.1 增量缓存：`entry/build` 与框架 `target` 必须一起清

- 症状：改了框架代码，真机上的表现**一字未变**；或者崩溃栈明明指向框架包，可你**已经**把那个文件移出去了。
- 实测数据：残留的旧 `libcjTauri.so`（824088 B）还在包里时，崩溃链**仍然**落在框架包
  （`cjTauri::package_global_init`）；`rm -rf entry/build` + 框架 `target/` 清理重建后，
  入口 `.so` 变成 939 KB 且含框架全链，判据才可信。
- 为什么必须两边都清：hvigor 的 `CompileCangjie` 有自己的增量判断，框架侧 cjpm 也有；
  **只清一边，另一边会把旧对象喂回来**。
- 判据：不看 `build success`，看**产物**——`ls -l` 的尺寸/时间戳 + `llvm-nm` 里 `cjTauri` 符号数
  （本轮健康值是 330 个符号）。AGENTS §4 的「`cjpm build success` 不等于产物存在」是桌面版同一条坑。

### 10.2 `cjpm.exe` 退出码 `0xC0000139`

`0xC0000139` = `STATUS_ENTRYPOINT_NOT_FOUND`，在这里的形状是**桌面 Cangjie SDK 的 DLL 冲突**
（环境里同时存在桌面 SDK 与鸿蒙 `build-tools`，`cjpm.exe` 加载到了不匹配的运行时）。
处置：把桌面 SDK 从 `PATH` / `CANGJIE_HOME` 里摘掉，并**重启 hvigor daemon**（daemon 会把旧环境一直带着）。
它不会打印任何有用信息，只有退出码。

### 10.3 `bash: failed to spawn shell: 拒绝访问 (os error 5)`

本机 Git Bash 的偶发故障：某个时刻起，连 `/usr/bin/rm` 都 `Permission denied`，编译进程起不来。
处置：把 `TMPDIR` 指到**仓库内**目录（如 `.atomcode/tmp`）再跑即可恢复；不必重启机器。
判据是「同一条命令在设了 `TMPDIR` 后能跑」，不要往代码或工具链上找原因。

### 10.4 `aa start` 用的是 `module.json5` 里的 ability 名，不是仓颉类名

`aa start -b com.yang.testcj -a MainAbility` 返回 **`10104001`**（找不到 ability），
因为 `module.json5` 里声明的是 `EntryAbility`。本机实测：换成 `EntryAbility` 立即启动。
顺带：`aa start` 要求**屏幕已解锁**（§7.3），锁屏状态下的「启动失败」不是真失败。

### 10.5 桌面 `cjpm` 交叉编会**静默回落**

`cjpm build --target=aarch64-linux-ohos` 用桌面 cjpm 时会回落到 `x86_64-w64-mingw32`——
不报错，只是编出一份 Windows 产物。判据：产物路径与 `llvm-readobj` 里的机器类型（§5.1）。

## 11. 鸿蒙侧语言与标准库差异速查（写代码前先扫一眼）

桌面代码直接搬过来编不过的那些，基本都在这一张表里。**它们和鸿蒙本身无关，是 OHOS 版仓颉标准库/编译器的形状差异**。

| 桌面写法 | 鸿蒙侧 | 报错 / 现象 |
|---|---|---|
| `ArrayList.append(x)` | **`add(x)`** | `'append' is not a member of ...` |
| 命名参数（`f(name: v)`） | 多数 ArkUI/OHOS API **拒绝命名参数** | 参数不匹配，指向调用行 |
| `s.indexOf(t)` 当 `Int64` 用 | 返回 **`Option<...>`** | 拿它直接比大小/相加编不过 |
| `Duration.second(n)` 之类 | 用 `Duration.millisecond * 10` 这类乘法表达 | 构造器缺失 |
| `Hilog.error(msg)`（2 参） | **需 4 参数**（`Hilog.info` 用显式 3 参） | §8.1.3 |
| `for (c in s)` 期望字符 | 迭代出 **`UInt8` 字节** | 与 AGENTS §4 同一条，鸿蒙侧同样成立 |
| `import pkg.synchronized`（成员名） | `synchronized` 是**关键字**，不能当包成员导入 | 改成通配导入 `import pkg.*` |
| 跨包直接用内部符号 | **必须 `public`**（`DEFAULT_WINDOW_LABEL`、`ARKWEB_PROXY_NAME` 都因此改过） | 链接期 `undefined` 或编译期不可见 |
| `build()` 里写逻辑（`let` / 赋值） | 只能写 UI 组件语法，**代理方法表要内联进调用参数** | 编译期语法错 |
| ArkUI 侧找定时器 / `UIContext` | 没有；页面侧用 `setInterval` | 见 §8.1.5.1 的心跳方案 |
| `WebviewController.loadData(...)` | **不存在** | §6：落沙箱文件走 `file://` |
| `runJavaScript(script, callback)` 命名调用 | 两个都是**位置参数** | 参数不匹配 |

**判据口径不变**：能力位（菜单 / 托盘 / 快捷键 / 拖放 / 对话框）在 `native/platforms/harmonyos/`
真正落地并通过真机取证之前，一律报 **0 / 未实现**，不写「理论上可以」。

## 12. 下一步（未完成，勿当成已完成）

1. **ArkWeb 宿主 + NAPI 桥**（按 `native/platforms/harmonyos/README.md` 的契约）：ArkTS `Web` 组件 +
   `javaScriptProxy` 注入 `window.__CJ_TAURI__`、生命周期与加载事件回投；C 桥按「同名同签名」承接 `cj_core_*`，
   **回调首参必须带 `struct cj_host *`**（AGENTS §2）。
2. **先给 `src/clipboard_bridge.cj` 加 `@When` 门禁**，再谈剪贴板插件——否则 §1 的崩溃原样复现。
3. 验收出口：ArkWeb 加载本地资源与 `CJ_TAURI_DEV_URL` → `system:version` IPC 往返 →
   宿主回调按句柄路由不串台 → HAP 真机（平板 / 2-in-1）→ hilog 无 panic/fatal → 桥 stderr 取证链路照旧。
4. 设备类型待确认：探针 `module.json5` 目前只声明 `phone` / `tablet`，**鸿蒙 PC（`2in1`）是否必须单独声明尚未验证**。
