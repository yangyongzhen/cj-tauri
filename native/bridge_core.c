/*
 * cj-tauri C 桥公共核心（批次 1）：句柄化的宿主状态 + 平台无关逻辑
 *
 * 契约见 native/bridge_core.h。本文件只放「两平台逐字相同」的东西：
 *   回投队列与批处理（含单条快路径）、对话框单槽状态机、窗口配置与预执行脚本存储、
 *   生命周期标志、以及**全部 cj_bridge_* 导出**（单一来源，两平台导出一致由此保证）。
 * 任何平台能力都经 cj_plat_*，本文件不 include 任何平台头。
 */
#include "bridge_core.h"

/* ===== 内部小工具 ===== */

static char *cj_strdup(const char *s) {
    size_t n;
    char *p;
    if (!s) return NULL;
    n = strlen(s) + 1;
    p = (char *)malloc(n);
    if (!p) return NULL;
    memcpy(p, s, n);
    return p;
}

/* 回投队列整体释放（宿主销毁时兜底） */
static void cj_js_queue_free(cj_host *h) {
    js_node *n = h->js_head;
    while (n) {
        js_node *next = n->next;
        free(n->js);
        free(n);
        n = next;
    }
    h->js_head = NULL;
    h->js_tail = NULL;
}

/* ===== 建 / 释放宿主 ===== */

cj_host *cj_bridge_create(void) {
    cj_host *h = (cj_host *)calloc(1, sizeof(cj_host));
    if (!h) {
        fprintf(stderr, "[cj-bridge] create host failed: out of memory\n");
        return NULL;
    }
    /* 默认与两平台原先的静态初值一致 */
    h->win_w = 900;
    h->win_h = 640;
    h->devtools = 1;
    h->js_lock = cj_plat_sync_create();
    h->dlg_lock = cj_plat_sync_create();
    if (!h->js_lock || !h->dlg_lock) {
        if (h->js_lock) cj_plat_sync_destroy(h->js_lock);
        if (h->dlg_lock) cj_plat_sync_destroy(h->dlg_lock);
        free(h);
        fprintf(stderr, "[cj-bridge] create host failed: sync init failed\n");
        return NULL;
    }
    fprintf(stderr, "[cj-bridge] host created: %p\n", (void *)h);
    return h;
}

void cj_bridge_destroy(cj_host *h) {
    int i;
    if (!h) return;
    /* 平台资源先走：COM 环境引用 / 模块句柄等（幂等）。返回 0＝宿主线程还在收尾，
       它可能仍在用 h（GTK/WebView2 回调的 user_data 就是它）——这时连句柄一起留着不释放。 */
    if (!cj_plat_fini(h)) {
        fprintf(stderr, "[cj-bridge] destroy: host thread still running, handle kept\n");
        return;
    }
    if (h->js_lock) cj_plat_sync_destroy(h->js_lock);
    if (h->dlg_lock) cj_plat_sync_destroy(h->dlg_lock);
    cj_js_queue_free(h);
    /* dlg_cur 此时应为空：窗口销毁路径已作废并交了槽位；故意不碰，免得与等待方抢 free */
    free(h->win_title);
    free(h->win_icon);
    for (i = 0; i < h->init_script_count; i++) {
        free(h->init_scripts[i]);
    }
    free(h->init_scripts);
    free(h->pending_html);
    free(h->pending_url);
    fprintf(stderr, "[cj-bridge] host destroyed: %p\n", (void *)h);
    free(h);
}

void cj_bridge_init(cj_host *h, cj_on_message_fn m, cj_on_destroy_fn d) {
    if (!h) return;
    h->on_message = m;
    h->on_destroy = d;
    cj_plat_init(h); /* 平台一次性初始化（Windows 在这里装 COM vtbl 并打 init 日志） */
}

/* ===== 窗口配置 / 预执行脚本（必须在 cj_bridge_start 之前注入）===== */

void cj_bridge_set_window(cj_host *h, const char *title, int width, int height) {
    if (!h) return;
    fprintf(stderr, "[cj-bridge] set window: title=%s size=%dx%d\n",
            title ? title : "(default)", width, height);
    free(h->win_title);
    h->win_title = NULL;
    if (title) {
        h->win_title = cj_strdup(title);
    }
    if (width > 0) h->win_w = width;
    if (height > 0) h->win_h = height;
}

