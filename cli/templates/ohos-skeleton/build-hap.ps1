# {{PROJECT_NAME}} - HarmonyOS PC (2in1) HAP build entry for PowerShell.
#
# PowerShell twin of build-hap.sh (same steps, native Windows paths; no Git Bash needed).
# Usage:
#   powershell -ExecutionPolicy Bypass -File build-hap.ps1              build the hap
#   powershell -ExecutionPolicy Bypass -File build-hap.ps1 -Install     build + hdc install + aa start
#   powershell -ExecutionPolicy Bypass -File build-hap.ps1 -Clean       remove entry/build first
#
# Prerequisites (each checked below with an actionable message):
#   1. DevEco Studio 6.1+ (ships hvigor + node). Probed at common locations;
#      set DEVECO_WIN=<install root, Windows form> to override.
#   2. Ohos stdx: set CANGJIE_STDX_OHOS=<stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx
#      - without it cjpm reports a misleading "missing dependency" error.
#   3. Signing: the template ships no certificate. In DevEco: File -> Project Structure ->
#      Signing Configs -> "Automatically generate signature" (requires a Huawei account).
#      Unsigned builds still produce *-unsigned.hap but cannot be installed (9568289 etc.).

$ErrorActionPreference = "Stop"
$RootDir = $PSScriptRoot
$DoInstall = $false
$DoClean = $false
foreach ($a in $args) {
    switch -- ($a.ToLower()) {
        "-install" { $DoInstall = $true }
        "--install" { $DoInstall = $true }
        "-clean" { $DoClean = $true }
        "--clean" { $DoClean = $true }
        "-h" { Get-Content $PSCommandPath | Select-Object -First 22; exit 0 }
        "--help" { Get-Content $PSCommandPath | Select-Object -First 22; exit 0 }
        default { Write-Error "[ohos] unknown arg: $a (supported: -Install / -Clean / -Help)"; exit 2 }
    }
}

function Write-Ohos([string]$msg) { Write-Host "[ohos] $msg" }
function Write-OhosErr([string]$msg) { Write-Host "[ohos] $msg" -ForegroundColor Red }

# DevEco install root: DEVECO_WIN first, then common locations.
function Find-Deveco {
    if ($env:DEVECO_WIN) { return $env:DEVECO_WIN }
    foreach ($cand in @(
        "D:\oh\DevEcoStudio",
        "C:\Program Files\Huawei\DevEco Studio",
        "D:\Program Files\Huawei\DevEco Studio",
        "C:\Program Files (x86)\Huawei\DevEco Studio")) {
        if (Test-Path (Join-Path $cand "tools\hvigor")) { return $cand }
    }
    return $null
}

# A preset env value pointing at a non-existent dir makes hvigor fail with
# "Invalid value of 'DEVECO_SDK_HOME'" - fall back and say what was ignored.
function Pick-DevecoPath([string]$cand, [string]$fallback) {
    if ($cand -and (Test-Path $cand)) { return $cand }
    if ($cand) { Write-OhosErr "ignoring invalid path: $cand, using $fallback" }
    return $fallback
}

$deveco = Find-Deveco
if (-not $deveco) {
    Write-OhosErr "DevEco Studio not found. Set DEVECO_WIN=<install root, Windows form>"
    Write-Host "       e.g. `$env:DEVECO_WIN = 'D:\Program Files\Huawei\DevEco Studio'"
    exit 1
}
$env:DEVECO_WIN = $deveco
$env:DEVECO_SDK_HOME = Pick-DevecoPath $env:DEVECO_SDK_HOME (Join-Path $deveco "sdk")
$env:NODE_HOME = Pick-DevecoPath $env:NODE_HOME (Join-Path $deveco "tools\node")

if (-not $env:CANGJIE_STDX_OHOS) {
    Write-OhosErr "set CANGJIE_STDX_OHOS=<ohos stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx first"
    exit 1
}

$nodeExe = Join-Path $deveco "tools\node\node.exe"
$hvigorJs = Join-Path $deveco "tools\hvigor\bin\hvigorw.js"
if (-not (Test-Path $hvigorJs)) {
    Write-OhosErr "$hvigorJs not found - is DEVECO_WIN correct?"
    exit 1
}

