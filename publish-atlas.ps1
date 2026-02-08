# publish-atlas.ps1
# Pull-first, export CSV->JSON into Dashboard, validate, commit, push.
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\publish-atlas.ps1 "C:\Users\rick\projects\Atlas"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Info([string]$msg) { Write-Host $msg -ForegroundColor Cyan }
function Ok([string]$msg) { Write-Host $msg -ForegroundColor Green }

$AtlasPath = $args[0]
if (-not $AtlasPath) {
  Fail 'Usage: powershell -ExecutionPolicy Bypass -File .\publish-atlas.ps1 "C:\Path\To\Atlas"'
}

$DashboardDataPath = "public\data"

# --- 0) Ensure we're in AtlasDashboard repo ---
$gitTop = (git rev-parse --show-toplevel 2>$null)
if (-not $gitTop) { Fail "Not inside a git repo. cd into AtlasDashboard first." }
Set-Location $gitTop
Info "Repo root: $gitTop"

if (-not (Test-Path (Join-Path $gitTop "public"))) { Fail "Missing public/ at repo root." }
$targetDataDir = Join-Path $gitTop $DashboardDataPath
if (-not (Test-Path $targetDataDir)) { Fail "Dashboard data dir not found: $targetDataDir" }

# Guard: no merge/rebase
$gitDir = (git rev-parse --git-dir)
if ((Test-Path (Join-Path $gitDir "rebase-merge")) -or (Test-Path (Join-Path $gitDir "rebase-apply")) -or (Test-Path (Join-Path $gitDir "MERGE_HEAD"))) {
  Fail "Git merge/rebase in progress. Finish it before publishing."
}

# Guard: generated data should never block publishing.
# If ONLY dashboard data files are dirty, auto-revert them to restore a clean tree.
$status = (git status --porcelain)
if ($status) {
  $lines = @($status -split "`n") | Where-Object { $_ -and $_.Trim().Length -gt 0 }
  $onlyDashboardData = $true
  foreach ($l in $lines) {
    # porcelain format: "XY path" (path starts at index 3)
    $p = $l.Substring(3).Trim()
    if (-not ($p -like "public/data/*")) {
      $onlyDashboardData = $false
      break
    }
  }
  if ($onlyDashboardData) {
    Info "Working tree has local changes only under public/data/. Reverting generated artifacts..."
    git restore --worktree --staged $DashboardDataPath 2>$null
    $status = (git status --porcelain)
  }
}

# Guard: clean before pull
if ($status) { Fail "Working tree not clean BEFORE pull.`n$status" }

# --- 1) Pull first ---
Info "Pulling latest from origin/main (rebase)..."
git pull --rebase

$status = (git status --porcelain)
if ($status) { Fail "Working tree not clean AFTER pull.`n$status" }

# --- 2) Source directories in Atlas ---
$atlasRoot = (Resolve-Path $AtlasPath).Path
$latestAll = Join-Path $atlasRoot "data\output\latest\all"
$latestWindfall = Join-Path $latestAll "Windfall"
$latestSystem   = Join-Path $latestAll "System"
$latestAI       = Join-Path $latestAll "AI"
$latestCapper   = Join-Path $latestAll "Capper"
$latestRisky    = Join-Path $latestAll "risky"   # legacy (may not exist)

if (-not (Test-Path $latestAll)) { Fail "Atlas latest/all not found: $latestAll" }
if (-not (Test-Path $latestSystem)) { Fail "Atlas latest/all/System not found: $latestSystem" }
if (-not (Test-Path $latestWindfall)) { Fail "Atlas latest/all/Windfall not found: $latestWindfall" }

Info "Atlas latest/all:          $latestAll"
Info "Atlas latest/all/System:   $latestSystem"
Info "Atlas latest/all/Windfall: $latestWindfall"

if (Test-Path $latestAI) {
  Info "Atlas latest/all/AI:       $latestAI"
} else {
  Info "Atlas latest/all/AI:       (missing)"
}
if (Test-Path $latestCapper) {
  Info "Atlas latest/all/Capper:   $latestCapper"
} else {
  Info "Atlas latest/all/Capper:   (missing)"
}

if (Test-Path $latestRisky) {
  Info "Atlas latest/all/risky (legacy): $latestRisky"
} else {
  Info "Atlas latest/all/risky (legacy): (missing)"
}
Info "Dashboard target data:     $targetDataDir"


