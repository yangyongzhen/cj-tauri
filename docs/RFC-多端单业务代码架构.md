# RFC-002：多端单业务代码架构（greenfield 版）

> 状态：草案 v2（待评审）｜ 提出：2026-10-23
> 立场：**不为现有工程的历史形态做扭曲**。本文按"一个全新的 cj-tauri 项目结构上最合理"来设计，现有 `examples/` 的迁移只作为附录，不参与设计权衡。
> 一句话：**应用是一份声明，端是适配**——业务只声明"我要什么"，框架负责"这个端怎么给"。

## 0. 结论摘要

1. **应用身份必须有一处单一真相**：`cj-tauri.toml`（应用清单，含 id/name/version/icon/windows/capabilities）。今天的现状是**没有**——桌面模板连应用标识都没有，`bundleName` 只作为 `{{BUNDLE_NAME}}` 占位出现在鸿蒙骨架 `AppScope/app.json5:5`，`cli/src/scaffold.cj:20` 的注释写着"bundleName…桌面模板不用"。这决定了任何多端方案都先要把身份收敛。
2. **业务 API 只有一句**：`main() { cjTauri.launch(build()) }`。`build()` 是纯声明、无参数、不知道自己在哪个端；`launch()` 在框架内部按目标分派。
3. **能力在编译期成为类型**：命令与 capability 声明由构建期生成的注册表绑定，**漏声明 = 编译错误**，而不是运行时读 `capabilities/*.json` 才发现（现状 `src/app.cj:441` 是运行时读盘）。
4. **业务侧零 `@When`**：平台差异不再由 OS 名分支表达，而由**能力探测**表达（`ctx.supports(Tray)` / `sandboxed` / `PageSource` 自适）。业务代码里出现 `os == "Windows"` 视为设计缺陷。
5. **资产编译期定型**：构建期生成类型化资产表（`const` + 生成器校验），业务拿到的是常量而非字符串键；前端页面用统一的 `PageSource` 四态表达，取代"读盘 / 内嵌"两套业务分支。
6. **骨架是派生物**：每端一份 `targets/<target>/`，由清单 + 模板生成，可入库、可 `--check` 比对、可整目录丢弃重建。业务目录里不允许出现任何平台文件。
7. **多窗口是一等公民**：`windows = [...]` 是清单的一部分（桌面多窗、移动端多任务/分屏），不再是试验性的 `addWindow`。

代价与边界：每端仍需要一个 `WebViewHost` 实现与原生桥（这是唯一必须手写的部分）；macOS/Android 目标名已被 `cjc 1.2.0` 接受但生态未验证，本文只保证"接得进来"，不承诺可用。

## 1. 设计目标与不变量

### 1.1 目标

| # | 目标 | 判据 |
| --- | --- | --- |
| G1 | 一份业务代码 | 业务目录内 `git grep "package "` 只有自己；不存在按端复制 |
| G2 | 业务零平台知识 | 业务目录内 `@When` 出现次数 = **0**；`import kit.*` = 0 |
| G3 | 装配点唯一且无参 | `build(): AppSpec`，`TauriApp` 构造只出现在 `build()` |
| G4 | 权限漏声明是编译错误 | 注册未声明的命令/插件 → 编译失败 |
| G5 | 新端成本有上限 | ≤ 宿主 600 行 + 1 份骨架模板 + 1 段权限派生；**不改业务目录** |
| G6 | 构建可复现 | 同 commit 三端构建全绿；骨架 `--check` 无漂移 |

### 1.2 不变量（任何端都必须满足）

- **一次装配、多处运行**：`build()` 的返回是纯粹的声明，运行期不再被改写。
- **框架不 callback 到业务**：没有"应用侧实现接口交给框架调"的钩子（生命周期钩子以**事件**形式给业务，而不是接口实现），业务只提供命令与声明。
- **平台差异只能出现在 L0**（适配层）。L1 及以上若需要知道"这是哪个端"，只能通过**能力探测**，不能通过名字匹配。
- **没有"兼容开关"**：`CJ_TAURI_LEGACY_*` 这类兜底开关在 greenfield 里不存在；旧形态由迁移附录处理，不进入设计。

### 1.3 非目标（本期明确不做）

自动更新、深链/协议注册、系统分享、多语言运行时切换、托盘菜单编辑器。它们都能在声明式清单上后加，但都不是"多端单业务"的前置条件——列出来是防止评审时范围膨胀。

## 2. 分层与所有权

```
┌──────────────────────────────────────────────────────────────────┐
│ L4 派生骨架  targets/{desktop,ohos,macos,android}/                │
│    生成物：构建描述 + 系统资源 + 入口胶水。不含业务，可整删重建      │
├──────────────────────────────────────────────────────────────────┤
│ L3 业务（唯一真源码）                                              │
│    cj-tauri.toml（清单） + src/（命令、插件用法、build()）          │
├──────────────────────────────────────────────────────────────────┤
│ L2 框架内核（平台无关，已有）                                       │
│    IpcHub / CapabilityRegistry / WindowRegistry / 插件体系 / 生命周期事件 │
├──────────────────────────────────────────────────────────────────┤
│ L1 运行时（框架自己实现，业务不可见）                                │
│    launch() 分派 / AppContext（assets+paths+target+dev）/ PageSource 解析 │
├──────────────────────────────────────────────────────────────────┤
│ L0 适配层（每端一份，手写）                                         │
│    WebViewHost 实现 + 原生桥 + HostProvider + 目录/资产发现 + 权限派生 │
└──────────────────────────────────────────────────────────────────┘
```

**所有权表（谁拥有什么）**——这张表是本文最重要的一张，任何"该写在哪"的争论都回到它：

| 关注点 | 唯一所有者 | 其他层能做什么 |
| --- | --- | --- |
| 应用身份（id / 名称 / 版本 / 图标规格） | `cj-tauri.toml` | 只能读；骨架文件里的同名值一律由它生成 |
| 窗口结构与初始尺寸 | `cj-tauri.toml` 的 `windows` | `WindowRegistry` 执行，业务不 `addWindow` |
| 命令与能力映射 | 生成器产出的 `registry.generated.cj`（源：`cj-tauri.toml` + `capabilities/*.json`） | 业务注册命令时按生成常量引用 |
| 页面来源与开发模式 | `PageSource`（L1） | 宿主实现 `load(source)` |
| 数据目录 / 缓存目录 | L0 适配层填 `AppContext.paths` | 业务只读 |
| 平台差异（宿主、权限声明、打包） | L0 + 骨架 | 上层不可见 |
| 构建参数（sysroot、target、签名） | 骨架 | 业务 `cjpm.toml` 不含任何 `[target.*]` |

三条硬约束：

1. **L3 不认识端**：业务看不到 `os` 字符串，只能看到能力位。
2. **L4 不含业务**：骨架里出现 `package music_app` 一类内容即为违规（现状 `build-hap.sh:61` 的 `sed` 复制正是这个反例）。
3. **L1 不 `import kit.*`**：平台包只能出现在 L0（现状注释已记录过这个约束：内核 import ArkUI kit 会把依赖带进桌面构建）。

