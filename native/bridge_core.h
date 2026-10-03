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
typedef void (*cj_on_destroy_fn)(void);             /* 窗口销毁 / 退出（每个宿主恰好一次）*/
typedef void (*cj_on_dialog_fn)(const char *path);  /* 原生对话框选中的路径（取消 = 空串）*/

/* 前向声明：下面的 shell 回调签名要用到宿主句柄，而 cj_host 结构体还在后面才定义。
   必须是**文件作用域**的前向声明——只在参数列表里写 struct cj_host，clang 会把它当成
   「仅本原型内可见」的另一个类型（-Wvisibility），赋函数指针时就报类型不兼容。 */
struct cj_host;

/* 宿主级 shell 事件回调：**菜单 / 托盘 / 拖放共用一个入口**（RFC-002 §5.5），
   第一个参数回传宿主句柄，第二个是 JSON 载荷（与 on_message 同一载体，仓颉侧已有 JSON 解析）。

       {"kind":"menu","id":"file.save","enabled":true,"checked":false}
       {"kind":"tray","id":"toggle"}                     ← 7.C
       {"kind":"drop","paths":["C:\\a.png"]}             ← 7.C

   **为什么首参必须是宿主**：仓颉的 @C 函数是模块级函数，每个宿主注册的是同一个函数指针，
   不把 h 传回去就分不清是哪个窗口点的——这正是多窗口把静态单槽回调逼出来的那个坑
   （docs/架构演进-多平台与多窗口.md §7.5）的根治办法。**新增回调一律照此带宿主身份**；
   老的 cj_on_destroy / cj_on_dialog 无此参数，属已知真缺口，留待一起改。

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

/* ===== 回投队列节点（core 拥有；UTF-8 存储，宽字符转换由平台在 cj_plat_post_js 里做）===== */
typedef struct js_node {
    char *js;
    struct js_node *next;
} js_node;

/* ===== 原生对话框请求（core 分配 / 释放；平台只填 ok 与 path）===== */
typedef struct dlg_req {
    int kind;      /* 0 打开文件 1 保存文件 2 info 3 warning 4 error 5 confirm */
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

    /* --- 窗口配置：由仓颉侧在 cj_bridge_start 之前经 cj_bridge_set_window 注入 --- */
    char *win_title;
    int win_w;
    int win_h;
    char *win_icon;  /* NULL = 系统默认图标 */
    int devtools;    /* 开发者工具开关 */

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
 *  平台原语清单（每个平台实现一份，共 21 个）
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
int  cj_plat_run_dialog(cj_host *h, dlg_req *req);         /* UI 线程直接弹原生对话框，写 req */
void cj_plat_open_devtools(cj_host *h);
void cj_plat_load_url(cj_host *h, const char *url);
void cj_plat_reload(cj_host *h);

/* ---- 菜单 / 能力位（RFC-002；7.A 只做菜单栏，托盘 / 拖放在 7.B / 7.C）----
   wire 是 `MenuModel.toWire()` 的线路文本（格式见 cj_core_menu_walk 的注释），空串 = 清空菜单栏。
   调用时机两头都要支持：**未就绪**时只记下（平台建窗时读 h->pending_menu_text）；**已就绪**时由平台
   投到 UI 线程重建菜单。cj_plat_menu_item_state 只改运行期状态（可用 / 勾选），要快、可能频繁。 */
void cj_plat_set_menu(cj_host *h, const char *wire);
void cj_plat_menu_item_state(cj_host *h, const char *id, int enabled, int checked);

/* 宿主能力位（CJ_CAP_* 的按位或）：纯静态事实，cj_plat_init 里由平台给出。 */
int cj_plat_host_capabilities(cj_host *h);

/* =========================================================================
 *  core 提供给平台的状态迁移（平台的事件循环里调用）
 * ========================================================================= */
void cj_core_set_ready(cj_host *h);       /* 窗口 + WebView 就绪（平台在装配完成后调）*/
void cj_core_flush_js(cj_host *h);        /* UI 线程：取队列拼批回投（idle / WM_CJT_FLUSH 里调）*/
void cj_core_dialog_tick(cj_host *h, dlg_req *req); /* UI 线程：弹对话框 → 回调 → 唤醒等待方 */
void cj_core_dialog_abort(cj_host *h);    /* 作废进行中的对话框并唤醒等待方（ok=0，幂等）*/
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

#endif /* CJ_BRIDGE_CORE_H */
