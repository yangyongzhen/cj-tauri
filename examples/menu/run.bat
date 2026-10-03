@echo off
REM ============================================================
REM cj-tauri menu capability probe (examples\menu) -- Windows only.
REM
REM What this run is evidence for (see src\main.cj and click-menu.ps1):
REM   1) the menu bar really gets built on the host UI thread -- once per
REM      window: "[cj-bridge] menu applied: items=N";
REM   2) a real Win32 WM_COMMAND click travels the whole chain
REM      (bridge -> core -> Cangjie shell callback) and comes back out into
REM      the platform menu;
REM   3) the item state really changed ON THE PLATFORM: click-menu.ps1 reads it
REM      back with GetMenuState, so "the app says it changed" is not the evidence;
REM   4) per-window routing: only the SECOND window's menu is clicked, so the
REM      first window must log NO shell event at all (this is what exercises
REM      HostGlobals.shellRoutes + cj_bridge_host_eq);
REM   5) both windows own independent HMENUs.
REM
REM Why Windows only: the two-window part cannot run on Linux (WebKitGTK cannot
REM be driven from two threads -- see examples\multi-window), and this box has no
REM GTK/WebKitGTK toolchain to build the Linux bridge anyway.
REM
REM Override CANGJIE_HOME / CANGJIE_STDX if your install paths differ.
REM NOTE: keep this file pure ASCII -- cmd.exe reads .bat in the OEM codepage
REM       and non-ASCII bytes can swallow the following lines.
REM ============================================================
setlocal

set SCRIPT_DIR=%~dp0
for %%I in ("%SCRIPT_DIR%..\..") do set "REPO_ROOT=%%~fI"
for %%I in ("%SCRIPT_DIR%..\..\native") do set "NATIVE=%%~fI"
if "%CANGJIE_HOME%"=="" set "CANGJIE_HOME=D:\Program Files (x86)\Cangjie"
if "%CANGJIE_STDX%"=="" set "CANGJIE_STDX=D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"

set "APP=%SCRIPT_DIR%target\release\bin\main.exe"
set "LOG=%TEMP%\cj-menu-probe.log"
set "DLOG=%TEMP%\cj-menu-driver.log"
set "DRIVER=%SCRIPT_DIR%click-menu.ps1"

if not exist "%NATIVE%\webview2\WebView2Loader.dll" (
    echo [ERROR] native\webview2\WebView2Loader.dll not found.
    echo         Run native\build_win.bat first.
    exit /b 1
)
if not exist "%DRIVER%" (
    echo [ERROR] %DRIVER% not found.
    exit /b 1
)

REM Cangjie runtime + SDK tools + stdx + the C bridge + the WebView2 loader
set "PATH=%CANGJIE_HOME%\runtime\lib\windows_x86_64_cjnative;%CANGJIE_HOME%\bin;%CANGJIE_HOME%\tools\bin;%CANGJIE_STDX%;%NATIVE%;%NATIVE%\webview2;%PATH%"

REM The app reads capabilities\ by relative path -> run it from the project root.
cd /d "%SCRIPT_DIR%"

REM No parentheses in this echo: it would sit inside an "if ... (" block, and an
REM unescaped "(" makes cmd report a confusing parse error instead.
echo [run] building the probe: cjpm build ...
call cjpm build
if errorlevel 1 (
    echo [ERROR] cjpm build failed -- check PATH / CANGJIE_HOME.
    exit /b 1
)

if exist "%LOG%" del "%LOG%"
if exist "%DLOG%" del "%DLOG%"

echo [run] app    =%APP%
echo [run] log    =%LOG%
echo [run] driver =%DRIVER%
echo [run] dlog   =%DLOG%

REM The driver runs in the background: it waits for the window, clicks the menu and
REM finally posts WM_CLOSE, which is what lets the foreground app return from run().
start "menudriver" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%DRIVER%" -Seconds 60 -ProcName main -LogPath "%DLOG%"

"%APP%" > "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
echo [run] exit=%RC%

echo ---- app evidence (menuprobe / bridge) ----
findstr /C:"[menuprobe]" "%LOG%"
REM Whole bridge lines, not "menu ": a needle with a space silently hid the very
REM diagnostics that explained why the menu was missing (menu: ... SetMenu failed).
findstr /C:"[cj-bridge]" "%LOG%"

echo ---- driver evidence (Win32 side) ----
if exist "%DLOG%" findstr /C:"[click]" "%DLOG%"

set "FAIL=0"
echo ---- assertions ----
call :check "probe started"          "[menuprobe] main start"
call :count "both windows armed"     "menu set bytes=" 2
call :check "capability reported"    "menu-capable=true"
call :count "menu built on UI thread" "menu applied: items=" 2
call :count "three clicks reached core" "menu clicked: id=" 3
call :check "plain item clicked"     "menu clicked: id=file.new enabled=1 checked=0"
call :check "platform flipped the check mark" "menu clicked: id=view.sidebar enabled=1 checked=1"
REM The routing claim: every click was aimed at the SECOND window's menu.
call :count "second window got all 3" "window=second shell" 3
call :count "first window stayed silent" "window=main shell" 0
call :check "app reacted to edit.toggle" "state requested id=view.sidebar enabled=false checked=true"
call :check "platform applied the state" "set menu item: id=view.sidebar enabled=0 checked=1"
call :check "app returned"           "[menuprobe] after run"

REM Driver-side (Win32) checks: state read back from the real menu, not from the app.
call :check "driver finished"        "[click] DONE" "" "%DLOG%"
call :check "second menu has 5 items" "second menu items=5" "" "%DLOG%"
call :check "check mark read back"   "sidebar checked=True" "" "%DLOG%"
call :check "state read back"        "sidebar disabled=True checked=True" "" "%DLOG%"
call :check "menus are independent"  "main menu items=5 independent-handle" "" "%DLOG%"

if "%FAIL%"=="0" (
    echo [run] PASS -- the menu chain is live on Windows: built on the UI thread,
    echo [run]        clicked from Win32, state changed on the real menu, and the
    echo [run]        event reached only the window that owned it.
) else (
    echo [run] FAIL -- see %LOG% and %DLOG%
)
echo [run] app log: %LOG%
echo [run] drv log: %DLOG%
exit /b %FAIL%

:check
REM :check "label" "needle" [re] [logfile]
set "CLOG=%~4"
if "%CLOG%"=="" set "CLOG=%LOG%"
if /i "%~3"=="re" (
    findstr /R /C:"%~2" "%CLOG%" >nul 2>&1
) else (
    findstr /C:"%~2" "%CLOG%" >nul 2>&1
)
if errorlevel 1 (
    echo   FAIL  %~1  ^(not found: %~2^)
    set "FAIL=1"
) else (
    echo   ok    %~1
)
goto :eof

:count
REM :count "label" "needle" expected [logfile] -- "expected" is exact, because a
REM missing line must be distinguishable from a duplicated one.
REM Count with cmd builtins + findstr ONLY. Do not pipe into `find /c /v ""`: under a
REM Git Bash PATH `find` is MSYS's GNU find, which reads "/c" as a path and walks the
REM whole disk (observed: the run hung until its timeout).
set "NLOG=%~4"
if "%NLOG%"=="" set "NLOG=%LOG%"
set /a CNT=0
for /f %%L in ('findstr /C:"%~2" "%NLOG%"') do set /a CNT+=1
if "%CNT%"=="%~3" (
    echo   ok    %~1  ^(count=%~3^)
) else (
    echo   FAIL  %~1  ^(expected %~3 lines of "%~2", got %CNT%^)
    set "FAIL=1"
)
goto :eof