## 3. 单一应用清单：`cj-tauri.toml`

一份 `toml` 描述"这个应用是什么"，与"这个端怎么构建"彻底分开。

```toml
# cj-tauri.toml —— 应用清单（业务包根目录，唯一真相）
[app]
id          = "com.example.music"   # 反向域名：派生出 ohos bundleName / android applicationId / macOS bundle id
name        = "音乐"
version     = "1.0.0"
icon        = "assets/icon.png"     # 单张高分辨率源图，各端规格由生成器派生
entry       = "src/main.cj"         # 只声明入口文件，里面有且只有 launch(build())
package     = "music"               # 业务 cjpm 包名（sync 生成 launcher 的 import 用）

[[windows]]
label       = "main"                # 与前端 __CJ_TAURI_LABEL__ 一致
title       = "音乐"
width       = 1100
height      = 720
resizable   = true

[assets]
root        = "assets"              # 资产根：ui/ 、capabilities/ 、图标都在其下
page        = "ui/index.html"       # 默认页面（逻辑名，编译期校验存在）

[capabilities]
dir         = "assets/capabilities" # 声明源：编译期编成注册表，运行时不读盘
```

三个必须由清单派生的东西（否则又散开）：

| 派生目标 | 各端落点 | 现状（分散） |
| --- | --- | --- |
| 应用 id | 鸿蒙 `AppScope/app.json5` 的 `bundleName`、Android `applicationId`、macOS `CFBundleIdentifier` | 只在鸿蒙模板里，桌面无（`scaffold.cj:20`） |
| 应用名与版本 | 各端 `productName` / `versionName` / `CFBundleShortVersionString` | 桌面只在 `cjpm.toml` 的 `version`，缺"应用版本"概念 |
| 图标 | 鸿蒙多倍图、Android mipmap、macOS `.icns`、Windows `.ico` | `create` 时逐端拷贝/生成 |

校验规则（`cj-tauri check`，CI 必跑）：

- `id` 必须能无损映射成三端标识（反向域名、仅小写字母数字与点、段不为空）；
- `windows[*].label` 唯一且非空；
- `assets.page` 在资产根内存在；
- `capabilities.dir` 内每个 JSON 都能被解析且引用的命令都有实现（见 §4.4）。

## 4. 三段式 API

### 4.1 `build()`：纯声明，无参数

```cangjie
package music

/**
 * 应用声明（三端共用，零平台知识）
 *
 * 注意签名：没有 env、没有 assets、没有平台参数。
 * "这个端有什么"由框架在自己的适配层里解决，业务不需要参与协商。
 */
public func build(): AppSpec {                       // 示意写法；落地用构造器链
    AppSpec(
        capabilities: Capabilities.default,          // 生成常量，见 §4.4
        commands: MusicCommands(                     // 生成类：字段 = 已声明命令，多/漏 = 编译错误
            playerToggle: PlayerToggleCommand(),
            librarySave: LibrarySaveCommand()),
        plugins: [StorePlugin(), FsPlugin()]
    )
}
```

为什么不像 v1 草案那样 `build(env, assets)`：参数一旦进签名，就等于承认"业务需要知道资产从哪来、目录在哪"——**而这恰恰是本方案要消灭的知识**。测试需要注入上下文时用 `launch(spec, context: Some(fake))`，不影响业务签名。

> **批次 3-PR1 落地形态**（替代批次 2 过渡契约）：`build(): AppSpec` + `launch(spec)` 已交付（`src/app_spec.cj` / `src/launch.cj`）。与示意写法的两处偏差，照实记录：① 命令装配点是 `wire` 闭包（业务命令多需要 app 自身，如 `music:quit`）——§4.4 的编译期命令表（generated registry）是批次 3 的后续 PR，届时 `wire` 收敛为类型化 `commands:` 字段；② `launch(spec)` / `launchWith(spec, context)` 两个重载代替默认参数（当前工具链不用默认参数）。批次 2 的过渡 launcher（`build(): TauriApp`）由 `sync` 重新生成后废弃，业务侧把 `build()` 的返回换成 `AppSpec` 即完成切换。

### 4.2 `launch()`：框架内部按目标分派

```cangjie
// src/main.cj —— 业务侧的入口，完整内容就这两行
import cjTauri.*
main(): Int64 {
    cjTauri.launch(build())
    return 0
}
```

```cangjie
// 框架侧（L1）
public func launch(spec: AppSpec, context: Option<AppContext> = None): Unit {
    let ctx = match (context) {
        case Some(c) => c
        case None => Platform.discover()   // L0：按 TargetInfo 发现目录/资产/宿主
    }
    AppRuntime(ctx).adopt(spec).run()      // 桌面阻塞主循环；移动端交给系统线程模型
}
```

`Platform.discover()` 是唯一的"端在哪儿"知识入口，`@When` 集中在这一个文件里（L0），业务与 L2 都不需要它。鸿蒙侧生成的胶水同样只调 `launch(build())`，差别在于它由 Ability 触发、跑在非 UI 线程：

```cangjie
// targets/ohos/entry/src/main/cangjie/ability_stage.cj（生成物，不是业务代码）
public func onWindowStageCreate(filesDir: String) {
    launch(build(), context: Some(Platform.mobile(filesDir)))   // 非 UI 线程 spawn 由框架处理
}
```

### 4.3 `PageSource`：页面来源只有一种表达

现状有两套入口（`run(html)` / `runUrl(url)`，`src/app.cj:546` 与 `:567`）与业务侧的分支（`textOrFile(PACKED_UI_B64, MUSIC_UI_PATH, ...)`）。greenfield 收敛为一个词：

```cangjie
public enum PageSource {
    | Inline(String)          // 代码里给的 HTML 字符串
    | Asset(String)           // 逻辑名，如 "ui/index.html"（编译期校验存在）
    | Url(String)             // http(s):// 或 file://
    | DevServer(String)       // 开发期前端 dev server（HMR）
}
```

- 业务/清单里只写 `Asset("ui/index.html")`；
- `devMode` 下框架自动改写为 `DevServer(CJ_TAURI_DEV_URL)`；
- **`Asset` 在移动端怎么落地是 L0 的事**：桌面直接读盘、鸿蒙把内嵌资源材化到沙箱再用 `file://`、Android 用 `assets/` + base URL。业务与骨架都不接触沙箱路径。

`WebViewHost` 的契约随之收敛（不再有 `start`/`startUrl` 两套）：

```cangjie
public interface WebViewHost {
    func label(): String
    func load(source: PageSource): Unit
    func addInitScript(js: String): Unit
    func reload(): Unit
    func dispose(): Unit
}
```

> **兼容期说明（批次 1 实况）**：`load(source)` 的收敛要同步改鸿蒙应用侧 `ArkWebHost` 与既有模板/测试桩，批次 1 先保留 `start(html)` / `startUrl(url)`，由装配层 `resolvePage` 完成 `PageSource` → 二者的映射；`load(source)` 收敛随批次 3（鸿蒙胶水迁移）一起落，届时本节即为准。

### 4.4 命令与能力：编译期绑定

