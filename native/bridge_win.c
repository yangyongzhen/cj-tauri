/*
 * cj-tauri C 桥（Windows 平台层）：Win32 窗口 + WebView2 宿主原语
 *
 * 本文件只实现 bridge_core.h 的「平台原语清单」+ 宿主线程装配；平台无关逻辑
 * （IPC 回投队列与批处理、对话框单槽状态机、窗口配置存储、生命周期标志、全部导出）
 * 都在 native/bridge_core.c，两平台共用。分层原因见 docs/架构演进-多平台与多窗口.md §2.2。
 *
 * 分层对标 Tauri 2：本文件 = tao(窗口/事件循环) + wry(WebView 抽象) 的 Windows 后端，
 * 上层 IPC 桥 / capability 安全模型（src 目录下的 .cj）跨平台复用。
 *
 * 与 Linux 桥（bridge_linux.c）的差异：
 *  - Windows 的 JS 引擎（V8）运行在 msedgewebview2.exe 独立进程，宿主进程内不跑 JS 引擎，
 *    因此 Linux 上 JSC 栈边界校验导致的「WebView 调用必须在原生 pthread」约束在此不适用；
 *    这里仍保持「独立宿主线程 + JS FIFO 投递」的同构结构，两端 API 与行为一致。
 *  - JS → 宿主：window.chrome.webview.postMessage(JSON.stringify(obj))
 *  - 宿主 → JS：ExecuteScript("window.postMessage(json,'*')")，与 Linux 端完全一致
 *
 * 编译（mingw-w64 / llvm-mingw gcc，见 native/build_win.bat）：
 *   gcc -shared -O2 bridge_core.c bridge_win.c -o libcjtbridge.dll \
 *       -Wl,--out-implib,libcjtbridge.dll.a \
 *       -I<WebView2 SDK>/build/native/include \
 *       -lole32 -loleaut32 -luuid -luser32 -lgdi32
 * 运行期要求：libcjtbridge.dll 与 WebView2Loader.dll 位于 exe 目录或 PATH 中。
 */
#define UNICODE
#define _UNICODE
/* 条件变量（CONDITION_VARIABLE）要 Vista+ 的头；WebView2 本身就要求 Win10，写 0x0601 足够 */
#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <commdlg.h>
#include <objbase.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "WebView2.h"
#include "bridge_core.h"

/* ===== COM 回调对象（每个宿主一套）=====
   原先 4 个 handler 是静态单例（AddRef/Release 硬编码 return 1），多窗口一落地就分不清是谁的回调；
   现在按宿主内嵌，This 直接转回本结构就能拿到 cj_host。引用计数仍恒 1：对象随宿主句柄存续
   （句柄壳活到 cj_bridge_destroy），这是 WebView2 手工 COM 的惯用写法，也是 AGENTS.md §4 里
   hr=0x8007139F 那个坑的由来——AddRef 若返回 0 / 不自持有，注册给 WebView2 的回调会被提前回收。 */
typedef struct env_handler {
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler iface; /* 首成员：This == &iface */
    cj_host *h;
} env_handler;

typedef struct ctrl_handler {
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler iface;
    cj_host *h;
} ctrl_handler;

typedef struct msg_handler {
    ICoreWebView2WebMessageReceivedEventHandler iface;
    cj_host *h;
} msg_handler;

typedef struct nav_handler {
    ICoreWebView2NavigationCompletedEventHandler iface;
    cj_host *h;
} nav_handler;

/* ===== 菜单栏（RFC-002 §5.4 / §5.5）=====
   core 把线路文本交下来，本文件翻译成 Win32 菜单栏。菜单栏是**每窗口**资源（HMENU 挂在窗口上），
   建 / 换 / 改都必须在 UI 线程上做——跨线程调用一律 PostMessage 到宿主线程。 */
#define CJ_MENU_MAX_ITEMS 64
#define CJ_MENU_MAX_DEPTH 8

typedef struct menu_slot {
    UINT cmd_id;   /* 建菜单时分配的命令 id（WM_COMMAND 带回来的那个），从 1 开始 */
    char *app_id;  /* 应用给的稳定 id：回投仓颉侧，也是 set_menu_item_state 的查找键 */
    char kind;     /* 'n' 普通 / 'c' 勾选（点击时由我们自己翻转勾选状态）*/
    int enabled;
    int checked;
} menu_slot;

/* ===== 每个宿主的平台私有状态 =====
   原先是一堆进程级单例（g_hwnd / g_controller / g_environment / g_webview / g_host_thread_id …）。
   现在挂在自己的 cj_host->plat 上，平台函数一律从入参句柄取状态。 */
typedef struct plat_host {
    HWND hwnd;                                /* 主窗口；WM_DESTROY 后置空 */
    ICoreWebView2Controller *controller;
    ICoreWebView2Environment *environment;    /* 必须自己持有一份引用（见 env_Invoke）*/
    ICoreWebView2 *webview;
    HANDLE thread;                            /* 宿主线程句柄（cj_plat_fini 里 join 用）*/
    DWORD thread_id;                          /* 宿主线程 id：判断「调用方是否已在宿主线程」*/
    int thread_started;
    int thread_set;
    volatile int thread_done;                 /* 宿主线程跑完（收尾最后一步）：见 cj_plat_fini */
    HMODULE loader;                           /* WebView2Loader.dll */
    env_handler env;
    ctrl_handler ctrl;
    msg_handler msg;
    nav_handler nav;
    /* --- 菜单栏（只在 UI 线程上建 / 换 / 改）--- */
    HMENU menu;                               /* 当前菜单栏；NULL = 没有 */
    menu_slot menu_items[CJ_MENU_MAX_ITEMS];  /* 命令 id ↔ 应用 id 映射：WM_COMMAND 靠它回投 */
    int menu_item_count;
} plat_host;

/* ===== 同步原语（core 只用这些，绝不直接碰 Win32）=====
   与 Linux 桥的 pthread_mutex + pthread_cond 一一对应；用条件变量而不是「事件」的好处是
   谓词在锁内检查，不存在「先 SetEvent 后 CreateEvent 丢唤醒」的时序坑。 */

struct cj_sync {
    CRITICAL_SECTION cs;
    CONDITION_VARIABLE cv;
};

cj_sync *cj_plat_sync_create(void) {
    cj_sync *s = (cj_sync *)calloc(1, sizeof(cj_sync));
    if (!s) return NULL;
    InitializeCriticalSection(&s->cs);
    InitializeConditionVariable(&s->cv);
    return s;
}

void cj_plat_sync_destroy(cj_sync *s) {
    if (!s) return;
    DeleteCriticalSection(&s->cs); /* CONDITION_VARIABLE 无需销毁 */
    free(s);
}

void cj_plat_sync_lock(cj_sync *s) {
    if (s) EnterCriticalSection(&s->cs);
}

void cj_plat_sync_unlock(cj_sync *s) {
    if (s) LeaveCriticalSection(&s->cs);
}

void cj_plat_sync_wait(cj_sync *s, int *ready) {
    if (!s || !ready) return;
    while (!*ready) {
        SleepConditionVariableCS(&s->cv, &s->cs, INFINITE);
    }
}

void cj_plat_sync_signal(cj_sync *s) {
    if (s) WakeConditionVariable(&s->cv);
}

