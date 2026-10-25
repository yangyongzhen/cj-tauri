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
#include <sys/stat.h>
#include <unistd.h>

/* mingw 的 <io.h> 把 mkdir 声明成单参（MSVCRT 语义，且已标 deprecated），
   POSIX 的两参形态在 Windows 上直接编不过（too many arguments to function call）——
   用例里统一走这个包装，两边的语义都是「建一级目录」。 */
#ifdef _WIN32
#include <direct.h>
static int cj_test_mkdir(const char *p) { return _mkdir(p); }
#else
static int cj_test_mkdir(const char *p) { return mkdir(p, 0700); }
#endif

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

/* ===== 日志落盘用例的辅助（RFC-003 第 5 期） =====
   开启日志后 fd 2 就被日志文件接管了，此时 CHECK 的失败行会**写进日志文件**、外面根本看不见。
   所以接管期间改用 LOG_CHECK：结果先攒在内存里，等 stderr 还原之后再一次性打出来。 */
static char g_log_fail_buf[4096];

static void cj_test_log_check(int cond, int line, const char *what) {
    if (cond) {
        g_pass++;
        return;
    }
    g_fail++;
    if (strlen(g_log_fail_buf) + 240 < sizeof(g_log_fail_buf)) {
        char row[200];
        snprintf(row, sizeof(row), "  [FAIL] %s:%d [log file] %s\n", __FILE__, line, what);
        strcat(g_log_fail_buf, row);
    }
}

#define LOG_CHECK(cond, what) cj_test_log_check((cond) ? 1 : 0, __LINE__, what)

static int cj_test_file_exists(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fclose(f);
    return 1;
}

