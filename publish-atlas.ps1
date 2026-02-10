param(
  [string]$AtlasRoot = "C:\Users\rick\projects\Atlas"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# Paths
# ============================================================
$RepoRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$PublicDir = Join-Path $RepoRoot "public"
$LiveDir   = Join-Path $PublicDir "data"
$StageDir  = Join-Path $PublicDir "data_stage"

$AtlasDashDir   = Join-Path $AtlasRoot "data\output\dashboard"
$AtlasLatestAll = Join-Path $AtlasRoot "data\output\latest\all"
$AtlasAuditCsv  = Join-Path $AtlasRoot "data\gamelogs\audit_last5_board.csv"

# ============================================================
# Helpers
# ============================================================
function Ensure-Dir([string]$DirPath) {
  if (-not (Test-Path -LiteralPath $DirPath)) {
    New-Item -ItemType Directory -Path $DirPath | Out-Null
  }
}

function Clear-DirFiles([string]$DirPath) {
  if (Test-Path -LiteralPath $DirPath) {
    Get-ChildItem -LiteralPath $DirPath -File -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
  }
}

function Read-JsonFile([string]$FilePath) {
  if (-not (Test-Path -LiteralPath $FilePath)) { return $null }
  $raw = Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Write-JsonFile([string]$FilePath, $Obj) {
  $parent = Split-Path -Parent $FilePath
  Ensure-Dir $parent

  $json = $Obj | ConvertTo-Json -Depth 50
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($FilePath, $json, $utf8NoBom)

  if (-not (Test-Path -LiteralPath $FilePath)) { throw "Failed to write JSON: $FilePath" }

  $raw = Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($raw)) { throw "Wrote blank JSON: $FilePath" }

  try { $null = ($raw.Trim() | ConvertFrom-Json -ErrorAction Stop) }
  catch { throw "Wrote unreadable JSON: $FilePath" }
}

function Copy-AllJson([string]$SrcDir, [string]$DstDir) {
  $n = 0
  if (Test-Path -LiteralPath $SrcDir) {
    $files = Get-ChildItem -LiteralPath $SrcDir -File -Filter "*.json" -ErrorAction SilentlyContinue
    foreach ($f in $files) {
      Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $DstDir $f.Name) -Force
      $n++
    }
  }
  return $n
}

function Read-CsvTopRow([string]$CsvPath) {
  if (-not (Test-Path -LiteralPath $CsvPath)) { return $null }
  try {
    $rows = Import-Csv -LiteralPath $CsvPath
    $arr = @($rows)
    if ($arr.Count -lt 1) { return $null }
    return $arr[0]
  } catch {
    return $null
  }
}

function Normalize-PlayerKey([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return "" }
  $t = $s.ToLowerInvariant()
  $t = $t -replace "[^a-z0-9\s\.\-']", " "
  $t = ($t -replace "\s+", " ").Trim()
  return $t
}

function Parse-RawLeg([string]$raw) {
  # raw example:
  # "Luguentz Dort OVER REB 2.5 (GOBLIN) [id:9800573]"
  $s = [string]$raw
  if ([string]::IsNullOrWhiteSpace($s)) {
    return [pscustomobject]@{ player=""; stat=""; id=$null }
  }

  $id = $null
  $mId = [regex]::Match($s, "\[id:\s*(\d+)\s*\]", "IgnoreCase")
  if ($mId.Success) { $id = [int]$mId.Groups[1].Value }

  $stat = ""
  $mStat = [regex]::Match($s, "\b(OVER|UNDER|MORE|LESS|O|U)\s+([A-Z0-9\+]+)\b", "IgnoreCase")
  if ($mStat.Success) { $stat = $mStat.Groups[2].Value.ToUpperInvariant() }

  $player = ""
  $idx = [regex]::Match($s, "\b(OVER|UNDER|MORE|LESS|O|U)\b", "IgnoreCase").Index
  if ($idx -gt 0) { $player = ($s.Substring(0,$idx)).Trim() }

  return [pscustomobject]@{ player=$player; stat=$stat; id=$id }
}

