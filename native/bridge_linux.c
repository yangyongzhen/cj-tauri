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

static cj_on_message_fn g_on_message = NULL;
static cj_on_destroy_fn g_on_destroy = NULL;
static GtkWidget *g_window = NULL;
static GtkWidget *g_view = NULL;
static char *g_pending_html = NULL;
static pthread_mutex_t g_js_mutex = PTHREAD_MUTEX_INITIALIZER;

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
static int g_devtools = 1; /* 开发者工具开关（cj_bridge_set_devtools） */

/* ===== 仓颉 → C 桥 ===== */

void cj_bridge_init(cj_on_message_fn m, cj_on_destroy_fn d) {
    g_on_message = m;
    g_on_destroy = d;
}

/* 开发者工具开关：enabled=0 表示禁止打开（须在 cj_bridge_start 之前调用） */
void cj_bridge_set_devtools(int enabled) {
    g_devtools = enabled ? 1 : 0;
    fprintf(stderr, "[cj-bridge] devtools %s\n", g_devtools ? "enabled" : "disabled");
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

/* 原生 → JS：把脚本投递到 GTK 线程执行（仓颉线程禁止直接调 webkit） */
static gboolean flush_pending_js(gpointer d) {
    js_node *node = NULL;
    pthread_mutex_lock(&g_js_mutex);
    if (g_js_head) {
        node = g_js_head;
        g_js_head = g_js_head->next;
        if (!g_js_head) g_js_tail = NULL;
    }
    pthread_mutex_unlock(&g_js_mutex);
    if (node) {
        if (g_view) {
            webkit_web_view_run_javascript(WEBKIT_WEB_VIEW(g_view), node->js, NULL, NULL, NULL);
        }
        free(node->js);
        free(node);
        /* 若队列仍有剩余，继续调度 */
        pthread_mutex_lock(&g_js_mutex);
        int more = (g_js_head != NULL);
        pthread_mutex_unlock(&g_js_mutex);
        if (more) g_idle_add(flush_pending_js, NULL);
    }
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
    gtk_main_quit();
}

/* 注入前端桥接脚本：暴露 window.__CJ_TAURI__ */
static const char *BRIDGE_JS =
    "window.__CJ_TAURI__ = (function () {"
    "  var seq = 0;"
    "  var pending = {};"
    "  var listeners = {};"
    "  function post(obj) {"
    "    window.webkit.messageHandlers.cjtauri.postMessage(JSON.stringify(obj));"
    "  }"
    "  return {"
    "    invoke: function (cmd, args) {"
    "      var id = ++seq;"
    "      var p = new Promise(function (resolve, reject) { pending[id] = { resolve: resolve, reject: reject }; });"
    "      post({ type: 'invoke', id: id, cmd: cmd, args: args || {} });"
    "      return p;"
    "    },"
    "    listen: function (event, cb) {"
    "      if (!listeners[event]) listeners[event] = [];"
    "      listeners[event].push(cb);"
    "      return function () {"
    "        var arr = listeners[event] || [];"
    "        var i = arr.indexOf(cb);"
    "        if (i >= 0) arr.splice(i, 1);"
    "      };"
    "    },"
    "    emit: function (event, payload) {"
    "      post({ type: 'emit', event: event, payload: payload || {} });"
    "    },"
    "    _dispatch: function (msg) {"
    "      if (!msg) return;"
    "      if (msg.type === 'resolve') {"
    "        var p = pending[msg.id];"
    "        if (!p) return;"
    "        delete pending[msg.id];"
    "        if (msg.ok) p.resolve(msg.data); else p.reject(new Error(msg.error || 'invoke failed'));"
    "      } else if (msg.type === 'event') {"
    "        var arr = listeners[msg.event] || [];"
    "        for (var i = 0; i < arr.length; i++) arr[i](msg.payload);"
    "      }"
    "    }"
    "  };"
    "})();"
    "window.addEventListener('message', function (e) {"
    "  var msg = e.data;"
    "  if (typeof msg === 'string') { try { msg = JSON.parse(msg); } catch (err) { return; } }"
    "  window.__CJ_TAURI__._dispatch(msg);"
    "});";

static void *gtk_thread_main(void *arg) {
    gtk_init(NULL, NULL);

    g_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(g_window), g_win_title ? g_win_title : "cj-tauri");
    gtk_window_set_default_size(GTK_WINDOW(g_window), g_win_w, g_win_h);
    g_signal_connect(g_window, "destroy", G_CALLBACK(on_destroy), NULL);

    WebKitUserContentManager *mgr = webkit_user_content_manager_new();
    webkit_user_content_manager_add_script(
        mgr,
        webkit_user_script_new(BRIDGE_JS,
                               WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                               WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END,
                               NULL, NULL));
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

    if (g_pending_html) {
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
    if (html) {
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
