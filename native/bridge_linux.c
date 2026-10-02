/*
 * cj-tauri C 桥：在原生 pthread 中运行 GTK/WebKit（Linux 桌面 WebView 宿主）
 *
 * 背景（关键）：仓颉 cjnative 的 main 运行在 M:N 轻量级线程的堆上协程栈，
 * JSC 的 sanitizeStackForVM 用 pthread 栈边界校验 SP 会失败并 abort。
 * 因此 GTK/WebKit 全部调用必须留在本文件创建的原生 pthread（标准 8MB 栈）内，
 * 仓颉侧经 FFI 与本桥交互，消息回调经 CFunc 回到仓颉。
 *
 * 编译：
 *   gcc -shared -fPIC -fstack-protector-all bridge.c -o libcjtbridge.so \
 *       $(pkg-config --cflags --libs webkit2gtk-4.1)
 */
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ===== 仓颉侧回调（@C 函数）===== */
typedef void (*cj_on_message_fn)(const char *json); /* JS 消息到达 */
typedef void (*cj_on_destroy_fn)(void);             /* 窗口销毁 */
typedef void (*cj_on_dialog_fn)(const char *path);  /* 原生对话框选中的路径 */

static cj_on_message_fn g_on_message = NULL;
static cj_on_destroy_fn g_on_destroy = NULL;
static cj_on_dialog_fn g_on_dialog = NULL;
static GtkWidget *g_window = NULL;
static GtkWidget *g_view = NULL;
static char *g_pending_html = NULL;
/* 页面来源二选一：cj_bridge_load_url 设 URL，cj_bridge_start 设 HTML；两者都设时 URL 优先 */
static char *g_pending_url = NULL;
static pthread_mutex_t g_js_mutex = PTHREAD_MUTEX_INITIALIZER;

/* 前端 __CJ_TAURI__.reload() 的控制消息：宿主级操作，不经过 IPC hub（与 BRIDGE_JS 里的字面量保持一致） */
#define CJT_RELOAD_MSG "__cj_tauri_reload__"

/* JS 投递队列（FIFO）：每条 JS 独立执行，防止覆盖 */
typedef struct js_node {
    char *js;
    struct js_node *next;
} js_node;
static js_node *g_js_head = NULL;
static js_node *g_js_tail = NULL;
static int g_ready = 0;
static volatile int g_should_quit = 0;

/* 窗口配置：由仓颉侧在 cj_bridge_start 之前经 cj_bridge_set_window 注入 */
static char *g_win_title = NULL;
static int g_win_w = 900;
static int g_win_h = 640;
/* 窗口图标路径（cj_bridge_set_icon 注入；NULL = 系统默认图标） */
static char *g_win_icon = NULL;
static int g_devtools = 1; /* 开发者工具开关（cj_bridge_set_devtools） */

/* 预执行脚本列表（cj_bridge_add_init_script 追加，WebView 创建时逐条注入到 document-start）：
   插件的 jsShim 走这条通道，注册顺序排在 BRIDGE_JS 之后——脚本里可直接引用 window.__CJ_TAURI__ */
static char **g_init_scripts = NULL;
static int g_init_script_count = 0;
static int g_init_script_cap = 0;

/* ===== 仓颉 → C 桥 ===== */

void cj_bridge_init(cj_on_message_fn m, cj_on_destroy_fn d) {
    g_on_message = m;
    g_on_destroy = d;
}

/* 窗口图标（png/ico 路径）：必须在 cj_bridge_start 之前调用；空路径 = 系统默认图标 */
void cj_bridge_set_icon(const char *path) {
    fprintf(stderr, "[cj-bridge] set icon: path=%s\n", (path && path[0]) ? path : "(default)");
    free(g_win_icon);
    g_win_icon = NULL;
    if (path && path[0]) {
        g_win_icon = strdup(path);
    }
}

/* 开发者工具开关：enabled=0 表示禁止打开（须在 cj_bridge_start 之前调用） */
void cj_bridge_set_devtools(int enabled) {
    g_devtools = enabled ? 1 : 0;
    fprintf(stderr, "[cj-bridge] devtools %s\n", g_devtools ? "enabled" : "disabled");
}

