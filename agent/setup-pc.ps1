# ตั้งค่าคอมที่ติด HIP Time ให้ทำงานต่อเนื่อง (ไม่แก้ค่าเครือข่าย ไม่แก้ฐานข้อมูล)
#   1) ไม่ให้คอมหลับเองตอนเสียบปลั๊ก
#   2) เปิด HIP Time อัตโนมัติเมื่อล็อกอิน Windows
#   3) แสดงข้อมูลเครือข่ายสำหรับจอง IP ที่เราเตอร์ + ตรวจ Task ส่งข้อมูล
# วิธีรัน:  powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SongkonSync\setup-pc.ps1"
$ErrorActionPreference = 'Continue'

Write-Host "== 1) ไม่ให้คอมหลับ (ตอนเสียบปลั๊ก)" -ForegroundColor Cyan
try {
  powercfg /change standby-timeout-ac 0
  powercfg /change hibernate-timeout-ac 0
  Write-Host "ตั้งแล้ว: ไม่หลับ/ไม่จำศีลเมื่อเสียบปลั๊ก (หน้าจอดับเองได้ตามเดิม)" -ForegroundColor Green
} catch { Write-Host "ตั้งไม่สำเร็จ: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host ""
Write-Host "== 2) เปิด HIP Time อัตโนมัติ" -ForegroundColor Cyan
$exe = 'C:\Program Files (x86)\HIP TIME\HIPSchool_Zee.exe'
if (Test-Path $exe) {
  $startup = [Environment]::GetFolderPath('Startup')
  $lnk = Join-Path $startup 'HIP Time.lnk'
  $ws = New-Object -ComObject WScript.Shell
  $s = $ws.CreateShortcut($lnk)
  $s.TargetPath = $exe
  $s.WorkingDirectory = Split-Path $exe
  $s.Save()
  Write-Host "สร้างทางลัดเปิดอัตโนมัติแล้ว: $lnk" -ForegroundColor Green
  Write-Host "(หมายเหตุ: ต้องเข้า หน้า Real Time ในโปรแกรมเองหลังเปิด เพื่อให้ขึ้น 'เริ่มทำงาน' ถ้ายังไม่ขึ้นเอง)" -ForegroundColor Yellow
} else { Write-Host "ไม่พบ $exe" -ForegroundColor Red }

Write-Host ""
Write-Host "== 3) ข้อมูลเครือข่าย (ใช้จอง IP ที่เราเตอร์)" -ForegroundColor Cyan
Get-NetIPConfiguration | Where-Object { $_.IPv4Address -and $_.NetAdapter.Status -eq 'Up' } | ForEach-Object {
  $a = $_.NetAdapter
  $dhcp = (Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4).Dhcp
  Write-Host ("ชื่อการ์ด: {0} | IP: {1} | MAC: {2} | DHCP: {3} | Gateway: {4}" -f $a.Name, $_.IPv4Address.IPAddress, $a.MacAddress, $dhcp, $_.IPv4DefaultGateway.NextHop)
}

Write-Host ""
Write-Host "== 4) Task ส่งข้อมูล" -ForegroundColor Cyan
$t = Get-ScheduledTask -TaskName 'SongkonHipSync' -ErrorAction SilentlyContinue
if ($t) { $i = Get-ScheduledTaskInfo -TaskName 'SongkonHipSync'; Write-Host ("สถานะ: {0} | รันล่าสุด: {1} | ผล: {2}" -f $t.State, $i.LastRunTime, $i.LastTaskResult) -ForegroundColor Green }
else { Write-Host "ไม่พบ Task SongkonHipSync" -ForegroundColor Red }
