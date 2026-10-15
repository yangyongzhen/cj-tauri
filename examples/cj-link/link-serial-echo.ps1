# cj-link probe far end on the serial side: hold COM2, echo whatever arrives back,
# and record what was actually seen on the wire into a log file. Pure ASCII.
#
# Usage: powershell -File link-serial-echo.ps1 <port> <logfile> <seconds>
param(
  [string]$Port = 'COM2',
  [string]$Log  = 'E:\test\harmonyos\test\cj-tauri\.atomcode\tmp\link-serial.log',
  [int]$Seconds = 60
)
$ErrorActionPreference = 'Stop'
$p = New-Object System.IO.Ports.SerialPort $Port,115200,None,8,One
$p.ReadTimeout = 200
$p.Open()
[System.IO.File]::WriteAllText($Log, ("[serial-peer] opened " + $Port + "`n"))
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
  try { $s = $p.ReadExisting() } catch { $s = '' }
  if ($s.Length -gt 0) {
    [System.IO.File]::AppendAllText($Log, ("[serial-peer] rx " + $s.Length + " bytes: " + $s + "`n"))
    $p.Write($s)   # echo straight back
  }
  Start-Sleep -Milliseconds 40
}
$p.Close()
[System.IO.File]::AppendAllText($Log, "[serial-peer] done`n")
