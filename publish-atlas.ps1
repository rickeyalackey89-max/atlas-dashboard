# publish-atlas.ps1
# Hardened publisher: pull-first, validate, fail-loud, then push.
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\publish-atlas.ps1 "C:\Users\rick\projects\Atlas"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$msg) {
  Write-Host "ERROR: $msg" -ForegroundColor Red
  exit 1
}

function Info([string]$msg) {
  Write-Host $msg -ForegroundColor Cyan
}

function Ok([string]$msg) {
  Write-Host $msg -ForegroundColor Green
}

# --- Args (newborn-proof) ---
$AtlasPath = $args[0]
if (-not $AtlasPath) {
  Fail 'Usage: powershell -ExecutionPolicy Bypass -File .\publish-atlas.ps1 "C:\Path\To\Atlas"'
}

# Defaults (edit only if your folders differ)
$DashboardDataPath = "public\data"

# --- 0) Confirm we're in the AtlasDashboard git repo ---
$gitTop = (git rev-parse --show-toplevel 2>$null)
if (-not $gitTop) { Fail "Not inside a git repository. cd into AtlasDashboard first." }

Set-Location $gitTop
Info "Repo root: $gitTop"

# Ensure public exists (Cloudflare expects it)
if (-not (Test-Path (Join-Path $gitTop "public"))) {
  Fail "Missing 'public/' at repo root. Cloudflare build output expects it."
}

# Ensure target data dir exists
$targetDataDir = Join-Path $gitTop $DashboardDataPath
if (-not (Test-Path $targetDataDir)) {
  Fail "Dashboard data directory not found: $targetDataDir"
}

# Guard: refuse if merge/rebase in progress
$gitDir = (git rev-parse --git-dir)
$rebaseOrMergeInProgress = (
  (Test-Path (Join-Path $gitDir "rebase-merge")) -or
  (Test-Path (Join-Path $gitDir "rebase-apply")) -or
  (Test-Path (Join-Path $gitDir "MERGE_HEAD"))
)
if ($rebaseOrMergeInProgress) {
  Fail "Git merge/rebase in progress. Finish it before publishing."
}

# Guard: ensure working tree is clean BEFORE pull
$statusPorcelain = (git status --porcelain)
if ($statusPorcelain) {
  Fail "Working tree not clean BEFORE pull. Commit/stash changes first.`n$statusPorcelain"
}

# --- 1) Pull first ---
Info "Pulling latest from origin/main (rebase)..."
git pull --rebase

# Double-check clean after pull
$statusPorcelain = (git status --porcelain)
if ($statusPorcelain) {
  Fail "Working tree not clean AFTER pull. Resolve conflicts first.`n$statusPorcelain"
}

# --- 2) Locate Atlas latest/all JSON source ---
$atlasRoot = (Resolve-Path $AtlasPath).Path
if (-not (Test-Path $atlasRoot)) { Fail "AtlasPath not found: $atlasRoot" }

$sourceDir = Join-Path $atlasRoot "data\output\latest\all"
if (-not (Test-Path $sourceDir)) { Fail "Atlas latest/all path not found: $sourceDir" }

Info "Atlas latest/all source: $sourceDir"
Info "Dashboard target data:   $targetDataDir"

# --- 3) Copy *_latest.json (fail if none found) ---
$jsonFiles = Get-ChildItem -Path $sourceDir -Filter "*_latest.json" -File -ErrorAction Stop
if (-not $jsonFiles -or $jsonFiles.Count -eq 0) {
  Fail "No *_latest.json files found in: $sourceDir. Did Atlas export JSON to latest/all?"
}

Info ("Copying {0} JSON files..." -f $jsonFiles.Count)
foreach ($f in $jsonFiles) {
  Copy-Item -Path $f.FullName -Destination (Join-Path $targetDataDir $f.Name) -Force
}

# --- 4) Validate JSON (parse + conflict markers) ---
Info "Validating JSON integrity..."
$targetJson = Get-ChildItem -Path $targetDataDir -Filter "*_latest.json" -File -ErrorAction Stop

foreach ($f in $targetJson) {
  $raw = Get-Content -Path $f.FullName -Raw

  if ($raw -match '<<<<<<<|=======|>>>>>>>' ) {
    Fail "Merge conflict markers found in JSON: $($f.FullName)"
  }

  try {
    $null = $raw | ConvertFrom-Json
  } catch {
    Fail "Invalid JSON (parse failed): $($f.FullName)`n$($_.Exception.Message)"
  }
}

Ok "JSON validation passed."

# --- 5) Commit + push if changes exist ---
git add $DashboardDataPath

$changes = (git diff --cached --name-only)
if (-not $changes) {
  Ok "No changes to publish (nothing staged). Exiting cleanly."
  exit 0
}

$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$msg = "Publish Atlas data ($ts)"

Info "Committing: $msg"
git commit -m $msg

Info "Pushing to origin/main..."
git push

Ok "Publish complete. Cloudflare Pages should auto-deploy this commit."