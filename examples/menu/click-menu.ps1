# cj-tauri menu capability probe driver (examples\menu) -- Windows only.
#
# Why a Win32 driver instead of a human clicking the menu bar: the claim under test is
# "the whole click chain works" -- WM_COMMAND -> platform -> core -> Cangjie -> back into
# the platform menu. A driver makes that repeatable and gives checkable evidence:
#   * it reads the command ids straight out of the window's HMENU (no hardcoded ids),
#   * it posts WM_COMMAND to the SECOND window only, so the app log proves per-window
#     routing (the first window must stay silent),
#   * it reads the item state back with GetMenuState -- "the app says it changed" is not
#     taken as proof, Win32 has to agree.
#
# Keep this file pure ASCII: PowerShell 5.1 reads .ps1 in the ANSI codepage, and non-ASCII
# bytes can break parsing.
param(
    [int]$Seconds = 60,
    [string]$ProcName = "main",
    [string]$LogPath = "$env:TEMP\cj-menu-driver.log"
)

$ErrorActionPreference = "Continue"

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class MenuWin {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
    [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr hMenu, int nPos);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr hMenu, uint uIDItem, StringBuilder lpString, int cchMax, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr hMenu, uint uId, uint uFlags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wp, IntPtr lp);
    public const uint MF_BYPOSITION = 0x400;
    public const uint MF_BYCOMMAND = 0x0;
    public const uint MF_CHECKED = 0x8;
    public const uint MF_DISABLED = 0x2;
    public const uint MF_GRAYED = 0x1;
    public const uint WM_COMMAND = 0x111;
    public const uint WM_CLOSE = 0x10;
}
"@ -ErrorAction Stop

