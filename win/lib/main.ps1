# ==============================================================================
#  main — settings, commands, the wizard and the executor (Windows).
#  Same commands, flags, profiles and settings files as the bash version.
# ==============================================================================

$script:Settings = @{}
$script:SettingSrc = @{}
$script:SettingNames = New-Object System.Collections.Generic.List[string]
$script:ProfileName = ''
$script:OptSet = @()
$script:TaskMode = $false

# ------------------------------------------------------------------------------
# Settings: NAME=value lines; a "…" value may span lines; never executed.
# ------------------------------------------------------------------------------
function Read-SkSettingsFile([string]$File, [string]$Label) {
  if (-not (Test-Path -LiteralPath $File)) { return }
  $lines = [IO.File]::ReadAllLines($File)
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if (-not $line.Trim() -or $line.Trim().StartsWith('#')) { continue }
    if ($line -notmatch '^([A-Z_][A-Z0-9_]*)=(.*)$') { Write-SkWarn "${File}: ignoring line: $line"; continue }
    $key = $Matches[1]; $val = $Matches[2]
    $val = ($val -replace '\s+#.*$', '').Trim()
    if (($val.StartsWith('"') -and -not ($val.Length -gt 1 -and $val.EndsWith('"'))) -or $val -eq '"') {
      while ($i + 1 -lt $lines.Count) {
        $i++
        $val += ' ' + $lines[$i]
        if ($lines[$i].TrimEnd().EndsWith('"')) { break }
      }
    }
    if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $Matches[1] }
    $val = ($val -replace '\s+', ' ').Trim()
    if ($Label -ne 'defaults' -and -not $script:SettingSrc.ContainsKey($key)) { Write-SkWarn "${File}: unknown setting $key (typo?) — ignored"; continue }
    if ($Label -eq 'defaults') { $script:SettingNames.Add($key) }
    $script:Settings[$key] = $val
    $script:SettingSrc[$key] = $Label
  }
}

function Import-SkSettings([string]$ProfileName) {
  $script:Settings = @{}; $script:SettingSrc = @{}; $script:SettingNames.Clear()
  Read-SkSettingsFile (Join-SkPath $script:Root 'profiles' '_defaults.conf') 'defaults'
  if ($ProfileName) { Read-SkSettingsFile (Join-SkPath $script:Root "profiles" "$ProfileName.conf") "profile:$ProfileName" }
  Read-SkSettingsFile (Join-Path $script:ConfigDir 'config.conf') 'config'
  foreach ($kv in $script:OptSet) {
    if ($kv -notmatch '^([A-Z_][A-Z0-9_]*)=(.*)$') { Stop-Sk "--set expects NAME=VALUE, got: $kv" }
    if (-not $script:SettingSrc.ContainsKey($Matches[1])) { Stop-Sk "unknown setting: $($Matches[1]) (see: serverkit config)" }
    $script:Settings[$Matches[1]] = $Matches[2]; $script:SettingSrc[$Matches[1]] = '--set'
  }
}
function Get-SkSetting([string]$Name) { return "$($script:Settings[$Name])" }

function Set-SkConfig([string]$Key, [string]$Value) {
  if (-not $script:SettingSrc.ContainsKey($Key)) { Stop-Sk "unknown setting: $Key" }
  if ($script:DryRun) { return }
  $f = Join-Path $script:ConfigDir 'config.conf'
  $lines = @()
  if (Test-Path -LiteralPath $f) { $lines = @(Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_ -notmatch "^$Key=" }) }
  if (-not $lines) { $lines = @('# serverkit settings — NAME=value. All names and defaults: serverkit config') }
  $lines += ('{0}="{1}"' -f $Key, $Value.Replace('"', ''))
  Write-SkText $f ($lines -join "`n")
  $script:Settings[$Key] = $Value; $script:SettingSrc[$Key] = 'config'
}