/* ===== UTF-8 <-> UTF-16 ===== */

static wchar_t *utf8_to_wide(const char *s) {
    if (!s) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (!w) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

static char *wide_to_utf8(const wchar_t *w) {
    if (!w) return NULL;
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *s = (char *)malloc((size_t)n);
    if (!s) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
    return s;
}

/* 关键 WebView2 调用的 HRESULT 上报 */
static void log_hr(const char *what, HRESULT hr) {
    fprintf(stderr, "[cj-bridge] %s -> hr=0x%08lx\n", what, (unsigned long)hr);
}

/* ===== 注入前端桥接脚本（暴露 window.__CJ_TAURI__，对标 @tauri-apps/api）===== */

/* 平台唯一差异行（其余 JS 见 native/bridge_js.h，两平台共用一份，防漂移）：
   post 通道 = chrome.webview；reload 控制消息同通道发字面量。宽字符：本文件要 wchar_t。 */
#define CJ_LIT(s) L##s
#define CJ_POST_STMT L"    window.chrome.webview.postMessage(JSON.stringify(obj));"
#define CJ_RELOAD_STMT L"      window.chrome.webview.postMessage('__cj_tauri_reload__');"
#include "bridge_js.h"

static const wchar_t *BRIDGE_JS = CJ_BRIDGE_JS(CJ_POST_STMT, CJ_RELOAD_STMT);

/* ===== 投递通道用到的窗口消息（PostMessage 按窗口寻址，句柄从窗口 USERDATA 取）===== */

#define WM_CJT_FLUSH (WM_APP + 1)
#define WM_CJT_QUIT (WM_APP + 2)
#define WM_CJT_DEVTOOLS (WM_APP + 3)
#define WM_CJT_LOAD_URL (WM_APP + 4)
#define WM_CJT_RELOAD (WM_APP + 5)
#define WM_CJT_DIALOG (WM_APP + 6)
#define WM_CJT_MENU (WM_APP + 7)       /* 运行期换菜单：lParam = strdup 的线路文本（UI 线程释放）*/
#define WM_CJT_MENU_ITEM (WM_APP + 8)  /* 运行期改单项状态：lParam = menu_state_msg*（UI 线程释放）*/

/* 运行期改单项状态：跨线程传递的小包裹（谁 post 谁分配，UI 线程处理完释放）*/
typedef struct menu_state_msg {
    char *id;
    int enabled;
    int checked;
} menu_state_msg;

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);
/* 菜单实现集中在文件末尾；宿主线程与窗口过程要用，先声明 */
static void menu_apply_wire(cj_host *h, plat_host *p, const char *wire);
static void menu_apply_item_state(plat_host *p, const char *id, int enabled, int checked);
static void menu_clear_slots(plat_host *p);

/* ===== COM 回调实现（完成/事件 handler）===== */

/* --- 环境创建完成 --- */

static HRESULT STDMETHODCALLTYPE env_QueryInterface(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This, REFIID riid, void **ppvObject) {
    if (ppvObject) *ppvObject = This;
    return S_OK;
}

static ULONG STDMETHODCALLTYPE env_AddRef(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This) {
    return 1;
}

static ULONG STDMETHODCALLTYPE env_Release(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This) {
    return 1;
}

static HRESULT STDMETHODCALLTYPE env_Invoke(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This,
        HRESULT errorCode, ICoreWebView2Environment *result) {
    env_handler *self = (env_handler *)This;
    cj_host *h = self ? self->h : NULL;
    plat_host *p = h ? (plat_host *)h->plat : NULL;

    if (!h || !p) return S_OK;
    if (FAILED(errorCode) || !result) {
        fprintf(stderr, "[cj-bridge] create WebView2 environment failed: 0x%08lx\n",
                (unsigned long)errorCode);
        h->should_quit = 1;
        cj_core_window_destroyed(h); /* 通知仓颉侧（onDestroy 恰好一次）+ 作废对话框 */
        if (p->hwnd) PostMessageW(p->hwnd, WM_CJT_QUIT, 0, 0);
        return S_OK;
    }
    /* 必须自己持有一份环境引用：否则本回调返回后环境对象被释放，
       WebView2 会随即关闭浏览器进程，表现为导航不完成、ExecuteScript 返回 0x8007139F */
    p->environment = result;
    p->environment->lpVtbl->AddRef(p->environment);
    result->lpVtbl->CreateCoreWebView2Controller(result, p->hwnd, &p->ctrl.iface);
    fprintf(stderr, "[cj-bridge] WebView2 environment ready\n");
    return S_OK;
}

static ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl g_env_vtbl = {
    env_QueryInterface, env_AddRef, env_Release, env_Invoke
};

/* --- 控制器（WebView）创建完成：装配 WebView、注入桥、加载 HTML --- */

static HRESULT STDMETHODCALLTYPE ctrl_QueryInterface(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This, REFIID riid, void **ppvObject) {
    if (ppvObject) *ppvObject = This;
    return S_OK;
}

static ULONG STDMETHODCALLTYPE ctrl_AddRef(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This) {
    return 1;
}

static ULONG STDMETHODCALLTYPE ctrl_Release(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This) {
    return 1;
}

static HRESULT STDMETHODCALLTYPE ctrl_Invoke(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This,
        HRESULT errorCode, ICoreWebView2Controller *result) {
    ctrl_handler *self = (ctrl_handler *)This;
    cj_host *h = self ? self->h : NULL;
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    RECT rc;
    int i;

    if (!h || !p) return S_OK;
    if (FAILED(errorCode) || !result) {
        fprintf(stderr, "[cj-bridge] create WebView2 controller failed: 0x%08lx\n",
                (unsigned long)errorCode);
        h->should_quit = 1;
        cj_core_window_destroyed(h);
        if (p->hwnd) PostMessageW(p->hwnd, WM_CJT_QUIT, 0, 0);
        return S_OK;
    }
    p->controller = result;
    p->controller->lpVtbl->AddRef(p->controller);
    result->lpVtbl->get_CoreWebView2(result, &p->webview);
    if (!p->webview) {
        fprintf(stderr, "[cj-bridge] get_CoreWebView2 failed\n");
        return S_OK;
    }

    /* 先让父窗口可见，再摆放 WebView：不可见的父窗口会挂起渲染 */
    ShowWindow(p->hwnd, SW_SHOW);
    UpdateWindow(p->hwnd);

    GetClientRect(p->hwnd, &rc);
    result->lpVtbl->put_Bounds(result, rc);
    result->lpVtbl->put_IsVisible(result, TRUE);

    /* WebView 行为设置 */
    {
        ICoreWebView2Settings *settings = NULL;
        HRESULT hr = p->webview->lpVtbl->get_Settings(p->webview, &settings);
        if (SUCCEEDED(hr) && settings) {
            settings->lpVtbl->put_IsStatusBarEnabled(settings, FALSE);
            settings->lpVtbl->put_IsZoomControlEnabled(settings, FALSE);
            settings->lpVtbl->put_AreDefaultContextMenusEnabled(settings, TRUE);
            settings->lpVtbl->put_AreDevToolsEnabled(settings, h->devtools ? TRUE : FALSE);
            settings->lpVtbl->Release(settings);
        }
    }

    /* 注入桥接脚本（页面脚本执行前）+ 注册 JS 消息通道 */
    p->webview->lpVtbl->AddScriptToExecuteOnDocumentCreated(p->webview, BRIDGE_JS, NULL);
    /* 预执行脚本按注册顺序追加在桥之后（WebView2 按注册顺序执行），脚本里可直接用 window.__CJ_TAURI__ */
    for (i = 0; i < h->init_script_count; i++) {
        wchar_t *w = utf8_to_wide(h->init_scripts[i]);
        if (w) {
            p->webview->lpVtbl->AddScriptToExecuteOnDocumentCreated(p->webview, w, NULL);
            free(w);
        }
    }
    fprintf(stderr, "[cj-bridge] init scripts injected: %d\n", h->init_script_count);
    p->webview->lpVtbl->add_WebMessageReceived(p->webview, &p->msg.iface, NULL);
    p->webview->lpVtbl->add_NavigationCompleted(p->webview, &p->nav.iface, NULL);

    cj_core_set_ready(h);
    fprintf(stderr, "[cj-bridge] controller ready, loading page\n");

    /* 页面来源：URL 优先（cj_bridge_load_url），否则内联 HTML（cj_bridge_start） */
    if (h->pending_url) {
        wchar_t *w = utf8_to_wide(h->pending_url);
        if (w) {
            log_hr("Navigate", p->webview->lpVtbl->Navigate(p->webview, w));
            free(w);
        }
        fprintf(stderr, "[cj-bridge] url navigation requested: %s\n", h->pending_url);
    } else if (h->pending_html) {
        wchar_t *w = utf8_to_wide(h->pending_html);
        if (w) {
            log_hr("NavigateToString", p->webview->lpVtbl->NavigateToString(p->webview, w));
            free(w);
        }
        fprintf(stderr, "[cj-bridge] html navigation requested\n");
    }
    /* 宿主就绪前可能已有排队脚本（如启动即推送的事件） */
    cj_core_flush_js(h);
    return S_OK;
}

static ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl g_ctrl_vtbl = {
    ctrl_QueryInterface, ctrl_AddRef, ctrl_Release, ctrl_Invoke
};

/* --- JS → 宿主的消息（chrome.webview.postMessage 的字符串载荷）--- */

static HRESULT STDMETHODCALLTYPE msg_QueryInterface(
        ICoreWebView2WebMessageReceivedEventHandler *This, REFIID riid, void **ppvObject) {
    if (ppvObject) *ppvObject = This;
    return S_OK;
}

static ULONG STDMETHODCALLTYPE msg_AddRef(ICoreWebView2WebMessageReceivedEventHandler *This) {
    return 1;
}

static ULONG STDMETHODCALLTYPE msg_Release(ICoreWebView2WebMessageReceivedEventHandler *This) {
    return 1;
}

static HRESULT STDMETHODCALLTYPE msg_Invoke(
        ICoreWebView2WebMessageReceivedEventHandler *This,
        ICoreWebView2 *sender, ICoreWebView2WebMessageReceivedEventArgs *args) {
    msg_handler *self = (msg_handler *)This;
    cj_host *h = self ? self->h : NULL;
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    LPWSTR payload = NULL;

    if (SUCCEEDED(args->lpVtbl->TryGetWebMessageAsString(args, &payload)) && payload) {
        char *utf8 = wide_to_utf8(payload);
        CoTaskMemFree(payload);
        if (utf8) {
            /* 前端 __CJ_TAURI__.reload()：宿主控制消息，不进 IPC hub */
            if (strcmp(utf8, CJT_RELOAD_MSG) == 0) {
                fprintf(stderr, "[cj-bridge] frontend requested reload\n");
                if (p && p->hwnd) PostMessageW(p->hwnd, WM_CJT_RELOAD, 0, 0);
                free(utf8);
                return S_OK;
            }
            fprintf(stderr, "[cj-bridge] js -> native (%d bytes)\n", (int)strlen(utf8));
            if (h && h->on_message) h->on_message(utf8); /* 回调仓颉（IPC hub） */
            free(utf8);
        }
    }
    return S_OK;
}

static ICoreWebView2WebMessageReceivedEventHandlerVtbl g_msg_vtbl = {
    msg_QueryInterface, msg_AddRef, msg_Release, msg_Invoke
};

/* --- 导航完成：仅在失败时上报（成功无需打扰用户）--- */

static HRESULT STDMETHODCALLTYPE nav_QueryInterface(
        ICoreWebView2NavigationCompletedEventHandler *This, REFIID riid, void **ppvObject) {
    if (ppvObject) *ppvObject = This;
    return S_OK;
}

static ULONG STDMETHODCALLTYPE nav_AddRef(ICoreWebView2NavigationCompletedEventHandler *This) {
    return 1;
}

static ULONG STDMETHODCALLTYPE nav_Release(ICoreWebView2NavigationCompletedEventHandler *This) {
    return 1;
}

static HRESULT STDMETHODCALLTYPE nav_Invoke(
        ICoreWebView2NavigationCompletedEventHandler *This,
        ICoreWebView2 *sender, ICoreWebView2NavigationCompletedEventArgs *args) {
    BOOL ok = FALSE;
    COREWEBVIEW2_WEB_ERROR_STATUS status = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
    args->lpVtbl->get_IsSuccess(args, &ok);
    args->lpVtbl->get_WebErrorStatus(args, &status);
    if (!ok) {
        fprintf(stderr, "[cj-bridge] navigation failed: web error status=%d\n", (int)status);
    }
    return S_OK;
}

static ICoreWebView2NavigationCompletedEventHandlerVtbl g_nav_vtbl = {
    nav_QueryInterface, nav_AddRef, nav_Release, nav_Invoke
};

/* ===== 原生对话框（原生弹窗部分；状态机在 core）===== */

/* "描述|模式|描述|模式" → Win32 双 NUL 过滤器串（末尾落单的描述段按 *.* 处理） */
static wchar_t *build_win_filter(const char *filter) {
    const char *p;
    wchar_t *out;
    size_t cap, len = 0;

    if (!filter || !filter[0]) {
        filter = "所有文件 (*.*)|*.*";
    }
    cap = strlen(filter) * 4 + 8; /* UTF-8 → UTF-16 上界，末尾留双 NUL 位 */
    out = (wchar_t *)calloc(cap, sizeof(wchar_t));
    if (!out) return NULL;

    p = filter;
    while (p && p[0]) {
        const char *bar = strchr(p, '|');
        size_t seg = bar ? (size_t)(bar - p) : strlen(p);
        int n = MultiByteToWideChar(CP_UTF8, 0, p, (int)seg, out + len, (int)(cap - len - 2));
        if (n > 0) {
            len += (size_t)n;
            out[len++] = 0; /* 段结束符 */
        }
        if (!bar) {
            break;
        }
        if (!bar[1]) { /* 末尾落单的描述段：补一个 *.* 当模式 */
            int m = MultiByteToWideChar(CP_UTF8, 0, "*.*", 3, out + len, (int)(cap - len - 2));
            if (m > 0) {
                len += (size_t)m;
                out[len++] = 0;
            }
            break;
        }
        p = bar + 1;
    }
    out[len] = 0; /* 双 NUL 收尾（上一格已经是 0） */
    return out;
}

