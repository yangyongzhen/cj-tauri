# RFC-002：cj-tauri 菜单 / 托盘 / 拖放（宿主能力位 v1）

> 状态：**设计定稿，实现开工**（2026-10-03）。三处分叉已决（见 §8 的评审结论行）：**原生菜单实现**、
> **Linux 托盘可选编译**、**拖放只做文件拖入 → 真实路径**；落地按 §7 分期，先做 **7.A 菜单**（Windows 先行）。
> 上位文档：[架构演进-多平台与多窗口](架构演进-多平台与多窗口.md) §2.3（只定模型、不写实现）、
> §5（「没有第二个实现来验证的抽象只定模型」的判据）、§6.3（托盘必须可选编译）。
> 体例对标 [RFC-001 插件体系](RFC-插件体系.md)。

## 1. 摘要

给「混合开发框架」补上三样只有宿主能做、页面做不了的**系统集成**能力：**窗口菜单栏**、**托盘图标**
与**文件拖入**。三者走同一条设计线：**纯仓颉模型描述意图 → `HostCapabilities` 如实上报平台是否有
这能力 → `bridge_*.c` 只写「模型 → 原生 API」的翻译层**。

v1 的边界（建议，见 §8）：**Windows 三个全做**；**Linux 做菜单与拖入，托盘按「系统有
`libayatana-appindicator3` 就编、没有就跳过」**；鸿蒙（ArkWeb）留条件编译位，不写实现。
默认全关：不调用新 API 的应用**零改动、零新依赖**（含构建脚本）。

## 2. 现状与问题

| 现状 | 证据 | 问题 |
|---|---|---|
| 宿主接口只有「窗口 + WebView + 对话框」 | `src/host.cj:12-117`（`WebViewHost` 17 个方法）、`:129-144`（`AppHost` 3 个方法） | 想加菜单栏 / 托盘，上层没有挂载点 |
| 托盘早已在架构文档里「排了队但没落地」 | `src/host.cj:123`（`AppHost` 的注释：「将来还有托盘与应用菜单——批次 3 只定模型」）、架构文档 §2.3 末段 | 模型名（`MenuModel` / `TrayModel` / `DragDropPolicy`）与 `HostCapabilities` **只被提过，仓库里零实现**（全仓 grep 无命中） |
| 平台差异边界清楚，但两平台的**装配结构**不同 | Windows：`bridge_win.c:695` 一个 `CreateWindowExW` 直接带 WebView2 子窗口；Linux：`bridge_linux.c:519` `gtk_container_add(window, view)`——窗口里**只有** view | Linux 加菜单栏必须改装配结构（引入容器），Windows 只加一个 `SetMenu`——这处差异必须在设计里点明，否则实现时会往上层泄漏 |
| 原生 UI 操作有明确的**线程归属** | `bridge_win.c:691`（`p->thread_id`）、`bridge_linux.c:467`（`p->thread`）、`bridge_core.h:142`（`cj_plat_is_ui_thread`） | 菜单/托盘/拖放的回调天生在 UI 线程，必须定清「谁在哪个线程碰原生对象」，否则重踩 §4 那条「轻量线程碰 GTK 即 abort」 |
| 回调目前是**无身份的静态单槽** | `src/host.cj:150-156`（`HostGlobals`）、`native/bridge_core.h:39-41`（三个 `cj_*_fn` 都不带宿主） | 多窗口下「哪个窗口的菜单被点了」无法回答（架构文档 §7.5 的残余项）。**新回调不许再复制这个形态**——这是本 RFC 的硬约束 |
| Windows 构建目前**没有** `-lshell32` | `native/build_win.bat:43` 的链接行 | 托盘要用 `Shell_NotifyIconW`，构建脚本得加库；属于「用户机器上会立刻暴露」的改动，要写进交付物 |
| 拖放能力在本机是**可用的**，但没有一行代码 | WebView2 SDK 头（本机 `D:\webview2sdk\sdk-1.0.2365.46\build\native\include\WebView2.h:25037`）已有 `ICoreWebView2Controller4::put_AllowExternalDrop`；`native/*.c` 里 `IDropTarget` / `RegisterDragDrop` / `WM_DROPFILES` **零命中** | 不关掉 WebView2 自带的 drop 处理，子窗口会把拖放吃在 web 内容里，宿主的 `IDropTarget` 收不到文件**真实路径** |

## 3. 目标与非目标

### 3.1 目标（v1）

1. **窗口菜单栏**：应用用 `MenuModel` 描述一层菜单（含分隔线、勾选项、子菜单与快捷键提示），宿主翻译成
   系统菜单栏；点击 → 前端收到事件（过能力清单白名单）；运行期可改启用 / 勾选状态。
2. **托盘**：`TrayModel`（图标 + 提示 + 菜单 + 点击事件）；**平台不支持时如实上报**而不是假装成功。
3. **文件拖入**：把拖进窗口的文件**真实路径**交给页面（HTML5 的 `File` 对象在 WebView2 里拿不到本地路径）。
4. **能力位**：`HostCapabilities`（`menu` / `tray` / `dragDrop` 三个布尔 + 平台名）由两平台如实上报；
   应用与 CLI（`cj-tauri info`）能据此降级与自检。
5. **默认全关 + 零改动**：不碰新 API 的应用行为不变；不装托盘依赖的机器**编译照过**。
6. **平台差异只出现在两处**（AGENTS §2）：`@When` 条件编译与 `bridge_*.c`。

