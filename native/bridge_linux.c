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
#include "bridge_core.h"

/* ===== 每个宿主的平台私有状态 =====
   原先是一堆进程级单例（g_window / g_view / g_gtk_thread …）：多窗口一落地就互相覆盖，
   而且「哪个窗口」这件事在 ABI 上根本传不进来。现在挂在自己的 cj_host->plat 上，
   平台函数一律从入参句柄取状态——平台原语只认句柄，不看全局。 */
typedef struct plat_host {
    GtkWidget *window;  /* 主窗口；窗口销毁时置空（含用户关窗路径）*/
    GtkWidget *view;    /* WebKitWebView；宿主线程收尾时 unref 并置空 */
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
    gtk_container_add(GTK_CONTAINER(p->window), p->view);
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
