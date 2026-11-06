# ตัวส่งข้อมูลลงเวลา: อ่านรายการสแกนใหม่จาก HIP Time (SQL Server) แล้วส่งขึ้น Supabase
# - อ่านอย่างเดียว ใช้บัญชี SQL "songkon_sync" ที่มีสิทธิ์ SELECT แค่ 2 ตาราง
# - Task Scheduler เรียกทุก 5 นาที (ตั้งโดย install.ps1)
# - ล็อกอยู่ที่ sync.log ในโฟลเดอร์เดียวกัน

param([switch]$Show)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Security

$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $Here 'sync.log'
$Batch   = 1000

function Log($msg) {
  $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
  if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
    Move-Item $LogFile "$LogFile.old" -Force
  }
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
  if ($Show) { Write-Host $line }
}

function Unprotect($b64) {
  $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
    [Convert]::FromBase64String($b64), $null,
    [Security.Cryptography.DataProtectionScope]::CurrentUser)
  [Text.Encoding]::UTF8.GetString($bytes)
}

# กันรันซ้อน
$mutex = New-Object System.Threading.Mutex($false, 'Local\SongkonHipSync')
if (-not $mutex.WaitOne(0)) { exit 0 }

$script:Stage = 'เริ่มต้น'
try {
  $cfg    = Get-Content (Join-Path $Here 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $secret = Unprotect $cfg.agentSecretProtected
  $sqlPwd = Unprotect $cfg.sqlPasswordProtected
  $cs     = "Server=$($cfg.sqlServer);Database=$($cfg.sqlDatabase);User ID=$($cfg.sqlUser);Password=$sqlPwd;Connect Timeout=15"
  $headers = @{ apikey = $cfg.publishableKey }

  function Rpc($name, $body) {
    $json  = $body | ConvertTo-Json -Depth 5 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    Invoke-RestMethod -Method Post -Uri "$($cfg.supabaseUrl)/rest/v1/rpc/$name" `
      -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 60
  }

  function Query($sql, $params) {
    $cn = New-Object System.Data.SqlClient.SqlConnection $cs
    $cn.Open()
    try {
      $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql
      foreach ($k in $params.Keys) { [void]$cmd.Parameters.AddWithValue($k, $params[$k]) }
      $t = New-Object System.Data.DataTable
      $t.Load($cmd.ExecuteReader())
      return ,$t
    } finally { $cn.Close() }
  }

  $script:Stage = 'อ่านรายชื่อ/ส่งรายชื่อ (hip_people_upsert)'
  # 1) รายชื่อเจ้าหน้าที่ในเครื่อง (ใช้นำเข้ารายชื่อบนหน้าเว็บ)
  $people = Query "SELECT enrollnumber, studentname, active FROM dbo.Student WHERE enrollnumber IS NOT NULL" @{}
  $pRows = @($people.Rows | ForEach-Object {
    @{ enroll = [string]$_.enrollnumber; name = [string]$_.studentname
       active = if ($_.active -is [DBNull]) { $true } else { [bool]$_.active } }
  })
  if ($pRows.Count -gt 0) { [void](Rpc 'hip_people_upsert' @{ p_secret = $secret; p_rows = $pRows }) }

  $script:Stage = 'ถาม id ล่าสุด (hip_last_scan_id)'
  # 2) รายการสแกนใหม่ ต่อจาก id ล่าสุดที่ระบบรับแล้ว
  $last  = [long](Rpc 'hip_last_scan_id' @{ p_secret = $secret })
  $total = 0
  do {
    $t = Query "SELECT TOP $Batch id, enrollnumber, verifymode, verifymodestr, datetimescan, adddate FROM dbo.Transcantime WHERE id > @last ORDER BY id" @{ '@last' = $last }
    if ($t.Rows.Count -eq 0) { break }
    $rows = @(foreach ($r in $t.Rows) {
      # datetimescan เช่น "2026-11-05 08:48:07 AM" — ใช้ 19 ตัวแรก (เวลา 24 ชม.) ไม่สน AM/PM ที่ต่อท้าย
      $ts = $null; $modeStr = [string]$r.verifymodestr
      $raw = ([string]$r.datetimescan).Trim()
      if ($raw.Length -ge 19) {
        $p = [datetime]::MinValue
        if ([datetime]::TryParseExact($raw.Substring(0,19), 'yyyy-MM-dd HH:mm:ss',
              [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$p)) { $ts = $p }
      }
      if (-not $ts) { $ts = [datetime]$r.adddate; $modeStr = "$modeStr|BADTIME:$raw" }
      @{ id = [long]$r.id; enroll = [string]$r.enrollnumber
         mode = if ($r.verifymode -is [DBNull]) { $null } else { [long]$r.verifymode }
         mode_str = $modeStr
         time = $ts.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + '+07:00' }
    })
    $script:Stage = 'ส่งรายการสแกน (hip_ingest)'
    $res   = Rpc 'hip_ingest' @{ p_secret = $secret; p_rows = $rows }
    $last  = [long]$res.last_scan_id
    $total += $rows.Count
    Log ("ส่ง {0} รายการ (ใหม่ {1}, รอจับคู่ {2}) ถึง id {3}" -f $rows.Count, $res.new, $res.unmatched, $last)
  } while ($t.Rows.Count -eq $Batch)

  if ($total -eq 0 -and $Show) { Log "ไม่มีรายการใหม่ (ล่าสุด id $last)" }
  exit 0
}
catch {
  $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { ' | ' + $_.ErrorDetails.Message } else { '' }
  Log ("ผิดพลาด [$script:Stage]: " + $_.Exception.Message + $detail)
  exit 1
}
finally {
  $mutex.ReleaseMutex() | Out-Null
}
