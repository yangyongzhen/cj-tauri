@echo off
REM ============================================================
REM cj-tauri Windows backend: build the WebView2 C bridge (libcjtbridge.dll)
REM
REM Requirements:
REM   - mingw-w64 / llvm-mingw gcc on PATH
REM   - WebView2 SDK (NuGet package Microsoft.Web.WebView2, unzipped = SDK root)
REM     Default SDK root: D:\webview2sdk\sdk-1.0.2365.46
REM     Override with the WEBVIEW2_SDK_ROOT environment variable.
REM
REM Version rule (important): the SDK must NOT be newer than the WebView2
REM   Runtime installed on this machine. This machine has runtime 122.0.2365.106,
REM   so use SDK 1.0.2365.46.
REM   Check runtime version:
REM     reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" /v pv
REM
REM Output: native\libcjtbridge.dll + native\libcjtbridge.dll.a (import lib)
REM         native\webview2\WebView2Loader.dll (synced to the SDK version)
REM ============================================================
setlocal

set SCRIPT_DIR=%~dp0
if "%WEBVIEW2_SDK_ROOT%"=="" set WEBVIEW2_SDK_ROOT=D:\webview2sdk\sdk-1.0.2365.46
set WEBVIEW2_SDK_INCLUDE=%WEBVIEW2_SDK_ROOT%\build\native\include

if not exist "%WEBVIEW2_SDK_INCLUDE%\WebView2.h" (
    echo [ERROR] WebView2.h not found in %WEBVIEW2_SDK_INCLUDE%
    echo         Download Microsoft.Web.WebView2 from nuget.org and unzip,
    echo         or set WEBVIEW2_SDK_ROOT.
    exit /b 1
)

cd /d "%SCRIPT_DIR%"

REM bridge_core.c holds the platform-independent half (JS queue, dialog state
REM machine, init scripts, lifecycle flags) and exports every cj_bridge_* entry
REM point; bridge_win.c only implements the WebView2/COM primitives it calls.
REM Both must be linked, or the cj_core_* symbols bridge_win.c references go
REM undefined (that is what happens if you build bridge_win.c alone).
gcc -shared -O2 -fstack-protector-all bridge_core.c bridge_win.c -o libcjtbridge.dll ^
    -Wl,--out-implib,libcjtbridge.dll.a ^
    -I"%WEBVIEW2_SDK_INCLUDE%" ^
    -lole32 -loleaut32 -luuid -luser32 -lgdi32 -ladvapi32 -lcomdlg32

if errorlevel 1 (
    echo [ERROR] build libcjtbridge.dll failed
    exit /b 1
)

REM Sync the x64 loader matching the headers, so the WebView never puts an
REM SDK newer than the installed runtime on the wire.
if not exist webview2 mkdir webview2
copy /y "%WEBVIEW2_SDK_ROOT%\build\native\x64\WebView2Loader.dll" webview2\ >nul
if errorlevel 1 (
    echo [WARN] WebView2Loader.dll copy failed, check %WEBVIEW2_SDK_ROOT%\build\native\x64
) else (
    echo [OK] WebView2Loader.dll synced
)

echo [OK] libcjtbridge.dll built
endlocal
