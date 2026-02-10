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

$AtlasDashDir = Join-Path $AtlasRoot "data\output\dashboard"

$SrcPayload = Join-Path $AtlasDashDir "cloudflare_payload.json"
$DstPayload = Join-Path $StageDir   "cloudflare_payload.json"

# Keep these for legacy UI / quick status
$SrcStatus = Join-Path $AtlasDashDir "status_latest.json"
$SrcInvalidations = Join-Path $AtlasDashDir "invalidations_latest.json"
$SrcInjuryInvalid = Join-Path $AtlasDashDir "injury_invalidations_latest.json"


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

function Copy-If-Exists([string]$Src, [string]$DstDir) {
  if (Test-Path -LiteralPath $Src) {
    Copy-Item -LiteralPath $Src -Destination (Join-Path $DstDir (Split-Path -Leaf $Src)) -Force
    return $true
  }
  return $false
}

# ============================================================
# Stage build
# ============================================================
Write-Host "Staging into $StageDir (safe publish; live data not deleted until stage succeeds)"
Ensure-Dir $StageDir
Ensure-Dir $LiveDir
Clear-DirFiles $StageDir

if (-not (Test-Path -LiteralPath $SrcPayload)) {
  throw "Missing canonical payload from Atlas: $SrcPayload"
}

Copy-Item -LiteralPath $SrcPayload -Destination $DstPayload -Force

# Validate payload shape
$payload = Read-JsonFile $DstPayload
if ($null -eq $payload) { throw "Payload is unreadable JSON: $DstPayload" }

# Must contain these keys (arrays allowed empty)
foreach ($k in @("system","windfall","gamescript")) {
  if (-not ($payload.PSObject.Properties.Name -contains $k)) {
    throw "Payload missing key '$k' in cloudflare_payload.json"
  }
}

# Optional: stage status / invalidations if present
$stagedStatus = Copy-If-Exists $SrcStatus $StageDir
$stagedInv    = Copy-If-Exists $SrcInvalidations $StageDir
$stagedInjInv = Copy-If-Exists $SrcInjuryInvalid $StageDir

Write-Host ("Staged payload + status={0} invalidations={1} injury_invalidations={2}" -f $stagedStatus,$stagedInv,$stagedInjInv)

# For backward compatibility with old UI links: publish empty arrays safely
Write-JsonFile (Join-Path $StageDir "recommended_latest.json")              (,@())
Write-JsonFile (Join-Path $StageDir "recommended_windfall_latest.json")     (,@())
Write-JsonFile (Join-Path $StageDir "recommended_gamescript_latest.json")   (,@())
Write-JsonFile (Join-Path $StageDir "recommended_risky_latest.json")        (,@())
Write-JsonFile (Join-Path $StageDir "recommended_risky_3leg_latest.json")   (,@())
Write-JsonFile (Join-Path $StageDir "recommended_risky_4leg_latest.json")   (,@())
Write-JsonFile (Join-Path $StageDir "recommended_risky_5leg_latest.json")   (,@())

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

# Validate live payload exists and is readable
$livePayload = Join-Path $LiveDir "cloudflare_payload.json"
if (-not (Test-Path -LiteralPath $livePayload)) { throw "Publish missing payload: $livePayload" }
if ($null -eq (Read-JsonFile $livePayload)) { throw "Published unreadable payload JSON: $livePayload" }

Write-Host "Publish OK (payload JSON validated)"

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