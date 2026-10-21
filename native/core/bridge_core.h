/*
 * cj-tauri C 桥公共核心（批次 1）：句柄化的宿主状态 + 平台无关逻辑
 *
 * 分层（AGENTS.md §2：平台差异只允许出现在 @When 与 bridge_*.c）：
 *   bridge_core.c/.h  平台无关：JS 回投队列与批处理、对话框单槽状态机、窗口配置存储、
 *                     预执行脚本注册表、生命周期标志、全部 cj_bridge_* 导出（单一来源）
 *   bridge_linux.c    GTK / WebKitGTK 原语：建窗装配、gtk_main、原生对话框、idle 投递
 *   bridge_win.c      Win32 / WebView2 / COM 原语：窗口类与消息循环、COM 回调、原生对话框
 *
 * 为什么句柄化：原先是进程级单例（g_window / g_hwnd），多窗口无从落地——
 *   见 docs/架构演进-多平台与多窗口.md §2.1。这里把「哪个窗口」变成显式句柄，单窗口行为不变。
 *
 * 分工铁律：
 *   1. core **不 include 任何平台头**（pthread / windows.h / gtk），需要平台能力一律走 cj_plat_*；
 *   2. 平台文件**不实现任何 cj_bridge_***（导出全在 core，两平台导出名与签名因此逐字一致）；
 *   3. 平台文件只实现下面的「平台原语清单」。
 *
 * 句柄生命周期（docs/架构演进-多平台与多窗口.md §6.1）：
 *   窗口关闭 ≠ 释放句柄。窗口销毁时平台调 cj_core_window_destroyed()，只置标志 + 通知回调 +
 *   释放原生/COM 资源；句柄内存由 cj_bridge_destroy() 在 C 侧回收（malloc 与 free 同侧）。
 *   仓颉侧保证 destroy 至多调用一次并把字段置空（C 侧的 destroy 对 NULL 安全）。
 */
#ifndef CJ_BRIDGE_CORE_H
#define CJ_BRIDGE_CORE_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 导出宏：导出定义全在 bridge_core.c，平台文件只实现 cj_plat_*（不重复定义导出）。
   Windows 要 dllexport；Linux 默认可见，仍显式声明一遍。 */
#if defined(_WIN32)
#define CJ_BRIDGE_API __declspec(dllexport)
#else
#define CJ_BRIDGE_API __attribute__((visibility("default")))
#endif

/* ===== 仓颉侧回调（@C 函数）===== */
typedef void (*cj_on_message_fn)(const char *json); /* JS 消息到达（UTF-8 JSON）*/

/* 前向声明：下面三个回调签名都要用到宿主句柄，而 cj_host 结构体还在后面才定义。
   必须是**文件作用域**的前向声明——只在参数列表里写 struct cj_host，clang 会把它当成
   「仅本原型内可见」的另一个类型（-Wvisibility），赋函数指针时就报类型不兼容。 */
struct cj_host;

/* **为什么这些回调的首参是宿主句柄**：仓颉的 @C 函数是模块级函数，每个宿主注册的是同一个
   函数指针，不把 h 传回去就分不清是哪个窗口触发的——多窗口下就是「后装配的窗口覆盖先装配的」
   那个静态单槽坑（docs/架构演进-多平台与多窗口.md §7.5）的根治办法。**新增回调一律照此带宿主身份。**

   cj_on_message_fn 是唯一的例外，且是**有意**的：报文自带发起窗口的 window label
   （架构文档 §7.3），仓颉侧给所有窗口装的是同一只派发器，不需要按句柄分表
   （见 src/app.cj 的 wireHostCallbacks）。其余回调没有这种自带身份的载荷，只能靠句柄。 */
typedef void (*cj_on_destroy_fn)(struct cj_host *host); /* 窗口销毁 / 退出（每个宿主恰好一次）*/
typedef void (*cj_on_dialog_fn)(struct cj_host *host, const char *path); /* 原生对话框选中的路径（取消 = 空串）*/

/* 宿主级 shell 事件回调：**菜单 / 托盘 / 拖放共用一个入口**（RFC-002 §5.5），
   第一个参数回传宿主句柄，第二个是 JSON 载荷（与 on_message 同一载体，仓颉侧已有 JSON 解析）。

       {"kind":"menu","id":"file.save","enabled":true,"checked":false}
       {"kind":"tray","id":"toggle"}                     ← 7.C
       {"kind":"drop","paths":["C:\\a.png"]}             ← 7.C

   **签名这里必须写 `struct cj_host *`（不能用 `cj_host *`）**：本 typedef 要出现在 cj_host
   结构体定义之前（结构体里有 on_shell 字段），此时那个 typedef 名字还不存在，只有上面刚做的
   结构体前向声明可用。同一类型，Cangjie 侧看不出来——它只拿到一个不透明指针。 */
typedef void (*cj_on_shell_fn)(struct cj_host *host, const char *json);

/* 前端 __CJ_TAURI__.reload() 的控制消息：宿主级操作，不进 IPC hub
   （与 native/bridge_js.h 里的字面量必须一致） */
#define CJT_RELOAD_MSG "__cj_tauri_reload__"

/* 单批上限：一次 UI 空闲窗口最多合并多少条回投。写成常量而不是「取空为止」，
   是为了长队列也肯让出 UI 线程（剩下的由自续唤醒接手）。 */
#define CJ_JS_BATCH_MAX 64

