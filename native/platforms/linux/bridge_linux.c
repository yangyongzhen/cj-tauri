/*
 * cj-tauri C 桥（Linux 平台层）：GTK / WebKitGTK 宿主原语
 *
 * 本文件只实现 bridge_core.h 的「平台原语清单」+ 宿主线程装配；平台无关逻辑
 * （IPC 回投队列与批处理、对话框单槽状态机、窗口配置存储、生命周期标志、全部导出）
 * 都在 native/bridge_core.c，两平台共用。分层原因见 docs/架构演进-多平台与多窗口.md §2.2。
 *
 * 背景（关键）：仓颉 cjnative 的 main 运行在 M:N 轻量级线程的堆上协程栈，
 * JSC 的 sanitizeStackForVM 用 pthread 栈边界校验 SP 会失败并 abort。
 * 因此 GTK/WebKit 全部调用必须留在本文件创建的原生 pthread（标准 8MB 栈）内，
 * 仓颉侧经 FFI 与本桥交互，消息回调经 CFunc 回到仓颉。
 *
 * 编译（见 native/build_linux.sh）：
 *   gcc -shared -fPIC -fstack-protector-all bridge_core.c bridge_linux.c \
 *       -o libcjtbridge.so $(pkg-config --cflags --libs webkit2gtk-4.1)
 */
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
/* 串口（plugin_serial）：termios 配置 + 超时读写 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
/* posix_spawn 要用进程环境指针：glibc 的 unistd.h 只在 _GNU_SOURCE 下暴露 environ，
   共享库构建没定义它——按 POSIX 显式声明（标准符号，不带 _GNU_SOURCE 也合法） */
extern char **environ;
#include <sys/types.h>
#include <termios.h>
#include <time.h>
#include "bridge_core.h"
#ifdef CJ_HAVE_X11
#include <X11/Xlib.h>
#endif
#ifdef CJ_HAVE_TRAY
#include <libayatana-appindicator/app-indicator.h>
#endif

/* ===== 菜单栏（RFC-002 §5.4 / §5.5）=====
   core 把线路文本交下来，本文件翻译成 GTK 菜单栏。菜单栏是**每窗口**资源（GtkMenuBar 挂在
   窗口里那层 GtkBox 上），建 / 换 / 改都必须在 GTK 线程上做——跨线程一律 g_idle_add 投过去。 */
#define CJ_MENU_MAX_ITEMS 64
#define CJ_MENU_MAX_DEPTH 8

typedef struct menu_item_ctx {
    cj_host *h;
    char *app_id;      /* 应用给的稳定 id：菜单项被激活时回投仓颉侧 */
    char kind;         /* 'n' 普通 / 'c' 勾选（勾选项靠 toggled 信号回投）*/
    int enabled;
    int checked;
    int suppress;      /* 程序化改勾选时置 1：把随之而来的 toggled 当噪声挡掉 */
} menu_item_ctx;

typedef struct menu_slot {
    char *app_id;         /* 与 menu_item_ctx 各存一份：槽会被重建复用，ctx 随 widget 存亡 */
    GtkWidget *widget;    /* 对应的 GtkMenuItem / GtkCheckMenuItem */
    menu_item_ctx *ctx;   /* 该 widget 的信号回调上下文（改状态要动它的 suppress）*/
    char kind;
    int enabled;
    int checked;
} menu_slot;

/* ===== 同窗内嵌视图（PLT-006 真标签页）=====
   一个宿主装多个 WebKitWebView：主视图与各视图都摆在同一个 GtkFixed 里（按客户区像素
   定位），切换 tab 就是 gtk_widget_show / hide 换谁露出来。

   线程纪律与 Windows 侧同形但更硬：**GTK 只在宿主自己的原生 pthread 上调**（仓颉轻量线程
   的堆上协程栈会被 JSC 的栈边界校验 abort，见 AGENTS §4），所以 worker 线程进来一律
   g_idle_add 把意图投到 GTK 线程，与 set_owner_window 走同一条路。 */
#define CJ_VIEW_MAX 8

typedef struct view_slot {
    long long id;         /* 0 = 空位 */
    GtkWidget *webview;   /* 这个视图自己的 WebKitWebView */
    int visible;
    int x, y, w, h;       /* 客户区坐标（与页面 getBoundingClientRect 同量纲）*/
    char *pending_url;    /* UTF-8 待导航地址 */
} view_slot;

typedef struct view_op {
    cj_host *h;
    int opcode;
    long long id;
    int x, y, w, hgt;
    int flag;   /* CJ_VIEW_OP_VISIBLE：1 显示 / 0 隐藏 */
    char *url;
} view_op;

#define CJ_VIEW_OP_CREATE 1
#define CJ_VIEW_OP_VISIBLE 2
#define CJ_VIEW_OP_BOUNDS 3
#define CJ_VIEW_OP_NAVIGATE 4
#define CJ_VIEW_OP_DESTROY 5

/* ===== 每个宿主的平台私有状态 =====
   原先是一堆进程级单例（g_window / g_view / g_gtk_thread …）：多窗口一落地就互相覆盖，
   而且「哪个窗口」这件事在 ABI 上根本传不进来。现在挂在自己的 cj_host->plat 上，
   平台函数一律从入参句柄取状态——平台原语只认句柄，不看全局。 */
typedef struct plat_host {
    GtkWidget *window;  /* 主窗口；窗口销毁时置空（含用户关窗路径）*/
    GtkWidget *view;    /* WebKitWebView；宿主线程收尾时 unref 并置空 */
    /* --- 菜单栏（只在 GTK 线程上建 / 换 / 改）--- */
    GtkWidget *box;      /* window 里那层竖向 GtkBox：装顶行（菜单栏 + 副标题）+ view */
    GtkWidget *topbar;   /* 顶部那一行水平 GtkBox：菜单栏靠左、副标题靠右 */
    GtkWidget *subtitle; /* 副标题 label；文本空串即隐藏（不留一条空行）*/
    GtkWidget *menubar;  /* 当前菜单栏；NULL = 没有（空菜单栏不留空条）*/
    menu_slot menu_items[CJ_MENU_MAX_ITEMS];
    int menu_item_count;
    pthread_t thread;   /* 跑 gtk_main 的原生线程（对话框判断「调用方是否已在 GTK 线程」用）*/
    int thread_started;
    int thread_set;
    volatile int thread_done; /* 宿主线程跑完（收尾最后一步）：只有它为 1 才敢 free 这个结构，
                                 见 cj_plat_fini 里「为什么不 join」的注释 */
    /* --- 全局快捷键（CJ_HAVE_X11 编译期开关；grab 线程独占自己的 X 连接，
            命令经 hk_cmd 投递、触发事件经 hk_evt 回 GTK 线程——Xlib 的多线程安全不想赌，
            单线程拥有一切 X 资源；仓颉回调仍只发生在 GTK 线程，与菜单/拖放同一纪律）--- */
    int hk_cmd[2];      /* [0] 读端（grab 线程 poll）[1] 写端（cj_plat_set_global_hotkeys 发 'R'/'Q'）*/
    int hk_evt[2];      /* [0] 读端（GTK 线程 50ms 轮询）[1] 写端（grab 线程写触发 id 行）*/
    pthread_t hk_thread;
    int hk_thread_started;
    int hk_boot;          /* grab 线程是否已起（懒启动：首次 set_global_hotkeys 才建线程与管道）*/
    guint hk_evt_src;     /* GTK 侧事件轮询的 source id（收尾时 g_source_remove）*/
    volatile int hk_quit; /* 收尾旗标：grab 线程见到即退出 */
    volatile int hk_done; /* grab 线程跑完（fini 回收状态的另一半条件）*/
    /* --- 窗口可见性 / 最小化到托盘（RFC-003 第 5 期余项）--- */
    int min_to_tray_warned; /* 「托盘没挂上，最小化降级」只出声一次（重新设策略时复位）*/
    /* --- 附庸窗：跨线程改属主时先记下，由 GTK 线程的 idle 回调取用 --- */
    cj_host *pending_owner;
    /* --- 同窗内嵌视图（PLT-006）：GtkOverlay 让主视图填满，GtkFixed 在其上按坐标摆视图 --- */
    GtkWidget *stack;     /* GtkOverlay：第一个 child 是主视图（自动填满）*/
    GtkWidget *fixed;     /* GtkFixed：内嵌视图的容器，坐标 = 页面 client 矩形 */
    view_slot views[CJ_VIEW_MAX];
    long long view_seq;   /* 句柄发号：命令 worker 线程会调，必须原子（__sync_add_and_fetch）*/
#ifdef CJ_HAVE_TRAY
    AppIndicator *tray;   /* 当前托盘；NULL = 没有。GTK 线程专属，重建 = 释放旧的再建 */
#endif
} plat_host;

/* 主视图的尺寸交给 GtkOverlay 管（第一个 child 自动填满），不再手工同步：
   若把主视图也放进 GtkFixed，就得在 size-allocate 里反向设置它的 request，
   等于在分配期改布局——退回两层（overlay 填满 + fixed 覆盖其上）可以完全避开这条。 */

/* ===== 同步原语（core 只用这些，绝不直接碰 pthread）===== */

struct cj_sync {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
};

cj_sync *cj_plat_sync_create(void) {
    cj_sync *s = (cj_sync *)calloc(1, sizeof(cj_sync));
    if (!s) return NULL;
    if (pthread_mutex_init(&s->mutex, NULL) != 0) {
        free(s);
        return NULL;
    }
    if (pthread_cond_init(&s->cond, NULL) != 0) {
        pthread_mutex_destroy(&s->mutex);
        free(s);
        return NULL;
    }
    return s;
}

void cj_plat_sync_destroy(cj_sync *s) {
    if (!s) return;
    pthread_cond_destroy(&s->cond);
    pthread_mutex_destroy(&s->mutex);
    free(s);
}

void cj_plat_sync_lock(cj_sync *s) {
    if (s) pthread_mutex_lock(&s->mutex);
}

void cj_plat_sync_unlock(cj_sync *s) {
    if (s) pthread_mutex_unlock(&s->mutex);
}

void cj_plat_sync_wait(cj_sync *s, int *ready) {
    if (!s || !ready) return;
    while (!*ready) {
        pthread_cond_wait(&s->cond, &s->mutex);
    }
}

void cj_plat_sync_signal(cj_sync *s) {
    if (s) pthread_cond_signal(&s->cond);
}

/* ===== 投递到 GTK 线程的小工具 ===== */

/* 带一个字符串参数的投递（URL 需要，且参数所有权要跟着走） */
typedef struct ui_call {
    cj_host *h;
    char *arg;
} ui_call;

static gboolean open_devtools_idle(gpointer d) {
    cj_host *h = (cj_host *)d;
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (p && p->view) {
        WebKitWebInspector *insp = webkit_web_view_get_inspector(WEBKIT_WEB_VIEW(p->view));
        if (insp) {
            webkit_web_inspector_show(insp);
        }
    }
    return G_SOURCE_REMOVE;
}

static gboolean load_url_idle(gpointer d) {
    ui_call *c = (ui_call *)d;
    plat_host *p = (c && c->h) ? (plat_host *)c->h->plat : NULL;
    if (p && p->view && c->arg) {
        webkit_web_view_load_uri(WEBKIT_WEB_VIEW(p->view), c->arg);
    }
    if (c) {
        free(c->arg);
        free(c);
    }
    return G_SOURCE_REMOVE;
}

static gboolean reload_idle(gpointer d) {
    cj_host *h = (cj_host *)d;
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (p && p->view) {
        webkit_web_view_reload(WEBKIT_WEB_VIEW(p->view));
    }
    return G_SOURCE_REMOVE;
}

/* 退出：只收主循环，窗口交给 gtk_thread_main 的收尾去销毁（见那段收尾 + on_destroy 信号）。
   不能在空闲回调里 gtk_widget_destroy：实测「主循环内销毁 WebKit 窗口」会让 libwebkit2gtk 的
   退出期析构函数在 g_object_unref 里 abort——栈是 StartMainTask → exit → __run_exit_handlers
   → libwebkit2gtk * → g_object_unref → abort，退出码 134（6 轮里 5 轮），而主循环退出后再销毁
   同一份活儿照样干完，6 轮里干净退出（AB 对照）。onDestroy 仍由 destroy 信号触发一次，
   收尾里那次 cj_core_window_destroyed 只是幂等兜底；与 Windows 的 DestroyWindow → WM_DESTROY
   语义仍对齐：quit 一定触发一次 onDestroy。 */
static gboolean quit_idle(gpointer d) {
    (void)d; /* 窗口销毁已不在这里做，入参用不上了 */
    gtk_main_quit();
    return G_SOURCE_REMOVE;
}

/* 回投：UI 线程取队列拼批执行 */
static gboolean flush_idle(gpointer d) {
    cj_core_flush_js((cj_host *)d);
    return G_SOURCE_REMOVE;
}

/* ===== 宿主生命周期 ===== */

/* 菜单：实现集中在文件末尾；装配路径与 g_idle 回调都要用，先声明 */
static void menu_apply_wire(cj_host *h, plat_host *p, const char *wire);
static void menu_apply_item_state(plat_host *p, const char *id, int enabled, int checked);
static void menu_clear_slots(plat_host *p);
/* 菜单几何的「事后读回」（低优先级 idle 里读 GTK 的分配值）：建完菜单、以及每次用户点击之后
   各投一次，实机驱动脚本按它把鼠标点到项的中心——见函数定义处的注释 */
static void menu_post_layout(cj_host *h);
static void drag_dest_apply(cj_host *h, plat_host *p, int enabled, int files);
#ifdef CJ_HAVE_TRAY
static void tray_apply_wire(cj_host *h, plat_host *p, const char *wire);
static void tray_remove(plat_host *p);
#endif
/* 窗口可见性：装配点（建窗后按 h->win_visible 定稿）与运行期 g_idle 投递都要用，先声明 */
static void window_apply_visible(plat_host *p, int visible);
/* 附庸窗属主：同样两头都要用（装配期按 h->owner 定稿 / 运行期 g_idle 投递） */
static void window_apply_owner(plat_host *p, plat_host *owner_p);
/* 最小化到托盘的拦截点：建窗时挂 signal，定义在文件后段的平台原语区 */
static gboolean on_window_state(GtkWidget *w, GdkEventWindowState *ev, gpointer ud);

void cj_plat_init(cj_host *h) {
    plat_host *p;
    if (!h) return;
    p = (plat_host *)calloc(1, sizeof(plat_host));
    if (!p) {
        fprintf(stderr, "[cj-bridge] init failed: out of memory\n");
        return;
    }
    /* fd 0 是合法描述符（stdin）：管道字段 calloc 出来的 0 会被误当「已打开」，
       必须显式置 -1（「未创建」的约定值），首次 set_global_hotkeys 时才真正 pipe() */
    p->hk_cmd[0] = -1;
    p->hk_cmd[1] = -1;
    p->hk_evt[0] = -1;
    p->hk_evt[1] = -1;
    h->plat = p;
}