### 3.2 非目标（v1 明确不做）

- **HTML 自绘菜单**：页面自己能做的事框架不做——框架的价值只在「系统级菜单栏 / 托盘」。
- **拖出（drag out）**、**全局快捷键**、**右键上下文菜单**（页面自绘即可）、**协议处理（`mailto:` 等注册）**。
- **scope 级权限**（「只允许拖入 `.png`」「只放行某个菜单项」）：与 `shell:exec` 的 scope 结论保持一致
  （RFC-001 §8 第 8 条），闸门仍是「能力清单里放行 / 不放行」。
- **macOS 后端**（未验证过的平台标识不写，AGENTS §4）。
- **菜单的「应用级」形态**（macOS 那种全局菜单栏 + 应用菜单）：v1 只做**窗口级**菜单。

## 4. 术语与命名

| 术语 | 含义 | 落在哪 |
|---|---|---|
| 模型（model） | 纯仓颉数据结构，描述意图，不含任何平台概念 | `src/menu.cj` / `src/tray.cj` / `src/dragdrop.cj` |
| 能力位（host capability） | **本平台有没有**这个能力（静态事实，如实上报） | `HostCapabilities`（`src/host.cj`） |
| 权限（capability manifest） | **这个应用放不放行**这个事件 / 命令（安全闸门） | `capabilities/*.json`（`src/capability.cj`） |
| 翻译层（translate） | 把模型变成原生对象的那段平台代码 | `bridge_win.c` / `bridge_linux.c` |
| 宿主身份（host identity） | 回调里回传的「这是哪个窗口」标识 | 新回调的**第一个参数**（§5.5） |

命名沿用既有约定：类型 `PascalCase`、函数 `camelCase`、常量 `UPPER_SNAKE_CASE`；
菜单项 `id` 是**应用给的字符串**（框架不生成、不解释，只在回调里原样返回）——这样应用自己就能做
「id → 业务动作」的映射，框架不掺和。

## 5. 设计

一条主线：**模型（仓颉）→ 线路格式（跨 FFI 的 UTF-8 文本）→ 翻译层（`cj_plat_*`）→ 原生对象**，
回调沿反方向走「带宿主身份的 @C 回调 → 事件投递（过能力清单）」。

### 5.1 模型：纯仓颉数据结构（`src/menu.cj` / `src/tray.cj` / `src/dragdrop.cj`）

拆成三个文件而不是一个 `shell_model.cj`：三者生命周期与归属不同（菜单 per-window、托盘 per-app、
拖放 per-window 的策略），且 AGENTS §2 要求「新增文件按单一职责拆分」。

```cangjie
// src/menu.cj —— 纯仓颉，无平台概念（不 include 任何平台头，符合 AGENTS §2）
public enum MenuItemKind {
    | Normal | Checkbox | Separator | Submenu
}

public class MenuItem {
    public let id: String            // 应用定义；Separator 用空串，框架不解释
    public let label: String
    public let kind: MenuItemKind
    public let accelerator: String   // "Ctrl+S" 形式的**提示**；v1 只显示，不抢页面按键
    public var enabled: Bool
    public var checked: Bool
    public let children: ArrayList<MenuItem>  // 仅 Submenu 用；空 = 叶子
}

public class MenuModel {
    public let items: ArrayList<MenuItem>
    public func toWire(): String     // 线路格式，见 §5.4（不是 JSON，理由在那一节）
}
```

```cangjie
// src/dragdrop.cj —— 策略而非回调：框架只负责「把路径交出去」，动作由页面决定
public class DragDropPolicy {
    public let enabled: Bool         // 关掉则平台层不注册 drop target（默认关）
    public let files: Bool           // 接受文件路径（唯一 v1 支持的载荷）
    public let text: Bool            // 接受纯文本载荷（可缓；不影响 Windows/Linux 的落地顺序）
}
```

```cangjie
// src/tray.cj —— 托盘是应用级（一个进程一个图标），所以模型挂在 AppHost 上
public class TrayModel {
    public let iconPath: String      // png / ico；空 = 平台默认
    public let tooltip: String
    public let menu: MenuModel       // 右键菜单（复用菜单模型与同一套 id）
    public let onClick: String       // 点击图标本体时上报的 id（空 = 只弹菜单，不上报）
}
```

**为什么 `id` 用字符串而不是整数**：整数 id 要么由框架分配（应用要维护反向表），要么由应用手工编号
（容易撞号、且跨窗口重复）；字符串让应用自己命名空间化（`"file.save"` / `"win2.zoom"`），框架只做
「原样存、原样回」。代价是 C 侧比较字符串（`strcmp`，量级是「几十个菜单项」，可忽略）。

### 5.2 宿主接口扩展（`src/host.cj`）

按 AGENTS §2 的既有做法：**先扩接口，再改各平台实现，最后在 C 桥加同名同签名的导出**。

