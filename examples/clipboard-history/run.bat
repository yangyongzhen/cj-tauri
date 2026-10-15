@echo off
REM ============================================================
REM cj-tauri clipboard-history example (examples\clipboard-history)
REM
REM What runs on Windows: clipboard:read / clipboard:write (Win32
REM clipboard in bridge_win.c), store:get / store:set, report, quit,
REM and the 500ms front-end poll that builds the history.
REM
REM What does NOT run on Windows yet: the tray icon and the global
REM hotkey are compile-time stubs on this platform -- the bridge does
REM not set CJ_CAP_TRAY / CJ_CAP_HOTKEY, so system:host reports them
REM as 0 and no tray/hotkey event ever arrives. That is the honest
REM truth, not a failure: the example is still fully usable by hand
REM (copy text anywhere, it shows up in the list; click an entry to
REM put it back on the clipboard).
REM
REM Override CANGJIE_HOME / CANGJIE_STDX if your install paths differ.
REM NOTE: keep this file pure ASCII -- cmd.exe reads .bat in the OEM
REM       codepage and non-ASCII bytes can swallow the following lines.
REM ============================================================
setlocal

set SCRIPT_DIR=%~dp0
for %%I in ("%SCRIPT_DIR%..\..\native") do set "NATIVE=%%~fI"
if "%CANGJIE_HOME%"=="" set "CANGJIE_HOME=D:\Program Files (x86)\Cangjie"
if "%CANGJIE_STDX%"=="" set "CANGJIE_STDX=D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"

set "APP=%SCRIPT_DIR%target\release\bin\main.exe"
set "LOG=%TEMP%\cj-clipboard-history.log"

if not exist "%NATIVE%\libcjtbridge.dll" (
    echo [ERROR] native\libcjtbridge.dll not found.
    echo         Run native\build_win.bat first.
    exit /b 1
)
if not exist "%NATIVE%\webview2\WebView2Loader.dll" (
    echo [ERROR] native\webview2\WebView2Loader.dll not found.
    echo         Run native\build_win.bat first.
    exit /b 1
)

REM Cangjie runtime + SDK tools + stdx + the C bridge + the WebView2 loader
set "PATH=%CANGJIE_HOME%\runtime\lib\windows_x86_64_cjnative;%CANGJIE_HOME%\bin;%CANGJIE_HOME%\tools\bin;%CANGJIE_STDX%;%NATIVE%;%NATIVE%\webview2;%PATH%"

REM The app reads capabilities\ and ui\ by relative path, so the working
REM directory must be this example's root.
cd /d "%SCRIPT_DIR%"

echo [run] building: cjpm build ...
call cjpm build
if errorlevel 1 (
    echo [ERROR] cjpm build failed -- check PATH / CANGJIE_HOME.
    exit /b 1
)

if exist "%LOG%" del "%LOG%"

echo [run] app = %APP%
echo [run] log = %LOG%
echo [run] starting -- close the window to quit.
echo.

REM The bridge writes its diagnostics to stderr only, so the log is the
REM evidence trail; replay it here instead of trying to tee.
"%APP%" > "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"

echo.
echo [run] exit=%RC%
if exist "%LOG%" type "%LOG%"
if exist "%LOG%" (
    echo ---- capability report (system:host) ----
    findstr /C:"tray=" /C:"hotkey=" "%LOG%"
)
echo [run] log kept at %LOG%
exit /b %RC%
