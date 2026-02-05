param(
  [string]$AtlasOutDir = "C:\Users\rick\projects\Atlas\data\output\dashboard",
  [string]$DashboardRepoDir = "C:\Users\rick\projects\AtlasDashboard",
  [string]$DataDir = "public\data"
)

$ErrorActionPreference = "Stop"

# --- Source files ---
$srcRecommended = Join-Path $AtlasOutDir "recommended_latest.json"
$srcStatus      = Join-Path $AtlasOutDir "status_latest.json"
$srcInvalid     = Join-Path $AtlasOutDir "invalidations_latest.json"

# Back-compat: some runs may produce recommend_latest.json
if (-not (Test-Path $srcRecommended)) {
  $alt = Join-Path $AtlasOutDir "recommend_latest.json"
  if (Test-Path $alt) { $srcRecommended = $alt }
}

# --- Destination dir in dashboard repo ---
$destDataDir = Join-Path $DashboardRepoDir $DataDir

# --- Validate inputs ---
foreach ($p in @($srcRecommended, $srcStatus, $srcInvalid)) {
  if (-not (Test-Path $p)) { throw "Missing source file: $p" }
}
if (-not (Test-Path $DashboardRepoDir)) { throw "Missing dashboard repo dir: $DashboardRepoDir" }

# --- Ensure destination exists ---
if (-not (Test-Path $destDataDir)) {
  New-Item -ItemType Directory -Path $destDataDir | Out-Null
}

# --- Copy files ---
Copy-Item $srcRecommended (Join-Path $destDataDir "recommended_latest.json") -Force
Copy-Item $srcStatus      (Join-Path $destDataDir "status_latest.json") -Force
Copy-Item $srcInvalid     (Join-Path $destDataDir "invalidations_latest.json") -Force

# --- Sanity: files not empty ---
Get-ChildItem (Join-Path $destDataDir "*_latest.json") | ForEach-Object {
  if ($_.Length -le 5) { throw "File looks too small/empty: $($_.FullName)" }
}

# --- Git commit + push (dashboard repo only) ---
Set-Location $DashboardRepoDir

git add "$DataDir\recommended_latest.json" "$DataDir\status_latest.json" "$DataDir\invalidations_latest.json" | Out-Null

# No-op guard: if nothing changed, exit cleanly
if (-not (git status --porcelain)) {
  Write-Host "No changes to publish."
  exit 0
}

$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
git commit -m "Publish Atlas data ($stamp)" | Out-Null
git push origin main | Out-Null

Write-Host "Published Atlas data at $stamp"