# hvigorw locates the Cangjie build plugin itself and creates the node_modules junctions;
# headless runs must hand it the path or the failure surfaces as
# "property name must be valid: cangjieOptions" (looks like a project config error,
# actually the plugin was not loaded).
if (-not $env:DEVECO_HVIGOR_CANGJIE_PLUGIN) {
    $appdata = if ($env:APPDATA) { $env:APPDATA } else { "$env:USERPROFILE\AppData\Roaming" }
    $cjb = Get-ChildItem -Path (Join-Path $appdata "Huawei") -Filter "DevEcoStudio*" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem (Join-Path $_.FullName "plugins") -Filter "devecostudio-cangjie-plugin-*" -Directory -ErrorAction SilentlyContinue } |
        ForEach-Object { Get-ChildItem (Join-Path $_.FullName "lib\hvigor") -Filter "cangjie-build-support" -Directory -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if ($cjb) {
        $env:DEVECO_HVIGOR_CANGJIE_PLUGIN = $cjb.FullName
    } else {
        Write-OhosErr "Cangjie build plugin not found under <APPDATA>\Huawei\DevEcoStudio*\plugins\devecostudio-cangjie-plugin-*\lib\hvigor\cangjie-build-support"
        Write-Host "       set DEVECO_HVIGOR_CANGJIE_PLUGIN=<that dir>"
        exit 1
    }
}
# The plugin being loadable is not the same as being enabled: when disabled it deletes the
# cangjie schema silently (terminal only shows 00303038). Set both switches.
$env:DEVECO_CANGJIE_PLUGIN_ENABLED = "true"
$env:NODE_PATH = Join-Path (Get-Location) "node_modules"

