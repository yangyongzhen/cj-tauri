@echo off
REM ============================================================
REM cj-tauri serial-assistant probe (examples\serial-assistant) -- Windows.
REM
REM Evidence this run produces (bridge stderr + peer-side log):
REM   1) serial:list really enumerates COM ports on Windows:
REM        "port enum" line in the frontend report;
REM   2) serial:open really opens a Win32 comm port:
REM        "[cj-bridge] serial win32: path=COM1 ... handle=0x..." and
REM        "serial open: handle=N";
REM   3) write direction is proven OUTSIDE the app: the peer process
REM      (serial-peer-win.ps1 on COM2) logs the bytes it received;
REM   4) read direction: the app reads back the peer's "PONG:<rx>" frame;
REM   5) serial:close returns true.
REM
REM Loopback pairing: COM1 (app side) <-> COM2 (peer side) must be a virtual
REM null-modem pair (com0com or similar). The peer is started first; the app
REM gets CJ_SERIAL_PROBE_PATH=COM1 via document-start injection and runs the
REM probe round automatically.
REM
REM NOTE: keep this file pure ASCII -- cmd.exe reads .bat in the OEM codepage.
REM ============================================================
setlocal

set SCRIPT_DIR=%~dp0
for %%I in ("%SCRIPT_DIR%..\..") do set "REPO_ROOT=%%~fI"
for %%I in ("%SCRIPT_DIR%..\..\native") do set "NATIVE=%%~fI"
if "%CANGJIE_HOME%"=="" set "CANGJIE_HOME=D:\Program Files (x86)\Cangjie"
if "%CANGJIE_STDX%"=="" set "CANGJIE_STDX=D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"

set "APP=%SCRIPT_DIR%target\release\bin\main.exe"
set "LOG=%TEMP%\cj-serial-assistant.log"
set "PLOG=%TEMP%\cj-serial-peer.log"
set "RX=%TEMP%\cj-serial-peer-rx.log"
set "PEER=%SCRIPT_DIR%serial-peer-win.ps1"

if not exist "%NATIVE%\libcjtbridge.dll" (
    echo [ERROR] native\libcjtbridge.dll not found. Run native\build_win.bat first.
    exit /b 1
)
if not exist "%PEER%" (
    echo [ERROR] %PEER% not found.
    exit /b 1
)

set "PATH=%CANGJIE_HOME%\runtime\lib\windows_x86_64_cjnative;%CANGJIE_HOME%\bin;%CANGJIE_HOME%\tools\bin;%CANGJIE_STDX%;%NATIVE%;%NATIVE%\webview2;%PATH%"

cd /d "%SCRIPT_DIR%"

echo [run] building: cjpm build ...
call cjpm build
if errorlevel 1 (
    echo [ERROR] cjpm build failed -- check PATH / CANGJIE_HOME.
    exit /b 1
)

if exist "%LOG%" del "%LOG%"
if exist "%PLOG%" del "%PLOG%"
if exist "%RX%" del "%RX%"

REM "run.bat manual": open the window for hand testing -- no probe env, no peer,
REM no auto-quit. Everything else (PATH, working dir, log) is identical.
if /I "%~1"=="manual" (
    echo [run] manual mode -- app window will stay open, close it yourself
    "%APP%" > "%LOG%" 2>&1
    echo [run] exit=%ERRORLEVEL%
    echo [run] log=%LOG%
    exit /b 0
)

echo [run] app  =%APP%
echo [run] log  =%LOG%
echo [run] peer =%PEER%

REM Peer first (COM2): it sends the initial PONG the probe reads first.
REM chcp 65001 first: powershell child inherits the OEM codepage (GBK here) for its
REM error reports, which findstr cannot grep (UTF-16 warning + mojibake). Under 65001
REM the redirected log is plain ASCII. NOTE the redirect must live INSIDE the inner
REM cmd /c string -- as a start-level redirect the inner window's output never lands.
start "serialpeer" /min cmd /c "chcp 65001 >nul && powershell -NoProfile -ExecutionPolicy Bypass -File %PEER% -Port COM2 -RxFile %RX% -IdleExitSec 20 > "%PLOG%" 2>&1"
REM ping is the reliable wait inside .bat (GNU timeout on PATH shadows timeout.exe)
ping -n 3 127.0.0.1 >nul

set "CJ_SERIAL_PROBE_PATH=COM1"
set "CJ_SERIAL_PROBE_BAUD=115200"
set "CJ_SERIAL_PROBE_DATA=cj-tauri-ping"
set "CJ_SERIAL_PROBE_READ_MS=800"
set "CJ_SERIAL_PROBE_QUIT=1"

"%APP%" > "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
echo [run] exit=%RC%

echo ---- app evidence (frontend / bridge) ----
findstr /C:"[frontend]" "%LOG%"
findstr /C:"[cj-bridge] serial" "%LOG%"

echo ---- peer evidence (outside the app: bytes really hit the wire) ----
if exist "%PLOG%" findstr /C:"[peer]" "%PLOG%"

set "FAIL=0"
echo ---- assertions ----
call :check "probe started"            "[probe] start path=COM1"
REM port-enumeration proof: the page selfcheck prints an ASCII "port enum" line via report
call :check "port enumeration ran"     "port enum"
call :check "open succeeded"           "serial open: handle="
call :check "bridge logged win32 open" "serial win32: path=COM1"
call :check "probe ALL DONE"           "[probe] ALL DONE"
call :check "app returned"             "[serial-assistant] after run"
call :check "peer saw app bytes"       "cj-tauri-ping" "%RX%"
call :check "peer answered"            "[peer] rx" "%PLOG%"

if "%FAIL%"=="0" (
    echo [run] PASS -- the serial chain is live on Windows: enumerated COM ports,
    echo [run]        opened COM1, wrote to the wire, read the peer PONG back, closed.
) else (
    echo [run] FAIL -- see %LOG% and %PLOG%
)
echo [run] app log : %LOG%
echo [run] peer log: %PLOG%
echo [run] peer rx : %RX%
exit /b %FAIL%

:check
REM :check "label" "needle" [logfile]
set "CLOG=%~3"
if "%CLOG%"=="" set "CLOG=%LOG%"
findstr /C:"%~2" "%CLOG%" >nul 2>&1
if errorlevel 1 (
    echo   FAIL  %~1  ^(not found: %~2^)
    set "FAIL=1"
) else (
    echo   ok    %~1
)
goto :eof