```cangjie
public interface WebViewHost {
    // ……现有 17 个方法不变……

    /**
     * 窗口菜单栏。必须在 start() / startUrl() 之前调用——Linux 侧要据此决定装配结构
     * （无菜单 = 窗口直接装 view；有菜单 = 窗口装 GtkBox，里面先菜单栏后 view），
     * 建窗之后再调用只能走「重建菜单栏」的慢路径（见 §5.4 的时序）。
     * 重复调用以最后一次为准。
     */
    public func setMenu(menu: MenuModel): Unit

    /** 运行期改菜单项状态（灰化 / 勾选）；id 不存在时静默忽略（不抛、不报错） */
    public func setMenuItemState(id: String, enabled: Bool, checked: Bool): Unit

    /** 拖放策略：必须在 start() 之前调用（Windows 要在建窗后注册 IDropTarget，Linux 要在 view 建好后设 drag dest） */
    public func setDragDropPolicy(policy: DragDropPolicy): Unit
}

public interface AppHost {
    // ……现有 3 个方法不变……

    /**
     * 托盘图标（应用级）。返回 false = 本平台不支持或初始化失败，stderr 会打一行原因；
     * 调用方应据此降级（或先查 capabilities().tray）。
     */
    public func setTray(tray: TrayModel): Bool

    /** 托盘提示文本（运行期改） */
    public func setTrayTooltip(text: String): Unit

    /**
     * 本平台的宿主能力位（静态事实）。放在 AppHost 而不是 WebViewHost：
     * 同一进程内平台必然相同，per-window 没有差异（唯一"可能不一致"的托盘也是进程级——
     * Linux 取决于编译期是否链上 appindicator），放两份只会带来不一致的风险。
     */
    public func capabilities(): HostCapabilities
}
```

### 5.3 能力位：`HostCapabilities`（如实上报，不假装）

```cangjie
public class HostCapabilities {
    public let platform: String   // "windows" / "linux" / "harmony"（与 @When 的取值同字面量）
    public let menu: Bool
    public let tray: Bool         // Linux = 编译期 `pkg-config --exists ayatana-appindicator3-0.1` 的结果
    public let dragDrop: Bool
    public func toJson(): JsonValue
}
```

| 平台 | menu | tray | dragDrop | 依据 |
|---|---|---|---|---|
| Windows | `true` | `true` | `true` | Win32 菜单 / `Shell_NotifyIconW` / `IDropTarget` 都是系统自带 |
| Linux | `true` | **编译期决定** | `true` | GTK 菜单与拖放自带；托盘依赖 `libayatana-appindicator3`（本机现状 = 缺 → `false`，架构文档 §6.3 已实测） |
| 鸿蒙（预留） | `false` | `false` | `false` | 未实现，条件编译位（AGENTS §4：不发明未验证的平台标识） |

**能力位 ≠ 权限**：能力位说「这台机器能不能」，`capabilities/*.json` 说「这个应用放不放行」。两者都要过：
应用放行了但平台没有 → 事件永不出现（框架在 stderr 提示一次「本平台不支持 tray，已忽略」，
`setTray` 返回 `false`），这与「未授权命令给 `command not allowed`」是两条不同的诊断路径，不要合并。

可观测性：新增内置命令 **`system:host`**（`src/api_system.cj`，走 AGENTS §2 的「新增命令三处联动」：
实现 → `TauriApp.run()` 注册 → 能力清单声明），返回上面的 JSON——这样「平台有没有这能力」在页面上
可自检，也符合「行为变更必须给出可观测证据」的门禁。

### 5.4 C 桥：线路格式、导出族与新平台原语

#### 线路格式（跨 FFI 怎么传菜单树）

**（定稿）制表符分隔的行式 UTF-8 文本，缩进深度即层级**（不用 JSON，也不用结构体数组）。
**下面那张表是设计早期的示意，字段顺序与编码已被实现取代**——一行恒 5 段、kind 在最前、
flags 为十进制位域、且**不做转义**（含制表符 / 换行的项在仓颉侧 `toWire()` 就被丢弃，见 `src/menu.cj`）：

    <行首制表符 = 层级><kind>\t<id>\t<label>\t<flags>\t<accel>\n
    kind：n 普通 / c 勾选 / s 分隔线 / m 子菜单
    flags：bit0 = 可用、bit1 = 勾选（3 = 又可用又勾选）
    accel：快捷键提示文本，可为空（Windows 侧并进标签右对齐，Linux 侧 v1 只拼在文字后）

```
file	文件	0	1	0	Ctrl+O	       ← id / label / kind / enabled / checked / accelerator
	file.open	打开…	0	1	0	Ctrl+O
	-	0	1	0		               ← 分隔线：id 与 label 都空
```

1. **C 侧零依赖**：`bridge_core.c` 是纯 C（不引第三方），解析只需按 `\n` 切行、按 `\t` 切列、
   数前导制表符得层级——几十行，且能直接 `fprintf(stderr, …)` 出来（诊断走 stderr 是项目铁律，
   二进制载荷做不到这点）。
2. **不跨 FFI 共享结构体布局**：避免 ABI 焊死，也避免重踩 AGENTS §6.1 那条「谁分配谁释放」
   （文本由仓颉侧 `CString` 传下去，C 侧只读、不持有）。
3. JSON 仍留在仓颉侧——`toJson()` 给 CLI / 清单（`cj-tauri info`）用，**不过 FFI**。
   备选（不推荐）：传 JSON + 手写极简 JSON 解析器，为的是「格式更眼熟」；代价是 C 侧多 200 行
   状态机且要处理转义与嵌套，收益只是眼熟。

#### 新增导出（全部实现在 `bridge_core.c`，两平台同名同签名，AGENTS §2）

