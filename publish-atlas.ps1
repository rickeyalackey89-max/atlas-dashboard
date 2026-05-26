param(
  [string]$AtlasRoot = "C:\Users\13142\Atlas\NBA",
  [ValidateSet("nba","mlb")]
  [string]$Sport = "nba",
  [string]$DashboardOutputDir = "",
  [switch]$NoGit,
  [string]$PremiumKvNamespaceId = $env:ATLAS_PREMIUM_KV_NAMESPACE_ID,
  [string]$PremiumKvKey = "",
  [switch]$ForcePublicPremiumPayload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# Paths
# ============================================================
$RepoRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$PublicDir = Join-Path $RepoRoot "public"
$StageRoot = Join-Path $RepoRoot ".publish_stage"

$Sport = $Sport.ToLowerInvariant()
$StageDir = Join-Path $StageRoot $Sport
if ([string]::IsNullOrWhiteSpace($PremiumKvKey)) {
  $PremiumKvKey = "premium:${Sport}:dashboard:latest"
}
if ([string]::IsNullOrWhiteSpace($DashboardOutputDir)) {
  if ($Sport -eq "mlb") {
    $DashboardOutputDir = Join-Path $AtlasRoot "data\mlb\output\dashboard"
  } else {
    $DashboardOutputDir = Join-Path $AtlasRoot "data\output\dashboard"
  }
}

$LiveDir = if ($Sport -eq "mlb") {
  Join-Path (Join-Path $PublicDir "data") "mlb"
} else {
  Join-Path $PublicDir "data"
}

$AtlasDashDir = $DashboardOutputDir

$SrcPayload = Join-Path $AtlasDashDir "cloudflare_payload.json"
$DstPayload = Join-Path $LiveDir    "cloudflare_payload.json"

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

function Invoke-Git([string[]]$GitArgs, [string]$Label) {
  & git @GitArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Git failed during ${Label}: git $($GitArgs -join ' ')"
  }
}

function Invoke-Wrangler([string[]]$WranglerArgs, [string]$Label) {
  & npx wrangler @WranglerArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Wrangler failed during ${Label}: npx wrangler $($WranglerArgs -join ' ')"
  }
}

function Resolve-PremiumKvNamespaceId([string]$ExistingId) {
  if (-not [string]::IsNullOrWhiteSpace($ExistingId)) { return $ExistingId }
  $configPath = Join-Path $RepoRoot "wrangler.toml"
  if (-not (Test-Path -LiteralPath $configPath)) { return "" }
  $raw = Get-Content -LiteralPath $configPath -Raw -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($raw)) { return "" }
  $matches = [regex]::Matches($raw, '(?s)\[\[kv_namespaces\]\]\s*binding\s*=\s*"([^"]+)"\s*id\s*=\s*"([^"]+)"')
  foreach ($m in $matches) {
    if ($m.Groups[1].Value -eq "ATLAS_PREMIUM_KV") {
      return $m.Groups[2].Value
    }
  }
  return ""
}

$PremiumKvNamespaceId = Resolve-PremiumKvNamespaceId $PremiumKvNamespaceId

# ============================================================
# Preflight
# ============================================================
if (-not (Test-Path -LiteralPath $AtlasRoot)) {
  throw "AtlasRoot does not exist: $AtlasRoot"
}
if (-not (Test-Path -LiteralPath $AtlasDashDir)) {
  throw "Atlas dashboard output directory does not exist: $AtlasDashDir"
}
if (-not (Test-Path -LiteralPath $SrcPayload)) {
  throw "Missing canonical payload from Atlas: $SrcPayload"
}

Write-Host "Sport: $Sport"
Write-Host "AtlasRoot: $AtlasRoot"
Write-Host "Dashboard output: $AtlasDashDir"

# ============================================================
# Stage build
# ============================================================
Write-Host "Staging into $StageDir (safe publish; live data not deleted until stage succeeds)"
Ensure-Dir $StageDir
Ensure-Dir $LiveDir
Clear-DirFiles $StageDir

$StagePayload = Join-Path $StageDir (Split-Path -Leaf $SrcPayload)
Copy-Item -LiteralPath $SrcPayload -Destination $StagePayload -Force

# Validate payload shape
$payload = Read-JsonFile $StagePayload
if ($null -eq $payload) { throw "Payload is unreadable JSON: $DstPayload" }

