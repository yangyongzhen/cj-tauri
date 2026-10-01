@echo off
REM ============================================================
REM Run the cj-tauri hello example on Windows (WebView2 backend).
REM
REM Prerequisites:
REM   1) native\libcjtbridge.dll + native\webview2\WebView2Loader.dll built
REM      (run native\build_win.bat first)
REM   2) examples\hello built once: cd examples\hello ^&^& cjpm build
REM   3) WebView2 Runtime installed, with a version >= the WebView2 SDK
REM      used to build the bridge
REM
REM Override CANGJIE_HOME / CANGJIE_STDX if your install paths differ.
REM ============================================================
setlocal

set SCRIPT_DIR=%~dp0
if "%CANGJIE_HOME%"=="" set "CANGJIE_HOME=D:\Program Files (x86)\Cangjie"
if "%CANGJIE_STDX%"=="" set "CANGJIE_STDX=D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"

set "APP=%SCRIPT_DIR%examples\hello\target\release\bin\main.exe"
if not exist "%APP%" (
    echo [ERROR] %APP% not found. Build the example first:
    echo         cd examples\hello ^&^& cjpm build
    exit /b 1
)
if not exist "%SCRIPT_DIR%native\webview2\WebView2Loader.dll" (
    echo [ERROR] native\webview2\WebView2Loader.dll not found.
    echo         Run native\build_win.bat first.
    exit /b 1
)

REM Cangjie runtime + stdx + the C bridge + the WebView2 loader
set "PATH=%CANGJIE_HOME%\runtime\lib\windows_x86_64_cjnative;%CANGJIE_STDX%;%SCRIPT_DIR%native;%SCRIPT_DIR%native\webview2;%PATH%"

REM The app reads capabilities\ and ui\ by relative path, so run it from the
REM example root (same project-root convention as a Tauri app).
REM NOTE: keep this file pure ASCII -- cmd.exe reads .bat in the OEM codepage
REM       and non-ASCII bytes can break subsequent lines.
cd /d "%SCRIPT_DIR%examples\hello"

echo [run] %APP%
"%APP%"
endlocal
