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
  $json = $obj | ConvertTo-Json -Depth 30
  $json | Out-File -LiteralPath $path -Encoding UTF8
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

function Make-Key([string]$player, [string]$stat, [string]$direction, [object]$line) {
  $p = $(if ($null -ne $player) { [string]$player } else { '' })
  $p = ($p -replace '\s+', ' ').Trim().ToLowerInvariant()

  $s = $(if ($null -ne $stat) { [string]$stat } else { '' })
  $s = $s.Trim().ToUpperInvariant()

  $d = $(if ($null -ne $direction) { [string]$direction } else { '' })
  $d = $d.Trim().ToUpperInvariant()

  $l = ''
  if ($null -ne $line -and $line -ne '') {
    try { $l = ([double]$line).ToString('0.###') } catch { $l = "$line" }
  }

  return "$p|$s|$d|$l"
}

function Normalize-RecommendedLatest([object]$recLatestRaw) {
  # Always return object with properties: system, windfall, gamescript
  if ($null -eq $recLatestRaw) { return $null }

  # Array => treat as windfall list
  if ($recLatestRaw -is [System.Collections.IEnumerable] -and -not ($recLatestRaw -is [string])) {
    return [pscustomobject]@{
      system     = $null
      windfall   = @($recLatestRaw)
      gamescript = $null
    }
  }

  # Object => ensure properties exist (StrictMode-safe)
  if (-not ($recLatestRaw.PSObject.Properties.Name -contains 'system'))     { $recLatestRaw | Add-Member -NotePropertyName system     -NotePropertyValue $null }
  if (-not ($recLatestRaw.PSObject.Properties.Name -contains 'windfall'))   { $recLatestRaw | Add-Member -NotePropertyName windfall   -NotePropertyValue $null }
  if (-not ($recLatestRaw.PSObject.Properties.Name -contains 'gamescript')) { $recLatestRaw | Add-Member -NotePropertyName gamescript -NotePropertyValue $null }

  return $recLatestRaw
}

function Build-Leg-Lookups([object]$recommendedLatest) {
  $byId = @{}
  $byKey = @{}

  if ($null -eq $recommendedLatest) { return @{ byId=$byId; byKey=$byKey } }

  foreach ($groupName in @('system','windfall','gamescript')) {
    $grp = $recommendedLatest.$groupName
    if ($null -eq $grp) { continue }

    foreach ($slip in @($grp)) {
      if ($null -eq $slip) { continue }
      if (-not ($slip.PSObject.Properties.Name -contains 'legs_detail')) { continue }

      $ld = $slip.legs_detail
      if ($null -eq $ld) { continue }

      foreach ($leg in @($ld)) {
        if ($null -eq $leg) { continue }

        if ($leg.PSObject.Properties.Name -contains 'id' -and $null -ne $leg.id) {
          $idStr = [string]$leg.id
          if (-not $byId.ContainsKey($idStr)) { $byId[$idStr] = $leg }
        }

        $player = $null
        $stat = $null
        $direction = $null
        $line = $null

        if ($leg.PSObject.Properties.Name -contains 'player') { $player = $leg.player }
        if ($leg.PSObject.Properties.Name -contains 'stat') { $stat = $leg.stat }
        if ($leg.PSObject.Properties.Name -contains 'direction') { $direction = $leg.direction }
        if ($leg.PSObject.Properties.Name -contains 'line') { $line = $leg.line }

        $k = Make-Key $player $stat $direction $line
        if (-not [string]::IsNullOrWhiteSpace($k)) {
          if (-not $byKey.ContainsKey($k)) { $byKey[$k] = $leg }
        }
      }
    }
  }

  return @{ byId=$byId; byKey=$byKey }
}

