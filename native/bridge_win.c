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
#include <objbase.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "WebView2.h"

#define CJ_BRIDGE_API __declspec(dllexport)

/* ===== 仓颉侧回调（@C 函数）===== */
typedef void (*cj_on_message_fn)(const char *json); /* JS 消息到达 */
typedef void (*cj_on_destroy_fn)(void);             /* 窗口销毁 */

static cj_on_message_fn g_on_message = NULL;
static cj_on_destroy_fn g_on_destroy = NULL;

static HWND g_hwnd = NULL;
static ICoreWebView2Controller *g_controller = NULL;
static ICoreWebView2Environment *g_environment = NULL;
static ICoreWebView2 *g_webview = NULL;
static char *g_pending_html = NULL;
static volatile LONG g_ready = 0;
static volatile LONG g_should_quit = 0;

/* 窗口配置：由仓颉侧在 cj_bridge_start 之前经 cj_bridge_set_window 注入 */
static wchar_t *g_win_title_w = NULL;
static int g_win_w = 900;
static int g_win_h = 640;
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
    fprintf(stderr, "[cj-bridge] controller ready, loading HTML\n");

    if (g_pending_html) {
        wchar_t *w = utf8_to_wide(g_pending_html);
        if (w) {
            log_hr("NavigateToString", g_webview->lpVtbl->NavigateToString(g_webview, w));
            free(w);
        }
    }
    fprintf(stderr, "[cj-bridge] html navigation requested\n");
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

    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.lpszClassName = WINDOW_CLASS;
    RegisterClassExW(&wc);

    g_hwnd = CreateWindowExW(0, WINDOW_CLASS,
                             g_win_title_w ? g_win_title_w : L"cj-tauri", WS_OVERLAPPEDWINDOW,
                             CW_USEDEFAULT, CW_USEDEFAULT, g_win_w, g_win_h,
                             NULL, NULL, wc.hInstance, NULL);
    if (!g_hwnd) {
        fprintf(stderr, "[cj-bridge] CreateWindowExW failed: %lu\n", GetLastError());
        goto done;
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

CJ_BRIDGE_API void cj_bridge_start(const char *html) {
    HANDLE t;
    DWORD tid = 0;
    if (html) {
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