现状是运行时读盘（`src/app.cj:441` 的 `loadCapabilities(dir)`），`capabilities/*.json` 写错或漏写只有到运行时才知道。greenfield 把这一步挪到构建期：

```
assets/capabilities/default.json  ──sync──▶  src/generated/registry.generated.cj
   { "identifier": "core:default",              public class MusicCommands {     // 字段 = 已声明命令
     "commands": ["player_toggle",                public let playerToggle: CommandSlot
                  "library_save"] }               public let librarySave: CommandSlot
                                               }
                                               const Capabilities = CapabilitySet(
                                                   commands: ["player_toggle", "library_save"],
                                                   scopes: [...])
```

- **机制本体**：`AppSpec.commands` 的类型是生成类（如 `MusicCommands`），**不是 `HashMap<String, …>`**——字符串键的字面量拼错也能编译通过，类型化字段才能让"注册未声明命令"变成编译错误。业务多写、漏写、拼错都过不了编译。
- 插件同理：`StorePlugin()` 声明它需要的能力，缺声明即编译失败，而不是运行时静默降级。
- **运行时仍保留 scope 判定**（路径通配、URL 白名单等动态部分），因为那是数据不是结构。

这是本方案相对 v1 最重要的一处升级：**"权限单一来源"从评审纪律变成编译器强制**。

### 4.5 用能力探测替代 OS 分支

业务需要"这个端有没有"时，问能力，不问名字：

```cangjie
public class AppContext {
    public let paths: AppPaths            // data / cache / temp
    public let target: TargetInfo         // 仅供日志与埋点，业务判断请用 supports()
    public let dev: Bool
    public func supports(_ f: PlatformFeature): Bool
}

/**
 * 平台特性位（注意命名：不是安全能力）
 *
 * 安全能力 = CapabilitySet（命令/资源权限，§4.4）；
 * 平台特性 = 本枚举（这个端"有没有"某个系统设施）。两者在中文里都容易被叫成"能力"，
 * 类型名必须分开，评审时看到 PlatformFeature 只谈可用性、看到 Capability 只谈权限。
 */
public enum PlatformFeature {
    | Tray            // 托盘
    | MultiWindow     // 多窗口/多任务
    | FilePicker      // 系统文件选择器
    | ClipboardImage  // 剪贴板图片
    | SoftKeyboardInset  // 软键盘遮挡可感知
}
```

写法对照：

```cangjie
// ❌ v1 草案允许的 A 档（业务里写平台分支）
if (@When[os == "HarmonyOS"] { true } else { false }) { ... }

// ✅ greenfield：探测能力，缺了就走降级路径
if (ctx.supports(PlatformFeature.Tray)) {
    app.tray(TraySpec(icon: "assets/tray.png"))   // 声明在 spec 里更好，见 §8
}
```

好处不只是好看：**能力位是可测的**（mock 一个 `supports` 返回 false 的上下文，就能测降级路径），而 OS 分支只能靠真机覆盖。

### 4.6 插件机制的多端设计（完整版，批次 2 实现暂停期间补齐）

#### 4.6.1 现状盘点（均已核对）

| 事实 | 出处 |
| --- | --- |
| `Plugin` 接口 = name / commands / events / jsShim，命令注册为 `<插件名>:<短名>` | `src/plugin.cj:20` |
| 15 个插件子包（`cjTauri.plugins.*`），CLI 按子包链接 | `src/plugins/`、CLI 链接行 |
| `serial`/`shell` 已有 `@When` 平台分支；`sqlite` 依赖 `-lsqlite3`（Linux/Windows 段已配） | `plugins/serial`、`plugins/shell`、根 `cjpm.toml` |
| 鸿蒙段**没有**链接 sqlite，也没有 C 桥（`cj_bridge_*` 未产出） | 根 `cjpm.toml` 鸿蒙段、`src/host.cj:546` 注释 |
| 无头装配导出已实现：设 `CJ_TAURI_MANIFEST` 即打印插件清单退出，不建窗口 | `src/app.cj:588`（`describePluginsJson`，`src/plugin.cj:199`） |

#### 4.6.2 插件的三层构成（差异从哪来）

| 层 | 内容 | 多端差异点 |
| --- | --- | --- |
| 仓颉命令层 | 命令处理器、事件 | 纯逻辑，全端一致 |
| 原生桥层 | C 桥导出 / 系统库 / 系统 kit | **差异主源**：桥按端产出、系统库按端链接（sqlite）、kit 仅鸿蒙 |
| 前端 shim 层 | `jsShim()` 注入 `window.__CJ_TAURI__.<插件名>` | 纯 JS，全端一致；但 shim 调的命令可能端不可用 |

结论：插件的多端问题几乎全部落在**原生桥层**，设计围绕它展开。

#### 4.6.3 自描述：静态声明 + 无头导出，双通道交叉验证

```cangjie
/** 插件自描述（静态数据，随插件子包编译；不含任何平台代码，三端可编） */
public class PluginManifest {
    public let name: String
    public let commands: ArrayList<String>     // 短名清单
    public let events: ArrayList<String>
    public let requiredCapabilities: ArrayList<String>
    public let supportedHosts: ArrayList<String>  // hostKind 列表，如 ["webkitgtk","webview2","arkweb"]；缺省 = 全端
}

public interface Plugin {
    // ...既有 name/commands/events/jsShim 不变...
    func describe(): PluginManifest
}
```

- **静态 `describe()`**（新增）：sync 在**为目标端生成骨架时**消费——此时业务还没在该端编译过，无头导出不可用，只有静态声明能算出"哪些插件进哪个端的依赖列表"。
- **无头导出**（已有，`app.cj:588`）：`check` 阶段消费——业务可编后跑一次，拿到真实命令集/能力需求，与静态 `describe()` **交叉比对，不一致即失败**。两条通道各有分工，缺一不可。

#### 4.6.4 端可用性：三档归档 + 桩规则（P-1 / P-2）

15 个现有插件逐个归档（`待核` = 本次未逐一核实，批次 3 清障时确认）：

| 档 | 插件 | 依据 |
| --- | --- | --- |
| 纯仓颉 + stdx（预期全端可用） | `http` `ws` `mqtt` `redis` `store` `log` `fs`（待核） | 无桥依赖、无系统库 |
| C 桥依赖（桌面可用；鸿蒙桥产出前 = 桩） | `clipboard` `dialog` `notification` `menu` `shell`（3 处 @When）`serial`（1 处 @When） | 桥依赖；鸿蒙侧 `cj_bridge_*` 未产出 |
| 系统库 | `sqlite`（Linux/Windows 已链接；鸿蒙段未链接、未验证） | `-lsqlite3` 仅两段配置 |

两条硬规则（对齐 §8 差异三档，插件的桩属于 B 档实现）：

- **P-1 插件子包三端必须可编译**：某端不可用的能力，在该插件子包内用 `@When` 片段给出**桩实现**（调用即抛可照做的"端不支持"错误）。理由：业务 `build()` 三端共用且会 import 全部所用插件——若靠"编译期把子包排除出依赖"，业务在缺失端必然编译失败，除非业务按端分支，违反 G2（业务零平台知识）。桩让"编得过、运行期可照做地报错"成立。
- **P-2 端可用性必须标注且可观测**：桩实现必须与 `describe().supportedHosts` 一致；`check` 汇总"业务用了 unsupported 插件"为**警告**（编译已过、运行期报错，不 fail）；装配期被降级忽略的插件在启动日志列出（§8 第 1 条）。