int cj_plat_fini(cj_host *h) {
    plat_host *p;
    if (!h) return 1;
    p = (plat_host *)h->plat;
    if (!p) return 1;
    /* 全局快捷键 grab 线程先收：置旗标 + 发 'Q'，有界等它退出（等不到照旧留着状态不阻塞，
       与宿主线程同一口径）。evt 轮询 source 挂在 GTK 主循环上，主循环已随窗口退出而结束，
       这里 remove 是幂等兜底（GSource 句柄已无效时 g_source_remove 只告警，故先判非 0）。 */
    if (p->hk_thread_started) {
        char q = 'Q';
        p->hk_quit = 1;
        if (p->hk_cmd[1] >= 0) {
            ssize_t w = write(p->hk_cmd[1], &q, 1);
            (void)w;
        }
        {
            int spin_hk = 0;
            while (!p->hk_done && spin_hk < 500) { /* 最多约 1s */
                usleep(2000);
                spin_hk++;
            }
        }
        if (p->hk_evt_src) {
            g_source_remove(p->hk_evt_src);
            p->hk_evt_src = 0;
        }
        pthread_detach(p->hk_thread);
        p->hk_thread_started = 0;
    }
    if (p->hk_cmd[0] >= 0) { close(p->hk_cmd[0]); close(p->hk_cmd[1]); p->hk_cmd[0] = p->hk_cmd[1] = -1; }
    if (p->hk_evt[0] >= 0) { close(p->hk_evt[0]); close(p->hk_evt[1]); p->hk_evt[0] = p->hk_evt[1] = -1; }
    /* 这里**不能 join**：宿主线程收尾时要进入仓颉运行时（窗口销毁回调 on_destroy），
       而在仓颉线程里阻塞 join 会与运行时的「停处理器」握手互等——实测约 1/6 概率整进程挂死，
       栈是 cj_plat_fini → pthread_join ↔ CJ_CJThreadMexit → CJ_ProcessorStopWithLastCheck。
       改成 detach + 让宿主线程自己立 thread_done 标记：跑完了才回收状态，没跑完就留着
       （进程随即退出；泄漏一次状态远比死锁安全，也与批次 1 之前的 detach 行为一致）。 */
    if (p->thread_started) {
        pthread_detach(p->thread);
        p->thread_started = 0;
    }
    /* 收尾顺序同样要命：窗口销毁是 GTK/WebKit 一整串多线程拆解，若它与仓颉运行时的收尾
       并发（run() 返回 → 运行时关停），实测几乎必然以 SIGABRT 收尾（`schd-worker` unhandled
       SIGABRT from runtime frame）。所以给宿主线程一个有界的等待窗口——纯 usleep 轮询标记，
       不碰 join（join 会与运行时握手互等，见上）；等不到也不阻塞进程退出，照旧留着状态。 */
    if (!p->thread_done) {
        int spin = 0;
        while (!p->thread_done && spin < 2000) { /* 最多约 2s */
            usleep(1000);
            spin++;
        }
    }
    if (!p->thread_done) {
        fprintf(stderr, "[cj-bridge] fini: host thread still running, platform state kept\n");
        return 0;
    }
    h->plat = NULL;
    free(p);
    return 1;
}

int cj_plat_is_ui_thread(cj_host *h) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || !p->thread_set) return 0;
    return pthread_equal(pthread_self(), p->thread) ? 1 : 0;
}

void cj_plat_wake_ui(cj_host *h) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    /* 窗口还没建好：消息留在 core 的队列里，等宿主就绪后的第一次投递带走 */
    if (!p || !p->view) return;
    g_idle_add(flush_idle, h);
}

/* ===== 平台原语：投递 / 运行时操作 ===== */

/* 回投结果校验：这条 eval 是「仓颉 → 前端」的唯一出口，静默失败会让前端 promise 永久 pending。
   Windows 侧有 log_hr("ExecuteScript", …) 兜同一件事（两平台对称）。 */
static void on_js_done(GObject *src, GAsyncResult *res, gpointer ud) {
    GError *err = NULL;
    WebKitJavascriptResult *r =
        webkit_web_view_run_javascript_finish(WEBKIT_WEB_VIEW(src), res, &err);
    if (r) {
        g_object_unref(r); /* 每次回投都会新建一个结果对象，不看也要释放 */
    }
    if (err) {
        fprintf(stderr, "[cj-bridge] run js failed: %s\n", err->message);
        g_error_free(err);
    }
}

void cj_plat_post_js(cj_host *h, const char *script_utf8) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || !p->view || !script_utf8) return;
    webkit_web_view_run_javascript(WEBKIT_WEB_VIEW(p->view), script_utf8, NULL, on_js_done, NULL);
}

void cj_plat_open_devtools(cj_host *h) {
    if (!h) return;
    g_idle_add(open_devtools_idle, h);
}

void cj_plat_load_url(cj_host *h, const char *url) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!h || !url || !url[0]) return;
    fprintf(stderr, "[cj-bridge] load url: %s\n", url);
    /* 已启动：投递到 GTK 线程切页面；未启动：pending_url 由宿主线程建窗后加载 */
    if (p && p->view) {
        ui_call *c = (ui_call *)calloc(1, sizeof(ui_call));
        if (!c) return;
        c->h = h;
        c->arg = strdup(url);
        if (!c->arg) {
            free(c);
            return;
        }
        g_idle_add(load_url_idle, c);
    }
}

void cj_plat_reload(cj_host *h) {
    if (!h) return;
    g_idle_add(reload_idle, h);
}

void cj_plat_quit(cj_host *h) {
    if (!h) return;
    g_idle_add(quit_idle, h);
}

/* ===== 原生对话框：这里只管「弹」，状态机（单槽/互斥/等待/作废）在 core ===== */

/* "描述|模式|描述|模式" → GTK 过滤器（与 Win32 OPENFILENAME 用同一套写法） */
static void apply_filter(GtkFileChooser *chooser, const char *filter) {
    char *buf, *seg;
    if (!filter || !filter[0]) {
        return;
    }
    buf = strdup(filter);
    if (!buf) {
        return;
    }
    seg = buf;
    while (seg && seg[0]) {
        char *pat = strchr(seg, '|');
        char *next = NULL;
        if (!pat) {
            break; /* 落单的描述段：忽略 */
        }
        *pat = 0;
        pat += 1;
        next = strchr(pat, '|');
        if (next) {
            *next = 0;
        }
        {
            GtkFileFilter *f = gtk_file_filter_new();
            char *p = pat;
            /* 一段里可以有多个空格分隔的 glob（如 "*.txt *.md"） */
            while (p && p[0]) {
                char *sp = strchr(p, ' ');
                if (sp) {
                    *sp = 0;
                }
                if (p[0]) {
                    gtk_file_filter_add_pattern(f, p);
                }
                p = sp ? sp + 1 : NULL;
            }
            gtk_file_filter_set_name(f, seg);
            gtk_file_chooser_add_filter(chooser, f);
        }
        seg = next ? next + 1 : NULL;
    }
    {
        GtkFileFilter *all = gtk_file_filter_new();
        gtk_file_filter_set_name(all, "所有文件");
        gtk_file_filter_add_pattern(all, "*");
        gtk_file_chooser_add_filter(chooser, all);
    }
    free(buf);
}

/* 已经站在 GTK 线程上：直接弹一次，返回 1 = 确认；选中路径写入 *out_path（由调用方 free） */
static int show_dialog_here(GtkWidget *parent_w, int kind, const char *title, const char *message,
                            const char *filter, char **out_path) {
    GtkWindow *parent = parent_w ? GTK_WINDOW(parent_w) : NULL;
    int ok = 0;

    *out_path = NULL;
    if (kind == 6) {
        /* 选目录：GET 不到「选目录」的 GTK 动作之外别无他法（kind 6 与文件类 / 消息类并列，
           见 bridge_core.h 的 dlg_req）。这里不设 filter：目录没有过滤语义。 */
        GtkWidget *dlg = gtk_file_chooser_dialog_new(
            title[0] ? title : "选择文件夹",
            parent,
            GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
            "取消", GTK_RESPONSE_CANCEL,
            "选择", GTK_RESPONSE_ACCEPT,
            NULL);
        if (gtk_dialog_run(GTK_DIALOG(dlg)) == GTK_RESPONSE_ACCEPT) {
            char *p = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dlg));
            if (p) {
                *out_path = strdup(p);
                ok = 1;
                g_free(p);
            }
        }
        gtk_widget_destroy(dlg);
    } else if (kind <= 1) {
        GtkWidget *dlg = gtk_file_chooser_dialog_new(
            title[0] ? title : (kind == 1 ? "保存文件" : "打开文件"),
            parent,
            (kind == 1) ? GTK_FILE_CHOOSER_ACTION_SAVE : GTK_FILE_CHOOSER_ACTION_OPEN,
            "取消", GTK_RESPONSE_CANCEL,
            (kind == 1) ? "保存" : "打开", GTK_RESPONSE_ACCEPT,
            NULL);
        apply_filter(GTK_FILE_CHOOSER(dlg), filter);
        if (kind == 1) {
            gtk_file_chooser_set_do_overwrite_confirmation(GTK_FILE_CHOOSER(dlg), TRUE);
        }
        if (gtk_dialog_run(GTK_DIALOG(dlg)) == GTK_RESPONSE_ACCEPT) {
            char *p = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dlg));
            if (p) {
                *out_path = strdup(p);
                ok = 1;
                g_free(p);
            }
        }
        gtk_widget_destroy(dlg);
    } else {
        GtkMessageType type = GTK_MESSAGE_INFO;
        GtkWidget *dlg;
        int res;
        if (kind == 3) {
            type = GTK_MESSAGE_WARNING;
        } else if (kind == 4) {
            type = GTK_MESSAGE_ERROR;
        } else if (kind == 5) {
            type = GTK_MESSAGE_QUESTION;
        }
        /* 用 "%s" 占位：提示文案里带 % 也不会被当成格式串 */
        dlg = gtk_message_dialog_new(parent, GTK_DIALOG_MODAL, type,
                                     (kind == 5) ? GTK_BUTTONS_OK_CANCEL : GTK_BUTTONS_OK,
                                     "%s", message[0] ? message : " ");
        if (title[0]) {
            gtk_window_set_title(GTK_WINDOW(dlg), title);
        }
        res = gtk_dialog_run(GTK_DIALOG(dlg));
        ok = (kind == 5) ? (res == GTK_RESPONSE_OK) : 1;
        gtk_widget_destroy(dlg);
    }
    return ok;
}

int cj_plat_run_dialog(cj_host *h, dlg_req *req) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!req) return 0;
    req->ok = show_dialog_here(p ? p->window : NULL, req->kind, req->title, req->message,
                               req->filter, &req->path);
    return req->ok;
}

/* 别的线程投递进来的对话框请求：g_idle_add 只带一个参数，包一层带上句柄 */
typedef struct dialog_call {
    cj_host *h;
    dlg_req *req;
} dialog_call;

static gboolean dialog_idle(gpointer d) {
    dialog_call *c = (dialog_call *)d;
    if (c) {
        cj_core_dialog_tick(c->h, c->req);
        free(c);
    }
    return G_SOURCE_REMOVE;
}

void cj_plat_post_dialog(cj_host *h, dlg_req *req) {
    dialog_call *c = (dialog_call *)calloc(1, sizeof(dialog_call));
    if (!c) {
        /* 投不出去就别让调用方干等：作废请求并唤醒等待方 */
        fprintf(stderr, "[cj-bridge] dialog failed: out of memory\n");
        cj_core_dialog_abort(h);
        return;
    }
    c->h = h;
    c->req = req;
    g_idle_add(dialog_idle, c);
}

/* ===== GTK 线程 ===== */

static void on_load_changed(WebKitWebView *wv, WebKitLoadEvent ev, gpointer ud) {
    /* no-op */
}

static void on_script_message(WebKitUserContentManager *mgr,
                              WebKitJavascriptResult *result, gpointer ud) {
    cj_host *h = (cj_host *)ud;
    JSCValue *v = webkit_javascript_result_get_js_value(result);
    char *s = jsc_value_to_string(v);
    /* 前端 __CJ_TAURI__.reload()：宿主控制消息，不进 IPC hub */
    if (s && strcmp(s, CJT_RELOAD_MSG) == 0) {
        fprintf(stderr, "[cj-bridge] frontend requested reload\n");
        g_idle_add(reload_idle, h);
        g_free(s);
        return;
    }
    /* 入站日志：与 Windows 侧同一格式（bridge_win.c 的 js -> native (%d bytes)）。
       此前只有 Windows 打这行，端到端取证时两平台不对称（AGENTS.md §1 的交付凭证就看它）。 */
    fprintf(stderr, "[cj-bridge] js -> native (%d bytes)\n", (int)strlen(s ? s : ""));
    if (h && h->on_message) {
        h->on_message(s);
    }
    g_free(s);
}

static void on_destroy(GtkWidget *w, gpointer ud) {
    cj_host *h = (cj_host *)ud;
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (p && p->window == w) {
        p->window = NULL; /* 窗口已自毁：别在收尾里再碰它 */
        /* view 是窗口的子 widget（gtk_container_add 把浮动引用沉给容器）：父窗口销毁时子 widget
           一并销毁、容器那份引用也释放，指针随即失效。收尾要是再 unref 它，就是摸已释放内存——
           实测打出 g_object_unref: assertion 'G_IS_OBJECT (object)' failed。故一并置空。 */
        p->view = NULL;
    }
    /* 置 should_quit + 触发 onDestroy（每个宿主恰好一次）+ 作废进行中的对话框 */
    cj_core_window_destroyed(h);
    gtk_main_quit();
}

/* 注入前端桥接脚本：暴露 window.__CJ_TAURI__ */
/* 平台唯一差异行（其余 JS 见 native/bridge_js.h，两平台共用一份，防漂移）：
   post 通道 = webkit.messageHandlers；reload 控制消息同通道发字面量。 */
#define CJ_LIT(s) s
#define CJ_POST_STMT "    window.webkit.messageHandlers.cjtauri.postMessage(JSON.stringify(obj));"
#define CJ_RELOAD_STMT "      window.webkit.messageHandlers.cjtauri.postMessage('__cj_tauri_reload__');"
#include "bridge_js.h"

static const char *BRIDGE_JS = CJ_BRIDGE_JS(CJ_POST_STMT, CJ_RELOAD_STMT);

