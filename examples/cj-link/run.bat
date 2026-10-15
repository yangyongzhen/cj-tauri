@echo off
REM ============================================================
REM cj-tauri cj-Link example (examples\cj-link) -- Windows PC.
REM
REM Usage:
REM   run.bat             normal: a window opens, pick a link and talk
REM   run.bat selfcheck   unattended probe: the page walks
REM                       serial open/write/read/close + CRC vectors +
REM                       TCP connect/send/recv/close + UDP connect/send/recv/close
REM                       and reports every step through `report`; then quits.
REM                       Needs cj-link-peer.py running as the far end
REM                       (see README.md: it plays the serial + TCP + UDP echo).
REM
REM What this run does:
REM   1) builds the app (cjpm build);
REM   2) starts it from the project root -- capabilities\ and ui\index.html are
REM      read by RELATIVE path (same convention as every example);
REM   3) keeps stderr in a log file (stderr is the record: Cangjie stdout is
REM      buffered and would be lost on a hard kill).
REM
REM Evidence to look for in the log:
REM   [cj-link] main start                 -- assembly reached main()
REM   [cj-link] ui page loaded (N bytes)   -- ui\index.html was read
REM   [cj-bridge] ... window ...           -- the host window came up
REM   [frontend] ...                       -- page-side probe, reported back
REM   [cj-bridge] ExecuteScript -> hr=0x00000000
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
set "LOG=%TEMP%\cj-link-app.log"
set "MODE=%~1"
if /I "%MODE%"=="selfcheck" (
    set "CJ_LINK_PROBE=1"
) else (
    set "MODE=play"
)

if not exist "%NATIVE%\webview2\WebView2Loader.dll" (
    echo [ERROR] native\webview2\WebView2Loader.dll not found.
    echo         Run native\build_win.bat first.
    exit /b 1
)

REM Cangjie runtime + SDK tools + stdx + the C bridge + the WebView2 loader
set "PATH=%CANGJIE_HOME%\runtime\lib\windows_x86_64_cjnative;%CANGJIE_HOME%\bin;%CANGJIE_HOME%\tools\bin;%CANGJIE_STDX%;%NATIVE%;%NATIVE%\webview2;%PATH%"

REM Relative-path reads (capabilities\, ui\) mean the cwd must be the project root.
cd /d "%SCRIPT_DIR%"

echo [run] building: cjpm build ...
call cjpm build
if errorlevel 1 (
    echo [ERROR] cjpm build failed -- check PATH / CANGJIE_HOME.
    exit /b 1
)

if exist "%LOG%" del "%LOG%"

echo [run] mode = %MODE%
if /I "%MODE%"=="play" echo [run] starting cj-Link -- close the window to exit
if /I "%MODE%"=="selfcheck" echo [run] unattended probe -- needs cj-link-peer.py as the far end
echo [run] app = %APP%
echo [run] log = %LOG%

"%APP%" 2>"%LOG%"
set "RC=%ERRORLEVEL%"

echo [run] exited with code %RC%
echo [run] --- app / command log ---
findstr /C:"[cj-link]" "%LOG%"
echo [run] --- host log ---
findstr /C:"[cj-bridge]" "%LOG%"
echo [run] --- page-side probe ---
findstr /C:"[frontend]" "%LOG%"
echo [run] full stderr log: %LOG%

if /I "%MODE%"=="selfcheck" goto :tally
exit /b %RC%

:tally
findstr /C:"FAIL " "%LOG%" >nul
if not errorlevel 1 (
    echo [run] PROBE HAS FAILURES -- see the FAIL lines above
    exit /b 2
)
echo [run] probe: no FAIL lines
exit /b %RC%