/* 宿主能力位（cj_bridge_host_capabilities 的返回值，RFC-002 §5.4）：
   纯静态事实，由平台在 cj_plat_init 时给出（例：Linux 侧托盘没编进来 → 不置 CJ_CAP_TRAY），
   仓颉侧据此构造 HostCapabilities，`system:host` 如实上报，不许猜。 */
#define CJ_CAP_MENU      1
#define CJ_CAP_TRAY      2
#define CJ_CAP_DRAG_DROP 4
#define CJ_CAP_NOTIFICATION 8 /* 平台通知可用（Linux = freedesktop Notifications）*/
#define CJ_CAP_HOTKEY    16 /* 全局快捷键可用（Linux = X11 grab；Wayland 不置位）*/
#define CJ_CAP_SUBTITLE  32 /* 窗口顶部那一行能显示副标题（Linux = 与菜单栏同排的 label；
                               Windows 的系统菜单没有自绘区，未实现、不置位）*/

/* ===== 回投队列节点（core 拥有；UTF-8 存储，宽字符转换由平台在 cj_plat_post_js 里做）===== */
typedef struct js_node {
    char *js;
    struct js_node *next;
} js_node;

/* ===== 原生对话框请求（core 分配 / 释放；平台只填 ok 与 path）===== */
typedef struct dlg_req {
    int kind;      /* 0 打开文件 1 保存文件 2 info 3 warning 4 error 5 confirm 6 选择目录 */
    char *title;
    char *message;
    char *filter;  /* "描述|模式|描述|模式"；空串 = 不过滤 */
    char *path;    /* 文件类结果：选中路径（取消时为空）*/
    int ok;        /* 1 = 用户点了确认 */
} dlg_req;

/* ===== 同步原语句柄（平台私有结构：Linux = mutex + cond；Windows = CRITICAL_SECTION +
   CONDITION_VARIABLE）。core 只用它们，绝不直接碰 pthread / Win32。 ===== */
typedef struct cj_sync cj_sync;

/* ===== 宿主句柄：core 拥有的状态 + 一个平台私有指针 ===== */
typedef struct cj_host {
    /* --- 回调（cj_bridge_init 注入）--- */
    cj_on_message_fn on_message;
    cj_on_destroy_fn on_destroy;
    cj_on_dialog_fn  on_dialog;
    cj_on_shell_fn   on_shell;  /* cj_bridge_set_shell_callback 注入；未注册 = 事件只留日志 */

    /* --- JS 回投队列（FIFO：每条 JS 独立执行，防止覆盖）--- */
    cj_sync *js_lock;
    js_node *js_head;
    js_node *js_tail;

    /* --- 对话框单槽：对话框是模态的，同时只允许一个（嵌套调用直接拒绝而不是自锁）--- */
    cj_sync *dlg_lock;
    int dlg_busy;   /* 有人正在进行中 */
    int dlg_ready;  /* 结果就绪（与 dlg_lock 配套的谓词）*/
    dlg_req *dlg_cur; /* 进行中的请求；窗口先关时由 cj_core_window_destroyed 作废 */

    /* --- 剪贴板单槽（同一时刻只允许一次读写；窗口销毁时作废等待方）---
       读结果经 cb_text 交回（core malloc，调用方 cj_bridge_clipboard_free 释放），
       cb_ok=0 表示失败/作废（cb_text 为 NULL）。 */
    cj_sync *clip_lock;
    int clip_ready;
    int clip_ok;
    char *clip_text;   /* 读操作的结果（UI 线程 malloc，等待方负责释放）*/
    int clip_busy;

    /* --- 窗口配置：由仓颉侧在 cj_bridge_start 之前经 cj_bridge_set_window 注入 --- */
    char *win_title;
    int win_w;
    int win_h;
    char *win_icon;  /* NULL = 系统默认图标 */
    int devtools;    /* 开发者工具开关 */

    /* 窗口初始可见性（cj_bridge_set_window_visible 存入）：1 = 显示（默认，老应用行为不变）、
       0 = 窗口建好即隐藏。**只解决「建窗那一刻该不该显示」**——运行期改可见性由平台直接投
       UI 线程执行，不需要它。 */
    int win_visible;

    /* 最小化到托盘（cj_bridge_set_minimize_to_tray 存入）：1 = 平台把「最小化」改写成「隐藏」。
       真到最小化那一刻平台还会复核托盘是否真装上了（没有就如实降级为普通最小化 + 一行 stderr）。 */
    int minimize_to_tray;

    /* --- 预执行脚本（cj_bridge_add_init_script 追加，WebView 创建时逐条注入到
       document-start；插件的 jsShim 走这条通道，注册顺序排在 BRIDGE_JS 之后）--- */
    char **init_scripts;
    int init_script_count;
    int init_script_cap;

    /* --- 页面来源二选一（URL 优先）：start 之前注入，start 之后由平台导航 --- */
    char *pending_html;
    char *pending_url;

    /* --- 菜单线路文本（cj_bridge_set_menu 存入；平台建窗时读它，运行期改则由平台重建）--- */
    char *pending_menu_text;

    /* --- 拖放策略（cj_bridge_set_drag_drop 存入：enabled/files 两个开关）。
            enabled=0 平台不注册 drop target（默认关——现有应用零改动）；
            平台建 view 时读它决定要不要挂 drag dest，运行期再改由平台重挂 --- */
    int pending_drop_enabled;
    int pending_drop_files;

    /* --- 全局快捷键线路（cj_bridge_set_global_hotkeys 存入，空串 = 一个都没注册）。
            格式一行一条：`<accel>:<id>`（accel 如 Ctrl+Alt+C，id 是应用给的标识）。
            平台负责解析 accel 并 grab；触发时经 cj_core_hotkey_pressed 交回 core。
            运行期再调 = 整表替换（先 ungrab 再按新表 grab） --- */
    char *pending_hotkeys;

    /* --- 托盘线路（cj_bridge_set_tray 存入，空串 = 移除托盘）。
            格式（与 src/tray.cj 的 TrayModel.toWire() 逐字对应）：
              第 1 行 `icon\t<路径>`（空路径 = 主题默认图标）
              第 2 行 `tooltip\t<文本>`（可空）
              其余行 = 菜单项，与菜单线路同格式（kind\tid\tlabel\tflags\taccel，无前导制表符 = 平铺一层）
            平台建宿主线程时读它装配；运行期再调 = 整体重建。菜单项被点经
            cj_core_tray_clicked 交回 core（{"kind":"tray","id":…}，与菜单点击同走 on_shell） --- */
    char *pending_tray;

    /* --- 能力位（cj_plat_init 时由 cj_plat_host_capabilities 填，此后只读）--- */
    int capabilities;

    /* --- 生命周期 --- */
    volatile int ready;       /* 宿主 UI 就绪（平台在窗口 + WebView 建好后置 1）*/
    volatile int should_quit; /* 事件循环已退出 / 要求退出（平台在启动失败等路径可直接置 1）*/
    int window_gone;          /* 窗口已销毁、原生资源已释放；句柄壳仍可安全调用 destroy */
    int destroy_notified;     /* onDestroy 是否已触发（quit 与关窗只通知一次）*/

    /* --- 平台私有（GTK 窗口/view；HWND + COM 接口 + 宿主线程 id）--- */
    void *plat;
} cj_host;

