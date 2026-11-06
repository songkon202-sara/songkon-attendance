# ตั้ง Task Scheduler ให้ตัวส่งข้อมูลทำงานทุก 5 นาที (ใช้เมื่อ install.ps1 หยุดก่อนถึงขั้นที่ 5)
$ErrorActionPreference = 'Stop'
$Target   = Join-Path $env:LOCALAPPDATA 'SongkonSync'
$TaskName = 'SongkonHipSync'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Target\hip-sync.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries `
  -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
  -Description 'ส่งข้อมูลลงเวลาจาก HIP Time ขึ้นระบบ รพ.สต.สองคอน ทุก 5 นาที' -Force | Out-Null

$t = Get-ScheduledTask -TaskName $TaskName
Write-Host "ตั้งเรียบร้อย: $TaskName ($($t.State)) ทำงานทุก 5 นาที" -ForegroundColor Green
