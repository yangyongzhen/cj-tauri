/*
 * cj-tauri C 桥（Windows）：Win32 窗口 + WebView2（Edge Chromium）WebView 宿主
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
 *   gcc -shared -O2 bridge_win.c -o libcjtbridge.dll \
 *       -Wl,--out-implib,libcjtbridge.dll.a \
 *       -I<WebView2 SDK>/build/native/include \
 *       -lole32 -loleaut32 -luuid -luser32 -lgdi32
 * 运行期要求：libcjtbridge.dll 与 WebView2Loader.dll 位于 exe 目录或 PATH 中。
 */
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <commdlg.h>
#include <objbase.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "WebView2.h"

#define CJ_BRIDGE_API __declspec(dllexport)

/* ===== 仓颉侧回调（@C 函数）===== */
typedef void (*cj_on_message_fn)(const char *json); /* JS 消息到达 */
typedef void (*cj_on_destroy_fn)(void);             /* 窗口销毁 */
typedef void (*cj_on_dialog_fn)(const char *path);  /* 原生对话框选中的路径 */

static cj_on_message_fn g_on_message = NULL;
static cj_on_destroy_fn g_on_destroy = NULL;
static cj_on_dialog_fn g_on_dialog = NULL;

static HWND g_hwnd = NULL;
static ICoreWebView2Controller *g_controller = NULL;
static ICoreWebView2Environment *g_environment = NULL;
static ICoreWebView2 *g_webview = NULL;
static char *g_pending_html = NULL;
/* 页面来源二选一：cj_bridge_load_url 设 URL，cj_bridge_start 设 HTML；两者都设时 URL 优先 */
static char *g_pending_url = NULL;
static volatile LONG g_ready = 0;
static volatile LONG g_should_quit = 0;

/* 窗口配置：由仓颉侧在 cj_bridge_start 之前经 cj_bridge_set_window 注入 */
static wchar_t *g_win_title_w = NULL;
static int g_win_w = 900;
static int g_win_h = 640;
/* 窗口图标（.ico 路径，cj_bridge_set_icon 注入；NULL = 用系统默认图标） */
static wchar_t *g_win_icon_w = NULL;
static int g_devtools = 1; /* 开发者工具开关（cj_bridge_set_devtools） */

/* JS 投递队列（FIFO）：每条 JS 独立执行，防止覆盖 */
typedef struct js_node {
    wchar_t *js;
    struct js_node *next;
} js_node;
static js_node *g_js_head = NULL;
static js_node *g_js_tail = NULL;
static CRITICAL_SECTION g_js_lock;
static int g_js_lock_init = 0;

#define WM_CJT_FLUSH (WM_APP + 1)
#define WM_CJT_QUIT (WM_APP + 2)
#define WM_CJT_DEVTOOLS (WM_APP + 3)
#define WM_CJT_LOAD_URL (WM_APP + 4)
#define WM_CJT_RELOAD (WM_APP + 5)
#define WM_CJT_DIALOG (WM_APP + 6)

/* 前端 __CJ_TAURI__.reload() 的控制消息：宿主级操作，不经过 IPC hub（与 BRIDGE_JS 里的字面量保持一致） */
#define CJT_RELOAD_MSG "__cj_tauri_reload__"

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

/* ===== 注入前端桥接脚本（暴露 window.__CJ_TAURI__，对标 @tauri-apps/api）===== */

