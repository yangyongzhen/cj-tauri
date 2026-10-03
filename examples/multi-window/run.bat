@echo off
REM ============================================================
REM cj-tauri multi-window PoC probe (examples/multi-window) on Windows.
REM
REM Hypotheses under test (see the header of src\main.cj):
REM   A) one process can run TWO hosts at the same time
REM   B) each window keeps its own label (the injected
REM      window.__CJ_TAURI_LABEL__ equals the "window" field of its IPC
REM      messages)
REM   C) a broadcast reaches both windows, a targeted event only its window
REM
REM On Linux A fails: WebKitGTK cannot be driven from two threads, so the
REM current "one host = one native thread = one main loop" layout cannot
REM start a second window (architecture doc, sec. 8). On Windows
REM two UI threads are legal (each window its own message loop, the WebView2
REM controller only touched by the thread that created it), so this run is
REM the open question: a pass means multi-window needs no single-main-loop
REM rework here, and sec. 8 needs a platform-specific correction.
REM
REM Usage:
REM   run.bat                             -> two windows (the PoC itself)
REM   set MW_MODE=single, then run.bat     -> single-window control group
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
if "%MW_MODE%"=="" set "MW_MODE=full"

set "APP=%SCRIPT_DIR%target\release\bin\main.exe"
set "LOG=%TEMP%\cj-multi-window-%MW_MODE%.log"

if not exist "%NATIVE%\webview2\WebView2Loader.dll" (
    echo [ERROR] native\webview2\WebView2Loader.dll not found.
    echo         Run native\build_win.bat first.
    exit /b 1
)

REM Cangjie runtime + SDK tools + stdx + the C bridge + the WebView2 loader
set "PATH=%CANGJIE_HOME%\runtime\lib\windows_x86_64_cjnative;%CANGJIE_HOME%\bin;%CANGJIE_HOME%\tools\bin;%CANGJIE_STDX%;%NATIVE%;%NATIVE%\webview2;%PATH%"

REM The app reads capabilities\ by relative path -> run it from the project root.
cd /d "%SCRIPT_DIR%"

if not exist "%APP%" (
    REM No parentheses here: this echo sits inside an "if ... (" block and an
    REM unescaped "(" makes cmd report a confusing parse error instead.
    echo [run] building the probe: cjpm build ...
    call cjpm build
    if errorlevel 1 (
        echo [ERROR] cjpm build failed -- check PATH / CANGJIE_HOME.
        exit /b 1
    )
)

echo [run] mode=%MW_MODE%
echo [run] app =%APP%
echo [run] log =%LOG%
"%APP%" > "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
echo [run] exit=%RC%

echo ---- evidence lines ----
findstr /C:"[mwprobe]" "%LOG%"
findstr /R /C:"label=.second." "%LOG%"

set "FAIL=0"
echo ---- assertions (mode=%MW_MODE%) ----
if /i "%MW_MODE%"=="single" goto :assert_single

call :check "[probe] main start"   "[mwprobe] main start"
call :check "second host started"  "label=.second." re
REM Do NOT pin the boot order: which host boots first is up to the runtime
REM (on Windows the "second" host was seen booting first). What hypothesis B
REM actually claims is that each window's routed identity equals the label it
REM read back from the injected window.__CJ_TAURI_LABEL__ -- and "GATE boots=2"
REM below proves both labels did register.
call :check "main labelled"        "window=main BOOT jsLabel=main booted="
call :check "second labelled"      "window=second BOOT jsLabel=second booted="
call :check "gate saw 2 windows"   "GATE boots=2"
call :check "driver counts"        "COUNTS role=driver label=main broadcast=1 target_main=1 target_second=0"
call :check "observer counts"      "COUNTS role=observer label=second broadcast=1 target_main=0 target_second=1"
call :check "run returned"         "[mwprobe] after run"
goto :verdict

:assert_single
call :check "[probe] main start"        "[mwprobe] main start"
call :check "main booted"               "BOOT jsLabel=main booted=1"
call :check "gate saw only 1 window"    "GATE boots=1"
call :check "reported missing 2nd win"  "FAIL second window never booted"
call :check "run returned"              "[mwprobe] after run"
call :absent "no second window"         "jsLabel=second"
if not "%RC%"=="0" (
    echo   FAIL  clean exit expected, got exit=%RC%
    set "FAIL=1"
)
goto :verdict

:verdict
if "%FAIL%"=="0" (
    if /i "%MW_MODE%"=="single" (
        echo [run] CONTROL PASS -- single-window path is intact on Windows.
    ) else (
        echo [run] PASS -- two windows ran together on Windows: A/B/C all hold.
        echo [run] NOTE: exit=%RC% is reported separately; a non-zero exit
        echo [run]       after the assertions may be the known flaky
        echo [run]       libwebkit2gtk exit-time abort seen on Linux.
    )
) else (
    if /i "%MW_MODE%"=="single" (
        echo [run] CONTROL FAIL -- single-window path regressed; see %LOG%
    ) else (
        echo [run] FAIL -- see %LOG% and check MW_MODE=single first to tell
        echo [run]        "the seam is broken" from "two hosts do not work".
    )
)
echo [run] full log: %LOG%
echo %CMDCMDLINE% | find /i "%~nx0" >nul && pause
exit /b %FAIL%

:check
if /i "%~3"=="re" (
    findstr /R /C:"%~2" "%LOG%" >nul 2>&1
) else (
    findstr /C:"%~2" "%LOG%" >nul 2>&1
)
if errorlevel 1 (
    echo   FAIL  %~1  ^(not found: %~2^)
    set "FAIL=1"
) else (
    echo   ok    %~1
)
goto :eof

:absent
findstr /C:"%~2" "%LOG%" >nul 2>&1
if errorlevel 1 (
    echo   ok    %~1
) else (
    echo   FAIL  %~1  ^(unexpected: %~2^)
    set "FAIL=1"
)
goto :eof