# ------------------------------------------------------------------------------
# Context: everything a spinner runspace or the elevated process needs to
# continue this exact run.
# ------------------------------------------------------------------------------
function Export-SkContext {
  $ctx = [ordered]@{
    Root = $script:Root; Version = $script:Version; DryRun = $script:DryRun; Force = $script:Force
    VerboseRun = $script:VerboseRun; RunDir = $script:RunDir; Log = $script:Log; StateDir = $script:StateDir
    ConfigDir = $script:ConfigDir; DataDir = $script:DataDir; Settings = $script:Settings; EventsFile = $script:EventsFile
  }
  Write-SkText (Join-Path $script:RunDir 'context.json') ($ctx | ConvertTo-Json -Depth 4)
}
function Import-SkContext([string]$File) {
  $c = Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json
  $script:Root = $c.Root; $script:Version = $c.Version; $script:DryRun = [bool]$c.DryRun; $script:Force = [bool]$c.Force
  $script:VerboseRun = [bool]$c.VerboseRun; $script:RunDir = $c.RunDir; $script:Log = $c.Log; $script:StateDir = $c.StateDir
  $script:ConfigDir = $c.ConfigDir; $script:DataDir = $c.DataDir; $script:EventsFile = $c.EventsFile
  $script:Settings = @{}
  foreach ($p in $c.Settings.PSObject.Properties) { $script:Settings[$p.Name] = "$($p.Value)" }
  Initialize-SkPlatform
  Import-SkCatalog
  Initialize-SkResolution
}

# ------------------------------------------------------------------------------
# Executing
# ------------------------------------------------------------------------------
function Invoke-SkItem([string]$Id) {
  $script:CurrentItem = $Id
  $spec = "$($script:Res[$Id])"
  $kind, $arg = $spec.Split(':', 2)
  $r = $null
  try {
    switch ($kind) {
      'scoop' { $r = Install-SkScoop ($arg.Split(',')) }
      'winget' { $r = Install-SkWinget $arg }
      'npm' { $r = Install-SkNpm $arg }
      'uv' { $r = Install-SkUv $arg }
      { $_ -eq 'ps' -or $_ -eq 'psadmin' } { $r = & "item_$arg" }
      'builtin' { Write-SkSkip "$arg comes with Windows"; $r = 0 }
      default { Write-SkErr "don't know how to install $Id ($spec)"; $r = 1 }
    }
  } catch {
    Write-SkErr "$Id failed: $($_.Exception.Message)"
    $r = 1
  }
  # a function's output is everything it emitted; its code is the last value
  $last = @($r)
  if ($last.Count -eq 0) { return 0 }
  $v = $last[$last.Count - 1]
  if ($v -is [int]) { return $v }
  return 0
}