static const wchar_t *BRIDGE_JS =
    L"window.__CJ_TAURI__ = (function () {"
    L"  var seq = 0;"
    L"  var pending = {};"
    L"  var listeners = {};"
    L"  function post(obj) {"
    L"    window.chrome.webview.postMessage(JSON.stringify(obj));"
    L"  }"
    L"  return {"
    L"    invoke: function (cmd, args) {"
    L"      var id = ++seq;"
    L"      var p = new Promise(function (resolve, reject) { pending[id] = { resolve: resolve, reject: reject }; });"
    L"      post({ type: 'invoke', id: id, cmd: cmd, args: args || {} });"
    L"      return p;"
    L"    },"
    L"    listen: function (event, cb) {"
    L"      if (!listeners[event]) listeners[event] = [];"
    L"      listeners[event].push(cb);"
    L"      return function () {"
    L"        var arr = listeners[event] || [];"
    L"        var i = arr.indexOf(cb);"
    L"        if (i >= 0) arr.splice(i, 1);"
    L"      };"
    L"    },"
    L"    emit: function (event, payload) {"
    L"      post({ type: 'emit', event: event, payload: payload || {} });"
    L"    },"
    L"    reload: function () {"
    L"      /* 与 CJT_RELOAD_MSG 保持一致：宿主拦截后不会进 IPC hub */"
    L"      window.chrome.webview.postMessage('__cj_tauri_reload__');"
    L"    },"
    L"    _dispatch: function (msg) {"
    L"      if (!msg) return;"
    L"      if (msg.type === 'resolve') {"
    L"        var p = pending[msg.id];"
    L"        if (!p) return;"
    L"        delete pending[msg.id];"
    L"        if (msg.ok) p.resolve(msg.data); else p.reject(new Error(msg.error || 'invoke failed'));"
    L"      } else if (msg.type === 'event') {"
    L"        var arr = listeners[msg.event] || [];"
    L"        for (var i = 0; i < arr.length; i++) arr[i](msg.payload);"
    L"      }"
    L"    }"
    L"  };"
    L"})();"
    L"window.addEventListener('message', function (e) {"
    L"  var msg = e.data;"
    L"  if (typeof msg === 'string') { try { msg = JSON.parse(msg); } catch (err) { return; } }"
    L"  window.__CJ_TAURI__._dispatch(msg);"
    L"});";

/* ===== COM 回调实现（WebView2 的完成/事件 handler，静态生命周期）===== */

/* 关键 WebView2 调用的 HRESULT 上报 */

static void log_hr(const char *what, HRESULT hr) {
    fprintf(stderr, "[cj-bridge] %s -> hr=0x%08lx\n", what, (unsigned long)hr);
}

static void flush_js(void);

