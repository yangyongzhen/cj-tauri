@echo off
REM ============================================================
REM cj-tauri CLI launcher (Windows)
REM
REM Builds the CLI itself with cjpm on first run, then runs it with
REM the same PATH layout the SDK's envsetup.bat uses
REM (runtime DLL dir + bin + tools\bin + tools\lib).
REM Set CANGJIE_HOME if your SDK lives elsewhere.
REM
REM Comments are ASCII on purpose: Chinese text in a .bat file breaks
REM parsing under the default GBK code page.
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
if "%CANGJIE_HOME%"=="" set "CANGJIE_HOME=D:\Program Files (x86)\Cangjie"

set "PATH=%CANGJIE_HOME%\runtime\lib\windows_x86_64_cjnative;%CANGJIE_HOME%\bin;%CANGJIE_HOME%\tools\bin;%CANGJIE_HOME%\tools\lib;%PATH%;%USERPROFILE%\.cjpm\bin"

REM stdx dynamic dir (issue #11-3): the CLI itself loads libstdx.*.dll by name.
REM Without this dir on PATH the CLI exits silently with a loader error that is
REM invisible in pipelines. CANGJIE_STDX wins if set; otherwise probe the newest
REM version dir under %USERPROFILE%\.cangjie\stdx (reverse-name order works for
REM same-major version strings like 1.0.5.1 / 1.2.0.1).
set "STDX_DIR=%CANGJIE_STDX%"
if not defined STDX_DIR for /f "delims=" %%d in ('dir /b /ad /o-n "%USERPROFILE%\.cangjie\stdx\*" 2^>nul') do (
    if not defined STDX_DIR if exist "%USERPROFILE%\.cangjie\stdx\%%d\windows_x86_64_cjnative\dynamic\stdx" set "STDX_DIR=%USERPROFILE%\.cangjie\stdx\%%d\windows_x86_64_cjnative\dynamic\stdx"
)
if defined STDX_DIR set "PATH=%STDX_DIR%;%PATH%"

set "CLI_BIN=%SCRIPT_DIR%target\release\bin\main.exe"

if not exist "%CLI_BIN%" (
    echo [cj-tauri] first run: building the CLI itself ^(cjpm build^) ...
    pushd "%SCRIPT_DIR%"
    call cjpm build
    if errorlevel 1 (
        popd
        echo [cj-tauri] ERROR: CLI build failed
        exit /b 1
    )
    popd
)

if not exist "%CLI_BIN%" (
    echo [cj-tauri] ERROR: CLI binary not found: %CLI_BIN%
    exit /b 1
)

"%CLI_BIN%" %*
endlocal