function Invoke-SkPlan([string[]]$Plan) {
  if (-not $script:DryRun) {
    $script:RunDir = Join-SkPath $script:StateDir "runs" "$script:Stamp"
    New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
    $script:Log = Join-Path $script:RunDir 'serverkit.log'
    Set-Content -LiteralPath $script:Log -Value "serverkit $($script:Version) — $(Get-Date)`nplatform: $(Get-SkPlatformLine)`nitems: $($Plan -join ' ')" -Encoding UTF8
  } else {
    $script:RunDir = Join-Path (Get-SkTemp) 'run'
    New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
  }
  Export-SkContext

  $title = "Installing $($Plan.Count) items"
  if ($script:DryRun) { $title = 'Dry run — nothing will change' }
  Show-SkTitle $title
  if (-not $script:DryRun) { Show-SkNote "  log: $($script:Log)" }
  Write-SkEvent 'run_start' @{ count = $Plan.Count; dry_run = $script:DryRun }
  $start = Get-Date
  $status = @{}

  # Items needing administrator rights run first, together, in one elevated
  # window (a single UAC prompt); everything else runs as you.
  $admin = @($Plan | Where-Object { Test-SkSystemItem $_ })
  if ($admin.Count -gt 0 -and -not $script:IsAdmin -and -not $script:DryRun) {
    Show-SkNote "  $($admin.Count) item(s) need administrator rights — Windows will ask once (UAC)."
    $ids = $admin -join ','
    try {
      $p = Start-Process -FilePath (Get-SkPowerShell) -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-SkPath $script:Root 'win' 'serverkit.ps1')`"",
        '__elevated', "`"$($script:RunDir)`"", $ids)
      [void]$p
    } catch {
      Write-SkErr 'administrator rights were declined — those items were skipped'
    }
    foreach ($id in $admin) {
      $f = Join-Path $script:RunDir "status-$id"
      $st = 'failed'
      if (Test-Path -LiteralPath $f) { $st = (Get-Content -LiteralPath $f -Encoding UTF8 | Select-Object -First 1) }
      $status[$id] = $st
      $sym = @{ ok = '  ✓'; na = '  –'; failed = '  ✗' }[$st]
      $col = @{ ok = 'Green'; na = 'Cyan'; failed = 'Red' }[$st]
      Write-SkLine $col $sym "$($script:Items[$id].Name) (as administrator)"
    }
  }

  foreach ($id in $Plan) {
    if ($status.ContainsKey($id)) { continue }
    $blocked = ''
    foreach ($d in (Get-SkDeps $id)) { if ($status[$d] -eq 'failed' -or $status[$d] -eq 'blocked') { $blocked = $d } }
    if ($blocked) {
      $status[$id] = 'blocked'
      Write-SkLine Yellow '  –' "$($script:Items[$id].Name) (skipped: needs $blocked)"
      Write-SkEvent 'item_done' @{ id = $id; status = 'blocked' }
      continue
    }
    Write-SkEvent 'item_start' @{ id = $id; name = $script:Items[$id].Name }
    $script:CurrentItem = $id
    $code = Invoke-SkTask $script:Items[$id].Name $id
    $st = 'failed'
    if ($code -eq 0) { $st = 'ok' } elseif ($code -eq $script:NA) { $st = 'na' }
    $status[$id] = $st
    Write-SkEvent 'item_done' @{ id = $id; status = $st }
  }
  $script:CurrentItem = ''
  Show-SkReport $Plan $status $start
}

function Show-SkReport([string[]]$Plan, [hashtable]$Status, [datetime]$Start) {
  $ok = @($Plan | Where-Object { $Status[$_] -eq 'ok' }).Count
  $na = @($Plan | Where-Object { $Status[$_] -eq 'na' -or $Status[$_] -eq 'blocked' }).Count
  $fail = @($Plan | Where-Object { $Status[$_] -eq 'failed' }).Count
  if ($script:DryRun) { Write-Host ''; Show-SkNote 'Dry run finished — nothing was changed. Run again without --dry-run to apply.'; return }
  $el = [int]((Get-Date) - $Start).TotalSeconds
  Show-SkTitle 'Summary'
  Write-Host ("  {0} done   {1} skipped   {2} failed   ({3}m{4}s)" -f $ok, $na, $fail, [int]($el / 60), ($el % 60))
  foreach ($id in $Plan) {
    if ($Status[$id] -eq 'failed') { Write-SkLine Red '  ✗' "$($script:Items[$id].Name) — see the log" }
    if ($Status[$id] -eq 'na') {
      $f = Join-Path $script:RunDir ".na-$id"
      $why = ''; if (Test-Path -LiteralPath $f) { $why = Get-Content -LiteralPath $f -Encoding UTF8 | Select-Object -First 1 }
      Write-SkLine Cyan '  –' "$($script:Items[$id].Name): $why"
    }
  }
  $w = Join-Path $script:RunDir 'warnings'
  if (Test-Path -LiteralPath $w) { Show-SkTitle 'Warnings'; Get-Content -LiteralPath $w -Encoding UTF8 | ForEach-Object { $p = $_.Split("`t", 2); Write-Host "  ! $($p[0]): $($p[-1])" } }
  $h = Join-Path $script:RunDir 'hints'
  if (Test-Path -LiteralPath $h) { Show-SkTitle 'Next steps'; $n = 1; Get-Content -LiteralPath $h -Encoding UTF8 | ForEach-Object { Write-Host "  $n. $_"; $n++ } }
  $pending = Get-SkPending
  if ($pending) { Show-SkTitle 'Your files were kept'; Show-SkNote "  serverkit's version is beside each one as .new — compare, or re-run with --force:"; $pending | ForEach-Object { Write-Host "    $_" } }
  Write-Host ''; Show-SkNote "log: $($script:Log)"
  Add-Content -LiteralPath (Join-Path $script:StateDir 'runs.log') -Encoding UTF8 -Value ("{0}  profile={1}  ok={2} skipped={3} failed={4}  items=[{5}]" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $(if ($script:ProfileName) { $script:ProfileName } else { 'custom' }), $ok, $na, $fail, ($Plan -join ' '))
  Write-SkEvent 'run_done' @{ ok = $ok; skipped = $na; failed = $fail }
  if ($fail -gt 0) { $script:ExitCode = 1 }
}