/* 已经站在宿主线程上：直接弹一次，返回 1 = 确认；选中路径写入 *out_path（由调用方 free） */
static int show_dialog_here(cj_host *h, int kind, const char *title, const char *message,
                            const char *filter, char **out_path) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    HWND owner = p ? p->hwnd : NULL;
    int ok = 0;

    *out_path = NULL;
    if (kind <= 1) {
        wchar_t path[32768];
        wchar_t *title_w = utf8_to_wide(title[0] ? title : (kind == 1 ? "保存文件" : "打开文件"));
        wchar_t *filter_w = build_win_filter(filter);
        OPENFILENAMEW ofn;

        path[0] = 0;
        ZeroMemory(&ofn, sizeof(ofn));
        ofn.lStructSize = sizeof(ofn);
        ofn.hwndOwner = owner;
        ofn.lpstrFile = path;
        ofn.nMaxFile = (DWORD)(sizeof(path) / sizeof(path[0]));
        ofn.lpstrFilter = filter_w;
        ofn.nFilterIndex = 1;
        ofn.lpstrTitle = title_w;
        ofn.Flags = OFN_EXPLORER | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR |
                    ((kind == 1) ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
        {
            BOOL got = (kind == 1) ? GetSaveFileNameW(&ofn) : GetOpenFileNameW(&ofn);
            if (got) {
                *out_path = wide_to_utf8(path);
                ok = 1;
            } else {
                DWORD err = CommDlgExtendedError();
                if (err) {
                    fprintf(stderr, "[cj-bridge] dialog failed: CommDlgExtendedError=0x%lx\n",
                            (unsigned long)err);
                }
            }
        }
        free(title_w);
        free(filter_w);
    } else {
        UINT flags = MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND;
        wchar_t *title_w, *msg_w;

        if (kind == 3) {
            flags = MB_OK | MB_ICONWARNING | MB_SETFOREGROUND;
        } else if (kind == 4) {
            flags = MB_OK | MB_ICONERROR | MB_SETFOREGROUND;
        } else if (kind == 5) {
            flags = MB_OKCANCEL | MB_ICONQUESTION | MB_SETFOREGROUND;
        }
        title_w = utf8_to_wide(title[0] ? title : "cj-tauri");
        msg_w = utf8_to_wide(message[0] ? message : " ");
        {
            int res = MessageBoxW(owner, msg_w, title_w, flags);
            ok = (kind == 5) ? (res == IDOK) : 1;
        }
        free(title_w);
        free(msg_w);
    }
    return ok;
}

int cj_plat_run_dialog(cj_host *h, dlg_req *req) {
    if (!req) return 0;
    req->ok = show_dialog_here(h, req->kind, req->title, req->message, req->filter, &req->path);
    return req->ok;
}