（取代此前"编译期排除子包"的设想——它与"业务零分支"冲突，评审质询时更正。）

#### 4.6.5 鸿蒙端插件的原生层：宿主中介，已真机验证

问题（评审质询）：桌面插件进程内调 C 桥；鸿蒙 hap 里宿主是 ArkUI 组件，插件的原生能力怎么来？要走 RPC/IPC 异步吗？

先立事实（全部有出处）：

- hap 是**单进程**（UI 线程 + worker），仓颉与 ArkUI、系统服务同进程——不存在要跨越的进程边界，**RPC/跨进程方案否决**（无收益，复杂度抬一级）；
- 仓颉直连系统 kit 绑定可用：ohos-probe 顶部就 `import kit.PerformanceAnalysisKit.Hilog`（`examples/ohos-probe/entry/src/main/cangjie/probe_app.cj:3`）；
- 鸿蒙 sysroot 链接通路已配（根 `cjpm.toml` 鸿蒙段 `--sysroot`），NDK 覆盖的底层能力可同进程 FFI；
- **dialog 已真机验证**（2026-10-20，ohos-probe 取证）：`dialog:message` → 宿主队列（`ArkWebDialogRequest`，`src/host_arkweb.cj:135`）→ **应用侧 ArkUI 组件** `showAlertDialog` 渲染（该 API 只能在应用侧组件调，队列正是为这次线程跳转而生）→ 20ms 轮询回填答案（上限 120s）→ handler 同步返回；多窗口各持 overlay、按 label 路由不串台；
- clipboard / notification：鸿蒙宿主把能力位报 0、命令如实失败（`probe_app.cj:111` 注释）——§4.6.4 规则 P-2 的实机先例。

设计结论——**四条通道，按能力类型选**：

| 能力类型 | 通道 | 状态 |
| --- | --- | --- |
| 有仓颉 kit 绑定（Hilog 等） | 仓颉直连 kit（与宿主同模式，无桥） | 已验证（Hilog） |
| 需要宿主 UI 线程的（对话框/弹层类） | **宿主中介队列**：插件命令 → 宿主队列 → 应用侧组件渲染 → 回填 | 已真机验证（dialog，含多窗口） |
| NDK 覆盖的底层（文件、进程等） | 同进程 NDK FFI，复用桌面 `cj_bridge_*` 契约子集 | 通路已配，待逐插件接 |
| 暂无实现 | 能力位 0 + 桩如实失败（P-2） | 已真机验证（clipboard / notification） |

**照实记录的不足**：dialog 的轮询回填（20ms 间隔）会占住分发线程直到用户点击（上限 120s）——真机验证可用，但属临时形态。批次 3 评估换成条件变量等待，或把 `CommandHandler` 扩出异步回写契约（handler 返回 `Pending`、经 `ipc.reply(...)` 在回调线程回写；桌面同步实现内部立即回写，行为不变）。

#### 4.6.6 命令表与 jsShim 的衔接

- **命令**：插件命令以 `<插件名>:<短名>` 并入编译期命令表（§4.4 的 `registry.generated.cj`），数据源 = 静态 `describe()`；无头导出交叉验证。插件的命令漏声明能力 → 编译失败（§4.4 已有）。
- **jsShim**：保持运行期注入（`runWith` → `registerPluginScripts` 已有），不进生成物——它是纯 JS，没有端差异。

#### 4.6.7 sync/check 数据流

```
业务 build() 装配（唯一真相，含插件 import）
   │ cjpm build（业务可编）
   ▼
CJ_TAURI_MANIFEST 无头导出（app.cj:588 已实现）
   │ 交叉比对
   ▼
静态 describe()（三端可编，目标端生成时唯一可用通道）
   │ 按端过滤 supportedHosts
   ▼
sync 生成 targets/<端>/ 骨架（依赖列表 = 业务所用插件 ∩ 该端可用；桩规则 P-1 兜底）
   ▼
check：清单 ∩ describe() ∩ 无头导出 三方一致；漂移即失败
```

**清单不设 `[plugins]` 段**：插件用哪些由业务 `build()` 的 import 决定（代码即真相），生成器从无头导出反推——避免"清单写一遍、代码写一遍"的双份真相。

#### 4.6.8 对批次计划的影响

| 批次 | 插件相关动作 |
| --- | --- |
| 批次 0/1（已合并） | 无影响；`describePluginsJson` / 无头导出本就存在 |
| 批次 2（当前，暂停中） | **不含**插件依赖生成；仅清单解析、资产解析器、desktop 骨架 |
| 批次 3 | 鸿蒙骨架生成时启用 P-1/P-2；`Plugin` 接口加 `describe()`；15 插件清障（开放问题 9）；`check` 加三方比对；鸿蒙桩换真实现时优先复用宿主中介队列模式（§4.6.5），dialog 的轮询回填评估换条件变量/异步回写（开放问题 11） |
| 批次 4 | 桥产出（鸿蒙 `cj_bridge_*`）后逐个把桩换成真实现，从 `log`/`clipboard` 这类简单的开始 |

## 5. L0 适配层（每端唯一手写处）

### 5.1 五个契约

```cangjie
/** 平台自述：选宿主、选资产策略、日志与埋点都用它；业务不得据此分支 */
public class TargetInfo {
    public let os: String        // "Windows" / "Linux" / "HarmonyOS" / "macOS" / "Android"
    public let arch: String      // "x86_64" / "aarch64"
    public let hostKind: String  // "webview2" / "webkitgtk" / "arkweb" / "wkwebview" / "android-webview"
    public let display: String   // "desktop" / "mobile"（决定窗口语义，不决定能力位）
}

/** 宿主提供者：取代单槽 setHostFactory，支持同 os 多宿主与优先级 */
public interface HostProvider {
    func supports(target: TargetInfo): Int64      // 0 = 不匹配；>0 越大越优先
    func create(label: String, target: TargetInfo): WebViewHost
}

public func registerHost(provider: HostProvider): Unit

/** 目录与资产发现（沙箱端必须实现，桌面端给合理默认） */
public interface PlatformEnv {
    func paths(appId: String): AppPaths
    func assets(root: String): AssetResolver
    func features(): Set<PlatformFeature>
}

/** 页面材化：把 Asset 逻辑名变成宿主能加载的形态（L0 内部细节） */
public interface PageMaterializer {
    func resolve(asset: String, page: String): PageSource
}
```

**arch 的取值（批次 1 实测）**：编译期拿不到可靠 arch，`Platform.guessTarget()` 从 `CJ_TAURI_ARCH` 环境变量读取（hvigor / CLI 构建时注入；未注入为 `unknown`）。宿主选择请勿依赖 arch——用 `hostKind` / `display` 区分，它们正是为「同 os 多宿主」设计的。

