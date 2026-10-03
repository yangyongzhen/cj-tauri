# Answer the native message boxes the multi-window probe opens on purpose.
#
# Why: phase 2 of examples/multi-window opens one message box from EACH window at the same
# time and only continues once both are answered. The concurrency evidence is the probe's
# "inflight=2" line, which only appears if the two boxes really are open together -- so this
# script waits a warm-up period after the FIRST box shows up before answering anything,
# giving the second window time to open its own box.
#
# Safety: it only ever posts to a window that (a) has class "#32770" (the Win32 dialog class)
# AND (b) belongs to the target process; nothing else is touched, and no keys are injected
# (PostMessage of WM_COMMAND/IDOK -- the same thing as clicking the default button).
#
# Diagnostics: every state CHANGE is logged as "POLL pids=.. dialogs=..", so a run that
# answers nothing is traceable to its cause (no process / process but no dialog / error)
# instead of being a silent no-op. Failures inside the poll are logged as "ERR ...".
#
# Keep this file pure ASCII: PowerShell 5.1 reads .ps1 in the ANSI codepage.
param(
    [int]$Seconds = 60,
    [int]$WarmupSeconds = 4,
    [string]$ProcName = 'main',
    [string]$LogPath = ''
)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class CjDlg {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);

    // Returns "hwnd|pid|title" for every #32770 window owned by one of the given pids.
    // pids is int[] on purpose: PowerShell refused to bind a [uint[]] cast to this method
    // ("cannot convert ... [uint]"), and uint adds nothing here.
    public static List<string> Find(int[] pids) {
        var found = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            var cls = new StringBuilder(256);
            GetClassName(h, cls, 256);
            if (cls.ToString() != "#32770") return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            for (int i = 0; i < pids.Length; i++) {
                if ((uint)pids[i] == pid) {
                    var t = new StringBuilder(256);
                    GetWindowText(h, t, 256);
                    found.Add(h.ToInt64().ToString() + "|" + pid + "|" + t.ToString());
                    break;
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static void PostOk(IntPtr h) { PostMessage(h, 0x0111, (IntPtr)1, IntPtr.Zero); }
}
'@

function Say([string]$line) {
    Write-Output $line
    # UTF8 (not ASCII): the diagnostic lines carry PowerShell's own error text, which is
    # localized Chinese on this machine -- ASCII would turn it into "?????".
    if ($LogPath -ne '') { Add-Content -Path $LogPath -Value $line -Encoding UTF8 }
}

$deadline = (Get-Date).AddSeconds($Seconds)
$answered = @{}
$firstSeen = $null
$count = 0
$lastState = ''

while ((Get-Date) -lt $deadline) {
    $state = ''
    try {
        $pids = @(Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        $state = 'pids=' + $pids.Count
        if ($pids.Count -gt 0) {
            $dlgs = [CjDlg]::Find([int[]]$pids)
            $open = 0
            foreach ($d in $dlgs) {
                $parts = $d.Split('|')
                if (-not $answered.ContainsKey($parts[0])) { $open++ }
            }
            $state = $state + ' dialogs=' + $open
            if ($open -gt 0) {
                if ($firstSeen -eq $null) {
                    $firstSeen = Get-Date
                    Say ('FIRST batch: ' + $open + ' dialog(s) open, warming up ' + $WarmupSeconds + 's')
                }
                if (((Get-Date) - $firstSeen).TotalSeconds -ge $WarmupSeconds) {
                    foreach ($d in $dlgs) {
                        $parts = $d.Split('|')
                        if ($answered.ContainsKey($parts[0])) { continue }
                        $answered[$parts[0]] = $true
                        $count++
                        Say ('DIALOG hwnd=' + $parts[0] + ' pid=' + $parts[1] + ' title=' + $parts[2] + ' -> WM_COMMAND/IDOK')
                        [CjDlg]::PostOk([IntPtr][long]$parts[0])
                    }
                    # reset so a later box gets its own warm-up
                    $firstSeen = $null
                }
            }
        }
    }
    catch {
        $state = 'ERR ' + $_.Exception.Message
    }
    if ($state -ne $lastState) {
        Say ('POLL ' + $state)
        $lastState = $state
    }
    Start-Sleep -Milliseconds 250
}
Say ('DISMISSER done, answered=' + $count)
