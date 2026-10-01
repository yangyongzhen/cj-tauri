/*
 * 临时排障工具：直接驱动 libcjtbridge.dll，隔离验证 Windows 宿主
 * （不走仓颉侧，用于区分「C 桥问题」与「仓颉 FFI 回调问题」）
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

__declspec(dllimport) void cj_bridge_init(void (*)(const char *), void (*)(void));
__declspec(dllimport) void cj_bridge_start(const char *);
__declspec(dllimport) void cj_bridge_run_js(const char *);
__declspec(dllimport) void cj_bridge_quit(void);
__declspec(dllimport) int cj_bridge_is_ready(void);
__declspec(dllimport) int cj_bridge_should_quit(void);

static const char *HTML =
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><h1>harness</h1>"
    "<script>"
    "window.chrome.webview.postMessage('{\"hello\":\"from-js\"}');"
    "window.addEventListener('message', function (e) {"
    "  window.chrome.webview.postMessage('native-to-js:' + JSON.stringify(e.data));"
    "});"
    "</script></body></html>";

static void on_message(const char *json) {
    printf("[harness] js -> native: %s\n", json);
    fflush(stdout);
}

static void on_destroy(void) {
    printf("[harness] window destroyed\n");
    fflush(stdout);
}

int main(void) {
    int i;
    printf("[harness] init\n");
    fflush(stdout);
    cj_bridge_init(on_message, on_destroy);
    printf("[harness] start\n");
    fflush(stdout);
    cj_bridge_start(HTML);

    for (i = 0; i < 60; i++) {
        Sleep(500);
        if (i == 6) {
            printf("[harness] ready=%d -> native to js\n", cj_bridge_is_ready());
            fflush(stdout);
            cj_bridge_run_js("window.postMessage('{\"type\":\"event\",\"event\":\"tick\",\"payload\":{\"n\":1}}', '*')");
        }
        if (cj_bridge_should_quit()) {
            printf("[harness] should_quit at i=%d\n", i);
            fflush(stdout);
            break;
        }
    }
    printf("[harness] done (ready=%d)\n", cj_bridge_is_ready());
    fflush(stdout);
    return 0;
}
