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
/* 串口（plugin_serial）：termios 配置 + 超时读写 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <sys/types.h>
#include <termios.h>
#include <time.h>
#include "bridge_core.h"

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

/* ===== 每个宿主的平台私有状态 =====
   原先是一堆进程级单例（g_window / g_view / g_gtk_thread …）：多窗口一落地就互相覆盖，
   而且「哪个窗口」这件事在 ABI 上根本传不进来。现在挂在自己的 cj_host->plat 上，
   平台函数一律从入参句柄取状态——平台原语只认句柄，不看全局。 */
typedef struct plat_host {
    GtkWidget *window;  /* 主窗口；窗口销毁时置空（含用户关窗路径）*/
    GtkWidget *view;    /* WebKitWebView；宿主线程收尾时 unref 并置空 */
    /* --- 菜单栏（只在 GTK 线程上建 / 换 / 改）--- */
    GtkWidget *box;      /* window 里那层竖向 GtkBox：装菜单栏（若有）+ view */
    GtkWidget *menubar;  /* 当前菜单栏；NULL = 没有（空菜单栏不留空条）*/
    menu_slot menu_items[CJ_MENU_MAX_ITEMS];
    int menu_item_count;
    pthread_t thread;   /* 跑 gtk_main 的原生线程（对话框判断「调用方是否已在 GTK 线程」用）*/
    int thread_started;
    int thread_set;
    volatile int thread_done; /* 宿主线程跑完（收尾最后一步）：只有它为 1 才敢 free 这个结构，
                                 见 cj_plat_fini 里「为什么不 join」的注释 */
} plat_host;

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

void cj_plat_init(cj_host *h) {
    plat_host *p;
    if (!h) return;
    p = (plat_host *)calloc(1, sizeof(plat_host));
    if (!p) {
        fprintf(stderr, "[cj-bridge] init failed: out of memory\n");
        return;
    }
    h->plat = p;
}

int cj_plat_fini(cj_host *h) {
    plat_host *p;
    if (!h) return 1;
    p = (plat_host *)h->plat;
    if (!p) return 1;
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
    if (kind <= 1) {
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
    /* 装配：window 里套一层竖向 GtkBox（菜单栏 + view）。固定套一层而不是「有菜单才套」——
       少一种装配分支就少一类时序坑，代价只是一个 GtkBox 的开销。 */
    p->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_pack_start(GTK_BOX(p->box), p->view, TRUE, TRUE, 0);
    gtk_container_add(GTK_CONTAINER(p->window), p->box);
    /* 装配期就已经 set_menu 过：这时把菜单栏建出来（运行期再改的走 g_idle_add 到本线程）*/
    if (h->pending_menu_text && h->pending_menu_text[0]) {
        menu_apply_wire(h, p, h->pending_menu_text);
    }
    gtk_widget_show_all(p->window);
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
    p->menubar = NULL;
    menu_clear_slots(p); /* 槽里的 app_id 是我们 malloc 的，跟平台状态一起收 */
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
    gtk_box_pack_start(GTK_BOX(p->box), p->menubar, FALSE, FALSE, 0);
    gtk_box_reorder_child(GTK_BOX(p->box), p->menubar, 0); /* 菜单栏必须在 view 之上 */
    gtk_widget_show_all(p->menubar);
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

int cj_plat_host_capabilities(cj_host *h) {
    (void)h;
    /* 本平台的静态能力：菜单栏已落地（GTK 的菜单栏不需要可选依赖）；托盘 / 拖放到 7.B / 7.C */
    return CJ_CAP_MENU;
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
