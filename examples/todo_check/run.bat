@echo off
REM ============================================================
REM Run the tutorial's todo-list app (examples/todo_check).
REM Its sources are extracted from docs/前端入门教程.md by extract.js,
REM so this doubles as an end-to-end check of the tutorial's code.
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
    echo         cd examples\todo_check ^&^& cjpm build
    exit /b 1
)

set "PATH=%CANGJIE_HOME%\runtime\lib\windows_x86_64_cjnative;%CANGJIE_STDX%;%NATIVE%;%NATIVE%\webview2;%PATH%"

REM The app reads ui\ and capabilities\ by relative path -> run from project root.
cd /d "%SCRIPT_DIR%"

echo [run] %APP%
"%APP%"
endlocal
