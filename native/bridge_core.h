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

/* 前端 __CJ_TAURI__.reload() 的控制消息：宿主级操作，不进 IPC hub
   （与 native/bridge_js.h 里的字面量必须一致） */
#define CJT_RELOAD_MSG "__cj_tauri_reload__"

/* 单批上限：一次 UI 空闲窗口最多合并多少条回投。写成常量而不是「取空为止」，
   是为了长队列也肯让出 UI 线程（剩下的由自续唤醒接手）。 */
#define CJ_JS_BATCH_MAX 64

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

    /* --- 生命周期 --- */
    volatile int ready;       /* 宿主 UI 就绪（平台在窗口 + WebView 建好后置 1）*/
    volatile int should_quit; /* 事件循环已退出 / 要求退出（平台在启动失败等路径可直接置 1）*/
    int window_gone;          /* 窗口已销毁、原生资源已释放；句柄壳仍可安全调用 destroy */
    int destroy_notified;     /* onDestroy 是否已触发（quit 与关窗只通知一次）*/

    /* --- 平台私有（GTK 窗口/view；HWND + COM 接口 + 宿主线程 id）--- */
    void *plat;
} cj_host;

/* =========================================================================
 *  平台原语清单（每个平台实现一份，共 18 个）
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
/* 释放宿主级平台资源（COM 环境引用 / 模块句柄），幂等。
   返回 1＝状态已释放、句柄可以回收；0＝宿主线程可能还在收尾（它会进入仓颉运行时，
   阻塞式 join 会与运行时的线程退出握手互等），调用方须保留句柄与状态，不要 free。 */
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

/* =========================================================================
 *  core 提供给平台的状态迁移（平台的事件循环里调用）
 * ========================================================================= */
void cj_core_set_ready(cj_host *h);       /* 窗口 + WebView 就绪（平台在装配完成后调）*/
void cj_core_flush_js(cj_host *h);        /* UI 线程：取队列拼批回投（idle / WM_CJT_FLUSH 里调）*/
void cj_core_dialog_tick(cj_host *h, dlg_req *req); /* UI 线程：弹对话框 → 回调 → 唤醒等待方 */
void cj_core_dialog_abort(cj_host *h);    /* 作废进行中的对话框并唤醒等待方（ok=0，幂等）*/
void cj_core_window_destroyed(cj_host *h);/* 窗口销毁：置标志 + 通知 onDestroy（一次）+ 作废对话框 */

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

#endif /* CJ_BRIDGE_CORE_H */