function Enrich-LegsDetail([string]$legsStr, [hashtable]$byId, [hashtable]$byKey) {
  $out = @()

  foreach ($legText in (Split-Legs $legsStr)) {
    $parsed = Parse-LegText $legText
    $found = $null

    if ($null -ne $parsed.id) {
      $idStr = [string]$parsed.id
      if ($byId.ContainsKey($idStr)) { $found = $byId[$idStr] }
    }

    if ($null -eq $found) {
      $k = Make-Key $parsed.player $parsed.stat $parsed.direction $parsed.line
      if ($byKey.ContainsKey($k)) { $found = $byKey[$k] }
    }

    if ($null -ne $found) {
      $o = [ordered]@{
        id         = $found.id
        player     = $(if ($found.PSObject.Properties.Name -contains 'player') { $found.player } else { $parsed.player })
        stat       = $(if ($found.PSObject.Properties.Name -contains 'stat') { $found.stat } else { $parsed.stat })
        direction  = $(if ($found.PSObject.Properties.Name -contains 'direction') { $found.direction } else { $parsed.direction })
        line       = $(if ($found.PSObject.Properties.Name -contains 'line') { $found.line } else { $parsed.line })
        last5_hits = $(if ($found.PSObject.Properties.Name -contains 'last5_hits') { $found.last5_hits } else { $null })
        leg_text   = $legText
      }
      $out += [pscustomobject]$o
    }
    else {
      $o = [ordered]@{
        id         = $parsed.id
        player     = $parsed.player
        stat       = $parsed.stat
        direction  = $parsed.direction
        line       = $parsed.line
        last5_hits = $null
        leg_text   = $legText
      }
      $out += [pscustomobject]$o
    }
  }

  return ,$out
}

function Parse-NumList([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return @() }
  $parts = $s -split '\s*\|\s*'
  $nums = @()
  foreach ($p in $parts) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    try { $nums += [double]$p } catch { }
  }
  return ,$nums
}

function Build-AuditMap([string]$auditCsvPath) {
  $m = @{}
  if (-not (Test-Path -LiteralPath $auditCsvPath)) {
    Warn "Missing audit_last5_board.csv: $auditCsvPath"
    return $m
  }

  $rows = Import-Csv -LiteralPath $auditCsvPath
  foreach ($r in $rows) {
    if ($null -eq $r) { continue }
    $bp = $r.board_player
    $rp = $r.resolved_player

    $obj = [pscustomobject]@{
      board_player = $bp
      resolved_player = $rp
      pts = (Parse-NumList $r.last5_pts)
      reb = (Parse-NumList $r.last5_reb)
      ast = (Parse-NumList $r.last5_ast)
      fg3m = (Parse-NumList $r.last5_fg3m)
    }

    if (-not [string]::IsNullOrWhiteSpace($bp)) { $m[$bp.Trim().ToLowerInvariant()] = $obj }
    if (-not [string]::IsNullOrWhiteSpace($rp)) { $m[$rp.Trim().ToLowerInvariant()] = $obj }
  }

  return $m
}

function Normalize-Direction([object]$d) {
  if ($null -eq $d) { return $null }
  $ds = [string]$d
  $ds = $ds.Trim().ToUpperInvariant()
  if ($ds -eq '0' -or $ds -eq 'OVER' -or $ds -eq 'MORE') { return 'OVER' }
  if ($ds -eq '1' -or $ds -eq 'UNDER' -or $ds -eq 'LESS') { return 'UNDER' }
  return $ds
}

