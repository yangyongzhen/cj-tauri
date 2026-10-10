/*
 * bridge_core.c 自检：不依赖仓颉 SDK，也不依赖 GTK / WebKit / WebView2。
 *
 * 被测的是「两平台逐字相同」的公共核心（回投队列与批处理、对话框单槽状态机、窗口配置存储、
 * 生命周期标志、菜单线路格式解析、串口路径白名单、以及全部 cj_bridge_* 导出）。做法：用一个「只记录调用」的桩平台实现
 * bridge_core.h 里的 25 个 cj_plat_* 原语，再把 core 与桩一起编译成单文件可执行程序——
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
static int g_set_menu_calls;
static char *g_last_menu_text;
static int g_menu_state_calls;
static char g_last_menu_state_id[256];
static int g_last_menu_state_enabled;
static int g_last_menu_state_checked;
static int g_caps_calls;
static int g_caps_value = CJ_CAP_MENU; /* 桩平台自称的能力位（用例里改它，验证 core 只是如实缓存） */

static void reset_counters(void) {
    g_post_js_calls = g_wake_calls = g_quit_calls = g_start_calls = 0;
    g_fini_calls = g_run_dialog_calls = g_post_dialog_calls = 0;
    g_load_url_calls = g_reload_calls = g_devtools_calls = 0;
    g_set_menu_calls = g_menu_state_calls = g_caps_calls = 0;
    free(g_last_js);
    g_last_js = NULL;
    free(g_last_menu_text);
    g_last_menu_text = NULL;
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

void cj_plat_set_menu(cj_host *h, const char *wire) {
    (void)h;
    g_set_menu_calls++;
    free(g_last_menu_text);
    g_last_menu_text = wire ? strdup(wire) : NULL;
}

void cj_plat_menu_item_state(cj_host *h, const char *id, int enabled, int checked) {
    (void)h;
    g_menu_state_calls++;
    snprintf(g_last_menu_state_id, sizeof(g_last_menu_state_id), "%s", id ? id : "");
    g_last_menu_state_enabled = enabled;
    g_last_menu_state_checked = checked;
}

int cj_plat_host_capabilities(cj_host *h) {
    (void)h;
    g_caps_calls++;
    return g_caps_value;
}

/* ---- 串口：桩平台只记录调用，不碰真设备（core 侧的职责是白名单与参数校验）---- */
static int g_serial_open_calls;
static char g_serial_last_path[256];
static cj_serial_cfg g_serial_last_cfg;
static long long g_serial_open_ret = 42; /* 桩返回的假句柄（>0）*/
static int g_serial_read_calls;
static int g_serial_write_calls;
static int g_serial_close_calls;
static int g_serial_read_ret = 1;   /* 默认「读到 1 字节」*/
static int g_serial_write_ret = -1; /* 负值 = 按写满 len 处理 */
static int g_serial_write_last_len;
static unsigned char g_serial_write_first;

long long cj_plat_serial_open(const char *path, const cj_serial_cfg *cfg, char *err, int err_len) {
    g_serial_open_calls++;
    snprintf(g_serial_last_path, sizeof(g_serial_last_path), "%s", path ? path : "");
    if (cfg) g_serial_last_cfg = *cfg;
    if (g_serial_open_ret <= 0 && err && err_len > 0) {
        snprintf(err, (size_t)err_len, "stub: 平台打开失败");
    }
    return g_serial_open_ret;
}

int cj_plat_serial_read(long long h, unsigned char *buf, int len, int timeout_ms,
                        char *err, int err_len) {
    (void)h;
    (void)timeout_ms;
    (void)err;
    (void)err_len;
    g_serial_read_calls++;
    if (buf && len > 0 && g_serial_read_ret > 0) buf[0] = 'Z';
    return g_serial_read_ret;
}

int cj_plat_serial_write(long long h, const unsigned char *buf, int len, int timeout_ms,
                         char *err, int err_len) {
    (void)h;
    (void)timeout_ms;
    (void)err;
    (void)err_len;
    g_serial_write_calls++;
    g_serial_write_last_len = len;
    g_serial_write_first = (buf && len > 0) ? buf[0] : 0;
    return g_serial_write_ret >= 0 ? g_serial_write_ret : len;
}

int cj_plat_serial_close(long long h, char *err, int err_len) {
    (void)h;
    (void)err;
    (void)err_len;
    g_serial_close_calls++;
    return 0;
}

/* 枚举桩：回 0（没有串口不是错误），只为让 core 的 cj_bridge_serial_list 可链接可调 */
int cj_plat_serial_list(char *out, int out_len) {
    if (out && out_len > 0) out[0] = '\0';
    return 0;
}

/* ===== 线路解析的回调收集器（菜单是树，桩侧用一张表记录 core 走出来的每一行）===== */

typedef struct row_rec {
    int depth;
    char kind;
    char id[64];
    char label[64];
    int flags;
    char accel[64];
} row_rec;

typedef struct row_log {
    row_rec rows[32];
    int n;
} row_log;

static void collect_row(void *ctx, int depth, char kind, const char *id,
                        const char *label, int flags, const char *accel) {
    row_log *log = (row_log *)ctx;
    row_rec *r;
    if (!log || log->n >= 32) return;
    r = &log->rows[log->n++];
    r->depth = depth;
    r->kind = kind;
    snprintf(r->id, sizeof(r->id), "%s", id ? id : "");
    snprintf(r->label, sizeof(r->label), "%s", label ? label : "");
    r->flags = flags;
    snprintf(r->accel, sizeof(r->accel), "%s", accel ? accel : "");
}

/* ===== 仓颉侧回调（桩）===== */

static int g_msg_calls;
static int g_destroy_calls;
static cj_host *g_destroy_cb_host; /* 销毁回调收到的句柄（多窗口下这是唯一能分辨「哪扇窗没了」的凭据）*/
static int g_dialog_cb_calls;
static cj_host *g_dialog_cb_host; /* 结果回调收到的句柄：必须等于**发起这次对话框**的那个宿主 */
static char g_dialog_cb_path[256];

static void on_message(const char *json) { (void)json; g_msg_calls++; }
static void on_destroy(cj_host *host) {
    g_destroy_calls++;
    g_destroy_cb_host = host;
}
static void on_dialog(cj_host *host, const char *path) {
    g_dialog_cb_calls++;
    g_dialog_cb_host = host;
    snprintf(g_dialog_cb_path, sizeof(g_dialog_cb_path), "%s", path ? path : "");
}

/* shell 事件回调：**首参必须是宿主句柄**，桩侧把句柄与 JSON 载荷原样记下供断言比对 */
static int g_shell_cb_calls;
static cj_host *g_shell_cb_host;
static char g_shell_cb_json[512];

static void on_shell(cj_host *host, const char *json) {
    g_shell_cb_calls++;
    g_shell_cb_host = host;
    snprintf(g_shell_cb_json, sizeof(g_shell_cb_json), "%s", json ? json : "");
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
    CHECK(g_destroy_cb_host == h, "销毁回调带回的是这个宿主的句柄");
    CHECK(g_msg_calls == 0, "on_message 不该被碰");
    cj_core_window_destroyed(h);
    CHECK(g_destroy_calls == 1, "重复通知不再触发 onDestroy");

    /* --- 9b. 句柄身份：销毁另一个宿主时，回调收到的是它自己 --- */
    case_begin("window_destroyed 两宿主不串（回调带回被销毁者的句柄）");
    {
        cj_host *hb = cj_bridge_create();
        int before;
        CHECK(hb != NULL, "另建一个宿主可独立创建");
        if (hb) {
            before = g_destroy_calls;
            cj_bridge_init(hb, on_message, on_destroy);
            cj_core_window_destroyed(hb);
            CHECK(g_destroy_calls == before + 1 && g_destroy_cb_host == hb,
                  "回调收到 hb（先 init 的 h 不会被误报）");
            cj_bridge_destroy(hb);
        }
    }

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

    /* --- 12b. 句柄身份：结果回调必须落回**发起这次对话框**的宿主 --- */
    case_begin("dialog 结果回调带回发起窗口的句柄（两宿主不串）");
    {
        cj_host *hd = cj_bridge_create();
        int before;
        CHECK(hd != NULL, "另建宿主用于对照");
        if (hd) {
            cj_bridge_set_dialog_callback(hd, on_dialog);
            cj_core_set_ready(hd);
            before = g_dialog_cb_calls;
            CHECK(cj_bridge_show_dialog(h2, 0, "open", "p", "") == 1, "h2 弹框成功");
            CHECK(g_dialog_cb_calls == before + 1 && g_dialog_cb_host == h2,
                  "h2 的结果回调收到 h2");
            CHECK(cj_bridge_show_dialog(hd, 0, "open", "p", "") == 1, "hd 弹框成功");
            CHECK(g_dialog_cb_calls == before + 2 && g_dialog_cb_host == hd,
                  "hd 的结果回调收到 hd（不是上一条的 h2）");
            cj_bridge_destroy(hd);
        }
    }

    /* --- 13. 菜单线路解析（两平台翻译层共用这一份）--- */
    case_begin("menu_walk：线路格式解析（层级 / 字段 / flags）");
    {
        static const char *wire =
            "m\t\t视图\t1\t\n"
            "\tc\tview.sidebar\t侧栏\t3\t\n"
            "\tn\tview.zoom\t放大\t1\tCtrl+=\n"
            "s\t\t\t1\t\n"
            "n\tfile.open\t打开\t1\t\n";
        row_log log;
        log.n = 0;
        cj_core_menu_walk(wire, collect_row, &log);
        CHECK(log.n == 5, "5 行全部解析出来");
        CHECK(log.n == 5 && log.rows[0].depth == 0 && log.rows[0].kind == 'm' &&
              log.rows[0].id[0] == '\0' && strcmp(log.rows[0].label, "视图") == 0,
              "子菜单：层级 0、id 为空、label 保留");
        CHECK(log.n == 5 && log.rows[1].depth == 1 && log.rows[1].kind == 'c' &&
              strcmp(log.rows[1].id, "view.sidebar") == 0 && log.rows[1].flags == 3,
              "勾选项：行首制表符 = 层级 1、flags=3（可用 + 勾选）");
        CHECK(log.n == 5 && log.rows[2].kind == 'n' && strcmp(log.rows[2].label, "放大") == 0 &&
              strcmp(log.rows[2].accel, "Ctrl+=") == 0,
              "普通项：accel 原样带出（Windows 侧要并进标签右对齐）");
        CHECK(log.n == 5 && log.rows[3].kind == 's' && log.rows[3].id[0] == '\0' &&
              log.rows[3].label[0] == '\0',
              "分隔线：id / label 为空但仍是完整一行");
        CHECK(log.n == 5 && strcmp(log.rows[4].id, "file.open") == 0 && log.rows[4].flags == 1,
              "顶层普通项");
    }
    {
        /* 容错：缺字段按空串 / 0；kind 空的行整行跳过；末行不带换行也要出 */
        row_log log2;
        log2.n = 0;
        cj_core_menu_walk("n\tonly-id\n\t\t\nn\ttail\t尾\t1", collect_row, &log2);
        CHECK(log2.n == 2, "kind 为空的行被跳过（容错优于崩溃）");
        CHECK(log2.n == 2 && strcmp(log2.rows[0].id, "only-id") == 0 &&
              log2.rows[0].label[0] == '\0' && log2.rows[0].flags == 0 &&
              log2.rows[0].accel[0] == '\0',
              "缺字段按空串 / 0");
        CHECK(log2.n == 2 && strcmp(log2.rows[1].id, "tail") == 0 &&
              log2.rows[1].accel[0] == '\0', "末行不带换行也解析");
        cj_core_menu_walk(NULL, collect_row, &log2);
        cj_core_menu_walk("n\tx\tX\t1\t\n", NULL, NULL);
        CHECK(1, "walk 对 NULL 参数安全（未崩）");
    }

    /* --- 14. set_menu：core 存下 + 立即透传平台 --- */
    case_begin("set_menu 存下线路文本并透传平台");
    reset_counters();
    cj_bridge_set_menu(h, "n\tfile.open\t打开\t1\t\n");
    CHECK(h->pending_menu_text && strcmp(h->pending_menu_text, "n\tfile.open\t打开\t1\t\n") == 0,
          "线路文本由 core 存下（平台建窗时读它）");
    CHECK(g_set_menu_calls == 1 && g_last_menu_text &&
          strcmp(g_last_menu_text, h->pending_menu_text) == 0, "同时透传平台（未就绪时平台只记下）");
    cj_bridge_set_menu(h, "n\tfile.save\t保存\t0\t\n");
    CHECK(h->pending_menu_text && strcmp(h->pending_menu_text, "n\tfile.save\t保存\t0\t\n") == 0,
          "再次 set：替换并释放旧文本");
    cj_bridge_set_menu(h, "");
    CHECK(h->pending_menu_text && h->pending_menu_text[0] == '\0', "空串 = 清空菜单栏（仍然记下并透传）");
    cj_bridge_set_menu(h, NULL);
    CHECK(h->pending_menu_text && h->pending_menu_text[0] == '\0', "NULL 忽略（不误清）");
    cj_bridge_set_menu(NULL, "x");
    CHECK(1, "set_menu 对 NULL 宿主安全");

    /* --- 15. 菜单点击：shell 回调带回宿主身份 + JSON 载荷 --- */
    case_begin("menu 点击回调带宿主句柄 + JSON 载荷（多窗口不串台）");
    reset_counters();
    g_shell_cb_calls = 0;
    cj_bridge_set_shell_callback(h, on_shell);
    cj_core_menu_clicked(h, "view.sidebar", 1, 1);
    CHECK(g_shell_cb_calls == 1, "点击回调触发一次");
    CHECK(g_shell_cb_host == h, "首参就是该宿主句柄");
    CHECK(strstr(g_shell_cb_json, "\"kind\":\"menu\"") != NULL &&
          strstr(g_shell_cb_json, "\"id\":\"view.sidebar\"") != NULL &&
          strstr(g_shell_cb_json, "\"enabled\":true") != NULL &&
          strstr(g_shell_cb_json, "\"checked\":true") != NULL,
          "载荷是 §5.5 的 JSON（kind / id / enabled / checked）");
    cj_core_menu_clicked(h, "quote\"and\\back", 0, 0);
    CHECK(g_shell_cb_calls == 2 &&
          strstr(g_shell_cb_json, "\"id\":\"quote\\\"and\\\\back\"") != NULL,
          "id 里的 \\ 与 \" 被转义（JSON 不被弄坏）");
    cj_core_menu_clicked(h, "", 1, 0);
    CHECK(g_shell_cb_calls == 2, "空 id 不回调（分隔线 / 子菜单走不到这里）");
    cj_bridge_set_shell_callback(h2, on_shell);
    cj_core_menu_clicked(h2, "panel.reload", 0, 0);
    CHECK(g_shell_cb_calls == 3 && g_shell_cb_host == h2,
          "第二个宿主的点击带回的是它自己的句柄");
    cj_core_menu_clicked(NULL, "x", 1, 1);
    CHECK(1, "clicked 对 NULL 宿主安全");

    /* --- 16. menu_item_state：透传平台 --- */
    case_begin("menu_item_state 透传平台");
    reset_counters();
    cj_bridge_set_menu_item_state(h, "view.sidebar", 1, 0);
    CHECK(g_menu_state_calls == 1 && strcmp(g_last_menu_state_id, "view.sidebar") == 0 &&
          g_last_menu_state_enabled == 1 && g_last_menu_state_checked == 0,
          "id 与状态透传到平台");
    cj_bridge_set_menu_item_state(h, "", 0, 0);
    CHECK(g_menu_state_calls == 1, "空 id 忽略");
    cj_bridge_set_menu_item_state(NULL, "x", 1, 1);
    CHECK(1, "对 NULL 宿主安全");

    /* --- 17. 能力位：cj_plat_init 时问一次，此后只读 --- */
    case_begin("host capabilities 透传（system:host 的依据）");
    {
        cj_host *h3 = cj_bridge_create();
        reset_counters();
        g_caps_value = CJ_CAP_MENU | CJ_CAP_DRAG_DROP;
        cj_bridge_init(h3, on_message, on_destroy);
        CHECK(g_caps_calls == 1, "cj_plat_init 时问平台一次");
        CHECK(h3 && cj_bridge_host_capabilities(h3) == (CJ_CAP_MENU | CJ_CAP_DRAG_DROP) &&
              h3->capabilities == (CJ_CAP_MENU | CJ_CAP_DRAG_DROP),
              "能力位由平台给出并被 core 缓存（托盘没编进来 → 不置位）");
        CHECK(cj_bridge_host_capabilities(NULL) == 0, "NULL 宿主返回 0");
        CHECK(h->capabilities == CJ_CAP_MENU, "先建的宿主保留自己那次 init 的结果");
        g_caps_value = CJ_CAP_MENU;
        cj_bridge_destroy(h3);
    }

    /* --- 18. 销毁：先走平台 fini，再回收句柄 --- */
    case_begin("destroy 先走 cj_plat_fini 再回收");
    reset_counters();
    cj_bridge_destroy(h2);
    cj_bridge_destroy(h);
    CHECK(g_fini_calls == 2, "两个宿主各自走一次平台 fini");

    /* --- 19. 串口：白名单是安全边界，导出只做校验 + 转发 --- */
    case_begin("serial 白名单与导出转发");
    CHECK(cj_serial_path_allowed("/dev/ttyUSB0"), "放行 /dev/ttyUSB0");
    CHECK(cj_serial_path_allowed("/dev/ttyS3"), "放行 /dev/ttyS3");
    CHECK(cj_serial_path_allowed("/dev/pts/7"), "放行伪终端 /dev/pts/7（socat 造的虚拟串口）");
    CHECK(cj_serial_path_allowed("/dev/serial/by-id/usb-1a86_USB_Serial-if00-port0"),
          "放行 udev 稳定链接");
    CHECK(cj_serial_path_allowed("/dev/cu.usbserial-1420"), "放行 macOS /dev/cu.*");
    CHECK(cj_serial_path_allowed("COM3"), "放行 Windows COM3");
    CHECK(cj_serial_path_allowed("\\\\.\\COM12"), "放行 Windows 长名形式");
    CHECK(!cj_serial_path_allowed("/etc/shadow"), "拒绝 /etc/shadow");
    CHECK(!cj_serial_path_allowed("/dev/tty"), "拒绝裸 /dev/tty（那是控制终端，不是串口）");
    CHECK(!cj_serial_path_allowed("/dev/ttyUSB0/../../etc/shadow"), "拒绝借白名单前缀做 .. 穿越");
    CHECK(!cj_serial_path_allowed("/dev/serial/by-id/../../etc/passwd"), "拒绝符号链接段的 .. 穿越");
    CHECK(!cj_serial_path_allowed("COMfoo"), "拒绝 COMfoo（COM 前缀后必须是数字）");
    CHECK(!cj_serial_path_allowed("COM1234"), "拒绝 COM1234（超过 3 位）");
    CHECK(!cj_serial_path_allowed(""), "拒绝空路径");
    CHECK(!cj_serial_path_allowed(NULL), "拒绝 NULL 路径");

    g_serial_open_calls = 0;
    CHECK(cj_bridge_serial_open("/etc/shadow", 115200, 8, 0, 1) == -1,
          "白名单外的路径被 core 拒绝（-1）");
    CHECK(g_serial_open_calls == 0, "被拒路径不触达平台");
    CHECK(cj_bridge_serial_last_error()[0] != '\0', "拒绝时 last_error 有可读原因");
    CHECK(cj_bridge_serial_open("/dev/ttyUSB0", 115200, 9, 0, 1) == -1, "dataBits=9 被拒");
    CHECK(cj_bridge_serial_open("/dev/ttyUSB0", 0, 8, 0, 1) == -1, "baud=0 被拒");
    CHECK(cj_bridge_serial_open("/dev/ttyUSB0", 115200, 8, 3, 1) == -1, "parity=3 被拒");
    CHECK(cj_bridge_serial_open("/dev/ttyUSB0", 115200, 8, 0, 3) == -1, "stopBits=3 被拒");
    CHECK(g_serial_open_calls == 0, "参数非法同样不触达平台");

    CHECK(cj_bridge_serial_open("/dev/ttyUSB0", 115200, 8, 2, 1) == 42,
          "合法路径转发平台并原样带回句柄");
    CHECK(g_serial_open_calls == 1 && strcmp(g_serial_last_path, "/dev/ttyUSB0") == 0,
          "路径原样传给平台");
    CHECK(g_serial_last_cfg.baud == 115200 && g_serial_last_cfg.data_bits == 8 &&
          g_serial_last_cfg.parity == 2 && g_serial_last_cfg.stop_bits == 1,
          "四项配置（含偶校验）原样传给平台");

    g_serial_open_ret = -3;
    CHECK(cj_bridge_serial_open("/dev/ttyUSB0", 115200, 8, 0, 1) == -3, "平台失败码原样返回");
    CHECK(strstr(cj_bridge_serial_last_error(), "stub") != NULL, "平台给的原因进 last_error");
    g_serial_open_ret = 42;

    {
        unsigned char rd[4];
        unsigned char wr[3];
        int n;

        rd[0] = 0;
        wr[0] = 'A';
        wr[1] = 'B';
        wr[2] = 'C';
        n = cj_bridge_serial_read(42, rd, (int)sizeof(rd), 0);
        CHECK(n == 1 && rd[0] == 'Z' && g_serial_read_calls == 1, "read 转发并带回字节");
        n = cj_bridge_serial_write(42, wr, (int)sizeof(wr), 0);
        CHECK(n == 3 && g_serial_write_calls == 1 && g_serial_write_last_len == 3 &&
              g_serial_write_first == 'A', "write 转发（平台拿到原缓冲）");
        CHECK(cj_bridge_serial_close(42) == 0 && g_serial_close_calls == 1, "close 转发");

        CHECK(cj_bridge_serial_read(0, rd, 4, 0) == -1, "handle<=0 的 read 被拒");
        CHECK(cj_bridge_serial_read(42, NULL, 4, 0) == -1, "空缓冲的 read 被拒");
        CHECK(cj_bridge_serial_write(42, wr, 0, 0) == -1, "len=0 的 write 被拒");
        CHECK(cj_bridge_serial_close(0) == -1, "handle<=0 的 close 被拒");
        CHECK(g_serial_read_calls == 1 && g_serial_write_calls == 1 && g_serial_close_calls == 1,
              "参数非法的调用没有触达平台");
        CHECK(1, "串口导出不需要宿主（本用例跑在两个宿主都已销毁之后）");
    }

    fprintf(stderr, "[bridge-core] 断言 %d 项：通过 %d，失败 %d\n", g_pass + g_fail,
            g_pass, g_fail);
    free(g_last_js);
    free(g_last_menu_text);
    if (g_fail) {
        fprintf(stderr, "[FAIL] bridge_core 自检未通过\n");
        return 1;
    }
    fprintf(stderr, "[OK] bridge_core 自检全过\n");
    return 0;
}