/* 读全文（截断到 cap-1）；返回读到的字节数，-1 = 打不开 */
static long cj_test_read_all(const char *path, char *buf, long cap) {
    FILE *f = fopen(path, "rb");
    long n;
    if (!f) {
        if (cap > 0) buf[0] = '\0';
        return -1;
    }
    n = (long)fread(buf, 1, (size_t)(cap - 1), f);
    buf[n > 0 ? n : 0] = '\0';
    fclose(f);
    return n;
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

/* 拖放策略：桩平台只记录调用（core 的职责是 pending 存取与 drop 报文解析）*/
static int g_drag_calls;
static int g_drag_last_enabled;
static int g_drag_last_files;

/* 标题栏副标题：桩平台只记录调用（core 的职责是参数校验 + 透传）*/
static int g_subtitle_calls;
static char *g_last_subtitle_text;

static void reset_counters(void) {
    g_post_js_calls = g_wake_calls = g_quit_calls = g_start_calls = 0;
    g_fini_calls = g_run_dialog_calls = g_post_dialog_calls = 0;
    g_load_url_calls = g_reload_calls = g_devtools_calls = 0;
    g_set_menu_calls = g_menu_state_calls = g_caps_calls = 0;
    g_drag_calls = g_drag_last_enabled = g_drag_last_files = 0;
    g_subtitle_calls = 0;
    free(g_last_subtitle_text);
    g_last_subtitle_text = NULL;
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

/* ---- 剪贴板桩：记调用次数与最后一次写的文本；读返回桩文本 ---- */
static int g_clip_write_calls = 0;
static int g_clip_read_calls = 0;
static char *g_clip_last_written = NULL;
static int g_clip_write_ok = 1; /* 用例可扳成 0 模拟平台失败 */

int cj_plat_post_ui(cj_host *h, cj_ui_fn fn, void *ud) {
    (void)h;
    fn(ud); /* 桩平台没有真 UI 线程：就地执行（core 的 is_ui_thread 桩可扳成 0 验投递路径）*/
    return 1;
}

int cj_plat_clipboard_write_text(cj_host *h, const char *text, char *err, int err_len) {
    (void)h; (void)err; (void)err_len;
    g_clip_write_calls++;
    if (!g_clip_write_ok) return -3;
    free(g_clip_last_written);
    g_clip_last_written = strdup(text ? text : "");
    return 0;
}

char *cj_plat_clipboard_read_text(cj_host *h, char *err, int err_len) {
    (void)h; (void)err; (void)err_len;
    g_clip_read_calls++;
    if (!g_clip_last_written) return NULL;
    return strdup(g_clip_last_written);
}

/* ---- 通知桩：记调用次数与最后一次的标题；用例可扳失败 ---- */
static int g_note_calls = 0;
static char *g_note_last_title = NULL;
static int g_note_ok = 1;

int cj_plat_notification_notify(cj_host *h, const char *title, const char *body,
                                char *err, int err_len) {
    (void)h; (void)body; (void)err; (void)err_len;
    g_note_calls++;
    if (!g_note_ok) return -3;
    free(g_note_last_title);
    g_note_last_title = strdup(title ? title : "");
    return 0;
}

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

/* 桩平台：副标题一律接受（真平台未就绪返回 -3、Windows 返回 -4，那是平台自己的事）*/
int cj_plat_set_titlebar_subtitle(cj_host *h, const char *text) {
    (void)h;
    g_subtitle_calls++;
    free(g_last_subtitle_text);
    g_last_subtitle_text = text ? strdup(text) : NULL;
    return 0;
}

void cj_plat_menu_item_state(cj_host *h, const char *id, int enabled, int checked) {
    (void)h;
    g_menu_state_calls++;
    snprintf(g_last_menu_state_id, sizeof(g_last_menu_state_id), "%s", id ? id : "");
    g_last_menu_state_enabled = enabled;
    g_last_menu_state_checked = checked;
}

/* ---- 拖放策略：声明在计数器区（reset_counters 之前），这里只留原语 ---- */
void cj_plat_set_drag_drop(cj_host *h, int enabled, int files) {
    (void)h;
    g_drag_calls++;
    g_drag_last_enabled = enabled;
    g_drag_last_files = files;
}

/* ---- 全局快捷键：桩平台没有 X11，只记录调用（接线层自检用）---- */
static int g_hotkey_calls;
static char g_hotkey_last_wire[512];
void cj_plat_set_global_hotkeys(cj_host *h, const char *wire) {
    (void)h;
    g_hotkey_calls++;
    snprintf(g_hotkey_last_wire, sizeof(g_hotkey_last_wire), "%s", wire ? wire : "");
}

/* ---- 托盘：桩平台没有 appindicator，只记录调用（接线层自检用）---- */
static int g_tray_calls;
static char g_tray_last_wire[512];
void cj_plat_set_tray(cj_host *h, const char *wire) {
    (void)h;
    g_tray_calls++;
    snprintf(g_tray_last_wire, sizeof(g_tray_last_wire), "%s", wire ? wire : "");
}

/* ---- 窗口可见性 / 最小化到托盘：桩平台没有窗口，只记录调用（接线层自检用）---- */
static int g_win_visible_calls;
static int g_win_visible_last = -1;
void cj_plat_set_window_visible(cj_host *h, int visible) {
    (void)h;
    g_win_visible_calls++;
    g_win_visible_last = visible;
}

static int g_min_tray_calls;
static int g_min_tray_last = -1;
void cj_plat_set_minimize_to_tray(cj_host *h, int enabled) {
    (void)h;
    g_min_tray_calls++;
    g_min_tray_last = enabled;
}

/* ---- 附庸窗：桩平台同样只记录调用（owner 记成「有没有」而不是指针值）---- */
static int g_owner_calls;
static int g_owner_has_owner = -1;
void cj_plat_set_owner_window(cj_host *h, cj_host *owner) {
    (void)h;
    g_owner_calls++;
    g_owner_has_owner = owner ? 1 : 0;
}

/* --- 内嵌视图（PLT-006）：桩只记调用与入参，语义契约由 core 的校验覆盖 --- */
static int g_view_create_calls;
static long long g_view_create_last;
static int g_view_visible_calls;
static int g_view_visible_last = -1;
static int g_view_bounds_calls;
static int g_view_bounds_last[4];
static int g_view_navigate_calls;
static int g_view_destroy_calls;
static long long g_view_seq;

long long cj_plat_view_create(cj_host *h, const char *url, int x, int y, int w, int hgt) {
    (void)h;
    if (!url || !url[0]) return 0;
    g_view_create_calls++;
    g_view_seq++;
    g_view_create_last = g_view_seq;
    g_view_bounds_last[0] = x;
    g_view_bounds_last[1] = y;
    g_view_bounds_last[2] = w;
    g_view_bounds_last[3] = hgt;
    return g_view_seq;
}

void cj_plat_view_set_visible(cj_host *h, long long view, int visible) {
    (void)h;
    (void)view;
    g_view_visible_calls++;
    g_view_visible_last = visible;
}

void cj_plat_view_set_bounds(cj_host *h, long long view, int x, int y, int w, int hgt) {
    (void)h;
    (void)view;
    g_view_bounds_calls++;
    g_view_bounds_last[0] = x;
    g_view_bounds_last[1] = y;
    g_view_bounds_last[2] = w;
    g_view_bounds_last[3] = hgt;
}

void cj_plat_view_navigate(cj_host *h, long long view, const char *url) {
    (void)h;
    (void)view;
    (void)url;
    g_view_navigate_calls++;
}

void cj_plat_view_destroy(cj_host *h, long long view) {
    (void)h;
    (void)view;
    g_view_destroy_calls++;
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

/* ===== 静默子进程桩：桩平台建不了真进程，只为让 core 的**参数校验与转发**可调可断言 =====
   真进程那条路（Windows 的 DETACHED_PROCESS / Linux 的 posix_spawn）由平台实机验证。 */
long long cj_plat_spawn_hidden(const char *exe, const char *args, char *err, int err_len) {
    (void)args;
    if (err && err_len > 0) {
        err[0] = '\0';
    }
    /* 只认一个哨兵：命中就给个假 pid，其余回 0 并留一句原因（两条分支 core 都要覆盖） */
    if (exe && strcmp(exe, "stub-ok") == 0) {
        return 4242;
    }
    if (err && err_len > 0) {
        snprintf(err, (size_t)err_len, "stub: 不能建进程");
    }
    return 0;
}

int cj_plat_kill_pid(long long pid) {
    (void)pid;
    return 1; /* 幂等口径：桩上一律算「已结束」 */
}

int cj_plat_pid_alive(long long pid) {
    (void)pid;
    return 0; /* 桩平台没有真进程 */
}

/* ===== 内嵌资源桩：桩平台没有 PE 资源表，如实返回 0 或留一句原因，
   让 core 的三条分支（参数校验 / 无资源 / 失败）都能在无 SDK 的机器上被断言。 ===== */
int cj_plat_extract_assets(const char *dir, char *err, int err_len) {
    if (err && err_len > 0) err[0] = '\0';
    if (dir && strcmp(dir, "stub-missing") == 0) {
        if (err && err_len > 0) snprintf(err, (size_t)err_len, "桩平台：没有内嵌资源");
        return -1;
    }
    return 0; /* 普通产物没有内嵌资源——如实回报 */
}

/* ===== 动态库预加载桩：桩平台不去真加载库，只让 core 的「空路径拒绝 / 失败出口」可断言。
   真加载那条路（Windows 的 LoadLibraryW / Linux 的 dlopen）由平台实机验证。 ===== */
int cj_plat_preload_library(const char *path, char *err, int err_len) {
    if (err && err_len > 0) err[0] = '\0';
    if (path && strcmp(path, "stub-broken") == 0) {
        if (err && err_len > 0) snprintf(err, (size_t)err_len, "桩平台：加载失败");
        return 0;
    }
    return 1; /* 其余一律算加载成功（core 只关心 0 / 非 0 与日志） */
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

    /* --- 2b. 窗口可见性 / 最小化到托盘：两头都能用，但「建窗前」只记不下发 --- */
    case_begin("set_window_visible / set_minimize_to_tray");
    cj_bridge_set_window_visible(h, 0);
    CHECK(h->win_visible == 0, "未就绪：记下待定可见性");
    CHECK(g_win_visible_calls == 0, "未就绪：不下发平台（建窗时按 h->win_visible 定稿，省一次闪烁）");
    h->ready = 1;
    cj_bridge_set_window_visible(h, 1);
    CHECK(h->win_visible == 1 && g_win_visible_calls == 1 && g_win_visible_last == 1,
          "就绪后：投平台执行显示");
    cj_bridge_set_minimize_to_tray(h, 1);
    CHECK(h->minimize_to_tray == 1 && g_min_tray_calls == 1 && g_min_tray_last == 1,
          "最小化到托盘策略转给平台");
    cj_bridge_set_minimize_to_tray(h, 0);
    CHECK(h->minimize_to_tray == 0 && g_min_tray_last == 0, "策略可关（回到普通最小化）");
    h->ready = 0; /* 后面的用例还按「未启动」的前提走 */

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

    /* --- 15. titlebar 副标题：core 校验参数、原样透传平台 --- */
    case_begin("titlebar 副标题：校验 + 透传平台");
    reset_counters();
    CHECK(cj_bridge_set_titlebar_subtitle(h, "n.md · 已保存 · 54 字") == 0, "正常文本返回 0");
    CHECK(g_subtitle_calls == 1 && g_last_subtitle_text &&
          strcmp(g_last_subtitle_text, "n.md · 已保存 · 54 字") == 0,
          "原文透传平台（UTF-8 多字节不截断）");
    cj_bridge_set_titlebar_subtitle(h, "");
    CHECK(g_last_subtitle_text && g_last_subtitle_text[0] == '\0', "空串 = 清空副标题（仍透传）");
    {
        /* 超 1024 字节：core 当场拒绝，不透传——平台在 UI 线程里不该再做第二份校验 */
        char big[1100];
        memset(big, 'a', sizeof(big) - 1);
        big[sizeof(big) - 1] = '\0';
        reset_counters();
        CHECK(cj_bridge_set_titlebar_subtitle(h, big) == -1, "超过 1024 字节返回 -1");
        CHECK(g_subtitle_calls == 0, "被拒的请求不透传到平台");
    }
    CHECK(cj_bridge_set_titlebar_subtitle(h, NULL) == -1, "NULL 文本返回 -1");
    CHECK(cj_bridge_set_titlebar_subtitle(NULL, "x") == -1, "NULL 宿主返回 -1");

    /* --- 16. 菜单点击：shell 回调带回宿主身份 + JSON 载荷 --- */
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

    /* --- 16b. 拖放：策略透传 + drop 报文解析（RFC-002 §5 / §7.B）--- */
    case_begin("set_drag_drop 透传与 pending");
    reset_counters();
    cj_bridge_set_drag_drop(h, 1, 1);
    CHECK(g_drag_calls == 1 && g_drag_last_enabled == 1 && g_drag_last_files == 1,
          "策略透传到平台原语");
    CHECK(h->pending_drop_enabled == 1 && h->pending_drop_files == 1,
          "策略同时记进 pending（建 view 时读）");
    cj_bridge_set_drag_drop(h, 0, 0);
    CHECK(g_drag_calls == 2 && h->pending_drop_enabled == 0 && h->pending_drop_files == 0,
          "关掉也透传（平台摘 drag dest）");
    cj_bridge_set_drag_drop(NULL, 1, 1);
    CHECK(1, "对 NULL 宿主安全");

    case_begin("cj_core_drop_files 解析与报文");
    reset_counters();
    g_shell_cb_calls = 0; /* shell 回调计数不在 reset_counters 里（menu 用例也是手动清零） */
    cj_core_drop_files(h, "file:///tmp/a.png\r\nfile:///tmp/b%20c.txt\r\n");
    CHECK(g_shell_cb_calls == 1 && g_shell_cb_host == h, "drop 回调一次、带回该宿主句柄");
    CHECK(strstr(g_shell_cb_json, "\"kind\":\"drop\"") != NULL &&
          strstr(g_shell_cb_json, "\"paths\":[\"/tmp/a.png\",\"/tmp/b c.txt\"]") != NULL,
          "file:// 解码成路径（\\r\\n 分隔、%20 还原空格），报文是 {kind,paths} JSON");
    cj_core_drop_files(h, "# comment line\n\nfile:///tmp/only.txt\nhttps://example.com/x");
    CHECK(g_shell_cb_calls == 2 &&
          strstr(g_shell_cb_json, "\"/tmp/only.txt\"") != NULL &&
          strstr(g_shell_cb_json, "\"https://example.com/x\"") != NULL &&
          strstr(g_shell_cb_json, "comment") == NULL,
          "注释/空行跳过，非 file:// URI 原样保留");
    cj_core_drop_files(h, "");
    CHECK(g_shell_cb_calls == 2, "空载荷不回调");
    cj_core_drop_files(h, NULL);
    CHECK(g_shell_cb_calls == 2, "NULL 载荷安全");
    cj_bridge_set_shell_callback(h2, on_shell);
    cj_core_drop_files(h2, "file:///tmp/second.txt");
    CHECK(g_shell_cb_calls == 3 && g_shell_cb_host == h2,
          "第二个宿主的 drop 带回它自己的句柄（句柄路由不串台）");
    cj_core_drop_files(NULL, "file:///tmp/x");
    CHECK(1, "对 NULL 宿主安全");

    /* --- 16c. 全局快捷键：接线层（wire 记 pending + 透传平台；触发报文走 shell 通道）--- */
    case_begin("set_global_hotkeys 接线（pending + 平台透传）");
    reset_counters();
    g_hotkey_calls = 0;
    g_hotkey_last_wire[0] = '\0';
    cj_bridge_set_global_hotkeys(h, "Ctrl+Alt+C:show-panel\nCtrl+Shift+P:pause");
    CHECK(g_hotkey_calls == 1 && strcmp(g_hotkey_last_wire,
          "Ctrl+Alt+C:show-panel\nCtrl+Shift+P:pause") == 0,
          "wire 透传到平台原语（解析与 grab 在平台层）");
    CHECK(h->pending_hotkeys != NULL &&
          strcmp(h->pending_hotkeys, "Ctrl+Alt+C:show-panel\nCtrl+Shift+P:pause") == 0,
          "wire 同时记进 pending（grab 线程启动时读）");
    cj_bridge_set_global_hotkeys(h, "");
    CHECK(g_hotkey_calls == 2 && h->pending_hotkeys != NULL &&
          strcmp(h->pending_hotkeys, "") == 0,
          "空 wire = 全部注销（整表替换语义）");
    cj_bridge_set_global_hotkeys(NULL, "Ctrl+Alt+C:x");
    CHECK(1, "对 NULL 宿主安全");

    case_begin("cj_core_hotkey_pressed 触发报文");
    g_shell_cb_calls = 0;
    cj_bridge_set_shell_callback(h, on_shell);
    cj_core_hotkey_pressed(h, "show-panel");
    CHECK(g_shell_cb_calls == 1 && g_shell_cb_host == h,
          "触发回调一次、带回该宿主句柄");
    CHECK(strstr(g_shell_cb_json, "\"kind\":\"hotkey\"") != NULL &&
          strstr(g_shell_cb_json, "\"id\":\"show-panel\"") != NULL,
          "载荷是 {kind,id} JSON（与菜单点击同族，走 on_shell 通道）");
    cj_core_hotkey_pressed(h, "");
    CHECK(g_shell_cb_calls == 1, "空 id 不回调（无法路由，直接丢弃）");
    cj_bridge_set_shell_callback(h2, on_shell);
    cj_core_hotkey_pressed(h2, "second");
    CHECK(g_shell_cb_calls == 2 && g_shell_cb_host == h2,
          "第二个宿主的触发带回它自己的句柄（句柄路由不串台）");
    cj_core_hotkey_pressed(NULL, "x");
    CHECK(1, "对 NULL 宿主安全");

    /* --- 16d. 托盘：接线层（wire 记 pending + 透传平台；点击报文走 shell 通道）--- */
    case_begin("set_tray 接线（pending + 平台透传）");
    reset_counters();
    g_tray_calls = 0;
    g_tray_last_wire[0] = '\0';
    cj_bridge_set_tray(h, "icon\t/tmp/tray.png\ntooltip\tcj-tauri\nn\ttoggle\t显示/隐藏\t1\t\nn\tquit\t退出\t1\t\n");
    CHECK(g_tray_calls == 1 && strstr(g_tray_last_wire, "icon\t/tmp/tray.png") != NULL &&
          strstr(g_tray_last_wire, "n\ttoggle") != NULL,
          "wire 透传到平台原语（解析与 appindicator 在平台层）");
    CHECK(h->pending_tray != NULL && strstr(h->pending_tray, "tooltip\tcj-tauri") != NULL,
          "wire 同时记进 pending（宿主线程装配时读）");
    cj_bridge_set_tray(h, "");
    CHECK(g_tray_calls == 2 && h->pending_tray != NULL && strcmp(h->pending_tray, "") == 0,
          "空 wire = 移除托盘（pending 同步清空）");
    cj_bridge_set_tray(NULL, "icon\tx");
    CHECK(1, "对 NULL 宿主安全");

    case_begin("cj_core_tray_clicked 触发报文");
    g_shell_cb_calls = 0;
    cj_bridge_set_shell_callback(h, on_shell);
    cj_core_tray_clicked(h, "toggle");
    CHECK(g_shell_cb_calls == 1 && g_shell_cb_host == h,
          "点击回调一次、带回该宿主句柄");
    CHECK(strstr(g_shell_cb_json, "\"kind\":\"tray\"") != NULL &&
          strstr(g_shell_cb_json, "\"id\":\"toggle\"") != NULL,
          "载荷是 {kind,id} JSON（RFC-002 §5.5 的 tray 信封，走 on_shell 通道）");
    cj_core_tray_clicked(h, "");
    CHECK(g_shell_cb_calls == 1, "空 id 不回调（无法路由，直接丢弃）");
    cj_bridge_set_shell_callback(h2, on_shell);
    cj_core_tray_clicked(h2, "quit");
    CHECK(g_shell_cb_calls == 2 && g_shell_cb_host == h2,
          "第二个宿主的点击带回它自己的句柄（句柄路由不串台）");
    cj_core_tray_clicked(NULL, "x");
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

    /* --- 20. 剪贴板：参数校验在 core，平台失败码原样返回 --- */
    case_begin("clipboard 校验与转发");
    CHECK(cj_bridge_clipboard_write_text(NULL, "x") == -1, "NULL 文本被拒（-1）");
    {
        char *big = (char *)malloc((8u << 20) + 1);
        cj_host *hc = cj_bridge_create(); /* 剪贴板是宿主能力：要一个活句柄（不 start，window_gone=0）*/
        if (big && hc) {
            memset(big, 'a', (8u << 20));
            big[8u << 20] = '\0';
            CHECK(cj_bridge_clipboard_write_text(hc, big) == -1, "超 8 MiB 被拒");
            free(big);
        }
        if (hc) {
            g_clip_write_calls = 0;
            g_clip_read_calls = 0;
            free(g_clip_last_written);
            g_clip_last_written = NULL;
            CHECK(cj_bridge_clipboard_write_text(hc, "hello clip") == 0, "写文本成功");
            CHECK(g_clip_write_calls == 1 && g_clip_last_written &&
                  strcmp(g_clip_last_written, "hello clip") == 0, "文本原样到达平台");
            {
                char *got = cj_bridge_clipboard_read_text(hc);
                CHECK(got && strcmp(got, "hello clip") == 0, "读回刚写的文本");
                cj_bridge_clipboard_free(got);
                CHECK(g_clip_read_calls == 1, "读触达平台一次");
            }
            cj_bridge_clipboard_free(NULL);
            CHECK(1, "free(NULL) 幂等安全");
            g_clip_write_ok = 0;
            CHECK(cj_bridge_clipboard_write_text(hc, "x") == -3, "平台失败码返回 -3");
            g_clip_write_ok = 1;
            /* 通知：参数校验 + 发后即忘（投递即返回 0，平台成败看 stderr）*/
            g_note_calls = 0;
            hc->capabilities |= CJ_CAP_NOTIFICATION; /* 通知是宿主能力：声明了才走到平台 */
            CHECK(cj_bridge_notification_notify(hc, "", "b") == -1, "空标题被拒");
            CHECK(cj_bridge_notification_notify(hc, NULL, "b") == -1, "NULL 标题被拒");
            {
                char long_title[258];
                memset(long_title, 't', sizeof(long_title));
                long_title[sizeof(long_title) - 1] = '\0';
                CHECK(cj_bridge_notification_notify(hc, long_title, "b") == -1, "超长标题被拒");
            }
            CHECK(g_note_calls == 0, "被拒的通知不触达平台");
            CHECK(cj_bridge_notification_notify(hc, "hello", "body") == 0, "合法通知提交成功（发后即忘）");
            CHECK(g_note_calls == 1 && g_note_last_title && strcmp(g_note_last_title, "hello") == 0,
                  "标题原样到达平台");
            g_note_ok = 0;
            CHECK(cj_bridge_notification_notify(hc, "x", NULL) == -3, "UI 直行路径平台失败如实回 -3");
            g_note_ok = 1;
            /* 未声明通知能力的平台（如 Windows 桩）要当场拒绝，不能走「发后即忘」被读成成功 */
            hc->capabilities &= ~CJ_CAP_NOTIFICATION;
            g_note_calls = 0;
            CHECK(cj_bridge_notification_notify(hc, "x", "b") == -4, "未声明能力位如实回 -4");
            CHECK(g_note_calls == 0, "未声明能力位不触达平台");
            cj_bridge_destroy(hc);
        }
    }

    /* --- 日志落盘（RFC-003 第 5 期）：接管 stderr、按大小轮转、失败如实回 0 --- */
    case_begin("log file：接管 stderr / 按大小轮转 / 失败如实回 0");
    {
        char dir[256];
        char path[300];
        char archive1[320];
        char archive2[320];
        char archive3[320];
        char blocker[320];
        char unwritable[340];
        char long_path[1200];
        char buf[65536];
        FILE *bf;
        int saved_fd;
        int i;

        snprintf(dir, sizeof(dir), "/tmp/cj-bridge-logtest-%ld", (long)getpid());
        cj_test_mkdir(dir);
        /* 路径故意多两级不存在的目录：默认日志目录（~/.local/state/cj-tauri）常常还不存在，
           走到 ③ 顺带证明「父目录按需建出来」 */
        snprintf(path, sizeof(path), "%s/nested/deep/app.log", dir);
        snprintf(archive1, sizeof(archive1), "%s.1", path);
        snprintf(archive2, sizeof(archive2), "%s.2", path);
        snprintf(archive3, sizeof(archive3), "%s.3", path);

        /* ① 未开启（对照组）：回读空串、不创建文件，c j_logf 仍写 stderr */
        CHECK(strcmp(cj_bridge_log_file(), "") == 0, "未开启时回读空串");
        cj_logf("[bridge-core] probe before enable\n");
        CHECK(cj_test_file_exists(path) == 0, "未开启时不创建日志文件");

        /* ② 参数与失败路径都回 0（stderr 完好，原因打在 stderr 上） */
        CHECK(cj_bridge_set_log_file(NULL, 0, 0) == 0, "NULL 路径被拒");
        CHECK(cj_bridge_set_log_file("", 0, 0) == 0, "空路径被拒");
        memset(long_path, 'a', sizeof(long_path) - 1);
        long_path[sizeof(long_path) - 1] = '\0';
        CHECK(cj_bridge_set_log_file(long_path, 0, 0) == 0, "超长路径被拒");
        /* 「不可写」不能拿一个不存在的目录测：父目录缺失会被如实建出来（默认目录要的就是这行为），
           所以拿一个**普通文件**当路径的中间段——父级不是目录，建也建不了、开也开不了 */
        snprintf(blocker, sizeof(blocker), "%s/blocker", dir);
        bf = fopen(blocker, "wb");
        if (bf) fclose(bf);
        snprintf(unwritable, sizeof(unwritable), "%s/app.log", blocker);
        CHECK(cj_bridge_set_log_file(unwritable, 0, 0) == 0, "不可写路径被拒（父级是普通文件）");
        CHECK(cj_test_file_exists(path) == 0, "被拒的开启不产生文件");
        CHECK(strcmp(cj_bridge_log_file(), "") == 0, "被拒之后仍未激活");

        /* ③ 留底原 stderr fd（必须在接管之前取），然后开启：max 1KB、保留 2 份 */
        saved_fd = dup(2);
        LOG_CHECK(saved_fd >= 0, "留底原 stderr fd 成功");
        LOG_CHECK(cj_bridge_set_log_file(path, 1, 2) == 1, "开启成功回 1（父目录缺失也按需建出来）");
        LOG_CHECK(strcmp(cj_bridge_log_file(), path) == 0, "回读路径与传入一致");
        LOG_CHECK(cj_bridge_set_log_file(path, 1, 2) == 0, "重复开启被拒（换了目标只能重启）");

        /* ④ 开启后的诊断确实落在文件里 */
        cj_logf("[bridge-core] after enable marker=alpha\n");
        CHECK(1, "接管期间断言走 LOG_CHECK（失败行不会丢进日志文件）");
        LOG_CHECK(cj_test_read_all(path, buf, sizeof(buf)) > 0, "日志文件有内容");
        LOG_CHECK(strstr(buf, "[cj-bridge] log file: ") != NULL, "首行记录了日志路径与预算");
        LOG_CHECK(strstr(buf, "marker=alpha") != NULL, "开启后的 cj_logf 落到文件");
        LOG_CHECK(strstr(buf, "[2") != NULL, "落盘行带时间戳前缀（[YYYY-…)");
        LOG_CHECK(strstr(buf, "probe before enable") == NULL, "开启之前的输出不会被追认进文件");

        /* ⑤ 前端/插件通道：写一行 + NULL 拒绝 */
        LOG_CHECK(cj_bridge_log_write(NULL) == -1, "log_write(NULL) 被拒");
        LOG_CHECK(cj_bridge_log_write("[frontend] marker=beta") == 0, "log_write 回 0");
        LOG_CHECK(cj_test_read_all(path, buf, sizeof(buf)) > 0 && strstr(buf, "marker=beta") != NULL,
                  "log_write 的行也落在同一份文件");

        /* ⑥ 轮转：1KB 预算下连写，档案要出现、keep 上限要守住 */
        for (i = 0; i < 60; i++) cj_logf("[bridge-core] filler line %02d padding ................\n", i);
        LOG_CHECK(cj_test_file_exists(archive1) != 0, "超预算后出现 log.1");
        LOG_CHECK(cj_test_read_all(archive1, buf, sizeof(buf)) > 0, "log.1 有内容");
        LOG_CHECK(cj_test_file_exists(archive2) != 0, "继续写出现 log.2");
        LOG_CHECK(cj_test_file_exists(archive3) == 0, "keep=2 时不出现 log.3（上限守住）");
        LOG_CHECK(cj_test_read_all(path, buf, sizeof(buf)) > 0 &&
                  strstr(buf, "log rotated") != NULL, "轮转后当前文件仍继续写（有 rotated 行）");

        /* ⑦ 还原 stderr：后续断言与收尾输出照常可见（顺带证明接管可逆） */
        fflush(stderr);
        dup2(saved_fd, 2);
        close(saved_fd);
        fprintf(stderr, "  - [bridge-core] stderr 已还原（日志用例期间的失败行如下，无输出即全过）\n");
        if (g_log_fail_buf[0]) fprintf(stderr, "%s", g_log_fail_buf);
        CHECK(cj_test_read_all(path, buf, sizeof(buf)) > 0, "还原后仍能读日志文件");
    }

    /* ===== 静默子进程：core 侧的校验与转发（真进程由平台原语负责，实机验证） ===== */
    {
        case_begin("spawn hidden");
        CHECK(cj_bridge_spawn_hidden(NULL, "") == 0, "spawn_hidden(NULL) 被拒");
        CHECK(cj_bridge_spawn_hidden("", "") == 0, "spawn_hidden 空路径被拒");
        CHECK(cj_bridge_spawn_hidden("stub-ok", "a\x1f" "b") == 4242,
              "参数串按 0x1F 分隔转发给平台，pid 原样回给上层");
        CHECK(cj_bridge_spawn_hidden("stub-no", "") == 0, "平台失败时 core 回 0（绝不谎报 pid）");
        CHECK(cj_bridge_kill_pid(0) == 0, "kill_pid(0) 被拒");
        CHECK(cj_bridge_kill_pid(-5) == 0, "kill_pid(负数) 被拒");
        CHECK(cj_bridge_pid_alive(0) == 0, "pid_alive(0) 恒为 0（不落到平台原语）");
    }

    /* ===== 内嵌资源释放：单文件包随包资源（core 负责校验与错误出口） ===== */
    {
        case_begin("extract assets");
        CHECK(cj_bridge_extract_assets(NULL) == -1, "extract_assets(NULL) 被拒");
        CHECK(cj_bridge_extract_assets("") == -1, "extract_assets 空目录被拒");
        CHECK(cj_bridge_extract_assets("some/runtime/dir") == 0,
              "没有内嵌资源的产物如实回 0（普通构建就是这样，不是错误）");
        CHECK(cj_bridge_extract_assets("stub-missing") == -1,
              "平台报错时 core 回 -1（绝不把失败说成 0 个文件）");
    }

    /* ===== 同窗内嵌视图（PLT-006）：core 只做校验，句柄原样透传 ===== */
    {
        long long v;
        int before = g_view_create_calls;

        case_begin("embedded view");
        CHECK(cj_bridge_view_create(NULL, "https://a", 0, 0, 100, 100) == 0,
              "宿主为 NULL 被拒");
        CHECK(cj_bridge_view_create(h, "", 0, 0, 100, 100) == 0, "空 url 被拒");
        CHECK(cj_bridge_view_create(h, "https://a", 0, 0, 0, 100) == 0, "宽 0 被拒");
        CHECK(cj_bridge_view_create(h, "https://a", 0, 0, 100, -3) == 0, "高负数被拒");
        CHECK(g_view_create_calls == before, "被拒的请求一个都没落到平台");

        v = cj_bridge_view_create(h, "https://example.com/x", 12, 34, 800, 560);
        CHECK(v > 0, "合法请求拿到平台句柄");
        CHECK(g_view_bounds_last[0] == 12 && g_view_bounds_last[1] == 34 &&
              g_view_bounds_last[2] == 800 && g_view_bounds_last[3] == 560,
              "矩形按客户区坐标原样转发");

        cj_bridge_view_set_visible(h, v, 1);
        CHECK(g_view_visible_last == 1, "显示转发到平台");
        cj_bridge_view_set_visible(h, v, 0);
        CHECK(g_view_visible_last == 0, "隐藏转发到平台");

        g_view_bounds_calls = 0;
        cj_bridge_view_set_bounds(h, v, 0, 40, 640, 480);
        CHECK(g_view_bounds_calls == 1 && g_view_bounds_last[3] == 480, "重排矩形转发");
        cj_bridge_view_set_bounds(h, v, 0, 40, 0, 480);
        CHECK(g_view_bounds_calls == 1, "非法矩形不透传（宽 <=0）");

        cj_bridge_view_navigate(h, v, "https://b");
        CHECK(g_view_navigate_calls == 1, "导航转发");
        cj_bridge_view_navigate(h, v, "");
        CHECK(g_view_navigate_calls == 1, "空 url 导航被拒");

        cj_bridge_view_destroy(h, v);
        CHECK(g_view_destroy_calls == 1, "销毁转发");
        cj_bridge_view_destroy(h, 0);
        cj_bridge_view_set_visible(h, -2, 1);
        cj_bridge_view_set_bounds(NULL, v, 0, 0, 640, 480);
        cj_bridge_view_set_bounds(h, 0, 0, 0, 1, 1);
        cj_bridge_view_navigate(h, -1, "x");
        cj_bridge_view_set_visible(NULL, v, 1);
        CHECK(g_view_destroy_calls == 1 && g_view_visible_calls == 2 &&
              g_view_bounds_calls == 1,
              "非正句柄与空宿主一律不落平台（未崩）");
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
