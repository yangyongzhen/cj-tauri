/*
 * bridge_core.c 自检：不依赖仓颉 SDK，也不依赖 GTK / WebKit / WebView2。
 *
 * 被测的是「两平台逐字相同」的公共核心（回投队列与批处理、对话框单槽状态机、窗口配置存储、
 * 生命周期标志、以及全部 cj_bridge_* 导出）。做法：用一个「只记录调用」的桩平台实现
 * bridge_core.h 里的 18 个 cj_plat_* 原语，再把 core 与桩一起编译成单文件可执行程序——
 * 链接期就能证明 core 只经 cj_plat_* 触达平台、不 include 任何平台头。
 *
 * 跑法：bash scripts/test-bridge-core.sh
 */
#define _POSIX_C_SOURCE 200809L

#include "bridge_core.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ===== 断言与用例 ===== */

static int g_pass = 0;
static int g_fail = 0;
static const char *g_case = "?";

#define CHECK(cond, what)                                                     \
    do {                                                                      \
        if (cond) {                                                           \
            g_pass++;                                                         \
        } else {                                                              \
            g_fail++;                                                         \
            fprintf(stderr, "  [FAIL] %s:%d [%s] %s\n", __FILE__, __LINE__,    \
                    g_case, what);                                            \
        }                                                                     \
    } while (0)

static void case_begin(const char *name) {
    g_case = name;
    fprintf(stderr, "  - %s\n", name);
}

/* ===== 桩平台：只记录调用，不做真实副作用 ===== */

struct cj_sync {
    pthread_mutex_t m;
    pthread_cond_t c;
};

static int g_post_js_calls;
static char *g_last_js; /* 最近一次 cj_plat_post_js 的脚本（拷贝） */
static int g_wake_calls;
static int g_quit_calls;
static int g_start_calls;
static int g_fini_calls;
static int g_run_dialog_calls;
static int g_post_dialog_calls;
static int g_load_url_calls;
static int g_reload_calls;
static int g_devtools_calls;
static int g_is_ui_thread = 1; /* 默认假装调用方就站在 UI 线程上 */
static int g_dialog_ok = 1;    /* cj_plat_run_dialog 的返回值 */
static const char *g_dialog_path = "/tmp/picked.txt";

static void reset_counters(void) {
    g_post_js_calls = g_wake_calls = g_quit_calls = g_start_calls = 0;
    g_fini_calls = g_run_dialog_calls = g_post_dialog_calls = 0;
    g_load_url_calls = g_reload_calls = g_devtools_calls = 0;
    free(g_last_js);
    g_last_js = NULL;
}

/* 数一段脚本里有几个换行：批处理按「每条一段 + 换行」拼接，用它反推条数 */
static int count_nl(const char *s) {
    int n = 0;
    while (s && *s) {
        if (*s++ == '\n') n++;
    }
    return n;
}

cj_sync *cj_plat_sync_create(void) {
    cj_sync *s = (cj_sync *)calloc(1, sizeof(cj_sync));
    if (!s) return NULL;
    pthread_mutex_init(&s->m, NULL);
    pthread_cond_init(&s->c, NULL);
    return s;
}

void cj_plat_sync_destroy(cj_sync *s) {
    if (!s) return;
    pthread_mutex_destroy(&s->m);
    pthread_cond_destroy(&s->c);
    free(s);
}

void cj_plat_sync_lock(cj_sync *s) { if (s) pthread_mutex_lock(&s->m); }
void cj_plat_sync_unlock(cj_sync *s) { if (s) pthread_mutex_unlock(&s->m); }

void cj_plat_sync_wait(cj_sync *s, int *ready) {
    /* core 的约定：进入时已持锁，返回时 *ready 为真（允许虚假唤醒）*/
    while (s && ready && !*ready) pthread_cond_wait(&s->c, &s->m);
}

void cj_plat_sync_signal(cj_sync *s) { if (s) pthread_cond_signal(&s->c); }

void cj_plat_init(cj_host *h) { (void)h; }
int  cj_plat_fini(cj_host *h) { (void)h; g_fini_calls++; return 1; }
void cj_plat_start(cj_host *h) { (void)h; g_start_calls++; }
void cj_plat_quit(cj_host *h) { (void)h; g_quit_calls++; }
void cj_plat_wake_ui(cj_host *h) { (void)h; g_wake_calls++; }

