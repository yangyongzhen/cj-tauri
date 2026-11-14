@echo off
setlocal EnableExtensions
rem ============================================================
rem {{PROJECT_NAME}} - HarmonyOS PC (2in1) HAP build entry for Windows.
rem
rem Bat twin of build-hap.sh (same steps, native Windows paths; no Git Bash
rem needed). Runs from a cmd prompt or a PowerShell window alike.
rem Usage:
rem   build-hap.bat              build the hap
rem   build-hap.bat --install    build + hdc install + aa start
rem   build-hap.bat --clean      remove entry/build first (stale .so/.hap)
rem   build-hap.bat -h           show this help
rem
rem Prerequisites (each checked below with an actionable message):
rem   1. DevEco Studio 6.1+ (ships hvigor + node). Probed at common locations;
rem      set DEVECO_WIN=<install root, Windows form> to override.
rem   2. Ohos stdx: set CANGJIE_STDX_OHOS=<stdx>\linux_ohos_aarch64_cjnative\dynamic\stdx
rem      - without it cjpm reports a misleading "missing dependency" error.
rem   3. Signing: the template ships no certificate. In DevEco: File - Project
rem      Structure - Signing Configs - "Automatically generate signature"
rem      (needs a Huawei account). Unsigned builds yield *-unsigned.hap and
rem      cannot be installed (hdc install reports 9568289 etc.).
rem
rem To capture the full hvigor output to a file:  build-hap.bat > build.log 2>&1
rem
rem Comments are ASCII on purpose: Chinese text in a .bat file breaks parsing
rem under the default OEM code page.
rem ============================================================

cd /d "%~dp0"

rem ---------------- arguments ----------------
set "DO_INSTALL=0"
set "DO_CLEAN=0"
:arg_parse
if "%~1"=="" goto args_done
if /i "%~1"=="--install" (set "DO_INSTALL=1" & shift & goto arg_parse)
if /i "%~1"=="-install" (set "DO_INSTALL=1" & shift & goto arg_parse)
if /i "%~1"=="--clean" (set "DO_CLEAN=1" & shift & goto arg_parse)
if /i "%~1"=="-clean" (set "DO_CLEAN=1" & shift & goto arg_parse)
if /i "%~1"=="-h" goto help
if /i "%~1"=="--help" goto help
echo [ohos] unknown arg: %~1 (supported: --install / --clean / -h) 1>&2
exit /b 2
:args_done
goto :main
:help
echo Usage:
echo   build-hap.bat              build the hap
echo   build-hap.bat --install    build + hdc install + aa start
echo   build-hap.bat --clean      remove entry/build first
exit /b 0

:main
rem ---------------- DevEco install root ----------------
rem DEVECO_WIN first, then a few common locations.
if not defined DEVECO_WIN if exist "D:\oh\DevEcoStudio\tools\hvigor" set "DEVECO_WIN=D:\oh\DevEcoStudio"
if not defined DEVECO_WIN if exist "C:\Program Files\Huawei\DevEco Studio\tools\hvigor" set "DEVECO_WIN=C:\Program Files\Huawei\DevEco Studio"
if not defined DEVECO_WIN if exist "D:\Program Files\Huawei\DevEco Studio\tools\hvigor" set "DEVECO_WIN=D:\Program Files\Huawei\DevEco Studio"
if not defined DEVECO_WIN if exist "C:\Program Files (x86)\Huawei\DevEco Studio\tools\hvigor" set "DEVECO_WIN=C:\Program Files (x86)\Huawei\DevEco Studio"
if not defined DEVECO_WIN (
  echo [ohos] DevEco Studio not found. Set DEVECO_WIN=^<install root, Windows form^> 1>&2
  echo        e.g. set "DEVECO_WIN=C:\Program Files\Huawei\DevEco Studio" 1>&2
  exit /b 1
)

