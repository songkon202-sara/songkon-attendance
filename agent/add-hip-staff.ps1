# เพิ่มพนักงานใน HIP Time (ตาราง dbo.Student) ด้วยการทำสำเนาจากพนักงานที่มีอยู่
#   เลข 7  นายวราเทพ ฤกษ์สว่าง     เลข 10 นางสาวยุพิน รัตนะคำ
# ใช้ 2 ขั้น:
#   1) ตรวจก่อน (ไม่แก้อะไร):  powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SongkonSync\add-hip-staff.ps1"
#   2) เพิ่มจริง (ปิด HIP Time ก่อน): powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SongkonSync\add-hip-staff.ps1" -Apply

param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Plan  = Join-Path $Here 'add-hip-plan.txt'
$parts = (Get-Content 'C:\Program Files (x86)\HIP TIME\schcare.ini' -Raw).Trim().Split('$')
$cs    = "Server=$($parts[0]);Database=$($parts[1]);User ID=$($parts[2]);Password=$($parts[3]);Connect Timeout=15"

$ToAdd = @(
  @{ code = '7';  enroll = 7;  name = 'นายวราเทพ ฤกษ์สว่าง' },
  @{ code = '10'; enroll = 10; name = 'นางสาวยุพิน รัตนะคำ' }
)
# ใช้แถวของรหัสนี้เป็นแม่แบบ (สาขา/แผนก/กะ ให้เหมือนกัน)
$TemplateCode = '8'
# คอลัมน์ข้อมูลส่วนตัว/เฉพาะบุคคล ที่ต้องล้างให้ว่าง ไม่คัดลอกจากแม่แบบ
$Blank = @('studentnamee','cardno','birthdate','address1','address2','province','salary','mobile','idcard',
           'issueby','passport','carlicence','motorlicence','mobilerecvmsg','webusercode','pic','retiredate')

function Q($cn, $sql, $tx) {
  $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; if ($tx) { $cmd.Transaction = $tx }
  $t = New-Object System.Data.DataTable; $t.Load($cmd.ExecuteReader()); return ,$t
}