# The SDK's cjpm.exe hard-depends on libcangjie-runtime.dll (under runtime/lib):
# without it hvigor exits 0xC0000139 within milliseconds.
if (-not $env:CANGJIE_SDK) {
    $cand = Get-ChildItem "$env:USERPROFILE\.cangjie-sdk" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "cangjie" } | Where-Object { Test-Path $_ } |
        Sort-Object { [version]($_.Split('\') | Where-Object { $_ -match '^\d' } | Select-Object -First 1) } -ErrorAction SilentlyContinue |
        Select-Object -Last 1
    if ($cand) { $env:CANGJIE_SDK = $cand }
}
$cjsdkRt = Join-Path $env:CANGJIE_SDK "build-tools\runtime\lib\windows_x86_64_cjnative"
$cjsdkBin = Join-Path $env:CANGJIE_SDK "build-tools\bin"
$cjsdkToolsBin = Join-Path $env:CANGJIE_SDK "build-tools\tools\bin"
if (Test-Path $cjsdkRt) {
    $env:PATH = "$cjsdkRt;$env:PATH"
} else {
    Write-OhosErr "Cangjie runtime dir not found: $cjsdkRt - cjpm will exit 0xC0000139"
    Write-Host "       set CANGJIE_SDK=<.cangjie-sdk/<version>/cangjie>"
}
# cjc and opt must come from the SAME SDK build: cjc looks up opt via CANGJIE_HOME;
# a mismatch shows up as "EnumReflection format: operand numbers error!".
if (Test-Path $cjsdkBin) {
    $env:PATH = "$cjsdkBin;$cjsdkToolsBin;$env:PATH"
    $env:CANGJIE_HOME = Join-Path $env:CANGJIE_SDK "build-tools"
    $cjcCmd = Get-Command cjc -ErrorAction SilentlyContinue
    Write-Ohos "cjc = $($cjcCmd.Source)"
    Write-Ohos "CANGJIE_HOME = $env:CANGJIE_HOME"
}

# entry/cjpm.toml references stdx via the relative path "../stdx" = a junction on the project
# root: hvigor only substitutes its own template vars, any other ${...} expands to an empty
# string which kills the whole path-option line (reported as "not added as a dependency").
$stdxLink = Join-Path $RootDir "stdx"
if (-not (Test-Path $stdxLink)) {
    if (-not (Test-Path $env:CANGJIE_STDX_OHOS)) {
        Write-OhosErr "CANGJIE_STDX_OHOS points to a non-existent dir: $env:CANGJIE_STDX_OHOS"
        exit 1
    }
    New-Item -ItemType Junction -Path $stdxLink -Value $env:CANGJIE_STDX_OHOS | Out-Null
    Write-Ohos "stdx junction created: $stdxLink -> $env:CANGJIE_STDX_OHOS"
}

# Stale artifacts: hvigor's CompileCangjie and framework-side cjpm each keep their own
# incremental cache; clearing only one feeds back an old .so (judge by artifact size,
# not by "build success").
if ($DoClean) {
    Write-Ohos "cleaning entry/build (--clean)"
    if (Test-Path (Join-Path $RootDir "entry\build")) { Remove-Item -Recurse -Force (Join-Path $RootDir "entry\build") }
}

# Assets sync: the project root assets/ dir is the single source of truth (RFC-002 section 7);
# pages and capability manifests are real rawfile files inside the hap - building without
# this sync installs STALE pages (self-checks still run, changes silently lost).
$appRoot = Split-Path (Split-Path $RootDir)
if ((Test-Path (Join-Path $appRoot "cj-tauri.toml")) -and (Test-Path (Join-Path $appRoot "assets"))) {
    $rawfile = Join-Path $RootDir "entry\src\main\resources\rawfile"
    New-Item -ItemType Directory -Force -Path (Join-Path $rawfile "ui") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $rawfile "capabilities") | Out-Null
    # remove-then-copy: Copy-Item -Recurse into an existing dir would nest ui/ui/ and pages go stale
    Remove-Item -Recurse -Force (Join-Path $rawfile "ui"), (Join-Path $rawfile "capabilities") -ErrorAction SilentlyContinue
    Copy-Item -Recurse -Force (Join-Path $appRoot "assets\ui") (Join-Path $rawfile "ui")
    Copy-Item -Recurse -Force (Join-Path $appRoot "assets\capabilities") (Join-Path $rawfile "capabilities")
    Write-Ohos "assets synced from project root to rawfile (ui/ + capabilities/)"
}

# --no-daemon is mandatory: the resident daemon's CompileCangjie uses the env captured at
# daemon start; PATH/CANGJIE_HOME exported here never reach it (symptom: manual cjpm works,
# hvigor run crashes in opt).
$buildlogDir = Join-Path $RootDir ".buildlog"
New-Item -ItemType Directory -Force -Path $buildlogDir | Out-Null
& $nodeExe $hvigorJs --no-daemon --mode module -p product=default -p module=entry@default assembleHap 2>&1 |
    Tee-Object -FilePath (Join-Path $buildlogDir "last-build.log")
if ($LASTEXITCODE -ne 0) {
    Write-OhosErr "hvigor assembleHap failed (exit=$LASTEXITCODE)"
    exit $LASTEXITCODE
}

$hap = Get-ChildItem (Join-Path $RootDir "entry\build\default\outputs\default") -Filter "*.hap" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $hap) {
    Write-OhosErr "build finished but no hap artifact; check .buildlog/last-build.log"
    exit 1
}
Write-Ohos "HAP = $($hap.FullName) ($($hap.Length) bytes)"
if ($hap.Name -like "*unsigned*") {
    Write-OhosErr "unsigned hap: cannot be installed. Configure auto-signing in DevEco and rebuild."
    $DoInstall = $false
}

if ($DoInstall) {
    $hdc = Join-Path $deveco "sdk\default\openharmony\toolchains\hdc.exe"
    if (-not (Test-Path $hdc)) {
        Write-OhosErr "hdc not found: $hdc (-Install needs it; or put your own hdc on PATH)"
        exit 1
    }
    Write-Ohos "connected devices:"
    & $hdc list targets
    Write-Ohos "installing $($hap.Name)"
    & $hdc install -r $hap.FullName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Ohos "starting EntryAbility"
    # -a must be the ability name in module.json5 (EntryAbility), not the Cangjie class name.
    & $hdc shell aa start -a EntryAbility -b {{BUNDLE_NAME}}
}