static ICoreWebView2CreateCoreWebView2ControllerCompletedHandler g_ctrl_handler;
static ICoreWebView2WebMessageReceivedEventHandler g_msg_handler;
static ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler g_env_handler;
static ICoreWebView2NavigationCompletedEventHandler g_nav_handler;

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
    if (FAILED(errorCode) || !result) {
        fprintf(stderr, "[cj-bridge] create WebView2 environment failed: 0x%08lx\n",
                (unsigned long)errorCode);
        InterlockedExchange(&g_should_quit, 1);
        if (g_on_destroy) g_on_destroy();
        if (g_hwnd) PostMessageW(g_hwnd, WM_CJT_QUIT, 0, 0);
        return S_OK;
    }
    /* 必须自己持有一份环境引用：否则本回调返回后环境对象被释放，
       WebView2 会随即关闭浏览器进程，表现为导航不完成、ExecuteScript 返回 0x8007139F */
    g_environment = result;
    g_environment->lpVtbl->AddRef(g_environment);
    result->lpVtbl->CreateCoreWebView2Controller(result, g_hwnd, &g_ctrl_handler);
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
    RECT rc;

    if (FAILED(errorCode) || !result) {
        fprintf(stderr, "[cj-bridge] create WebView2 controller failed: 0x%08lx\n",
                (unsigned long)errorCode);
        InterlockedExchange(&g_should_quit, 1);
        if (g_on_destroy) g_on_destroy();
        if (g_hwnd) PostMessageW(g_hwnd, WM_CJT_QUIT, 0, 0);
        return S_OK;
    }
    g_controller = result;
    g_controller->lpVtbl->AddRef(g_controller);
    result->lpVtbl->get_CoreWebView2(result, &g_webview);
    if (!g_webview) {
        fprintf(stderr, "[cj-bridge] get_CoreWebView2 failed\n");
        return S_OK;
    }

    /* 先让父窗口可见，再摆放 WebView：不可见的父窗口会挂起渲染 */
    ShowWindow(g_hwnd, SW_SHOW);
    UpdateWindow(g_hwnd);

    GetClientRect(g_hwnd, &rc);
    result->lpVtbl->put_Bounds(result, rc);
    result->lpVtbl->put_IsVisible(result, TRUE);

    /* WebView 行为设置 */
    {
        ICoreWebView2Settings *settings = NULL;
        HRESULT hr = g_webview->lpVtbl->get_Settings(g_webview, &settings);
        if (SUCCEEDED(hr) && settings) {
            settings->lpVtbl->put_IsStatusBarEnabled(settings, FALSE);
            settings->lpVtbl->put_IsZoomControlEnabled(settings, FALSE);
            settings->lpVtbl->put_AreDefaultContextMenusEnabled(settings, TRUE);
            settings->lpVtbl->put_AreDevToolsEnabled(settings, g_devtools ? TRUE : FALSE);
            settings->lpVtbl->Release(settings);
        }
    }

    /* 注入桥接脚本（页面脚本执行前）+ 注册 JS 消息通道 */
    g_webview->lpVtbl->AddScriptToExecuteOnDocumentCreated(g_webview, BRIDGE_JS, NULL);
    g_webview->lpVtbl->add_WebMessageReceived(g_webview, &g_msg_handler, NULL);
    g_webview->lpVtbl->add_NavigationCompleted(g_webview, &g_nav_handler, NULL);

    InterlockedExchange(&g_ready, 1);
    fprintf(stderr, "[cj-bridge] controller ready, loading page\n");

    /* 页面来源：URL 优先（cj_bridge_load_url），否则内联 HTML（cj_bridge_start） */
    if (g_pending_url) {
        wchar_t *w = utf8_to_wide(g_pending_url);
        if (w) {
            log_hr("Navigate", g_webview->lpVtbl->Navigate(g_webview, w));
            free(w);
        }
        fprintf(stderr, "[cj-bridge] url navigation requested: %s\n", g_pending_url);
    } else if (g_pending_html) {
        wchar_t *w = utf8_to_wide(g_pending_html);
        if (w) {
            log_hr("NavigateToString", g_webview->lpVtbl->NavigateToString(g_webview, w));
            free(w);
        }
        fprintf(stderr, "[cj-bridge] html navigation requested\n");
    }
    /* 宿主就绪前可能已有排队脚本（如启动即推送的事件） */
    flush_js();
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
    LPWSTR payload = NULL;
    if (SUCCEEDED(args->lpVtbl->TryGetWebMessageAsString(args, &payload)) && payload) {
        char *utf8 = wide_to_utf8(payload);
        CoTaskMemFree(payload);
        if (utf8) {
            /* 前端 __CJ_TAURI__.reload()：宿主控制消息，不进 IPC hub */
            if (strcmp(utf8, CJT_RELOAD_MSG) == 0) {
                fprintf(stderr, "[cj-bridge] frontend requested reload\n");
                if (g_hwnd) PostMessageW(g_hwnd, WM_CJT_RELOAD, 0, 0);
                free(utf8);
                return S_OK;
            }
            fprintf(stderr, "[cj-bridge] js -> native (%d bytes)\n", (int)strlen(utf8));
            if (g_on_message) g_on_message(utf8); /* 回调仓颉（IPC hub） */
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

/* ===== 原生对话框（仓颉线程 → 宿主线程：PostMessage 投递 + 事件等待结果）=====
 * 对话框要在宿主线程弹出（UI/COM 线程，WebView2 也归它管），命令处理器又要同步结果：
 * 调用方把请求 PostMessage 给宿主窗口，然后等一个自动复位事件；宿主线程弹完对话框，
 * 先把结果经 g_on_dialog 送回仓颉，再 SetEvent 唤醒调用方。 */

typedef struct dlg_req {
    int kind;      /* 0 打开文件 1 保存文件 2 info 3 warning 4 error 5 confirm */
    char *title;
    char *message;
    char *filter;  /* "描述|模式|描述|模式"；空串 = 不过滤 */
    char *path;    /* 文件类结果：选中路径（UTF-8，堆上，调用方释放） */
    int ok;        /* 1 = 用户点了确认 */
    HANDLE done;   /* 自动复位事件：宿主线程 SetEvent 唤醒调用方 */
} dlg_req;

static CRITICAL_SECTION g_dlg_lock;
static int g_dlg_lock_init = 0;
static volatile LONG g_dlg_busy = 0;  /* 同时只允许一个：模态对话框，嵌套调用直接拒绝 */
static DWORD g_host_thread_id = 0;    /* 跑消息循环的宿主线程：用来判断调用方是否已在它上面 */
static int g_host_thread_set = 0;

/* "描述|模式|描述|模式" → Win32 双 NUL 过滤器串（末尾落单的描述段按 *.* 处理） */
static wchar_t *build_win_filter(const char *filter) {
    const char *p;
    wchar_t *out;
    size_t cap, len = 0;

    if (!filter || !filter[0]) {
        filter = "所有文件 (*.*)|*.*";
    }
    cap = strlen(filter) * 4 + 8;   /* UTF-8 → UTF-16 上界，末尾留双 NUL 位 */
    out = (wchar_t *)calloc(cap, sizeof(wchar_t));
    if (!out) return NULL;

    p = filter;
    while (p && p[0]) {
        const char *bar = strchr(p, '|');
        size_t seg = bar ? (size_t)(bar - p) : strlen(p);
        int n = MultiByteToWideChar(CP_UTF8, 0, p, (int)seg, out + len, (int)(cap - len - 2));
        if (n > 0) {
            len += (size_t)n;
            out[len++] = 0;         /* 段结束符 */
        }
        if (!bar) {
            break;
        }
        if (!bar[1]) {              /* 末尾落单的描述段：补一个 *.* 当模式 */
            int m = MultiByteToWideChar(CP_UTF8, 0, "*.*", 3, out + len, (int)(cap - len - 2));
            if (m > 0) {
                len += (size_t)m;
                out[len++] = 0;
            }
            break;
        }
        p = bar + 1;
    }
    out[len] = 0;                   /* 双 NUL 收尾（上一格已经是 0） */
    return out;
}

/* 已经站在宿主线程上：直接弹一次，返回 1 = 确认；选中路径写入 *out_path（由调用方 free） */
static int show_dialog_here(int kind, const char *title, const char *message, const char *filter,
                            char **out_path) {
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
        ofn.hwndOwner = g_hwnd;
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
            int res = MessageBoxW(g_hwnd, msg_w, title_w, flags);
            ok = (kind == 5) ? (res == IDOK) : 1;
        }
        free(title_w);
        free(msg_w);
    }
    return ok;
}