void cj_plat_post_dialog(cj_host *h, dlg_req *req) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || !p->hwnd) {
        fprintf(stderr, "[cj-bridge] dialog post failed: window not ready\n");
        cj_core_dialog_abort(h); /* 投不出去就别让调用方干等 */
        return;
    }
    if (!PostMessageW(p->hwnd, WM_CJT_DIALOG, 0, (LPARAM)req)) {
        fprintf(stderr, "[cj-bridge] dialog post failed: %lu\n", (unsigned long)GetLastError());
        cj_core_dialog_abort(h);
    }
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    /* 句柄从窗口自己的 USERDATA 取：PostMessage 按窗口寻址，谁收到就是谁的宿主 */
    cj_host *h = (cj_host *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    plat_host *p = h ? (plat_host *)h->plat : NULL;

    switch (msg) {
    case WM_NCCREATE: {
        /* 唯一安全时机：CreateWindowExW 的 lpParam 在这里交回来，之后这个窗口就知道自己属于谁 */
        CREATESTRUCTW *cs = (CREATESTRUCTW *)lp;
        if (cs) {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
        }
        break; /* 交给 DefWindowProcW 继续（它对 WM_NCCREATE 返回 TRUE）*/
    }
    case WM_SIZE:
        if (p && p->controller) {
            RECT rc;
            GetClientRect(hwnd, &rc);
            p->controller->lpVtbl->put_Bounds(p->controller, rc);
        }
        return 0;
    case WM_CJT_FLUSH:
        cj_core_flush_js(h);
        return 0;
    case WM_CJT_QUIT:
        DestroyWindow(hwnd);
        return 0;
    case WM_CJT_DEVTOOLS:
        if (p && p->webview) {
            p->webview->lpVtbl->OpenDevToolsWindow(p->webview);
        }
        return 0;
    case WM_CJT_RELOAD:
        if (p && p->webview) {
            log_hr("Reload", p->webview->lpVtbl->Reload(p->webview));
        }
        return 0;
    case WM_CJT_LOAD_URL: {
        /* lParam 是跨线程传过来的宽字符串，由宿主线程负责释放 */
        wchar_t *w = (wchar_t *)lp;
        if (p && p->webview && w) {
            log_hr("Navigate", p->webview->lpVtbl->Navigate(p->webview, w));
        }
        free(w);
        return 0;
    }
    case WM_CJT_MENU: {
        /* lParam 是调用方 strdup 的线路文本：宿主线程用完即释放（与 WM_CJT_LOAD_URL 同规）*/
        char *wire = (char *)lp;
        if (wire && h && p) {
            menu_apply_wire(h, p, wire);
        }
        free(wire);
        return 0;
    }
    case WM_CJT_MENU_ITEM: {
        menu_state_msg *m = (menu_state_msg *)lp;
        if (m) {
            if (p) {
                menu_apply_item_state(p, m->id, m->enabled, m->checked);
            }
            free(m->id);
            free(m);
        }
        return 0;
    }
    case WM_COMMAND: {
        /* 菜单项：LOWORD(wp) 是建菜单时分配的命令 id；0 = 没有命令（分隔线 / 子菜单标题）*/
        UINT cmd = (UINT)LOWORD(wp);
        if (h && p && cmd) {
            int i;
            for (i = 0; i < p->menu_item_count; i++) {
                menu_slot *s = &p->menu_items[i];
                if (s->cmd_id != cmd) continue;
                if (s->kind == 'c') {
                    /* Win32 不会替我们翻转勾选：自己翻，并同步菜单上的勾 */
                    s->checked = s->checked ? 0 : 1;
                    CheckMenuItem(p->menu, cmd,
                                  MF_BYCOMMAND | (s->checked ? MF_CHECKED : MF_UNCHECKED));
                }
                cj_core_menu_clicked(h, s->app_id, s->enabled, s->checked);
                break;
            }
        }
        return 0;
    }
    case WM_CJT_DIALOG:
        /* lParam 是调用方（仓颉线程）堆上的请求：宿主线程只填结果，释放仍归调用方 */
        if (lp) {
            cj_core_dialog_tick(h, (dlg_req *)lp);
        }
        return 0;
    case WM_DESTROY:
        if (p) {
            p->hwnd = NULL; /* 窗口没了：别再往它 PostMessage */
        }
        /* 置 should_quit + 触发 onDestroy（每个宿主恰好一次）+ 作废进行中的对话框 */
        cj_core_window_destroyed(h);
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    /* Cases above that break instead of returning (currently WM_NCCREATE) land
       here. Returning DefWindowProcW is mandatory: it is the one that answers
       TRUE to WM_NCCREATE. Falling off the end leaves the return value
       indeterminate, CreateWindowExW reads it as FALSE and the window creation
       fails with GetLastError() == 0 -- which is exactly what it looks like. */
    return DefWindowProcW(hwnd, msg, wp, lp);
}

/* ===== 宿主线程（对标 tao 的事件循环线程）===== */

/* WebView2Loader 的两种加载方式：
     · 默认（动态桥 / 便携包）：运行期按名字找 WebView2Loader.dll（exe 目录或 PATH）；
     · 单文件产物（-DCJ_EMBED_WEBVIEW2_LOADER）：把 loader 的字节直接编进 exe，首次运行时
       释放到 %TEMP%\cj-tauri-loader\ 再按绝对路径加载（幂等：大小一致就不重写）。
   为什么不是「静态链 WebView2LoaderStatic.lib」：那份 .lib 是 MSVC 编的，要 /GS 的
   __security_cookie 与 C++ 运行时符号（?nothrow@std@@、_Init_thread_epoch …），
   2026-10-07 mingw 实测链接失败（ld.lld: undefined symbol: __security_cookie）。 */
#ifdef CJ_EMBED_WEBVIEW2_LOADER
#include "webview2_loader_embed.h"   /* 打包脚本生成的 C 头：字节数组 + 长度 */

static int write_bytes(HANDLE f, const unsigned char *p, DWORD total) {
    DWORD off = 0;
    while (off < total) {
        DWORD wrote = 0;
        if (!WriteFile(f, p + off, total - off, &wrote, NULL) || wrote == 0) {
            return 0;
        }
        off += wrote;
    }
    return 1;
}

/* 把内嵌的 loader 释放成文件，成功时把绝对路径写进 out。
   路径拼接一律用 lstrcpyW/lstrcatW：mingw 的 swprintf 在默认方言下走 MSVCRT 语义，
   `%s` 收的是 char* 而不是 wchar_t* —— 拼出来是垃圾路径，而且失败时一声不响
   （2026-10-07 实测：日志只有一句 "failed to unpack embedded WebView2Loader.dll"）。 */
static int unpack_embedded_loader(wchar_t *out, DWORD cap) {
    wchar_t tmp[MAX_PATH];
    wchar_t dir[MAX_PATH];
    DWORD n = GetTempPathW(MAX_PATH, tmp);
    if (n == 0 || n + 32 >= MAX_PATH) {
        fprintf(stderr, "[cj-bridge] embedded loader: GetTempPathW failed: err=%lu\n",
                GetLastError());
        return 0;
    }
    lstrcpyW(dir, tmp);
    lstrcatW(dir, L"cj-tauri-loader");
    if (!CreateDirectoryW(dir, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) {
        fprintf(stderr, "[cj-bridge] embedded loader: CreateDirectoryW(%ls) err=%lu\n",
                dir, GetLastError());
        /* 建不出来也不立刻放弃：目录可能本来就存在且可写 */
    }
    lstrcpyW(out, dir);
    lstrcatW(out, L"\\WebView2Loader.dll");
    {
        WIN32_FILE_ATTRIBUTE_DATA attr;
        if (GetFileAttributesExW(out, GetFileExInfoStandard, &attr)) {
            LARGE_INTEGER sz;
            sz.HighPart = (LONG)attr.nFileSizeHigh;
            sz.LowPart = attr.nFileSizeLow;
            if (sz.QuadPart == (LONGLONG)CJ_WV2_LOADER_SIZE) {
                return 1;                  /* 已经释放过同一份 */
            }
        }
    }
    {
        HANDLE f = CreateFileW(out, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_NORMAL, NULL);
        int ok;
        if (f == INVALID_HANDLE_VALUE) {
            fprintf(stderr, "[cj-bridge] embedded loader: CreateFileW(%ls) err=%lu\n",
                    out, GetLastError());
            return 0;
        }
        ok = write_bytes(f, CJ_WV2_LOADER_BYTES, (DWORD)CJ_WV2_LOADER_SIZE);
        CloseHandle(f);
        if (!ok) {
            fprintf(stderr, "[cj-bridge] embedded loader: WriteFile failed: err=%lu\n",
                    GetLastError());
        }
        return ok;
    }
}

static HMODULE load_webview2_loader(void) {
    wchar_t path[MAX_PATH];
    if (unpack_embedded_loader(path, MAX_PATH)) {
        HMODULE m = LoadLibraryW(path);
        if (m) {
            fprintf(stderr, "[cj-bridge] WebView2Loader unpacked to %%TEMP%% and loaded\n");
            return m;
        }
        fprintf(stderr, "[cj-bridge] unpacked WebView2Loader refused to load: err=%lu\n",
                GetLastError());
    } else {
        fprintf(stderr, "[cj-bridge] failed to unpack embedded WebView2Loader.dll\n");
    }
    /* 退回按名字找：失败文案与默认模式一致，便于对照 */
    return LoadLibraryW(L"WebView2Loader.dll");
}
#else
static HMODULE load_webview2_loader(void) {
    return LoadLibraryW(L"WebView2Loader.dll");
}
#endif

typedef HRESULT(STDMETHODCALLTYPE *pfn_create_env)(
        PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions *,
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);

static const wchar_t *WINDOW_CLASS = L"CjTauriWindow";

static DWORD WINAPI host_thread_main(LPVOID param) {
    cj_host *h = (cj_host *)param;
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    pfn_create_env create_env = NULL;
    WNDCLASSEXW wc;
    MSG msg;
    wchar_t *title_w = NULL;  /* 宽字符标题（用完即 free）*/
    wchar_t *icon_w = NULL;
    HICON icon_big = NULL;    /* 窗口图标（h->win_icon 非空时才加载）*/
    HICON icon_small = NULL;

    if (!p) return 0;
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    fprintf(stderr, "[cj-bridge] host thread started\n");

    /* WebView2 的入口在 WebView2Loader.dll 中（默认按名字找；单文件产物从内嵌字节释放） */
    p->loader = load_webview2_loader();
    if (!p->loader) {
        fprintf(stderr, "[cj-bridge] WebView2Loader.dll not found: "
                        "put it next to the exe or on PATH\n");
        goto done;
    }
    create_env = (pfn_create_env)GetProcAddress(p->loader, "CreateCoreWebView2EnvironmentWithOptions");
    if (!create_env) {
        fprintf(stderr, "[cj-bridge] CreateCoreWebView2EnvironmentWithOptions not found\n");
        goto done;
    }
    {
        /* 诊断：x64 宿主是否能看到可用运行时（排障用，可删） */
        typedef HRESULT(STDAPICALLTYPE *pfn_getver)(PCWSTR, LPWSTR *);
        pfn_getver getver =
            (pfn_getver)GetProcAddress(p->loader, "GetAvailableCoreWebView2BrowserVersionString");
        if (getver) {
            LPWSTR ver = NULL;
            HRESULT hr = getver(NULL, &ver);
            char *v8 = ver ? wide_to_utf8(ver) : NULL;
            fprintf(stderr, "[cj-bridge] WebView2 runtime: hr=0x%08lx ver=%s\n",
                    (unsigned long)hr, v8 ? v8 : "(none)");
            free(v8);
            if (ver) CoTaskMemFree(ver);
        }
    }
    fprintf(stderr, "[cj-bridge] WebView2Loader loaded\n");

    /* 标题/图标在 core 里是 UTF-8，窗口类与窗口要宽字符，在这里转换 */
    title_w = h->win_title ? utf8_to_wide(h->win_title) : NULL;
    icon_w = h->win_icon ? utf8_to_wide(h->win_icon) : NULL;

    /* 窗口图标：在 RegisterClassExW 之前加载并挂到窗口类上，
       这样任务栏与 Alt-Tab 也用同一个图标；失败只是回到系统默认图标，不阻断启动。 */
    if (icon_w) {
        icon_big = (HICON)LoadImageW(NULL, icon_w, IMAGE_ICON,
                                     GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON),
                                     LR_LOADFROMFILE);
        icon_small = (HICON)LoadImageW(NULL, icon_w, IMAGE_ICON,
                                       GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
                                       LR_LOADFROMFILE);
        /* GetLastError 只在失败时才有意义：成功时它是上一次调用的残留值（常见 6 = 无效句柄） */
        if (icon_big && icon_small) {
            fprintf(stderr, "[cj-bridge] window icon: path=%s loaded (big=%p small=%p)\n",
                    h->win_icon, (void *)icon_big, (void *)icon_small);
        } else {
            fprintf(stderr, "[cj-bridge] window icon FAILED: path=%s hIcon=%p/%p err=%lu\n",
                    h->win_icon, (void *)icon_big, (void *)icon_small,
                    (unsigned long)GetLastError());
        }
    }

    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.lpszClassName = WINDOW_CLASS;
    wc.hIcon = icon_big; /* 可空：空则用系统默认 */
    wc.hIconSm = icon_small;
    RegisterClassExW(&wc);

    /* 先记下宿主线程身份：对话框要靠它判断「调用方是不是已经在本线程上」 */
    p->thread_id = GetCurrentThreadId();
    p->thread_set = 1;

    /* lpParam = 宿主句柄：WM_NCCREATE 里存进窗口 USERDATA，之后 PostMessage 按窗口寻址即找到宿主 */
    p->hwnd = CreateWindowExW(0, WINDOW_CLASS, title_w ? title_w : L"cj-tauri", WS_OVERLAPPEDWINDOW,
                              CW_USEDEFAULT, CW_USEDEFAULT, h->win_w, h->win_h,
                              NULL, NULL, wc.hInstance, h);
    if (!p->hwnd) {
        fprintf(stderr, "[cj-bridge] CreateWindowExW failed: %lu\n", GetLastError());
        goto done;
    }
    /* 类图标只管新窗口的默认值；对已存在的窗口再显式设一次，标题栏立刻生效 */
    if (icon_big) {
        SendMessageW(p->hwnd, WM_SETICON, ICON_BIG, (LPARAM)icon_big);
    }
    if (icon_small) {
        SendMessageW(p->hwnd, WM_SETICON, ICON_SMALL, (LPARAM)icon_small);
    }
    /* 菜单栏：装配期就先建好（仓颉侧可能在 start() 之前就 set_menu 了）；
       运行期再改的走 WM_CJT_MENU 到本线程重建。 */
    if (h->pending_menu_text && h->pending_menu_text[0]) {
        menu_apply_wire(h, p, h->pending_menu_text);
    }
    /* 创建 WebView2 环境（完成/失败都在回调 env_Invoke 中处理） */
    fprintf(stderr, "[cj-bridge] window created, requesting WebView2 environment\n");
    log_hr("CreateCoreWebView2EnvironmentWithOptions",
           create_env(NULL, NULL, NULL, &p->env.iface));

    while (GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

done:
    if (title_w) free(title_w);
    if (icon_w) free(icon_w);
    if (p->menu) { /* 窗口没了，菜单栏也要回收（HMENU 归本线程建、也归本线程销毁）*/
        DestroyMenu(p->menu);
        p->menu = NULL;
    }
    menu_clear_slots(p);
    if (p->controller) {
        p->controller->lpVtbl->Close(p->controller);
        p->controller = NULL;
    }
    /* COM 引用（controller / environment / webview）不在这里 Release：
       它们都在本线程的 STA 上创建，且进程随之结束——沿用原实现的「活到进程退出」口径，
       只把指针置空，避免收尾后再被别的路径碰到。 */
    p->webview = NULL;
    p->hwnd = NULL;
    if (p->loader) {
        FreeLibrary(p->loader);
        p->loader = NULL;
    }
    CoUninitialize();
    /* 兜底：非关窗路径退出消息循环（Loader 缺失 / 环境创建失败）也要通知一次（幂等）*/
    cj_core_window_destroyed(h);
    /* 最后一步才立这个标记：cj_plat_fini 见到它才 free 平台状态（此刻本线程已不再碰 p）*/
    p->thread_done = 1;
    return 0;
}

/* ===== 平台原语（bridge_core.h 的清单；导出不在这里，全在 core）===== */

void cj_plat_init(cj_host *h) {
    plat_host *p;
    if (!h) return;
    p = (plat_host *)calloc(1, sizeof(plat_host));
    if (!p) {
        fprintf(stderr, "[cj-bridge] init failed: out of memory\n");
        return;
    }
    p->env.h = h;
    p->ctrl.h = h;
    p->msg.h = h;
    p->nav.h = h;
    p->env.iface.lpVtbl = &g_env_vtbl;
    p->ctrl.iface.lpVtbl = &g_ctrl_vtbl;
    p->msg.iface.lpVtbl = &g_msg_vtbl;
    p->nav.iface.lpVtbl = &g_nav_vtbl;
    h->plat = p;
    fprintf(stderr, "[cj-bridge] init (on_message=%p on_destroy=%p)\n",
            (void *)h->on_message, (void *)h->on_destroy);
}

int cj_plat_fini(cj_host *h) {
    plat_host *p;
    if (!h) return 1;
    p = (plat_host *)h->plat;
    if (!p) return 1;
    /* 宿主线程还活着（事件循环没退出）：不能在这里 free 平台状态——它正被那条线程用着。
       等待必须有界：宿主线程收尾时要进入仓颉运行时（onDestroy），无限等会与运行时的线程
       退出握手互等（Linux 侧实测过，见 bridge_linux.c 同名函数）；超时就状态与句柄一起留着。 */
    if (p->thread_started && p->thread) {
        WaitForSingleObject(p->thread, 5000);
        CloseHandle(p->thread);
        p->thread = NULL;
        p->thread_started = 0;
    }
    if (!p->thread_done) {
        fprintf(stderr, "[cj-bridge] fini: host thread still running, platform state kept\n");
        return 0;
    }
    h->plat = NULL;
    free(p);
    return 1;
}

void cj_plat_start(cj_host *h) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    DWORD tid = 0;
    if (!p) {
        fprintf(stderr, "[cj-bridge] start failed: platform not initialized\n");
        if (h) h->should_quit = 1; /* 起不来就别让 run() 干等 */
        return;
    }
    p->thread = CreateThread(NULL, 0, host_thread_main, h, 0, &tid);
    if (!p->thread) {
        fprintf(stderr, "[cj-bridge] start failed: cannot create host thread\n");
        h->should_quit = 1;
        return;
    }
    p->thread_id = tid;
    p->thread_started = 1;
}

void cj_plat_quit(cj_host *h) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (p && p->hwnd) {
        PostMessageW(p->hwnd, WM_CJT_QUIT, 0, 0);
    } else if (h) {
        h->should_quit = 1;
    }
}

