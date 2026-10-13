@echo off
REM ============================================================
REM cj-tauri serial plugin probe (examples\plugin-serial) -- Windows PC.
REM
REM Linux's run.sh proves the FULL roundtrip (open/write/read/close against a
REM real pty pair). Windows has no hardware/pty peer here, so this probe takes
REM the honest subset that does NOT need a peer:
REM   run A: serial:list (QueryDosDeviceW enumeration) + open on COM97 --
REM          COM97 passes the whitelist (COM + digits) but the device does not
REM          exist, so the open must fail with a READABLE error, not a crash;
REM   run B: open on COMfoo -- refused by the whitelist itself.
REM Both runs auto-quit (probe QUIT=1) and report through the page -> stderr.
REM
REM Keep this file pure ASCII (cmd.exe reads .bat in the OEM codepage).
REM ============================================================
setlocal

set SCRIPT_DIR=%~dp0
for %%I in ("%SCRIPT_DIR%..\..") do set "REPO_ROOT=%%~fI"
for %%I in ("%SCRIPT_DIR%..\..\native") do set "NATIVE=%%~fI"
if "%CANGJIE_HOME%"=="" set "CANGJIE_HOME=D:\Program Files (x86)\Cangjie"
if "%CANGJIE_STDX%"=="" set "CANGJIE_STDX=D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"

set "PATH=%CANGJIE_HOME%\bin;%CANGJIE_HOME%\tools\bin;%CANGJIE_HOME%\runtime\lib\windows_x86_64_cjnative;%NATIVE%;%NATIVE%\webview2;%CANGJIE_STDX%;%PATH%"

set "APP=%SCRIPT_DIR%target\release\bin\main.exe"
set "LOG=%TEMP%\cj-plugin-serial-win.log"

if not exist "%APP%" (
    echo [ERROR] %APP% not found -- run "cjpm build" in examples\plugin-serial first.
    exit /b 1
)

del "%LOG%" 2>nul

cd /d "%SCRIPT_DIR%"

echo [run] A: list + open COM97 (nonexistent, whitelist passes)
set "CJ_SERIAL_PROBE_PATH=COM97"
set "CJ_SERIAL_PROBE_BAUD=115200"
set "CJ_SERIAL_PROBE_QUIT=1"
"%APP%" >> "%LOG%" 2>&1

echo [run] B: open COMfoo (whitelist refuses)
set "CJ_SERIAL_PROBE_PATH=COMfoo"
"%APP%" >> "%LOG%" 2>&1

echo.
echo ---- evidence (from %LOG%) ----
findstr /C:"[probe] serial:list => ports=" "%LOG%"
findstr /C:"[probe] start path=COM97" "%LOG%"
findstr /C:"[probe] start path=COMfoo" "%LOG%"
findstr /C:"[probe] FAIL =>" "%LOG%"
findstr /C:"serial open:" "%LOG%"

set PASS=0
set FAIL=0
findstr /C:"[probe] serial:list => ports=" "%LOG%" >nul && set /a PASS+=1 || set /a FAIL+=1
findstr /C:"[probe] start path=COM97" "%LOG%" >nul && set /a PASS+=1 || set /a FAIL+=1
findstr /C:"[probe] FAIL =>" "%LOG%" >nul && set /a PASS+=1 || set /a FAIL+=1
findstr /C:"serial-namespace-type=object" "%LOG%" >nul && set /a PASS+=1 || set /a FAIL+=1

echo.
echo selfcheck: %PASS% passed, %FAIL% failed (log: %LOG%)
if %FAIL% GTR 0 exit /b 1
exit /b 0