> **分期落地**：**7.A（菜单）**只落 `cj_bridge_set_menu` / `cj_bridge_set_menu_item_state` /
> `cj_bridge_set_shell_callback` / `cj_bridge_host_capabilities` 四条；拖放与托盘的三条留到 7.B / 7.C。

```c
/* 窗口菜单栏（文本为 §5.4 的行式格式，见 bridge_core.h 的格式注释）。空串 = 清空菜单栏；
   NULL = 忽略（不误清——仓颉侧 CString 转换失败给 NULL 时，不该把菜单清掉） */
CJ_BRIDGE_API void cj_bridge_set_menu(cj_host *h, const char *menu_text);
CJ_BRIDGE_API void cj_bridge_set_menu_item_state(cj_host *h, const char *id, int enabled, int checked);
/* 拖放策略：enabled=0 表示不注册 drop target */
CJ_BRIDGE_API void cj_bridge_set_drag_drop(cj_host *h, int enabled, int files);
/* 托盘：应用级，但按宿主传（实现上只有一个宿主会用到；返回 0 = 平台不支持） */
CJ_BRIDGE_API int  cj_bridge_set_tray(cj_host *h, const char *tray_text);
CJ_BRIDGE_API void cj_bridge_set_tray_tooltip(cj_host *h, const char *text);
/* 能力位：位掩码 1=menu 2=tray 4=dragDrop（cj_plat_init 时由平台填） */
CJ_BRIDGE_API int  cj_bridge_host_capabilities(cj_host *h);
```

#### 新增平台原语（`bridge_core.h` 的清单 18 → 24 个；**7.A 先到 21 个**：`cj_plat_set_menu` / `cj_plat_menu_item_state` / `cj_plat_host_capabilities`）

```c
int  cj_plat_host_capabilities(cj_host *h);   /* 位掩码，cj_plat_init 时填；纯静态事实 */
void cj_plat_set_menu(cj_host *h, const char *menu_text);
void cj_plat_menu_item_state(cj_host *h, const char *id, int enabled, int checked);
void cj_plat_set_drag_drop(cj_host *h, int enabled, int files);
int  cj_plat_set_tray(cj_host *h, const char *tray_text);   /* 0 = 不支持 */
void cj_plat_set_tray_tooltip(cj_host *h, const char *text);
```

#### 时序：start 之前 vs 之后（与 `cj_bridge_load_url` 同形）

菜单与拖放策略都要求「装配前知道」，但仓颉侧调用可能发生在 `start()` 之前或之后，两种时序都要成立：

| 调用时机 | 处理 | 先例 |
|---|---|---|
| `start()` 之前 | 存进 `cj_host` 的 pending 字段（`pending_menu_text` / `drop_enabled`），宿主线程装配时取用 | `pending_html` / `pending_url`（`bridge_core.h:103-104`） |
| `start()` 之后 | 投递到 UI 线程（Windows `PostMessageW` 新增 `WM_CJT_MENU`；Linux `g_idle_add`）后重建菜单栏 / 重设 drag dest | `cj_bridge_load_url` 的两分支（`bridge_core.h:192-196`） |

托盘天然是运行期对象（`cj_bridge_set_tray` 只在 start 之后有意义），不需要 pending 分支。

**所有原生调用只允许发生在宿主 UI 线程**（Windows = 跑消息循环那条线程，Linux = GTK 线程）——
这是 AGENTS §4 的既有铁律（轻量线程堆上协程栈会被 JSC 栈边界校验 abort），不是本 RFC 的新要求。
`cj_plat_*` 的实现里一律「先判 `cj_plat_is_ui_thread`，是则直接做，否则 post」（与对话框
`cj_plat_post_dialog` : `cj_plat_run_dialog` 的分流同形，`native/bridge_win.c:514-531`）。

### 5.5 回调必须带宿主身份（本 RFC 的硬约束）

现状的三个回调（`native/bridge_core.h:39-41`）都不带宿主，仓颉侧对应 `HostGlobals` 的三个**静态单槽**
（`src/host.cj:150-156`）——单窗口下够用，多窗口下 `onDestroy` 恒落到最后一个装配的窗口
（架构文档 §7.5 记了这个残余项）。**新回调一律不许再复制这个形态**：

```c
/* 宿主级事件（菜单 / 托盘 / 拖放）统一走一个回调，第一个参数回传宿主句柄 */
typedef void (*cj_on_shell_fn)(cj_host *host, const char *json);
CJ_BRIDGE_API void cj_bridge_set_shell_callback(cj_host *h, cj_on_shell_fn cb);
```

仓颉侧按**句柄地址**反查注册表拿到「是哪个窗口」：

```cangjie
@C
func shellOnEvent(host: CPointer<Unit>, json: CString): Unit {
    // 地址 → label：注册表在 TauriApp 里已有 label → WindowRecord，这里再按句柄存一份
    // （或让 WindowRecord 记住建宿主时 C 侧给的句柄地址），拿到 label 才能按窗口路由事件
    ...
}
```

`json` 载荷：

```json
{ "kind": "menu",  "id": "file.save", "checked": false }
{ "kind": "tray",  "id": "toggle" }
{ "kind": "drop",  "paths": ["C:\\a.png", "C:\\b.png"] }
```