/* =========================================================================
 *  平台原语清单（每个平台实现一份，共 24 个）
 * ========================================================================= */

/* ---- 同步（Linux: pthread_mutex + pthread_cond / Windows: CS + CONDITION_VARIABLE）---- */
cj_sync *cj_plat_sync_create(void);                       /* 非递归锁 + 配套条件变量 */
void cj_plat_sync_destroy(cj_sync *s);
void cj_plat_sync_lock(cj_sync *s);
void cj_plat_sync_unlock(cj_sync *s);
/* 谓词等待：内部 while (!*ready) 等待（允许虚假唤醒）；返回时 *ready 已为真 */
void cj_plat_sync_wait(cj_sync *s, int *ready);
void cj_plat_sync_signal(cj_sync *s);

/* ---- 宿主 ---- */
void cj_plat_init(cj_host *h);   /* 一次性平台初始化（Windows: COM vtbl；Linux: 无）*/
/* 释放宿主级平台资源（模块句柄、平台状态），幂等。
   注意：**不**释放 COM 对象——WebView2 的 controller / environment 按「活到进程退出」口径处理，
   平台文件只把指针置空（见 bridge_win.c 的 host_thread_main 收尾段），两平台的 fini 都不碰 COM。
   等待必须有界：宿主线程收尾要进入仓颉运行时（onDestroy 回调），阻塞式 join 会与运行时「停处理器」
   握手互等（Linux 侧实测 6 轮挂 1 轮，见 AGENTS.md §4），所以这里只做有界等待，不做无限 join。
   返回 1＝状态已释放、句柄可以回收；0＝宿主线程可能还在收尾，调用方须保留句柄与状态，不要 free。 */
int cj_plat_fini(cj_host *h);
void cj_plat_start(cj_host *h);  /* 起宿主线程：建窗口 + WebView + 跑事件循环，非阻塞返回 */
void cj_plat_quit(cj_host *h);   /* 请求退出：走与「用户关窗」同一条销毁路径 */
void cj_plat_wake_ui(cj_host *h);/* 让 UI 线程尽快跑一次 cj_core_flush_js */
void cj_plat_post_js(cj_host *h, const char *script_utf8); /* UI 线程执行一段 JS（含失败日志）*/
int  cj_plat_is_ui_thread(cj_host *h);                     /* 1 = 调用方已站在 UI 线程上 */
void cj_plat_post_dialog(cj_host *h, dlg_req *req);        /* 投到 UI 线程 → cj_core_dialog_tick */

/* 通用「投到 UI 线程执行」原语（剪贴板等后续宿主能力共用；对话框那套是它之前的专用通道）：
   在 UI 线程上回调 fn(ud)（一次），投不出去返回 0（调用方自行作废等待）。
   平台实现：Linux = g_idle_add；Windows = PostMessageW 新消息，UI 线程取 lParam 调 fn。 */
typedef void (*cj_ui_fn)(void *ud);
int cj_plat_post_ui(cj_host *h, cj_ui_fn fn, void *ud);
int  cj_plat_run_dialog(cj_host *h, dlg_req *req);         /* UI 线程直接弹原生对话框，写 req */
void cj_plat_open_devtools(cj_host *h);
void cj_plat_load_url(cj_host *h, const char *url);
void cj_plat_reload(cj_host *h);

/* ---- 菜单 / 能力位（RFC-002；7.A 只做菜单栏，托盘 / 拖放在 7.B / 7.C）----
   wire 是 `MenuModel.toWire()` 的线路文本（格式见 cj_core_menu_walk 的注释），空串 = 清空菜单栏。
   调用时机两头都要支持：**未就绪**时只记下（平台建窗时读 h->pending_menu_text）；**已就绪**时由平台
   投到 UI 线程重建菜单。cj_plat_menu_item_state 只改运行期状态（可用 / 勾选），要快、可能频繁。 */
