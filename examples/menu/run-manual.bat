@echo off
REM ============================================================
REM cj-tauri menu probe -- MANUAL mode (Windows).
REM
REM run.bat drives the menu from a PowerShell script and closes the
REM windows when it is finished. This one does none of that: it opens
REM the two probe windows and leaves them up, so a human can click the
REM native menu bar and watch the chain live in this console (all bridge
REM and probe diagnostics go to stderr, which is this window).
REM
REM What to look for while clicking:
REM   * [cj-bridge] menu clicked: id=... enabled=... checked=...
REM   * [menuprobe] window=<label> shell {"kind":"menu",...}
REM     -> <label> must be the window you clicked in; clicking in the
REM        MAIN window must NOT log window=second (routing is per host).
REM   * [cj-bridge] menu item state: id=view.sidebar enabled=0 checked=1
REM     -> one line per window, after you click "Disable sidebar" there.
REM   * Sidebar toggles its own check mark; "Disable sidebar" greys the
REM     Sidebar item out and ticks it.
REM
REM Read-only difference from run.bat: no build, no driver, no assertions.
REM Run "cjpm build" in this directory first if the binary is missing.
REM
REM NOTE: keep this file pure ASCII -- cmd.exe reads .bat in the OEM
REM       codepage and non-ASCII bytes can swallow the following lines.
REM ============================================================
setlocal

set SCRIPT_DIR=%~dp0
for %%I in ("%SCRIPT_DIR%..\..\native") do set "NATIVE=%%~fI"
if "%CANGJIE_HOME%"=="" set "CANGJIE_HOME=D:\Program Files (x86)\Cangjie"
if "%CANGJIE_STDX%"=="" set "CANGJIE_STDX=D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"

set "APP=%SCRIPT_DIR%target\release\bin\main.exe"

if not exist "%APP%" (
    echo [ERROR] %APP% not found.
    echo         Run "cjpm build" in examples\menu first.
    pause
    exit /b 1
)
if not exist "%NATIVE%\webview2\WebView2Loader.dll" (
    echo [ERROR] native\webview2\WebView2Loader.dll not found.
    echo         Run native\build_win.bat first.
    pause
    exit /b 1
)

REM Cangjie runtime + SDK tools + stdx + the C bridge + the WebView2 loader
set "PATH=%CANGJIE_HOME%\runtime\lib\windows_x86_64_cjnative;%CANGJIE_HOME%\bin;%CANGJIE_HOME%\tools\bin;%CANGJIE_STDX%;%NATIVE%;%NATIVE%\webview2;%PATH%"

REM capabilities\ is read by relative path -> run from the project root.
cd /d "%SCRIPT_DIR%"

echo [manual] opening two windows: "cj-tauri menu probe main" and "(second)".
echo [manual] click the native menu bar in either window; watch this console.
echo [manual] close the windows to end the run.
echo.
"%APP%"
echo [manual] exit=%ERRORLEVEL%
pause