**统一的理由**：三者的投递路径完全相同（UI 线程回调 → 解析 → 按 label 路由 → 事件投递 + 能力校验），
分成三个 `@C` 函数只是三份同形代码；一个 `kind` 字段即可分派。**不为 `kind` 引入 enum 传参**：
JSON 已经是既有回调的载体（`on_message` 就是 JSON），多一种 FFI 形态没有收益。

**为什么不用 `HostGlobals` 那样的全局槽**：单槽在多窗口下必然串台（谁最后装配谁生效），而窗口身份
恰恰是「菜单点击属于哪个窗口」的**必要信息**——不是可选的锦上添花。老回调（`on_message` /
`on_destroy` / `dialogOnResult`）本轮**不动**：那是独立的一件事（架构文档 §7.5 的残余项），
塞进同一提交会让「菜单能不能用」和「旧回调重构」两件事互相阻塞。

### 5.6 事件面：菜单 / 托盘 / 拖放点击怎么到前端

**建议做成三个官方插件**（`src/plugin_menu.cj` / `src/plugin_tray.cj` / `src/plugin_dragdrop.cj`），
而不是内置 `system:` 命令——理由：插件模型恰好提供了这三者需要的东西（`events()` 声明、
`jsShim()` 前端片段、可选 `commands()`），而 `system:` 前缀留给框架自身的元能力
（`version` / `ping` / `echo` / `devtools` / 本 RFC 新增的 `host`）。

| 事件 | 载荷 | 谁投递 | 归属 |
|---|---|---|---|
| `menu:click` | `{ "id": "file.save" }` | 按触发窗口的 label → `emitToWindow` | 窗口级 |
| `tray:click` | `{ "id": "toggle" }`（图标点击与托盘菜单项共用） | 应用级 → `emitAll` | 应用级 |
| `dragdrop:files` | `{ "paths": ["…"] }` | 按落点窗口的 label → `emitToWindow` | 窗口级 |

- **默认最小权限不破**：事件走既有的 `Capability.canEmit` 校验，清单不声明就不投递（与页面自己 `emit`
  同一口径，不新开闸门）。插件的 `events()` 只声明「我提供什么」，不自动放行——与 RFC-001 的铁律一致。
- **命令面**（运行期改状态，走既有命令分发，异步 + 能力校验）：
  `menu:setEnabled` / `menu:setChecked` / `tray:setTooltip`。
- 托盘菜单项与窗口菜单项**共用 id 空间，但不由框架区分**：应用自己命名空间化（`"tray.toggle"` vs
  `"file.save"`）。框架只保证「原样回调」，不猜应用意图。

### 5.7 线程模型与生命周期

| 事项 | 口径 | 与既有代码的关系 |
|---|---|---|
| 原生对象的创建 / 修改 / 销毁 | **只在宿主 UI 线程** | AGENTS §4 铁律；`cj_plat_is_ui_thread` 分流同 `cj_plat_post_dialog` |
| 回调 → 前端事件 | UI 线程里**只做入队**（`cj_bridge_run_js`），真正的 JS 执行由 core 的合并批处理在 UI 空闲时跑 | 复用 `CJ_JS_BATCH_MAX` 那套（`bridge_core.h:49`），**不新增等待原语** |
| 与对话框的区别 | 对话框是**阻塞 + 单槽**（`dlg_busy` 互斥、调用方等结果）；菜单/托盘/拖放是**异步 + 队列**（触发即返回） | 后来者别拿对话框模板套这里——那会把 UI 线程堵在事件上 |
| 窗口销毁 | 菜单是窗口的子对象，随窗口销毁；`p->menu` 指针一并置空（与 `p->view` 同款处理，`bridge_linux.c:434-447`） | 收尾只收还活着的对象 |
| 应用退出 | 托盘是**进程级**资源：`cj_plat_fini` 必须显式摘掉图标（`Shell_NotifyIconW(NIM_DELETE)` / `app_indicator_set_status(…, PASSIVE)`），否则任务栏残留一个死图标直到鼠标划过 | 托盘的生命周期**不在**窗口上，容易漏 |

### 5.8 平台矩阵（翻译层怎么写）