void cj_plat_set_menu(cj_host *h, const char *wire);

/* 平台原语：把副标题写到窗口顶部那一行（UI 线程调用）。返回 0 = 已提交，
   -3 = 宿主未就绪，-4 = 本平台没这块（Windows 的系统菜单没有自绘区）。 */
int cj_plat_set_titlebar_subtitle(cj_host *h, const char *text);
void cj_plat_menu_item_state(cj_host *h, const char *id, int enabled, int checked);
void cj_plat_set_drag_drop(cj_host *h, int enabled, int files);

/* 全局快捷键（RFC-003 第 5 期首个落地项）：wire 一行一条 `<accel>:<id>`（见 pending_hotkeys 注释）。
   调用时机两头都要支持：未就绪时只记下（平台建宿主线程后读 h->pending_hotkeys），
   已就绪时整表替换（先 ungrab 旧表再 grab 新表）。平台不支持（Wayland / Windows 桩）时
   打一行 stderr 如实说明，不算错误。 */
void cj_plat_set_global_hotkeys(cj_host *h, const char *wire);

/* 托盘（RFC-002 §7.C）：wire 见 pending_tray 注释，空串 = 移除托盘。
   未就绪时只记下（宿主线程装配时读 h->pending_tray）；已就绪时投 UI 线程重建。
   平台不支持 / 依赖没编进来时打一行 stderr 如实说明（可选编译，RFC-002 §6.3）。 */
void cj_plat_set_tray(cj_host *h, const char *wire);

/* 窗口可见性（RFC-003 第 5 期余项：最小化到托盘的还原路径）。
   未就绪时平台**什么都不做**——core 已把值写进 h->win_visible，平台建窗时读它定稿；
   已就绪时投 UI 线程执行（Linux = gtk_widget_show/hide + gtk_window_present，Windows = ShowWindow）。 */
void cj_plat_set_window_visible(cj_host *h, int visible);

/* 最小化到托盘策略（须在建窗前调）：平台把窗口过程 / 窗口状态信号里的「最小化」改写成「隐藏」。
   平台在**真要最小化那一刻**复核托盘是否真的装上了（能力位 / 应用有没有 setTray）：
   没装就降级为普通最小化并打一行 stderr——窗口藏起来却没有还原入口是比「不支持」更糟的结果。 */
void cj_plat_set_minimize_to_tray(cj_host *h, int enabled);

/* 宿主能力位（CJ_CAP_* 的按位或）：纯静态事实，cj_plat_init 里由平台给出。 */
int cj_plat_host_capabilities(cj_host *h);

/* ---- 串口（plugin_serial）----
   与窗口 / WebView 无关，所以平台原语**不带 cj_host**：串口是设备 I/O，不是宿主能力位，
   也不该为了拿一个句柄强迫应用先建窗口（无头侧跑串口服务是合法用法）。

   分工：**句柄表与真正的 termios / Win32 调用在平台侧**——平台本来就有 pthread / CS 这类同步设施，
   静态初始化即可，core 不必再发明一次「一次性初始化」；core 只做**路径白名单**与参数校验
   （安全边界 + 平台无关，因而能被桩平台自检覆盖）。

   返回码口径（core 与平台一致，上层因此不必写平台分支）：
     >0  = 成功（句柄，仅本进程有意义；页面/前端拿不到它对应的 fd）
     -1  = 参数非法（含路径不在白名单内）
     -2  = 句柄表满
     -3  = 打开 / 配置失败（明细写进 err）
     -4  = 句柄无效 / 该平台未实现
   read / write：>=0 实际字节数（0 = 超时无数据），<0 = 失败。 */
typedef struct cj_serial_cfg {
    int baud;       /* 数值波特率（平台自己查 speed_t / DCB 表）；不认识的值由平台拒绝 */
    int data_bits;  /* 5..8 */
    int parity;     /* 0=无 1=奇 2=偶 */
    int stop_bits;  /* 1 或 2 */
} cj_serial_cfg;

long long cj_plat_serial_open(const char *path, const cj_serial_cfg *cfg, char *err, int err_len);
int cj_plat_serial_read(long long h, unsigned char *buf, int len, int timeout_ms, char *err, int err_len);
int cj_plat_serial_write(long long h, const unsigned char *buf, int len, int timeout_ms,
                         char *err, int err_len);
int cj_plat_serial_close(long long h, char *err, int err_len);

/* 枚举本机串口：一行一个名字写进 out（\n 分隔），返回条数；-1 参数非法，-4 未实现。
   Linux 侧尚未实现（-4）——serial:list 在 Linux 仍走仓颉侧的 /dev 目录扫描。 */
int cj_plat_serial_list(char *out, int out_len);

/* 设备路径白名单（纯函数、平台无关）：只放行常见串口设备节点 / 伪终端 / udev 稳定链接，
   含 ".." 的一律拒绝。**这是安全边界**——路径是页面可控字符串，core 这里强制校验一次，
   平台实现就不必各自重写策略（仓颉侧另有一份镜像用于「跨 FFI 之前」给出可读错误，C 这份是权威）。
   非导出符号：桩平台自检直接调它。 */
int cj_serial_path_allowed(const char *path);

/* =========================================================================
 *  core 提供给平台的状态迁移（平台的事件循环里调用）
 * ========================================================================= */
