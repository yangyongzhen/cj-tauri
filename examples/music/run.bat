@echo off
REM ============================================================
REM cj-tauri music player example (examples\music) -- Windows PC.
REM
REM Usage:
REM   run.bat             normal play: a window opens, pick a song
REM   run.bat selfcheck   unattended check, level 1: the page pulls the
REM                       chart, fetches a cover, PLAYS (muted, to get past
REM                       the autoplay policy), syncs lyrics, writes a
REM                       favourite to the local library, then quits.
REM                       Nothing is sent to the backend.
REM   run.bat selfcheck2  level 1 + submit the playlist to the backend
REM                       (creates one menu entry there; use it only when
REM                       you really mean to write to the shared backend)
REM
REM What this run does:
REM   1) builds the app (cjpm build);
REM   2) starts it from the project root -- the app reads capabilities\ and
REM      ui\index.html by RELATIVE path (same convention as every example);
REM   3) keeps the app's stderr in a log file (stderr is the record here:
REM      Cangjie's stdout is buffered and would be lost on a hard kill).
REM
REM Evidence to look for in the log (the app's own log lines are Chinese;
REM the ASCII tags below are what findstr keys on):
REM   [music] main start                    -- assembly reached main()
REM   [music] ui page loaded (N bytes)      -- ui\index.html was read
REM   [cj-bridge] ... window ...            -- the host window came up
REM   [music] music:hot -> 200 ok bytes=... -- a page action really reached
REM                                            the backend THROUGH Cangjie
REM   [music] lyric sid=... lines=N         -- LRC parsed on the Cangjie side
REM   [music] fav set: songs=N saved=true   -- the local library was written
REM   [frontend] ...                        -- page-side check + self check,
REM                                            reported back via `report`
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
set "LOG=%TEMP%\cj-music-app.log"
set "MODE=%~1"
if /I "%MODE%"=="selfcheck" (
    set "CJ_MUSIC_SELFCHECK=1"
) else if /I "%MODE%"=="selfcheck2" (
    set "CJ_MUSIC_SELFCHECK=2"
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
if /I "%MODE%"=="play" echo [run] starting the player -- close the window to exit
if /I "%MODE%"=="selfcheck" echo [run] unattended: page checks itself, then quits (no backend writes)
if /I "%MODE%"=="selfcheck2" echo [run] unattended + sends a playlist to the backend
echo [run] app = %APP%
echo [run] log = %LOG%

"%APP%" 2>"%LOG%"
set "RC=%ERRORLEVEL%"

echo [run] exited with code %RC%
echo [run] --- app / command log ---
findstr /C:"[music]" "%LOG%"
echo [run] --- host log ---
findstr /C:"[cj-bridge]" "%LOG%"
echo [run] --- page-side check ---
findstr /C:"[frontend]" "%LOG%"
echo [run] full stderr log: %LOG%

if /I "%MODE%"=="selfcheck" goto :tally
if /I "%MODE%"=="selfcheck2" goto :tally
exit /b %RC%

:tally
findstr /C:"FAIL " "%LOG%" >nul
if not errorlevel 1 (
    echo [run] SELF CHECK HAS FAILURES -- see the FAIL lines above
    exit /b 2
)
echo [run] self check: no FAIL lines
exit /b %RC%