function Get-SkPending {
  $f = Join-Path $script:StateDir 'managed.list'
  if (-not (Test-Path -LiteralPath $f)) { return @() }
  return @(Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_ -and (Test-Path -LiteralPath "$_.new") } | ForEach-Object { "$_.new" })
}

# The elevated half of a run: started by Invoke-SkPlan through UAC.
function Invoke-SkElevated([string]$RunDir, [string]$Ids) {
  Import-SkContext (Join-Path $RunDir 'context.json')
  Write-Host 'serverkit — administrator steps' -ForegroundColor Magenta
  foreach ($id in $Ids.Split(',')) {
    $code = Invoke-SkTask $script:Items[$id].Name $id
    $st = 'failed'; if ($code -eq 0) { $st = 'ok' } elseif ($code -eq $script:NA) { $st = 'na' }
    Set-Content -LiteralPath (Join-Path $RunDir "status-$id") -Value $st -Encoding UTF8
  }
  Start-Sleep -Seconds 2
}

function Show-SkPlanAndRun($Resolved, [bool]$FromProfile) {
  $plan = $Resolved.Plan
  if ($plan.Count -eq 0) { Stop-Sk 'nothing to install on Windows from that selection' }
  Show-SkTitle "Plan — $($plan.Count) items for $env:USERNAME on $env:COMPUTERNAME"
  $sys = @($plan | Where-Object { Test-SkSystemItem $_ } | ForEach-Object { $script:Items[$_].Name })
  $usr = @($plan | Where-Object { -not (Test-SkSystemItem $_) } | ForEach-Object { $script:Items[$_].Name })
  if ($sys) { Write-Host '  As administrator (one UAC prompt)'; Write-SkWrapped $sys }
  if ($usr) { Write-Host '  Your account (no admin)'; Write-SkWrapped $usr }
  # items a profile names that simply don't exist on Windows aren't news
  $notes = @($Resolved.Skipped | Where-Object { -not ($FromProfile -and ($script:Why[$_] -like 'not offered*' -or $script:Why[$_] -like 'not available*')) })
  if ($notes) {
    Write-Host '  Not possible here'
    foreach ($id in $notes) { $why = $script:Why[$id]; if (-not $why) { $why = "a dependency can't be installed" }; Write-Host "    $($script:Items[$id].Name) — $why" }
  }
  Write-Host ''
  if (-not $script:DryRun -and -not $script:AssumeYes) {
    if ($script:UI -eq 'none') { Stop-Sk 'no console to confirm on — add --yes to proceed (or --dry-run to preview)' }
    if (-not (Read-SkConfirm 'Go ahead?' $true)) { Show-SkNote 'Nothing was changed.'; return }
  }
  foreach ($k in $script:PendingSave) { Set-SkConfig $k $script:Settings[$k] }
  Invoke-SkPlan $plan
}
$script:PendingSave = @()

function Write-SkWrapped([string[]]$Names) {
  $width = 78
  try { if ([Console]::WindowWidth -ge 40) { $width = [Math]::Min([Console]::WindowWidth - 6, 100) } } catch { }
  $line = ''
  foreach ($n in $Names) {
    if ($line -and ($line.Length + $n.Length + 2) -gt $width) { Write-Host "    $line,"; $line = $n }
    elseif ($line) { $line = "$line, $n" } else { $line = $n }
  }
  if ($line) { Write-Host "    $line" }
}