void cj_core_set_ready(cj_host *h);       /* 窗口 + WebView 就绪（平台在装配完成后调）*/
void cj_core_flush_js(cj_host *h);        /* UI 线程：取队列拼批回投（idle / WM_CJT_FLUSH 里调）*/
void cj_core_dialog_tick(cj_host *h, dlg_req *req); /* UI 线程：弹对话框 → 回调 → 唤醒等待方 */
void cj_core_dialog_abort(cj_host *h);    /* 作废进行中的对话框并唤醒等待方（ok=0，幂等）*/
int cj_core_clipboard_tick(cj_host *h, int is_write, char *text); /* UI 线程：执行剪贴板调用 → 唤醒等待方（返回 1=成功）*/
void cj_core_clipboard_abort(cj_host *h); /* 作废进行中的剪贴板请求并唤醒等待方（幂等）*/
void cj_core_window_destroyed(cj_host *h);/* 窗口销毁：置标志 + 通知 onDestroy（一次）+ 作废对话框 */

/* ---- 菜单线路格式的共享解析（两平台翻译层共用，避免各写一遍前缀/分割逻辑）----
   格式（RFC-002 §5.4，与仓颉侧 `MenuModel.toWire()` 逐字对应）：

       <行首制表符 = 层级><kind>\t<id>\t<label>\t<flags>\t<accel>\n

   kind：`n` 普通 / `c` 勾选 / `s` 分隔线 / `m` 子菜单；
   flags：十进制，bit0 = 可用、bit1 = 勾选（`3` = 又可用又勾选）。
   容错口径：字段缺失按空串 / 0 处理，kind 为空的行整行跳过——**不崩**优先于报错，
   真正的结构错误在仓颉侧就该被丢弃（toWire 不出口含制表符/换行的字段）。

   回调期间字段指针指向 core 内部的副本，**回调返回后失效**（需要留存请自行拷贝）。 */
typedef void (*cj_menu_row_fn)(void *ctx, int depth, char kind, const char *id,
                               const char *label, int flags, const char *accel);
void cj_core_menu_walk(const char *wire, cj_menu_row_fn fn, void *ctx);

/* 平台把「菜单项被点了」交回 core：core 记日志 + 经 h->on_menu 回调仓颉侧（带宿主身份）。 */
void cj_core_menu_clicked(cj_host *h, const char *id, int enabled, int checked);

/* 全局快捷键触发（平台在 grab 的事件回调里调）：id 是应用注册时给的标识。
   core 记日志 + 以 shell 报文 {"kind":"hotkey","id":"…"} 经 on_shell 回调仓颉侧（首参宿主句柄，
   仓颉侧按句柄路由——快捷键事件与菜单点击同走 on_shell 通道，不新增回调类型）。 */
void cj_core_hotkey_pressed(cj_host *h, const char *id);

/* 托盘菜单项被点（平台在 appindicator 的 activate 回调里调）：id 是 TrayModel 里应用给的标识。
   core 记日志 + 以 shell 报文 {"kind":"tray","id":"…"} 经 on_shell 回调仓颉侧（首参宿主句柄，
   按句柄路由；前端事件名 tray:click 由仓颉侧 shellEventNameFor 映射——RFC-002 §5.5 既有约定）。 */
void cj_core_tray_clicked(cj_host *h, const char *id);

/* 拖放落地（平台在 drag-data-received 里调）：uri_list 是 text/uri-list 原文
   （\r\n 或 \n 分隔，可含 file:// URI 与百分比编码）。
   core 负责解析：跳过注释行/空行、file:// 解码成路径（%XX 十六进制解码）、
   非 file:// 的 URI 原样保留（v1 载荷只有文件，页面自己决定要不要）。
   结果以 shell 报文 {"kind":"drop","paths":[…]} 经 on_shell 回投（首参宿主句柄，
   仓颉侧按句柄路由）。paths 上限 32 个、单个路径上限 4096 字节（超限丢弃并记日志）。 */
void cj_core_drop_files(cj_host *h, const char *uri_list);

/* =========================================================================
 *  仓颉 → C 桥：导出（全部实现在 bridge_core.c，两平台同一份）
 * ========================================================================= */

/* 建宿主：分配公共状态（默认标题尺寸 900x640、devtools 开）+ 建两把锁。失败返回 NULL。 */
CJ_BRIDGE_API cj_host *cj_bridge_create(void);

/* 释放宿主编：先 cj_plat_fini，再回收公共状态。对 NULL 安全。
   契约：仓颉侧在 waitForExit 返回后调用**至多一次**，调用后句柄不可再用（字段置空）。 */
CJ_BRIDGE_API void cj_bridge_destroy(cj_host *h);

/* 注入回调（JS 消息到达 / 窗口销毁）+ 平台一次性初始化 */
CJ_BRIDGE_API void cj_bridge_init(cj_host *h, cj_on_message_fn m, cj_on_destroy_fn d);

/* 窗口配置（标题 / 尺寸）：必须在 cj_bridge_start 之前调用 */
CJ_BRIDGE_API void cj_bridge_set_window(cj_host *h, const char *title, int width, int height);

/* 窗口图标（png / ico 路径）：必须在 cj_bridge_start 之前调用；空路径 = 系统默认图标 */
CJ_BRIDGE_API void cj_bridge_set_icon(cj_host *h, const char *path);

/* 开发者工具开关：enabled=0 表示禁止打开（须在 cj_bridge_start 之前调用） */
CJ_BRIDGE_API void cj_bridge_set_devtools(cj_host *h, int enabled);

/* 注册一段预执行脚本（须在 cj_bridge_start 之前调用；空串忽略） */
CJ_BRIDGE_API void cj_bridge_add_init_script(cj_host *h, const char *js);