| 能力 | Windows | Linux | 实现量 / 风险 |
|---|---|---|---|
| 菜单栏 | `CreateMenu` + `AppendMenuW`（`MF_STRING` / `MF_SEPARATOR` / `MF_GRAYED` / `MF_CHECKED`）+ `SetMenu`；`WM_COMMAND` 的 `LOWORD(wParam)` = 菜单 id → 回调 | `GtkMenuBar` + `GtkMenuItem` / `GtkCheckMenuItem` / `GtkSeparatorMenuItem`；**装配结构要改**：`gtk_container_add(window, view)` → 窗口装 `GtkBox(VERTICAL)`，`pack_start(menubar)` + `pack_start(view, EXPAND)` | Win 小（原生菜单是系统能力）；Linux 中（装配改动 + 多一个 per-host 字段 `p->box` / `p->menubar`，销毁时一并置空） |
| 托盘 | `Shell_NotifyIconW` + `NOTIFYICONDATAW`（`uCallbackMessage = WM_CJT_TRAY`，落在**宿主窗口**的 `wnd_proc` 里）；**构建要加 `-lshell32`**；Explorer 重启要处理 `RegisterWindowMessageW(L"TaskbarCreated")` 的重注册 | `libayatana-appindicator3`（`app_indicator_new` + `app_indicator_set_menu`） | Win 中；Linux 中 + **可选编译**：`build_linux.sh` 里 `pkg-config --exists ayatana-appindicator3-0.1`，未命中则 `-DCJ_TAURI_NO_TRAY`、`cj_plat_set_tray` 直接返回 0、能力位 false、stderr 一行说明（架构文档 §6.3 已定此口径，本机现状 = 未命中） |
| 拖入文件 | 宿主 HWND `RegisterDragDrop(hwnd, dropTarget)` + 自己实现 `IDropTarget`（`DragEnter` / `DragOver` / `DragLeave` / `Drop`，`Drop` 从 `IDataObject` 取 `CF_HDROP` → `DragQueryFileW` 拿路径）；**同时 `put_AllowExternalDrop(FALSE)`** 关掉 WebView2 自带的 drop 处理（否则 drop 被子窗口的 web 内容吃掉，宿主收不到） | `gtk_drag_dest_set(view, …)` + `drag-data-received` 取 `text/uri-list` → 去 `file://` 前缀 + URL 解码 | Win **最大**（COM 对象 + `CF_HDROP` 解析 + 与 WebView2 的 drop 归属协调）；Linux 中，且**有未知**：WebKit 自己也注册 drag dest，「谁先收到」必须实机试（spike 项） |

两点实现前必须核对的既有事实（**不预设结论**）：

1. **Windows 拖放要求 OLE 已初始化（STA）**：MSDN 口径是 `OleInitialize` 或
   `CoInitializeEx(COINIT_APARTMENTTHREADED)` 之后才可 `RegisterDragDrop`。宿主线程末尾已有
   `CoUninitialize()`（`native/bridge_win.c:735`），说明有配对初始化——实现前先确认它用的是哪种，
   并确认 `RegisterDragDrop` 与 WebView2 的 STA 要求不冲突。
2. **Linux 托盘的「点击图标本体」**：appindicator 的模型是「图标 → 弹菜单」，**没有** `StatusIcon`
   那种 activate 信号。因此 `TrayModel.onClick`（§5.1）在 Linux 上很可能**做不到**。v1 的建议口径：
   Linux 侧忽略 `onClick`（stderr 提示一次「托盘图标点击在 Linux 上不支持，请用菜单项」），
   能力位不足以表达「部分支持」——**如实提示 + 文档写清**，而不是假装成功。

### 5.9 前端形态（JS API）

插件 shim（document-start 注入，RFC-001 §5.4 的 v2 通道）只往桥对象上挂命名空间，不碰
`invoke` / `listen` / `emit`：

```js
// 运行期改状态（走命令，需在清单里声明 menu:setEnabled / menu:setChecked）
window.__CJ_TAURI__.menu.setEnabled({ id: "file.save", enabled: false });
window.__CJ_TAURI__.menu.setChecked({ id: "view.sidebar", checked: true });
window.__CJ_TAURI__.tray.setTooltip({ text: "cj-tauri" });

// 原生事件（走 listen，需在清单 events 里声明；事件名与菜单/托盘/拖放的 id 一样，是应用给的）
window.__CJ_TAURI__.listen("menu:click", function (e) {
    console.log("menu clicked:", e.payload.id);   // "file.save"
});
window.__CJ_TAURI__.listen("tray:click", function (e) { /* e.payload.id */ });
window.__CJ_TAURI__.listen("dragdrop:files", function (e) {
    console.log("dropped:", e.payload.paths);      // ["C:\\a.png"]
});
```

- shim 是**普通字符串拼接、无正则、无反斜杠**——避开 AGENTS §4 那条「三引号字符串吃反斜杠转义」
  的坑（`examples/plugin-fs` 曾因此整段脚本静默全灭）。
- 页面**不要**在模块作用域直接读桥：沿用模板里的 `waitForBridge`（document-start 注入只保证
  「早于页面脚本」，不保证「页面脚本第一行就能用」这一幻觉——`bridge_js.h` 的桥对象总是先建好，
  但应用侧等待逻辑仍应保留）。

## 6. 兼容性与版本

| 维度 | 口径 |
|---|---|
| 现有应用 | **零改动**：不调用 `setMenu` / `setTray` / `setDragDropPolicy` 就没有菜单栏、没有托盘、不注册 drop target（默认关），页面与桥行为逐字不变 |
| C ABI | **只增不改**：新增导出不动任何已有签名（`bridge_core.h:158-217` 的既有契约原样保留），两平台继续由 core 提供唯一实现 |
| Windows 构建 | `native/build_win.bat` 链接行加 `-lshell32`（系统库，无分发成本、无需用户安装） |
| Linux 构建 | **无新增必需依赖**：`ayatana-appindicator3-0.1` 只做 `pkg-config --exists` 探测，命中才编托盘；未命中照旧编译（`-DCJ_TAURI_NO_TRAY`） |
| 新第三方包登记 | `libayatana-appindicator3`（**可选**，AGENTS §3 要求登记：来源 GTK 生态、许可证 LGPL-3.0——登记在 AGENTS §3 的「已登记第三方包」里，并注明「可选项，不强制安装」） |
| 版本 | 0.6.0 → **0.7.0**（新增能力进中间位，AGENTS §6）；五处版本位置同步 + `check-version.sh` 全 `ok` |
| 文档同步 | `CHANGELOG.md` `[Unreleased]`、`README.md`、`docs/使用文档.md`（新能力 + 能力位自检）、`AGENTS.md`（新依赖登记 + 「新增宿主能力」引用本 RFC §5.5 的回调身份约束） |