void cj_plat_wake_ui(cj_host *h) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (p && p->hwnd) {
        PostMessageW(p->hwnd, WM_CJT_FLUSH, 0, 0);
    }
}

void cj_plat_post_js(cj_host *h, const char *script_utf8) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    wchar_t *w;
    if (!p || !p->webview || !script_utf8) return;
    w = utf8_to_wide(script_utf8);
    if (!w) return;
    log_hr("ExecuteScript", p->webview->lpVtbl->ExecuteScript(p->webview, w, NULL));
    free(w);
}

int cj_plat_is_ui_thread(cj_host *h) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    return (p && p->thread_set && GetCurrentThreadId() == p->thread_id) ? 1 : 0;
}

void cj_plat_open_devtools(cj_host *h) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || !p->hwnd) {
        fprintf(stderr, "[cj-bridge] open devtools ignored: window not ready\n");
        return;
    }
    PostMessageW(p->hwnd, WM_CJT_DEVTOOLS, 0, 0);
}

void cj_plat_load_url(cj_host *h, const char *url) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!h || !url || !url[0]) {
        return;
    }
    if (p && p->hwnd) {
        wchar_t *w = utf8_to_wide(url);
        if (!w) return;
        /* pending_url 由 core 拥有（cj_bridge_load_url 已经记过一份），这里只投当次导航 */
        fprintf(stderr, "[cj-bridge] load url (runtime): %s\n", url);
        PostMessageW(p->hwnd, WM_CJT_LOAD_URL, 0, (LPARAM)w);
        return;
    }
    fprintf(stderr, "[cj-bridge] load url: %s\n", url);
}

