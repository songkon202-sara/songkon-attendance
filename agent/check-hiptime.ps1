# ตรวจโครงสร้างฐานข้อมูล HIP Time แบบอ่านอย่างเดียว (ไม่แก้ไขข้อมูลใด ๆ)
# วิธีรัน: เปิด PowerShell แล้วพิมพ์
#   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\check-hiptime.ps1"
# ผลลัพธ์จะบันทึกที่ Downloads\hiptime-check.txt (ไม่มีชื่อเจ้าหน้าที่ และไม่มีรหัสผ่าน)

$ErrorActionPreference = 'Stop'
$ini   = Get-Content 'C:\Program Files (x86)\HIP TIME\schcare.ini' -Raw
$parts = $ini.Trim().Split('$')          # server$database$user$password$...
$cs    = "Server=$($parts[0]);Database=$($parts[1]);User ID=$($parts[2]);Password=$($parts[3]);ApplicationIntent=ReadOnly;Connect Timeout=10"
$out   = "$env:USERPROFILE\Downloads\hiptime-check.txt"

function Q($sql) {
  $cn = New-Object System.Data.SqlClient.SqlConnection $cs
  $cn.Open()
  try {
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql
    $t = New-Object System.Data.DataTable
    $t.Load($cmd.ExecuteReader()); $t
  } finally { $cn.Close() }
}

$report = @()
$report += "== server/database: $($parts[0]) / $($parts[1])"
$report += "== Transcantime columns"
$report += (Q "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='Transcantime' ORDER BY ORDINAL_POSITION" | Format-Table -AutoSize | Out-String)
$report += "== Transcantime: last 15 rows (no names)"
$report += (Q "SELECT TOP 15 id, enrollnumber, machineno, verifymode, verifymodestr, datetimescan, adddate FROM Transcantime ORDER BY id DESC" | Format-Table -AutoSize | Out-String)
$report += "== verifymode counts"
$report += (Q "SELECT verifymode, verifymodestr, COUNT(*) AS n FROM Transcantime GROUP BY verifymode, verifymodestr ORDER BY n DESC" | Format-Table -AutoSize | Out-String)
$report += "== totals"
$report += (Q "SELECT COUNT(*) AS scans, MIN(id) AS min_id, MAX(id) AS max_id, (SELECT COUNT(*) FROM Student) AS staff, (SELECT COUNT(*) FROM Student WHERE active=1) AS staff_active FROM Transcantime" | Format-Table -AutoSize | Out-String)

$report | Set-Content -Path $out -Encoding UTF8
Write-Host "บันทึกผลที่ $out แล้ว" -ForegroundColor Green