# ------------------------------------------------------------------------------
# Wizard
# ------------------------------------------------------------------------------
function Start-SkWizard {
  if ($script:UI -eq 'none') { Stop-Sk "no console: use 'serverkit apply --profile NAME --yes' or 'serverkit install ITEM... --yes'" }
  Show-SkBanner "$(Get-SkPlatformLine) — setting up $env:USERNAME"
  if ($script:IsAdmin) { Show-SkNote 'Running as administrator: Scoop tools are skipped. For everything, start serverkit from a normal PowerShell; it asks for admin only when needed.' }
  $opts = @()
  foreach ($p in 'desktop', 'minimal', 'personal', 'apps') {
    $f = Join-SkPath $script:Root "profiles" "$p.conf"
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $desc = ''
    foreach ($l in [IO.File]::ReadAllLines($f)) { if ($l -match '^PROFILE_DESC="(.*)"$') { $desc = $Matches[1] } }
    $opts += ("{0,-9} {1}`t{0}" -f $p, $desc)
  }
  $opts += ("{0,-9} {1}`t{0}" -f 'custom', 'start from nothing and pick items yourself')
  $p = Read-SkChoice 'What is this machine?' $opts
  if (-not $p) { exit 130 }
  $script:ProfileName = ''
  if ($p -ne 'custom') { $script:ProfileName = $p }
  Import-SkSettings $script:ProfileName
  $pre = @()
  if ($script:ProfileName) { $pre = @((Get-SkSetting 'ITEMS') -split '\s+' | Where-Object { $_ }) }
  $items = @()
  $width = 100; try { $width = [Console]::WindowWidth } catch { }
  foreach ($c in $script:CatOrder) {
    foreach ($id in $script:ItemOrder) {
      if ($script:Items[$id].Cat -ne $c -or -not (Test-SkAvailable $id)) { continue }
      $tag = ''; if (Test-SkSystemItem $id) { $tag = '  [admin]' }
      $room = [Math]::Max(10, $width - 4 - 13 - 27 - $tag.Length)
      $d = $script:Items[$id].Desc
      if ($d.Length -gt $room) { $d = $d.Substring(0, $room - 1) + '…' }
      $cat = $script:CatTitle[$c].Split(' ')[0]
      $items += ("{0,-12} {1,-26} {2}{3}`t{4}" -f $cat, $script:Items[$id].Name, $d, $tag, $id)
    }
  }
  if ($script:UI -eq 'gum') { Show-SkNote 'x or tab: select · ctrl+a: all · up/down: move · enter: done — the profile''s picks are preselected' }
  $sel = @(Read-SkMulti 'Pick what to install' $pre $items | Where-Object { $_ })
  if ($sel.Count -eq 0) { Show-SkNote 'Nothing selected — nothing changed.'; exit 0 }
  Show-SkPlanAndRun (Resolve-SkPlan $sel) $false
}

# ------------------------------------------------------------------------------
# Other commands
# ------------------------------------------------------------------------------
function Show-SkList([bool]$Json, [bool]$All, [string]$Category) {
  if ($Json) { [Console]::Out.WriteLine((Get-SkCatalogJson)); return }
  foreach ($c in $script:CatOrder) {
    if ($Category -and $Category -ne $c) { continue }
    $shown = $false
    foreach ($id in $script:ItemOrder) {
      if ($script:Items[$id].Cat -ne $c) { continue }
      $why = $script:Why[$id]
      if ($why -and -not $All) { continue }
      if (-not $shown) { Write-Host ''; Write-Host $script:CatTitle[$c] -ForegroundColor White; $shown = $true }
      $mark = '  '; if (Test-SkSystemItem $id) { $mark = '! ' }
      $line = "  {0}{1,-16} {2}" -f $mark, $id, $script:Items[$id].Desc
      if ($why) { Write-Host "$line — $why" -ForegroundColor DarkGray } else { Write-Host $line }
    }
  }
  Write-Host ''; Show-SkNote '! = needs administrator (one UAC prompt per run) · --all also shows items not offered here'
}