function Stat-Values([pscustomobject]$audit, [string]$stat) {
  if ($null -eq $audit -or [string]::IsNullOrWhiteSpace($stat)) { return @() }
  $s = $stat.Trim().ToUpperInvariant()

  if ($s -eq 'PTS') { return $audit.pts }
  if ($s -eq 'REB') { return $audit.reb }
  if ($s -eq 'AST') { return $audit.ast }
  if ($s -eq 'FG3M') { return $audit.fg3m }

  if ($s -eq 'PR') {
    $out = @()
    for ($i=0; $i -lt [Math]::Min($audit.pts.Count, $audit.reb.Count); $i++) { $out += ($audit.pts[$i] + $audit.reb[$i]) }
    return ,$out
  }
  if ($s -eq 'PA') {
    $out = @()
    for ($i=0; $i -lt [Math]::Min($audit.pts.Count, $audit.ast.Count); $i++) { $out += ($audit.pts[$i] + $audit.ast[$i]) }
    return ,$out
  }
  if ($s -eq 'RA') {
    $out = @()
    for ($i=0; $i -lt [Math]::Min($audit.reb.Count, $audit.ast.Count); $i++) { $out += ($audit.reb[$i] + $audit.ast[$i]) }
    return ,$out
  }
  if ($s -eq 'PRA') {
    $out = @()
    $n = [Math]::Min($audit.pts.Count, [Math]::Min($audit.reb.Count, $audit.ast.Count))
    for ($i=0; $i -lt $n; $i++) { $out += ($audit.pts[$i] + $audit.reb[$i] + $audit.ast[$i]) }
    return ,$out
  }

  return @()
}

function Last5-Hits([string]$player, [string]$stat, [object]$direction, [object]$line, [hashtable]$auditMap) {
  if ($null -eq $auditMap -or $auditMap.Count -eq 0) { return $null }
  if ([string]::IsNullOrWhiteSpace($player) -or [string]::IsNullOrWhiteSpace($stat) -or $null -eq $line -or $line -eq '') { return $null }

  $pkey = $player.Trim().ToLowerInvariant()
  if (-not $auditMap.ContainsKey($pkey)) { return $null }
  $audit = $auditMap[$pkey]

  $vals = Stat-Values $audit $stat
  if ($null -eq $vals -or $vals.Count -eq 0) { return $null }

  $dir = Normalize-Direction $direction
  $l = $null
  try { $l = [double]$line } catch { return $null }

  $hits = 0
  foreach ($v in $vals) {
    if ($dir -eq 'OVER') { if ([double]$v -gt $l) { $hits++ } }
    elseif ($dir -eq 'UNDER') { if ([double]$v -lt $l) { $hits++ } }
  }
  return $hits
}

function Apply-Last5([object]$legsDetail, [hashtable]$auditMap) {
  if ($null -eq $legsDetail) { return }
  foreach ($leg in @($legsDetail)) {
    if ($null -eq $leg) { continue }
    $has = ($leg.PSObject.Properties.Name -contains 'last5_hits')
    $cur = $null
    if ($has) { $cur = $leg.last5_hits }
    if ($null -ne $cur -and $cur -ne '') { continue }

    $player = $(if ($leg.PSObject.Properties.Name -contains 'player') { $leg.player } else { $null })
    $stat = $(if ($leg.PSObject.Properties.Name -contains 'stat') { $leg.stat } else { $null })
    $direction = $(if ($leg.PSObject.Properties.Name -contains 'direction') { $leg.direction } else { $null })
    $line = $(if ($leg.PSObject.Properties.Name -contains 'line') { $leg.line } else { $null })

    $h = Last5-Hits $player $stat $direction $line $auditMap
    if (-not $has) {
      $leg | Add-Member -NotePropertyName last5_hits -NotePropertyValue $h
    } else {
      $leg.last5_hits = $h
    }
  }
}