static void *gtk_thread_main(void *arg) {
    cj_host *h = (cj_host *)arg;
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    WebKitUserContentManager *mgr;
    int i;

    if (!p) return NULL;
    /* 先记下 GTK 线程身份：对话框要靠它判断「调用方是不是已经在本线程上」 */
    p->thread = pthread_self();
    p->thread_set = 1;
    gtk_init(NULL, NULL);

    p->window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(p->window), h->win_title ? h->win_title : "cj-tauri");
    gtk_window_set_default_size(GTK_WINDOW(p->window), h->win_w, h->win_h);
    /* 窗口图标：失败只意味着用系统默认图标，不阻断启动（GTK 的 err 要自己释放） */
    if (h->win_icon) {
        GError *icon_err = NULL;
        gboolean icon_ok =
            gtk_window_set_icon_from_file(GTK_WINDOW(p->window), h->win_icon, &icon_err);
        fprintf(stderr, "[cj-bridge] window icon: path=%s ok=%d%s%s\n",
                h->win_icon, icon_ok ? 1 : 0,
                icon_err ? " err=" : "", icon_err ? icon_err->message : "");
        if (icon_err) g_error_free(icon_err);
    }
    g_signal_connect(p->window, "destroy", G_CALLBACK(on_destroy), h);

    /* 注入时机与 Windows 侧对齐：那边是 AddScriptToExecuteOnDocumentCreated（页面脚本执行前）。
       这里原先用 AT_DOCUMENT_END，会让发行态单文件里的内联 <script type="module"> 抢在注入之前执行
       —— 前端在模块作用域 / onMounted 直接读 window.__CJ_TAURI__ 会拿到 undefined
       （开发态从 URL 加载、模块要现下载，反而掩盖了这个竞态）。所以必须 document-start。 */
    mgr = webkit_user_content_manager_new();
    webkit_user_content_manager_add_script(
        mgr,
        webkit_user_script_new(BRIDGE_JS,
                               WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                               WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
                               NULL, NULL));
    /* 预执行脚本按注册顺序追加在桥之后（同一 document-start 通道，脚本里可直接用 window.__CJ_TAURI__） */
    for (i = 0; i < h->init_script_count; i++) {
        webkit_user_content_manager_add_script(
            mgr,
            webkit_user_script_new(h->init_scripts[i],
                                   WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                                   WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
                                   NULL, NULL));
    }
    fprintf(stderr, "[cj-bridge] init scripts injected: %d\n", h->init_script_count);
    webkit_user_content_manager_register_script_message_handler(mgr, "cjtauri");
    g_signal_connect(mgr, "script-message-received::cjtauri",
                     G_CALLBACK(on_script_message), h);

    p->view = webkit_web_view_new_with_user_content_manager(mgr);
    {
        /* 开发者工具开关：settings 交由视图持有（单实例、随窗口存续，不再额外 unref） */
        WebKitSettings *settings = webkit_settings_new();
        webkit_settings_set_enable_developer_extras(settings, h->devtools ? TRUE : FALSE);
        webkit_web_view_set_settings(WEBKIT_WEB_VIEW(p->view), settings);
    }
    g_signal_connect(p->view, "load-changed", G_CALLBACK(on_load_changed), NULL);
    /* 装配：window 里套一层竖向 GtkBox，顶部再套一层水平 GtkBox（菜单栏 + 副标题）。
       固定套这几层而不是「有菜单才套」——少一种装配分支就少一类时序坑。顶行常驻但
       默认不显示：菜单栏是按需重建的、副标题是运行期高频改的，两者都有落点时整行才
       该出现，显隐统一由 topbar_sync_visible() 决定（no_show_all 挡掉 show_all 的蔓延）。 */
    p->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    p->topbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    p->subtitle = gtk_label_new(NULL);
    gtk_label_set_ellipsize(GTK_LABEL(p->subtitle), PANGO_ELLIPSIZE_END);
    gtk_label_set_single_line_mode(GTK_LABEL(p->subtitle), TRUE);
    gtk_widget_set_margin_start(p->subtitle, 8);
    gtk_widget_set_margin_end(p->subtitle, 12);
    gtk_box_pack_end(GTK_BOX(p->topbar), p->subtitle, FALSE, FALSE, 0);
    gtk_widget_set_no_show_all(p->topbar, TRUE);
    gtk_widget_set_no_show_all(p->subtitle, TRUE);
    gtk_box_pack_start(GTK_BOX(p->box), p->topbar, FALSE, FALSE, 0);
    /* 主视图与内嵌视图分两层（PLT-006）：GtkOverlay 的第一个 child 是主视图、自动填满，
       GtkFixed 叠在它上面按页面 client 矩形摆内嵌视图。切换 tab 就是 show/hide 换谁露出来。 */
    p->fixed = gtk_fixed_new();
    p->stack = gtk_overlay_new();
    gtk_container_add(GTK_CONTAINER(p->stack), p->view);
    gtk_widget_set_halign(p->fixed, GTK_ALIGN_FILL);
    gtk_widget_set_valign(p->fixed, GTK_ALIGN_FILL);
    gtk_overlay_add_overlay(GTK_OVERLAY(p->stack), p->fixed);
    gtk_box_pack_start(GTK_BOX(p->box), p->stack, TRUE, TRUE, 0);
    gtk_container_add(GTK_CONTAINER(p->window), p->box);
    /* 装配期就已经 set_menu 过：这时把菜单栏建出来（运行期再改的走 g_idle_add 到本线程）*/
    if (h->pending_menu_text && h->pending_menu_text[0]) {
        menu_apply_wire(h, p, h->pending_menu_text);
    }
    gtk_widget_show_all(p->window);
    /* 可见性定稿：装配期 setWindowVisible(false) 过的（h->win_visible == 0）建好就不显示
       （与拖放 / 托盘同一条「未就绪先记、建窗时读」的路）*/
    if (!h->win_visible) {
        window_apply_visible(p, 0);
    }
    /* 附庸窗属主：同样在装配期定稿（先显示再摘掉任务栏项，用户会看见闪一下）。
       属主窗尚未建好时 window_apply_owner 会打一行说明并跳过，运行期再设即可。 */
    if (h->owner) {
        window_apply_owner(p, (plat_host *)h->owner->plat);
    }
    /* 最小化到托盘：拦 GTK 的图标化（真拦不拦看托盘**是否真的挂上了**，见 on_window_state）*/
    g_signal_connect(p->window, "window-state-event", G_CALLBACK(on_window_state), h);
    /* 拖放策略：装配期已 set_drag_drop 过的（pending 字段非 0）这时挂 drag dest；
       运行期再改的走 cj_plat_set_drag_drop 投 UI 线程重挂。默认关（0=不注册），现有应用零改动 */
    if (h->pending_drop_enabled) {
        drag_dest_apply(h, p, h->pending_drop_enabled, h->pending_drop_files);
    }
#ifdef CJ_HAVE_TRAY
    /* 托盘：装配期已 set_tray 过的这时建出来（appindicator 不依赖窗口，但要在 GTK 线程） */
    if (h->pending_tray && h->pending_tray[0]) {
        tray_apply_wire(h, p, h->pending_tray);
    }
#endif
    /* 全局快捷键：应用在 run() 之前 set 时 cj_bridge_init 还没跑（plat 未分配），
       cj_plat_set_global_hotkeys 那会儿拿不到 plat 只能静默返回——托盘靠上面的装配点
       兜住了，快捷键同样在这里补延迟注册（grab 线程懒启动） */
    if (h->pending_hotkeys && h->pending_hotkeys[0]) {
        cj_plat_set_global_hotkeys(h, h->pending_hotkeys);
    }
    cj_core_set_ready(h);

    /* 页面来源：URL 优先（cj_bridge_load_url），否则内联 HTML（cj_bridge_start） */
    if (h->pending_url) {
        webkit_web_view_load_uri(WEBKIT_WEB_VIEW(p->view), h->pending_url);
    } else if (h->pending_html) {
        webkit_web_view_load_html(WEBKIT_WEB_VIEW(p->view), h->pending_html, NULL);
    }

    gtk_main();

    /* 主循环退出：收尾。用户关窗时窗口已自毁（on_destroy 里已置空），这里只收还活着的对象；
       一律置空，免得后续 quit_idle / cj_plat_fini 摸到已释放的 widget（此前悬垂指针的来源）。 */
    if (p->window) {
        /* 销毁必须留在主循环之外（quit_idle 只 gtk_main_quit）：主循环内销毁 WebKit 窗口会让
           libwebkit2gtk 的退出期析构函数 abort（退出码 134，见 quit_idle 上的注释）*/
        gtk_widget_destroy(p->window); /* 子 widget 随父销毁：容器持有的那份引用这时才释放 */
        p->window = NULL;
    }
    /* 我们从不额外持 view 的引用（那是容器的引用），所以这里没有可 unref 的东西：
       窗口一旦销毁，view 指针就已失效，只能置空。 */
    p->view = NULL;
    p->box = NULL;      /* 随窗口一起销毁了 */
    p->topbar = NULL;   /* 同上：顶行与副标题都是窗口的子 widget */
    p->subtitle = NULL;
    p->menubar = NULL;
    menu_clear_slots(p); /* 槽里的 app_id 是我们 malloc 的，跟平台状态一起收 */
#ifdef CJ_HAVE_TRAY
    tray_remove(p);      /* 托盘是应用级资源，不随窗口销毁：这里兜底摘除（幂等） */
#endif
    /* 兜底：非关窗路径退出主循环时也要通知一次（幂等，正常路径已触发过） */
    cj_core_window_destroyed(h);
    /* 最后一步才立这个标记：cj_plat_fini 见到它才 free 平台状态（此刻本线程已不再碰 p）*/
    p->thread_done = 1;
    return NULL;
}

void cj_plat_start(cj_host *h) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    pthread_t t;
    if (!p) {
        fprintf(stderr, "[cj-bridge] start failed: platform not initialized\n");
        if (h) h->should_quit = 1; /* 起不来就别让 run() 干等 */
        return;
    }
    if (pthread_create(&t, NULL, gtk_thread_main, h) != 0) {
        fprintf(stderr, "[cj-bridge] start failed: cannot create host thread\n");
        h->should_quit = 1;
        return;
    }
    /* 不再 detach：cj_plat_fini 需要 join 它，确认线程收尾完毕再释放平台状态 */
    p->thread = t;
    p->thread_started = 1;
}

/* ===== 菜单栏翻译层（RFC-002 §5.4）：线路文本 → GtkMenuBar =====
   格式解析不在这里重复实现：走 core 的 cj_core_menu_walk（两平台共用一份，桩平台已自检）。
   本层只做三件事：把行翻译成 GTK 控件、把「用户激活」经 core 回投、维护运行期改状态的槽。 */

static void menu_clear_slots(plat_host *p) {
    int i;
    if (!p) return;
    for (i = 0; i < p->menu_item_count; i++) {
        free(p->menu_items[i].app_id);
        p->menu_items[i].app_id = NULL;
        p->menu_items[i].widget = NULL;
        p->menu_items[i].ctx = NULL;
    }
    p->menu_item_count = 0;
}

/* 普通项：activate = 用户点选（没有勾选状态可报，checked 恒 0）*/
static void on_menu_item_activate(GtkMenuItem *item, gpointer data) {
    menu_item_ctx *c = (menu_item_ctx *)data;
    (void)item;
    if (!c || !c->h || c->suppress) return;
    /* 勾选项改状态会挪动菜单栏里的位置，所以每次点击后重投一次几何读回（见 menu_post_layout） */
    menu_post_layout(c->h);
    cj_core_menu_clicked(c->h, c->app_id ? c->app_id : "", c->enabled, c->checked);
}

/* 勾选项：toggled 在 active 变化之后发（含用户点击与程序化设置，后者被 suppress 挡掉）*/
static void on_menu_item_toggled(GtkCheckMenuItem *item, gpointer data) {
    menu_item_ctx *c = (menu_item_ctx *)data;
    if (!c || !c->h || c->suppress) return;
    c->checked = gtk_check_menu_item_get_active(item) ? 1 : 0;
    menu_post_layout(c->h); /* 同上：勾选指示器状态变了，重读一次几何 */
    cj_core_menu_clicked(c->h, c->app_id ? c->app_id : "", c->enabled, c->checked);
}

/* 菜单项随菜单栏销毁：ctx 归本次构建所有，在这里释放（槽里的那份 app_id 另算）*/
static void on_menu_item_destroy(GtkWidget *w, gpointer data) {
    menu_item_ctx *c = (menu_item_ctx *)data;
    (void)w;
    if (!c) return;
    free(c->app_id);
    free(c);
}

static void menu_apply_item_state(plat_host *p, const char *id, int enabled, int checked) {
    int i;
    if (!p || !id || !id[0]) return;
    for (i = 0; i < p->menu_item_count; i++) {
        menu_slot *s = &p->menu_items[i];
        if (!s->widget || !s->app_id || strcmp(s->app_id, id) != 0) continue;
        s->enabled = enabled ? 1 : 0;
        s->checked = checked ? 1 : 0;
        gtk_widget_set_sensitive(s->widget, s->enabled ? TRUE : FALSE);
        if (s->ctx) {
            s->ctx->enabled = s->enabled;
            s->ctx->checked = s->checked;
        }
        if (s->kind == 'c') {
            /* 程序化改勾选同样会发 toggled：置 suppress 把它挡掉，免得被当成一次用户点击 */
            if (s->ctx) s->ctx->suppress = 1;
            gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(s->widget),
                                           s->checked ? TRUE : FALSE);
            if (s->ctx) s->ctx->suppress = 0;
        }
        /* 同上：core 那句 `set menu item:` 只说明「我调过」，这里从 GTK 侧读回真正生效的值。
           两者不一致（例如 widget 已随菜单栏销毁）就说明这条改动没落到菜单上。 */
        fprintf(stderr, "[cj-bridge] menu item readback: id=%s sensitive=%d active=%d\n", s->app_id,
                gtk_widget_get_sensitive(s->widget) ? 1 : 0,
                (s->kind == 'c')
                    ? (gtk_check_menu_item_get_active(GTK_CHECK_MENU_ITEM(s->widget)) ? 1 : 0)
                    : 0);
        return;
    }
    fprintf(stderr, "[cj-bridge] menu item not found: %s\n", id);
}

/* 建菜单时的上下文：层级用一张 GtkMenu 栈表示（行按文档顺序来，深度只会 +1 或回退）*/
typedef struct menu_build_ctx {
    cj_host *h;
    plat_host *p;
    GtkWidget *menubar;
    GtkWidget *stack[CJ_MENU_MAX_DEPTH]; /* stack[d]：深度 d 的行往哪个 GtkMenu 里追加 */
    int ok[CJ_MENU_MAX_DEPTH];           /* 该层是否已有子菜单可挂（没有就退回上一层）*/
} menu_build_ctx;

static void menu_add_row(void *ctx, int depth, char kind, const char *id,
                         const char *label, int flags, const char *accel) {
    menu_build_ctx *c = (menu_build_ctx *)ctx;
    plat_host *p;
    GtkWidget *parent_menu;
    GtkWidget *item;
    menu_item_ctx *ic;
    menu_slot *slot;
    char *text;
    int enabled = (flags & 1) ? 1 : 0;
    int checked = (flags & 2) ? 1 : 0;

    if (!c || !c->p) return;
    p = c->p;
    if (depth < 0) depth = 0;
    if (depth >= CJ_MENU_MAX_DEPTH) depth = CJ_MENU_MAX_DEPTH - 1;
    parent_menu = (depth > 0 && c->ok[depth]) ? c->stack[depth] : c->menubar;

    if (kind == 's') { /* 分隔线：既没有命令 id，也没有文字 */
        gtk_menu_shell_append(GTK_MENU_SHELL(parent_menu), gtk_separator_menu_item_new());
        return;
    }
    /* 标签：accel 非空时接在文字后面（GTK3 的快捷键要走 accel_group，v1 只做提示文本；
       这里用空格而不是制表符——GTK 的标签不像 Win32 那样把 \t 之后的部分右对齐）*/
    {
        size_t n = strlen(label) + (accel[0] ? strlen(accel) + 2 : 0) + 1;
        text = (char *)malloc(n);
        if (!text) return;
        snprintf(text, n, "%s%s%s", label, accel[0] ? "  " : "", accel);
    }

    if (kind == 'm') { /* 子菜单：建出 GtkMenu 挂到子菜单项上，并让深一层的行知道往哪挂 */
        GtkWidget *submenu = gtk_menu_new();
        item = gtk_menu_item_new_with_label(text);
        free(text);
        gtk_menu_item_set_submenu(GTK_MENU_ITEM(item), submenu);
        gtk_widget_set_sensitive(item, enabled ? TRUE : FALSE);
        gtk_menu_shell_append(GTK_MENU_SHELL(parent_menu), item);
        if (depth + 1 < CJ_MENU_MAX_DEPTH) {
            c->stack[depth + 1] = submenu;
            c->ok[depth + 1] = 1;
        }
        return;
    }

    if (p->menu_item_count >= CJ_MENU_MAX_ITEMS) {
        fprintf(stderr, "[cj-bridge] menu: item limit reached, dropped: %s\n", id);
        free(text);
        return;
    }
    item = (kind == 'c') ? gtk_check_menu_item_new_with_label(text)
                         : gtk_menu_item_new_with_label(text);
    free(text);
    gtk_widget_set_sensitive(item, enabled ? TRUE : FALSE);
    if (kind == 'c') {
        gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(item), checked ? TRUE : FALSE);
    }
    ic = (menu_item_ctx *)calloc(1, sizeof(*ic));
    if (ic) {
        ic->h = c->h;
        ic->app_id = strdup(id);
        ic->kind = kind;
        ic->enabled = enabled;
        ic->checked = checked;
        if (kind == 'c') {
            g_signal_connect(item, "toggled", G_CALLBACK(on_menu_item_toggled), ic);
        } else {
            g_signal_connect(item, "activate", G_CALLBACK(on_menu_item_activate), ic);
        }
        g_signal_connect(item, "destroy", G_CALLBACK(on_menu_item_destroy), ic);
    } else {
        fprintf(stderr, "[cj-bridge] menu: out of memory for item ctx (%s)\n", id);
    }
    gtk_menu_shell_append(GTK_MENU_SHELL(parent_menu), item);

    slot = &p->menu_items[p->menu_item_count++];
    free(slot->app_id); /* 槽是复用的，清掉上一轮残留 */
    slot->app_id = strdup(id);
    slot->widget = item;
    slot->ctx = ic;
    slot->kind = kind;
    slot->enabled = enabled;
    slot->checked = checked;
}

