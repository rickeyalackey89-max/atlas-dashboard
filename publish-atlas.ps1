<#
publish-atlas.ps1 (PowerShell 5.1)

Usage:
  powershell -ExecutionPolicy Bypass -File .\publish-atlas.ps1 "..\Atlas"

Contract:
  1) Atlas System  -> public/data/recommended_{3,4,5}leg_latest.json
  2) Windfall      -> public/data/windfall_recommended_{3,4,5}leg_latest.json
  3) GameScript    -> public/data/gamescript_best_{3,4,5}leg.json (AI + Capper combined)
  Legacy risky JSONs written as empty arrays for compatibility.

Git hygiene:
  - Only auto-cleans public/data
  - If anything else is dirty, script stops.
#>

param(
  [Parameter(Mandatory=$true, Position=0)]
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
  # Normalize to array of non-empty strings; .Count always valid
  $a = @($raw)
  $a = $a | Where-Object { $_ -ne $null -and $_.ToString().Trim() -ne "" }
  return @($a)
}

function Is-OnlyPublicDataDirty([string[]]$lines) {
  $lines = @($lines)
  if ($lines.Count -eq 0) { return $true }
  foreach ($l in $lines) {
    $path = $l.Substring(3).Trim()
    if (-not ($path -like "public/data/*")) { return $false }
  }
  return $true
}

function Clean-PublicData([string]$repoRoot) {
  $pd = Join-Path $repoRoot "public\data"
  if (-not (Test-Path $pd)) { New-Item -ItemType Directory -Path $pd | Out-Null }

  & git -C $repoRoot restore --worktree --staged -- "public/data" 2>$null | Out-Null
  & git -C $repoRoot clean -fd -- "public/data" 2>$null | Out-Null
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

function Sort-ObjectsBestFirst($rows) {
  $rows = @($rows)
  if ($rows.Count -eq 0) { return @() }

  $cands = @("ev","slip_ev","score","p_combo","p_adj","p_hit","hit_prob","prob","p")
  $cols = @{}
  foreach ($pr in $rows[0].PSObject.Properties) { $cols[$pr.Name.ToLower()] = $pr.Name }

  foreach ($k in $cands) {
    if ($cols.ContainsKey($k)) {
      $col = $cols[$k]
      $sorted = $rows | Sort-Object @{Expression = { [double]($_.$col) }; Descending = $true}
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

# Cleanliness gate (auto-fix ONLY public/data)
$porc = Normalize-Lines (Get-GitPorcelain $repoRoot)
if (-not (Is-OnlyPublicDataDirty $porc)) {
  Write-Info "ERROR: Working tree not clean BEFORE pull."
  $porc | ForEach-Object { Write-Info $_ }
  Fail "Commit/stash local changes outside public/data."
}
if ($porc.Count -gt 0) {
  Write-Info "Working tree has local changes only under public/data. Reverting generated artifacts..."
  Clean-PublicData $repoRoot
  $porc2 = Normalize-Lines (Get-GitPorcelain $repoRoot)
  if ($porc2.Count -gt 0) {
    Write-Info "ERROR: Working tree not clean BEFORE pull."
    $porc2 | ForEach-Object { Write-Info $_ }
    Fail "Unable to clean public/data automatically."
  }
}

Write-Info "Pulling latest from origin/main (rebase)..."
GitOut $repoRoot @("pull","--rebase") | Out-Null

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

Write-Info "Exporting 12 outputs -> JSON..."

# System
$rowsSys3 = Read-CsvIfExists $sys3
$rowsSys4 = Read-CsvIfExists $sys4
$rowsSys5 = Read-CsvIfExists $sys5
if (@($rowsSys3).Count -eq 0 -and @($rowsSys4).Count -eq 0 -and @($rowsSys5).Count -eq 0) {
  Fail ("System picks missing. Expected at least one of: " + $sys3 + " / " + $sys4 + " / " + $sys5)
}
Write-JsonFile $out_sys3 (@($rowsSys3))
Write-JsonFile $out_sys4 (@($rowsSys4))
Write-JsonFile $out_sys5 (@($rowsSys5))

# Windfall (ok if empty)
$rowsWf3 = Read-CsvIfExists $wf3
$rowsWf4 = Read-CsvIfExists $wf4
$rowsWf5 = Read-CsvIfExists $wf5
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
  if (@($sorted).Count -gt $topN) { return @($sorted[0..($topN-1)]) }
  return @($sorted)
}

$gs3 = Combine-GameScript $ai3 $cap3
$gs4 = Combine-GameScript $ai4 $cap4
$gs5 = Combine-GameScript $ai5 $cap5
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
  sources = @{
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
  $out_sys3,$out_sys4,$out_sys5,
  $out_wf3,$out_wf4,$out_wf5,
  $out_gs3,$out_gs4,$out_gs5,
  $out_r3,$out_r4,$out_r5,
  $out_status,$out_inval
)
foreach ($p in $toValidate) { Validate-JsonFile $p }
Write-Info "JSON validation passed."

# Commit + push public/data only
GitOut $repoRoot @("add","-A","public/data") | Out-Null
$porcAfter = Normalize-Lines (Get-GitPorcelain $repoRoot)
if ($porcAfter.Count -eq 0) {
  Write-Info "No changes to publish (public/data unchanged). Publish complete (noop)."
  exit 0
}

$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
Write-Info ("Committing: Publish Atlas data (" + $ts + ")")
GitOut $repoRoot @("commit","-m",("Publish Atlas data (" + $ts + ")")) | Out-Null

Write-Info "Pushing..."
GitOut $repoRoot @("push") | Out-Null

Write-Info "Publish complete. Cloudflare Pages will auto-deploy this commit."