function Load-AuditMap([string]$AuditCsvPath) {
  $map = @{}
  if (-not (Test-Path -LiteralPath $AuditCsvPath)) {
    Write-Host "Audit CSV missing (no last-5 enrichment): $AuditCsvPath"
    return $map
  }

  try {
    $rows = Import-Csv -LiteralPath $AuditCsvPath
    foreach ($r in $rows) {
      # Prefer resolved_player if present, else board_player
      $name = ""
      if ($r.PSObject.Properties.Name -contains "resolved_player") { $name = [string]$r.resolved_player }
      if ([string]::IsNullOrWhiteSpace($name) -and ($r.PSObject.Properties.Name -contains "board_player")) { $name = [string]$r.board_player }
      $k = Normalize-PlayerKey $name
      if ([string]::IsNullOrWhiteSpace($k)) { continue }
      $map[$k] = $r
    }
  } catch {
    Write-Host "Audit CSV unreadable (no last-5 enrichment): $AuditCsvPath"
  }

  return $map
}

function Last5-ForStat($auditRow, [string]$stat) {
  if ($null -eq $auditRow) { return $null }

  $pts = [double]($auditRow.last5_pts  -as [double])
  $reb = [double]($auditRow.last5_reb  -as [double])
  $ast = [double]($auditRow.last5_ast  -as [double])
  $fg3 = [double]($auditRow.last5_fg3m -as [double])

  switch ($stat) {
    "PTS"  { return $pts }
    "REB"  { return $reb }
    "AST"  { return $ast }
    "FG3M" { return $fg3 }
    "PR"   { return ($pts + $reb) }
    "PA"   { return ($pts + $ast) }
    "RA"   { return ($reb + $ast) }
    "PRA"  { return ($pts + $reb + $ast) }
    default { return $null }
  }
}

function Enrich-LegsDetail($legsDetail, $auditMap) {
  # legsDetail is array of objects, often {raw:"..."}
  # NOTE: We ONLY publish last5_val (last 5 games), NOT minutes.
  if ($null -eq $legsDetail) { return @() }

  $arr = @($legsDetail)
  $out = @()

  foreach ($leg in $arr) {
    $raw = ""
    if ($leg.PSObject.Properties.Name -contains "raw") { $raw = [string]$leg.raw }
    else { $raw = [string]$leg }

    $p = Parse-RawLeg $raw
    $key = Normalize-PlayerKey $p.player

    $audit = $null
    if (-not [string]::IsNullOrWhiteSpace($key) -and $auditMap.ContainsKey($key)) { $audit = $auditMap[$key] }

    $last5Val = $null
    if ($null -ne $audit -and -not [string]::IsNullOrWhiteSpace($p.stat)) {
      $last5Val = Last5-ForStat $audit $p.stat
    }

    $o = [pscustomobject]@{
      raw = $raw
    }

    if ($p.id -ne $null) { $o | Add-Member -NotePropertyName "id" -NotePropertyValue $p.id -Force }
    if ($last5Val -ne $null) { $o | Add-Member -NotePropertyName "last5_val" -NotePropertyValue $last5Val -Force }

    $out += $o
  }

  return @($out)
}

function Guess-LegsDetailFromRow($Row) {
  foreach ($k in @("legs_detail","legs_detail_json","legsDetail","legs_detail_str")) {
    if ($Row.PSObject.Properties.Name -contains $k) {
      $v = [string]$Row.$k
      if (-not [string]::IsNullOrWhiteSpace($v)) {
        try { return @((ConvertFrom-Json -InputObject $v -ErrorAction Stop)) } catch { }
      }
    }
  }

  $legsKey = $null
  foreach ($k in @("legs","legs_str","legsString")) {
    if ($Row.PSObject.Properties.Name -contains $k) { $legsKey = $k; break }
  }
  if ($null -eq $legsKey) { return @() }

  $s = [string]$Row.$legsKey
  if ([string]::IsNullOrWhiteSpace($s)) { return @() }

  $parts = $s -split "\s*\|\s*"
  $out = @()
  foreach ($p in $parts) {
    $t = $p.Trim()
    if ($t.Length -eq 0) { continue }
    $out += [pscustomobject]@{ raw = $t }
  }
  return $out
}