/* ===== 菜单几何的事后读回（实机驱动用） =====
   为什么需要：鼠标驱动的探针要把点击落在「项的几何中心」，而**像素偏移是写不住的**——
   窗口位置每轮都可能不同（实测同一份脚本两轮：一轮窗口在 0,0，一轮在 60,83），
   写死 +45/+135 这类偏移会点到隔壁项（菜单轮实机第一版就是这么点歪的）。
   所以让 GTK 自己说：id=x+w+h，按菜单栏顺序打一行；分隔线与子菜单项没有应用 id，打 '-'。
   为什么走**低优先级** idle：刚 pack 上去那一刻还没走完分配，读到的可能是 0；排到低优先级
   就等于「当前待处理的事件与重绘先做完」，这时拿到的才是最终值。每次用户点击后再投一次，
   这样驱动脚本每次点击前都能从日志里取到**最新**几何（勾选指示器一类的状态变化会挪位置）。 */
typedef struct menu_layout_idle {
    cj_host *h;
} menu_layout_idle;

static gboolean menu_layout_idle_cb(gpointer data) {
    menu_layout_idle *m = (menu_layout_idle *)data;
    GString *s;
    if (!m) return G_SOURCE_REMOVE;
    s = g_string_new(NULL);
    if (m->h) {
        plat_host *p = (plat_host *)m->h->plat;
        /* 窗口可能已经销毁（销毁后 p->menubar 为 NULL）：这里不再碰 GTK */
        if (p && p->window && p->menubar) {
            GList *kids = gtk_container_get_children(GTK_CONTAINER(p->menubar));
            GList *it;
            for (it = kids; it; it = it->next) {
                GtkWidget *w = GTK_WIDGET(it->data);
                GtkAllocation a;
                const char *id = "-";
                int i;
                for (i = 0; i < p->menu_item_count; i++) {
                    if (p->menu_items[i].widget == w) {
                        id = p->menu_items[i].app_id;
                        break;
                    }
                }
                gtk_widget_get_allocation(w, &a);
                g_string_append_printf(s, "%s=%d+%d+%d ", id, a.x, a.width, a.height);
            }
            g_list_free(kids);
        }
    }
    fprintf(stderr, "[cj-bridge] menu layout: %s\n", s->str);
    g_string_free(s, TRUE);
    free(m);
    return G_SOURCE_REMOVE;
}

static void menu_post_layout(cj_host *h) {
    menu_layout_idle *m = (menu_layout_idle *)calloc(1, sizeof(*m));
    if (!m) return;
    m->h = h;
    g_idle_add_full(G_PRIORITY_LOW, menu_layout_idle_cb, m, NULL);
}

/* 顶部那一行的显隐：菜单栏挂着、或副标题文本非空时整行才出现。
   空菜单栏不留空条（原有约束）同样适用于空副标题——否则应用没设副标题时窗口顶部
   会凭空多出一条空行高度。 */
static void topbar_sync_visible(plat_host *p) {
    const char *t;

    if (!p) return;
    t = p->subtitle ? gtk_label_get_text(GTK_LABEL(p->subtitle)) : "";
    if (p->subtitle) {
        if (t && t[0]) gtk_widget_show(p->subtitle);
        else gtk_widget_hide(p->subtitle);
    }
    if (p->topbar) {
        if (p->menubar || (t && t[0])) gtk_widget_show(p->topbar);
        else gtk_widget_hide(p->topbar);
    }
}

static void menu_apply_wire(cj_host *h, plat_host *p, const char *wire) {
    menu_build_ctx c;

    /* p->window 为 NULL 说明窗口已销毁（on_destroy 会置空）：晚到的 idle 就别再碰 GTK 了 */
    if (!p || !p->window || !p->box) return;
    /* 旧菜单栏整体拆掉：子项随父销毁，各自的 ctx 由 destroy 处理器释放 */
    if (p->menubar) {
        gtk_widget_destroy(p->menubar);
        p->menubar = NULL;
    }
    menu_clear_slots(p);
    if (!wire || !wire[0]) { /* 空串 = 清空菜单栏（不留一条空条）*/
        topbar_sync_visible(p);
        fprintf(stderr, "[cj-bridge] menu cleared\n");
        return;
    }
    memset(&c, 0, sizeof(c)); /* 不用 ZeroMemory：那是 Windows 宏，本文件没有它 */
    c.h = h;
    c.p = p;
    c.menubar = gtk_menu_bar_new();
    c.stack[0] = c.menubar;
    c.ok[0] = 1;
    cj_core_menu_walk(wire, menu_add_row, &c);
    p->menubar = c.menubar;
    /* 菜单栏装进顶行（topbar 常驻；万一没有则回落 box，保持旧装配可用的形状）*/
    if (p->topbar) {
        gtk_box_pack_start(GTK_BOX(p->topbar), p->menubar, FALSE, FALSE, 0);
        gtk_box_reorder_child(GTK_BOX(p->topbar), p->menubar, 0); /* 菜单栏在副标题左侧 */
    } else {
        gtk_box_pack_start(GTK_BOX(p->box), p->menubar, FALSE, FALSE, 0);
        gtk_box_reorder_child(GTK_BOX(p->box), p->menubar, 0); /* 菜单栏必须在 view 之上 */
    }
    gtk_widget_show_all(p->menubar);
    topbar_sync_visible(p);
    /* 凭证是「事后从 GTK 侧读回来」，不是「我调过 gtk_menu_bar_new 了」：菜单栏没挂进 box、
       或条目一个都没建出来时，光打一句 applied 会把人骗过去（Windows 侧 SetMenu 静默失败
       正是这么踩的，见 bridge_win.c 的 GetMenu 复核）。bar_children 是菜单栏的顶层项数
       （含分隔线），items 是全部槽位（含子菜单里的项），两者不等是正常的。 */
    {
        GList *kids = gtk_container_get_children(GTK_CONTAINER(p->menubar));
        fprintf(stderr,
                "[cj-bridge] menu applied: items=%d bar=%p parent=%p bar_children=%u visible=%d\n",
                p->menu_item_count, (void *)p->menubar, (void *)gtk_widget_get_parent(p->menubar),
                (unsigned)g_list_length(kids), gtk_widget_get_visible(p->menubar) ? 1 : 0);
        g_list_free(kids);
    }
    menu_post_layout(h); /* 布局走完再读一次几何（低优先级 idle），驱动脚本据此定位 */
}

/* ===== 窗口顶部副标题（与菜单栏同一行的右侧）===== */
/* 运行期高频更新（标题 / 保存状态 / 字数），一律投 g_idle 到 GTK 线程——
   与 set_menu 同一条纪律：仓颉侧任何线程都可能调用，别在主循环外碰 widget。 */
typedef struct subtitle_idle {
    cj_host *h;
    char *text;
} subtitle_idle;

static gboolean subtitle_idle_cb(gpointer data) {
    subtitle_idle *s = (subtitle_idle *)data;

    if (!s) return G_SOURCE_REMOVE;
    {
        plat_host *p = s->h ? (plat_host *)s->h->plat : NULL;
        if (p && p->window && p->subtitle) {
            gtk_label_set_text(GTK_LABEL(p->subtitle), s->text ? s->text : "");
            topbar_sync_visible(p);
            /* 凭证：文本回读 + 整行显隐都打一行，避免「我设过了」式的假成功
               （菜单那轮的教训：SetMenu 返回 FALSE 也照打 applied） */
            fprintf(stderr, "[cj-bridge] titlebar subtitle: \"%s\" topbar_visible=%d\n",
                    gtk_label_get_text(GTK_LABEL(p->subtitle)),
                    (p->topbar && gtk_widget_get_visible(p->topbar)) ? 1 : 0);
        }
    }
    free(s->text);
    free(s);
    return G_SOURCE_REMOVE;
}

int cj_plat_set_titlebar_subtitle(cj_host *h, const char *text) {
    plat_host *p;
    subtitle_idle *s;

    if (!h || !text) return -1;
    p = (plat_host *)h->plat;
    if (!p || !p->window) return -3;
    s = (subtitle_idle *)calloc(1, sizeof(*s));
    if (!s) return -3;
    s->h = h;
    s->text = strdup(text);
    if (!s->text) {
        free(s);
        return -3;
    }
    if (!g_idle_add(subtitle_idle_cb, s)) {
        free(s->text);
        free(s);
        return -3;
    }
    return 0;
}

/* 跨线程换菜单：线路文本进 g_idle 队列，由 GTK 线程消费（payload 谁分配谁在 idle 里释放）*/
typedef struct menu_wire_idle {
    cj_host *h;
    char *wire;
} menu_wire_idle;

static gboolean menu_wire_idle_cb(gpointer data) {
    menu_wire_idle *m = (menu_wire_idle *)data;
    if (!m) return G_SOURCE_REMOVE;
    {
        plat_host *p = m->h ? (plat_host *)m->h->plat : NULL;
        if (p) menu_apply_wire(m->h, p, m->wire);
    }
    free(m->wire);
    free(m);
    return G_SOURCE_REMOVE;
}

void cj_plat_set_menu(cj_host *h, const char *wire) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || !wire) return;
    if (!p->window) {
        /* 未就绪：core 已把线路文本记在 h->pending_menu_text，宿主线程装配时取用 */
        fprintf(stderr, "[cj-bridge] menu deferred: window not ready\n");
        return;
    }
    if (cj_plat_is_ui_thread(h)) {
        menu_apply_wire(h, p, wire);
        return;
    }
    {
        menu_wire_idle *m = (menu_wire_idle *)calloc(1, sizeof(*m));
        if (!m) return;
        m->h = h;
        m->wire = strdup(wire);
        if (!m->wire) {
            free(m);
            return;
        }
        g_idle_add(menu_wire_idle_cb, m);
        fprintf(stderr, "[cj-bridge] menu posted to gtk thread (%d bytes)\n", (int)strlen(wire));
    }
}

/* 跨线程改单项状态：同样走 g_idle（与换菜单分开一个包裹，互不阻塞）*/
typedef struct menu_state_idle {
    cj_host *h;
    char *id;
    int enabled;
    int checked;
} menu_state_idle;

static gboolean menu_state_idle_cb(gpointer data) {
    menu_state_idle *m = (menu_state_idle *)data;
    if (!m) return G_SOURCE_REMOVE;
    {
        plat_host *p = m->h ? (plat_host *)m->h->plat : NULL;
        if (p) menu_apply_item_state(p, m->id, m->enabled, m->checked);
    }
    free(m->id);
    free(m);
    return G_SOURCE_REMOVE;
}

void cj_plat_menu_item_state(cj_host *h, const char *id, int enabled, int checked) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || !id || !id[0]) return;
    if (!p->window || !p->menubar) {
        fprintf(stderr, "[cj-bridge] menu item state ignored: menu not ready (%s)\n", id);
        return;
    }
    if (cj_plat_is_ui_thread(h)) {
        menu_apply_item_state(p, id, enabled, checked);
        return;
    }
    {
        menu_state_idle *m = (menu_state_idle *)calloc(1, sizeof(*m));
        if (!m) return;
        m->h = h;
        m->id = strdup(id);
        m->enabled = enabled ? 1 : 0;
        m->checked = checked ? 1 : 0;
        if (!m->id) {
            free(m);
            return;
        }
        g_idle_add(menu_state_idle_cb, m);
    }
}

/* ===== 拖放策略（7.B Linux 侧）：两头都支持——未就绪只记（建 view 时读 pending 字段），
   就绪后投 UI 线程重挂 drag dest（GTK 对象只能在 GTK 线程碰）===== */

typedef struct drag_idle {
    cj_host *h;
    int enabled;
    int files;
} drag_idle;

static gboolean drag_idle_cb(gpointer data) {
    drag_idle *m = (drag_idle *)data;
    if (!m) return G_SOURCE_REMOVE;
    {
        plat_host *p = m->h ? (plat_host *)m->h->plat : NULL;
        if (p) drag_dest_apply(m->h, p, m->enabled, m->files);
    }
    free(m);
    return G_SOURCE_REMOVE;
}

void cj_plat_set_drag_drop(cj_host *h, int enabled, int files) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p) return;
    if (!p->window) {
        /* 未就绪：core 已把策略写进 h->pending_drop_*，建 view 时读 */
        return;
    }
    if (cj_plat_is_ui_thread(h)) {
        drag_dest_apply(h, p, enabled, files);
        return;
    }
    {
        drag_idle *m = (drag_idle *)calloc(1, sizeof(*m));
        if (!m) return;
        m->h = h;
        m->enabled = enabled ? 1 : 0;
        m->files = files ? 1 : 0;
        g_idle_add(drag_idle_cb, m);
    }
}

/* ===== 窗口可见性 / 最小化到托盘（RFC-003 第 5 期余项）=====
   两条都只动**窗口层**：gtk_widget_hide() 不销毁窗口与 WebKitWebView，页面照旧跑、轮询照旧，
   只是看不见——所以「最小化到托盘」不需要任何页面侧配合。还原入口是应用自己的事
   （托盘菜单 / 全局快捷键里调 setWindowVisible(true)），框架不替它决定。

   拦截点在 GTK 的 "window-state-event"：用户按下最小化时窗口进入 ICONIFIED，若策略开着
   **且托盘真的挂上了**，就把窗口 hide 掉并吃掉这个事件（返回 TRUE，GTK 不再图标化），
   从用户视角看就是「最小化进了托盘」。托盘没挂上就如实降级为普通最小化 + 一行 stderr
   （与 Windows 侧 WM_SYSCOMMAND 同一条纪律：宁可说出「不支持」，也不能让窗口藏起来没入口点回来）。 */

/** 托盘是否真的挂上了（CJ_HAVE_TRAY 没编进来时恒为 0：能力位如实，这里也如实）*/
static int tray_installed(plat_host *p) {
#ifdef CJ_HAVE_TRAY
    return p->tray != NULL;
#else
    (void)p;
    return 0;
#endif
}

