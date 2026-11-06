# ตรวจสถานะการส่งข้อมูล (อ่านอย่างเดียว) — บอกว่าติดที่ HIP Time หรือที่ตัวส่งข้อมูล
# วิธีรัน: powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SongkonSync\check-status.ps1"
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Security
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $Here 'status.txt'
$r = @()
$r += "== เวลาเครื่อง: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# 1) Task Scheduler
try {
  $t = Get-ScheduledTask -TaskName SongkonHipSync -ErrorAction Stop
  $i = $t | Get-ScheduledTaskInfo
  $r += "== Task: $($t.State) · รันล่าสุด $($i.LastRunTime) · ผล $($i.LastTaskResult) · รอบถัดไป $($i.NextRunTime)"
} catch { $r += "== Task: ไม่พบ SongkonHipSync ($($_.Exception.Message))" }

# 2) ข้อมูลล่าสุดในฐานข้อมูล HIP Time
try {
  $cfg = Get-Content (Join-Path $Here 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $pwd = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect(
           [Convert]::FromBase64String($cfg.sqlPasswordProtected), $null, 'CurrentUser'))
  $cn = New-Object System.Data.SqlClient.SqlConnection "Server=$($cfg.sqlServer);Database=$($cfg.sqlDatabase);User ID=$($cfg.sqlUser);Password=$pwd;Connect Timeout=10"
  $cn.Open()
  $c = $cn.CreateCommand()
  $c.CommandText = "SELECT TOP 5 id, enrollnumber, verifymodestr, datetimescan, adddate FROM dbo.Transcantime ORDER BY id DESC"
  $tb = New-Object System.Data.DataTable; $tb.Load($c.ExecuteReader()); $cn.Close()
  $r += "== HIP Time: 5 รายการล่าสุดในฐานข้อมูล (adddate = เวลาที่ HIP ดึงจากเครื่องสแกน)"
  $r += ($tb | Format-Table -AutoSize | Out-String)
} catch { $r += "== HIP Time: อ่านฐานข้อมูลไม่ได้ ($($_.Exception.Message))" }

# 3) ล็อกตัวส่งข้อมูล
$log = Join-Path $Here 'sync.log'
if (Test-Path $log) { $r += "== sync.log 5 บรรทัดล่าสุด"; $r += (Get-Content $log -Tail 5) } else { $r += "== ไม่มี sync.log" }

$r | Set-Content $out -Encoding UTF8
$r | ForEach-Object { Write-Host $_ }
Write-Host "`nบันทึกผลที่ $out แล้ว" -ForegroundColor Green