/* 起宿主：html 非空则记作内联页面（空串 = 页面由 cj_bridge_load_url 指定）。
   平台在独立线程里建窗 + WebView + 跑事件循环，本函数立即返回。 */
CJ_BRIDGE_API void cj_bridge_start(cj_host *h, const char *html);

/* 原生 → JS：投递一段脚本（入队，UI 线程批量执行）。
   前端 promise 的 resolve/reject 都走这条通道，静默失败会让前端永久 pending。 */
CJ_BRIDGE_API void cj_bridge_run_js(cj_host *h, const char *js);

/* 按 URL 加载页面（http(s):// 或 file://）：
 *   - cj_bridge_start 之前调用：只记下 URL，宿主就绪时加载（与 HTML 二选一，URL 优先）；
 *   - 启动之后调用：投递到 UI 线程重新导航（运行期切页面）。
 * 空 URL 忽略。 */
CJ_BRIDGE_API void cj_bridge_load_url(cj_host *h, const char *url);

/* 重新加载当前页面：投递到 UI 线程执行 */
CJ_BRIDGE_API void cj_bridge_reload(cj_host *h);

/* 运行时打开开发者工具：投递到 UI 线程执行 */
CJ_BRIDGE_API void cj_bridge_open_devtools(cj_host *h);

/* 请求退出：与「用户关窗」走同一条销毁路径（onDestroy 恰好触发一次） */
CJ_BRIDGE_API void cj_bridge_quit(cj_host *h);

/* 宿主 UI 是否就绪 / 事件循环是否已退出（供仓颉侧 run 阻塞轮询） */
CJ_BRIDGE_API int cj_bridge_is_ready(cj_host *h);
CJ_BRIDGE_API int cj_bridge_should_quit(cj_host *h);

/* 原生对话框回调（选中路径回送仓颉侧） */
CJ_BRIDGE_API void cj_bridge_set_dialog_callback(cj_host *h, cj_on_dialog_fn cb);

/* 阻塞式原生对话框：返回 1 = 用户确认（文件类路径已回调送回），0 = 取消 / 宿主未就绪 /
   已有对话框在进行中。调用方已站在 UI 线程时内部走直接弹的快路径（投递 + 等待会自锁）。 */
CJ_BRIDGE_API int cj_bridge_show_dialog(cj_host *h, int kind, const char *title,
                                        const char *message, const char *filter);

/* 菜单栏：wire 是 MenuModel.toWire() 的线路文本（空串 = 移除菜单栏）。
   未 start 时只记下、建窗时生效；start 之后调用＝运行期换菜单（平台投到 UI 线程重建）。 */
CJ_BRIDGE_API void cj_bridge_set_menu(cj_host *h, const char *wire);

/* 运行期改单个菜单项的状态（按 id 找；找不到只记日志不报错）。 */
CJ_BRIDGE_API void cj_bridge_set_menu_item_state(cj_host *h, const char *id, int enabled, int checked);

/* 拖放策略（RFC-002 §5）：enabled=0 平台不注册 drop target（默认关）。
   两头都能用：未就绪时记 pending（建 view 时读），就绪后平台投 UI 线程重挂 drag dest。 */
CJ_BRIDGE_API void cj_bridge_set_drag_drop(cj_host *h, int enabled, int files);

/* 窗口顶部副标题：把一行 UTF-8 文本画在原生菜单栏**同一行的右侧**（应用据此省掉
   自己的页面顶栏，标题 / 保存状态 / 字数都能挂在原生那一行上）。允许运行期高频更新，
   实现必须自己投递到 UI 线程（Linux 走 g_idle_add，同 set_menu）。
   返回 0 = 已受理，-1 = 参数非法（含超过 1024 字节），-3 = 宿主未就绪，
   -4 = 本平台未实现（应用据 CJ_CAP_SUBTITLE 决定要不要自己画顶栏）。 */
CJ_BRIDGE_API int cj_bridge_set_titlebar_subtitle(cj_host *h, const char *text);

/* 全局快捷键：wire 一行一条 `<accel>:<id>`（空串 = 全部注销）。
   两头都能用：未就绪时记 pending（宿主线程起来后读），就绪后整表替换（ungrab 旧表再 grab 新表）。 */
CJ_BRIDGE_API void cj_bridge_set_global_hotkeys(cj_host *h, const char *wire);

/* 托盘（RFC-002 §7.C）：wire 见 pending_tray 注释（icon/tooltip 两行 + 菜单项），空串 = 移除。
   两头都能用：未就绪时记 pending（宿主线程装配时读），就绪后平台投 UI 线程重建。 */
CJ_BRIDGE_API void cj_bridge_set_tray(cj_host *h, const char *wire);

/* 窗口可见性（对标 Tauri 的 window.show()/hide()）：visible=1 显示并提到前台、0 隐藏。
   两头都能用：未 start 时只记下（平台建窗时按 h->win_visible 定稿），start 之后投 UI 线程执行。 */
CJ_BRIDGE_API void cj_bridge_set_window_visible(cj_host *h, int visible);

/* 最小化到托盘策略（须在 cj_bridge_start 之前调）：1 = 平台把「最小化」改写成「隐藏」。
   平台在真要最小化那一刻复核托盘是否装上，没装则降级为普通最小化 + 一行 stderr。 */
CJ_BRIDGE_API void cj_bridge_set_minimize_to_tray(cj_host *h, int enabled);

/* shell 事件回调（菜单点击等；载荷见 cj_on_shell_fn 的注释，首参为宿主句柄）。 */
CJ_BRIDGE_API void cj_bridge_set_shell_callback(cj_host *h, cj_on_shell_fn cb);