void cj_bridge_set_icon(cj_host *h, const char *path) {
    if (!h) return;
    fprintf(stderr, "[cj-bridge] set icon: path=%s\n", (path && path[0]) ? path : "(default)");
    free(h->win_icon);
    h->win_icon = NULL;
    if (path && path[0]) {
        h->win_icon = cj_strdup(path);
    }
}

void cj_bridge_set_devtools(cj_host *h, int enabled) {
    if (!h) return;
    h->devtools = enabled ? 1 : 0;
    fprintf(stderr, "[cj-bridge] devtools %s\n", h->devtools ? "enabled" : "disabled");
}

void cj_bridge_add_init_script(cj_host *h, const char *js) {
    if (!h || !js || !js[0]) {
        return;
    }
    if (h->init_script_count == h->init_script_cap) {
        int cap = h->init_script_cap ? h->init_script_cap * 2 : 4;
        char **grown = (char **)realloc(h->init_scripts, (size_t)cap * sizeof(char *));
        if (!grown) {
            fprintf(stderr, "[cj-bridge] add init script failed: out of memory\n");
            return;
        }
        h->init_scripts = grown;
        h->init_script_cap = cap;
    }
    h->init_scripts[h->init_script_count] = cj_strdup(js);
    if (!h->init_scripts[h->init_script_count]) {
        fprintf(stderr, "[cj-bridge] add init script failed: out of memory\n");
        return;
    }
    h->init_script_count++;
    fprintf(stderr, "[cj-bridge] init script queued: %d bytes (total %d)\n",
            (int)strlen(js), h->init_script_count);
}

/* ===== 运行期操作（投递细节留给平台：各平台的原生时机与日志口径不同）===== */

void cj_bridge_start(cj_host *h, const char *html) {
    if (!h) return;
    if (html && html[0]) { /* 空串表示「页面由 cj_bridge_load_url 指定」 */
        free(h->pending_html);
        h->pending_html = cj_strdup(html);
    }
    cj_plat_start(h);
}

void cj_bridge_load_url(cj_host *h, const char *url) {
    if (!h || !url || !url[0]) return;
    free(h->pending_url);
    h->pending_url = cj_strdup(url);
    cj_plat_load_url(h, url);
}

void cj_bridge_reload(cj_host *h) {
    if (!h) return;
    cj_plat_reload(h);
}

void cj_bridge_open_devtools(cj_host *h) {
    if (!h) return;
    cj_plat_open_devtools(h);
}

void cj_bridge_quit(cj_host *h) {
    if (!h) return;
    h->should_quit = 1;
    /* 平台走与「用户关窗」同一条销毁路径，onDestroy 因此恰好触发一次（批次 1 验收项） */
    cj_plat_quit(h);
}

/* ===== 原生 → JS：入队（执行在 UI 线程的 cj_core_flush_js 里）===== */

void cj_bridge_run_js(cj_host *h, const char *js) {
    js_node *node;
    int was_empty;
    if (!h || !js) return;
    node = (js_node *)calloc(1, sizeof(js_node));
    if (!node) return;
    node->js = cj_strdup(js);
    if (!node->js) {
        free(node);
        return;
    }
    if (!h->js_lock) {
        /* 未 init 时直接丢弃，避免未初始化锁 */
        free(node->js);
        free(node);
        return;
    }
    cj_plat_sync_lock(h->js_lock);
    if (h->js_tail) {
        h->js_tail->next = node;
    } else {
        h->js_head = node;
    }
    h->js_tail = node;
    was_empty = (h->js_head == node); /* 队列由空转非空：需要唤醒 UI 线程 */
    cj_plat_sync_unlock(h->js_lock);
    if (was_empty) {
        cj_plat_wake_ui(h); /* 平台自己判断窗口是否已就绪（未就绪就攒着） */
    }
}

int cj_bridge_is_ready(cj_host *h) {
    return h ? (int)h->ready : 0;
}

int cj_bridge_should_quit(cj_host *h) {
    return h ? (int)h->should_quit : 0;
}

/* ===== core 提供给平台的状态迁移 ===== */

void cj_core_set_ready(cj_host *h) {
    if (h) h->ready = 1;
}

