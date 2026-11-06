# ติดตั้งตัวส่งข้อมูลลงเวลา รพ.สต.สองคอน บนเครื่องที่มีโปรแกรม HIP Time
# วิธีรัน (PowerShell ธรรมดา ไม่ต้อง Run as administrator):
#   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\songkon-sync\install.ps1"
#
# สิ่งที่สคริปต์นี้ทำ:
#   1) คัดลอกไฟล์ไปที่ %LOCALAPPDATA%\SongkonSync
#   2) สร้างบัญชี SQL "songkon_sync" ที่อ่านได้แค่ตาราง Transcantime และ Student
#   3) สร้างรหัสลับของตัวส่งข้อมูล และแสดงคำสั่ง SQL ให้นำไปรันใน Supabase
#   4) ทดสอบส่งข้อมูล 1 รอบ
#   5) ตั้ง Task Scheduler ให้ทำงานทุก 5 นาที
# ไม่แก้ไขข้อมูลในฐานข้อมูล HIP Time และไม่เปลี่ยนการตั้งค่าของโปรแกรม HIP Time

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$SupabaseUrl    = 'https://wrevlndsturjpjdowraj.supabase.co'
$PublishableKey = 'sb_publishable_WhYrTft8NwwIQqpVTZEw2A_QnYcVWA2'
$HipIni         = 'C:\Program Files (x86)\HIP TIME\schcare.ini'
$Target         = Join-Path $env:LOCALAPPDATA 'SongkonSync'
$Src            = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName       = 'SongkonHipSync'

function Step($n, $msg) { Write-Host "`n[$n/5] $msg" -ForegroundColor Cyan }
function Protect($text) {
  [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect(
    [Text.Encoding]::UTF8.GetBytes($text), $null,
    [Security.Cryptography.DataProtectionScope]::CurrentUser))
}
function RandomText($bytes) {
  $b = New-Object byte[] $bytes
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+','A').Replace('/','B')
}

# ---------------------------------------------------------------- 1
Step 1 "คัดลอกไฟล์ไปที่ $Target"
New-Item -ItemType Directory -Force -Path $Target | Out-Null
Copy-Item (Join-Path $Src 'hip-sync.ps1') $Target -Force

# ---------------------------------------------------------------- 2
Step 2 "สร้างบัญชี SQL แบบอ่านอย่างเดียว (songkon_sync)"
$parts  = (Get-Content $HipIni -Raw).Trim().Split('$')   # server$database$user$password$...
$server = $parts[0]; $db = $parts[1]
$adminCs = "Server=$server;Database=master;User ID=$($parts[2]);Password=$($parts[3]);Connect Timeout=15"
$sqlPwd  = 'Sk!' + (RandomText 18)

$cn = New-Object System.Data.SqlClient.SqlConnection $adminCs
$cn.Open()
try {
  function Exec($sql) { $c = $cn.CreateCommand(); $c.CommandText = $sql; [void]$c.ExecuteNonQuery() }
  $pwdSql = $sqlPwd.Replace("'", "''")
  Exec @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'songkon_sync')
  CREATE LOGIN [songkon_sync] WITH PASSWORD = N'$pwdSql', CHECK_POLICY = ON, DEFAULT_DATABASE = [$db];
ELSE
  ALTER LOGIN [songkon_sync] WITH PASSWORD = N'$pwdSql';
"@
  $cn.ChangeDatabase($db)
  Exec @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'songkon_sync')
  CREATE USER [songkon_sync] FOR LOGIN [songkon_sync];
GRANT SELECT ON dbo.Transcantime TO [songkon_sync];
GRANT SELECT ON dbo.Student TO [songkon_sync];
"@
} finally { $cn.Close() }
Write-Host "  สร้างบัญชีเรียบร้อย (สิทธิ์ SELECT เฉพาะ Transcantime, Student)" -ForegroundColor Green

# ---------------------------------------------------------------- 3
Step 3 "สร้างรหัสลับของตัวส่งข้อมูล"
$cfgPath = Join-Path $Target 'config.json'
$secret = RandomText 32
$hash = -join ([Security.Cryptography.SHA256]::Create().ComputeHash(
          [Text.Encoding]::UTF8.GetBytes($secret)) | ForEach-Object { $_.ToString('x2') })

[ordered]@{
  supabaseUrl          = $SupabaseUrl
  publishableKey       = $PublishableKey
  sqlServer            = $server
  sqlDatabase          = $db
  sqlUser              = 'songkon_sync'
  sqlPasswordProtected = (Protect $sqlPwd)
  agentSecretProtected = (Protect $secret)
} | ConvertTo-Json | Set-Content -Path $cfgPath -Encoding UTF8

$sqlForSupabase = "insert into app_secrets (name, secret_hash) values ('hip_agent', '$hash') on conflict (name) do update set secret_hash = excluded.secret_hash;"
try { Set-Clipboard -Value $sqlForSupabase } catch {}
Write-Host ""
Write-Host "  นำคำสั่งด้านล่างไปรันใน Supabase > SQL Editor (คัดลอกไว้ในคลิปบอร์ดแล้ว กด Ctrl+V ได้เลย):" -ForegroundColor Yellow
Write-Host ""
Write-Host "  $sqlForSupabase"
Write-Host ""
Write-Host "  (เป็นค่า hash ของรหัสลับ ตัวรหัสจริงเก็บเข้ารหัสไว้บนเครื่องนี้เท่านั้น)" -ForegroundColor DarkGray
Read-Host "  รันใน Supabase เสร็จแล้ว กด Enter เพื่อทดสอบ"

# ---------------------------------------------------------------- 4
Step 4 "ทดสอบส่งข้อมูล (ครั้งแรกจะส่งข้อมูลย้อนหลังทั้งหมด อาจใช้เวลา 1-2 นาที)"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Target 'hip-sync.ps1') -Show
if ($LASTEXITCODE -ne 0) {
  Write-Host "`n  ทดสอบไม่ผ่าน ดูรายละเอียดใน $Target\sync.log แล้วส่งให้ผู้พัฒนา" -ForegroundColor Red
  Read-Host "  กด Enter เพื่อปิด"; exit 1
}
Write-Host "  ทดสอบผ่าน" -ForegroundColor Green

# ---------------------------------------------------------------- 5
Step 5 "ตั้งให้ทำงานอัตโนมัติทุก 5 นาที (Task Scheduler: $TaskName)"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Target\hip-sync.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries `
  -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
  -Description 'ส่งข้อมูลลงเวลาจาก HIP Time ขึ้นระบบ รพ.สต.สองคอน ทุก 5 นาที' -Force | Out-Null

Write-Host "`nติดตั้งเสร็จแล้ว" -ForegroundColor Green
Write-Host "  - ทำงานทุก 5 นาที ขณะที่เครื่องเปิดและล็อกอินอยู่"
Write-Host "  - ล็อก: $Target\sync.log"
Write-Host "  - ยกเลิก: Unregister-ScheduledTask -TaskName $TaskName"
Read-Host "`nกด Enter เพื่อปิด"