function Show-SkInfo([string]$Id) {
  if (-not $Id) { Stop-Sk 'usage: serverkit info ITEM' }
  if (-not $script:Items.ContainsKey($Id)) { Stop-Sk "unknown item '$Id' — see: serverkit list" }
  $it = $script:Items[$Id]
  Write-Host "$($it.Name) — $($it.Desc)"
  Write-Host "  category   $($script:CatTitle[$it.Cat])"
  $here = $script:Res[$Id]; if ($script:Why[$Id]) { $here += " — unavailable: $($script:Why[$Id])" }
  Write-Host "  here       $here"
  Write-Host "  scope      $(if (Test-SkSystemItem $Id) { 'administrator' } else { 'user' })"
  $d = Get-SkDeps $Id; if ($d) { Write-Host "  needs      $($d -join ' ')" }
  Write-Host "  all specs  $($it.Spec)"
  $doc = Join-SkPath $script:Root "docs" "items" "$Id.md"
  if (Test-Path -LiteralPath $doc) { Write-Host ''; Get-Content -LiteralPath $doc -Encoding UTF8 }
}

function Show-SkProfiles {
  foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:Root 'profiles') -Filter '*.conf' | Where-Object { -not $_.Name.StartsWith('_') }) {
    $p = $f.BaseName
    Import-SkSettings $p
    $ids = @((Get-SkSetting 'ITEMS') -split '\s+' | Where-Object { $_ -and $script:Items.ContainsKey($_) -and (Test-SkAvailable $_) })
    Write-Host ''; Write-Host "$p — $(Get-SkSetting 'PROFILE_DESC')" -ForegroundColor White
    Show-SkNote "  $($ids.Count) items on Windows: $($ids -join ' ')"
  }
  Write-Host ''; Show-SkNote 'preview one: serverkit apply --profile NAME --dry-run'
}

function Show-SkDoctor {
  Write-Host "serverkit $($script:Version)  ($($script:Root))"
  $w = Find-SkWinget; $s = Find-SkScoop
  $rows = [ordered]@{
    platform = Get-SkPlatformLine
    powershell = "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    user = "$env:USERNAME ($env:USERPROFILE)"
    administrator = $(if ($script:IsAdmin) { 'yes — Scoop items are skipped; run from a normal PowerShell' } else { 'no (admin items ask once via UAC)' })
    Scoop = $(if ($s) { "yes: $s" } elseif (Test-SkScoopSupported) { 'not installed yet' } else { 'not usable as administrator' })
    winget = $(if ($w) { "yes: $w" } else { 'not found — item "winget" installs App Installer' })
    'execution policy' = "$(Get-SkUserPolicy) (what new PowerShell windows get)"
    'terminal UI' = $(if ($script:Gum) { "gum ($($script:Gum))" } else { $script:UI })
    config = (Join-Path $script:ConfigDir 'config.conf')
  }
  foreach ($k in $rows.Keys) { Write-Host ("  {0,-18} {1}" -f $k, $rows[$k]) }
  $n = @($script:ItemOrder | Where-Object { Test-SkAvailable $_ }).Count
  Write-Host ("  {0,-18} {1} of {2}" -f 'items offered', $n, $script:ItemOrder.Count)
}

function Show-SkHealth {
  Show-SkTitle "── $env:COMPUTERNAME · $(Get-SkPlatformLine)"
  $os = Get-CimInstance Win32_OperatingSystem
  $up = (Get-Date) - $os.LastBootUpTime
  Write-Host ("  up {0}d {1}h {2}m" -f $up.Days, $up.Hours, $up.Minutes)
  Show-SkTitle '── memory'
  Write-Host ("  {0:N1} GB free of {1:N1} GB" -f ($os.FreePhysicalMemory / 1MB), ($os.TotalVisibleMemorySize / 1MB))
  Show-SkTitle '── disks'
  Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { Write-Host ("  {0}  {1:N0} GB free of {2:N0} GB" -f $_.DeviceID, ($_.FreeSpace / 1GB), ($_.Size / 1GB)) }
  Show-SkTitle '── security'
  try { Get-NetFirewallProfile | ForEach-Object { Write-Host ("  firewall {0,-8} {1}" -f $_.Name, $(if ($_.Enabled) { 'on' } else { 'OFF' })) } } catch { }
  try { $d = Get-MpComputerStatus -ErrorAction Stop; Write-Host "  Defender real-time protection: $(if ($d.RealTimeProtectionEnabled) { 'on' } else { 'OFF' })" } catch { }
  $reboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
  if ($reboot) { Show-SkTitle '── reboot'; Write-Host '  a restart is pending (updates installed)' }
}

