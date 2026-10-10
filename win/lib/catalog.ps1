# ==============================================================================
#  catalog — the same catalog/apps.tsv as Linux and macOS, resolved for Windows.
#
#  On Windows only win= targets count, plus all= targets of the kinds that work
#  everywhere (npm, builtin, none). A "homebrew" dependency means Scoop here.
# ==============================================================================

$script:CatOrder = New-Object System.Collections.Generic.List[string]
$script:CatTitle = @{}
$script:ItemOrder = New-Object System.Collections.Generic.List[string]
$script:Items = @{}
$script:Res = @{}
$script:Why = @{}

function Import-SkCatalog {
  $script:CatOrder.Clear(); $script:ItemOrder.Clear(); $script:Items.Clear()
  foreach ($line in [IO.File]::ReadAllLines((Join-SkPath $script:Root 'catalog' 'apps.tsv'))) {
    if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
    if ($line.StartsWith('@cat ')) {
      $kv = $line.Substring(5).Split('|', 2)
      $script:CatOrder.Add($kv[0]); $script:CatTitle[$kv[0]] = $kv[1]
      continue
    }
    $f = $line.Split('|')
    if ($f.Count -lt 5) { continue }
    $needs = @()
    if ($f.Count -gt 5 -and $f[5]) { $needs = $f[5].Split(',') }
    $script:ItemOrder.Add($f[0])
    $script:Items[$f[0]] = @{ Cat = $f[1]; Name = $f[2]; Desc = $f[3]; Spec = $f[4]; Needs = $needs }
  }
}

function Resolve-SkSpec([string]$Id) {
  $best = ''; $rank = 0
  foreach ($tok in ($script:Items[$Id].Spec -split '\s+')) {
    if (-not $tok.Contains('=')) { continue }
    $t, $s = $tok.Split('=', 2)
    $kind = $s.Split(':')[0]
    $r = 0
    if ($t -eq $script:DISTRO_ID) { $r = 4 }
    elseif ($t -eq $script:FAMILY -or $t -eq $script:OS) { $r = 3 }
    elseif ($t -eq 'all' -and @('npm', 'builtin', 'none') -contains $kind) { $r = 1 }
    if ($r -gt $rank) { $rank = $r; $best = $s }
  }
  return $best
}

function Get-SkWhy([string]$Id, [string]$Spec) {
  if (-not $Spec) { return 'not offered on Windows' }
  $kind = $Spec.Split(':')[0]
  switch ($kind) {
    'none' { return 'not available on Windows' }
    { $_ -eq 'scoop' -or $_ -eq 'npm' } {
      if (-not (Test-SkScoopSupported)) { return "Scoop doesn't run as administrator — start serverkit from a normal PowerShell" }
    }
  }
  if ($Id -eq 'scoop' -and -not (Test-SkScoopSupported)) { return "Scoop doesn't run as administrator — start serverkit from a normal PowerShell" }
  return ''
}

function Initialize-SkResolution {
  foreach ($id in $script:ItemOrder) {
    $s = Resolve-SkSpec $id
    $script:Res[$id] = $s
    $script:Why[$id] = Get-SkWhy $id $s
  }
}

function Get-SkKind([string]$Id) { return ("$($script:Res[$Id])").Split(':')[0] }
function Test-SkSystemItem([string]$Id) { return ((Get-SkKind $Id) -eq 'psadmin') }
function Test-SkAvailable([string]$Id) { return (-not $script:Why[$Id]) }

function Get-SkDeps([string]$Id) {
  $d = New-Object System.Collections.Generic.List[string]
  foreach ($n in $script:Items[$Id].Needs) {
    if (-not $n) { continue }
    if ($n -eq 'homebrew') { $n = 'scoop' }   # the user package manager, here
    $d.Add($n)
  }
  if ($Id -eq 'essentials') { $d.Add('scoop') }   # on Windows, Essentials comes from Scoop
  switch (Get-SkKind $Id) {
    'scoop' { $d.Add('scoop') }
    'winget' { $d.Add('winget') }
    'npm' { $d.Add('runtimes') }
  }
  return @($d | Where-Object { $_ -ne $Id } | Select-Object -Unique)
}

# Resolve-SkPlan IDS -> @{ Plan = [ids in catalog order]; Skipped = [ids] }
function Resolve-SkPlan([string[]]$Ids) {
  $want = @{}
  $queue = New-Object System.Collections.Generic.Queue[string]
  foreach ($i in $Ids) { $queue.Enqueue($i) }
  while ($queue.Count -gt 0) {
    $id = $queue.Dequeue()
    if ($want.ContainsKey($id)) { continue }
    if (-not $script:Items.ContainsKey($id)) { Stop-Sk "unknown item '$id' — see: serverkit list" }
    $want[$id] = $true
    foreach ($d in (Get-SkDeps $id)) { $queue.Enqueue($d) }
  }
  $plan = New-Object System.Collections.Generic.List[string]
  $skipped = New-Object System.Collections.Generic.List[string]
  $skip = @{}
  foreach ($id in $script:ItemOrder) {
    if (-not $want.ContainsKey($id)) { continue }
    $blocked = $false
    foreach ($d in (Get-SkDeps $id)) { if ($skip.ContainsKey($d)) { $blocked = $true } }
    if (-not $blocked -and (Test-SkAvailable $id)) { $plan.Add($id) } else { $skipped.Add($id); $skip[$id] = $true }
  }
  return @{ Plan = @($plan); Skipped = @($skipped) }
}

function Get-SkCatalogJson {
  $items = foreach ($id in $script:ItemOrder) {
    [ordered]@{
      id = $id; category = $script:Items[$id].Cat; name = $script:Items[$id].Name; description = $script:Items[$id].Desc
      method = $script:Res[$id]; scope = $(if (Test-SkSystemItem $id) { 'system' } else { 'user' })
      reason = $script:Why[$id]; needs = ((Get-SkDeps $id) -join ' '); available = (Test-SkAvailable $id)
    }
  }
  $cats = foreach ($c in $script:CatOrder) { [ordered]@{ id = $c; title = $script:CatTitle[$c] } }
  $o = [ordered]@{
    platform   = [ordered]@{ os = 'win'; family = 'win'; distro = $script:DistroName; arch = $script:Arch }
    categories = @($cats); items = @($items)
  }
  return ($o | ConvertTo-Json -Depth 5 -Compress)
}
