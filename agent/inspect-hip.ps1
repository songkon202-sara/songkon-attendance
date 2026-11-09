# ตรวจโครงสร้างตารางพนักงานของ HIP Time (อ่านอย่างเดียว ไม่แก้ข้อมูล)
# ผลลัพธ์: inspect-hip.txt  และสำรองตารางพนักงาน: student-backup.csv (เก็บไว้ในโฟลเดอร์นี้เท่านั้น)
# วิธีรัน:  powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SongkonSync\inspect-hip.ps1"

$ErrorActionPreference = 'Stop'
$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Out   = Join-Path $Here 'inspect-hip.txt'
$parts = (Get-Content 'C:\Program Files (x86)\HIP TIME\schcare.ini' -Raw).Trim().Split('$')
$cs    = "Server=$($parts[0]);Database=$($parts[1]);User ID=$($parts[2]);Password=$($parts[3]);Connect Timeout=15"

function Q($cn, $sql) {
  $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql
  $t = New-Object System.Data.DataTable; $t.Load($cmd.ExecuteReader()); return ,$t
}

$cn = New-Object System.Data.SqlClient.SqlConnection $cs
$cn.Open()
try {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("== ตาราง/คอลัมน์ที่มีคำว่า enroll")
  $c = Q $cn "SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE COLUMN_NAME LIKE '%enroll%' ORDER BY TABLE_NAME"
  foreach ($r in $c.Rows) {
    $n = (Q $cn ("SELECT COUNT(*) AS n FROM [{0}]" -f $r.TABLE_NAME)).Rows[0].n
    [void]$sb.AppendLine(("{0}.{1} ({2}) แถว={3}" -f $r.TABLE_NAME, $r.COLUMN_NAME, $r.DATA_TYPE, $n))
  }

  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("== คอลัมน์ของ dbo.Student")
  $cols = Q $cn "SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='Student' ORDER BY ORDINAL_POSITION"
  [void]$sb.AppendLine((($cols.Rows | ForEach-Object { "{0}:{1}" -f $_.COLUMN_NAME, $_.DATA_TYPE }) -join ', '))

  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("== Foreign key / trigger ที่เกี่ยวกับ Student")
  $fk = Q $cn "SELECT OBJECT_NAME(parent_object_id) AS child, OBJECT_NAME(referenced_object_id) AS parent, name FROM sys.foreign_keys WHERE OBJECT_NAME(referenced_object_id)='Student' OR OBJECT_NAME(parent_object_id)='Student'"
  foreach ($r in $fk.Rows) { [void]$sb.AppendLine(("FK {0} -> {1} ({2})" -f $r.child, $r.parent, $r.name)) }
  $tg = Q $cn "SELECT name FROM sys.triggers WHERE OBJECT_NAME(parent_id)='Student'"
  foreach ($r in $tg.Rows) { [void]$sb.AppendLine(("TRIGGER {0}" -f $r.name)) }

  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("== รายชื่อ (เฉพาะคอลัมน์ที่ไม่ใช่ข้อมูลส่วนตัว)")
  $all = Q $cn "SELECT * FROM dbo.Student"
  $show = @($all.Columns | Where-Object { $_.ColumnName -match '^(enrollnumber|studentname|studentid|studentcode|empcode|code|active|id|branchid|deptid)$' } | ForEach-Object { $_.ColumnName })
  [void]$sb.AppendLine(($show -join ' | '))
  foreach ($r in $all.Rows) { [void]$sb.AppendLine((($show | ForEach-Object { [string]$r[$_] }) -join ' | ')) }

  # สำรองทั้งตาราง (มีข้อมูลส่วนตัว เก็บในเครื่องเท่านั้น)
  $all | Export-Csv (Join-Path $Here 'student-backup.csv') -NoTypeInformation -Encoding UTF8

  $sb.ToString() | Set-Content $Out -Encoding UTF8
  Write-Host "เสร็จแล้ว: $Out" -ForegroundColor Green
  Write-Host "สำรองตารางพนักงานไว้ที่ $Here\student-backup.csv" -ForegroundColor Green
} finally { $cn.Close() }