# Must contain these keys (arrays allowed empty)
foreach ($k in @("system","windfall","gamescript")) {
  if (-not ($payload.PSObject.Properties.Name -contains $k)) {
    throw "Payload missing key '$k' in cloudflare_payload.json"
  }
}
foreach ($k in @("all_legs","generated_at","run_id")) {
  if (-not ($payload.PSObject.Properties.Name -contains $k)) {
    throw "Payload missing key '$k' in cloudflare_payload.json"
  }
}
try {
  if ($payload.generated_at -is [datetime]) {
    $generatedAt = [datetime]$payload.generated_at
  } else {
    $generatedAt = [datetime]::Parse(($payload.generated_at + ""), [System.Globalization.CultureInfo]::InvariantCulture)
  }
} catch {
  throw "Payload generated_at is not parseable: $($payload.generated_at)"
}
Write-Host ("Payload run_id={0} generated_at={1:o} age_minutes={2:n1} all_legs={3}" -f $payload.run_id,$generatedAt,((Get-Date)-$generatedAt).TotalMinutes,@($payload.all_legs).Count)

# Optional: stage status / invalidations if present
$stagedStatus = Copy-If-Exists $SrcStatus $StageDir
$stagedInv    = Copy-If-Exists $SrcInvalidations $StageDir
$stagedInjInv = Copy-If-Exists $SrcInjuryInvalid $StageDir

Write-Host ("Staged payload + status={0} invalidations={1} injury_invalidations={2}" -f $stagedStatus,$stagedInv,$stagedInjInv)

# Build lightweight picks_today.json (~10KB) for homepage
$picksFields = @("player","team","opp","stat","line","dir","tier","p_cal")
$allLegs = @($payload.all_legs)
# Guarantee 1 pick per tier (GOBLIN, STANDARD, DEMON), while avoiding alternate
# lines for the same player across the three public homepage cards.
$tierOrder = @('GOBLIN','STANDARD','DEMON')
$selected = [System.Collections.Generic.List[object]]::new()
$selectedKeys = @{}
$usedPlayers = @{}
function Leg-Key($leg) {
  return (($leg.player + '') + '|' + ($leg.stat + '') + '|' + ($leg.line + '') + '|' + ($leg.tier + '')).ToLower()
}
function Player-Key($leg) {
  return ($leg.player + '').Trim().ToLower()
}
foreach ($tier in $tierOrder) {
  $tierRows = @($allLegs | Where-Object { (($_.tier + '').ToUpper()) -eq $tier })
  $pick = $null
  foreach ($leg in $tierRows) {
    $pk = Player-Key $leg
    if ($pk -and -not $usedPlayers.ContainsKey($pk)) { $pick = $leg; break }
  }
  if ($null -eq $pick -and $tierRows.Count -gt 0) { $pick = $tierRows[0] }
  if ($null -ne $pick) {
    $selected.Add($pick)
    $selectedKeys[(Leg-Key $pick)] = $true
    $pk = Player-Key $pick
    if ($pk) { $usedPlayers[$pk] = $true }
  }
}
foreach ($leg in $allLegs) {
  if ($selected.Count -ge 50) { break }
  $key = Leg-Key $leg
  $pk = Player-Key $leg
  if ($selectedKeys.ContainsKey($key)) { continue }
  if ($pk -and $usedPlayers.ContainsKey($pk)) { continue }
  $selected.Add($leg)
  $selectedKeys[$key] = $true
  if ($pk) { $usedPlayers[$pk] = $true }
}
foreach ($leg in $allLegs) {
  if ($selected.Count -ge 50) { break }
  $key = Leg-Key $leg
  if (-not $selectedKeys.ContainsKey($key)) {
    $selected.Add($leg)
    $selectedKeys[$key] = $true
  }
}
$topLegs = @($selected)
$picksRows = foreach ($leg in $topLegs) {
    $row = [ordered]@{}
    foreach ($f in $picksFields) {
      $prop = $leg.PSObject.Properties[$f]
      $row[$f] = if ($null -ne $prop) { $prop.Value } else { $null }
    }
    $row
}
$systemCount    = if ($payload.system)        { @($payload.system).Count }        else { 0 }
$windfallCount  = if ($payload.windfall)      { @($payload.windfall).Count }      else { 0 }
$demonCount     = if ($payload.demonhunter)   { @($payload.demonhunter).Count }   else { 0 }
$marketedCount  = if ($payload.marketed_slips){ @($payload.marketed_slips).Count } else { 0 }
$picksPayload  = [ordered]@{
    generated_at = $payload.generated_at
    run_id       = $payload.run_id
    sport        = $Sport.ToUpperInvariant()
    model_engaged_at = if ($payload.PSObject.Properties["model_engaged_at"]) { $payload.model_engaged_at } else { $null }
    model_engaged_at_local = if ($payload.PSObject.Properties["model_engaged_at_local"]) { $payload.model_engaged_at_local } else { $null }
    model_engaged_label = if ($payload.PSObject.Properties["model_engaged_label"]) { $payload.model_engaged_label } else { $null }
    picks        = @($picksRows)
    total_legs   = $allLegs.Count
    total_slips  = $systemCount + $windfallCount + $demonCount + $marketedCount
}
Write-JsonFile (Join-Path $StageDir "picks_today.json") $picksPayload
Write-Host ("Built picks_today.json: {0} picks, {1} total_legs" -f @($picksRows).Count, $allLegs.Count)

