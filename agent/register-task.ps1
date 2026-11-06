# ตั้ง Task Scheduler ให้ตัวส่งข้อมูลทำงานทุก N นาที (ค่าเริ่มต้น 1 นาที)
# วิธีรัน: powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SongkonSync\register-task.ps1"
param([int]$Minutes = 1)
$ErrorActionPreference = 'Stop'
$Target   = Join-Path $env:LOCALAPPDATA 'SongkonSync'
$TaskName = 'SongkonHipSync'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Target\hip-sync.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes $Minutes) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries `
  -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
  -Description "ส่งข้อมูลลงเวลาจาก HIP Time ขึ้นระบบ รพ.สต.สองคอน ทุก $Minutes นาที" -Force | Out-Null

$t = Get-ScheduledTask -TaskName $TaskName
Write-Host "ตั้งเรียบร้อย: $TaskName ($($t.State)) ทำงานทุก $Minutes นาที" -ForegroundColor Green