/** 用户按下最小化（或从最小化恢复）时触发：策略 + 托盘齐备才改写成「藏进托盘」*/
static gboolean on_window_state(GtkWidget *w, GdkEventWindowState *ev, gpointer ud) {
    cj_host *h = (cj_host *)ud;
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || !ev || !h->minimize_to_tray) return FALSE;
    if (!(ev->new_window_state & GDK_WINDOW_STATE_ICONIFIED)) return FALSE;
    if (tray_installed(p)) {
        gtk_widget_hide(w);
        fprintf(stderr, "[cj-bridge] minimize -> tray (window hidden)\n");
        return TRUE; /* 吃掉事件：GTK 不再执行默认的图标化 */
    }
    if (!p->min_to_tray_warned) {
        p->min_to_tray_warned = 1; /* 只出声一次：用户每按一次最小化都打会刷屏 */
        fprintf(stderr, "[cj-bridge] minimize_to_tray: no tray installed - plain minimize\n");
    }
    return FALSE;
}

static void window_apply_visible(plat_host *p, int visible) {
    if (!p || !p->window) return;
    if (visible) {
        gtk_widget_show(p->window);
        gtk_window_present(GTK_WINDOW(p->window)); /* 藏过的窗口 show 不会自己激活：顺手提到前面 */
    } else {
        gtk_widget_hide(p->window);
    }
    fprintf(stderr, "[cj-bridge] window %s\n", visible ? "shown" : "hidden");
}

/* ===== 附庸窗（owned window）=====
   GTK 侧同样是一个关系带出两条效果：transient-for 让本窗**总在属主之上**、属主图标化时
   一并收起；skip_taskbar_hint 把它从任务栏与 Alt-Tab 列表里摘掉（窗口本来就是主窗的一块延伸）。
   owner=NULL 解除隶属时两样一起还原。 */
static void window_apply_owner(plat_host *p, plat_host *owner_p) {
    if (!p || !p->window) return;
    if (owner_p && !owner_p->window) {
        fprintf(stderr, "[cj-bridge] owner window not created yet, skip\n");
        return;
    }
    GtkWindow *win = GTK_WINDOW(p->window);
    if (owner_p) {
        gtk_window_set_transient_for(win, GTK_WINDOW(owner_p->window));
        gtk_window_set_skip_taskbar_hint(win, TRUE);
        gtk_window_set_skip_pager_hint(win, TRUE); /* 任务栏之外，工作区切换器里也别占一格 */
    } else {
        gtk_window_set_transient_for(win, NULL);
        gtk_window_set_skip_taskbar_hint(win, FALSE);
        gtk_window_set_skip_pager_hint(win, FALSE);
    }
    /* 事后查询复核打进同一行：GTK 的 hint 由窗口管理器执行，设了不等于生效
       （§4 的 SetMenu 那条教训：只打「我调过了」等于没有凭证）。 */
    fprintf(stderr, "[cj-bridge] owner window applied: owner=%p transient_for=%p skip_taskbar=%d\n",
            (void *)(owner_p ? owner_p->window : NULL),
            (void *)gtk_window_get_transient_for(win),
            gtk_window_get_skip_taskbar_hint(win) ? 1 : 0);
}

typedef struct owner_idle {
    cj_host *h;
    cj_host *owner;
} owner_idle;

static gboolean owner_idle_cb(gpointer data) {
    owner_idle *m = (owner_idle *)data;
    if (!m) return G_SOURCE_REMOVE;
    {
        plat_host *p = m->h ? (plat_host *)m->h->plat : NULL;
        plat_host *op = (m->owner && m->owner->plat) ? (plat_host *)m->owner->plat : NULL;
        if (p) window_apply_owner(p, op);
    }
    free(m);
    return G_SOURCE_REMOVE;
}

typedef struct visible_idle {
    cj_host *h;
    int visible;
} visible_idle;

static gboolean visible_idle_cb(gpointer data) {
    visible_idle *m = (visible_idle *)data;
    if (!m) return G_SOURCE_REMOVE;
    {
        plat_host *p = m->h ? (plat_host *)m->h->plat : NULL;
        if (p) window_apply_visible(p, m->visible);
    }
    free(m);
    return G_SOURCE_REMOVE;
}

void cj_plat_set_window_visible(cj_host *h, int visible) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p) return;
    if (!p->window) {
        /* 未就绪：core 已把可见性写进 h->win_visible，建窗时读（与拖放同一条路）*/
        return;
    }
    if (cj_plat_is_ui_thread(h)) {
        window_apply_visible(p, visible);
        return;
    }
    {
        visible_idle *m = (visible_idle *)calloc(1, sizeof(*m));
        if (!m) return;
        m->h = h;
        m->visible = visible ? 1 : 0;
        g_idle_add(visible_idle_cb, m);
    }
}

void cj_plat_set_owner_window(cj_host *h, cj_host *owner) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p) return;
    if (!p->window) {
        /* 未就绪：core 已把属主写进 h->owner，建窗时读（与可见性同一条路）*/
        return;
    }
    if (cj_plat_is_ui_thread(h)) {
        window_apply_owner(p, owner ? (plat_host *)owner->plat : NULL);
        return;
    }
    {
        owner_idle *m = (owner_idle *)calloc(1, sizeof(*m));
        if (!m) return;
        m->h = h;
        m->owner = owner;
        g_idle_add(owner_idle_cb, m);
    }
}

/* ===== 同窗内嵌视图（PLT-006 真标签页）=====
   五个导出都只做一件事：把意图 g_idle_add 到 GTK 线程（worker 线程绝不碰 GTK），
   真实的增删移全在 view_apply_op 里。 */

static void view_apply_op(view_op *op);

static gboolean view_idle_cb(gpointer data) {
    view_apply_op((view_op *)data);
    return G_SOURCE_REMOVE;
}

static void view_post(cj_host *h, int opcode, long long id, int x, int y, int w, int hgt,
                      int flag, const char *url) {
    view_op *op;

    if (!h) return;
    op = (view_op *)calloc(1, sizeof(*op));
    if (!op) return;
    op->h = h;
    op->opcode = opcode;
    op->id = id;
    op->x = x;
    op->y = y;
    op->w = w;
    op->hgt = hgt;
    op->flag = flag;
    if (url && url[0]) {
        size_t n = strlen(url) + 1;
        op->url = (char *)malloc(n);
        if (op->url) memcpy(op->url, url, n);
    }
    /* 已经在 GTK 线程里调也走这条：少一条「我是不是已经在 GTK 线程」的分支 */
    g_idle_add(view_idle_cb, op);
}

static view_slot *view_find(plat_host *p, long long id) {
    int i;
    if (!p || id <= 0) return NULL;
    for (i = 0; i < CJ_VIEW_MAX; i++) {
        if (p->views[i].id == id) return &p->views[i];
    }
    return NULL;
}

static view_slot *view_alloc(plat_host *p) {
    int i;
    for (i = 0; i < CJ_VIEW_MAX; i++) {
        if (p->views[i].id == 0) return &p->views[i];
    }
    return NULL;
}

/* 收掉一个视图：webview 是 overlay 的子 widget，destroy 会连带把它从容器摘掉。 */
static void view_close(plat_host *p, view_slot *vs) {
    (void)p;
    if (!vs) return;
    if (vs->webview) {
        gtk_widget_destroy(vs->webview);
        vs->webview = NULL;
    }
    if (vs->pending_url) {
        free(vs->pending_url);
        vs->pending_url = NULL;
    }
    vs->id = 0;
    vs->visible = 0;
}

/* GTK 线程：把一条意图落到表与容器上。op 由本函数释放。 */
static void view_apply_op(view_op *op) {
    plat_host *p;
    view_slot *vs;

    if (!op) return;
    p = op->h ? (plat_host *)op->h->plat : NULL;
    if (!p || !p->fixed) {
        fprintf(stderr, "[cj-bridge] view op dropped: overlay not ready\n");
        if (op->url) free(op->url);
        free(op);
        return;
    }
    switch (op->opcode) {
    case CJ_VIEW_OP_CREATE:
        vs = view_alloc(p);
        if (!vs) {
            fprintf(stderr, "[cj-bridge] view create rejected: %d 个槽位都在用\n", CJ_VIEW_MAX);
            break;
        }
        vs->id = op->id;
        vs->x = op->x;
        vs->y = op->y;
        vs->w = op->w;
        vs->h = op->hgt;
        vs->visible = 1;   /* 新建的视图就是用户刚要看的那个 */
        {
            /* 默认 context 建视图：cookie / 登录态与主页面共用（与 Windows 的共享 environment 同义）。
               这里**不注入桥**：装的是第三方站点，它的脚本不该拿到 window.__CJ_TAURI__。 */
            WebKitWebView *wv = WEBKIT_WEB_VIEW(webkit_web_view_new());
            vs->webview = GTK_WIDGET(wv);
            gtk_fixed_put(GTK_FIXED(p->fixed), vs->webview, vs->x, vs->y);
            gtk_widget_set_size_request(vs->webview, vs->w, vs->h);
            gtk_widget_show(vs->webview);
            if (op->url) {
                webkit_web_view_load_uri(wv, op->url);
            }
            fprintf(stderr, "[cj-bridge] view ready: id=%lld rect=%d,%d %dx%d url=%s\n",
                    vs->id, vs->x, vs->y, vs->w, vs->h, op->url ? op->url : "");
        }
        break;
    case CJ_VIEW_OP_VISIBLE:
        vs = view_find(p, op->id);
        if (!vs || !vs->webview) break;
        if (op->flag) gtk_widget_show(vs->webview);
        else gtk_widget_hide(vs->webview);
        vs->visible = op->flag ? 1 : 0;
        break;
    case CJ_VIEW_OP_BOUNDS:
        vs = view_find(p, op->id);
        if (!vs || !vs->webview) break;
        vs->x = op->x;
        vs->y = op->y;
        vs->w = op->w;
        vs->h = op->hgt;
        gtk_fixed_move(GTK_FIXED(p->fixed), vs->webview, vs->x, vs->y);
        gtk_widget_set_size_request(vs->webview, vs->w, vs->h);
        break;
    case CJ_VIEW_OP_NAVIGATE:
        vs = view_find(p, op->id);
        if (!vs || !vs->webview || !op->url) break;
        webkit_web_view_load_uri(WEBKIT_WEB_VIEW(vs->webview), op->url);
        break;
    case CJ_VIEW_OP_DESTROY:
        view_close(p, view_find(p, op->id));
        break;
    default:
        break;
    }
    if (op->url) free(op->url);
    free(op);
}

long long cj_plat_view_create(cj_host *h, const char *url, int x, int y, int w, int hgt) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    long long id;

    if (!p || !p->window) {
        fprintf(stderr, "[cj-bridge] view create rejected: host window not ready\n");
        return 0;
    }
    /* 发号要跨线程安全（调用方是命令 worker），建表仍在 GTK 线程 */
    id = __sync_add_and_fetch(&p->view_seq, 1);
    view_post(h, CJ_VIEW_OP_CREATE, id, x, y, w, hgt, 1, url);
    return id;
}

void cj_plat_view_set_visible(cj_host *h, long long view, int visible) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || view <= 0) return;
    view_post(h, CJ_VIEW_OP_VISIBLE, view, 0, 0, 0, 0, visible ? 1 : 0, NULL);
}

void cj_plat_view_set_bounds(cj_host *h, long long view, int x, int y, int w, int hgt) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || view <= 0) return;
    view_post(h, CJ_VIEW_OP_BOUNDS, view, x, y, w, hgt, 0, NULL);
}

void cj_plat_view_navigate(cj_host *h, long long view, const char *url) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || view <= 0 || !url) return;
    view_post(h, CJ_VIEW_OP_NAVIGATE, view, 0, 0, 0, 0, 0, url);
}

void cj_plat_view_destroy(cj_host *h, long long view) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || view <= 0) return;
    view_post(h, CJ_VIEW_OP_DESTROY, view, 0, 0, 0, 0, 0, NULL);
}

/* 最小化到托盘这里只**记一条策略**（并复位提醒位）：真正的拦截发生在用户按下最小化的那一刻
   （window-state-event），此刻窗口层没有可做的事——与 Windows 侧同形。 */
void cj_plat_set_minimize_to_tray(cj_host *h, int enabled) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p) return;
    p->min_to_tray_warned = 0;
    fprintf(stderr, "[cj-bridge] minimize_to_tray: %s\n", enabled ? "on" : "off");
}

int cj_plat_host_capabilities(cj_host *h) {
    (void)h;
    /* 本平台的静态能力：菜单栏已落地（GTK 的菜单栏不需要可选依赖）；拖放已落地（7.B，
       gtk_drag_dest，无新依赖）；通知走 freedesktop Notifications（会话总线），
       Xvfb 下无通知守护进程时命令会失败——能力位表示「协议层可用」，运行期成败由命令如实回传。
       全局快捷键按 CJ_HAVE_X11 编译期开关如实（RFC-002 §6.3 可选编译；运行期 X 打不开
       （Wayland）在 grab 线程里再打一行，位域只表达编译期事实）。
       托盘同理按 CJ_HAVE_TRAY 如实（libayatana-appindicator3 编进来了才置位）。 */
#ifdef CJ_HAVE_X11
#ifdef CJ_HAVE_TRAY
    return CJ_CAP_MENU | CJ_CAP_DRAG_DROP | CJ_CAP_NOTIFICATION | CJ_CAP_HOTKEY | CJ_CAP_TRAY |
        CJ_CAP_SUBTITLE;
#else
    return CJ_CAP_MENU | CJ_CAP_DRAG_DROP | CJ_CAP_NOTIFICATION | CJ_CAP_HOTKEY | CJ_CAP_SUBTITLE;
#endif
#else
#ifdef CJ_HAVE_TRAY
    return CJ_CAP_MENU | CJ_CAP_DRAG_DROP | CJ_CAP_NOTIFICATION | CJ_CAP_TRAY | CJ_CAP_SUBTITLE;
#else
    return CJ_CAP_MENU | CJ_CAP_DRAG_DROP | CJ_CAP_NOTIFICATION | CJ_CAP_SUBTITLE;
#endif
#endif
}

/* ===== 拖放（RFC-002 §5；7.B Linux 侧）===== */

/* drag-data-received：把 text/uri-list 原文交 core 解析（解码/上限/报文都在 core），
   本回调只做「取数据 + 转交 + finish」。动作语义由 core/上层定，这里不区分 copy/move。 */
static void on_drag_data_received(GtkWidget *widget, GdkDragContext *ctx,
                                  gint x, gint y, GtkSelectionData *sel,
                                  guint info, guint time, gpointer ud) {
    cj_host *h = (cj_host *)ud;
    (void)widget; (void)x; (void)y; (void)info;
    if (sel) {
        const guchar *data = gtk_selection_data_get_data(sel);
        gint len = gtk_selection_data_get_length(sel);
        if (data && len > 0) {
            char *uri_list = (char *)g_malloc((gsize)len + 1);
            if (uri_list) {
                memcpy(uri_list, data, (size_t)len);
                uri_list[len] = '\0';
                cj_core_drop_files(h, uri_list);
                g_free(uri_list);
            }
        }
    }
    gtk_drag_finish(ctx, sel != NULL && gtk_selection_data_get_length(sel) > 0,
                    FALSE, time);
}