# --- 3) Helper: CSV -> JSON array of rows ---
function Export-CsvToJson([string]$csvPath, [string]$jsonPath) {
  if (-not (Test-Path $csvPath)) { Fail "Missing CSV: $csvPath" }
  $rows = Import-Csv -Path $csvPath
  $json = $rows | ConvertTo-Json -Depth 10
  Set-Content -Path $jsonPath -Value $json -Encoding UTF8
}

function Write-EmptyJsonArray([string]$jsonPath) {
  Set-Content -Path $jsonPath -Value "[]" -Encoding UTF8
}

# --- 4) Export recommendations (3 groups) ---
#   1) Atlas (System): base model picks (standard modifiers / light rules)
#   2) Windfall: tier-mix rules (G/S/D) for higher payout optional bets
#   3) GameScript: external human+AI picks scored by Atlas math, no tier skew
#
# We keep legacy risky JSON outputs as empty arrays for backwards compatibility.

function Export-CsvToJsonIfExists([string]$csvPath, [string]$jsonPath) {
  if (-not (Test-Path $csvPath)) { Write-EmptyJsonArray -jsonPath $jsonPath; return }
  Export-CsvToJson -csvPath $csvPath -jsonPath $jsonPath
}

function Export-CombinedExternalToJson([string[]]$csvPaths, [string]$jsonPath) {
  $all = @()
  foreach ($p in $csvPaths) {
    if (Test-Path $p) {
      $rows = Import-Csv -Path $p
      foreach ($r in $rows) {
        # annotate provenance
        $r | Add-Member -NotePropertyName "_source_csv" -NotePropertyValue (Split-Path $p -Leaf) -Force
        $all += $r
      }
    }
  }

  if (-not $all -or $all.Count -eq 0) {
    Write-EmptyJsonArray -jsonPath $jsonPath
    return
  }

  # sort best-first: hit_prob desc, then ev_mult desc (numeric-safe)
  $sorted =
    $all | Sort-Object `
      @{ Expression = { try { [double]$_.hit_prob } catch { -1 } }; Descending = $true }, `
      @{ Expression = { try { [double]$_.ev_mult }  catch { -1 } }; Descending = $true }

  ($sorted | ConvertTo-Json -Depth 10) | Set-Content -Path $jsonPath -Encoding UTF8
}

$exports = @(
  # Atlas System (base)
  @{ csv = (Join-Path $latestSystem "recommended_3leg.csv");  json = (Join-Path $targetDataDir "recommended_3leg_latest.json"); required = $true;  group = "atlas_system" }
  @{ csv = (Join-Path $latestSystem "recommended_4leg.csv");  json = (Join-Path $targetDataDir "recommended_4leg_latest.json"); required = $true;  group = "atlas_system" }
  @{ csv = (Join-Path $latestSystem "recommended_5leg.csv");  json = (Join-Path $targetDataDir "recommended_5leg_latest.json"); required = $true;  group = "atlas_system" }

  # Windfall (tier-mix)
  @{ csv = (Join-Path $latestWindfall "recommended_3leg.csv"); json = (Join-Path $targetDataDir "windfall_recommended_3leg_latest.json"); required = $true; group = "windfall" }
  @{ csv = (Join-Path $latestWindfall "recommended_4leg.csv"); json = (Join-Path $targetDataDir "windfall_recommended_4leg_latest.json"); required = $true; group = "windfall" }
  @{ csv = (Join-Path $latestWindfall "recommended_5leg.csv"); json = (Join-Path $targetDataDir "windfall_recommended_5leg_latest.json"); required = $true; group = "windfall" }

  # GameScript (external picks scored by Atlas math) — combined AI + Capper if present
  @{ csv = ""; json = (Join-Path $targetDataDir "gamescript_best_3leg.json"); required = $false; group = "gamescript" }
  @{ csv = ""; json = (Join-Path $targetDataDir "gamescript_best_4leg.json"); required = $false; group = "gamescript" }
  @{ csv = ""; json = (Join-Path $targetDataDir "gamescript_best_5leg.json"); required = $false; group = "gamescript" }

  # Legacy risky outputs: publish empty arrays.
  @{ csv = ""; json = (Join-Path $targetDataDir "risky_recommended_3leg_latest.json"); required = $false; group = "legacy_risky" }
  @{ csv = ""; json = (Join-Path $targetDataDir "risky_recommended_4leg_latest.json"); required = $false; group = "legacy_risky" }
  @{ csv = ""; json = (Join-Path $targetDataDir "risky_recommended_5leg_latest.json"); required = $false; group = "legacy_risky" }
)