## 7. 交付物（v1 验收）

分三期，**每期都能独立实机验证并独立提交**（一次提交一件事，AGENTS §5）：

### 7.A 菜单（先做，风险最小、Windows 实机可覆盖）

1. `src/menu.cj`（`MenuModel` / `MenuItem` / `MenuItemKind` / `toWire()`）。
2. `src/host.cj`：`WebViewHost.setMenu` / `setMenuItemState`、`HostCapabilities`、`AppHost.capabilities`。
3. `native/bridge_core.c`：行式格式解析 + `cj_bridge_set_menu` / `cj_bridge_set_menu_item_state` /
   `cj_bridge_host_capabilities`；`bridge_core.h` 加格式注释与导出声明。
4. `native/bridge_win.c`：`CreateMenu` 族 + `WM_COMMAND` + `WM_CJT_MENU`；`bridge_linux.c`：`GtkBox` 装配改造 + `GtkMenuBar`。
5. `src/plugin_menu.cj` + `examples/plugin-menu/`（capability 里故意**只**声明 `menu:click`，
   `menu:setEnabled` 作未授权对照组）。
6. 内置命令 `system:host`（`src/api_system.cj`，三处联动齐全）。

**验收证据（桥 stderr + 页面输出）**：`[cj-bridge] menu: created items=5`；
点「文件 → 保存」后 `[cj-bridge] menu command: id=file.save` → 页面 `menu:click id=file.save`；
`system:host => {"platform":"windows","menu":true,"tray":true,"dragDrop":true}`；
未授权对照组 `command not allowed: menu:setEnabled`；未声明事件时「不投递」也有对照（另一条清单）。

### 7.B 拖入文件（Windows 先做，Linux 留 spike）

1. `src/dragdrop.cj`（`DragDropPolicy`）+ `setDragDropPolicy` 接口 + `cj_bridge_set_drag_drop` 导出 + 平台原语。
2. `bridge_win.c`：`IDropTarget`（COM 实现 + `CF_HDROP` → `DragQueryFileW`）+ `put_AllowExternalDrop(FALSE)`。
3. `bridge_linux.c`：`gtk_drag_dest_set` + `drag-data-received`（`text/uri-list`）——**先 spike 再写产品代码**。
4. `src/plugin_dragdrop.cj` + `examples/drag-drop/`。

**验收证据**：`[cj-bridge] drop: paths=2 first=…` → 页面 `dragdrop:files paths=[…]`；
关掉策略（`enabled=false`）后同一拖放**无回调**（对照组）；Linux 侧必须先回答
「WebKit 自己的 drag dest 与我们的谁先收到」，结论写进验证日志。

### 7.C 托盘（Windows 先做，Linux 可选编译）

1. `src/tray.cj`（`TrayModel`）+ `AppHost.setTray` / `setTrayTooltip`（返回 `Bool`）。
2. `bridge_win.c`：`Shell_NotifyIconW` + `WM_CJT_TRAY` + `NIM_DELETE`（`cj_plat_fini` 里摘图标）+
   `TaskbarCreated` 重注册；`build_win.bat` 加 `-lshell32`。
3. `bridge_linux.c`：`libayatana-appindicator3` 分支 + `-DCJ_TAURI_NO_TRAY` 空实现（返回 0）。
4. `src/plugin_tray.cj` + 示例（可并入 A 的示例工程，避免示例爆炸）。

**验收证据**：`[cj-bridge] tray: added icon=…`、`tray command: id=toggle` → 页面 `tray:click id=toggle`；
退出后**图标消失**（任务栏无残留）；Linux 未装库时 `tray: unavailable (libayatana-appindicator3 not found)`
+ `system:host` 的 `tray=false` + `setTray` 返回 `false`。

### 7.D 门禁与测试（三期共同）

- **单测（渐进目标）**：模型序列化往返（仓颉侧 `toWire()`）、能力位 JSON 形态、事件路由的 label 归属
  → 进 `src/tests/`。
- **桥的桩平台自检**：行式格式解析器在 `bridge_core.c` 里是**纯 C、不依赖 SDK / 图形栈**，
  正好加进既有的 `native/tests/test_bridge_core.c`（现 61 项断言）——这是本项目「不需要 SDK 也能跑的门禁」
  的既有模式，新增解析器不给它加断言等于没验收。
- **实机**：Windows 三期都能跑（本机有实机）；Linux 的菜单 / 拖放 / 托盘（含 spike）留给 Linux 机位，
  未跑的在文档里如实标注「未验证」。

## 8. 开放问题（评审时请逐条回答）

> **评审结论（2026-10-03）**：第 1 条——**原生实现**（用户请评审方定调，取原建议项，理由见下）；
> 第 2 条——**可选编译**（`build_linux.sh` 里 `pkg-config` 探测 + 未命中 `-DCJ_TAURI_NO_TRAY` +
> 能力位如实 `false`）；第 3 条——**只做文件拖入 → 真实路径**（接管 drop：Windows 侧
> `put_AllowExternalDrop(FALSE)`；**不做拖出**，**不做三态**——策略关掉即不注册 drop target，
> 这是唯一的开关）。第 4-9 条按本节的建议执行；实现时若有偏差，回来改这一节
> （体例与 RFC-001 §8 的「已决」标注一致）。