function Show-SkStatus {
  Write-Host 'Recent runs' -ForegroundColor White
  $f = Join-Path $script:StateDir 'runs.log'
  if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Tail 5 -Encoding UTF8 | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  none yet' }
  Write-Host ''; Write-Host 'Files waiting for your review' -ForegroundColor White
  $p = Get-SkPending
  if ($p) { $p | ForEach-Object { Write-Host "    $_" } } else { Write-Host '  none' }
}

function Show-SkConfig([string[]]$Rest) {
  $sub = 'show'; if ($Rest.Count -gt 0) { $sub = $Rest[0] }
  switch ($sub) {
    'show' {
      foreach ($k in $script:SettingNames) {
        if ($k -eq 'ITEMS' -or $k -eq 'PROFILE_DESC') { continue }
        Write-Host ("  {0,-20} {1,-40} {2}" -f $k, $script:Settings[$k], $script:SettingSrc[$k])
      }
    }
    'set' {
      if ($Rest.Count -lt 2 -or $Rest[1] -notmatch '^([A-Z_][A-Z0-9_]*)=(.*)$') { Stop-Sk 'usage: serverkit config set NAME=VALUE' }
      Set-SkConfig $Matches[1] $Matches[2]; Write-SkOk "saved $($Matches[1])"
    }
    'edit' { $f = Join-Path $script:ConfigDir 'config.conf'; if (-not (Test-Path $f)) { Set-SkConfig 'SSH_PASSWORD_AUTH' (Get-SkSetting 'SSH_PASSWORD_AUTH') }; Start-Process notepad.exe $f }
    default { Stop-Sk 'usage: serverkit config [show|set NAME=VALUE|edit]' }
  }
}

function Update-Sk {
  if (Test-Path -LiteralPath (Join-Path $script:Root '.git')) {
    $rc = Invoke-SkCmd -File git -Arguments @('-C', $script:Root, 'pull', '--ff-only')
    if ($rc -eq 0) { Write-SkOk "serverkit updated to $(Get-Content (Join-Path $script:Root 'VERSION'))" }
  } else {
    Show-SkNote 'Re-run the installer to update:'
    Write-Host '  irm https://raw.githubusercontent.com/naserowaimer/serverkit/main/install.ps1 | iex'
  }
}

function Show-SkUsage {
  @"
serverkit $($script:Version) — set up a Windows PC or server, safely.

Usage
  serverkit                          interactive setup
  serverkit install ITEM...          install items (and what they need)
  serverkit apply --profile NAME     install a profile's items
  serverkit list [--all] [--json]    everything installable here
  serverkit info ITEM | profiles | config [show|set NAME=VALUE|edit]
  serverkit health | status | doctor | update | version

Options
  -p, --profile NAME   desktop | minimal | personal | apps
      --only A,B / --skip A,B
  -n, --dry-run        show exactly what would change; change nothing
  -y, --yes            don't ask (needed without a console)
  -v, --verbose        show command output instead of spinners
      --force          adopt config files serverkit didn't write (.bak kept)
      --set NAME=VALUE --plain --events FILE
"@ | Write-Host
}