$cn = New-Object System.Data.SqlClient.SqlConnection $cs
$cn.Open()
try {
  $meta = Q $cn "SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COLUMNPROPERTY(OBJECT_ID('dbo.Student'), COLUMN_NAME, 'IsIdentity') AS idn FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='Student' ORDER BY ORDINAL_POSITION"
  $tpl = Q $cn "SELECT TOP 1 * FROM dbo.Student WHERE studentcode='$TemplateCode'"
  if ($tpl.Rows.Count -eq 0) { $tpl = Q $cn "SELECT TOP 1 * FROM dbo.Student ORDER BY id" }
  $t0 = $tpl.Rows[0]
  $maxId = [int](Q $cn "SELECT ISNULL(MAX(id),0) AS m FROM dbo.Student").Rows[0].m

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("== โหมด: " + $(if ($Apply) { 'เพิ่มจริง' } else { 'ตรวจอย่างเดียว' }))
  [void]$sb.AppendLine("แม่แบบ: รหัส $($t0.studentcode) ($($t0.studentname))")
  $now = Get-Date -Format 'yyyy-MM-dd'

  $rows = @(); $i = 0
  foreach ($p in $ToAdd) {
    $i++
    $exists = [int](Q $cn "SELECT COUNT(*) AS n FROM dbo.Student WHERE studentcode='$($p.code)' OR enrollnumber=$($p.enroll)").Rows[0].n
    if ($exists -gt 0) { [void]$sb.AppendLine("ข้าม: $($p.name) มีรหัส/เลขที่ $($p.code) อยู่แล้ว"); continue }
    $vals = [ordered]@{}
    foreach ($m in $meta.Rows) {
      $c = [string]$m.COLUMN_NAME
      if ($m.idn -eq 1) { continue }
      if ($c -eq 'id')            { $vals[$c] = $maxId + $i; continue }
      if ($c -eq 'studentcode')   { $vals[$c] = $p.code; continue }
      if ($c -eq 'studentname')   { $vals[$c] = $p.name; continue }
      if ($c -eq 'enrollnumber')  { $vals[$c] = [long]$p.enroll; continue }
      if ($c -eq 'studentdate')   { $vals[$c] = $now; continue }
      if ($c -eq 'active')        { $vals[$c] = $true; continue }
      if ($Blank -contains $c) {
        if ($m.IS_NULLABLE -eq 'YES') { $vals[$c] = [DBNull]::Value }
        elseif ($m.DATA_TYPE -match 'int|decimal|numeric|float|real|money|bit') { $vals[$c] = 0 }
        else { $vals[$c] = '' }
        continue
      }
      $vals[$c] = $t0[$c]
    }
    $rows += ,@{ person = $p; vals = $vals }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("เพิ่ม: $($p.name)  รหัส=$($p.code)  เลขที่ในเครื่อง=$($p.enroll)")
    foreach ($k in $vals.Keys) {
      if ($Blank -contains $k) { continue }
      [void]$sb.AppendLine(("   {0} = {1}" -f $k, $vals[$k]))
    }
  }
  $sb.ToString() | Set-Content $Plan -Encoding UTF8

  if (-not $Apply) {
    Write-Host "ตรวจเสร็จ ยังไม่ได้เพิ่มอะไร ดูแผนที่ $Plan" -ForegroundColor Green
    return
  }
  if ($rows.Count -eq 0) { Write-Host "ไม่มีรายการที่ต้องเพิ่ม (มีอยู่แล้วทั้งหมด)" -ForegroundColor Yellow; return }

  $hip = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -like '*HIP TIME*' } catch { $false } })
  if ($hip.Count -gt 0) { Write-Host "ปิดโปรแกรม HIP Time ก่อน แล้วรันใหม่ (พบ: $($hip.ProcessName -join ', '))" -ForegroundColor Red; return }

  $bk = Join-Path $Here ('hip-backup-add-{0:yyyyMMdd-HHmm}' -f (Get-Date))
  New-Item -ItemType Directory -Path $bk | Out-Null
  (Q $cn "SELECT * FROM dbo.Student") | Export-Csv (Join-Path $bk 'Student.csv') -NoTypeInformation -Encoding UTF8
  Write-Host "สำรองไว้ที่ $bk" -ForegroundColor Cyan

  $before = [int](Q $cn "SELECT COUNT(*) AS n FROM dbo.Student").Rows[0].n
  $tx = $cn.BeginTransaction()
  try {
    foreach ($r in $rows) {
      $cols = @($r.vals.Keys)
      $sql = "INSERT INTO dbo.Student (" + (($cols | ForEach-Object { "[$_]" }) -join ',') + ") VALUES (" + ((0..($cols.Count-1) | ForEach-Object { "@p$_" }) -join ',') + ")"
      $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.Transaction = $tx
      for ($k = 0; $k -lt $cols.Count; $k++) { [void]$cmd.Parameters.AddWithValue("@p$k", $r.vals[$cols[$k]]) }
      [void]$cmd.ExecuteNonQuery()
    }
    $after = [int](Q $cn "SELECT COUNT(*) AS n FROM dbo.Student" $tx).Rows[0].n
    if ($after -ne $before + $rows.Count) { throw "จำนวนแถวไม่ตรง ($before -> $after)" }
    $tx.Commit()
    Write-Host "เพิ่มเสร็จแล้ว ($($rows.Count) คน) เปิด HIP Time ใหม่ได้" -ForegroundColor Green
  } catch {
    $tx.Rollback()
    Write-Host "มีข้อผิดพลาด ยกเลิกทั้งหมดแล้ว (ข้อมูลเหมือนเดิม): $($_.Exception.Message)" -ForegroundColor Red
  }
} finally { $cn.Close() }