**1. 菜单形态：OS 原生菜单栏，还是只定模型不实现？**
建议 **原生实现**——理由：架构文档 §5 的判据是「没有第二个实现来验证的抽象只定模型」，而菜单的
「原生菜单栏」在两个平台都是系统自带能力（Win32 `HMENU`、GTK `GtkMenuBar`），翻译层是确定的、
不需要靠第二个平台来反推抽象；真正需要第二个实现验证的是「菜单**在抽象上怎么描述**」，那部分本 RFC
§5.1 已经用纯仓颉模型定住了。反方（可接受）：v1 只落模型 + 能力位，实现等有应用真要菜单时再做。

**2. Linux 托盘：可选编译、只做 Windows、还是强制依赖 `libayatana-appindicator3`？**
建议 **可选编译**（架构文档 §6.3 已定、本机实测现状 = 缺库）：强制依赖等于「用户没装 dev 包就编译不过」，
是分发事故不是功能缺失；代价是 Linux 上托盘可能不可用，由 `HostCapabilities.tray=false` 如实暴露。

**3. 拖放：只做「文件拖入 → 真实路径」，还是顺带做 HTML5 直通 / 拖出？**
建议 **只做前者**：HTML5 DnD 在页面里本来就能用（框架不该抢），而**真实路径**只有宿主拿得到
（WebView2 的 `File` 对象没有本地路径）；拖出（drag out）没有需求来源，v1 不做。
注意 `put_AllowExternalDrop(FALSE)` 会**关掉** WebView2 自带的 HTML5 drop 处理——要不要改成
「默认保留、应用显式开启才接管」（即策略三态）请一并定调。

**4. 线路格式：制表符行式文本（建议）还是 JSON + C 侧极简解析器？**
前者 C 侧零依赖、可 `fprintf` 成诊断；后者眼熟但要多写约 200 行解析状态机。倾向前者。

**5. 菜单 / 托盘 / 拖放做成**三个官方插件**（建议，事件走 `menu:click` 等），还是框架内置 `system:` 命令？**
插件模型的 `events()` / `jsShim()` / `permissions()` 三件套正好覆盖这三者的需要，且「声明 ≠ 放行」
的铁律已经过验证；`system:` 留给元能力。**本条同时回答 RFC-001 §8 第 6 条**（非命令类能力怎么进模型）：
答案是「宿主层原语 + 官方插件包装」，因此**不需要**给 `Plugin` 接口新增「要求宿主能力」的预留位
——插件通过既有的 `setup(app: TauriApp)` 就能拿到宿主 API。

**6. `HostCapabilities` 放 `AppHost`（建议）还是 `WebViewHost`？** 同一进程内平台必然相同，
放两份只会带来不一致风险；托盘的差异也属进程级。

**7. 菜单是否只做窗口级（建议）？** 应用级（macOS 风格全局菜单栏）v1 不做——本项目两个平台都没有
这个概念（Windows 的菜单栏本来就挂在窗口上）。

**8. Explorer 重启后的托盘重注册（`TaskbarCreated`）v1 就做吗？** 建议**做**：不做的话用户重启
Explorer 后托盘就消失，是肉眼可见的缺陷；实现成本只是多一个 `RegisterWindowMessageW` 分支。

**9. Linux 的 `TrayModel.onClick` 降级口径（§5.8 第 2 点）是否接受？** appindicator 很可能没有
「点击图标本体」的信号，v1 建议「忽略 + stderr 提示一次 + 文档写清」，不假装支持。此条**待 Linux 实机核对**。

## 9. 参考

- 上位文档：[架构演进-多平台与多窗口](架构演进-多平台与多窗口.md) §2.3（只定模型）、§5（抽象判据）、
  §6.3（托盘可选编译 + `HostCapabilities` 如实上报）、§7.5（回调身份的残余项）。
- 同族 RFC：[RFC-001 插件体系](RFC-插件体系.md) §5.4（jsShim 的 document-start 通道）、§6（命名权限集）、
  §8 第 6 条（非命令类能力怎么进模型——本 RFC §8 第 5 条回答）。
- 本仓现状：`src/host.cj`（宿主接口 + `HostGlobals`）、`src/plugin_dialog.cj`（插件范式）、
  `src/capability.cj`（能力校验）、`src/ipc_hub.cj`（事件投递）、`native/bridge_core.h`（导出与平台原语契约）、
  `native/bridge_win.c` / `native/bridge_linux.c`（两平台装配点）、`native/build_win.bat` / `build_linux.sh`（构建开关）。
- 对标实现：Tauri v2 的 `menu` / `tray` 模块（模型与原生翻译层分离、`HostCapabilities` 式能力自省）；
  wry 的 Windows 拖放实践（`IDropTarget` + 关闭 WebView 自带 drop）。
- 平台资料：WebView2 SDK `ICoreWebView2Controller4::AllowExternalDrop`（本机 SDK 1.0.2365.46 的
  `WebView2.h` 已含）、Win32 `Shell_NotifyIcon` / `RegisterDragDrop` / `CF_HDROP`、
  GTK `GtkMenuBar` / `gtk_drag_dest_set` + `text/uri-list`、`libayatana-appindicator3`。
