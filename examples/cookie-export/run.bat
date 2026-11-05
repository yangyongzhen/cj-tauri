@echo off
REM ============================================================
REM cj-tauri cookie-export (cspub credential helper) -- Windows launcher.
REM
REM What this run is evidence for:
REM   1) the window comes up and the page loads (5 platform cards);
REM   2) cookie:platforms / cookie:probe / cookie:export are registered
REM      AND allowed by capabilities\app.json -- otherwise the front end
REM      gets "command not registered" / "command not allowed";
REM   3) the native cookie path works on Windows: the C bridge answers
REM      "[cj-bridge] get_cookies: filter=... -> N bytes" from
REM      ICoreWebView2_2::get_CookieManager (this used to be unverified).
REM
REM Override CANGJIE_HOME / CANGJIE_STDX if your install paths differ.
REM NOTE: keep this file pure ASCII -- cmd.exe reads .bat in the OEM codepage
REM       and non-ASCII bytes can swallow the following lines.
REM ============================================================
setlocal

set SCRIPT_DIR=%~dp0
for %%I in ("%SCRIPT_DIR%..\..\native") do set "NATIVE=%%~fI"
if "%CANGJIE_HOME%"=="" set "CANGJIE_HOME=D:\Program Files (x86)\Cangjie"
if "%CANGJIE_STDX%"=="" set "CANGJIE_STDX=D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"

set "APP=%SCRIPT_DIR%target\release\bin\main.exe"
set "LOG=%TEMP%\cj-cookie-export.log"

if not exist "%NATIVE%\webview2\WebView2Loader.dll" (
    echo [ERROR] native\webview2\WebView2Loader.dll not found.
    echo         Run native\build_win.bat first.
    exit /b 1
)

REM Cangjie runtime + SDK tools + stdx + the C bridge + the WebView2 loader.
REM Missing runtime\lib here makes cjpm exit 127 with no output at all.
set "PATH=%CANGJIE_HOME%\runtime\lib\windows_x86_64_cjnative;%CANGJIE_HOME%\bin;%CANGJIE_HOME%\tools\bin;%CANGJIE_STDX%;%NATIVE%;%NATIVE%\webview2;%PATH%"

REM The page and the capability list are read relative to the project root.
cd /d "%SCRIPT_DIR%"

if not exist "%APP%" (
    echo [run] building: cjpm build ...
    call cjpm build
    if errorlevel 1 (
        echo [ERROR] cjpm build failed -- check PATH / CANGJIE_HOME.
        exit /b 1
    )
)

if exist "%LOG%" del "%LOG%"
echo [run] app = %APP%
echo [run] log = %LOG%

REM No parentheses in echos: this file has "if ... (" blocks and an unescaped
REM "(" inside one makes cmd report a parse error far away from the real line.
echo [run] starting the window. Close it to end the run.
"%APP%" > "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
echo [run] exit=%RC%

echo ---- bridge evidence ----
findstr /C:"[cj-bridge]" "%LOG%"
echo [run] full log: %LOG%
exit /b %RC%
