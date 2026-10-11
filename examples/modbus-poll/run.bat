@echo off
REM ============================================================
REM cj-tauri Modbus Poll example (examples\modbus-poll) -- Windows PC.
REM
REM Usage:
REM   run.bat             normal use: a window opens, add panels and poll
REM   run.bat selfcheck   unattended check: starts the built-in Modbus TCP
REM                       slave simulator, the page runs read/write round
REM                       trips against 127.0.0.1, prints PASS/FAIL lines,
REM                       then quits.
REM
REM What this run does:
REM   1) builds the app (cjpm build);
REM   2) starts it from the project root -- the app reads capabilities\
REM      and ui\index.html by RELATIVE path (same convention as every
REM      example);
REM   3) keeps the app's stderr in a log file (stderr is the record here:
REM      Cangjie's stdout is buffered and would be lost on a hard kill).
REM
REM Evidence to look for in the log:
REM   [mbpoll] main start               -- assembly reached main()
REM   [mbpoll] read host:... -> N ...   -- a poll really reached the Modbus
REM                                        layer THROUGH Cangjie
REM   [mbpoll] write ... -> ok          -- a write round-trip
REM   [frontend] PASS/FAIL ...          -- page-side self check lines
REM   [cj-bridge] ...                   -- the host window came up
REM
REM NOTE: keep this file pure ASCII -- cmd.exe reads .bat in the OEM
REM       codepage and non-ASCII bytes can swallow the following lines.
REM ============================================================
setlocal

set SCRIPT_DIR=%~dp0
for %%I in ("%SCRIPT_DIR%..\..") do set "REPO_ROOT=%%~fI"
for %%I in ("%SCRIPT_DIR%..\..\native") do set "NATIVE=%%~fI"
if "%CANGJIE_HOME%"=="" set "CANGJIE_HOME=D:\Program Files (x86)\Cangjie"
if "%CANGJIE_STDX%"=="" set "CANGJIE_STDX=D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"

set "APP=%SCRIPT_DIR%target\release\bin\main.exe"
set "LOG=%TEMP%\cj-mbpoll-app.log"
set "MODE=%~1"
set "SLAVE=0"
if /I "%MODE%"=="selfcheck" (
    set "SELFCHECK=1"
    set "SLAVE=1"
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
if /I "%MODE%"=="selfcheck" echo [run] unattended: built-in slave + page self check, then quits
if /I "%MODE%"=="play" echo [run] starting Modbus Poll -- close the window to exit
echo [run] app = %APP%
echo [run] log = %LOG%

set "CJ_MB_SLAVE=%SLAVE%"
set "CJ_MB_SELFCHECK=%SELFCHECK%"
"%APP%" 2>"%LOG%"
set "RC=%ERRORLEVEL%"

echo [run] exited with code %RC%
echo [run] --- app / command log ---
findstr /C:"[mbpoll]" "%LOG%"
echo [run] --- page-side check ---
findstr /C:"[frontend]" "%LOG%"
echo [run] --- host log ---
findstr /C:"[cj-bridge]" "%LOG%"
echo [run] full stderr log: %LOG%

if /I "%MODE%"=="selfcheck" goto :tally
exit /b %RC%

:tally
findstr /C:"FAIL " "%LOG%" >nul
if not errorlevel 1 (
    echo [run] SELF CHECK HAS FAILURES -- see the FAIL lines above
    exit /b 2
)
echo [run] self check: no FAIL lines
exit /b %RC%
