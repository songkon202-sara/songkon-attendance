# แก้ "เลขที่" (enrollnumber) ในฐานข้อมูล HIP Time ให้ตรงกับรหัสพนักงานชุดใหม่ (1-10)
#
# ใช้ 2 ขั้น:
#   1) ตรวจก่อน (ไม่แก้อะไร):   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SongkonSync\fix-hip-numbers.ps1"
#      -> เขียนแผนไว้ที่ fix-hip-plan.txt
#   2) แก้จริง (ปิด HIP Time ก่อน): powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SongkonSync\fix-hip-numbers.ps1" -Apply
#      -> สำรอง 5 ตารางเป็นไฟล์ แล้วแก้ใน transaction เดียว (ไม่ผ่านการตรวจนับ = ย้อนกลับทั้งหมด)

param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Plan  = Join-Path $Here 'fix-hip-plan.txt'
$parts = (Get-Content 'C:\Program Files (x86)\HIP TIME\schcare.ini' -Raw).Trim().Split('$')
$cs    = "Server=$($parts[0]);Database=$($parts[1]);User ID=$($parts[2]);Password=$($parts[3]);Connect Timeout=15"

# เลขเก่า -> เลขใหม่ (ตามคน)
# หมายเหตุ: ต้องใช้ hashtable ธรรมดา (ไม่ใช่ [ordered]) ไม่งั้นเลขจะถูกตีความเป็นลำดับตำแหน่ง
$Map = @{ 10 = 1; 7 = 2; 5 = 3; 9 = 4; 1 = 5; 8 = 6; 4 = 8; 2 = 9 }
$Off = 100000
# สแกนดิบ (Transcantime) ตั้งแต่ id นี้ขึ้นไปเป็นเลขชุดใหม่แล้ว ไม่แตะ
$NewScanFrom = 3071
$Tables = @('Student', 'StudentMachine', 'StudentShift', 'StudentTime', 'Transcantime')

function Q($cn, $sql, $tx) {
  $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; if ($tx) { $cmd.Transaction = $tx }
  $t = New-Object System.Data.DataTable; $t.Load($cmd.ExecuteReader()); return ,$t
}
function X($cn, $sql, $tx) {
  $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; if ($tx) { $cmd.Transaction = $tx }
  return $cmd.ExecuteNonQuery()
}
function Scope($t) { if ($t -eq 'Transcantime') { "id < $NewScanFrom" } else { '1=1' } }

$cn = New-Object System.Data.SqlClient.SqlConnection $cs
$cn.Open()
try {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("== โหมด: " + $(if ($Apply) { 'แก้จริง' } else { 'ตรวจอย่างเดียว' }))
  foreach ($t in $Tables) {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("-- $t  (ขอบเขต: $(Scope $t))")
    $cols = Q $cn "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='$t' ORDER BY ORDINAL_POSITION"
    [void]$sb.AppendLine("คอลัมน์: " + (($cols.Rows | ForEach-Object { $_.COLUMN_NAME }) -join ', '))
    $pk = Q $cn "SELECT c.COLUMN_NAME FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS t JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE c ON c.CONSTRAINT_NAME=t.CONSTRAINT_NAME WHERE t.TABLE_NAME='$t' AND t.CONSTRAINT_TYPE IN ('PRIMARY KEY','UNIQUE')"
    if ($pk.Rows.Count) { [void]$sb.AppendLine("คีย์/ห้ามซ้ำ: " + (($pk.Rows | ForEach-Object { $_.COLUMN_NAME }) -join ', ')) }
    $dateCol = ($cols.Rows | Where-Object { $_.COLUMN_NAME -match 'date|time' } | Select-Object -First 1).COLUMN_NAME
    $sel = if ($dateCol) { ", MIN(CAST([$dateCol] AS nvarchar(40))) AS d1, MAX(CAST([$dateCol] AS nvarchar(40))) AS d2" } else { '' }
    $g = Q $cn "SELECT enrollnumber, COUNT(*) AS n$sel FROM [$t] WHERE $(Scope $t) GROUP BY enrollnumber ORDER BY enrollnumber"
    foreach ($r in $g.Rows) {
      $e = [long]$r.enrollnumber
      $to = if ($Map.ContainsKey([int]$e)) { $Map[[int]$e] } else { $e + 1000 }
      $rng = if ($dateCol) { "  ช่วง [$dateCol] $($r.d1) .. $($r.d2)" } else { '' }
      [void]$sb.AppendLine(("  เลข {0,-6} -> {1,-6} {2,6} แถว{3}" -f $e, $to, $r.n, $rng))
    }
  }
  $sb.ToString() | Set-Content $Plan -Encoding UTF8

  if (-not $Apply) {
    Write-Host "ตรวจเสร็จ ยังไม่ได้แก้อะไร ดูแผนที่ $Plan" -ForegroundColor Green
    return
  }

  # ---- แก้จริง ----
  $hip = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -like '*HIP TIME*' } catch { $false } })
  if ($hip.Count -gt 0) { Write-Host "ปิดโปรแกรม HIP Time ก่อน แล้วรันใหม่ (พบ: $($hip.ProcessName -join ', '))" -ForegroundColor Red; return }

  $bk = Join-Path $Here ('hip-backup-{0:yyyyMMdd-HHmm}' -f (Get-Date))
  New-Item -ItemType Directory -Path $bk | Out-Null
  foreach ($t in $Tables) { (Q $cn "SELECT * FROM [$t]") | Export-Csv (Join-Path $bk "$t.csv") -NoTypeInformation -Encoding UTF8 }
  Write-Host "สำรองไว้ที่ $bk" -ForegroundColor Cyan

  $before = @{}; foreach ($t in $Tables) { $before[$t] = [int](Q $cn "SELECT COUNT(*) AS n FROM [$t]").Rows[0].n }
  $tx = $cn.BeginTransaction()
  try {
    foreach ($t in $Tables) {
      $sc = Scope $t
      # ขั้น 1: ย้ายทุกเลขในขอบเขตออกไปช่วงพัก (+100000) กันชนกันระหว่างสลับ
      [void](X $cn "UPDATE [$t] SET enrollnumber = enrollnumber + $Off WHERE $sc" $tx)
      # ขั้น 2: ตั้งเลขจริง
      foreach ($o in $Map.Keys) {
        [void](X $cn ("UPDATE [{0}] SET enrollnumber = {1} WHERE enrollnumber = {2}" -f $t, $Map[$o], ($o + $Off)) $tx)
      }
      [void](X $cn "UPDATE [$t] SET enrollnumber = enrollnumber - $Off + 1000 WHERE enrollnumber >= $Off" $tx)
    }
    foreach ($t in $Tables) {
      $after = [int](Q $cn "SELECT COUNT(*) AS n FROM [$t]" $tx).Rows[0].n
      if ($after -ne $before[$t]) { throw "จำนวนแถวของ $t ไม่เท่าเดิม ($($before[$t]) -> $after)" }
      $leftover = [int](Q $cn "SELECT COUNT(*) AS n FROM [$t] WHERE enrollnumber >= $Off" $tx).Rows[0].n
      if ($leftover -ne 0) { throw "$t ยังมีเลขช่วงพักค้าง $leftover แถว" }
    }
    $tx.Commit()
    Write-Host "แก้เสร็จแล้ว เปิด HIP Time ใหม่ได้" -ForegroundColor Green
  } catch {
    $tx.Rollback()
    Write-Host "มีข้อผิดพลาด ยกเลิกทั้งหมดแล้ว (ข้อมูลเหมือนเดิม): $($_.Exception.Message)" -ForegroundColor Red
  }
} finally { $cn.Close() }