/* 注册一段预执行脚本（须在 cj_bridge_start 之前调用；空串忽略），与 Windows 侧同名同签名。
   为什么在桥里排队、而不是仓颉侧把 JS 拼进 HTML：URL 页面（runUrl / dev server）的 HTML 不在本进程，
   拼不进去；document-start 注入对 HTML / URL 两种来源都成立（RFC §5.4 的 v2 方案）。 */
void cj_bridge_add_init_script(const char *js) {
    if (!js || !js[0]) {
        return;
    }
    if (g_init_script_count == g_init_script_cap) {
        int cap = g_init_script_cap ? g_init_script_cap * 2 : 4;
        char **grown = (char **)realloc(g_init_scripts, (size_t)cap * sizeof(char *));
        if (!grown) {
            fprintf(stderr, "[cj-bridge] add init script failed: out of memory\n");
            return;
        }
        g_init_scripts = grown;
        g_init_script_cap = cap;
    }
    g_init_scripts[g_init_script_count] = strdup(js);
    g_init_script_count++;
    fprintf(stderr, "[cj-bridge] init script queued: %d bytes (total %d)\n",
            (int)strlen(js), g_init_script_count);
}

/* 运行时打开开发者工具：投递到 GTK 线程执行（仓颉线程禁止直接调 webkit） */
static gboolean open_devtools_idle(gpointer d) {
    if (g_view) {
        WebKitWebInspector *insp = webkit_web_view_get_inspector(WEBKIT_WEB_VIEW(g_view));
        if (insp) {
            webkit_web_inspector_show(insp);
        }
    }
    return FALSE;
}

void cj_bridge_open_devtools(void) {
    g_idle_add(open_devtools_idle, NULL);
}

/* 运行期切页面 / 重载：投递到 GTK 线程（仓颉线程禁止直接调 webkit） */
static gboolean load_url_idle(gpointer d) {
    char *url = (char *)d;
    if (g_view && url) {
        webkit_web_view_load_uri(WEBKIT_WEB_VIEW(g_view), url);
    }
    free(url);
    return FALSE;
}

static gboolean reload_idle(gpointer d) {
    if (g_view) {
        webkit_web_view_reload(WEBKIT_WEB_VIEW(g_view));
    }
    return FALSE;
}

/* 按 URL 加载页面（http(s):// 或 file://）：
 *   - cj_bridge_start 之前调用：只记下 URL，宿主就绪时加载（与 HTML 二选一，URL 优先）；
 *   - 启动之后调用：投递到 GTK 线程重新导航（运行期切页面）。
 * 空 URL 忽略。 */
void cj_bridge_load_url(const char *url) {
    if (!url || !url[0]) {
        return;
    }
    free(g_pending_url);
    g_pending_url = strdup(url);
    fprintf(stderr, "[cj-bridge] load url: %s\n", url);
    if (g_view) {
        g_idle_add(load_url_idle, strdup(url));
    }
}

/* 重新加载当前页面：投递到 GTK 线程执行 */
void cj_bridge_reload(void) {
    g_idle_add(reload_idle, NULL);
}

/* ===== 原生对话框（仓颉线程 → GTK 线程：g_idle_add 投递 + 条件变量等结果）=====
 * 对话框必须在 GTK 线程弹出（仓颉线程禁止直接调 GTK），而命令处理器要拿同步结果，
 * 所以调用方投递后阻塞等待：GTK 线程弹完对话框，先把结果经 g_on_dialog 送回仓颉，
 * 再唤醒调用方——顺序反了调用方会读到上一次的旧值。 */

typedef struct dlg_req {
    int kind;      /* 0 打开文件 1 保存文件 2 info 3 warning 4 error 5 confirm */
    char *title;
    char *message;
    char *filter;  /* "描述|模式|描述|模式"；空串 = 不过滤 */
    char *path;    /* 文件类结果：选中路径（取消时为空） */
    int ok;        /* 1 = 用户点了确认 */
} dlg_req;

static pthread_mutex_t g_dlg_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_dlg_cond = PTHREAD_COND_INITIALIZER;
static int g_dlg_busy = 0;      /* 同时只允许一个：对话框是模态的，嵌套调用直接拒绝而不是自锁 */
static int g_dlg_ready = 0;     /* 结果就绪（与 g_dlg_mutex 配套的谓词） */
static dlg_req *g_dlg_cur = NULL; /* 进行中的请求；窗口先关时由 cancel_pending_dialog 作废 */
static pthread_t g_gtk_thread;    /* 跑 gtk_main 的线程：用来判断调用方是否已在 GTK 线程上 */
static int g_gtk_thread_set = 0;

