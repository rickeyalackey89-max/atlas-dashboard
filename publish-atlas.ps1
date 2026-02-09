param(
  [Parameter(Mandatory=$false)]
  [string]$AtlasRoot = "C:\Users\rick\projects\Atlas",

  [Parameter(Mandatory=$false)]
  [string]$DashboardRoot = ""
)

# Resolve script root (PowerShell 5.1-safe)
if ([string]::IsNullOrWhiteSpace($DashboardRoot)) {
  if ($PSScriptRoot) { $DashboardRoot = $PSScriptRoot }
  elseif ($PSCommandPath) { $DashboardRoot = (Split-Path -Parent $PSCommandPath) }
  elseif ($MyInvocation.MyCommand.Definition) { $DashboardRoot = (Split-Path -Parent $MyInvocation.MyCommand.Definition) }
  else { $DashboardRoot = (Get-Location).Path }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m) { Write-Host $m }
function Warn([string]$m) { Write-Warning $m }

function Ensure-Dir([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) {
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}

function Read-Json([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  return ($raw | ConvertFrom-Json)
}

function Write-Json([object]$obj, [string]$path) {
  $json = $obj | ConvertTo-Json -Depth 50
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
}

function Split-Legs([string]$legsStr) {
  if ([string]::IsNullOrWhiteSpace($legsStr)) { return @() }
  return ($legsStr -split '\s*\|\s*')
}

function Parse-LegText([string]$s) {
  $out = [ordered]@{
    id        = $null
    player    = $null
    direction = $null
    stat      = $null
    line      = $null
    leg_text  = $s
    last5_hits = $null
  }

  if ($s -match '\[id:(\d+)\]') {
    $out.id = [int]$matches[1]
  }

  if ($s -match '^(.*?)\s+(OVER|UNDER)\s+([A-Z0-9\+]+)\s+([0-9]+(?:\.[0-9]+)?)') {
    $out.player    = ($matches[1]).Trim()
    $out.direction = $matches[2]
    $out.stat      = $matches[3]
    $out.line      = [double]$matches[4]
  }

  return [pscustomobject]$out
}

function Normalize-RecommendedLatest([object]$recLatestRaw) {
  # Always return object with properties: system, windfall, gamescript
  if ($null -eq $recLatestRaw) { return $null }

  # If it is an array, treat it as windfall-only legacy export
  if ($recLatestRaw -is [System.Collections.IEnumerable] -and -not ($recLatestRaw -is [string])) {
    return [pscustomobject]@{
      system     = @()
      windfall   = @($recLatestRaw)
      gamescript = @()
    }
  }

  # Ensure properties exist
  if (-not ($recLatestRaw.PSObject.Properties.Name -contains 'system'))     { $recLatestRaw | Add-Member -NotePropertyName system     -NotePropertyValue @() }
  if (-not ($recLatestRaw.PSObject.Properties.Name -contains 'windfall'))   { $recLatestRaw | Add-Member -NotePropertyName windfall   -NotePropertyValue @() }
  if (-not ($recLatestRaw.PSObject.Properties.Name -contains 'gamescript')) { $recLatestRaw | Add-Member -NotePropertyName gamescript -NotePropertyValue @() }

  # Coerce null -> empty arrays
  if ($null -eq $recLatestRaw.system)     { $recLatestRaw.system = @() }
  if ($null -eq $recLatestRaw.windfall)   { $recLatestRaw.windfall = @() }
  if ($null -eq $recLatestRaw.gamescript) { $recLatestRaw.gamescript = @() }

  # Coerce single object -> array
  $recLatestRaw.system     = @($recLatestRaw.system)
  $recLatestRaw.windfall   = @($recLatestRaw.windfall)
  $recLatestRaw.gamescript = @($recLatestRaw.gamescript)

  return $recLatestRaw
}

function Parse-Series([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return @() }
  $parts = ($s -split '\s*\|\s*') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  $out = @()
  foreach ($p in $parts) {
    $v = $null
    if ([double]::TryParse(($p.Trim()), [ref]$v)) { $out += [double]$v }
  }
  return ,$out
}

function Build-AuditMap([string]$auditCsvPath) {
  $map = @{}
  if (-not (Test-Path -LiteralPath $auditCsvPath)) {
    Warn "Missing audit CSV: $auditCsvPath"
    return $map
  }

  $rows = Import-Csv -LiteralPath $auditCsvPath
  foreach ($r in @($rows)) {
    if ($null -eq $r) { continue }

    $rp = ($r.resolved_player | ForEach-Object { "$_".Trim() })
    $bp = ($r.board_player | ForEach-Object { "$_".Trim() })

    $obj = [pscustomobject]@{
      resolved_player = $rp
      board_player    = $bp
      pts  = Parse-Series $r.last5_pts
      reb  = Parse-Series $r.last5_reb
      ast  = Parse-Series $r.last5_ast
      fg3m = Parse-Series $r.last5_fg3m
    }

    if (-not [string]::IsNullOrWhiteSpace($rp)) { $map[$rp.ToLowerInvariant()] = $obj }
    if (-not [string]::IsNullOrWhiteSpace($bp)) { $map[$bp.ToLowerInvariant()] = $obj }
  }

  return $map
}

function Get-StatSeries([object]$audit, [string]$stat) {
  if ($null -eq $audit) { return @() }
  $s = ($stat | ForEach-Object { "$_".Trim().ToUpperInvariant() })

  if ($s -eq 'PTS')  { return ,@($audit.pts) }
  if ($s -eq 'REB')  { return ,@($audit.reb) }
  if ($s -eq 'AST')  { return ,@($audit.ast) }
  if ($s -eq 'FG3M') { return ,@($audit.fg3m) }

  # combos
  $out = @()

  if ($s -eq 'PR') {
    $n = [Math]::Min(@($audit.pts).Count, @($audit.reb).Count)
    $i = 0
    foreach ($idx in 0..($n-1)) { $out += (@($audit.pts)[$i] + @($audit.reb)[$i]); $i++ }
    return ,$out
  }

  if ($s -eq 'PA') {
    $n = [Math]::Min(@($audit.pts).Count, @($audit.ast).Count)
    $i = 0
    foreach ($idx in 0..($n-1)) { $out += (@($audit.pts)[$i] + @($audit.ast)[$i]); $i++ }
    return ,$out
  }

  if ($s -eq 'RA') {
    $n = [Math]::Min(@($audit.reb).Count, @($audit.ast).Count)
    $i = 0
    foreach ($idx in 0..($n-1)) { $out += (@($audit.reb)[$i] + @($audit.ast)[$i]); $i++ }
    return ,$out
  }

  if ($s -eq 'PRA') {
    $n = @($audit.pts).Count
    $n = [Math]::Min($n, @($audit.reb).Count)
    $n = [Math]::Min($n, @($audit.ast).Count)
    $i = 0
    foreach ($idx in 0..($n-1)) { $out += (@($audit.pts)[$i] + @($audit.reb)[$i] + @($audit.ast)[$i]); $i++ }
    return ,$out
  }

  return @()
}

function Compute-Last5Hits([double[]]$series, [string]$direction, [double]$line) {
  if ($null -eq $series -or @($series).Count -eq 0) { return $null }
  $dir = ($direction | ForEach-Object { "$_".Trim().ToUpperInvariant() })
  $hits = 0

  foreach ($v in @($series)) {
    if ($dir -eq 'OVER') {
      if ($v -gt $line) { $hits++ }
    } elseif ($dir -eq 'UNDER') {
      if ($v -lt $line) { $hits++ }
    }
  }

  return $hits
}

function Ensure-LegsDetail([object]$slip) {
  if ($null -eq $slip) { return }

  if ($slip.PSObject.Properties.Name -contains 'legs_detail') {
    if ($null -eq $slip.legs_detail) { $slip.legs_detail = @() }
    $slip.legs_detail = @($slip.legs_detail)
    return
  }

  # fallback: parse from legs string
  $legsStr = $null
  if ($slip.PSObject.Properties.Name -contains 'legs') { $legsStr = $slip.legs }
  elseif ($slip.PSObject.Properties.Name -contains 'legs_str') { $legsStr = $slip.legs_str }

  $legs = @()
  foreach ($t in Split-Legs "$legsStr") {
    $legs += (Parse-LegText "$t")
  }

  $slip | Add-Member -NotePropertyName legs_detail -NotePropertyValue @($legs)
}

function Enrich-Slip-Last5([object]$slip, [hashtable]$auditMap) {
  if ($null -eq $slip) { return }
  Ensure-LegsDetail $slip

  foreach ($leg in @($slip.legs_detail)) {
    if ($null -eq $leg) { continue }

    # leg fields (defensive)
    $player = $null
    $stat = $null
    $direction = $null
    $line = $null

    if ($leg.PSObject.Properties.Name -contains 'player')    { $player = $leg.player }
    if ($leg.PSObject.Properties.Name -contains 'stat')      { $stat = $leg.stat }
    if ($leg.PSObject.Properties.Name -contains 'direction') { $direction = $leg.direction }
    if ($leg.PSObject.Properties.Name -contains 'line')      { $line = $leg.line }

    if ([string]::IsNullOrWhiteSpace("$player") -or [string]::IsNullOrWhiteSpace("$stat") -or [string]::IsNullOrWhiteSpace("$direction") -or $null -eq $line) {
      # try parse from leg_text if exists
      if ($leg.PSObject.Properties.Name -contains 'leg_text') {
        $parsed = Parse-LegText "$($leg.leg_text)"
        if ($null -eq $player)    { $player = $parsed.player }
        if ($null -eq $stat)      { $stat = $parsed.stat }
        if ($null -eq $direction) { $direction = $parsed.direction }
        if ($null -eq $line)      { $line = $parsed.line }
      }
    }

    $key = ("$player".Trim().ToLowerInvariant())
    if ([string]::IsNullOrWhiteSpace($key)) { continue }

    $audit = $null
    if ($auditMap.ContainsKey($key)) { $audit = $auditMap[$key] }
    if ($null -eq $audit) {
      # no match => leave null
      if (-not ($leg.PSObject.Properties.Name -contains 'last5_hits')) {
        $leg | Add-Member -NotePropertyName last5_hits -NotePropertyValue $null
      } else {
        $leg.last5_hits = $null
      }
      continue
    }

    $series = Get-StatSeries $audit "$stat"
    $hits = $null
    try {
      $hits = Compute-Last5Hits -series @($series) -direction "$direction" -line ([double]$line)
    } catch {
      $hits = $null
    }

    if (-not ($leg.PSObject.Properties.Name -contains 'last5_hits')) {
      $leg | Add-Member -NotePropertyName last5_hits -NotePropertyValue $hits
    } else {
      $leg.last5_hits = $hits
    }
  }
}

# ----------------------------
# Paths
# ----------------------------
$PublicData = Join-Path $DashboardRoot 'public\data'
Ensure-Dir $PublicData

Info "Cleaning $PublicData"
Get-ChildItem -LiteralPath $PublicData -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

$AtlasDash = Join-Path $AtlasRoot 'data\output\dashboard'
$RecPath   = Join-Path $AtlasDash 'recommended_latest.json'
$StatPath  = Join-Path $AtlasDash 'status_latest.json'
$InvPath   = Join-Path $AtlasDash 'invalidations_latest.json'

# ----------------------------
# Load source JSONs from Atlas
# ----------------------------
$recRaw = Read-Json $RecPath

# Support wrapper export: { generated_at, row_count, data:[...] }
if ($null -ne $recRaw -and ($recRaw.PSObject.Properties.Name -contains 'data')) {
  $recRaw = @($recRaw.data)
}

$rec = Normalize-RecommendedLatest $recRaw

$status = Read-Json $StatPath
if ($null -eq $status) { $status = [pscustomobject]@{ ok=$false; note="missing status_latest.json" } }

$inv = Read-Json $InvPath
if ($null -eq $inv) { $inv = @() } else { $inv = @($inv) }

# ----------------------------
# Build audit map (last5)
# ----------------------------
$AuditPath = Join-Path $AtlasRoot 'data\gamelogs\audit_last5_board.csv'
$auditMap = Build-AuditMap $AuditPath
Info ("Last5 audit: players={0}" -f @($auditMap.Keys).Count)

# ----------------------------
# Enrich legs_detail with last5_hits
# ----------------------------
foreach ($grpName in @('system','windfall','gamescript')) {
  $grp = $rec.$grpName
  if ($null -eq $grp) { $rec.$grpName = @(); continue }

  $newArr = @()
  foreach ($slip in @($grp)) {
    if ($null -eq $slip) { continue }
    Enrich-Slip-Last5 $slip $auditMap
    $newArr += $slip
  }
  $rec.$grpName = @($newArr)
}

# ----------------------------
# Write outputs expected by UI
# ----------------------------
Write-Json $rec     (Join-Path $PublicData 'recommended_latest.json')
Write-Json @($rec.system)     (Join-Path $PublicData 'recommended_system_latest.json')
Write-Json @($rec.windfall)   (Join-Path $PublicData 'recommended_windfall_latest.json')
Write-Json @($rec.gamescript) (Join-Path $PublicData 'recommended_gamescript_latest.json')

Write-Json $status  (Join-Path $PublicData 'status_latest.json')
Write-Json @($inv)  (Join-Path $PublicData 'invalidations_latest.json')

# Legacy risky placeholders (keep UI happy) — ONLY risky files
"" | Out-File -LiteralPath (Join-Path $PublicData 'recommended_risky_latest.json') -Encoding UTF8
"" | Out-File -LiteralPath (Join-Path $PublicData 'invalidations_risky_latest.json') -Encoding UTF8
"" | Out-File -LiteralPath (Join-Path $PublicData 'status_risky_latest.json') -Encoding UTF8

# Re-write correct non-empty system/gamescript after placeholders (order matters with Force)
Write-Json @($rec.system)     (Join-Path $PublicData 'recommended_system_latest.json')
Write-Json @($rec.gamescript) (Join-Path $PublicData 'recommended_gamescript_latest.json')

# ----------------------------
# Validate JSON parses
# ----------------------------
$null = Read-Json (Join-Path $PublicData 'recommended_latest.json')
$null = Read-Json (Join-Path $PublicData 'recommended_windfall_latest.json')
Info "JSON validation passed."

# ----------------------------
# Git publish public/data
# ----------------------------
Info "Publishing to git..."
git -C $DashboardRoot add --all public/data | Out-Null
$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
git -C $DashboardRoot commit -m "Publish data ($ts)" | Out-Null
git -C $DashboardRoot push | Out-Null
Info "Done."