/* 宿主能力位（CJ_CAP_* 的按位或）：cj_plat_init 时填好，供仓颉侧 HostCapabilities /
   `system:host` 如实上报。未 init 返回 0。 */
CJ_BRIDGE_API int cj_bridge_host_capabilities(cj_host *h);

/* 句柄同一性判定（返回 1 = 同一个宿主，任一方为 NULL 返回 0）。
   为什么要有它：shell 事件回调首参是**发生事件的宿主句柄**，仓颉侧得判断「是不是我这个窗口」，
   但仓颉的 `CPointer<Unit>` 不支持 `==`（实测编译器直接报 invalid binary operator），
   也没有可靠的指针→整数转换。句柄本来就归 core 所有，判定交回 C 侧最省事、也最不会猜错。
   纯 core 函数：不需要任何平台原语。 */
CJ_BRIDGE_API int cj_bridge_host_eq(cj_host *a, cj_host *b);

/* =========================================================================
 *  串口（plugin_serial）：设备 I/O，与宿主 / 窗口无关
 *
 *  这几个导出**不带 cj_host**：串口不是宿主能力，也不该强迫应用先建窗口才能用。
 *  配置在仓颉侧已解析成数值，C 侧只认数值（字符串解析归仓颉，便于单测）。
 * ========================================================================= */

/* 打开并配置串口：成功返回 >0 句柄；失败返回负码（-1 参数/白名单、-2 句柄表满、
   -3 平台打不开）。path 必须先过 cj_serial_path_allowed——**这是安全边界**。
   打开是非阻塞的（O_NOCTTY | O_NONBLOCK + 裸 termios），不会为了等载波信号钉住调用线程。 */
CJ_BRIDGE_API long long cj_bridge_serial_open(const char *path, int baud, int data_bits,
                                              int parity, int stop_bits);

/* 读：最多 len 字节，最多等 timeout_ms 毫秒（0 = 立即返回，负值按 0 处理）。
   返回读到的字节数（0 = 超时无数据，不是错误）；<0 失败。缓冲由调用方提供。 */
CJ_BRIDGE_API int cj_bridge_serial_read(long long h, unsigned char *buf, int len, int timeout_ms);

/* 写：在 timeout_ms 预算内尽量写完；返回实际写入字节数（可能小于 len），<0 失败。 */
CJ_BRIDGE_API int cj_bridge_serial_write(long long h, const unsigned char *buf, int len,
                                         int timeout_ms);

/* 关闭并释放句柄（幂等：重复关同一句柄返回 -4）。 */
CJ_BRIDGE_API int cj_bridge_serial_close(long long h);

/* 枚举本机串口（serial:list 的平台层）：把「COM + 全数字」一行一个写进 out，
   返回条数（0 = 没有串口，不是错误）。平台不实现时返回 -4（err 口径同其余原语）。
   out_len 是 out 的容量；放不下时截断到已写入的整行。 */
CJ_BRIDGE_API int cj_bridge_serial_list(char *out, int out_len);

/* 最近一次失败的明细（UTF-8，**线程局部**——命令各自跑在 worker 线程上，静态单槽会被互相覆盖）。
   每次串口导出调用都会先清空它，失败时写入；返回的指针在该线程下次调用前有效。 */
CJ_BRIDGE_API const char *cj_bridge_serial_last_error(void);

/* =========================================================================
 *  剪贴板（plugin_clipboard）：宿主能力——GTK 的 clipboard 依赖 gtk_init 后的环境，
 *  且 GTK 规定剪贴板调用必须在 GTK 线程上，所以**带 cj_host**（借它的 UI 线程分流），
 *  与对话框同一套「已在 UI 线程就直接做、否则投递 + 有界等待」的样板。
 *  返回码口径：0 = 成功，-1 = 参数非法，-3 = 宿主未就绪 / 平台失败，-4 = 本平台未实现。
 * ========================================================================= */

/* 写文本：text 须为合法 UTF-8，长度上限 8 MB（core 校验）。0 = 成功。 */
CJ_BRIDGE_API int cj_bridge_clipboard_write_text(cj_host *h, const char *text);

/* 读文本：返回 malloc 的 UTF-8 字符串（可能为 NULL = 剪贴板为空 / 不是文本）。
   用 cj_bridge_clipboard_free 释放，**不许**在仓颉侧 free。 */
CJ_BRIDGE_API char *cj_bridge_clipboard_read_text(cj_host *h);

/* 释放 read_text 返回的缓冲（NULL 安全，幂等）。 */
CJ_BRIDGE_API void cj_bridge_clipboard_free(char *s);

/* 平台原语：真正的剪贴板读写。err 口径同其余原语（-4 未实现由平台自己报）。 */
int cj_plat_clipboard_write_text(cj_host *h, const char *text, char *err, int err_len);
char *cj_plat_clipboard_read_text(cj_host *h, char *err, int err_len);

/* =========================================================================
 *  系统通知（plugin_notification）：与剪贴板同一类宿主能力，但**发后即忘**——
 *  通知提交后显示与否不回传（freedesktop 协议本就不给同步回执），core 校验 + 投
 *  UI 线程即返回，成败只在 stderr 留行。返回码：0 = 已提交，-1 = 参数非法，
 *  -3 = 宿主未就绪 / 平台失败，-4 = 本平台未实现。
 * ========================================================================= */

/* 发一条通知：title 非空且 ≤256 字节，body ≤8 KiB（core 校验）。0 = 已提交。 */
CJ_BRIDGE_API int cj_bridge_notification_notify(cj_host *h, const char *title, const char *body);

