<#
publish-atlas.ps1 (PowerShell 5.1)

Usage:
  powershell -ExecutionPolicy Bypass -File .\publish-atlas.ps1 -AtlasRoot "C:\Users\rick\projects\Atlas"

Contract:
  1) Atlas System  -> public/data/recommended_{3,4,5}leg_latest.json
  2) Windfall      -> public/data/windfall_recommended_{3,4,5}leg_latest.json
  3) GameScript    -> public/data/gamescript_best_{3,4,5}leg.json (AI + Capper combined)
  Legacy risky JSONs written as empty arrays for compatibility.

Hard rule:
  - Repo MUST be clean before publishing. This script does NOT auto-clean anything.
  - The only changes this script makes are generated JSONs under public/data, which it commits & pushes.

Git hygiene:
  - If anything is dirty BEFORE we start, fail immediately.
#>

param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$AtlasRoot
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

function Write-Info([string]$m) { Write-Host $m }
function Fail([string]$m) { Write-Host ("ERROR: " + $m) -ForegroundColor Red; exit 1 }

function Resolve-RepoRoot([string]$startDir) {
  $d = (Resolve-Path $startDir).Path
  while ($true) {
    if (Test-Path (Join-Path $d ".git")) { return $d }
    $parent = Split-Path $d -Parent
    if ($parent -eq $d) { break }
    $d = $parent
  }
  return $null
}

