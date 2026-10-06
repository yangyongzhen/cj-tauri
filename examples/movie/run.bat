@echo off
REM ============================================================
REM cj-tauri movie app example (examples\movie) -- Windows PC.
REM
REM What this run does:
REM   1) builds the app (cjpm build);
REM   2) starts it from the project root -- the app reads capabilities\ and
REM      ui\index.html by RELATIVE path (same convention as every example);
REM   3) keeps the app's stderr in a log file.
REM
REM Evidence to look for in the log (the project takes stderr as the record):
REM   [movie] main start                  -- assembly reached main()
REM   [movie] ui page loaded (N bytes)   -- ui\index.html was read
REM   [cj-bridge] ... window ...          -- the host window came up
REM   [movie] /api/v1/hotmovie -> 200 ok  -- a page action really reached the
REM                                          backend THROUGH Cangjie
REM   [frontend] ...                      -- the page-side self check, reported
REM                                          back into stderr via `report`
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
set "LOG=%TEMP%\cj-movie-app.log"

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

echo [run] app = %APP%
echo [run] log = %LOG%
echo [run] starting the app -- close the window to exit.

"%APP%" 2>"%LOG%"
set "RC=%ERRORLEVEL%"

echo [run] exited with code %RC%
echo [run] --- backend calls issued by the app ---
findstr /C:"[movie]" "%LOG%"
echo [run] --- page-side self check ---
findstr /C:"[frontend]" "%LOG%"
echo [run] full stderr log: %LOG%
exit /b %RC%