void cj_plat_reload(cj_host *h) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || !p->hwnd) {
        fprintf(stderr, "[cj-bridge] reload ignored: window not ready\n");
        return;
    }
    PostMessageW(p->hwnd, WM_CJT_RELOAD, 0, 0);
}

/* ===== 菜单栏翻译层（RFC-002 §5.4）：线路文本 → HMENU =====
   格式解析不在这里重复实现：走 core 的 cj_core_menu_walk（两平台共用一份，桩平台已自检）。
   本层只做三件事：把行翻译成 Win32 项、维护「命令 id ↔ 应用 id」映射、把点击经 core 回投。 */

static void menu_clear_slots(plat_host *p) {
    int i;
    if (!p) return;
    for (i = 0; i < p->menu_item_count; i++) {
        free(p->menu_items[i].app_id);
        p->menu_items[i].app_id = NULL;
    }
    p->menu_item_count = 0;
}

static void menu_apply_item_state(plat_host *p, const char *id, int enabled, int checked) {
    int i;
    if (!p || !id || !id[0] || !p->menu) return;
    for (i = 0; i < p->menu_item_count; i++) {
        menu_slot *s = &p->menu_items[i];
        if (!s->app_id || strcmp(s->app_id, id) != 0) continue;
        s->enabled = enabled ? 1 : 0;
        s->checked = checked ? 1 : 0;
        EnableMenuItem(p->menu, s->cmd_id, MF_BYCOMMAND | (s->enabled ? MF_ENABLED : MF_GRAYED));
        CheckMenuItem(p->menu, s->cmd_id,
                      MF_BYCOMMAND | (s->checked ? MF_CHECKED : MF_UNCHECKED));
        DrawMenuBar(p->hwnd);
        return;
    }
    fprintf(stderr, "[cj-bridge] menu item not found: %s\n", id);
}

/* 建菜单时的上下文：层级用一张 HMENU 栈表示（行按文档顺序来，深度只会 +1 或回退）*/
typedef struct menu_build_ctx {
    plat_host *p;
    HMENU bar;
    HMENU stack[CJ_MENU_MAX_DEPTH]; /* stack[d]：深度 d 的行往哪个菜单里追加 */
    int ok[CJ_MENU_MAX_DEPTH];      /* 该层是否已经有子菜单可挂（没有就退回上一层）*/
} menu_build_ctx;

static void menu_add_row(void *ctx, int depth, char kind, const char *id,
                         const char *label, int flags, const char *accel) {
    menu_build_ctx *c = (menu_build_ctx *)ctx;
    plat_host *p;
    HMENU target;
    wchar_t *wlabel = NULL;
    int enabled = (flags & 1) ? 1 : 0;
    int checked = (flags & 2) ? 1 : 0;

    if (!c || !c->p) return;
    p = c->p;
    if (depth < 0) depth = 0;
    if (depth >= CJ_MENU_MAX_DEPTH) depth = CJ_MENU_MAX_DEPTH - 1;
    target = (depth > 0 && c->ok[depth]) ? c->stack[depth] : c->bar;

    if (kind == 's') { /* 分隔线：既没有命令 id，也没有文字 */
        AppendMenuW(target, MF_SEPARATOR, 0, NULL);
        return;
    }

    /* 标签：accel 非空时用制表符并进去——Win32 会把 \t 之后的部分右对齐，正是快捷键栏的位置 */
    {
        size_t n = strlen(label) + (accel[0] ? strlen(accel) + 1 : 0) + 1;
        char *tmp = (char *)malloc(n);
        if (!tmp) return;
        snprintf(tmp, n, "%s%s%s", label, accel[0] ? "\t" : "", accel);
        wlabel = utf8_to_wide(tmp);
        free(tmp);
    }
    if (!wlabel) return;

    if (kind == 'm') { /* 子菜单：建出 HMENU 挂进父项，并让深一层的行知道往哪挂 */
        HMENU sub = CreatePopupMenu();
        if (!sub) {
            free(wlabel);
            return;
        }
        if (!AppendMenuW(target, MF_POPUP | (enabled ? 0 : MF_GRAYED), (UINT_PTR)sub, wlabel)) {
            fprintf(stderr, "[cj-bridge] menu: append submenu failed: %lu\n",
                    (unsigned long)GetLastError());
            DestroyMenu(sub);
            free(wlabel);
            return;
        }
        free(wlabel);
        if (depth + 1 < CJ_MENU_MAX_DEPTH) {
            c->stack[depth + 1] = sub;
            c->ok[depth + 1] = 1;
        }
        return;
    }

    if (p->menu_item_count >= CJ_MENU_MAX_ITEMS) {
        fprintf(stderr, "[cj-bridge] menu: item limit reached, dropped: %s\n", id);
        free(wlabel);
        return;
    }
    {
        UINT item_flags = MF_STRING;
        UINT cmd_id = (UINT)(p->menu_item_count + 1); /* 0 保留给「没有命令」*/
        menu_slot *s = &p->menu_items[p->menu_item_count];
        if (!enabled) item_flags |= MF_GRAYED;
        if (kind == 'c' && checked) item_flags |= MF_CHECKED;
        if (!AppendMenuW(target, item_flags, cmd_id, wlabel)) {
            fprintf(stderr, "[cj-bridge] menu: append item failed: %lu (id=%s)\n",
                    (unsigned long)GetLastError(), id);
            free(wlabel);
            return;
        }
        free(wlabel);
        ZeroMemory(s, sizeof(*s));
        s->cmd_id = cmd_id;
        s->app_id = strdup(id);
        s->kind = kind;
        s->enabled = enabled;
        s->checked = checked;
        p->menu_item_count++;
    }
}