function GitOut([string]$repoRoot, [string[]]$gitArgs) {
  & git -C $repoRoot @gitArgs
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    $joined = ($gitArgs -join " ")
    Fail ("git failed (exit $code): git -C `"$repoRoot`" $joined")
  }
}

function Get-GitPorcelain([string]$repoRoot) {
  $out = & git -C $repoRoot status --porcelain 2>$null
  if ($LASTEXITCODE -ne 0) { Fail "git status --porcelain failed. Is git installed and is this a repo?" }
  return $out
}

function Normalize-Lines($raw) {
  # Always return an array of non-empty strings
  $a = @($raw)
  $a = $a | Where-Object { $_ -ne $null -and $_.ToString().Trim() -ne "" }
  return @($a)
}

function Read-CsvIfExists([string]$p) {
  if (-not (Test-Path $p)) { return @() }
  try {
    # CRITICAL: force array even for single-row CSV
    $rows = Import-Csv -Path $p
    return @($rows)
  } catch {
    Fail ("Failed to read CSV: " + $p + " :: " + $_.Exception.Message)
  }
}

function Load-Last5AuditMap([string]$atlasRoot) {
  # Returns: Hashtable[int] -> int? (last5_hits)
  $map = @{}
  $p = Join-Path $atlasRoot "data\gamelogs\audit_last5_board.csv"
  if (-not (Test-Path $p)) { return $map }

  try {
    $rows = Import-Csv -Path $p
    foreach ($r in $rows) {
      $pidRaw = $r.projection_id
      if (-not $pidRaw) { $pidRaw = $r.id }
      if (-not $pidRaw) { continue }
      [int]$projId = 0
      if (-not [int]::TryParse($pidRaw, [ref]$projId)) { continue }

      $vRaw = $r.last5_hits
      if (-not $vRaw) { $vRaw = $r.last5_hit_count }
      if (-not $vRaw) { $vRaw = $r.hit_count }

      $v = $null
      if ($vRaw -ne $null -and $vRaw -ne "") {
        [int]$tmp = 0
        if ([int]::TryParse($vRaw, [ref]$tmp)) { $v = $tmp } else { $v = $null }
      }
      $map[$projId] = $v
    }
  } catch {
    # best-effort: leave map empty
    return @{}
  }
  return $map
}

function Extract-LegIdsFromRow($row) {
  $ids = @()
  $rx = [regex]"\[id:(\d+)\]"

  foreach ($k in @("leg_1","leg_2","leg_3","leg_4","leg_5")) {
    try {
      $s = $row.$k
      if ($s) {
        $m = $rx.Match([string]$s)
        if ($m.Success) { $ids += [int]$m.Groups[1].Value }
      }
    } catch { }
  }

  if ($ids.Count -gt 0) { return $ids }

  try {
    $s = $row.legs
    if ($s) {
      foreach ($mm in $rx.Matches([string]$s)) {
        $ids += [int]$mm.Groups[1].Value
      }
    }
  } catch { }

  return $ids
}


function Add-LegsDetailAndFilter($rows, $last5Map) {
  # Adds legs_detail=[{id,last5_hits},...] to each row.
  # Drops slips where any leg has last5_hits == 0 (only when last5_hits is known).
  $out = @()
  foreach ($r in @($rows)) {
    if ($r -eq $null) { continue }

    $ids = Extract-LegIdsFromRow $r
    $detail = @()
    $drop = $false

    foreach ($projId in $ids) {
      $v = $null
      try {
        if ($last5Map.ContainsKey($projId)) { $v = $last5Map[$projId] }
      } catch { $v = $null }

      $detail += [pscustomobject]@{ id = $projId; last5_hits = $v }
      if ($v -ne $null -and $v -eq 0) { $drop = $true }
    }

    if ($detail.Count -gt 0) {
      try {
        $r | Add-Member -Force -NotePropertyName "legs_detail" -NotePropertyValue $detail
      } catch { }
    }

    if (-not $drop) { $out += $r }
  }
  return $out
}


function Sort-ObjectsBestFirst($rows) {
  $rows = @($rows)
  if (@($rows).Count -eq 0) { return @() }

  $cands = @("ev","slip_ev","score","p_combo","p_adj","p_hit","hit_prob","prob","p")
  $cols = @{}
  foreach ($pr in $rows[0].PSObject.Properties) { $cols[$pr.Name.ToLower()] = $pr.Name }

  foreach ($k in $cands) {
    if ($cols.ContainsKey($k)) {
      $col = $cols[$k]
      $sorted = $rows | Sort-Object @{ Expression = { [double]($_.$col) }; Descending = $true }
      return @($sorted)
    }
  }
  return @($rows)
}

function Write-JsonFile([string]$path, $obj) {
  $dir = Split-Path $path -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $json = $obj | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText($path, $json)
}

function Validate-JsonFile([string]$path) {
  if (-not (Test-Path $path)) { Fail ("Missing JSON after write: " + $path) }
  try {
    $txt = Get-Content -Raw -Path $path
    $null = $txt | ConvertFrom-Json
  } catch {
    Fail ("JSON validation failed for " + $path + " :: " + $_.Exception.Message)
  }
}

# -----------------------------
# Start
# -----------------------------

$repoRoot = Resolve-RepoRoot (Get-Location).Path
if (-not $repoRoot) { Fail "Could not locate repo root (.git) from current directory." }
Write-Info ("Repo root: " + $repoRoot)

try { $atlasAbs = (Resolve-Path $AtlasRoot).Path } catch { Fail ("Atlas root path not found: " + $AtlasRoot) }

# HARD CLEANLINESS GATE (no auto-clean)
$porcBefore = Normalize-Lines (Get-GitPorcelain $repoRoot)
if (@($porcBefore).Count -gt 0) {
  Write-Info "ERROR: Working tree must be clean BEFORE publishing."
  @($porcBefore) | ForEach-Object { Write-Info $_ }
  Fail "Commit or stash changes, then re-run publish."
}

Write-Info "Pulling latest from origin/main (rebase)..."
GitOut $repoRoot @("pull","--rebase") | Out-Null

# Re-check after pull (paranoia / safety)
$porcAfterPull = Normalize-Lines (Get-GitPorcelain $repoRoot)
if (@($porcAfterPull).Count -gt 0) {
  Write-Info "ERROR: Working tree became dirty after pull."
  @($porcAfterPull) | ForEach-Object { Write-Info $_ }
  Fail "Resolve git state and re-run publish."
}

# Atlas paths
$latestAll      = Join-Path $atlasAbs "data\output\latest\all"
$latestSystem   = Join-Path $latestAll "System"
$latestWindfall = Join-Path $latestAll "Windfall"
$latestAI       = Join-Path $latestAll "AI"
$latestCapper   = Join-Path $latestAll "Capper"
$latestRisky    = Join-Path $latestAll "risky"

Write-Info ("Atlas latest/all:          " + $latestAll)
Write-Info ("Atlas latest/all/System:   " + $latestSystem)
Write-Info ("Atlas latest/all/Windfall: " + $latestWindfall)
Write-Info ("Atlas latest/all/AI:       " + $latestAI)
Write-Info ("Atlas latest/all/Capper:   " + $latestCapper)
if (Test-Path $latestRisky) { Write-Info ("Atlas latest/all/risky (legacy): " + $latestRisky) } else { Write-Info "Atlas latest/all/risky (legacy): (missing)" }

if (-not (Test-Path $latestAll)) { Fail ("Atlas latest/all not found: " + $latestAll + " (Run Atlas first.)") }

$dashData = Join-Path $repoRoot "public\data"
if (-not (Test-Path $dashData)) { New-Item -ItemType Directory -Path $dashData | Out-Null }
Write-Info ("Dashboard target data:     " + $dashData)

# Sources
$sys3 = Join-Path $latestSystem   "recommended_3leg.csv"
$sys4 = Join-Path $latestSystem   "recommended_4leg.csv"
$sys5 = Join-Path $latestSystem   "recommended_5leg.csv"

$wf3  = Join-Path $latestWindfall "recommended_3leg.csv"
$wf4  = Join-Path $latestWindfall "recommended_4leg.csv"
$wf5  = Join-Path $latestWindfall "recommended_5leg.csv"

$ai3  = Join-Path $latestAI       "recommended_3leg.csv"
$ai4  = Join-Path $latestAI       "recommended_4leg.csv"
$ai5  = Join-Path $latestAI       "recommended_5leg.csv"

$cap3 = Join-Path $latestCapper   "recommended_3leg.csv"
$cap4 = Join-Path $latestCapper   "recommended_4leg.csv"
$cap5 = Join-Path $latestCapper   "recommended_5leg.csv"

# Outputs
$out_sys3 = Join-Path $dashData "recommended_3leg_latest.json"
$out_sys4 = Join-Path $dashData "recommended_4leg_latest.json"
$out_sys5 = Join-Path $dashData "recommended_5leg_latest.json"

$out_wf3  = Join-Path $dashData "windfall_recommended_3leg_latest.json"
$out_wf4  = Join-Path $dashData "windfall_recommended_4leg_latest.json"
$out_wf5  = Join-Path $dashData "windfall_recommended_5leg_latest.json"

$out_gs3  = Join-Path $dashData "gamescript_best_3leg.json"
$out_gs4  = Join-Path $dashData "gamescript_best_4leg.json"
$out_gs5  = Join-Path $dashData "gamescript_best_5leg.json"

$out_r3   = Join-Path $dashData "risky_recommended_3leg_latest.json"
$out_r4   = Join-Path $dashData "risky_recommended_4leg_latest.json"
$out_r5   = Join-Path $dashData "risky_recommended_5leg_latest.json"

$out_status = Join-Path $dashData "status_latest.json"
$out_inval  = Join-Path $dashData "invalidations_latest.json"

Write-Info "Exporting outputs -> JSON..."

$last5Map = Load-Last5AuditMap $atlasAbs

# System
$rowsSys3 = Add-LegsDetailAndFilter (Read-CsvIfExists $sys3) $last5Map
$rowsSys4 = Add-LegsDetailAndFilter (Read-CsvIfExists $sys4) $last5Map
$rowsSys5 = Add-LegsDetailAndFilter (Read-CsvIfExists $sys5) $last5Map
if (@($rowsSys3).Count -eq 0 -and @($rowsSys4).Count -eq 0 -and @($rowsSys5).Count -eq 0) {
  Fail ("System picks missing. Expected at least one of: " + $sys3 + " / " + $sys4 + " / " + $sys5)
}
Write-JsonFile $out_sys3 (@($rowsSys3))
Write-JsonFile $out_sys4 (@($rowsSys4))
Write-JsonFile $out_sys5 (@($rowsSys5))

# Windfall (ok if empty)
$rowsWf3 = Add-LegsDetailAndFilter (Read-CsvIfExists $wf3) $last5Map
$rowsWf4 = Add-LegsDetailAndFilter (Read-CsvIfExists $wf4) $last5Map
$rowsWf5 = Add-LegsDetailAndFilter (Read-CsvIfExists $wf5) $last5Map
Write-JsonFile $out_wf3 (@($rowsWf3))
Write-JsonFile $out_wf4 (@($rowsWf4))
Write-JsonFile $out_wf5 (@($rowsWf5))

# GameScript (AI + Capper combined)
function Combine-GameScript([string]$aiCsv, [string]$capCsv) {
  $a = Read-CsvIfExists $aiCsv
  $c = Read-CsvIfExists $capCsv
  $all = @()
  $all += @($a)
  $all += @($c)

  if (@($all).Count -eq 0) { return @() }

  $sorted = Sort-ObjectsBestFirst $all
  $topN = 50
  if (@($sorted).Count -gt $topN) { return @($sorted[0..($topN - 1)]) }
  return @($sorted)
}

$gs3 = Add-LegsDetailAndFilter (Combine-GameScript $ai3 $cap3) $last5Map
$gs4 = Add-LegsDetailAndFilter (Combine-GameScript $ai4 $cap4) $last5Map
$gs5 = Add-LegsDetailAndFilter (Combine-GameScript $ai5 $cap5) $last5Map
Write-JsonFile $out_gs3 (@($gs3))
Write-JsonFile $out_gs4 (@($gs4))
Write-JsonFile $out_gs5 (@($gs5))

# Legacy risky (empty)
Write-JsonFile $out_r3 @()
Write-JsonFile $out_r4 @()
Write-JsonFile $out_r5 @()

# Minimal status + invalidations (always present)
$nowIso = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$statusObj = @{
  generated_at = $nowIso
  atlas_root   = $atlasAbs
  sources      = @{
    latest_all = $latestAll
    system     = $latestSystem
    windfall   = $latestWindfall
    ai         = $latestAI
    capper     = $latestCapper
  }
  counts = @{
    system_3     = @($rowsSys3).Count
    system_4     = @($rowsSys4).Count
    system_5     = @($rowsSys5).Count
    windfall_3   = @($rowsWf3).Count
    windfall_4   = @($rowsWf4).Count
    windfall_5   = @($rowsWf5).Count
    gamescript_3 = @($gs3).Count
    gamescript_4 = @($gs4).Count
    gamescript_5 = @($gs5).Count
  }
  legacy = @{ risky_jsons = "empty arrays (deprecated)" }
}
Write-JsonFile $out_status $statusObj
Write-JsonFile $out_inval @()

# Validate
Write-Info "Validating JSON integrity..."
$toValidate = @(
  $out_sys3, $out_sys4, $out_sys5,
  $out_wf3,  $out_wf4,  $out_wf5,
  $out_gs3,  $out_gs4,  $out_gs5,
  $out_r3,   $out_r4,   $out_r5,
  $out_status, $out_inval
)
foreach ($p in $toValidate) { Validate-JsonFile $p }
Write-Info "JSON validation passed."

# Commit + push public/data only
GitOut $repoRoot @("add", "-A", "public/data") | Out-Null
$porcAfter = Normalize-Lines (Get-GitPorcelain $repoRoot)
if (@($porcAfter).Count -eq 0) {
  Write-Info "No changes to publish (public/data unchanged). Publish complete (noop)."
  exit 0
}

$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
Write-Info ("Committing: Publish Atlas data (" + $ts + ")")
GitOut $repoRoot @("commit", "-m", ("Publish Atlas data (" + $ts + ")")) | Out-Null

Write-Info "Pushing..."
GitOut $repoRoot @("push") | Out-Null

Write-Info "Publish complete. Cloudflare Pages will auto-deploy this commit."