rem An invalid preset value makes hvigor fail with "Invalid value of ...":
rem fall back to the path under DEVECO_WIN and say what was ignored.
if not defined DEVECO_SDK_HOME set "DEVECO_SDK_HOME=%DEVECO_WIN%\sdk"
if defined DEVECO_SDK_HOME if not exist "%DEVECO_SDK_HOME%" (
  echo [ohos] ignoring invalid DEVECO_SDK_HOME: %DEVECO_SDK_HOME^> 1>&2
  set "DEVECO_SDK_HOME=%DEVECO_WIN%\sdk"
)
if not defined NODE_HOME set "NODE_HOME=%DEVECO_WIN%\tools\node"
if defined NODE_HOME if not exist "%NODE_HOME%" (
  echo [ohos] ignoring invalid NODE_HOME: %NODE_HOME^> 1>&2
  set "NODE_HOME=%DEVECO_WIN%\tools\node"
)

if not defined CANGJIE_STDX_OHOS (
  echo [ohos] set CANGJIE_STDX_OHOS=^<ohos stdx^\>linux_ohos_aarch64_cjnative\dynamic\stdx first 1>&2
  exit /b 1
)

set "NODE_EXE=%DEVECO_WIN%\tools\node\node.exe"
set "HVIGOR_JS=%DEVECO_WIN%\tools\hvigor\bin\hvigorw.js"
if not exist "%HVIGOR_JS%" (
  echo [ohos] %HVIGOR_JS% not found - is DEVECO_WIN correct? 1>&2
  exit /b 1
)

rem hvigorw locates the Cangjie build plugin itself and creates the node_modules
rem junctions; a headless run must hand it the path, or the failure surfaces as
rem "property name must be valid: cangjieOptions" (looks like a project config
rem error, actually the plugin was not loaded).
if not defined DEVECO_HVIGOR_CANGJIE_PLUGIN (
  if not defined APPDATA set "APPDATA=%USERPROFILE%\AppData\Roaming"
  for /d %%D in ("%APPDATA%\Huawei\DevEcoStudio*") do (
    for /d %%P in ("%%~D\plugins\devecostudio-cangjie-plugin-*") do (
      if exist "%%~P\lib\hvigor\cangjie-build-support" (
        if not defined DEVECO_HVIGOR_CANGJIE_PLUGIN set "DEVECO_HVIGOR_CANGJIE_PLUGIN=%%~P\lib\hvigor\cangjie-build-support"
      )
    )
  )
)
if not defined DEVECO_HVIGOR_CANGJIE_PLUGIN (
  echo [ohos] Cangjie build plugin not found under %APPDATA%\Huawei\DevEcoStudio*\plugins\devecostudio-cangjie-plugin-*\lib\hvigor\cangjie-build-support 1>&2
  echo        set DEVECO_HVIGOR_CANGJIE_PLUGIN=^<that dir^> 1>&2
  exit /b 1
)

rem The plugin being loadable is not the same as being enabled: when disabled it
rem deletes the cangjie schema silently (terminal only shows 00303038). Set both.
set "DEVECO_CANGJIE_PLUGIN_ENABLED=true"
set "NODE_PATH=%CD%\node_modules"

rem The SDK's cjpm.exe hard-depends on libcangjie-runtime.dll (under runtime/lib):
rem without it hvigor exits 0xC0000139 within milliseconds. First match wins; with
rem several SDK versions set CANGJIE_SDK explicitly.
if not defined CANGJIE_SDK (
  for /d %%D in ("%USERPROFILE%\.cangjie-sdk\*\cangjie") do (
    if not defined CANGJIE_SDK set "CANGJIE_SDK=%%~D"
  )
)
if defined CANGJIE_SDK (
  set "CJS_RT=%CANGJIE_SDK%\build-tools\runtime\lib\windows_x86_64_cjnative"
  set "CJS_BIN=%CANGJIE_SDK%\build-tools\bin"
  set "CJS_TOOLS=%CANGJIE_SDK%\build-tools\tools\bin"
  if exist "%CJS_RT%" (
    set "PATH=%CJS_RT%;%PATH%"
  ) else (
    echo [ohos] Cangjie runtime dir not found: %CJS_RT% - cjpm will exit 0xC0000139 1>&2
    echo        set CANGJIE_SDK=^<.cangjie-sdk\<version>\cangjie^> 1>&2
  )
  if exist "%CJS_BIN%" (
    set "PATH=%CJS_BIN%;%CJS_TOOLS%;%PATH%"
    set "CANGJIE_HOME=%CANGJIE_SDK%\build-tools"
    echo [ohos] cjc = %CJS_BIN%\cjc.exe
    echo [ohos] CANGJIE_HOME = %CANGJIE_HOME%
  )
)