void cj_core_window_destroyed(cj_host *h) {
    if (!h) return;
    h->window_gone = 1;
    h->should_quit = 1;
    /* 每个宿主恰好通知一次：无论是用户关窗还是 cj_bridge_quit，都汇到这条路径 */
    if (!h->destroy_notified) {
        h->destroy_notified = 1;
        if (h->on_destroy) {
            h->on_destroy();
        }
    }
    /* 有对话框开着时先作废并唤醒等待方：事件循环退出后挂起的回调不再执行，等待方会永远挂住 */
    cj_core_dialog_abort(h);
}

void cj_core_dialog_abort(cj_host *h) {
    if (!h || !h->dlg_lock) return;
    cj_plat_sync_lock(h->dlg_lock);
    if (h->dlg_cur && !h->dlg_ready) {
        h->dlg_cur->ok = 0;
        h->dlg_ready = 1;
        h->dlg_cur = NULL;
        cj_plat_sync_signal(h->dlg_lock);
    }
    cj_plat_sync_unlock(h->dlg_lock);
}

/* ===== 回投队列：一次空闲窗口拼批回投（UI 线程调用）===== */

void cj_core_flush_js(cj_host *h) {
    js_node *batch[CJ_JS_BATCH_MAX];
    char *single = NULL; /* 快路径：接管字符串所有权，省掉一次拷贝 */
    char *script = NULL;
    size_t len = 0;
    size_t cap = 0;
    int n = 0;
    int more = 0;
    int i, j;

    if (!h || !h->js_lock) return;

    cj_plat_sync_lock(h->js_lock);
    if (h->js_head) {
        js_node *node = h->js_head;
        h->js_head = node->next;
        if (!h->js_head) {
            h->js_tail = NULL;
            single = node->js; /* 队里只有这一条 */
            free(node);
        } else {
            batch[n++] = node;
            while (h->js_head && n < CJ_JS_BATCH_MAX) {
                node = h->js_head;
                h->js_head = node->next;
                if (!h->js_head) {
                    h->js_tail = NULL;
                }
                batch[n++] = node;
            }
        }
    }
    more = (h->js_head != NULL);
    cj_plat_sync_unlock(h->js_lock);

    if (single) {
        cj_plat_post_js(h, single);
        free(single);
    } else if (n > 0) {
        /* 拼批：一段脚本只跨一次语言边界，省掉 n-1 次固定开销。
           为什么不用 GString 之类的缓冲：core 不依赖平台库（glib / Win32）。 */
        for (i = 0; i < n; i++) {
            size_t nl = strlen(batch[i]->js);
            if (len + nl + 2 > cap) {
                size_t ncap = (len + nl + 2) * 2;
                char *grown = (char *)realloc(script, ncap);
                if (!grown) {
                    /* 内存不够：退回逐条执行——宁可多花开销，也不丢回投（回投丢了前端会一直 pending）*/
                    for (j = i; j < n; j++) {
                        cj_plat_post_js(h, batch[j]->js);
                    }
                    for (j = 0; j < n; j++) {
                        free(batch[j]->js);
                        free(batch[j]);
                    }
                    free(script);
                    if (more) cj_plat_wake_ui(h);
                    return;
                }
                script = grown;
                cap = ncap;
            }
            memcpy(script + len, batch[i]->js, nl);
            len += nl;
            script[len++] = '\n';
            script[len] = '\0';
            free(batch[i]->js);
            free(batch[i]);
        }
        cj_plat_post_js(h, script);
        free(script);
    }

    /* 队列没取空：自续一次，剩下的下一批走 */
    if (more) {
        cj_plat_wake_ui(h);
    }
}

/* ===== 原生对话框：单槽状态机（模态，同时只允许一个）===== */

static dlg_req *cj_dlg_req_new(int kind, const char *title, const char *message, const char *filter) {
    dlg_req *r = (dlg_req *)calloc(1, sizeof(dlg_req));
    if (!r) return NULL;
    r->kind = kind;
    r->title = cj_strdup(title ? title : "");
    r->message = cj_strdup(message ? message : "");
    r->filter = cj_strdup(filter ? filter : "");
    return r;
}

static void cj_dlg_req_free(dlg_req *r) {
    if (!r) return;
    free(r->title);
    free(r->message);
    free(r->filter);
    free(r->path);
    free(r);
}

