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
$latestRisky = Join-Path $latestAll "risky"   # legacy (may not exist)

if (-not (Test-Path $latestAll)) { Fail "Atlas latest/all not found: $latestAll" }
if (-not (Test-Path $latestWindfall)) { Fail "Atlas latest/all/Windfall not found: $latestWindfall" }

Info "Atlas latest/all:       $latestAll"
Info "Atlas latest/all/Windfall: $latestWindfall"
if (Test-Path $latestRisky) {
  Info "Atlas latest/all/risky (legacy): $latestRisky"
} else {
  Info "Atlas latest/all/risky (legacy): (missing)"
}
Info "Dashboard target data:  $targetDataDir"

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

# --- 4) Export recommendations (Windfall-only contract) ---
# Keep legacy risky JSON outputs as empty arrays for backwards compatibility.
$exports = @(
  @{ csv = (Join-Path $latestWindfall "recommended_3leg.csv"); json = (Join-Path $targetDataDir "recommended_3leg_latest.json"); required = $true }
  @{ csv = (Join-Path $latestWindfall "recommended_4leg.csv"); json = (Join-Path $targetDataDir "recommended_4leg_latest.json"); required = $true }
  @{ csv = (Join-Path $latestWindfall "recommended_5leg.csv"); json = (Join-Path $targetDataDir "recommended_5leg_latest.json"); required = $true }

  # Legacy risky outputs: Atlas is Windfall-only now, so publish empty arrays.
  @{ csv = ""; json = (Join-Path $targetDataDir "risky_recommended_3leg_latest.json"); required = $false }
  @{ csv = ""; json = (Join-Path $targetDataDir "risky_recommended_4leg_latest.json"); required = $false }
  @{ csv = ""; json = (Join-Path $targetDataDir "risky_recommended_5leg_latest.json"); required = $false }
)

Info ("Exporting {0} outputs -> JSON..." -f $exports.Count)
foreach ($e in $exports) {
  if ($e.csv -and (Test-Path $e.csv)) {
    Export-CsvToJson -csvPath $e.csv -jsonPath $e.json
  } else {
    Write-EmptyJsonArray -jsonPath $e.json
  }
}

# --- 5) Write status_latest.json (freshness + file list) ---
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
  latest_dir = $latestWindfall
  ok = $true
  files = $filesStatus
  notes = "Generated by publish-atlas.ps1 from Atlas Windfall CSV outputs. Legacy risky JSONs are published as empty arrays."
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