static void menu_apply_wire(cj_host *h, plat_host *p, const char *wire) {
    menu_build_ctx c;
    HMENU old;

    if (!p) return;
    if (!wire || !wire[0]) {
        /* 空串 = 清空菜单栏：SetMenu(hwnd, NULL) 才是真的没有菜单栏（空 popup 会留一条空条）*/
        menu_clear_slots(p);
        if (p->menu) {
            SetMenu(p->hwnd, NULL);
            DestroyMenu(p->menu);
            p->menu = NULL;
        }
        DrawMenuBar(p->hwnd);
        fprintf(stderr, "[cj-bridge] menu cleared\n");
        return;
    }
    ZeroMemory(&c, sizeof(c));
    c.p = p;
    /* 顶层必须是「菜单栏」：SetMenu 只接受 CreateMenu 出来的句柄，塞一个 CreatePopupMenu
       的 popup 句柄进去会以 ERROR_INVALID_PARAMETER(87) **静默失败**——实测就是这样：
       menu applied 照打、窗口上却查不到菜单（GetMenu 一直是 NULL）。子菜单才用 popup。 */
    c.bar = CreateMenu();
    if (!c.bar) {
        fprintf(stderr, "[cj-bridge] menu: CreateMenu failed: %lu\n",
                (unsigned long)GetLastError());
        return;
    }
    c.stack[0] = c.bar;
    c.ok[0] = 1;
    menu_clear_slots(p); /* 旧映射整体作废：新菜单的命令 id 从 1 重新分配 */
    cj_core_menu_walk(wire, menu_add_row, &c);
    old = p->menu;
    p->menu = c.bar;
    /* SetMenu 会静默失败（返回 FALSE），此时日志照样说「已应用」而窗口上什么都没有——
       Windows 上「真挂上了」的唯一凭证就是这两行：返回值 + 事后 GetMenu 复核。 */
    if (!SetMenu(p->hwnd, p->menu)) {
        fprintf(stderr, "[cj-bridge] menu: SetMenu failed: %lu\n", (unsigned long)GetLastError());
    }
    DrawMenuBar(p->hwnd);
    if (old) DestroyMenu(old);
    fprintf(stderr, "[cj-bridge] menu applied: items=%d hwnd=%p bar=%p GetMenu=%p\n",
            p->menu_item_count, (void *)p->hwnd, (void *)p->menu, (void *)GetMenu(p->hwnd));
}

void cj_plat_set_menu(cj_host *h, const char *wire) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || !wire) return;
    if (!p->hwnd) {
        /* 未就绪：core 已把线路文本记在 h->pending_menu_text，宿主线程建窗时取用 */
        fprintf(stderr, "[cj-bridge] menu deferred: window not ready\n");
        return;
    }
    if (cj_plat_is_ui_thread(h)) {
        menu_apply_wire(h, p, wire);
        return;
    }
    {
        char *copy = strdup(wire); /* 跨线程：谁 post 谁分配，UI 线程在 WM_CJT_MENU 分支里释放 */
        if (!copy) return;
        if (!PostMessageW(p->hwnd, WM_CJT_MENU, 0, (LPARAM)copy)) {
            fprintf(stderr, "[cj-bridge] menu post failed: %lu\n", (unsigned long)GetLastError());
            free(copy);
            return;
        }
        fprintf(stderr, "[cj-bridge] menu posted to ui thread (%d bytes)\n", (int)strlen(wire));
    }
}

void cj_plat_menu_item_state(cj_host *h, const char *id, int enabled, int checked) {
    plat_host *p = h ? (plat_host *)h->plat : NULL;
    if (!p || !id || !id[0]) return;
    if (!p->hwnd || !p->menu) {
        fprintf(stderr, "[cj-bridge] menu item state ignored: menu not ready (%s)\n", id);
        return;
    }
    if (cj_plat_is_ui_thread(h)) {
        menu_apply_item_state(p, id, enabled, checked);
        return;
    }
    {
        menu_state_msg *m = (menu_state_msg *)malloc(sizeof(*m));
        if (!m) return;
        m->id = strdup(id);
        m->enabled = enabled ? 1 : 0;
        m->checked = checked ? 1 : 0;
        if (!m->id || !PostMessageW(p->hwnd, WM_CJT_MENU_ITEM, 0, (LPARAM)m)) {
            fprintf(stderr, "[cj-bridge] menu item state post failed: %lu\n",
                    (unsigned long)GetLastError());
            free(m->id);
            free(m);
        }
    }
}

int cj_plat_host_capabilities(cj_host *h) {
    (void)h;
    /* 本平台的静态能力：菜单栏已落地；托盘 / 拖放到 7.B / 7.C 做完再把对应的位置打开 */
    return CJ_CAP_MENU;
}

/* =========================================================================
 *  串口（plugin_serial 的平台层）：Windows 侧
 *
 *  四个原语的**名字与返回码口径**与 Linux 侧逐字一致（见 bridge_core.h），所以上层不必写平台分支。
 *  这里先只留接口：应用拿到的是可读的「本平台暂不支持」，而不是静默失败或链接期缺符号。
 *  后续实现要点：CreateFileW("\\\\.\\COM3", GENERIC_READ|GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED)
 *  + GetCommState/SetCommState 配 DCB（BaudRate / ByteSize / Parity / StopBits）
 *  + SetCommTimeouts 或 OVERLAPPED + WaitCommEvent 做超时读写。
 * ========================================================================= */
#define CJ_SERIAL_WIN_TODO "serial: Windows 侧串口尚未实现（接口已留，见 native/bridge_win.c）"

long long cj_plat_serial_open(const char *path, const cj_serial_cfg *cfg, char *err, int err_len) {
    (void)path;
    (void)cfg;
    if (err && err_len > 0) snprintf(err, (size_t)err_len, "%s", CJ_SERIAL_WIN_TODO);
    return -3;
}

int cj_plat_serial_read(long long h, unsigned char *buf, int len, int timeout_ms, char *err, int err_len) {
    (void)h;
    (void)buf;
    (void)len;
    (void)timeout_ms;
    if (err && err_len > 0) snprintf(err, (size_t)err_len, "%s", CJ_SERIAL_WIN_TODO);
    return -4;
}

int cj_plat_serial_write(long long h, const unsigned char *buf, int len, int timeout_ms,
                         char *err, int err_len) {
    (void)h;
    (void)buf;
    (void)len;
    (void)timeout_ms;
    if (err && err_len > 0) snprintf(err, (size_t)err_len, "%s", CJ_SERIAL_WIN_TODO);
    return -4;
}

int cj_plat_serial_close(long long h, char *err, int err_len) {
    (void)h;
    if (err && err_len > 0) snprintf(err, (size_t)err_len, "%s", CJ_SERIAL_WIN_TODO);
    return -4;
}