void cj_plat_post_js(cj_host *h, const char *script_utf8) {
    (void)h;
    g_post_js_calls++;
    free(g_last_js);
    g_last_js = script_utf8 ? strdup(script_utf8) : NULL;
}

int cj_plat_is_ui_thread(cj_host *h) { (void)h; return g_is_ui_thread; }
void cj_plat_post_dialog(cj_host *h, dlg_req *req) { (void)h; (void)req; g_post_dialog_calls++; }

int cj_plat_run_dialog(cj_host *h, dlg_req *req) {
    (void)h;
    g_run_dialog_calls++;
    if (req && (req->kind == 0 || req->kind == 1)) { /* 文件类才有路径 */
        free(req->path);
        req->path = strdup(g_dialog_path);
    }
    return g_dialog_ok;
}

void cj_plat_open_devtools(cj_host *h) { (void)h; g_devtools_calls++; }
void cj_plat_load_url(cj_host *h, const char *url) { (void)h; (void)url; g_load_url_calls++; }
void cj_plat_reload(cj_host *h) { (void)h; g_reload_calls++; }

/* ===== 仓颉侧回调（桩）===== */

static int g_msg_calls;
static int g_destroy_calls;
static int g_dialog_cb_calls;
static char g_dialog_cb_path[256];

static void on_message(const char *json) { (void)json; g_msg_calls++; }
static void on_destroy(void) { g_destroy_calls++; }
static void on_dialog(const char *path) {
    g_dialog_cb_calls++;
    snprintf(g_dialog_cb_path, sizeof(g_dialog_cb_path), "%s", path ? path : "");
}

/* ===== 用例 ===== */