function CsvToSlipList([string]$csvPath, [string]$groupName, [hashtable]$byId, [hashtable]$byKey) {
  if (-not (Test-Path -LiteralPath $csvPath)) {
    Warn "Missing $groupName CSV: $csvPath"
    return @()
  }

  $rows = Import-Csv -LiteralPath $csvPath
  $out = @()

  foreach ($r in $rows) {
    $legs = $null
    if ($r.PSObject.Properties.Name -contains 'legs') { $legs = [string]$r.legs }
    if ([string]::IsNullOrWhiteSpace($legs) -and ($r.PSObject.Properties.Name -contains 'slip_key')) { $legs = [string]$r.slip_key }

    $obj = [ordered]@{}
    foreach ($p in $r.PSObject.Properties) { $obj[$p.Name] = $p.Value }

    $obj['legs_detail'] = (Enrich-LegsDetail $legs $byId $byKey)

    Apply-Last5 $obj['legs_detail'] $script:auditMap`n    $out += [pscustomobject]$obj
  }

  return ,$out
}

# ----------------------------
# Paths
# ----------------------------
$PublicDir = Join-Path $DashboardRoot 'public'
$DataDir   = Join-Path $PublicDir 'data'
Ensure-Dir $DataDir

$AtlasDashboardOut = Join-Path $AtlasRoot 'data\output\dashboard'
$AtlasLatestAll    = Join-Path $AtlasRoot 'data\output\latest\all'
$AtlasWindfall     = Join-Path $AtlasLatestAll 'Windfall'
$AtlasExternal     = Join-Path $AtlasLatestAll 'External'

# ----------------------------
# Clean public/data
# ----------------------------
Info "Cleaning $DataDir"
Get-ChildItem -LiteralPath $DataDir -Force -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
Ensure-Dir $DataDir

# ----------------------------
# Copy Atlas-produced JSON (source of truth = dashboard exports)
# ----------------------------
$RecLatestSrc  = Join-Path $AtlasDashboardOut 'recommended_latest.json'
$StatLatestSrc = Join-Path $AtlasDashboardOut 'status_latest.json'
$InvLatestSrc  = Join-Path $AtlasDashboardOut 'invalidations_latest.json'

$recLatestRaw = Read-Json $RecLatestSrc
if ($null -eq $recLatestRaw) {
  throw "Missing or unreadable: $RecLatestSrc"
}

Copy-Item -LiteralPath $RecLatestSrc  -Destination (Join-Path $DataDir 'recommended_latest.json')  -Force
if (Test-Path -LiteralPath $StatLatestSrc) { Copy-Item -LiteralPath $StatLatestSrc -Destination (Join-Path $DataDir 'status_latest.json') -Force }
if (Test-Path -LiteralPath $InvLatestSrc)  { Copy-Item -LiteralPath $InvLatestSrc  -Destination (Join-Path $DataDir 'invalidations_latest.json') -Force }

# Normalize to object with .system/.windfall/.gamescript
$recLatest = Normalize-RecommendedLatest $recLatestRaw

# ----------------------------
# Build lookups from whatever legs_detail already exists
# ----------------------------
$lookups = Build-Leg-Lookups $recLatest
$byId = $lookups.byId
$byKey = $lookups.byKey
Info "Lookup sizes: byId=$($byId.Count) byKey=$($byKey.Count)"

`n# Build Last-5 audit map (for last5_hits enrichment)`n$AuditPath = Join-Path $AtlasRoot 'data\gamelogs\audit_last5_board.csv'`n$script:auditMap = Build-AuditMap $AuditPath`nInfo \"Last5 audit: players=$($script:auditMap.Count)\"`n# ----------------------------
# Enrich and write group JSONs expected by UI
# ----------------------------

# SYSTEM
if ($recLatest.system -ne $null) {
  # Ensure system slips have legs_detail objects (in case some were id-only)
  $sysOut = @()
  foreach ($slip in @($recLatest.system)) {
    $legsStr = $null
    if ($slip -ne $null -and ($slip.PSObject.Properties.Name -contains 'legs')) { $legsStr = [string]$slip.legs }
    if ([string]::IsNullOrWhiteSpace($legsStr) -and $slip -ne $null -and ($slip.PSObject.Properties.Name -contains 'slip_key')) { $legsStr = [string]$slip.slip_key }
    $slip.legs_detail = (Enrich-LegsDetail $legsStr $byId $byKey)
    Apply-Last5 $slip.legs_detail $script:auditMap`n    $sysOut += $slip
  }
  Write-Json $sysOut (Join-Path $DataDir 'recommended_system_latest.json')
} else {
  Write-Json @() (Join-Path $DataDir 'recommended_system_latest.json')
}

# WINDFALL: build unified list from CSVs (3/4/5) and enrich legs_detail
$wfOut = @()

$wf3 = CsvToSlipList (Join-Path $AtlasWindfall 'recommended_3leg.csv') 'Windfall-3' $byId $byKey
$wf4 = CsvToSlipList (Join-Path $AtlasWindfall 'recommended_4leg.csv') 'Windfall-4' $byId $byKey
$wf5 = CsvToSlipList (Join-Path $AtlasWindfall 'recommended_5leg.csv') 'Windfall-5' $byId $byKey

if (@($wf3).Count -gt 0) { $wfOut += @($wf3) }
if (@($wf4).Count -gt 0) { $wfOut += @($wf4) }
if (@($wf5).Count -gt 0) { $wfOut += @($wf5) }

Write-Json $wfOut (Join-Path $DataDir 'recommended_windfall_latest.json')
Info "Windfall unified: rows=$($wfOut.Count)"

# GAMESCRIPT (prefer grouped JSON; else External drop-in; else empty)
$gsOut = @()

if ($recLatest.gamescript -ne $null) {
  foreach ($slip in @($recLatest.gamescript)) {
    $legsStr = $null
    if ($slip -ne $null -and ($slip.PSObject.Properties.Name -contains 'legs')) { $legsStr = [string]$slip.legs }
    if ([string]::IsNullOrWhiteSpace($legsStr) -and $slip -ne $null -and ($slip.PSObject.Properties.Name -contains 'slip_key')) { $legsStr = [string]$slip.slip_key }
    $slip.legs_detail = (Enrich-LegsDetail $legsStr $byId $byKey)
    Apply-Last5 $slip.legs_detail $script:auditMap`n    $gsOut += $slip
  }
}
else {
  $gsJson = Join-Path $AtlasExternal 'recommended_gamescript_latest.json'
  $gsObj = Read-Json $gsJson
  if ($null -ne $gsObj) {
    foreach ($slip in @($gsObj)) {
      $legsStr = $null
      if ($slip -ne $null -and ($slip.PSObject.Properties.Name -contains 'legs')) { $legsStr = [string]$slip.legs }
      if ([string]::IsNullOrWhiteSpace($legsStr) -and $slip -ne $null -and ($slip.PSObject.Properties.Name -contains 'slip_key')) { $legsStr = [string]$slip.slip_key }
      $slip.legs_detail = (Enrich-LegsDetail $legsStr $byId $byKey)
    Apply-Last5 $slip.legs_detail $script:auditMap`n      $gsOut += $slip
    }
  }
}

Write-Json $gsOut (Join-Path $DataDir 'recommended_gamescript_latest.json')

# Legacy empties (old UI expectations)
Write-Json @() (Join-Path $DataDir 'recommended_risky_latest.json')
Write-Json @() (Join-Path $DataDir 'status_risky_latest.json')
Write-Json @() (Join-Path $DataDir 'invalidations_risky_latest.json')

# ----------------------------
# Validate JSON parse
# ----------------------------
$null = Read-Json (Join-Path $DataDir 'recommended_latest.json')
$null = Read-Json (Join-Path $DataDir 'recommended_system_latest.json')
$null = Read-Json (Join-Path $DataDir 'recommended_windfall_latest.json')
$null = Read-Json (Join-Path $DataDir 'recommended_gamescript_latest.json')
Info "JSON validation passed."

# ----------------------------
# Git commit + push (Dashboard repo)
# ----------------------------
Info "Publishing to git..."

# Ensure clean tree outside public/data
$gitStatus = (git -C $DashboardRoot status --porcelain)
$dirtyOther = @()
foreach ($line in @($gitStatus)) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  if ($line -match 'public/data') { continue }
  $dirtyOther += $line
}
if ($dirtyOther.Count -gt 0) {
  throw "Repo has uncommitted changes outside public/data. Commit or stash first."
}

git -C $DashboardRoot add public/data | Out-Null
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$msg = "Publish data ($stamp)"
$commitOut = (git -C $DashboardRoot commit -m $msg 2>$null)
if ($LASTEXITCODE -ne 0) {
  Info "No changes to commit."
} else {
  Info $commitOut
}

git -C $DashboardRoot push | Out-Null
Info "Done."