/* 宿主线程：处理别的线程投递进来的请求（调用方正阻塞等结果，由 wnd_proc 调用） */
static void run_dialog(dlg_req *r) {
    r->ok = show_dialog_here(r->kind, r->title, r->message, r->filter, &r->path);
    fprintf(stderr, "[cj-bridge] dialog closed: kind=%d ok=%d%s%s\n", r->kind, r->ok,
            (r->kind <= 1) ? " path=" : "",
            (r->kind <= 1) ? (r->path ? r->path : "(none)") : "");
    if (g_on_dialog) {
        g_on_dialog(r->path ? r->path : "");
    }
    SetEvent(r->done);
}

/* ===== 窗口消息处理 ===== */

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_SIZE:
        if (g_controller) {
            RECT rc;
            GetClientRect(hwnd, &rc);
            g_controller->lpVtbl->put_Bounds(g_controller, rc);
        }
        return 0;
    case WM_CJT_FLUSH:
        flush_js();
        return 0;
    case WM_CJT_QUIT:
        DestroyWindow(hwnd);
        return 0;
    case WM_CJT_DEVTOOLS:
        if (g_webview) {
            g_webview->lpVtbl->OpenDevToolsWindow(g_webview);
        }
        return 0;
    case WM_CJT_RELOAD:
        if (g_webview) {
            log_hr("Reload", g_webview->lpVtbl->Reload(g_webview));
        }
        return 0;
    case WM_CJT_LOAD_URL: {
        /* lParam 是跨线程传过来的宽字符串，由宿主线程负责释放 */
        wchar_t *w = (wchar_t *)lp;
        if (g_webview && w) {
            log_hr("Navigate", g_webview->lpVtbl->Navigate(g_webview, w));
        }
        free(w);
        return 0;
    }
    case WM_CJT_DIALOG:
        /* lParam 是调用方（仓颉线程）堆上的请求：宿主线程只填结果，释放仍归调用方 */
        if (lp) {
            run_dialog((dlg_req *)lp);
        }
        return 0;
    case WM_DESTROY:
        InterlockedExchange(&g_should_quit, 1);
        if (g_on_destroy) g_on_destroy();
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}