int main(void) {
    cj_host *h;
    cj_host *h2;
    int i;

    fprintf(stderr, "[bridge-core] 自检开始（桩平台，无需 SDK / 图形栈）\n");

    /* --- 1. 建宿主：默认值与 NULL 安全 --- */
    case_begin("create 默认值与导出对 NULL 安全");
    h = cj_bridge_create();
    CHECK(h != NULL, "create 返回非 NULL");
    if (!h) return 1;
    CHECK(h->win_w == 900 && h->win_h == 640, "默认窗口 900x640");
    CHECK(h->devtools == 1, "默认开 devtools");
    CHECK(h->win_title == NULL, "默认标题为空（由平台兜底）");
    CHECK(h->ready == 0 && h->should_quit == 0 && h->window_gone == 0,
          "初始生命周期标志全 0");
    CHECK(cj_bridge_is_ready(h) == 0 && cj_bridge_should_quit(h) == 0, "访问器初值 0");
    CHECK(cj_bridge_is_ready(NULL) == 0 && cj_bridge_should_quit(NULL) == 0,
          "访问器对 NULL 返回 0");
    cj_bridge_destroy(NULL);
    cj_bridge_quit(NULL);
    cj_bridge_run_js(NULL, "x");
    cj_bridge_set_window(NULL, "t", 1, 1);
    cj_bridge_add_init_script(NULL, "x");
    cj_bridge_show_dialog(NULL, 2, "t", "m", "");
    CHECK(1, "全部导出对 NULL 安全（未崩）");

    /* --- 2. 窗口配置：标题/图标都是拷贝，非法尺寸不覆盖 --- */
    case_begin("set_window / set_icon / set_devtools");
    cj_bridge_set_window(h, "First", 800, 600);
    CHECK(h->win_w == 800 && h->win_h == 600, "尺寸生效");
    CHECK(h->win_title && strcmp(h->win_title, "First") == 0, "标题是拷贝");
    cj_bridge_set_window(h, "Second", 0, -1);
    CHECK(h->win_title && strcmp(h->win_title, "Second") == 0, "标题替换（旧值已释放）");
    CHECK(h->win_w == 800 && h->win_h == 600, "宽高 <=0 时保持原值");
    cj_bridge_set_icon(h, "");
    CHECK(h->win_icon == NULL, "空图标路径 = 系统默认");
    cj_bridge_set_icon(h, "/tmp/a.png");
    CHECK(h->win_icon && strcmp(h->win_icon, "/tmp/a.png") == 0, "图标路径是拷贝");
    cj_bridge_set_devtools(h, 0);
    CHECK(h->devtools == 0, "devtools 可关");
    cj_bridge_set_devtools(h, 1);
    CHECK(h->devtools == 1, "devtools 可开");

    /* --- 3. 预执行脚本：忽略空串、顺序保持、容量翻倍 --- */
    case_begin("add_init_script 顺序与扩容");
    cj_bridge_add_init_script(h, "");
    cj_bridge_add_init_script(h, NULL);
    CHECK(h->init_script_count == 0, "空串 / NULL 脚本被忽略");
    cj_bridge_add_init_script(h, "s1");
    cj_bridge_add_init_script(h, "s2");
    cj_bridge_add_init_script(h, "s3");
    cj_bridge_add_init_script(h, "s4");
    cj_bridge_add_init_script(h, "s5"); /* 第 5 条触发扩容（4 -> 8）*/
    CHECK(h->init_script_count == 5, "5 条脚本入列");
    CHECK(h->init_script_cap >= 5, "容量已扩容");
    CHECK(h->init_scripts[0] && strcmp(h->init_scripts[0], "s1") == 0 &&
          h->init_scripts[4] && strcmp(h->init_scripts[4], "s5") == 0,
          "顺序保持（注册序 = 注入序）");

    /* --- 4. 页面来源二选一 + 运行期操作透传平台 --- */
    case_begin("start / load_url / reload / open_devtools");
    cj_bridge_start(h, "<html>hi</html>");
    CHECK(g_start_calls == 1, "start 调到平台");
    CHECK(h->pending_html && strcmp(h->pending_html, "<html>hi</html>") == 0,
          "内联 HTML 记下");
    cj_bridge_start(h, ""); /* 空串 = 页面由 URL 指定，不清掉已记的来源 */
    CHECK(h->pending_html != NULL, "空串 start 不改页面来源");
    cj_bridge_load_url(h, "http://x/");
    CHECK(g_load_url_calls == 1 && h->pending_url &&
          strcmp(h->pending_url, "http://x/") == 0, "URL 记下并投递");
    cj_bridge_load_url(h, "");
    CHECK(g_load_url_calls == 1, "空 URL 忽略");
    cj_bridge_reload(h);
    cj_bridge_open_devtools(h);
    CHECK(g_reload_calls == 1 && g_devtools_calls == 1, "reload / devtools 投递到平台");

    /* --- 5. 回投：单条快路径 --- */
    case_begin("run_js + flush：单条快路径");
    reset_counters();
    cj_bridge_run_js(h, "console.log(1)");
    CHECK(g_wake_calls == 1, "入队即唤醒 UI");
    CHECK(g_post_js_calls == 0, "入队本身不执行 JS");
    cj_core_flush_js(h);
    CHECK(g_post_js_calls == 1, "单条只 post 一次");
    CHECK(g_last_js && strcmp(g_last_js, "console.log(1)") == 0, "快路径原样透传（不加换行）");
    CHECK(g_wake_calls == 1, "队列已空：不再自续唤醒");
    cj_core_flush_js(h);
    CHECK(g_post_js_calls == 1, "空队列 flush 不产生回投");

    /* --- 6. 回投：多条拼批 --- */
    case_begin("run_js + flush：多条拼批（顺序 + 换行分隔）");
    reset_counters();
    cj_bridge_run_js(h, "A");
    cj_bridge_run_js(h, "B");
    cj_bridge_run_js(h, "C");
    CHECK(g_wake_calls == 1, "队列由空转非空：只唤醒一次");
    cj_core_flush_js(h);
    CHECK(g_post_js_calls == 1, "三条合成一段脚本：只 post 一次");
    CHECK(g_last_js && strcmp(g_last_js, "A\nB\nC\n") == 0,
          "顺序保持、换行分隔（末条也带换行）");

    /* --- 7. 回投：批上限 64 + 自续唤醒（长队列肯让出 UI 线程）--- */
    case_begin("flush 批上限 CJ_JS_BATCH_MAX 与自续唤醒");
    reset_counters();
    for (i = 0; i < 70; i++) {
        char buf[32];
        snprintf(buf, sizeof(buf), "x%d", i);
        cj_bridge_run_js(h, buf);
    }
    cj_core_flush_js(h);
    CHECK(g_post_js_calls == 1, "首批只发一段");
    CHECK(g_last_js && count_nl(g_last_js) == 64, "首批恰好 64 条");
    CHECK(g_last_js && strncmp(g_last_js, "x0\n", 3) == 0, "从队首开始");
    CHECK(g_wake_calls >= 1, "队列未取空：自续唤醒");
    cj_core_flush_js(h);
    CHECK(g_post_js_calls == 2 && g_last_js && count_nl(g_last_js) == 6,
          "第二批 6 条（70 - 64）");
    CHECK(count_nl(g_last_js) == 6 && strncmp(g_last_js, "x64\n", 4) == 0, "第二批接着队尾");

    /* --- 8. quit：置标志 + 走平台同一路径 --- */
    case_begin("quit 置 should_quit 并投递平台");
    reset_counters();
    CHECK(cj_bridge_should_quit(h) == 0, "quit 前 shouldQuit=0");
    cj_bridge_quit(h);
    CHECK(cj_bridge_should_quit(h) == 1, "quit 置 should_quit");
    CHECK(g_quit_calls == 1, "投递到平台（与用户关窗同一条销毁路径）");

    /* --- 9. 窗口销毁：标志 + onDestroy 恰好一次 --- */
    case_begin("window_destroyed 幂等（onDestroy 恰好一次）");
    reset_counters();
    cj_bridge_init(h, on_message, on_destroy);
    cj_core_window_destroyed(h);
    CHECK(h->window_gone == 1 && h->should_quit == 1, "置 window_gone + should_quit");
    CHECK(g_destroy_calls == 1, "onDestroy 触发一次");
    CHECK(g_msg_calls == 0, "on_message 不该被碰");
    cj_core_window_destroyed(h);
    CHECK(g_destroy_calls == 1, "重复通知不再触发 onDestroy");

    /* --- 10. 对话框：宿主未就绪直接拒绝 --- */
    case_begin("dialog：宿主未就绪返回 0");
    reset_counters();
    h2 = cj_bridge_create();
    CHECK(h2 != NULL, "第二个宿主可独立创建（无进程级单例）");
    if (!h2) return 1;
    cj_bridge_set_dialog_callback(h2, on_dialog);
    CHECK(cj_bridge_show_dialog(h2, 2, "t", "m", "") == 0, "未就绪返回 0");
    CHECK(g_run_dialog_calls == 0, "未就绪时平台没被调用");

    /* --- 11. 对话框：UI 线程快路径（不投递、不阻塞）--- */
    case_begin("dialog：UI 线程快路径与路径回调");
    reset_counters();
    cj_core_set_ready(h2);
    CHECK(cj_bridge_is_ready(h2) == 1, "set_ready 生效");
    CHECK(cj_bridge_show_dialog(h2, 0, "open", "pick", "*.txt") == 1, "文件类返回平台结果 1");
    CHECK(g_run_dialog_calls == 1, "在 UI 线程上直接弹（投递 + 阻塞会自锁）");
    CHECK(g_post_dialog_calls == 0, "快路径不发消息");
    CHECK(g_dialog_cb_calls == 1 && strcmp(g_dialog_cb_path, "/tmp/picked.txt") == 0,
          "选中路径回调送回");
    CHECK(h2->dlg_busy == 0, "槽位交回");
    CHECK(cj_bridge_show_dialog(h2, 2, "info", "m", "") == 1, "第二次调用仍可用");
    CHECK(h2->dlg_busy == 0, "第二次调用后槽位仍空");

    /* --- 12. 对话框作废：幂等 --- */
    case_begin("dialog_abort 幂等");
    cj_core_dialog_abort(h2);
    cj_core_dialog_abort(h2);
    CHECK(h2->dlg_cur == NULL, "无进行中对话框时 abort 是空操作");

    /* --- 13. 销毁：先走平台 fini，再回收句柄 --- */
    case_begin("destroy 先走 cj_plat_fini 再回收");
    reset_counters();
    cj_bridge_destroy(h2);
    cj_bridge_destroy(h);
    CHECK(g_fini_calls == 2, "两个宿主各自走一次平台 fini");

    fprintf(stderr, "[bridge-core] 断言 %d 项：通过 %d，失败 %d\n", g_pass + g_fail,
            g_pass, g_fail);
    free(g_last_js);
    if (g_fail) {
        fprintf(stderr, "[FAIL] bridge_core 自检未通过\n");
        return 1;
    }
    fprintf(stderr, "[OK] bridge_core 自检全过\n");
    return 0;
}
