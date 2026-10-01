@echo off
REM ============================================================
REM Run the Vue 3 version of the tutorial's todo-list app
REM (examples/vue_todo). Its commands and events are identical to
REM examples/todo_check -- only the frontend differs (Vite + Vue 3).
REM
REM The release page is ui\dist\index.html, a single file produced by
REM vite-plugin-singlefile, so build the frontend once before running:
REM     cd ui && npm install && npm run build
REM
REM Same env layout as the repo-root run_win.bat: Cangjie runtime +
REM stdx + the C bridge + the WebView2 loader.
REM Keep this file pure ASCII -- cmd.exe reads .bat in the OEM codepage.
REM ============================================================
setlocal

set SCRIPT_DIR=%~dp0
for %%I in ("%SCRIPT_DIR%..\..") do set "REPO_ROOT=%%~fI"
for %%I in ("%SCRIPT_DIR%..\..\native") do set "NATIVE=%%~fI"
if "%CANGJIE_HOME%"=="" set "CANGJIE_HOME=D:\Program Files (x86)\Cangjie"
if "%CANGJIE_STDX%"=="" set "CANGJIE_STDX=D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"

set "APP=%SCRIPT_DIR%target\release\bin\main.exe"
if not exist "%APP%" (
    echo [ERROR] %APP% not found. Build it first:
    echo         cd examples\vue_todo ^&^& cjpm build
    exit /b 1
)
if not exist "%SCRIPT_DIR%ui\dist\index.html" (
    echo [ERROR] ui\dist\index.html not found. Build the frontend first:
    echo         cd examples\vue_todo\ui ^&^& npm install ^&^& npm run build
    exit /b 1
)

set "PATH=%CANGJIE_HOME%\runtime\lib\windows_x86_64_cjnative;%CANGJIE_STDX%;%NATIVE%;%NATIVE%\webview2;%PATH%"

REM The app reads ui\ and capabilities\ by relative path - run from project root.
cd /d "%SCRIPT_DIR%"

echo [run] %APP%
"%APP%"
endlocal