/* 原生 → JS：把脚本投递到宿主线程串行执行（FIFO，防覆盖） */
static void flush_js(void) {
    for (;;) {
        js_node *node = NULL;
        if (!g_js_lock_init) return;
        EnterCriticalSection(&g_js_lock);
        node = g_js_head;
        if (node) {
            g_js_head = node->next;
            if (!g_js_head) g_js_tail = NULL;
        }
        LeaveCriticalSection(&g_js_lock);
        if (!node) return;
        if (g_webview) {
            log_hr("ExecuteScript", g_webview->lpVtbl->ExecuteScript(g_webview, node->js, NULL));
        }
        free(node->js);
        free(node);
    }
}

/* ===== 宿主线程（对标 tao 的事件循环线程）===== */

typedef HRESULT(STDMETHODCALLTYPE *pfn_create_env)(
        PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions *,
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);

static const wchar_t *WINDOW_CLASS = L"CjTauriWindow";

static DWORD WINAPI host_thread_main(LPVOID param) {
    HMODULE loader = NULL;
    pfn_create_env create_env = NULL;
    WNDCLASSEXW wc;
    MSG msg;
    HICON icon_big = NULL;   /* 窗口图标（g_win_icon_w 非空时才加载） */
    HICON icon_small = NULL;

    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    fprintf(stderr, "[cj-bridge] host thread started\n");

    /* WebView2 的入口在 WebView2Loader.dll 中（运行期查找，避免依赖 MSVC 导入库） */
    loader = LoadLibraryW(L"WebView2Loader.dll");
    if (!loader) {
        fprintf(stderr, "[cj-bridge] WebView2Loader.dll not found: "
                        "put it next to the exe or on PATH\n");
        goto done;
    }
    create_env = (pfn_create_env)GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions");
    if (!create_env) {
        fprintf(stderr, "[cj-bridge] CreateCoreWebView2EnvironmentWithOptions not found\n");
        goto done;
    }
    {
        /* 诊断：x64 宿主是否能看到可用运行时（排障用，可删） */
        typedef HRESULT (STDAPICALLTYPE *pfn_getver)(PCWSTR, LPWSTR *);
        pfn_getver getver =
            (pfn_getver)GetProcAddress(loader, "GetAvailableCoreWebView2BrowserVersionString");
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

    /* 窗口图标：在 RegisterClassExW 之前加载并挂到窗口类上，
       这样任务栏与 Alt-Tab 也用同一个图标；失败只是回到系统默认图标，不阻断启动。 */
    if (g_win_icon_w) {
        char *p8 = wide_to_utf8(g_win_icon_w);
        icon_big = (HICON)LoadImageW(NULL, g_win_icon_w, IMAGE_ICON,
                                     GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON),
                                     LR_LOADFROMFILE);
        icon_small = (HICON)LoadImageW(NULL, g_win_icon_w, IMAGE_ICON,
                                       GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
                                       LR_LOADFROMFILE);
        /* GetLastError 只在失败时才有意义：成功时它是上一次调用的残留值（常见 6 = 无效句柄） */
        if (icon_big && icon_small) {
            fprintf(stderr, "[cj-bridge] window icon: path=%s loaded (big=%p small=%p)\n",
                    p8 ? p8 : "(null)", (void *)icon_big, (void *)icon_small);
        } else {
            fprintf(stderr, "[cj-bridge] window icon FAILED: path=%s hIcon=%p/%p err=%lu\n",
                    p8 ? p8 : "(null)", (void *)icon_big, (void *)icon_small,
                    (unsigned long)GetLastError());
        }
        free(p8);
    }

    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.lpszClassName = WINDOW_CLASS;
    wc.hIcon = icon_big;    /* 可空：空则用系统默认 */
    wc.hIconSm = icon_small;
    RegisterClassExW(&wc);

    /* 先记下宿主线程身份：对话框要靠它判断「调用方是不是已经在本线程上」 */
    g_host_thread_id = GetCurrentThreadId();
    g_host_thread_set = 1;

    g_hwnd = CreateWindowExW(0, WINDOW_CLASS,
                             g_win_title_w ? g_win_title_w : L"cj-tauri", WS_OVERLAPPEDWINDOW,
                             CW_USEDEFAULT, CW_USEDEFAULT, g_win_w, g_win_h,
                             NULL, NULL, wc.hInstance, NULL);
    if (!g_hwnd) {
        fprintf(stderr, "[cj-bridge] CreateWindowExW failed: %lu\n", GetLastError());
        goto done;
    }
    /* 类图标只管新窗口的默认值；对已存在的窗口再显式设一次，标题栏立刻生效 */
    if (icon_big) {
        SendMessageW(g_hwnd, WM_SETICON, ICON_BIG, (LPARAM)icon_big);
    }
    if (icon_small) {
        SendMessageW(g_hwnd, WM_SETICON, ICON_SMALL, (LPARAM)icon_small);
    }
    /* 创建 WebView2 环境（完成/失败都在回调 env_Invoke 中处理） */
    fprintf(stderr, "[cj-bridge] window created, requesting WebView2 environment\n");
    log_hr("CreateCoreWebView2EnvironmentWithOptions",
           create_env(NULL, NULL, NULL, &g_env_handler));

    while (GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

done:
    if (g_controller) {
        g_controller->lpVtbl->Close(g_controller);
        g_controller = NULL;
    }
    g_webview = NULL;
    g_hwnd = NULL;
    InterlockedExchange(&g_should_quit, 1);
    if (loader) FreeLibrary(loader);
    CoUninitialize();
    return 0;
}

/* ===== 仓颉 → C 桥 ===== */

CJ_BRIDGE_API void cj_bridge_init(cj_on_message_fn m, cj_on_destroy_fn d) {
    g_on_message = m;
    g_on_destroy = d;
    fprintf(stderr, "[cj-bridge] init (on_message=%p on_destroy=%p)\n", (void *)m, (void *)d);
    g_env_handler.lpVtbl = &g_env_vtbl;
    g_ctrl_handler.lpVtbl = &g_ctrl_vtbl;
    g_msg_handler.lpVtbl = &g_msg_vtbl;
    g_nav_handler.lpVtbl = &g_nav_vtbl;
    if (!g_js_lock_init) {
        InitializeCriticalSection(&g_js_lock);
        g_js_lock_init = 1;
    }
    if (!g_dlg_lock_init) {
        InitializeCriticalSection(&g_dlg_lock);
        g_dlg_lock_init = 1;
    }
}

/* 窗口配置（标题 / 尺寸）：必须在 cj_bridge_start 之前调用 */
CJ_BRIDGE_API void cj_bridge_set_window(const char *title, int width, int height) {
    fprintf(stderr, "[cj-bridge] set window: title=%s size=%dx%d\n",
            title ? title : "(default)", width, height);
    if (g_win_title_w) {
        free(g_win_title_w);
        g_win_title_w = NULL;
    }
    if (title) {
        g_win_title_w = utf8_to_wide(title);
    }
    if (width > 0) g_win_w = width;
    if (height > 0) g_win_h = height;
}

/* 窗口图标（.ico 路径）：必须在 cj_bridge_start 之前调用；空路径 = 用系统默认图标 */
CJ_BRIDGE_API void cj_bridge_set_icon(const char *path) {
    fprintf(stderr, "[cj-bridge] set icon: path=%s\n", (path && path[0]) ? path : "(default)");
    if (g_win_icon_w) {
        free(g_win_icon_w);
        g_win_icon_w = NULL;
    }
    if (path && path[0]) {
        g_win_icon_w = utf8_to_wide(path);
    }
}

/* 开发者工具开关：enabled=0 表示禁止打开（须在 cj_bridge_start 之前调用） */
CJ_BRIDGE_API void cj_bridge_set_devtools(int enabled) {
    g_devtools = enabled ? 1 : 0;
    fprintf(stderr, "[cj-bridge] devtools %s\n", g_devtools ? "enabled" : "disabled");
}

/* 运行时打开开发者工具：投递到宿主线程执行（WebView2 要求在其 UI 线程上调用） */
CJ_BRIDGE_API void cj_bridge_open_devtools(void) {
    if (!g_hwnd) {
        fprintf(stderr, "[cj-bridge] open devtools ignored: window not ready\n");
        return;
    }
    PostMessageW(g_hwnd, WM_CJT_DEVTOOLS, 0, 0);
}

/* 按 URL 加载页面（http(s):// 或 file://）：
 *   - cj_bridge_start 之前调用：只记下 URL，宿主就绪时用 Navigate 加载（与 HTML 二选一，URL 优先）；
 *   - 启动之后调用：投递到宿主线程重新导航（运行期切页面）。
 * 空 URL 忽略。 */
CJ_BRIDGE_API void cj_bridge_load_url(const char *url) {
    if (!url || !url[0]) {
        return;
    }
    if (g_hwnd) {
        wchar_t *w = utf8_to_wide(url);
        if (!w) return;
        free(g_pending_url);
        g_pending_url = _strdup(url);
        fprintf(stderr, "[cj-bridge] load url (runtime): %s\n", url);
        PostMessageW(g_hwnd, WM_CJT_LOAD_URL, 0, (LPARAM)w);
        return;
    }
    free(g_pending_url);
    g_pending_url = _strdup(url);
    fprintf(stderr, "[cj-bridge] load url: %s\n", url);
}

/* 重新加载当前页面：投递到宿主线程执行（WebView2 要求在其 UI 线程上调用） */
CJ_BRIDGE_API void cj_bridge_reload(void) {
    if (!g_hwnd) {
        fprintf(stderr, "[cj-bridge] reload ignored: window not ready\n");
        return;
    }
    PostMessageW(g_hwnd, WM_CJT_RELOAD, 0, 0);
}

CJ_BRIDGE_API void cj_bridge_start(const char *html) {
    HANDLE t;
    DWORD tid = 0;
    if (html && html[0]) { /* 空串表示「页面由 cj_bridge_load_url 指定」 */
        free(g_pending_html);
        g_pending_html = _strdup(html);
    }
    t = CreateThread(NULL, 0, host_thread_main, NULL, 0, &tid);
    if (t) CloseHandle(t);
}

CJ_BRIDGE_API void cj_bridge_run_js(const char *js) {
    js_node *node;
    int wasEmpty;
    wchar_t *w;

    if (!js) return;
    w = utf8_to_wide(js);
    if (!w) return;
    node = (js_node *)calloc(1, sizeof(js_node));
    if (!node) {
        free(w);
        return;
    }
    node->js = w;

    if (!g_js_lock_init) {
        /* 未 init 时直接丢弃，避免未初始化锁 */
        free(node->js);
        free(node);
        return;
    }
    EnterCriticalSection(&g_js_lock);
    if (g_js_tail) {
        g_js_tail->next = node;
    } else {
        g_js_head = node;
    }
    g_js_tail = node;
    wasEmpty = (g_js_head == node);
    LeaveCriticalSection(&g_js_lock);

    if (g_hwnd && wasEmpty) {
        PostMessageW(g_hwnd, WM_CJT_FLUSH, 0, 0);
    }
}

CJ_BRIDGE_API void cj_bridge_quit(void) {
    if (g_hwnd) {
        PostMessageW(g_hwnd, WM_CJT_QUIT, 0, 0);
    } else {
        InterlockedExchange(&g_should_quit, 1);
    }
}

CJ_BRIDGE_API int cj_bridge_is_ready(void) {
    return (int)g_ready;
}

CJ_BRIDGE_API int cj_bridge_should_quit(void) {
    return (int)g_should_quit;
}

/* ===== 原生对话框（导出；实现在上面的「原生对话框」一节）===== */

CJ_BRIDGE_API void cj_bridge_set_dialog_callback(cj_on_dialog_fn cb) {
    g_on_dialog = cb;
}

/* 阻塞式原生对话框：返回 1 = 用户确认（文件类路径已回调送回），0 = 取消 / 宿主未就绪 */
CJ_BRIDGE_API int cj_bridge_show_dialog(int kind, const char *title, const char *message, const char *filter) {
    dlg_req *r;
    int ok;

    if (!g_hwnd || !g_dlg_lock_init) {
        fprintf(stderr, "[cj-bridge] dialog ignored: host not ready\n");
        return 0;
    }
    EnterCriticalSection(&g_dlg_lock);
    if (InterlockedExchange(&g_dlg_busy, 1) == 1) {
        LeaveCriticalSection(&g_dlg_lock);
        fprintf(stderr, "[cj-bridge] dialog rejected: another dialog is open\n");
        return 0;
    }
    LeaveCriticalSection(&g_dlg_lock);

    /* 调用方已经在宿主线程上（WebView2 的 WebMessageReceived 回调就跑在这个线程）：直接弹。
       这里**不能**走「PostMessage + 等事件」——消息得由宿主线程自己处理，而宿主线程正卡在
       这次调用里，等于自己把自己锁死（与 Linux 桥同一个坑，实机踩到过）。 */
    if (g_host_thread_set && GetCurrentThreadId() == g_host_thread_id) {
        char *path = NULL;
        fprintf(stderr, "[cj-bridge] dialog: kind=%d title=%s (caller on host thread)\n", kind,
                title ? title : "");
        ok = show_dialog_here(kind, title ? title : "", message ? message : "",
                              filter ? filter : "", &path);
        fprintf(stderr, "[cj-bridge] dialog closed: kind=%d ok=%d%s%s\n", kind, ok,
                (kind <= 1) ? " path=" : "", (kind <= 1) ? (path ? path : "(none)") : "");
        if (g_on_dialog) {
            g_on_dialog(path ? path : "");
        }
        free(path);
        InterlockedExchange(&g_dlg_busy, 0);
        return ok;
    }

    r = (dlg_req *)calloc(1, sizeof(dlg_req));
    if (!r) {
        InterlockedExchange(&g_dlg_busy, 0);
        return 0;
    }
    /* 事件先建好再投递：否则宿主线程可能先 SetEvent、后 CreateEvent，唤醒就丢了 */
    r->done = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!r->done) {
        free(r);
        InterlockedExchange(&g_dlg_busy, 0);
        return 0;
    }
    r->kind = kind;
    r->title = _strdup(title ? title : "");
    r->message = _strdup(message ? message : "");
    r->filter = _strdup(filter ? filter : "");
    fprintf(stderr, "[cj-bridge] dialog: kind=%d title=%s\n", kind, r->title);

    if (!PostMessageW(g_hwnd, WM_CJT_DIALOG, 0, (LPARAM)r)) {
        fprintf(stderr, "[cj-bridge] dialog post failed: %lu\n", (unsigned long)GetLastError());
        free(r->title);
        free(r->message);
        free(r->filter);
        CloseHandle(r->done);
        free(r);
        InterlockedExchange(&g_dlg_busy, 0);
        return 0;
    }

    WaitForSingleObject(r->done, INFINITE);
    ok = r->ok;
    free(r->title);
    free(r->message);
    free(r->filter);
    free(r->path);
    CloseHandle(r->done);
    free(r);
    InterlockedExchange(&g_dlg_busy, 0);
    return ok;
}