**为什么是"优先级"而不是布尔匹配**：同一 `os` 下确实会有多个宿主——鸿蒙 ArkWeb 与 ARM64 Linux 桌面都报 `Linux`，Android 与 Linux 同理，未来 macOS 也可能有 WKWebView / 嵌入 CEF 两条路。整数优先级让"专用实现压过通用实现"成为数据而不是 `if` 顺序。

### 5.2 桌面目录语义（greenfield 修正）

v1 草案写"`dataDir` = cwd"，这是为现状低头。新项目的合理语义：

| 端 | `paths.data` | `paths.cache` | 开发覆盖 |
| --- | --- | --- | --- |
| Linux | `$XDG_DATA_HOME/<appId>`（默认 `~/.local/share/<appId>`） | `$XDG_CACHE_HOME/<appId>` | `CJ_TAURI_DATA_DIR` |
| Windows | `%APPDATA%\<appId>` | `%LOCALAPPDATA%\<appId>\cache` | 同上 |
| 鸿蒙 | `filesDir` | `cacheDir` | 不可覆盖（真机） |
| macOS | `~/Library/Application Support/<appId>` | `~/Library/Caches/<appId>` | 同上 |
| Android | `filesDir` | `cacheDir` | 同上 |

规则：**应用数据默认跟着应用 id 走，不落在可执行文件旁边**。便携版需求（数据跟着 exe）作为显式选项 `--portable` 由骨架在构建时注入，而不是默认行为。

### 5.3 `@When` 的合法落点

全库只允许三类文件出现平台名匹配：

1. `src/platform/platform_discover.cj`（`Platform.discover()` 的唯一实现，`package cjTauri.platform`）；
2. 插件子包的平台差异实现（`src/plugins/*/`，如 shell 的 Linux/Windows 分支差异——AGENTS §2 的规矩）；
3. `targets/*/` 下的生成胶水（它们本来就是按端生成的）。

CI 规则：`grep -r '@When\[os' src/ | grep -v 'src/platform/' | grep -v 'src/plugins/'` 必须为空。

**这层的变更频率与再拆路径**：批次 0 的 7 个 `platform_*.cj` 分两档——6 个是纯契约（`TargetInfo` / `PlatformFeature` / `PageSource` / `AppContext` / `PlatformEnv` / `AssetResolver`），属于框架公共 API，业务项目**永不改**，只随框架演进偶尔动（新增特性位、新端字段），与 `host.cj` 的 `WebViewHost` 同类；只有 `platform_discover.cj` 携带平台知识，**加新端时改一次**，业务项目同样不改。

> **再拆已落地（批次 3 补记）**：契约不再摊平在根包。批次 0 曾实测「cjpm 子目录必须是独立子包，父↔子互引即循环依赖」，当时摊平；批次 3 用最小实验复验了该结论（互引构建失败、单向引用正常——`plugins/*` 子包能活正是单向），并逐文件测量依赖边界：7 个契约文件中 6 个对父包零引用，`discover` 仅 1 处父引用（`TauriApp.devUrl()`，3 行环境变量读取）可脱钩。于是 6 个契约 + `discover` 折进 `src/platform/` 子包（`package cjTauri.platform`），`platform_host_provider.cj` 留根包——它是平台层唯一必须引用 `WebViewHost` 与三个内置宿主构造器的文件，折不进。业务侧多一行 `import cjTauri.platform.*`（生成物由生成器自动带上）。后续演进路径不变：discover 的每端默认实现若继续膨胀，可再拆 `cjTauri.platform.defaults`（顶层 `let` 初始化自注册，先例是测试里的 `let TEST_SINK_LOCK = Mutex()`）。

## 6. 资产：编译期定型

### 6.1 为什么不用字符串键

`assets.readText("ui/index.html")` 的失败模式是运行时（拼错、忘记打进包）。greenfield 把资产在构建期变成常量：

```
assets/                        ──sync──▶   src/generated/assets.generated.cj
  ui/index.html                              const A_UI_INDEX = "ui/index.html"           // 逻辑名（拼错 = 编译不过）
  icon.png                                   const ASSET_BODIES: HashMap<String, String>  // 逻辑名 → 内容（发布内嵌用）
  capabilities/default.json                  const A_CAPABILITIES_DEFAULT = "capabilities/default.json"
```

业务侧的用法：

```cangjie
app.page(PageSource.Asset(A_UI_INDEX))   // 传逻辑名常量；内容由 AssetResolver 决定读盘还是取 ASSET_BODIES
```

三条规则：

1. **生成器校验清单里 `[assets] page` 存在**，缺页在生成期就失败，不是到设备上白屏。
2. **大二进制不进常量**（图标、字体走文件 + 打包时入各端资源目录），只有 HTML/JSON 这类小文本内嵌。
3. **开发期可绕过内嵌**：`devMode` 下 `AssetResolver` 优先读盘，改 HTML 刷新即见——这靠 `PageSource.DevServer` 与资产解析两条路共存，不靠业务分支。

### 6.2 各端落地差异（全部在 L0）

| 端 | `Asset` 逻辑名落地 | 单文件分发 |
| --- | --- | --- |
| 桌面 | 读盘（开发期）或内嵌常量（发布单文件） | 全内嵌 + 可执行文件自解压到临时目录 |
| 鸿蒙 | 构建期打进 `resources/rawfile/`，运行时读成字符串材化到沙箱后 `file://` | 不适用（hap 本身是容器） |
| Android | 进 `assets/`，用 `WebViewAssetLoader` 风格的 base URL 提供 | 不适用 |
| macOS | `.app/Contents/Resources/`，`file://` 直读 | 不适用 |

业务与清单都不出现在这张表里——**这正是"资产抽象"该有的样子**。

冗余说明：内容三端同源，鸿蒙端常量表会随库编进去而宿主只读 rawfile，造成几十 KB 级冗余。先用 `sync --no-embed-assets`（按端关内嵌）控制，不为它做链接期裁剪—— HTML/JSON 体量下不值得。

## 7. 骨架：派生，不手写

### 7.1 结构

```
my-app/
├── cj-tauri.toml              # 唯一清单
├── src/                       # 唯一业务源码
│   ├── main.cj                #   launch(build())
│   ├── commands.cj
│   └── generated/             #   构建期生成（assets.generated.cj / registry.generated.cj）
├── assets/                    # 页面、图标、能力声明
│   ├── ui/index.html
│   └── capabilities/default.json
└── targets/                   # 每端一份派生骨架（可入库、可整删重建）
    ├── desktop/               #   cjpm.toml(可执行) + 依赖 ../.. + 包脚本
    ├── ohos/                  #   AppScope/ + entry/ + hvigor + build-hap.sh
    ├── macos/                 #   Package.swift + Info.plist + WKWebView 胶水
    └── android/               #   Gradle + AndroidManifest.xml + JNI 胶水
```

**关键点：业务工程不再是"一个 cjpm 工程"**。`src/` 由 `targets/*/` 各自以路径依赖引用（`path = "../.."`），因此同一个业务可以在一个目录里被三端同时构建，互不覆盖 `target/`。