# For backward compatibility with old UI links: publish empty arrays safely
Write-JsonFile (Join-Path $StageDir "recommended_latest.json")              (,@())
Write-JsonFile (Join-Path $StageDir "recommended_windfall_latest.json")     (,@())
Write-JsonFile (Join-Path $StageDir "recommended_gamescript_latest.json")   (,@())
Write-JsonFile (Join-Path $StageDir "recommended_risky_latest.json")        (,@())
Write-JsonFile (Join-Path $StageDir "recommended_risky_3leg_latest.json")   (,@())
Write-JsonFile (Join-Path $StageDir "recommended_risky_4leg_latest.json")   (,@())
Write-JsonFile (Join-Path $StageDir "recommended_risky_5leg_latest.json")   (,@())

# ============================================================
# Private premium publish
# ============================================================
if ($PremiumKvNamespaceId -and -not $ForcePublicPremiumPayload) {
  Write-Host "Premium KV configured: uploading cloudflare_payload.json to KV key '$PremiumKvKey'"
  Invoke-Wrangler -WranglerArgs @(
    "kv", "key", "put", $PremiumKvKey,
    "--namespace-id", $PremiumKvNamespaceId,
    "--path", $StagePayload,
    "--remote"
  ) -Label "premium KV upload"

  $stub = [ordered]@{
    ok = $false
    error = "premium_data_moved"
    message = "Premium dashboard payload is served through /api/premium-data after auth."
    api = "/api/premium-data?dataset=dashboard&sport=$Sport"
    public_preview = if ($Sport -eq "mlb") { "/data/mlb/picks_today.json" } else { "/data/picks_today.json" }
    generated_at = $payload.generated_at
    run_id = $payload.run_id
    model_engaged_at = if ($payload.PSObject.Properties["model_engaged_at"]) { $payload.model_engaged_at } else { $null }
    model_engaged_at_local = if ($payload.PSObject.Properties["model_engaged_at_local"]) { $payload.model_engaged_at_local } else { $null }
    model_engaged_label = if ($payload.PSObject.Properties["model_engaged_label"]) { $payload.model_engaged_label } else { $null }
  }
  Write-JsonFile $StagePayload $stub
  Write-Host "Public cloudflare_payload.json replaced with private-data stub."
} else {
  Write-Warning "Premium KV namespace not configured; publishing cloudflare_payload.json publicly as a compatibility fallback."
  Write-Warning "Set ATLAS_PREMIUM_KV_NAMESPACE_ID and bind ATLAS_PREMIUM_KV in Cloudflare Pages to remove the public premium payload."
}

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
if ($NoGit) {
  Write-Host "NoGit set: staged/live files validated; skipping git commit/push."
  Write-Host "Done."
  exit 0
}

Write-Host "Git: add public/data"
Invoke-Git -GitArgs @("-C", $RepoRoot, "add", "public/data") -Label "add public/data"

$stagedChanged = $true
& git -C $RepoRoot diff --cached --quiet -- "public/data"
if ($LASTEXITCODE -eq 0) {
  $stagedChanged = $false
} elseif ($LASTEXITCODE -eq 1) {
  $stagedChanged = $true
} else {
  throw "Git failed during staged diff check"
}

if (-not $stagedChanged) {
  Write-Host "Git: no changes to commit/push (ok)"
  Write-Host "Done."
  exit 0
}

Write-Host "Git: commit"
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Invoke-Git -GitArgs @("-C", $RepoRoot, "commit", "-m", "Publish data ($ts)") -Label "commit"

Write-Host "Git: push"
Invoke-Git -GitArgs @("-C", $RepoRoot, "push") -Label "push"

Write-Host "Done."