Info ("Exporting {0} outputs -> JSON..." -f $exports.Count)

# export atlas + windfall
foreach ($e in $exports) {
  if ($e.group -eq "atlas_system" -or $e.group -eq "windfall") {
    Export-CsvToJsonIfExists -csvPath $e.csv -jsonPath $e.json
  }
}

# export gamescript combined
Export-CombinedExternalToJson -csvPaths @(
  (Join-Path $latestAI "recommended_3leg.csv"),
  (Join-Path $latestCapper "recommended_3leg.csv")
) -jsonPath (Join-Path $targetDataDir "gamescript_best_3leg.json")

Export-CombinedExternalToJson -csvPaths @(
  (Join-Path $latestAI "recommended_4leg.csv"),
  (Join-Path $latestCapper "recommended_4leg.csv")
) -jsonPath (Join-Path $targetDataDir "gamescript_best_4leg.json")

Export-CombinedExternalToJson -csvPaths @(
  (Join-Path $latestAI "recommended_5leg.csv"),
  (Join-Path $latestCapper "recommended_5leg.csv")
) -jsonPath (Join-Path $targetDataDir "gamescript_best_5leg.json")

# legacy risky = empty
Write-EmptyJsonArray -jsonPath (Join-Path $targetDataDir "risky_recommended_3leg_latest.json")
Write-EmptyJsonArray -jsonPath (Join-Path $targetDataDir "risky_recommended_4leg_latest.json")
Write-EmptyJsonArray -jsonPath (Join-Path $targetDataDir "risky_recommended_5leg_latest.json")

# --- 5) Write status_latest.json (freshness + file list) ---
# --- freshness + file list ---

$filesStatus = @()
foreach ($e in $exports) {
  if (Test-Path $e.json) {
    $j = Get-Item -Path $e.json
    $filesStatus += @{
      name = (Split-Path $e.json -Leaf)
      exists = $true
      bytes = $j.Length
      last_modified = $j.LastWriteTime.ToString("s")
    }
  } else {
    $filesStatus += @{
      name = (Split-Path $e.json -Leaf)
      exists = $false
      bytes = 0
      last_modified = $null
    }
  }
}

$statusObj = @{
  generated_at = (Get-Date).ToUniversalTime().ToString("s") + "Z"
  ok = $true
  atlas_latest_all = $latestAll
  atlas_latest_system = $latestSystem
  atlas_latest_windfall = $latestWindfall
  atlas_latest_ai = $(if (Test-Path $latestAI) { $latestAI } else { $null })
  atlas_latest_capper = $(if (Test-Path $latestCapper) { $latestCapper } else { $null })
  files = $filesStatus
  notes = "Published 3 groups: Atlas System (recommended_*), Windfall (windfall_recommended_*), and GameScript (gamescript_best_*) combined from AI+Capper when available. Legacy risky JSONs are published as empty arrays."
}

$statusJsonPath = Join-Path $targetDataDir "status_latest.json"
($statusObj | ConvertTo-Json -Depth 10) | Set-Content -Path $statusJsonPath -Encoding UTF8

# --- 6) Validate JSON (parse + conflict markers) ---
Info "Validating JSON integrity..."
$toValidate = @($exports.json + $statusJsonPath)
foreach ($p in $toValidate) {
  $raw = Get-Content -Path $p -Raw
  if ($raw -match '<<<<<<<|=======|>>>>>>>' ) { Fail "Merge conflict markers found: $p" }
  try { $null = $raw | ConvertFrom-Json } catch { Fail "Invalid JSON: $p`n$($_.Exception.Message)" }
}
Ok "JSON validation passed."

# --- 7) Commit + push if changes exist ---
git add $DashboardDataPath
$changes = (git diff --cached --name-only)
if (-not $changes) { Ok "No changes to publish. Exiting cleanly."; exit 0 }

$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$msg = "Publish Atlas data ($ts)"
Info "Committing: $msg"
git commit -m $msg

Info "Pushing..."
git push

Ok "Publish complete. Cloudflare Pages will auto-deploy this commit."