# ------------------------------------------------------------------------------
$script:ExitCode = 0
function Invoke-SkMain([string[]]$Argv) {
  $cmd = ''; $rest = @(); $prof = ''; $only = ''; $skip = ''; $json = $false; $all = $false; $category = ''
  for ($i = 0; $i -lt $Argv.Count; $i++) {
    $a = $Argv[$i]
    switch -regex ($a) {
      '^(-p|--profile)$' { $prof = $Argv[++$i]; continue }
      '^--profile=' { $prof = $a.Split('=', 2)[1]; continue }
      '^--only$' { $only = $Argv[++$i]; continue }
      '^--skip$' { $skip = $Argv[++$i]; continue }
      '^--set$' { $script:OptSet += $Argv[++$i]; continue }
      '^--category$' { $category = $Argv[++$i]; continue }
      '^--events$' { $script:EventsFile = $Argv[++$i]; continue }
      '^(-n|--dry-run)$' { $script:DryRun = $true; continue }
      '^(-y|--yes)$' { $script:AssumeYes = $true; continue }
      '^(-v|--verbose)$' { $script:VerboseRun = $true; continue }
      '^(-q|--quiet)$' { $script:Quiet = $true; continue }
      '^--force$' { $script:Force = $true; continue }
      '^--plain$' { $env:SERVERKIT_UI = 'plain'; continue }
      '^--json$' { $json = $true; continue }
      '^--all$' { $all = $true; continue }
      '^(-h|--help)$' { $cmd = 'help'; continue }
      '^--version$' { $cmd = 'version'; continue }
      '^-' { Stop-Sk "unknown option: $a (see: serverkit --help)" }
      default { if (-not $cmd) { $cmd = $a } else { $rest += $a } }
    }
  }
  if ($cmd -eq 'help') { Show-SkUsage; return 0 }
  if ($cmd -eq 'version') { Write-Host "serverkit $($script:Version)"; return 0 }
  if ($cmd -eq '__elevated') { Invoke-SkElevated $rest[0] $rest[1]; return 0 }

  Initialize-SkPlatform
  Import-SkCatalog
  Initialize-SkResolution
  if ($prof -and -not (Test-Path -LiteralPath (Join-SkPath $script:Root "profiles" "$prof.conf"))) { Stop-Sk "no profile '$prof'" }
  $script:ProfileName = $prof
  Import-SkSettings $prof
  if (@('', 'setup', 'install', 'apply', 'plan', 'doctor') -contains $cmd) { Initialize-SkUI }
  if ($cmd -eq 'plan') { $script:DryRun = $true }

  switch ($cmd) {
    { $_ -eq '' -or $_ -eq 'setup' } {
      if ($prof) { $cmd = 'apply' } else { Start-SkWizard | Out-Host; return $script:ExitCode }
    }
  }
  & { switch ($cmd) {
    { @('install', 'apply', 'plan') -contains $_ } {
      $fromProfile = $false
      if ($rest.Count -gt 0) { $sel = $rest }
      elseif ($prof) {
        $fromProfile = $true
        $sel = @((Get-SkSetting 'ITEMS') -split '\s+' | Where-Object { $_ })
        if ($only) { $sel = @($only.Split(',') | ForEach-Object { if ($sel -notcontains $_) { Stop-Sk "'$_' isn't in profile $prof" }; $_ }) }
      } else {
        if ($cmd -eq 'install') { Stop-Sk 'usage: serverkit install ITEM... (see: serverkit list)' }
        Start-SkWizard | Out-Host; return $script:ExitCode
      }
      if ($skip) { $sel = @($sel | Where-Object { $skip.Split(',') -notcontains $_ }) }
      foreach ($id in $sel) { if (-not $script:Items.ContainsKey($id)) { Stop-Sk "unknown item '$id' — see: serverkit list" } }
      $r = Resolve-SkPlan $sel
      if ($skip) { $r.Plan = @($r.Plan | Where-Object { $skip.Split(',') -notcontains $_ }) }
      Show-SkPlanAndRun $r $fromProfile
    }
    'list' { Show-SkList $json $all $category }
    'info' { Show-SkInfo $(if ($rest.Count) { $rest[0] } else { '' }) }
    'profiles' { Show-SkProfiles }
    'config' { Show-SkConfig $rest }
    'status' { Show-SkStatus }
    'doctor' { Show-SkDoctor }
    'health' { Show-SkHealth }
    'update' { Update-Sk }
    default { Stop-Sk "unknown command '$cmd' — see: serverkit --help" }
  } } | Out-Host
  return $script:ExitCode
}