/* 平台原语：真正发通知（UI 线程调用）。 */
int cj_plat_notification_notify(cj_host *h, const char *title, const char *body,
                                char *err, int err_len);

/* =========================================================================
 *  日志落盘（RFC-003 第 5 期）：把 stderr 接管到文件，给「没有控制台」的产物留凭证
 *
 *  为什么在 fd 层接管：单文件产物是 Windows GUI 子系统，双击时 stderr 无处可去；
 *  而诊断输出分布在 core、平台实现与仓颉侧上百处。解 `freopen` 一次，**所有** stderr
 *  写者自动落进同一个 FILE*（顺序天然一致），两端调用点一处都不用改。stdout 一律不碰
 *  （`CJ_TAURI_MANIFEST` 的插件清单走 stdout）。
 * ========================================================================= */

/* 开启日志落盘：path 非空且可写时返回 1，否则返回 0 并在**还在的** stderr 上说明原因。
   max_kb ≤ 0 表示不轮转（交给外部 logrotate）；keep = 保留几份档案（log.1 … log.keep），
   ≤0 表示轮转时直接丢弃旧内容。**只能在第一条日志之前调**——已开启后重复调用返回 0
   （stderr 已经被接管，换不了目标；想换就重启应用换参数）。 */
CJ_BRIDGE_API int cj_bridge_set_log_file(const char *path, int max_kb, int keep);

/* 回读生效中的日志路径；未开启返回空串。供 system:host 如实上报。 */
CJ_BRIDGE_API const char *cj_bridge_log_file(void);

/* 追加一行调用方提供的日志（同样走轮转；用于 log 插件把前端报错并进同一份文件）。
   返回 0 = 已写入（或未开启但已落 stderr），-1 = 参数非法。 */
CJ_BRIDGE_API int cj_bridge_log_write(const char *line);

/* core 内的诊断输出统一走它：**未开启落盘时逐字节等同 `fprintf(stderr, …)`**
   （现有 E2E needle 与 `[cj-bridge]` 前缀断言因此一条都不受影响）；开启后才加
   `[YYYY-MM-DD HH:MM:SS] ` 前缀并按大小轮转。 */
void cj_core_logf(const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 1, 2)))
#endif
    ;
#define cj_logf(...) cj_core_logf(__VA_ARGS__)

/* =========================================================================
 *  静默子进程：后台启动控制台程序，与宿主 / 窗口无关（不带 cj_host）
 *
 *  为什么必须下沉到 C 桥：cj-tauri 应用都是 GUI 子系统（Windows 的 `--subsystem=windows`），
 *  父进程**没有控制台**；此时拉起一个控制台子系统的子进程，Windows 会给它**单独配一个控制台
 *  窗口**——用户看到的就是一个黑窗口。仓颉的 `std.process.launch` 没有创建标志可传，
 *  所以这条只能在桥里做：Windows 走 `CreateProcessW` + `DETACHED_PROCESS`（连隐藏 console 都不建），
 *  Linux 走 `fork` + `execv` + `setsid`（脱开终端，Ctrl-C 不连带打死）。
 *
 *  三个导出两平台同名同签名（AGENTS §2）：上层因此没有平台分叉的调用点。
 * ========================================================================= */

/* 静默启动：exe 是程序路径（UTF-8），args 是参数串（UTF-8，**以 0x1F 分隔**，空串 = 无参数）。
   引号 / 空格由平台按各自规则转义，调用方**不要**自己加引号。
   返回 pid（> 0）；失败返回 0，原因由平台写进 stderr（core 会再补一行带 exe 的上下文）。 */
CJ_BRIDGE_API long long cj_bridge_spawn_hidden(const char *exe, const char *args);

/* 终止该 pid（幂等：进程已经不在了也返回 1）。返回 1 = 已结束，0 = 无权 / 失败。 */
CJ_BRIDGE_API int cj_bridge_kill_pid(long long pid);

/* 该 pid 是否还活着：1 = 活着，0 = 已退出或查不到（**含没权限查**——按「不在」上报，
   比谎报活着好：调用方据它决定要不要重新拉起）。 */
CJ_BRIDGE_API int cj_bridge_pid_alive(long long pid);

/* 把产物内嵌的资源释放到 dir（单文件包用：scripts/pack-win-single.sh 把随包的程序与依赖 DLL
   作为 RT_RCDATA 资源嵌进 exe，资源名就是文件名）。
   返回值：> 0 = 已就绪的文件数（本次释放的 + 本来就在的），0 = **产物里没有内嵌资源**
   （普通构建、非单文件包都是这个），-1 = 参数为空或写盘失败（原因在 stderr）。
   幂等：目标文件已存在且大小与资源一致就跳过——每次启动调它不会重写一份几十 MB 的资源。
   目录由调用方给（桥不认识应用名）：典型是 %LOCALAPPDATA%\应用名\runtime。 */
CJ_BRIDGE_API int cj_bridge_extract_assets(const char *dir);

/* 平台原语（err 口径同其余原语：写不进就留空，core 会打「平台没有给出原因」）。
   没有内嵌资源机制的平台如实返回 0，不假装成功。 */
long long cj_plat_spawn_hidden(const char *exe, const char *args, char *err, int err_len);
int cj_plat_kill_pid(long long pid);
int cj_plat_pid_alive(long long pid);
int cj_plat_extract_assets(const char *dir, char *err, int err_len);

#endif /* CJ_BRIDGE_CORE_H */
