# Serial peer for the probe round (examples/serial-assistant, Windows):
# opens the OTHER end of the virtual pair, sends an initial PONG frame,
# then echoes PONG:<rx> for every received chunk and appends rx bytes to a file
# (the file is the external evidence that bytes really crossed the wire).
param(
    [string]$Port = "COM2",
    [string]$RxFile = "peer-rx.log",
    [int]$IdleExitSec = 15
)
$ErrorActionPreference = "Stop"
# UTF-8 (no BOM): cmd-side findstr can't read PowerShell's default Unicode output.
# Note: $OutputEncoding/[Console] only cover OUR lines; the script-terminating error
# report is emitted by the OUTER host AFTER our settings are gone, and it stays
# GBK there -- so keep this script ASCII-only and never let an error line be a needle.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, None, 8, One
$sp.ReadTimeout = 200
try {
    $sp.Open()
} catch {
    Write-Output ("[peer] FAILED to open " + $Port + ": " + $_.Exception.InnerException.Message)
    exit 1
}
$sp.Write("PONG:cj-tauri-ping")
Write-Output "[peer] opened $Port, initial PONG sent"
$deadline = (Get-Date).AddSeconds($IdleExitSec)
try {
    while ((Get-Date) -lt $deadline) {
        try {
            $n = $sp.BytesToRead
            if ($n -gt 0) {
                $buf = New-Object byte[] $n
                $sp.Read($buf, 0, $n) | Out-Null
                $text = [System.Text.Encoding]::ASCII.GetString($buf)
                Add-Content -Path $RxFile -Value $text -NoNewline
                $sp.Write("PONG:" + $text)
                Write-Output ("[peer] rx {0} bytes: {1}" -f $n, $text)
                $deadline = (Get-Date).AddSeconds($IdleExitSec)
            } else {
                Start-Sleep -Milliseconds 50
            }
        } catch [TimeoutException] { }
    }
} finally {
    $sp.Close()
    Write-Output "[peer] closed"
}