/* 挂/摘 drag dest（装配期与运行期共用：enabled=0 摘除）。files=0 也先照挂——
   v1 载荷只有文件路径，files 开关留给将来的文本载荷；策略语义在仓颉侧把关 */
static void drag_dest_apply(cj_host *h, plat_host *p, int enabled, int files) {
    (void)files;
    if (!p || !p->view) return;
    if (enabled) {
        static const GtkTargetEntry targets[] = {
            { (gchar *)"text/uri-list", 0, 0 },
        };
        gtk_drag_dest_set(p->view, GTK_DEST_DEFAULT_ALL, targets, 1, GDK_ACTION_COPY);
        g_signal_connect(p->view, "drag-data-received",
                         G_CALLBACK(on_drag_data_received), h);
        fprintf(stderr, "[cj-bridge] drag dest attached (uri-list)\n");
    } else {
        gtk_drag_dest_unset(p->view);
        fprintf(stderr, "[cj-bridge] drag dest detached\n");
    }
}

/* =========================================================================
 *  托盘（RFC-002 §7.C；Linux = libayatana-appindicator3，可选编译 CJ_HAVE_TRAY）
 *
 *  线程纪律与菜单相同：AppIndicator / GtkMenu 只在 GTK 线程上创建与释放
 *  （activate 回调本来就是 GTK 主循环在发，交回 core 不跨线程）。运行期整表重建走
 *  g_idle_add 投到本线程；宿主线程收尾段（gtk_main 返回后）unref 兜底摘除。
 *  菜单行走 cj_core_menu_walk 的同一遍解析（平铺一层，depth 恒 0），
 *  头部两行 icon/tooltip 由本层自己切出来。
 * ========================================================================= */
#ifdef CJ_HAVE_TRAY

/* 托盘菜单项的回调上下文：id 是我们 malloc 的（随 widget 存亡，走 destroy notify 释放） */
typedef struct tray_item_ctx {
    cj_host *h;
    char *id;
} tray_item_ctx;

static void tray_item_ctx_free(gpointer data, GClosure *closure) {
    tray_item_ctx *c = (tray_item_ctx *)data;
    (void)closure;
    if (!c) return;
    free(c->id);
    free(c);
}

static void tray_on_activate(GtkMenuItem *item, gpointer ud) {
    tray_item_ctx *c = (tray_item_ctx *)ud;
    (void)item;
    if (!c || !c->h) return;
    cj_core_tray_clicked(c->h, c->id);
}

typedef struct tray_build_ctx {
    cj_host *h;
    GtkMenuShell *menu;
} tray_build_ctx;

/** 平铺一层的托盘菜单：kind 与菜单线路同码（n/c/s；m 丢弃——v1 不支持子菜单） */
static void tray_add_row(void *ctx, int depth, char kind, const char *id,
                         const char *label, int flags, const char *accel) {
    tray_build_ctx *c = (tray_build_ctx *)ctx;
    GtkWidget *item;
    int enabled = (flags & 1) ? 1 : 0;
    int checked = (flags & 2) ? 1 : 0;
    (void)depth;
    (void)accel;
    if (!c || !c->menu) return;
    if (kind == 's') {
        gtk_menu_shell_append(c->menu, gtk_separator_menu_item_new());
        return;
    }
    if (kind == 'm') {
        fprintf(stderr, "[cj-bridge] tray: submenu dropped (v1 tray menu is flat): %s\n", label);
        return;
    }
    item = (kind == 'c') ? gtk_check_menu_item_new_with_label(label)
                         : gtk_menu_item_new_with_label(label);
    gtk_widget_set_sensitive(item, enabled ? TRUE : FALSE);
    if (kind == 'c') {
        gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(item), checked ? TRUE : FALSE);
    }
    if (id[0]) {
        tray_item_ctx *tc = (tray_item_ctx *)calloc(1, sizeof(*tc));
        if (!tc) return;
        tc->h = c->h;
        tc->id = strdup(id);
        if (!tc->id) {
            free(tc);
            return;
        }
        g_signal_connect_data(item, "activate", G_CALLBACK(tray_on_activate), tc,
                              tray_item_ctx_free, (GConnectFlags)0);
    }
    gtk_menu_shell_append(c->menu, item);
}

/** 头部两行（icon/tooltip）之外的部分——调用方保证至少两行 */
static const char *tray_menu_part(const char *wire) {
    int nl = 0;
    const char *p = wire;
    while (*p && nl < 2) {
        if (*p == '\n') nl++;
        p++;
    }
    return p;
}

/** 跳到下一行行首（最后一行没有 \n 就到串尾） */
static const char *tray_next_line(const char *p) {
    const char *nl = strchr(p, '\n');
    return nl ? nl + 1 : p + strlen(p);
}

static void tray_apply_wire(cj_host *h, plat_host *p, const char *wire) {
    char icon[512];
    char tooltip[512];
    const char *menu_part;
    GtkWidget *menu;
    tray_build_ctx ctx;
    AppIndicator *ind;

    if (!p) return;
    if (!wire || !wire[0]) {
        tray_remove(p);
        return;
    }
    /* 逐行推进：第 1 行 icon、第 2 行 tooltip、剩下的全是菜单行。
       （第一版「先跳两行再找 tooltip」永远找不着——tooltip 在第 2 行，跳两行已经越过它了） */
    icon[0] = '\0';
    tooltip[0] = '\0';
    menu_part = wire;
    if (strncmp(menu_part, "icon\t", 5) == 0) {
        const char *v = menu_part + 5;
        const char *nl = strchr(v, '\n');
        size_t n = nl ? (size_t)(nl - v) : strlen(v);
        if (n >= sizeof(icon)) n = sizeof(icon) - 1;
        memcpy(icon, v, n);
        icon[n] = '\0';
        menu_part = tray_next_line(menu_part);
    }
    if (strncmp(menu_part, "tooltip\t", 8) == 0) {
        const char *v = menu_part + 8;
        const char *nl = strchr(v, '\n');
        size_t n = nl ? (size_t)(nl - v) : strlen(v);
        if (n >= sizeof(tooltip)) n = sizeof(tooltip) - 1;
        memcpy(tooltip, v, n);
        tooltip[n] = '\0';
        menu_part = tray_next_line(menu_part);
    }

    tray_remove(p);
    menu = gtk_menu_new();
    ctx.h = h;
    ctx.menu = GTK_MENU_SHELL(menu);
    cj_core_menu_walk(menu_part, tray_add_row, &ctx);
    gtk_widget_show_all(menu);

    /* 图标：给了路径走 set_icon_full（绝对路径 libappindicator 自己处理）；没给用主题图标兜底 */
    ind = app_indicator_new("cj-tauri-tray", icon[0] ? icon : "dialog-information",
                            APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
    app_indicator_set_status(ind, APP_INDICATOR_STATUS_ACTIVE);
    if (icon[0]) {
        app_indicator_set_icon_full(ind, icon, "cj-tauri tray icon");
    }
    if (tooltip[0]) {
        app_indicator_set_title(ind, tooltip);
    }
    app_indicator_set_menu(ind, GTK_MENU(menu));
    p->tray = ind;
    fprintf(stderr, "[cj-bridge] tray applied: icon=%s tooltip=%d bytes\n",
            icon[0] ? icon : "(theme)", (int)strlen(tooltip));
}

static void tray_remove(plat_host *p) {
    if (!p) return;
    if (p->tray) {
        g_object_unref(p->tray); /* 创建引用归我们：unref 即摘除（GtkMenu 随之释放） */
        p->tray = NULL;
        fprintf(stderr, "[cj-bridge] tray removed\n");
    }
}

/* 运行期整表重建的 idle 载荷（与 menu_wire_idle 同形，不复用是让回调各回各的函数） */
typedef struct tray_wire_idle {
    cj_host *h;
    char *wire;
} tray_wire_idle;

static gboolean tray_wire_idle_cb(gpointer data) {
    tray_wire_idle *m = (tray_wire_idle *)data;
    if (!m) return G_SOURCE_REMOVE;
    {
        plat_host *p = m->h ? (plat_host *)m->h->plat : NULL;
        if (p) tray_apply_wire(m->h, p, m->wire);
    }
    free(m->wire);
    free(m);
    return G_SOURCE_REMOVE;
}

#endif /* CJ_HAVE_TRAY */

void cj_plat_set_tray(cj_host *h, const char *wire) {
#ifndef CJ_HAVE_TRAY
    (void)h;
    (void)wire;
    fprintf(stderr, "[cj-bridge] tray not compiled in (no libayatana-appindicator3) - ignored\n");
#else
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || !wire) return;
    if (!p->window) {
        /* 未就绪：core 已把线路记在 h->pending_tray，宿主线程装配时取用 */
        fprintf(stderr, "[cj-bridge] tray deferred: window not ready\n");
        return;
    }
    if (cj_plat_is_ui_thread(h)) {
        tray_apply_wire(h, p, wire);
        return;
    }
    {
        tray_wire_idle *m = (tray_wire_idle *)calloc(1, sizeof(*m));
        if (!m) return;
        m->h = h;
        m->wire = strdup(wire);
        if (!m->wire) {
            free(m);
            return;
        }
        g_idle_add(tray_wire_idle_cb, m);
        fprintf(stderr, "[cj-bridge] tray posted to gtk thread (%d bytes)\n", (int)strlen(wire));
    }
#endif
}

/* =========================================================================
 *  全局快捷键（RFC-003 第 5 期；Linux = X11 XGrabKey，可选编译 CJ_HAVE_X11）
 *
 *  线程与管道拓扑（Xlib 的线程安全不想赌——单线程拥有一切 X 资源，命令/事件全走管道）：
 *    [任意线程] cj_plat_set_global_hotkeys ─'R'+长度+wire─▶ hk_cmd[1]→[0]
 *    [grab 线程] poll hk_cmd → 整表替换（ungrab 旧表再 grab 新表）；KeyPress → id 行 ─▶ hk_evt[1]→[0]
 *    [GTK 线程] g_timeout 50ms 轮询 hk_evt → cj_core_hotkey_pressed（仓颉回调只发生在 GTK 线程，
 *               与菜单/拖放同一纪律——绝不在 grab 线程碰仓颉运行时）
 *
 *  X 错误处理：Xlib 的错误处理器是**每线程**状态，grab 线程里安装/恢复不影响 GTK 线程的处理器；
 *  BadAccess（组合键已被别的程序占用）按「该条注册失败」处理，打日志继续，不是致命错。
 *
 *  锁定键坑（照修）：NumLock/CapsLock/ScrollLock 开着时 modifier state 多一位，
 *  XGrabKey 按 state 精确匹配——同一组合必须把 3 个锁定位的 8 种变体全部 grab，否则
 *  「开着 NumLock 就失灵」。事件匹配时反过来把锁定位掩掉再比。
 * ========================================================================= */
#define HK_MAX_KEYS  32
#define HK_ID_MAX    128
#define HK_LOCK_MASKS (Mod2Mask | LockMask | Mod5Mask)

#ifdef CJ_HAVE_X11

typedef struct hk_entry {
    int used;
    int keycode;
    unsigned int mods;   /* 不含锁定位的修饰键（Shift/Ctrl/Alt/Super）*/
    char id[HK_ID_MAX];
} hk_entry;

typedef struct hk_state {
    Display *dpy;        /* grab 线程独占的 X 连接；NULL = 打不开（Wayland 等），如实降级 */
    Window root;
    hk_entry keys[HK_MAX_KEYS];
    int count;
} hk_state;

/* Xlib 错误处理器（每线程）：只记 BadAccess（组合键被占用），其余交给默认处理 */
static int g_hk_badaccess = 0;
static int hk_xerror_handler(Display *dpy, XErrorEvent *ev) {
    (void)dpy;
    if (ev->error_code == BadAccess) {
        g_hk_badaccess = 1;
        return 0;
    }
    return 0;
}

/** 修饰键名 → mask；认不出返回 -1（整行丢弃并打日志） */
static int hk_mod_bit(const char *name, unsigned int *out) {
    if (strcmp(name, "Ctrl") == 0 || strcmp(name, "Control") == 0) { *out = ControlMask; return 0; }
    if (strcmp(name, "Alt") == 0)  { *out = Mod1Mask; return 0; }
    if (strcmp(name, "Shift") == 0) { *out = ShiftMask; return 0; }
    if (strcmp(name, "Super") == 0 || strcmp(name, "Win") == 0) { *out = Mod4Mask; return 0; }
    return -1;
}

/** 键名 → keysym：常用别名（加速器文案惯例）+ 其余原样交给 XStringToKeysym */
static KeySym hk_keysym_of(const char *name) {
    if (strcmp(name, "Enter") == 0) { return XStringToKeysym("Return"); }
    if (strcmp(name, "Esc") == 0)   { return XStringToKeysym("Escape"); }
    return XStringToKeysym(name); /* "a" / "F1" / "Return" / "Up" 都是合法 keysym 名 */
}

/** 注销当前整表（8 种锁定位变体逐个 ungrab，与 grab 一一对应） */
static void hk_ungrab_all(hk_state *s) {
    int i, lock;
    for (i = 0; i < s->count; i++) {
        if (!s->keys[i].used) continue;
        for (lock = 0; lock < 8; lock++) {
            unsigned int extra = 0;
            if (lock & 1) extra |= Mod2Mask;
            if (lock & 2) extra |= LockMask;
            if (lock & 4) extra |= Mod5Mask;
            XUngrabKey(s->dpy, s->keys[i].keycode, s->keys[i].mods | extra, s->root);
        }
        s->keys[i].used = 0;
    }
    s->count = 0;
    XSync(s->dpy, False);
}

/** grab 一条（8 变体 + XSync 收错误）；被占用返回 0（该条出局，其余照常） */
static int hk_grab_one(hk_state *s, int keycode, unsigned int mods, const char *id) {
    int lock;
    XErrorHandler prev;
    if (s->count >= HK_MAX_KEYS) {
        fprintf(stderr, "[cj-bridge] hotkey: table full (%d), dropped: %s\n", HK_MAX_KEYS, id);
        return 0;
    }
    prev = XSetErrorHandler(hk_xerror_handler);
    g_hk_badaccess = 0;
    for (lock = 0; lock < 8; lock++) {
        unsigned int extra = 0;
        if (lock & 1) extra |= Mod2Mask;
        if (lock & 2) extra |= LockMask;
        if (lock & 4) extra |= Mod5Mask;
        XGrabKey(s->dpy, keycode, mods | extra, s->root, True, GrabModeAsync, GrabModeAsync);
    }
    XSync(s->dpy, False);
    (void)XSetErrorHandler(prev);
    if (g_hk_badaccess) {
        /* 已被别的程序 grab：把本条已 grab 上的变体退掉，如实报占用 */
        for (lock = 0; lock < 8; lock++) {
            unsigned int extra = 0;
            if (lock & 1) extra |= Mod2Mask;
            if (lock & 2) extra |= LockMask;
            if (lock & 4) extra |= Mod5Mask;
            XUngrabKey(s->dpy, keycode, mods | extra, s->root);
        }
        XSync(s->dpy, False);
        return 0;
    }
    s->keys[s->count].used = 1;
    s->keys[s->count].keycode = keycode;
    s->keys[s->count].mods = mods;
    snprintf(s->keys[s->count].id, HK_ID_MAX, "%s", id);
    s->count++;
    return 1;
}

