# สำรองข้อมูล HIP Time (SQL Server) เป็นไฟล์ CSV บีบอัด .zip — ไม่แก้ข้อมูลใด ๆ (อ่านอย่างเดียว)
#   รัน:  powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SongkonSync\backup-hip.ps1"
#   สำรองไปอีกที่ด้วย (เช่นแฟลชไดรฟ์ D:):  ... backup-hip.ps1 -CopyTo "D:\HIP-backup"
# เก็บไฟล์ล่าสุด 8 ชุด ที่ <โฟลเดอร์นี้>\backups
# ไฟล์สำรองมีชื่อและข้อมูลส่วนบุคคลของเจ้าหน้าที่ — เก็บในที่ปลอดภัย ห้ามส่งต่อ/อัปโหลดที่สาธารณะ
# ตั้งให้รันทุกสัปดาห์ (วันอาทิตย์ 20:00) ครั้งเดียว:
#   schtasks /Create /TN SongkonHipBackup /SC WEEKLY /D SUN /ST 20:00 /F /TR "powershell -NoProfile -ExecutionPolicy Bypass -File \"%LOCALAPPDATA%\SongkonSync\backup-hip.ps1\""

param([string]$CopyTo = '', [int]$Keep = 8)
$ErrorActionPreference = 'Stop'
$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dir   = Join-Path $Here 'backups'
$parts = (Get-Content 'C:\Program Files (x86)\HIP TIME\schcare.ini' -Raw).Trim().Split('$')
$cs    = "Server=$($parts[0]);Database=$($parts[1]);User ID=$($parts[2]);Password=$($parts[3]);ApplicationIntent=ReadOnly;Connect Timeout=15"
$Tables = @('Student', 'StudentMachine', 'StudentShift', 'StudentTime', 'Transcantime', 'AutoLoadTime')

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$tmp   = Join-Path $Dir "hip-$stamp"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$cn = New-Object System.Data.SqlClient.SqlConnection $cs
$cn.Open()
try {
  $log = @()
  foreach ($t in $Tables) {
    try {
      $cmd = $cn.CreateCommand(); $cmd.CommandText = "SELECT * FROM [$t]"
      $dt = New-Object System.Data.DataTable; $dt.Load($cmd.ExecuteReader())
      $dt | Export-Csv (Join-Path $tmp "$t.csv") -NoTypeInformation -Encoding UTF8
      $log += "$t : $($dt.Rows.Count) แถว"
    } catch { $log += "$t : ข้าม ($($_.Exception.Message))" }
  }
  $log | Set-Content (Join-Path $tmp 'สรุป.txt') -Encoding UTF8
} finally { $cn.Close() }

$zip = Join-Path $Dir "hip-$stamp.zip"
Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zip -Force
Remove-Item $tmp -Recurse -Force

# เก็บแค่ชุดล่าสุด
Get-ChildItem $Dir -Filter 'hip-*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep | Remove-Item -Force

if ($CopyTo) {
  New-Item -ItemType Directory -Path $CopyTo -Force | Out-Null
  Copy-Item $zip $CopyTo -Force
  Get-ChildItem $CopyTo -Filter 'hip-*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep | Remove-Item -Force
}

Write-Host "สำรองเสร็จ: $zip ($([math]::Round((Get-Item $zip).Length/1KB)) KB)" -ForegroundColor Green
$log | ForEach-Object { Write-Host "  $_" }
if ($CopyTo) { Write-Host "คัดลอกไปที่ $CopyTo แล้ว" -ForegroundColor Cyan }