**模块命名规则**（批次 3-PR2 实测补记）：cjpm 强制两条约束——① 每个工程的 toml 模块名 == 其源文件包名（music：toml `music_app` ↔ 源 `package music_app`）；② 依赖树内模块名唯一。因此业务包模块名被 ① 钉死为清单 `package`（仓颉包名，launcher `import <package>.*` 引用的就是它）；骨架模块名 = `exeName`（appId 最后一段），**与 `package` 撞名时加 `_app` 后缀**——`com.example.<pkg>` + `package = <pkg>` 是最常见命名，必然撞 ②，撞时骨架模块名为 `<pkg>_app`（如 `fixapp_app`）。二进制名与模块名无关：cjpm 可执行工程恒输出 `target/release/bin/main`（music / CLI 同口径）。

### 7.2 生成器命令

```
cj-tauri new   <dir>                        # 建工程：清单 + src 骨架 + assets 骨架
cj-tauri add   <target>...                  # 派生 targets/<target>（可一次多个）
cj-tauri sync                               # 按清单重新派生全部骨架（含图标、版本、权限）
cj-tauri check                              # 校验清单 + 骨架漂移 + 资产完整
```

契约：

1. **幂等**：`sync` 只重写生成物，保留 `targets/*/` 下的手写区（若某端确需手写，放在 `targets/<t>/local/`，生成器不触碰）。
2. **指纹头**：每个生成文件首行 `generated by cj-tauri sync vX.Y.Z (app-id@version)`（`.cj` 用 `//`、`*.toml` 用 `#`——TOML 注释只认 `#`，批次 3-PR2 实测 `//` 会被 cjpm 解析器拒绝），`check` 比对整体哈希，漂移即失败。哈希**不含生成时间与绝对路径**，保证跨机器、跨目录可复现。
3. **写入范围封闭**：生成器只允许写 `src/generated/`（业务源码里的生成区，已入 `.gitignore` 与否由 §13.2 问题 2 决定）与 `targets/`；**永不写 `src/` 其余部分、`assets/`、`cj-tauri.toml`**，越界即报错并指出该改哪。
4. **敏感信息不进骨架**：签名证书、密钥由环境变量或本地配置提供，模板里只有占位符名。

### 7.3 各端骨架的职责边界

| 骨架 | 必须包含 | 绝不允许包含 |
| --- | --- | --- |
| `targets/desktop` | `cjpm.toml`（exe + 路径依赖）、启动脚本、单文件打包脚本 | 业务包名、业务源码副本 |
| `targets/ohos` | `AppScope/app.json5`（由 id/name/version 派生）、`entry/cjpm.toml`（dynamic + 显式依赖业务包）、`module.json5`（权限由 capability 派生）、Ability 胶水、`rawfile` 资产注入口、`build-hap.sh` | 业务代码副本、`sed` 改包名 |
| `targets/macos` | `Package.swift` 或 Xcode 工程、`Info.plist`（id/version 派生）、WKWebView 宿主胶水、`.icns` | 同上 |
| `targets/android` | Gradle 工程、`AndroidManifest.xml`（id/权限派生）、JNI 胶水、`assets/` 注入 | 同上 |

这一栏"绝不允许"就是现状 `build-hap.sh:61` 的反面：**骨架永远是外壳，业务永远只有一份**。

## 8. 窗口、托盘、插件：都是声明

`windows` 已在清单里（§3）。其余同类能力保持同一哲学——**声明式，且缺能力时降级而不是崩**：

```cangjie
public class AppSpec {
    public let capabilities: CapabilitySet
    public let commands: CommandTable        // 生成类（如 MusicCommands），字段 = 已声明命令，见 §4.4
    public let plugins: Array<Plugin>
    public let tray: Option<TraySpec>        // 无 Tray 特性的端：框架忽略并记一条 info 日志
    public let windows: Array<WindowSpec>    // 来自清单；多窗口/多任务由端自行解释
}
```

三条语义：

1. **声明被忽略是可观测的**：`cj-tauri check` 与启动日志都会列出"本端不支持、已降级"的项。静默忽略是 bug。
2. **插件声明所需能力**：`StorePlugin` 声明需要 `Fs` 能力，缺则**编译期**失败（见 §4.4），而不是运行到一半发现写不了文件。
3. **多窗口语义由端解释**：桌面 = 多个原生窗口；移动端 = 多任务/分屏/单窗口切换。业务只按 label 收事件（`hostOf(label)` 与 label 路由已具备）。

## 9. 构建与产物

### 9.1 工具链事实（2026-10-23 实测）

用 `cjc 1.2.0 (cjnative)` 逐个探测目标三元组：

| 目标 | 结果 | 含义 |
| --- | --- | --- |
| `x86_64-unknown-linux-gnu` | 现役 | Linux 桌面 |
| `x86_64-w64-mingw32` | 现役 | Windows |
| `aarch64-linux-ohos` | 现役（鸿蒙 `entry/cjpm.toml` 已配） | 鸿蒙 PC |
| `x86_64-apple-darwin` / `aarch64-apple-darwin` | **目标被接受**，进入编译阶段 | macOS 双架构可期 |
| `aarch64-linux-android` | **目标被接受**，提示默认 API level 23 | Android 可期 |
| `*-apple-ios` | 未探测 | 开放问题（见 §13） |

两条边界：**目标被接受 ≠ 生态就绪**（sysroot、系统 API 绑定、链接形态仍要各端解决）；**能编 ≠ 能发**（签名、公证、商店合规）。

### 9.2 每端构建链

| 端 | 业务编译 | 外壳构建 | 产物 |
| --- | --- | --- | --- |
| Windows | `cjpm build --target x86_64-w64-mingw32`（在 `targets/desktop` 内） | cjpm 直出 | `.exe`（可单文件） |
| Linux | `cjpm build` | cjpm 直出 | ELF（`strip -s`） |
| 鸿蒙 | `hvigor` 触发内层 `cjpm`（`dynamic` 模块依赖业务库） | DevEco / hvigor | `.hap` |
| macOS | `cjpm build` + Xcode 外壳 | Xcode / `swift build` | `.app` / `.dmg` |
| Android | Gradle 触发 `cjpm` | Gradle | `.apk` / `.aab` |

**构建描述的唯一真相**是清单 + 骨架：业务根目录只有 `cj-tauri.toml` 与 `src/`，`target/` 由各 `targets/*/` 自己持有，因此**同一份业务可以三端并行构建而不互相污染**。

## 10. 测试与守门

### 10.1 编译期守门（本方案最强的部分）

| 守门项 | 机制 | 失败时机 |
| --- | --- | --- |
| 命令必须已声明能力 | 生成的 `registry.generated.cj` 只含已声明 key | 编译错误 |
| 插件所需能力必须已声明 | 插件声明的能力集在生成期求交 | 编译错误 |
| 页面资产必须存在 | 生成器校验 `[assets] page` | 生成期失败 |
| 应用 id 可无损映射三端 | `cj-tauri check` | CI 失败 |
| 骨架无漂移 | `cj-tauri check`（哈希比对） | CI 失败 |
| 业务无平台知识 | `grep -r '@When\[os' src/ \| grep -v 'src/platform/' \| grep -v 'src/plugins/'` 为空 | CI 失败 |