function Build-OneSlipFromCsv([string]$CsvPath, [string]$Product, [int]$NLegs, $auditMap) {
  $top = Read-CsvTopRow $CsvPath
  if ($null -eq $top) { return $null }

  $legsKey = $null
  foreach ($k in @("legs","legs_str","legsString")) {
    if ($top.PSObject.Properties.Name -contains $k) { $legsKey = $k; break }
  }
  $legsStr = if ($null -ne $legsKey) { [string]$top.$legsKey } else { "" }

  $legsDetailRaw = Guess-LegsDetailFromRow $top
  $legsDetailEnriched = Enrich-LegsDetail $legsDetailRaw $auditMap

  $obj = [pscustomobject]@{
    product     = $Product
    n_legs      = $NLegs
    legs        = $legsStr
    legs_detail = @($legsDetailEnriched)
  }

  foreach ($k in @(
    "ev_mult","ev","atlas_ev",
    "hit_prob","p_hit","slip_p","p_slip",
    "avg_fragility","slip_tag_set","slip_tag",
    "slip_agreement_tier","slip_min_start_utc",
    "notes"
  )) {
    if ($top.PSObject.Properties.Name -contains $k) {
      $obj | Add-Member -NotePropertyName $k -NotePropertyValue $top.$k -Force
    }
  }

  return $obj
}

# ============================================================
# Stage build
# ============================================================
Write-Host "Staging into $StageDir (safe publish; live data not deleted until stage succeeds)"
Ensure-Dir $StageDir
Ensure-Dir $LiveDir
Clear-DirFiles $StageDir

$copiedDash   = Copy-AllJson $AtlasDashDir $StageDir
$copiedLatest = Copy-AllJson $AtlasLatestAll $StageDir
Write-Host "Auto-pull: copied $copiedDash JSON(s) from Atlas export dir: $AtlasDashDir"
Write-Host "Auto-pull: copied $copiedLatest JSON(s) from Atlas export dir: $AtlasLatestAll"
Write-Host "Status staged"
Write-Host "Invalidations staged"

# Load audit map once (used for System + Windfall enrichment)
$auditMap = Load-AuditMap $AtlasAuditCsv
if ($auditMap.Count -gt 0) {
  Write-Host ("Audit map loaded: {0} players (last-5 enrichment enabled)" -f $auditMap.Count)
}

# ============================================================
# System — BUILD FROM CSVs (array of 3 rows: 3/4/5)
# ============================================================
$sys3 = Join-Path $AtlasLatestAll "System\recommended_3leg.csv"
$sys4 = Join-Path $AtlasLatestAll "System\recommended_4leg.csv"
$sys5 = Join-Path $AtlasLatestAll "System\recommended_5leg.csv"

$sysBest = @()
if (Test-Path -LiteralPath $sys3) { $x = Build-OneSlipFromCsv $sys3 "System" 3 $auditMap; if ($null -ne $x) { $sysBest += $x } }
if (Test-Path -LiteralPath $sys4) { $x = Build-OneSlipFromCsv $sys4 "System" 4 $auditMap; if ($null -ne $x) { $sysBest += $x } }
if (Test-Path -LiteralPath $sys5) { $x = Build-OneSlipFromCsv $sys5 "System" 5 $auditMap; if ($null -ne $x) { $sysBest += $x } }

if (@($sysBest).Count -lt 1) {
  throw "System CSVs missing/empty. Expected at least one of: $sys3 / $sys4 / $sys5"
}

$systemStagePath = Join-Path $StageDir "recommended_latest.json"
Write-JsonFile $systemStagePath @($sysBest)
Write-Host ("System built from CSV: 3leg={0} 4leg={1} 5leg={2} => slips={3}" -f
  (Test-Path -LiteralPath $sys3), (Test-Path -LiteralPath $sys4), (Test-Path -LiteralPath $sys5), @($sysBest).Count
)