rem entry/cjpm.toml references stdx via the relative path "../stdx" = a junction on
rem the project root. hvigor only substitutes its own template vars, any other
rem ${...} expands to an empty string which kills the whole path-option line
rem (reported as "not added as a dependency").
if not exist "stdx" (
  if not exist "%CANGJIE_STDX_OHOS%" (
    echo [ohos] CANGJIE_STDX_OHOS points to a non-existent dir: %CANGJIE_STDX_OHOS% 1>&2
    exit /b 1
  )
  mklink /J "stdx" "%CANGJIE_STDX_OHOS%" >nul
  echo [ohos] stdx junction created: stdx -^> %CANGJIE_STDX_OHOS%
)

rem Stale artifacts: hvigor's CompileCangjie and framework-side cjpm each keep
rem their own incremental cache; clearing only one feeds back an old .so.
if "%DO_CLEAN%"=="1" (
  echo [ohos] cleaning entry/build (--clean)
  if exist "entry\build" rmdir /s /q "entry\build"
)

rem Assets sync: the project root assets/ dir is the single source of truth
rem (RFC-002 section 7). Pages and capability manifests are real rawfile files
rem inside the hap - building without this sync installs STALE pages.
if exist "..\..\cj-tauri.toml" if exist "..\..\assets" (
  set "RAWFILE=entry\src\main\resources\rawfile"
  if exist "%RAWFILE%\ui" rmdir /s /q "%RAWFILE%\ui"
  if exist "%RAWFILE%\capabilities" rmdir /s /q "%RAWFILE%\capabilities"
  xcopy /e /i /y /q "..\..\assets\ui" "%RAWFILE%\ui\" >nul
  xcopy /e /i /y /q "..\..\assets\capabilities" "%RAWFILE%\capabilities\" >nul
  echo [ohos] assets synced from project root to rawfile (ui/ + capabilities/)
)

rem --no-daemon is mandatory: the resident daemon's CompileCangjie uses the env
rem captured at daemon start; PATH/CANGJIE_HOME exported here never reach it.
call "%NODE_EXE%" "%HVIGOR_JS%" --no-daemon --mode module -p product=default -p module=entry@default assembleHap
if errorlevel 1 (
  echo [ohos] hvigor assembleHap failed (see output above) 1>&2
  exit /b 1
)

set "HAP_DIR=entry\build\default\outputs\default"
set "HAP="
for /f "delims=" %%F in ('dir /b /o-d "%HAP_DIR%\*.hap" 2^>nul') do (
  if not defined HAP set "HAP=%HAP_DIR%\%%~F"
)
if not defined HAP (
  echo [ohos] build finished but no hap artifact; check the hvigor output above 1>&2
  exit /b 1
)
for %%A in ("%HAP%") do set "HAP_SIZE=%%~zA"
echo [ohos] HAP = %HAP% (%HAP_SIZE% bytes)
echo "%HAP%" | findstr /i "unsigned" >nul && (
  echo [ohos] unsigned hap: cannot be installed. Configure auto-signing in DevEco and rebuild. 1>&2
  set "DO_INSTALL=0"
)

if "%DO_INSTALL%"=="1" (
  set "HDC=%DEVECO_SDK_HOME%\default\openharmony\toolchains\hdc.exe"
  if not exist "%HDC%" (
    echo [ohos] hdc not found: %HDC% (--install needs it; or put your own hdc on PATH) 1>&2
    exit /b 1
  )
  echo [ohos] connected devices:
  call "%HDC%" list targets
  echo [ohos] installing %HAP%
  call "%HDC%" install -r "%HAP%"
  if errorlevel 1 (
    echo [ohos] hdc install failed 1>&2
    exit /b 1
  )
  echo [ohos] starting EntryAbility
  rem -a must be the ability name in module.json5 (EntryAbility), not the Cangjie class name.
  call "%HDC%" shell aa start -a EntryAbility -b {{BUNDLE_NAME}}
)

endlocal
exit /b 0