这些项以前靠评审与记忆，现在靠工具。**"业务零平台知识"能被 CI 判定，是这套设计成立的标志**。

### 10.2 运行期测试分层

| 层 | 手段 | 覆盖 | 成本 |
| --- | --- | --- | --- |
| T1 逻辑单测 | `cjpm test`（业务包，无宿主） | 命令实现、解析、状态机 | 秒级 |
| T2 装配快照 | 导出 spec 摘要（命令表/能力集/窗口表）与期望 JSON 比对 | 装配完整性 | 无显示环境可跑 |
| T3 能力降级测试 | mock `AppContext.supports()` 返回不同能力集 | 降级路径（无托盘、无文件选择器） | 秒级，**这是能力探测换来的红利** |
| T4 宿主冒烟 | 各端真实启动 + 探针命令 | IPC、label 路由、页面加载 | 需 X / 真机 |
| T5 真机回归 | 桌面 CI runner + 鸿蒙真机 | 截图、启动耗时、内存 | 按发布节奏 |

## 11. 接入一个新端：9 步

比 v1 草案少了"业务侧实现入口适配/资产"两步——因为这两件事现在归框架与 L0，**新端接入天然不触碰业务**。

| # | 步骤 | 产出 | 判据 |
| --- | --- | --- | --- |
| 1 | 填 `TargetInfo` | os / arch / hostKind / display | `cj-tauri info` 能打印 |
| 2 | 实现 `WebViewHost` | `load(PageSource)` / init script / reload / dispose | 能加载 Inline 与 Asset 两种页面 |
| 3 | 打通原生桥 | `native/platforms/<t>/bridge_*.c` 或系统 kit 直连 | IPC 往返成功、`platform` 字段正确 |
| 4 | 实现 `PlatformEnv` | paths（沙箱必填）/ assets / features | 业务拿到正确的 `paths.data` 与特性集 |
| 5 | 实现 `PageMaterializer` | Asset → 该端可加载形态 | 内嵌与读盘两条路都通 |
| 6 | 注册 `HostProvider`（含优先级） | `registerHost` | 同 os 多宿主不误选 |
| 7 | 写骨架模板 + `sync` 分支 | `targets/<t>/` 全套 | `cj-tauri sync` 幂等、`check` 无漂移 |
| 8 | 派生系统权限 | capability → 平台权限清单 | 新增命令只需改一处 JSON |
| 9 | 补 T4 探针 | 冒烟脚本进 CI | 能跑"编得过 + 冒烟通过" |

**成本上限**：步骤 2–5 为主体。参照现役实现（`bridge_linux.c` 2485 行、`bridge_win.c` 3248 行是从零做桌面宿主的**历史**成本），在 `WebViewHost` + `HostRoute` 已成型的前提下，新端宿主主体应在 **200–600 行**；超过 1000 行就要回头问：是不是有共享逻辑漏在 L0 了。

## 12. 与前一版草案（v1）的取舍变更

v1 是按"怎么把现状挪过来"写的，因此有若干为兼容低头的设计。v2 按"新项目最合理"重写，逐条改掉：

| 关注点 | v1 草案 | v2（本文） | 改的理由 |
| --- | --- | --- | --- |
| 装配签名 | `build(env, assets)` | `build()` 无参 | 参数进签名等于承认业务要知道"资产从哪来、目录在哪" |
| 资产 | 业务/launcher 造 `AssetsSource` 传进来 | 框架内 `AssetResolver` + 编译期常量表 | 字符串键的失败模式是运行时；常量表把失败挪到编译期 |
| 运行时环境 | launcher 造 `RuntimeEnv` | 框架 `Platform.discover()` 造 `AppContext` | launcher 应能缩到两行，不该承担平台发现 |
| 入口适配 | 业务侧实现 `EntryAdapter` 接口 | 框架内部分派（`Platform.discover` 唯一实现） | 让业务实现生命周期接口 = 平台知识外泄 |
| 差异表达 | 三档，含"业务 `@When` ≤ 20 行" | 两档 + **能力探测**，业务 `@When` 归零 | OS 分支不可测；能力位可 mock、可降级 |
| 宿主注入 | 保留单槽 `setHostFactory` | 只留 `registerHost`（带优先级） | 同 os 多宿主是真实存在的，单槽迟早要改 |
| 能力声明 | 运行时读 `capabilities/*.json` | 编译期生成注册表 | 漏声明应当在编译期失败 |
| 资产布局 | 兼容旧相对路径 | 强制 `assets/` 根 + 生成期校验 | 兼容层会让新项目学到旧形态 |
| 数据目录 | `dataDir` = cwd | 平台规范目录（按 app id） | 落 exe 旁边不是桌面应用的合理默认 |
| 页面入口 | `run(html)` / `runUrl(url)` 两套 | `PageSource` 单一表达 | 双入口导致业务侧分支 |
| 多窗口 | 试验性 `addWindow` | 清单声明 `windows` | 多窗口在多端都是常态，不该是实验特性 |
| 迁移 | 五批迁移参与设计权衡 | 迁移降为附录 | 设计不为迁就历史而变形 |

### 12.1 迁移附录（不参与设计权衡）

现有 `examples/` 的迁移只是**工程动作**，任何"迁起来麻烦"都不构成改设计的理由。建议顺序：

| 步骤 | 动作 | 备注 |
| --- | --- | --- |
| 1 | 补 `cj-tauri.toml`（id/name/version/icon/windows/资产根） | 一次性，之后所有端由它派生 |
| 2 | 跑生成器：出 `assets.generated.cj` 与 `registry.generated.cj` | 与 `capabilities/*.json` 对齐 |
| 3 | 业务 `main()` 换成 `launch(build())`；装配搬进 `build()` | 拆 `examples/music/src/main.cj` |
| 4 | 删 `build-hap.sh` 的 `sed` 复制与 `musiclib/`（`build-hap.sh:61`、`.gitignore:25`） | 业务改为被 `targets/ohos/entry/cjpm.toml` 路径依赖 |
| 5 | 各端骨架改由 `cj-tauri sync` 派生 | 不再手改 |

过渡期允许旧 API 短期共存，但**不写进新项目文档**——文档只描述 v2 形态，避免新项目照抄旧样板。

## 13. 风险与开放问题

### 13.1 风险

| 风险 | 可能性 | 影响 | 缓解 |
| --- | --- | --- | --- |
| 编译期注册表需要代码生成步骤，而 cjpm 没有 build script 钩子 | 高 | 中 | `cj-tauri sync` 显式生成并入库，`check` 校验生成物与源一致；生成物带指纹头 |
| 鸿蒙 `dynamic` 模块依赖"含 stdx 的静态库"链接形态未验证 | 中 | 高 | 接入前先做最小验证（空业务 + 一条命令出 hap） |
| macOS 缺 Cocoa 绑定，需 ObjC 桥或 `objc_msgSend` 手写 | 中 | 中 | 先做 C 桥，复用 Win/Linux 的桥经验 |
| Android JNI 与仓颉互操作未验证 | 中 | 中 | 列为后续端，先只保证编译目标存在 |
| 移动端 `Asset` 材化每次启动的解包成本 | 中 | 中 | 带版本号目录 + 命中即跳过；启动预算实测后再优化 |
| 能力位定义不足，业务会偷偷按 os 分支 | 中 | 中 | CI grep + 能力位申请流程（新增能力位要写清三端语义与降级行为） |
| 图标单源派生需要图像处理 | 低 | 低 | 生成器调用外部工具（`convert`/`iconutil`），无工具则跳过并提示 |
| 声明式 `AppSpec` 与"运行期动态注册"的冲突 | 中 | 中 | 允许 `spec.extend()` 但有边界：动态注册的命令也必须在注册表里（编译期白名单） |