# ============================================================
# Windfall — BUILD FROM CSVs (array of 3 rows: 3/4/5)
# ============================================================
$wf3 = Join-Path $AtlasLatestAll "Windfall\recommended_3leg.csv"
$wf4 = Join-Path $AtlasLatestAll "Windfall\recommended_4leg.csv"
$wf5 = Join-Path $AtlasLatestAll "Windfall\recommended_5leg.csv"

$wfBest = @()
if (Test-Path -LiteralPath $wf3) { $x = Build-OneSlipFromCsv $wf3 "Windfall" 3 $auditMap; if ($null -ne $x) { $wfBest += $x } }
if (Test-Path -LiteralPath $wf4) { $x = Build-OneSlipFromCsv $wf4 "Windfall" 4 $auditMap; if ($null -ne $x) { $wfBest += $x } }
if (Test-Path -LiteralPath $wf5) { $x = Build-OneSlipFromCsv $wf5 "Windfall" 5 $auditMap; if ($null -ne $x) { $wfBest += $x } }

Write-Host ("Windfall built from CSV: 3leg={0} 4leg={1} 5leg={2} => slips={3}" -f
  (Test-Path -LiteralPath $wf3), (Test-Path -LiteralPath $wf4), (Test-Path -LiteralPath $wf5), @($wfBest).Count
)

$wfStagePath = Join-Path $StageDir "recommended_windfall_latest.json"
Write-JsonFile $wfStagePath @($wfBest)

# ============================================================
# GameScript — array (pulled if exists; else empty array)
# ============================================================
$gsStagePath  = Join-Path $StageDir "recommended_gamescript_latest.json"
$gsExportPath = Join-Path $AtlasDashDir "recommended_gamescript_latest.json"

if (Test-Path -LiteralPath $gsExportPath) {
  $gsObj = Read-JsonFile $gsExportPath
  if ($null -eq $gsObj) {
    Write-Host "GameScript exported JSON unreadable; publishing empty array."
    Write-JsonFile $gsStagePath (,@())
  } else {
    Write-Host "GameScript pulled from Atlas JSON."
    Write-JsonFile $gsStagePath $gsObj
  }
} else {
  Write-Host "GameScript: no exported JSON found; publishing empty array."
  Write-JsonFile $gsStagePath (,@())
}

# ============================================================
# Legacy risky placeholders — arrays
# ============================================================
Write-JsonFile (Join-Path $StageDir "recommended_risky_latest.json")       (,@())
Write-JsonFile (Join-Path $StageDir "recommended_risky_3leg_latest.json") (,@())
Write-JsonFile (Join-Path $StageDir "recommended_risky_4leg_latest.json") (,@())
Write-JsonFile (Join-Path $StageDir "recommended_risky_5leg_latest.json") (,@())
Write-Host "Risky placeholders staged"

# ============================================================
# Publish stage -> live
# ============================================================
Write-Host "Publishing staged files to $LiveDir"
Write-Host "Cleaning $LiveDir"
Clear-DirFiles $LiveDir

$stageFiles = Get-ChildItem -LiteralPath $StageDir -File -ErrorAction Stop
foreach ($f in $stageFiles) {
  Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $LiveDir $f.Name) -Force
}

foreach ($fp in @(
  (Join-Path $LiveDir "recommended_latest.json"),
  (Join-Path $LiveDir "recommended_windfall_latest.json"),
  (Join-Path $LiveDir "recommended_gamescript_latest.json")
)) {
  if (-not (Test-Path -LiteralPath $fp)) { throw "Publish missing expected file: $fp" }
  if ($null -eq (Read-JsonFile $fp)) { throw "Published unreadable JSON: $fp" }
}

Write-Host "Publish OK (JSON validated)"

# ============================================================
# Git publish
# ============================================================
Write-Host "Git: add public/data"
git -C $RepoRoot add "public/data"

$porcelain = git -C $RepoRoot status --porcelain
if ([string]::IsNullOrWhiteSpace($porcelain)) {
  Write-Host "Git: no changes to commit/push (ok)"
  Write-Host "Done."
  exit 0
}

Write-Host "Git: commit"
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
git -C $RepoRoot commit -m "Publish data ($ts)"

Write-Host "Git: push"
git -C $RepoRoot push

Write-Host "Done."