static void cj_dlg_log_closed(const dlg_req *r) {
    if (r->kind == 0 || r->kind == 1) { /* 文件类才有路径 */
        fprintf(stderr, "[cj-bridge] dialog closed: kind=%d ok=%d path=%s\n",
                r->kind, r->ok, r->path ? r->path : "(none)");
    } else {
        fprintf(stderr, "[cj-bridge] dialog closed: kind=%d ok=%d\n", r->kind, r->ok);
    }
}

void cj_bridge_set_dialog_callback(cj_host *h, cj_on_dialog_fn cb) {
    if (!h) return;
    h->on_dialog = cb;
}

int cj_bridge_show_dialog(cj_host *h, int kind, const char *title,
                          const char *message, const char *filter) {
    dlg_req *r;
    int ok;

    if (!h) return 0;
    if (!h->ready) { /* 没有窗口就没有父窗口，模态对话框无处安放 */
        fprintf(stderr, "[cj-bridge] dialog ignored: host not ready\n");
        return 0;
    }

    cj_plat_sync_lock(h->dlg_lock);
    if (h->dlg_busy) {
        cj_plat_sync_unlock(h->dlg_lock);
        fprintf(stderr, "[cj-bridge] dialog rejected: another dialog is open\n");
        return 0;
    }
    h->dlg_busy = 1;
    h->dlg_ready = 0;
    cj_plat_sync_unlock(h->dlg_lock);

    /* 调用方已经站在 UI 线程上（WebKit 的 script-message / WebView2 的 WebMessageReceived 就跑在那里）：
       直接弹。这里**不能**走「投递 + 阻塞等待」——等待的事件得由 UI 线程处理，而 UI 线程正卡在这次调用里，
       等于自己把自己锁死。 */
    if (cj_plat_is_ui_thread(h)) {
        fprintf(stderr, "[cj-bridge] dialog: kind=%d title=%s (caller on ui thread)\n",
                kind, title ? title : "");
        r = cj_dlg_req_new(kind, title, message, filter);
        if (!r) {
            cj_plat_sync_lock(h->dlg_lock);
            h->dlg_busy = 0;
            cj_plat_sync_unlock(h->dlg_lock);
            return 0;
        }
        r->ok = cj_plat_run_dialog(h, r);
        ok = r->ok;
        cj_dlg_log_closed(r);
        if (h->on_dialog) {
            h->on_dialog(r->path ? r->path : "");
        }
        cj_dlg_req_free(r);
        cj_plat_sync_lock(h->dlg_lock);
        h->dlg_busy = 0;
        cj_plat_sync_unlock(h->dlg_lock);
        return ok;
    }

    r = cj_dlg_req_new(kind, title, message, filter);
    if (!r) {
        cj_plat_sync_lock(h->dlg_lock);
        h->dlg_busy = 0;
        cj_plat_sync_unlock(h->dlg_lock);
        return 0;
    }
    fprintf(stderr, "[cj-bridge] dialog: kind=%d title=%s\n", kind, r->title);
    cj_plat_sync_lock(h->dlg_lock);
    h->dlg_cur = r;
    cj_plat_sync_unlock(h->dlg_lock);

    cj_plat_post_dialog(h, r);

    /* 等结果：窗口先关的话，cj_core_window_destroyed 会作废并唤醒（ok=0） */
    cj_plat_sync_lock(h->dlg_lock);
    cj_plat_sync_wait(h->dlg_lock, &h->dlg_ready);
    ok = r->ok;
    h->dlg_busy = 0;
    cj_plat_sync_unlock(h->dlg_lock);
    cj_dlg_req_free(r);
    return ok;
}

void cj_core_dialog_tick(cj_host *h, dlg_req *req) {
    int alive;
    if (!h || !req) return;

    cj_plat_sync_lock(h->dlg_lock);
    alive = (h->dlg_cur == req);
    cj_plat_sync_unlock(h->dlg_lock);
    if (!alive) {
        /* 窗口先关了：槽位已交回调用方（它会 free 这个请求）——这里连碰都不能碰 */
        return;
    }

    req->ok = cj_plat_run_dialog(h, req);
    cj_dlg_log_closed(req);
    if (h->on_dialog) {
        h->on_dialog(req->path ? req->path : "");
    }

    cj_plat_sync_lock(h->dlg_lock);
    h->dlg_cur = NULL;
    h->dlg_ready = 1;
    cj_plat_sync_signal(h->dlg_lock);
    cj_plat_sync_unlock(h->dlg_lock);
}