### 13.2 开放问题（评审需逐条回答）

1. **iOS 可行吗？** 本次只验证了 `*-apple-darwin` 与 `aarch64-linux-android` 被接受，`*-apple-ios` 未测；且 iOS 禁止 JIT、动态链接形态受限。未验证前不承诺。
2. **生成物入库还是每次生成？** 入库的好处是可 diff、IDE 友好；坏处是漂移风险。当前倾向：入库 + `check` 守漂移。
3. **强制 `assets/` 根是否可接受？** 新项目没有负担，倾向强制；但需考虑 monorepo 里共享页面的场景（可能需要 `assets.shared`）。
4. **能力位怎么治理？** 新增能力位必须写"三端各自语义 + 缺省降级行为"，否则业务会把它当 `os` 分支的马甲。
5. **同一份业务产出两个 app（白标）**：清单与源码解耦后理论上支持（两份清单 + 同一 `src/`），是否要在 v1 就支持？
6. **移动端多窗口语义**：`windows` 在移动端如何映射（多任务 / 分屏 / 单窗切换）需要真实需求驱动。
7. **托盘/菜单在移动端**：是忽略、还是映射成侧栏？倾向忽略 + 日志，但要评估"业务以为有"的误判风险。
8. **平台默认值的归属**：批次 0 将 discover 摊平进根包（6 个纯契约 + 1 个平台知识文件，业务项目零改动）；当每端默认实现多到污染根包时，是否拆出自注册子包 `cjTauri.platform.defaults`（见 §5.3 再拆路径）？前置条件是验证顶层 `let` 初始化的执行时序。
9. **15 个插件的端可用性清障**：归档表见 §4.6.4（`fs` 等 2 项待核）；批次 3 需给 `clipboard`/`dialog`/`notification`/`menu`/`shell`/`serial`/`sqlite` 写鸿蒙桩（P-1），并让桩行为与 `describe().supportedHosts` 严格一致（P-2）。
10. **插件 API 版本兼容**：`PluginManifest` 要不要带 `apiVersion`，框架 Plugin 接口演进时如何拒绝过旧插件（check 阶段比对 vs 运行期报错）？倾向 check 阶段，避免运行期才发现。
11. **鸿蒙插件的异步语义与 kit 覆盖面**：① dialog 的「宿主队列 + 20ms 轮询回填」（`host_arkweb.cj:162`，上限 120s）会占住分发线程，换条件变量等待还是扩 `CommandHandler` 异步回写契约（`Pending` + `ipc.reply`）？② 仓颉 ohos kit 绑定对 pasteboard / notification / file 等的覆盖面需按 SDK 实测——有绑定走直连（§4.6.5 首选通道），无绑定维持桩或走 NDK FFI。

## 14. 验收判据（可机械化）

落地完成后逐条检查，全过才算成立：

| # | 判据 | 检查手段 |
| --- | --- | --- |
| 1 | 业务零平台知识 | `grep -r '@When\[os' src/ \| grep -v 'src/platform/' \| grep -v 'src/plugins/'` 为空；`import kit.` 为空 |
| 2 | 应用身份单一真相 | `grep -rn 'bundleName\|applicationId\|CFBundleIdentifier' .` 只命中 `targets/` 生成物与清单 |
| 3 | 装配唯一且无参 | `grep -rn 'TauriApp(' src/` 只在 `build()`；`build` 签名无参数 |
| 4 | 漏声明编不过 | 反向测试：新加一条命令但不改 `capabilities/*.json` → **编译失败** |
| 5 | 页面缺失生成期失败 | 清单指向不存在的 `ui/*.html` → `sync` 报错 |
| 6 | 骨架可重建 | 删 `targets/` 后 `cj-tauri sync` → `check` 通过，产物一致 |
| 7 | 业务入口足够薄 | `src/main.cj` ≤ 2 行有效代码 |
| 8 | 新端不改业务 | 接入记录中 `src/`、`assets/`、`cj-tauri.toml` 的 diff 为 0 行 |
| 9 | 降级路径可测 | T3 至少覆盖 2 个能力位（如 `Tray`、`FilePicker`）的无能力行为 |
| 10 | 三端同 commit 全绿 | CI 矩阵：desktop(Linux/Windows) + ohos 编 hap + `check` |

第 4 条最有价值：它把"权限模型是否真的统一"变成**一次必然失败的编译**，而不是一句承诺。

## 15. 参考与术语

### 15.1 现状相关（本文化用的事实出处）

- `src/host.cj:91`（`WebViewHost`）、`:354`（`AppHost`）、`:384`（`HostRoute`）：宿主契约与句柄路由，v2 继续沿用
- `src/host_factory.cj`：现有单槽宿主注入，v2 由 `registerHost` 取代
- `src/capability.cj:182`（`CapabilityRegistry`）：运行时能力校验，v2 保留（scope 判定仍是数据）
- `src/app.cj:61`（`window`）、`:432`（`addCapabilityJson`）、`:441`（`loadCapabilities`）、`:546`（`run`）、`:567`（`runUrl`）、`:588`（manifest 导出）
- `cli/src/scaffold.cj:20`：`bundleName` "桌面模板不用"——应用身份缺失的证据
- `cli/templates/ohos-pc/AppScope/app.json5:5`：`{{BUNDLE_NAME}}` 占位，v2 改由清单派生
- `examples/music/cjpm.toml:7`：`output-type = "executable"`（现状业务不可当库依赖的原因）
- `examples/ohos/ohos-music/build-hap.sh:61`：`sed` 改包名复制业务，v2 删除该路径
- `docs/架构演进-多平台与多窗口.md`：句柄/注册表/label 路由的前序设计

### 15.2 术语

| 术语 | 含义 |
| --- | --- |
| 清单（manifest） | `cj-tauri.toml`，应用身份与声明的唯一真相 |
| 业务包 | `src/` 里的 cjpm 包，三端共享，零平台知识 |
| 骨架（target） | `targets/<t>/`，由清单派生，含构建描述与入口胶水 |
| 装配 | `build(): AppSpec` 的求值过程，纯声明 |
| 能力位 | `PlatformFeature`，业务判断"这个端有没有某设施"的唯一手段（与权限 `CapabilitySet` 是两回事） |
| 命令表 | 编译期生成的命令/能力绑定类（如 `MusicCommands`），漏声明即编译错误 |
| 注册表 | 编译期生成的命令/能力绑定，漏声明即编译错误 |
| 材化 | 把 `Asset` 逻辑名变成宿主可加载形态（L0 内部动作） |
| 漂移 | 仓库骨架与生成器输出不一致 |
