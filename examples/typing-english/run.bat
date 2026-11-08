@echo off
REM ============================================================
REM cj-tauri typing-english example (examples\typing-english) -- Windows PC.
REM
REM Usage:
REM   run.bat             normal play: a window opens, pick a lesson, type
REM   run.bat selfcheck   unattended self check: the page types words by
REM                       itself, asserts the Chinese-meaning popups (one
REM                       per completed word, queued in order), then quits
REM                       (exit code 2 if any FAIL)
REM
REM What this run does:
REM   1) builds the app (cjpm build);
REM   2) starts it from the project root -- the app reads capabilities\ and
REM      ui\index.html by RELATIVE path (same convention as every example);
REM   3) keeps the app's stderr in a log file (stderr is the record here:
REM      Cangjie's stdout is buffered and would be lost on a hard kill).
REM
REM Evidence to look for in the log (the app's own log lines are Chinese; the
REM ASCII tags below are what findstr keys on):
REM   [english] main start                    -- assembly reached main()
REM   [english] word:list -> <N> ...          -- the word bank reached the page
REM   [english] score:save ...                -- stars + best flags at the end
REM   [cj-bridge] ... window ...              -- the host window came up
REM   [frontend] PASS/FAIL ...                -- page-side self check lines
REM
REM Handy overrides (see src/commands.cj):
REM   set CJ_TYPING_LESSON=school   open straight into one lesson
REM   set CJ_TYPING_POP_MS=4000     how long a meaning card stays (600..12000)
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
if "%CANGJIE_STDX%"=="" set "CANGJIE_STDX=D:\cangjie-stdx\1.2.0.1\windows_x86_64_cjnative\dynamic\stdx"

set "APP=%SCRIPT_DIR%target\release\bin\main.exe"
set "LOG=%TEMP%\cj-typing-english.log"
set "MODE=%~1"
if /I "%MODE%"=="selfcheck" (
    set "CJ_TYPING_SELFCHECK=1"
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
if /I "%MODE%"=="selfcheck" echo [run] unattended: the page types words itself, then quits
if /I "%MODE%"=="play" echo [run] close the window to exit
echo [run] app = %APP%
echo [run] log = %LOG%

"%APP%" 2>"%LOG%"
set "RC=%ERRORLEVEL%"

echo [run] exited with code %RC%
echo [run] --- framework / command log ---
findstr /C:"[english]" "%LOG%"
echo [run] --- host log ---
findstr /C:"[cj-bridge]" "%LOG%"
echo [run] --- page-side self check ---
findstr /C:"[frontend]" "%LOG%"
echo [run] full stderr log: %LOG%

if /I "%MODE%"=="selfcheck" (
    findstr /C:"FAIL " "%LOG%" >nul
    if not errorlevel 1 (
        echo [run] SELF CHECK HAS FAILURES -- see the FAIL lines above
        exit /b 2
    )
    echo [run] self check: no FAIL lines
)
exit /b %RC%