/* "描述|模式|..." → GTK 过滤器（与 Win32 OPENFILENAME 用同一套写法） */
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
            break;  /* 落单的描述段：忽略 */
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

/* 窗口销毁时作废进行中的对话框：不这么做，gtk_main_quit 之后等待方会永远挂住 */
static void cancel_pending_dialog(void) {
    pthread_mutex_lock(&g_dlg_mutex);
    if (g_dlg_cur && !g_dlg_ready) {
        g_dlg_cur->ok = 0;
        g_dlg_ready = 1;
        g_dlg_cur = NULL;
        pthread_cond_signal(&g_dlg_cond);
    }
    pthread_mutex_unlock(&g_dlg_mutex);
}

/* 已经站在 GTK 线程上：直接弹一次，返回 1 = 确认；选中路径写入 *out_path（由调用方 free） */
static int show_dialog_here(int kind, const char *title, const char *message, const char *filter,
                            char **out_path) {
    GtkWindow *parent = g_window ? GTK_WINDOW(g_window) : NULL;
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

/* GTK 线程：处理别的线程投递进来的请求（调用方正阻塞等结果） */
static gboolean dialog_idle(gpointer d) {
    dlg_req *r = (dlg_req *)d;
    int alive;

    pthread_mutex_lock(&g_dlg_mutex);
    alive = (g_dlg_cur == r);
    pthread_mutex_unlock(&g_dlg_mutex);
    if (!alive) {
        /* 窗口先关了，结果槽位已交回调用方（它会 free 这个请求）：这里连碰都不能碰 */
        return G_SOURCE_REMOVE;
    }

    r->ok = show_dialog_here(r->kind, r->title, r->message, r->filter, &r->path);
    fprintf(stderr, "[cj-bridge] dialog closed: kind=%d ok=%d%s%s\n", r->kind, r->ok,
            (r->kind <= 1) ? " path=" : "",
            (r->kind <= 1) ? (r->path ? r->path : "(none)") : "");
    if (g_on_dialog) {
        g_on_dialog(r->path ? r->path : "");
    }
    pthread_mutex_lock(&g_dlg_mutex);
    g_dlg_cur = NULL;
    g_dlg_ready = 1;
    pthread_cond_signal(&g_dlg_cond);
    pthread_mutex_unlock(&g_dlg_mutex);
    return G_SOURCE_REMOVE;
}

void cj_bridge_set_dialog_callback(cj_on_dialog_fn cb) {
    g_on_dialog = cb;
}

/* 阻塞式原生对话框：返回 1 = 用户确认（文件类路径已经回调送回），0 = 取消 / 宿主未就绪 */
int cj_bridge_show_dialog(int kind, const char *title, const char *message, const char *filter) {
    dlg_req *r;
    int ok;

    if (!g_ready || !g_window) {
        fprintf(stderr, "[cj-bridge] dialog ignored: host not ready\n");
        return 0;
    }
    pthread_mutex_lock(&g_dlg_mutex);
    if (g_dlg_busy) {
        pthread_mutex_unlock(&g_dlg_mutex);
        fprintf(stderr, "[cj-bridge] dialog rejected: another dialog is open\n");
        return 0;
    }
    g_dlg_busy = 1;
    g_dlg_ready = 0;
    pthread_mutex_unlock(&g_dlg_mutex);

    /* 调用方已经在 GTK 线程上（WebKit 的 script-message 回调就跑在这个线程）：直接弹。
       这里**不能**走「投递 idle + 阻塞等待」——idle 要由 GTK 线程来跑，而 GTK 线程正卡在
       这次调用里，等于自己把自己锁死（实测：日志停在 dialog: kind=…，对话框永不出现）。 */
    if (g_gtk_thread_set && pthread_equal(pthread_self(), g_gtk_thread)) {
        char *path = NULL;
        fprintf(stderr, "[cj-bridge] dialog: kind=%d title=%s (caller on GTK thread)\n", kind,
                title ? title : "");
        ok = show_dialog_here(kind, title ? title : "", message ? message : "",
                              filter ? filter : "", &path);
        fprintf(stderr, "[cj-bridge] dialog closed: kind=%d ok=%d%s%s\n", kind, ok,
                (kind <= 1) ? " path=" : "", (kind <= 1) ? (path ? path : "(none)") : "");
        if (g_on_dialog) {
            g_on_dialog(path ? path : "");
        }
        free(path);
        pthread_mutex_lock(&g_dlg_mutex);
        g_dlg_busy = 0;
        pthread_mutex_unlock(&g_dlg_mutex);
        return ok;
    }

    r = (dlg_req *)calloc(1, sizeof(dlg_req));
    if (!r) {
        pthread_mutex_lock(&g_dlg_mutex);
        g_dlg_busy = 0;
        pthread_mutex_unlock(&g_dlg_mutex);
        return 0;
    }
    r->kind = kind;
    r->title = strdup(title ? title : "");
    r->message = strdup(message ? message : "");
    r->filter = strdup(filter ? filter : "");
    fprintf(stderr, "[cj-bridge] dialog: kind=%d title=%s\n", kind, r->title);

    pthread_mutex_lock(&g_dlg_mutex);
    g_dlg_cur = r;
    pthread_mutex_unlock(&g_dlg_mutex);
    g_idle_add(dialog_idle, r);

    pthread_mutex_lock(&g_dlg_mutex);
    while (!g_dlg_ready) {
        pthread_cond_wait(&g_dlg_cond, &g_dlg_mutex);
    }
    ok = r->ok;
    g_dlg_busy = 0;
    pthread_mutex_unlock(&g_dlg_mutex);

    free(r->title);
    free(r->message);
    free(r->filter);
    free(r->path);
    free(r);
    return ok;
}

/* 窗口配置（标题 / 尺寸）：必须在 cj_bridge_start 之前调用 */
void cj_bridge_set_window(const char *title, int width, int height) {
    fprintf(stderr, "[cj-bridge] set window: title=%s size=%dx%d\n",
            title ? title : "(default)", width, height);
    if (g_win_title) {
        free(g_win_title);
        g_win_title = NULL;
    }
    if (title) {
        g_win_title = strdup(title);
    }
    if (width > 0) g_win_w = width;
    if (height > 0) g_win_h = height;
}

/* 回投结果校验：这条 eval 是「仓颉 → 前端」的唯一出口，静默失败会让前端 promise 永久 pending。
   Windows 侧有 log_hr("ExecuteScript", …) 兜同一件事，此前 Linux 完全不看结果（两平台不对称）。 */
static void on_js_done(GObject *src, GAsyncResult *res, gpointer ud) {
    GError *err = NULL;
    WebKitJavascriptResult *r = webkit_web_view_run_javascript_finish(WEBKIT_WEB_VIEW(src), res, &err);
    if (r) {
        g_object_unref(r);  /* 每次回投都会新建一个结果对象，不看也要释放 */
    }
    if (err) {
        fprintf(stderr, "[cj-bridge] run js failed: %s\n", err->message);
        g_error_free(err);
    }
}

/* 单批上限：一次 idle 最多合并多少条回投。写成常量而不是「取空为止」，
   是为了长队列也肯让出 UI 线程（剩下的由自续 idle 接手）。 */
#define CJ_JS_BATCH_MAX 64

/* 原生 → JS：把脚本投递到 GTK 线程执行（仓颉线程禁止直接调 webkit）。
   一次 idle 取走队列里最多 CJ_JS_BATCH_MAX 条、拼成一段脚本只执行一次：
   eval 的固定开销（跨语言进 JS 引擎 + 启动一次脚本）是这里的成本大头，N 条合并即省掉 N-1 次。
   队里只有一条时走快路径（直接用它自己的字符串，不拼批）：「一次往返一条响应」是最常见形态，
   拼批那点拷贝在顺序往返上是白花，实测会让它慢几个百分点。
   每条脚本自带分号，拼接靠换行分隔；一条语句运行时报错不会中断后续语句（只有语法错会整批失败，
   真出这种错由 on_js_done 打日志兜底）。 */
static gboolean flush_pending_js(gpointer d) {
    char *single = NULL;   /* 快路径专用：非空表示这次就投这一条 */
    GString *script = NULL;
    int n = 0;
    pthread_mutex_lock(&g_js_mutex);
    if (g_js_head) {
        js_node *node = g_js_head;
        g_js_head = node->next;
        if (!g_js_head) g_js_tail = NULL;
        if (g_js_head) {
            /* 后面还有第二条 → 拼批：这条当批头，剩下的在同一把锁里收完 */
            script = g_string_new(node->js);
            g_string_append_c(script, '\n');
            n = 1;
            while (g_js_head && n < CJ_JS_BATCH_MAX) {
                js_node *next = g_js_head;
                g_js_head = next->next;
                if (!g_js_head) g_js_tail = NULL;
                g_string_append(script, next->js);
                g_string_append_c(script, '\n');
                free(next->js);
                free(next);
                n++;
            }
        } else {
            single = node->js;   /* 接管字符串所有权，省掉一次拷贝 */
            node->js = NULL;
        }
        free(node->js);
        free(node);
    }
    int more = (g_js_head != NULL);
    pthread_mutex_unlock(&g_js_mutex);
    /* 注意快路径下 n 仍是 0（那条不算进批量），守卫必须把 single 一起放进来 */
    if ((single || n > 0) && g_view) {
        webkit_web_view_run_javascript(WEBKIT_WEB_VIEW(g_view),
                                       single ? single : script->str, NULL, on_js_done, NULL);
    }
    free(single);
    if (script) g_string_free(script, TRUE);
    /* 队列没取空就再挂一次 idle 自续 */
    if (more) g_idle_add(flush_pending_js, NULL);
    return G_SOURCE_REMOVE;
}

void cj_bridge_run_js(const char *js) {
    if (!js) return;
    js_node *node = (js_node *)calloc(1, sizeof(js_node));
    node->js = strdup(js);
    pthread_mutex_lock(&g_js_mutex);
    if (g_js_tail) {
        g_js_tail->next = node;
    } else {
        g_js_head = node;
    }
    g_js_tail = node;
    int wasEmpty = (g_js_head == node);
    pthread_mutex_unlock(&g_js_mutex);
    if (g_view && wasEmpty) {
        g_idle_add(flush_pending_js, NULL);
    }
}

void cj_bridge_quit(void) {
    g_should_quit = 1;
    if (g_window) {
        gtk_main_quit();
    }
}

/* ===== GTK 线程 ===== */

static void on_load_changed(WebKitWebView *wv, WebKitLoadEvent ev, gpointer ud) {
    /* no-op */
}

static void on_script_message(WebKitUserContentManager *mgr,
                              WebKitJavascriptResult *result, gpointer ud) {
    JSCValue *v = webkit_javascript_result_get_js_value(result);
    char *s = jsc_value_to_string(v);
    /* 前端 __CJ_TAURI__.reload()：宿主控制消息，不进 IPC hub */
    if (s && strcmp(s, CJT_RELOAD_MSG) == 0) {
        fprintf(stderr, "[cj-bridge] frontend requested reload\n");
        g_idle_add(reload_idle, NULL);
        g_free(s);
        return;
    }
    /* 入站日志：与 Windows 侧同一格式（bridge_win.c 的 js -> native (%d bytes)）。
       此前只有 Windows 打这行，端到端取证时两平台不对称（AGENTS.md §1 的交付凭证就看它）。 */
    fprintf(stderr, "[cj-bridge] js -> native (%d bytes)\n", (int)strlen(s ? s : ""));
    if (g_on_message) {
        g_on_message(s);
    }
    g_free(s);
}

static void on_destroy(GtkWidget *w, gpointer ud) {
    g_should_quit = 1;
    if (g_on_destroy) {
        g_on_destroy();
    }
    /* 有对话框开着时先作废并唤醒等待方：gtk_main_quit 之后挂起的 idle 不再执行 */
    cancel_pending_dialog();
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
    /* 先记下 GTK 线程身份：对话框要靠它判断「调用方是不是已经在本线程上」 */
    g_gtk_thread = pthread_self();
    g_gtk_thread_set = 1;
    gtk_init(NULL, NULL);

    g_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(g_window), g_win_title ? g_win_title : "cj-tauri");
    gtk_window_set_default_size(GTK_WINDOW(g_window), g_win_w, g_win_h);
    /* 窗口图标：失败只意味着用系统默认图标，不阻断启动（GTK 的 err 要自己释放） */
    if (g_win_icon) {
        GError *icon_err = NULL;
        gboolean icon_ok = gtk_window_set_icon_from_file(GTK_WINDOW(g_window), g_win_icon, &icon_err);
        fprintf(stderr, "[cj-bridge] window icon: path=%s ok=%d%s%s\n",
                g_win_icon, icon_ok ? 1 : 0,
                icon_err ? " err=" : "", icon_err ? icon_err->message : "");
        if (icon_err) g_error_free(icon_err);
    }
    g_signal_connect(g_window, "destroy", G_CALLBACK(on_destroy), NULL);

    /* 注入时机与 Windows 侧对齐：那边是 AddScriptToExecuteOnDocumentCreated（页面脚本执行前）。
       这里原先用 AT_DOCUMENT_END，会让发行态单文件里的内联 <script type="module"> 抢在注入之前执行
       —— 前端在模块作用域 / onMounted 直接读 window.__CJ_TAURI__ 会拿到 undefined
       （开发态从 URL 加载、模块要现下载，反而掩盖了这个竞态）。所以必须 document-start。 */
    WebKitUserContentManager *mgr = webkit_user_content_manager_new();
    webkit_user_content_manager_add_script(
        mgr,
        webkit_user_script_new(BRIDGE_JS,
                               WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                               WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
                               NULL, NULL));
    /* 预执行脚本按注册顺序追加在桥之后（同一 document-start 通道，脚本里可直接用 window.__CJ_TAURI__） */
    for (int i = 0; i < g_init_script_count; i++) {
        webkit_user_content_manager_add_script(
            mgr,
            webkit_user_script_new(g_init_scripts[i],
                                   WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                                   WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
                                   NULL, NULL));
    }
    fprintf(stderr, "[cj-bridge] init scripts injected: %d\n", g_init_script_count);
    webkit_user_content_manager_register_script_message_handler(mgr, "cjtauri");
    g_signal_connect(mgr, "script-message-received::cjtauri",
                     G_CALLBACK(on_script_message), NULL);

    g_view = webkit_web_view_new_with_user_content_manager(mgr);
    {
        /* 开发者工具开关：settings 交由视图持有（单实例、随窗口存续，不再额外 unref） */
        WebKitSettings *settings = webkit_settings_new();
        webkit_settings_set_enable_developer_extras(settings, g_devtools ? TRUE : FALSE);
        webkit_web_view_set_settings(WEBKIT_WEB_VIEW(g_view), settings);
    }
    g_signal_connect(g_view, "load-changed", G_CALLBACK(on_load_changed), NULL);
    gtk_container_add(GTK_CONTAINER(g_window), g_view);
    gtk_widget_show_all(g_window);
    g_ready = 1;

    /* 页面来源：URL 优先（cj_bridge_load_url），否则内联 HTML（cj_bridge_start） */
    if (g_pending_url) {
        webkit_web_view_load_uri(WEBKIT_WEB_VIEW(g_view), g_pending_url);
    } else if (g_pending_html) {
        webkit_web_view_load_html(WEBKIT_WEB_VIEW(g_view), g_pending_html, NULL);
    }

    gtk_main();

    /* 主循环退出：确保窗口清理后返回 */
    if (g_view) {
        g_object_unref(g_view);
        g_view = NULL;
    }
    if (g_window) {
        gtk_widget_destroy(g_window);
        g_window = NULL;
    }
    return NULL;
}

void cj_bridge_start(const char *html) {
    if (html && html[0]) { /* 空串表示「页面由 cj_bridge_load_url 指定」 */
        free(g_pending_html);
        g_pending_html = strdup(html);
    }
    pthread_t t;
    pthread_create(&t, NULL, gtk_thread_main, NULL);
    pthread_detach(t);
}

int cj_bridge_is_ready(void) {
    return g_ready;
}

/* 宿主事件循环是否已退出（窗口关闭 / quit），供仓颉侧 app.run 阻塞等待 */
int cj_bridge_should_quit(void) {
    return g_should_quit;
}