/** 整表替换：ungrab 旧表 → 逐行解析 wire → grab 新表（解析不了的行整行丢弃并打日志） */
static void hk_apply_wire(hk_state *s, const char *wire) {
    char *copy, *line, *nl;
    hk_ungrab_all(s);
    if (!wire || !wire[0]) {
        fprintf(stderr, "[cj-bridge] hotkeys cleared\n");
        return;
    }
    copy = strdup(wire);
    if (!copy) return;
    line = copy;
    while (line && line[0]) {
        char *colon, *accel, *id, *tok, *save;
        char accel_orig[128];
        unsigned int mods = 0;
        KeySym sym;
        int ok = 1;
        nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        colon = strchr(line, ':');
        if (!colon || colon == line) {
            fprintf(stderr, "[cj-bridge] hotkey line skipped (no 'accel:id'): %s\n", line);
            goto next_line;
        }
        *colon = '\0';
        accel = line;
        id = colon + 1;
        snprintf(accel_orig, sizeof(accel_orig), "%s", accel); /* strtok 会原地改坏 accel，日志留原始文本 */
        /* 修饰键：'+' 分隔逐个解析，最后一个 token 是键名 */
        save = NULL;
        tok = strtok_r(accel, "+", &save);
        while (tok) {
            unsigned int bit;
            char *next = strtok_r(NULL, "+", &save);
            if (!next) break; /* tok 是键名 */
            if (hk_mod_bit(tok, &bit) == 0) {
                mods |= bit;
            } else {
                fprintf(stderr, "[cj-bridge] hotkey: unknown modifier \"%s\" in: %s:%s\n", tok, accel, id);
                ok = 0;
                break;
            }
            tok = next;
        }
        if (ok && tok) {
            sym = hk_keysym_of(tok);
            if (sym == NoSymbol) {
                fprintf(stderr, "[cj-bridge] hotkey: unknown key \"%s\" in: %s:%s\n", tok, accel, id);
                ok = 0;
            } else {
                int code = XKeysymToKeycode(s->dpy, sym);
                if (code == 0) {
                    fprintf(stderr, "[cj-bridge] hotkey: no keycode for \"%s\"\n", tok);
                    ok = 0;
                } else if (hk_grab_one(s, code, mods, id)) {
                    fprintf(stderr, "[cj-bridge] hotkey grab: %s:%s (code=%d mods=0x%x)\n",
                            accel_orig, id, code, mods);
                } else {
                    fprintf(stderr, "[cj-bridge] hotkey grab failed (in use?): %s:%s\n", accel_orig, id);
                }
            }
        }
next_line:
        line = nl ? nl + 1 : NULL;
    }
    free(copy);
}

/** 定长读（grab 线程的命令协议：'R' + 4 字节长度 + wire） */
static int hk_read_full(int fd, void *buf, size_t n) {
    char *p = (char *)buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return 0;
}

/** grab 线程主体：独占 X 连接；命令（整表替换 / 退出）走 hk_cmd，触发走 hk_evt */
static void *hk_thread_main(void *ud) {
    cj_host *h = (cj_host *)ud;
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    hk_state st;
    if (!p) return NULL;
    memset(&st, 0, sizeof(st));
    st.dpy = XOpenDisplay(NULL);
    if (!st.dpy) {
        /* Wayland 会话 / 无 X：能力位是编译期静态事实，这里如实降级——事件不会来 */
        fprintf(stderr, "[cj-bridge] hotkey: XOpenDisplay failed (Wayland? X11 unavailable)\n");
    } else {
        st.root = DefaultRootWindow(st.dpy);
        /* pending 不在这里应用：宿主线程装配点必发 'R'（整表替换），启动时再应用一遍
           只会重复注册（实测同一组合 grab 日志出两行）。'R' 在管道里等着，本线程进循环就取到。 */
    }
    while (!p->hk_quit) {
        fd_set rf;
        struct timeval tv;
        int xfd = st.dpy ? XConnectionNumber(st.dpy) : -1;
        int maxfd = (p->hk_cmd[0] > xfd) ? p->hk_cmd[0] : xfd;
        FD_ZERO(&rf);
        FD_SET(p->hk_cmd[0], &rf);
        if (xfd >= 0) FD_SET(xfd, &rf);
        tv.tv_sec = 0;
        tv.tv_usec = 500 * 1000; /* 500ms：hk_quit 的兜底检查周期 */
        if (select(maxfd + 1, &rf, NULL, NULL, &tv) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (p->hk_quit) break;
        if (FD_ISSET(p->hk_cmd[0], &rf)) {
            char cmd;
            if (hk_read_full(p->hk_cmd[0], &cmd, 1) != 0) break;
            if (cmd == 'Q') break;
            if (cmd == 'R') {
                unsigned int len = 0;
                char *wire;
                if (hk_read_full(p->hk_cmd[0], &len, sizeof(len)) != 0) break;
                if (len > 65536) break; /* 防御：线路文本不该有这么长 */
                wire = (char *)malloc(len + 1);
                if (!wire) break;
                if (hk_read_full(p->hk_cmd[0], wire, len) != 0) {
                    free(wire);
                    break;
                }
                wire[len] = '\0';
                if (st.dpy) {
                    hk_apply_wire(&st, wire);
                } else {
                    fprintf(stderr, "[cj-bridge] hotkeys set but X11 unavailable - ignored\n");
                }
                free(wire);
            }
        }
        if (st.dpy && xfd >= 0 && FD_ISSET(xfd, &rf)) {
            while (XPending(st.dpy)) {
                XEvent ev;
                int i;
                XNextEvent(st.dpy, &ev);
                if (ev.type != KeyPress) continue;
                for (i = 0; i < st.count; i++) {
                    unsigned int mods = ev.xkey.state & ~HK_LOCK_MASKS;
                    if (st.keys[i].used && st.keys[i].keycode == (int)ev.xkey.keycode &&
                        st.keys[i].mods == mods) {
                        char line[HK_ID_MAX + 2];
                        int n = snprintf(line, sizeof(line), "%s\n", st.keys[i].id);
                        /* PIPE_BUF 之上的写才可能交错；单行远小于 4KB，原子 */
                        if (write(p->hk_evt[1], line, (size_t)n) > 0) {
                            fprintf(stderr, "[cj-bridge] hotkey fired: %s\n", st.keys[i].id);
                        }
                        break;
                    }
                }
            }
        }
    }
    if (st.dpy) {
        hk_ungrab_all(&st);
        XCloseDisplay(st.dpy);
    }
    p->hk_done = 1;
    return NULL;
}

/** GTK 侧：50ms 轮询 hk_evt，把触发的 id 逐行交回 core（仓颉回调只在本线程发生） */
static gboolean hk_evt_poll(gpointer data) {
    cj_host *h = (cj_host *)data;
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    char buf[1024];
    ssize_t n;
    if (!p) return G_SOURCE_REMOVE;
    do {
        n = read(p->hk_evt[0], buf, sizeof(buf) - 1);
        if (n > 0) {
            ssize_t i = 0;
            buf[n] = '\0';
            while (i < n) {
                ssize_t j = i;
                while (j < n && buf[j] != '\n') j++;
                if (j > i) {
                    buf[j] = '\0';
                    cj_core_hotkey_pressed(h, buf + i);
                }
                i = j + 1;
            }
        }
    } while (n > 0);
    return G_SOURCE_CONTINUE;
}

#else /* !CJ_HAVE_X11：能力位不置位，调用打一行如实说明（可选编译约定，RFC-002 §6.3） */

static gboolean hk_evt_poll(gpointer data) {
    (void)data;
    return G_SOURCE_REMOVE;
}

#endif /* CJ_HAVE_X11 */

void cj_plat_set_global_hotkeys(cj_host *h, const char *wire) {
#ifndef CJ_HAVE_X11
    (void)wire;
    fprintf(stderr, "[cj-bridge] global hotkeys not compiled in (no X11 dev) - ignored\n");
    (void)h;
#else
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    unsigned int len;
    if (!p) return;
    /* 懒启动：首次调用才建管道与 grab 线程（不用全局快捷键的应用零改动、零线程） */
    if (!p->hk_boot) {
        if (pipe(p->hk_cmd) != 0 || pipe(p->hk_evt) != 0) {
            fprintf(stderr, "[cj-bridge] hotkey: pipe failed (errno=%d)\n", errno);
            return;
        }
        fcntl(p->hk_evt[0], F_SETFL, fcntl(p->hk_evt[0], F_GETFL) | O_NONBLOCK);
        p->hk_boot = 1;
        if (pthread_create(&p->hk_thread, NULL, hk_thread_main, h) == 0) {
            p->hk_thread_started = 1;
            p->hk_evt_src = g_timeout_add(50, hk_evt_poll, h);
            fprintf(stderr, "[cj-bridge] hotkey grab thread started (X11)\n");
        } else {
            fprintf(stderr, "[cj-bridge] hotkey: pthread_create failed\n");
            return;
        }
    }
    /* 管道写对 <=PIPE_BUF 的块是原子的：任意线程可直接写，无需投到 GTK 线程 */
    len = wire ? (unsigned int)strlen(wire) : 0;
    {
        char cmd = 'R';
        ssize_t w1 = write(p->hk_cmd[1], &cmd, 1);
        ssize_t w2 = write(p->hk_cmd[1], &len, sizeof(len));
        ssize_t w3 = (len > 0) ? write(p->hk_cmd[1], wire, len) : 0;
        (void)w1; (void)w2; (void)w3; /* 失败由 grab 线程侧 read_full 兜住并退出循环 */
    }
#endif
}

/* =========================================================================
 *  串口（plugin_serial 的平台层）：POSIX termios
 *
 *  句柄表与 fd **只活在本文件**：仓颉侧拿到的是表里分配的序号而不是 fd —— 页面即使拿着句柄乱试，
 *  也够不到 fd 1/2 这类「另有含义」的值。表锁用 PTHREAD_MUTEX_INITIALIZER 静态初始化，
 *  所以不需要 core 提供「一次性初始化」钩子，无头进程（没有窗口）里也能直接用。
 *
 *  打开一律 O_RDWR | O_NOCTTY | O_NONBLOCK：不阻塞（不为等载波信号钉住 worker 线程），
 *  也不把串口变成进程的控制终端。读取的超时交给 poll，不用 VTIME/VMIN——两套超时混用会让
 *  「timeout=0 就是不等待」这件事变得不可预测。
 * ========================================================================= */
#define CJ_SERIAL_MAX_HANDLES 8

typedef struct serial_slot {
    int used;
    long long id;
    int fd;
    char path[256];
} serial_slot;

static serial_slot g_serial_slots[CJ_SERIAL_MAX_HANDLES];
static long long g_serial_next_id = 1;
static pthread_mutex_t g_serial_lock = PTHREAD_MUTEX_INITIALIZER;

static void serial_err(char *err, int err_len, const char *fmt, ...) {
    va_list ap;
    if (!err || err_len <= 0) return;
    va_start(ap, fmt);
    vsnprintf(err, (size_t)err_len, fmt, ap);
    va_end(ap);
}

/* 数值波特率 → speed_t：只收 Linux 明确有宏的档位，不认识就拒绝（不猜、不近似） */
static int serial_speed_of(int baud, speed_t *out) {
    switch (baud) {
        case 300: *out = B300; return 1;
        case 600: *out = B600; return 1;
        case 1200: *out = B1200; return 1;
        case 2400: *out = B2400; return 1;
        case 4800: *out = B4800; return 1;
        case 9600: *out = B9600; return 1;
        case 19200: *out = B19200; return 1;
        case 38400: *out = B38400; return 1;
        case 57600: *out = B57600; return 1;
        case 115200: *out = B115200; return 1;
        case 230400: *out = B230400; return 1;
        case 460800: *out = B460800; return 1;
        case 500000: *out = B500000; return 1;
        case 921600: *out = B921600; return 1;
        case 1000000: *out = B1000000; return 1;
        default: return 0;
    }
}

static serial_slot *serial_find_locked(long long id) {
    int i;
    for (i = 0; i < CJ_SERIAL_MAX_HANDLES; i++) {
        if (g_serial_slots[i].used && g_serial_slots[i].id == id) return &g_serial_slots[i];
    }
    return NULL;
}

/* 把句柄翻成 fd；句柄无效时返回 -1 并填 err。调用方负责在 poll/read/write 期间不再持锁。 */
static int serial_fd_of(long long h, char *err, int err_len) {
    serial_slot *s;
    int fd;
    pthread_mutex_lock(&g_serial_lock);
    s = serial_find_locked(h);
    fd = s ? s->fd : -1;
    pthread_mutex_unlock(&g_serial_lock);
    if (fd < 0) serial_err(err, err_len, "serial: 句柄 %lld 无效（未打开或已关闭）", h);
    return fd;
}

static long long serial_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + (long long)ts.tv_nsec / 1000000;
}

long long cj_plat_serial_open(const char *path, const cj_serial_cfg *cfg, char *err, int err_len) {
    struct termios tty;
    speed_t sp;
    tcflag_t dbits;
    int fd;
    int i;
    long long id;

    if (!path || !cfg) {
        serial_err(err, err_len, "serial: 空路径 / 空配置");
        return -1;
    }
    if (!serial_speed_of(cfg->baud, &sp)) {
        serial_err(err, err_len, "serial: 本平台不支持的波特率 %d（只收常见档位）", cfg->baud);
        return -1;
    }

    /* open + 配置整段留在锁内：O_NONBLOCK 下 open 不会久等，这样也免了「先占槽再开」的竞态窗口 */
    pthread_mutex_lock(&g_serial_lock);

    for (i = 0; i < CJ_SERIAL_MAX_HANDLES; i++) {
        if (!g_serial_slots[i].used) break;
    }
    if (i == CJ_SERIAL_MAX_HANDLES) {
        pthread_mutex_unlock(&g_serial_lock);
        serial_err(err, err_len, "serial: 句柄表满（最多 %d 个并发串口）", CJ_SERIAL_MAX_HANDLES);
        return -2;
    }

    fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        serial_err(err, err_len, "serial: open(%s) 失败: %s", path, strerror(errno));
        pthread_mutex_unlock(&g_serial_lock);
        return -3;
    }
    if (tcgetattr(fd, &tty) != 0) {
        serial_err(err, err_len, "serial: tcgetattr(%s) 失败: %s（不是终端类设备？）",
                   path, strerror(errno));
        close(fd);
        pthread_mutex_unlock(&g_serial_lock);
        return -3;
    }

    /* 裸模式：串口上多半是二进制帧，回显 / 换行转换 / 信号解释都是破坏性加工。
       cfmakeraw 顺带设好 CS8 与清 PARENB，所以后面再按调用方参数覆盖一遍。 */
    cfmakeraw(&tty);
    tty.c_cflag |= (CLOCAL | CREAD);
    switch (cfg->data_bits) {
        case 5: dbits = CS5; break;
        case 6: dbits = CS6; break;
        case 7: dbits = CS7; break;
        default: dbits = CS8; break;
    }
    tty.c_cflag &= ~CSIZE;
    tty.c_cflag |= dbits;
    switch (cfg->parity) {
        case 1: tty.c_cflag |= (PARENB | PARODD); break;  /* 奇校验 */
        case 2: tty.c_cflag |= PARENB; tty.c_cflag &= ~PARODD; break; /* 偶校验 */
        default: tty.c_cflag &= ~PARENB; break;            /* 无校验 */
    }
    if (cfg->stop_bits == 2) {
        tty.c_cflag |= CSTOPB;
    } else {
        tty.c_cflag &= ~CSTOPB;
    }
    /* 硬件流控不替应用开：RTS/CTS 在不少设备上是手工握手的信号，框架自作主张会改语义 */
    tty.c_cflag &= ~CRTSCTS;
    tty.c_iflag &= ~(IXON | IXOFF | IXANY);
    tty.c_cc[VMIN] = 0;
    tty.c_cc[VTIME] = 0;
    if (cfsetispeed(&tty, sp) != 0 || cfsetospeed(&tty, sp) != 0) {
        serial_err(err, err_len, "serial: 设置波特率 %d 失败: %s", cfg->baud, strerror(errno));
        close(fd);
        pthread_mutex_unlock(&g_serial_lock);
        return -3;
    }
    if (tcsetattr(fd, TCSANOW, &tty) != 0) {
        serial_err(err, err_len, "serial: tcsetattr(%s) 失败: %s（设备不接受这组参数？）",
                   path, strerror(errno));
        close(fd);
        pthread_mutex_unlock(&g_serial_lock);
        return -3;
    }
    tcflush(fd, TCIOFLUSH);

    id = g_serial_next_id++;
    if (g_serial_next_id <= 0) g_serial_next_id = 1; /* 溢出兜底：句柄永不为 0 */
    g_serial_slots[i].used = 1;
    g_serial_slots[i].id = id;
    g_serial_slots[i].fd = fd;
    snprintf(g_serial_slots[i].path, sizeof(g_serial_slots[i].path), "%s", path);
    pthread_mutex_unlock(&g_serial_lock);

    /* 落地一行：参数与 fd 都打全，串口问题基本都是拿这行对账（AGENTS §1 的取证口径） */
    fprintf(stderr, "[cj-bridge] serial termios: path=%s baud=%d data=%d parity=%d stop=%d fd=%d\n",
            path, cfg->baud, cfg->data_bits, cfg->parity, cfg->stop_bits, fd);
    return id;
}

