/*
 * 多窗口可行性最小对照（纯 GTK / GTK+WebKit；无仓颉、无 cj-tauri 代码）
 *
 * 用途：把 docs/架构演进-多平台与多窗口.md §8 的结论做成可复跑的复现器。
 *
 *   用法: gtk_threading_probe <N> [--webkit] [--stagger-ms N]
 *     N=1                → exit=0（基线）
 *     N=2（纯 GTK）       → exit=0：GTK 本身不反对两条各自的 gtk_main
 *     N=2 --webkit       → **不可用**：实测 8/8 致命失败（多数 exit=139 SIGSEGV +
 *                          Gtk-CRITICAL；早先 /tmp 变体是 exit=134 abort；也可能表现为
 *                          线程卡在 gtk_init 里 → main 超时给 exit=3）
 *
 * 退出码：0 = N 个窗口都起来且无迟到崩溃；3 = 超时（有窗口没起来）；134/139 = 被信号打死。
 *
 * 线程一律**串行起**（默认纯 GTK 300ms、带 WebKit 1500ms）：串行也逃不掉（8/8），
 * 所以既不是单纯的「初始化撞车」，也不是靠时序能回避的竞态——一个进程里两个
 * WebKitWebView 分处两条线程就是不被支持的用法。
 *
 * 编译 / 跑法见 scripts/test-gtk-threading.sh（本文件不会被 cjpm 编译，纯 C 小程序）。
 */
#include <gtk/gtk.h>

#ifdef CJ_GTK_PROBE_WITH_WEBKIT
#include <webkit2/webkit2.h>
#endif

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct worker_arg {
    int idx;
    int use_webkit;
} worker_arg;

/* 已经「窗口建好、进了 gtk_main」的线程数。主线程靠它判成败——不能只 sleep 完就 return：
   线程卡在 gtk_init 里没出来时，主线程照样返回 0，那会把「卡死」误报成干净退出（本探针首版
   就踩过这个坑：日志里没有 window up 行，退出码却是 0）。 */
static volatile int g_windows_up = 0;

static gboolean tick(gpointer d) {
    fprintf(stderr, "[gtkprobe] window %ld alive\n", (long)(intptr_t)d);
    return G_SOURCE_CONTINUE;
}

#ifdef CJ_GTK_PROBE_WITH_WEBKIT
static void on_load(WebKitWebView *view, WebKitLoadEvent ev, gpointer d) {
    (void)view;
    fprintf(stderr, "[gtkprobe] window %ld load event=%d\n", (long)(intptr_t)d, (int)ev);
}
#endif

static void *worker(void *arg) {
    worker_arg *wa = (worker_arg *)arg;
    GtkWidget *w;
    GtkWidget *view = NULL;
    char tmp[160];

    fprintf(stderr, "[gtkprobe] thread %d: gtk_init\n", wa->idx);
    gtk_init(NULL, NULL); /* 每条线程各初始化一次 GDK，与本项目的桥同构 */

    w = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    snprintf(tmp, sizeof(tmp), "gtkprobe %d", wa->idx);
    gtk_window_set_title(GTK_WINDOW(w), tmp);
    gtk_window_set_default_size(GTK_WINDOW(w), 400, 300);

    if (wa->use_webkit) {
#ifdef CJ_GTK_PROBE_WITH_WEBKIT
        view = webkit_web_view_new(); /* 默认 WebKitWebContext */
        gtk_container_add(GTK_CONTAINER(w), view);
        g_signal_connect(view, "load-changed", G_CALLBACK(on_load), (gpointer)(intptr_t)wa->idx);
#else
        fprintf(stderr, "[gtkprobe] 本二进制未编入 WebKit（--webkit 无效）\n");
        return NULL;
#endif
    }

    g_signal_connect(w, "destroy", G_CALLBACK(gtk_main_quit), NULL);
    gtk_widget_show_all(w);

    if (wa->use_webkit && view) {
#ifdef CJ_GTK_PROBE_WITH_WEBKIT
        snprintf(tmp, sizeof(tmp), "data:text/html,<h1>win %d</h1>", wa->idx);
        webkit_web_view_load_uri(WEBKIT_WEB_VIEW(view), tmp);
#endif
    }
    fprintf(stderr, "[gtkprobe] thread %d: window up, entering gtk_main\n", wa->idx);
    __sync_fetch_and_add(&g_windows_up, 1);
    g_timeout_add(500, tick, (gpointer)(intptr_t)wa->idx);
    gtk_main();
    fprintf(stderr, "[gtkprobe] thread %d: gtk_main returned\n", wa->idx);
    return NULL;
}

int main(int argc, char **argv) {
    int n = 1;
    int use_webkit = 0;
    int stagger_ms = 300;
    int i;
    pthread_t t[8];
    worker_arg args[8];

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--webkit") == 0) {
            use_webkit = 1;
        } else if (strcmp(argv[i], "--stagger-ms") == 0 && i + 1 < argc) {
            stagger_ms = atoi(argv[++i]);
        } else {
            n = atoi(argv[i]);
        }
    }
    if (n < 1) n = 1;
    if (n > 8) n = 8;
    if (use_webkit && stagger_ms == 300) stagger_ms = 1500; /* WebKit 起视图更慢，给它更多余量 */

    fprintf(stderr, "[gtkprobe] creating %d thread(s) use_webkit=%d stagger=%dms\n",
            n, use_webkit, stagger_ms);
    for (i = 0; i < n; i++) {
        args[i].idx = i;
        args[i].use_webkit = use_webkit;
        pthread_create(&t[i], NULL, worker, &args[i]);
        usleep(stagger_ms * 1000);
    }
    {
        int waited = 0;
        while (g_windows_up < n && waited < 8000) {
            usleep(100000);
            waited += 100;
        }
        if (g_windows_up < n) {
            fprintf(stderr, "[gtkprobe] 超时：只有 %d/%d 个窗口起来了（线程卡在初始化里）\n",
                    g_windows_up, n);
            return 3; /* 独立退出码，别和 SIGSEGV/abort 混为一谈 */
        }
        fprintf(stderr, "[gtkprobe] %d 个窗口都起来了，再观察 3s（抓迟到的崩溃）\n", n);
        sleep(3);
    }
    fprintf(stderr, "[gtkprobe] main: 正常退出\n");
    return 0;
}