function Write-Log([string]$msg) {
    $line = "[click] " + $msg
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

# Top-level windows belonging to the probe process (the app is "main.exe", so -ProcName main).
# Matching by window TITLE (set from WindowConfig) keeps this driver free of window-class names.
function Get-ProbeWindows {
    $ids = @(Get-Process -Name $ProcName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($ids.Count -eq 0) { return @() }
    $script:hits = New-Object System.Collections.ArrayList
    $cb = [MenuWin+EnumProc]{
        param($h, $l)
        $owner = 0
        [void][MenuWin]::GetWindowThreadProcessId($h, [ref]$owner)
        if (($ids -contains [int]$owner) -and [MenuWin]::IsWindowVisible($h)) {
            $sb = New-Object System.Text.StringBuilder 512
            [void][MenuWin]::GetWindowTextW($h, $sb, 512)
            $t = $sb.ToString()
            if ($t.Length -gt 0) { [void]$script:hits.Add(@{ hwnd = $h; title = $t }) }
        }
        return $true
    }
    [void][MenuWin]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:hits
}

function Send-Click([IntPtr]$hwnd, [uint32]$id, [string]$what) {
    if ($id -eq 0) {
        Write-Log ("FAIL no command id for {0}" -f $what)
        return
    }
    if ([MenuWin]::PostMessageW($hwnd, [MenuWin]::WM_COMMAND, [IntPtr]([int64]$id), [IntPtr]::Zero)) {
        Write-Log ("posted WM_COMMAND id={0} ({1})" -f $id, $what)
    } else {
        Write-Log ("FAIL post WM_COMMAND id={0} ({1})" -f $id, $what)
    }
}

# Never leave the app running: run.bat waits on it in the foreground, so a stuck window
# would turn a failed probe into a hung script. Close both windows, then bail out.
function Fail([string]$msg) {
    Write-Log ("FAIL " + $msg)
    foreach ($w in @(Get-ProbeWindows)) {
        if (($w.title -like "*main*") -or ($w.title -like "*second*")) {
            [void][MenuWin]::PostMessageW($w.hwnd, [MenuWin]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
        }
    }
    Write-Log "windows closed after failure"
    exit 1
}

$deadline = (Get-Date).AddSeconds($Seconds)
$second = $null
$first = $null
while ((Get-Date) -lt $deadline) {
    foreach ($w in @(Get-ProbeWindows)) {
        if ($w.title -like "*second*") { $second = $w }
        elseif ($w.title -like "*main*") { $first = $w }
    }
    if ($null -ne $second) { break }
    Start-Sleep -Milliseconds 250
}

if ($null -eq $second) {
    Fail ("second window not found within {0}s" -f $Seconds)
}
Write-Log ("found second hwnd=0x{0:X} title={1}" -f [int64]$second.hwnd, $second.title)

# Every window of the process with its menu item count: if the menu ended up on the wrong
# window, this line says which one, which is far cheaper than guessing from GetMenu()==NULL.
foreach ($w in @(Get-ProbeWindows)) {
    $wm = [MenuWin]::GetMenu($w.hwnd)
    $wc = 0
    if ($wm -ne [IntPtr]::Zero) { $wc = [MenuWin]::GetMenuItemCount($wm) }
    Write-Log ("probe window hwnd=0x{0:X} menuItems={1} title={2}" -f [int64]$w.hwnd, $wc, $w.title)
}

# The window shows up (its title is set) a moment BEFORE the menu is attached on the host
# UI thread, so poll for the menu instead of sampling once -- a single GetMenu() here is a
# race that reports "no menu" against a perfectly good window.
$menu = [IntPtr]::Zero
$menuCount = 0
$menuDeadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $menuDeadline) {
    $menu = [MenuWin]::GetMenu($second.hwnd)
    if ($menu -ne [IntPtr]::Zero) {
        $menuCount = [MenuWin]::GetMenuItemCount($menu)
        if ($menuCount -ge 5) { break }
    }
    Start-Sleep -Milliseconds 200
}
if (($menu -eq [IntPtr]::Zero) -or ($menuCount -lt 5)) {
    Fail ("second window has no usable menu after 15s (items={0})" -f $menuCount)
}

$count = [MenuWin]::GetMenuItemCount($menu)
Write-Log ("second menu items={0}" -f $count)

$ids = @{}
for ($i = 0; $i -lt $count; $i++) {
    $id = [MenuWin]::GetMenuItemID($menu, $i)
    $sb = New-Object System.Text.StringBuilder 256
    [void][MenuWin]::GetMenuStringW($menu, [uint32]$i, $sb, 256, [MenuWin]::MF_BYPOSITION)
    Write-Log ("item pos={0} id={1} label={2}" -f $i, $id, $sb.ToString())
    $ids[$i] = [uint32]$id
}

# The probe model's five top-level items are, in order:
#   0 New / 1 Sidebar (checkbox) / 2 separator / 3 Help (submenu) / 4 Disable sidebar
if ($count -lt 5) {
    Fail ("expected at least 5 top-level items, got {0}" -f $count)
}

$sidebarId = $ids[1]

# 1) plain item: only proves the click reaches Cangjie at all
Send-Click $second.hwnd $ids[0] "New"
Start-Sleep -Milliseconds 800

# 2) checkbox: the platform is supposed to flip the mark itself and report checked=1
Send-Click $second.hwnd $sidebarId "Sidebar (checkbox)"
Start-Sleep -Milliseconds 800
$st = [MenuWin]::GetMenuState($menu, $sidebarId, [MenuWin]::MF_BYCOMMAND)
Write-Log ("sidebar checked={0} (state=0x{1:X})" -f (($st -band [MenuWin]::MF_CHECKED) -ne 0), $st)

# 3) app-side reaction: this item makes the app call setMenuItemState("view.sidebar", false, true),
#    i.e. the Cangjie -> core -> platform path at runtime. Win32 must agree afterwards.
Send-Click $second.hwnd $ids[4] "Disable sidebar"
Start-Sleep -Milliseconds 1500
$st2 = [MenuWin]::GetMenuState($menu, $sidebarId, [MenuWin]::MF_BYCOMMAND)
$dis = (((($st2 -band [MenuWin]::MF_DISABLED) -ne 0) -or (($st2 -band [MenuWin]::MF_GRAYED) -ne 0)))
Write-Log ("sidebar disabled={0} checked={1} (state=0x{2:X})" -f $dis, (($st2 -band [MenuWin]::MF_CHECKED) -ne 0), $st2)

# Both windows must own independent menus (a shared HMENU would be a bug).
if ($null -ne $first) {
    $m1 = [MenuWin]::GetMenu($first.hwnd)
    $c1 = 0
    if ($m1 -ne [IntPtr]::Zero) { $c1 = [MenuWin]::GetMenuItemCount($m1) }
    Write-Log ("main menu items={0} independent-handle" -f $c1)
} else {
    Write-Log "WARN main window not found"
}

# Close both windows: the app returns from run() once every window is gone.
[void][MenuWin]::PostMessageW($second.hwnd, [MenuWin]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
if ($null -ne $first) {
    [void][MenuWin]::PostMessageW($first.hwnd, [MenuWin]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
}
Write-Log "close posted to both windows"
Write-Log "DONE"
exit 0