int cj_plat_serial_read(long long h, unsigned char *buf, int len, int timeout_ms, char *err, int err_len) {
    struct pollfd pfd;
    int fd = serial_fd_of(h, err, err_len);
    int pr;
    ssize_t n;

    if (fd < 0) return -4;

    /* poll 在锁外等：同一把锁若被「某个句柄的读超时」占住，别的串口就全废了 */
    pfd.fd = fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    pr = poll(&pfd, 1, timeout_ms > 0 ? timeout_ms : 0);
    if (pr < 0) {
        if (errno == EINTR) return 0; /* 被打断按「本轮无数据」处理，由上层决定要不要再读 */
        serial_err(err, err_len, "serial: poll 失败: %s", strerror(errno));
        return -3;
    }
    if (pr == 0) return 0; /* 超时：确实没数据，不是错误 */

    n = read(fd, buf, (size_t)len);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return 0;
        serial_err(err, err_len, "serial: read 失败: %s", strerror(errno));
        return -3;
    }
    return (int)n; /* n == 0：对端已关闭（pty 侧退出）*/
}

int cj_plat_serial_write(long long h, const unsigned char *buf, int len, int timeout_ms,
                         char *err, int err_len) {
    struct pollfd pfd;
    long long deadline = serial_now_ms() + (timeout_ms > 0 ? (long long)timeout_ms : 0);
    int budget = timeout_ms > 0 ? timeout_ms : 0;
    int fd = serial_fd_of(h, err, err_len);
    int written = 0;

    if (fd < 0) return -4;

    /* 有界写完：每轮 poll 只等「剩余预算」，所以总等待不会超出 timeout_ms（不是每轮都等满一遍） */
    while (written < len) {
        ssize_t n;
        int pr;
        pfd.fd = fd;
        pfd.events = POLLOUT;
        pfd.revents = 0;
        pr = poll(&pfd, 1, budget);
        if (pr < 0) {
            if (errno == EINTR) continue;
            serial_err(err, err_len, "serial: poll(POLLOUT) 失败: %s", strerror(errno));
            return written > 0 ? written : -3;
        }
        if (pr == 0) break; /* 预算用尽：返回已写入量，由上层决定要不要再写 */

        n = write(fd, buf + written, (size_t)(len - written));
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (budget <= 0) break; /* 不忙等：预算已尽就交回上层 */
                budget = (int)(deadline - serial_now_ms());
                if (budget < 0) budget = 0;
                continue;
            }
            serial_err(err, err_len, "serial: write 失败: %s", strerror(errno));
            return written > 0 ? written : -3;
        }
        written += (int)n;
        budget = (int)(deadline - serial_now_ms());
        if (budget < 0) budget = 0;
    }
    return written;
}

int cj_plat_serial_close(long long h, char *err, int err_len) {
    int fd = -1;
    int i;

    pthread_mutex_lock(&g_serial_lock);
    for (i = 0; i < CJ_SERIAL_MAX_HANDLES; i++) {
        if (g_serial_slots[i].used && g_serial_slots[i].id == h) {
            fd = g_serial_slots[i].fd;
            g_serial_slots[i].used = 0;
            g_serial_slots[i].id = 0;
            g_serial_slots[i].fd = -1;
            g_serial_slots[i].path[0] = '\0';
            break;
        }
    }
    pthread_mutex_unlock(&g_serial_lock);

    if (fd < 0) {
        serial_err(err, err_len, "serial: 句柄 %lld 无效（未打开或已关闭）", h);
        return -4;
    }
    close(fd); /* close 放锁外：它可能触发 pty 侧的清理，不该占着表锁 */
    return 0;
}

/* Linux 侧不实现 C 桥枚举：serial:list 仍走仓颉侧的 /dev 目录扫描（pty / by-id 都能收），
   这里按「未实现」口径返回 -4，core 原样交回。 */
int cj_plat_serial_list(char *out, int out_len) {
    if (out && out_len > 0) {
        serial_err(out, out_len, "%s", "serial: list 在本平台未实现（走仓颉侧 /dev 扫描）");
    }
    return -4;
}

/* ===== 通用 UI 线程投递（剪贴板等宿主能力共用；对话框走的是自己的专用通道）===== */

/* 通用投递的载荷 + 跳板：core 侧回调是 void 返回的，直接塞给 g_idle_add 会被
   GLib 按 GSourceFunc 解读返回值——void 函数留在返回寄存器里的**垃圾**若非 0，
   GLib 就认为「还要再跑」，同一个载荷被反复重入（实测：剪贴板读被跑两遍、
   通知载荷 double free）。跳板一律返回 G_SOURCE_REMOVE，只执行一次。 */
typedef struct ui_post_msg {
    cj_ui_fn fn;
    void *ud;
} ui_post_msg;

static gboolean ui_post_trampoline(gpointer data) {
    ui_post_msg *m = (ui_post_msg *)data;
    if (m) {
        m->fn(m->ud);
        free(m);
    }
    return G_SOURCE_REMOVE;
}

int cj_plat_post_ui(cj_host *h, cj_ui_fn fn, void *ud) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    ui_post_msg *m;
    if (!p || !p->view) {
        /* GTK 主循环还没起来（或已退出）：idle 回调永远不会执行 */
        fprintf(stderr, "[cj-bridge] post ui failed: gtk loop not ready\n");
        return 0;
    }
    m = (ui_post_msg *)malloc(sizeof(ui_post_msg));
    if (!m) {
        return 0;
    }
    m->fn = fn;
    m->ud = ud;
    g_idle_add(ui_post_trampoline, m);
    return 1;
}

/* ===== 剪贴板（plugin_clipboard 的平台层）：GTK clipboard =====
   调用方保证已在 GTK 线程上（core 的 UI 线程分流负责），这里不做线程判断。
   gtk_clipboard_wait_* 是同步 API：在 GTK 线程上阻塞等 X11 往返——对话框轮已证过
   「worker 等 UI 线程」这条链可行，这里反过来「UI 线程短暂阻塞等剪贴板」是 GTK 应用的常规做法。 */

int cj_plat_clipboard_write_text(cj_host *h, const char *text, char *err, int err_len) {
    GtkClipboard *cb;

    (void)h;
    cb = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    if (!cb) {
        if (err && err_len > 0) serial_err(err, err_len, "%s", "clipboard: 取不到默认剪贴板");
        return -3;
    }
    gtk_clipboard_set_text(cb, text ? text : "", -1);
    gtk_clipboard_store(cb); /* 关窗后仍留给系统（X11 上不 store 会随窗口一起消失）*/
    return 0;
}

char *cj_plat_clipboard_read_text(cj_host *h, char *err, int err_len) {
    GtkClipboard *cb;
    gchar *text;
    char *out = NULL;

    (void)h;
    cb = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    if (!cb) {
        if (err && err_len > 0) serial_err(err, err_len, "%s", "clipboard: 取不到默认剪贴板");
        return NULL;
    }
    text = gtk_clipboard_wait_for_text(cb);
    if (text) {
        out = strdup(text); /* 返回值要经 cj_bridge_clipboard_free 释放（malloc 家族）*/
        g_free(text);
    }
    return out; /* NULL = 空 / 非文本，不是错误 */
}

/* ===== 通知（plugin_notification 的平台层）：freedesktop Notifications =====
   走 GDBus 同步调用 org.freedesktop.Notifications.Notify（发后即忘：不等动作回执）。
   调用方保证已在 GTK 线程上。GIO 与 GTK 同源，无需额外链接。 */

int cj_plat_notification_notify(cj_host *h, const char *title, const char *body,
                                char *err, int err_len) {
    GBusType bus_type;
    GDBusConnection *conn;
    GVariant *result;
    GVariantBuilder actions_b;
    GVariantBuilder hints_b;
    GError *gerr = NULL;
    const char *app_name = "cj-tauri";
    const char *unused = "";

    (void)h;
    /* 会话总线（桌面通知走 session，不是 system）；无桌面环境时失败——如实报，不降级 */
    bus_type = G_BUS_TYPE_SESSION;
    conn = g_bus_get_sync(bus_type, NULL, &gerr);
    if (!conn) {
        if (err && err_len > 0) serial_err(err, err_len, "notification: 会话总线不可用: %s",
                                           gerr ? gerr->message : "?");
        if (gerr) g_error_free(gerr);
        return -3;
    }
    g_variant_builder_init(&actions_b, G_VARIANT_TYPE("as"));
    g_variant_builder_init(&hints_b, G_VARIANT_TYPE("a{sv}"));
    result = g_dbus_connection_call_sync(
        conn, "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications", "Notify",
        g_variant_new("(susssasa{sv}i)", app_name, (guint32)0, unused, title ? title : "",
                      body ? body : "", &actions_b, &hints_b, (gint32)-1),
        NULL, G_DBUS_CALL_FLAGS_NONE, 2000, NULL, &gerr);
    g_object_unref(conn);
    if (!result) {
        if (err && err_len > 0) serial_err(err, err_len, "notification: Notify 调用失败: %s",
                                           gerr ? gerr->message : "?");
        if (gerr) g_error_free(gerr);
        return -3;
    }
    g_variant_unref(result);
    return 0;
}

/* ===== 静默子进程（cj_plat_spawn_hidden / kill / alive 的平台层）=====
   Linux 没有「控制台窗口」这回事，但同样得脱开终端：自成会话 + 独立进程组之后，终端 Ctrl-C
   （SIGINT 发给前台进程组）不会连带打死它；标准 I/O 指到 /dev/null——父进程的终端随时可能消失，
   子进程往一个已经关掉的 pty 写就是 SIGPIPE。

   用 posix_spawn 而不是 fork + exec：它把「exec 失败」**同步**报给父进程（fork 那条只能让子进程
   自己 _exit，失败原因父进程永远拿不到），正好喂给 err 缓冲。 */

long long cj_plat_spawn_hidden(const char *exe, const char *args, char *err, int err_len) {
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t attr;
    char *copy = NULL;
    char *argv[64];
    int n = 0;
    int rc;
    pid_t pid = 0;
    short flags = POSIX_SPAWN_SETPGROUP; /* 自成进程组：终端 Ctrl-C 不连带打死 */

    if (!exe || !*exe) {
        serial_err(err, err_len, "spawn hidden: 程序路径为空");
        return 0;
    }
    argv[n++] = (char *)exe;
    if (args && *args) {
        char *p;
        copy = strdup(args);
        if (!copy) {
            serial_err(err, err_len, "spawn hidden: out of memory");
            return 0;
        }
        p = copy;
        while (*p && n < 63) {
            char *q = strchr(p, 0x1f);
            if (q) *q = '\0';
            argv[n++] = p;
            if (!q) break;
            p = q + 1;
        }
    }
    argv[n] = NULL;

    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDWR, 0);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_RDWR, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_RDWR, 0);
    posix_spawnattr_init(&attr);
#ifdef POSIX_SPAWN_SETSID
    flags = (short)(flags | POSIX_SPAWN_SETSID);
#endif
    posix_spawnattr_setflags(&attr, flags);
    rc = posix_spawn(&pid, exe, &fa, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    free(copy);
    if (rc != 0) {
        serial_err(err, err_len, "spawn hidden: posix_spawn 失败（%s）", strerror(rc));
        return 0;
    }
    return (long long)pid;
}

/* 幂等口径：进程已经不在了算成功（调用方只是想让它结束）。 */
int cj_plat_kill_pid(long long pid) {
    int i;

    if (pid <= 0) return 0;
    if (kill((pid_t)pid, SIGTERM) != 0) {
        if (errno == ESRCH) return 1; /* 已经不在了 */
        fprintf(stderr, "[cj-bridge] kill pid %lld: SIGTERM 失败（%s）\n", pid, strerror(errno));
        return 0;
    }
    /* 给 3 秒走完收尾（与 Windows 侧同口径），到点还在就补一刀 SIGKILL */
    for (i = 0; i < 30; i++) {
        usleep(100 * 1000);
        if (kill((pid_t)pid, 0) != 0 && errno == ESRCH) return 1;
    }
    fprintf(stderr, "[cj-bridge] kill pid %lld: 3s 内没等到退出，补 SIGKILL\n", pid);
    kill((pid_t)pid, SIGKILL);
    return 1;
}

int cj_plat_pid_alive(long long pid) {
    if (pid <= 0) return 0;
    return (kill((pid_t)pid, 0) == 0) ? 1 : 0;
}

/* ===== 内嵌资源释放（cj_plat_extract_assets 的平台层）=====
   Linux 侧的单文件产物是 ELF、随包资源走打包脚本各自的机制，不在 PE 资源这条路上，所以这里
   如实返回 0 =「这个产物里没有内嵌资源」。**不要**假装释放成功：调用方据此降级，谎报只会让它
   去找一个并不存在的文件。 */
int cj_plat_extract_assets(const char *dir, char *err, int err_len) {
    (void)dir;
    if (err && err_len > 0) err[0] = '\0';
    return 0;
}

/* ===== 动态库预加载（cj_plat_preload_library 的平台层）=====
   Linux 侧通常由系统提供 libssl/libcrypto（发行版包），本来就在 loader 的搜索路径里；
   这条原语是给「随包释放出来的库」留的出口，与 Windows 同名同签名（AGENTS §2）。
   RTLD_NOW：符号缺失当场报，不把错误推迟到第一次调用；RTLD_GLOBAL 让后续按名引用可见。 */
int cj_plat_preload_library(const char *path, char *err, int err_len) {
    void *h;

    if (err && err_len > 0) err[0] = '\0';
    if (!path || !*path) {
        serial_err(err, err_len, "preload: 路径为空");
        return 0;
    }
    h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        const char *e = dlerror();
        serial_err(err, err_len, "dlopen 失败：%s", e ? e : "没有给出原因");
        return 0;
    }
    return 1;
}

