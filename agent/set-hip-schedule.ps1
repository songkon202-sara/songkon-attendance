# ตั้งเวลาให้โปรแกรม HIP Time ดึงข้อมูลจากเครื่องสแกนทุก 15 นาที (07:30–17:30)
# ก่อนรัน: ในโปรแกรม HIP Time > ข้อมูลหลัก > "ตั้งเวลาดึงข้อมูลจากเครื่องบันทึกเวลา"
#          กด F2 เพิ่มเวลา 07:30 ด้วยมือ 1 รายการก่อน (สคริปต์จะใช้รูปแบบเวลาเดียวกันกับรายการนั้น)
# วิธีรัน:  powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SongkonSync\set-hip-schedule.ps1"
# หลังรัน: ปิดแล้วเปิดโปรแกรม HIP Time ใหม่ 1 ครั้ง
# สคริปต์จะสำรองรายการเวลาเดิมไว้ที่ hip-schedule-backup.txt ก่อนเพิ่ม และไม่ลบรายการที่มีอยู่

$ErrorActionPreference = 'Stop'
$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$parts = (Get-Content 'C:\Program Files (x86)\HIP TIME\schcare.ini' -Raw).Trim().Split('$')
$cs    = "Server=$($parts[0]);Database=$($parts[1]);User ID=$($parts[2]);Password=$($parts[3]);Connect Timeout=15"

$cn = New-Object System.Data.SqlClient.SqlConnection $cs
$cn.Open()
try {
  $cmd = $cn.CreateCommand()
  $cmd.CommandText = "SELECT id, loadtime FROM dbo.AutoLoadTime ORDER BY id"
  $t = New-Object System.Data.DataTable; $t.Load($cmd.ExecuteReader())

  $existing = @($t.Rows | ForEach-Object { ([string]$_.loadtime).Trim() })
  ($existing -join "`r`n") | Set-Content (Join-Path $Here 'hip-schedule-backup.txt') -Encoding UTF8

  if ($existing.Count -eq 0) {
    Write-Host "ยังไม่มีเวลาในโปรแกรม HIP Time" -ForegroundColor Yellow
    Write-Host "กรุณากด F2 เพิ่มเวลา 07:30 ด้วยมือ 1 รายการก่อน แล้วรันสคริปต์นี้อีกครั้ง"
    exit 1
  }

  # อ่านรูปแบบจากรายการที่มีอยู่ เช่น "07:30", "7:30", "07:30:00"
  $sample = $existing[0]
  if ($sample -notmatch '^(\d{1,2}):(\d{2})(:\d{2})?$') {
    Write-Host "รูปแบบเวลาที่มีอยู่ ('$sample') ไม่คุ้นเคย สคริปต์จะไม่แก้อะไร กรุณาส่งข้อความนี้ให้ผู้พัฒนา" -ForegroundColor Red
    exit 1
  }
  $padHour = $Matches[1].Length -eq 2
  $withSec = [bool]$Matches[3]
  function Fmt([int]$h, [int]$m) {
    $hh = if ($padHour) { '{0:D2}' -f $h } else { "$h" }
    $s = "${hh}:" + ('{0:D2}' -f $m)
    if ($withSec) { $s += ':00' }
    $s
  }
  $norm = { param($x) if ($x -match '^(\d{1,2}):(\d{2})') { [int]$Matches[1] * 60 + [int]$Matches[2] } else { -1 } }
  $have = @{}; foreach ($x in $existing) { $have[(& $norm $x)] = $true }

  $added = @()
  for ($min = 7*60+30; $min -le 17*60+30; $min += 15) {
    if ($have.ContainsKey($min)) { continue }
    $val = Fmt ([math]::Floor($min / 60)) ($min % 60)
    $ins = $cn.CreateCommand()
    $ins.CommandText = "INSERT INTO dbo.AutoLoadTime (loadtime) VALUES (@t)"
    [void]$ins.Parameters.AddWithValue('@t', $val)
    [void]$ins.ExecuteNonQuery()
    $added += $val
  }
  Write-Host ("เพิ่มเวลา {0} รายการ (รูปแบบ '{1}'): {2}" -f $added.Count, $sample, ($added -join ', ')) -ForegroundColor Green
  Write-Host "สำรองรายการเดิมไว้ที่ $Here\hip-schedule-backup.txt"
  Write-Host "ปิดแล้วเปิดโปรแกรม HIP Time ใหม่ 1 ครั้ง แล้วเข้าหน้าตั้งเวลาเพื่อตรวจดู" -ForegroundColor Cyan
} finally { $cn.Close() }
