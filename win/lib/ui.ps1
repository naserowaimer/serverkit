# ==============================================================================
#  ui — gum (pinned, SHA-256 checked) when possible, plain prompts otherwise.
#  $script:UI = gum | plain | none (none: no console; answers must come from flags)
# ==============================================================================

$script:UI = 'plain'
$script:Gum = $null
$script:GumVersion = '2.0.2'
# Windows builds are x86_64 only; Windows on ARM runs it under emulation.
$script:GumSha256 = '0397091dec9b4e8f00e02b90fd3eb07bf45acabbdb61d67437950f18e03a8b79'
$script:Accent = '212'

function Initialize-SkUI {
  if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { $script:UI = 'none'; return }
  $script:UI = 'plain'
  if ($env:SERVERKIT_UI -eq 'plain') { return }
  $local = Join-SkPath $script:DataDir 'bin' 'gum.exe'
  $have = ''
  if (Test-Path -LiteralPath $local) { $have = "$(& $local --version 2>$null)" }
  if ($have -match "v$([regex]::Escape($script:GumVersion))") {
    $script:Gum = $local
  } elseif (Save-SkGum) {
    $script:Gum = $local
  }
  if ($script:Gum) { $script:UI = 'gum' }
}

function Save-SkGum {
  $zip = "gum_$($script:GumVersion)_Windows_x86_64.zip"
  $tmp = Get-SkTemp
  Write-Host -NoNewline "fetching the terminal UI (gum $($script:GumVersion))…" -ForegroundColor DarkGray
  try { Get-SkDownload "https://github.com/charmbracelet/gum/releases/download/v$($script:GumVersion)/$zip" (Join-Path $tmp $zip) }
  catch { Write-Host "`r$(' ' * 60)`r" -NoNewline; return $false }
  $got = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $tmp $zip)).Hash.ToLower()
  Write-Host "`r$(' ' * 60)`r" -NoNewline
  if ($got -ne $script:GumSha256) { Write-SkWarn 'gum download failed its checksum — using plain prompts'; return $false }
  Expand-Archive -LiteralPath (Join-Path $tmp $zip) -DestinationPath (Join-Path $tmp 'gum') -Force
  $exe = Get-ChildItem -LiteralPath (Join-Path $tmp 'gum') -Recurse -Filter gum.exe | Select-Object -First 1
  if (-not $exe) { return $false }
  New-Item -ItemType Directory -Path (Join-Path $script:DataDir 'bin') -Force | Out-Null
  Copy-Item -LiteralPath $exe.FullName -Destination (Join-SkPath $script:DataDir 'bin' 'gum.exe') -Force
  return $true
}

function Show-SkBanner([string]$Subtitle) {
  if ($script:UI -eq 'gum') {
    $t = & $script:Gum style --bold --foreground $script:Accent "serverkit $($script:Version)"
    & $script:Gum style --border rounded --border-foreground $script:Accent --padding '0 2' --margin '1 0 0 0' $t $Subtitle
  } else {
    Write-Host ''; Write-Host "serverkit $($script:Version)" -ForegroundColor Magenta; Write-Host $Subtitle; Write-Host ''
  }
}
function Show-SkTitle([string]$t) { Write-Host ''; Write-Host $t -ForegroundColor Magenta }
function Show-SkNote([string]$t) { Write-Host $t -ForegroundColor DarkGray }

# Options are "LABEL`tVALUE"; the value comes back. gum separates --selected
# entries with commas, so ASCII commas in labels become a look-alike (U+201A).
function ConvertTo-SkLabel([string]$o) { ($o.Split("`t")[0]).Replace(',', [string][char]0x201A) }
function ConvertTo-SkValue([string]$o) { $o.Split("`t")[-1] }

function Read-SkChoice([string]$Header, [string[]]$Options) {
  $opts = @($Options | ForEach-Object { "$(ConvertTo-SkLabel $_)`t$(ConvertTo-SkValue $_)" })
  if ($script:UI -eq 'gum') {
    return (& $script:Gum choose --header $Header "--label-delimiter=`t" --cursor '> ' --header.foreground $script:Accent --cursor.foreground $script:Accent @opts)
  }
  Write-Host $Header
  for ($i = 0; $i -lt $opts.Count; $i++) { Write-Host ("  {0,2}) {1}" -f ($i + 1), (ConvertTo-SkLabel $opts[$i])) }
  while ($true) {
    $a = Read-Host "  choose [1-$($opts.Count)]"
    $n = 0
    if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $opts.Count) { return (ConvertTo-SkValue $opts[$n - 1]) }
  }
}

function Read-SkMulti([string]$Header, [string[]]$Preselected, [string[]]$Options) {
  $opts = @($Options | ForEach-Object { "$(ConvertTo-SkLabel $_)`t$(ConvertTo-SkValue $_)" })
  if ($script:UI -eq 'gum') {
    $sel = @($opts | Where-Object { $Preselected -contains (ConvertTo-SkValue $_) } | ForEach-Object { ConvertTo-SkLabel $_ }) -join ','
    return @(& $script:Gum choose --no-limit --header $Header "--label-delimiter=`t" --height 20 --selected $sel `
        --cursor '> ' --selected-prefix '[x] ' --unselected-prefix '[ ] ' --header.foreground $script:Accent `
        --cursor.foreground $script:Accent --selected.foreground $script:Accent @opts)
  }
  $on = @($opts | ForEach-Object { $Preselected -contains (ConvertTo-SkValue $_) })
  while ($true) {
    Write-Host $Header
    for ($i = 0; $i -lt $opts.Count; $i++) {
      $mark = ' '; if ($on[$i]) { $mark = 'x' }
      Write-Host ("  {0,3} [{1}] {2}" -f ($i + 1), $mark, (ConvertTo-SkLabel $opts[$i]))
    }
    $a = Read-Host '  toggle numbers/ranges (e.g. 2 5-7), a=all, n=none, Enter=done'
    if (-not $a) { break }
    foreach ($tok in ($a -split '\s+')) {
      if ($tok -eq 'a') { for ($i = 0; $i -lt $on.Count; $i++) { $on[$i] = $true } }
      elseif ($tok -eq 'n') { for ($i = 0; $i -lt $on.Count; $i++) { $on[$i] = $false } }
      elseif ($tok -match '^(\d+)-(\d+)$') { for ($i = [int]$Matches[1]; $i -le [int]$Matches[2] -and $i -le $on.Count; $i++) { if ($i -ge 1) { $on[$i - 1] = -not $on[$i - 1] } } }
      elseif ($tok -match '^\d+$' -and [int]$tok -ge 1 -and [int]$tok -le $on.Count) { $on[[int]$tok - 1] = -not $on[[int]$tok - 1] }
    }
  }
  $r = @(); for ($i = 0; $i -lt $opts.Count; $i++) { if ($on[$i]) { $r += (ConvertTo-SkValue $opts[$i]) } }
  return $r
}

function Read-SkConfirm([string]$Question, [bool]$Default = $true) {
  if ($script:AssumeYes) { return $true }
  if ($script:UI -eq 'none') { return $Default }
  if ($script:UI -eq 'gum') {
    $d = 'false'; if ($Default) { $d = 'true' }
    & $script:Gum confirm "--default=$d" $Question
    return ($LASTEXITCODE -eq 0)
  }
  $h = '[y/N]'; if ($Default) { $h = '[Y/n]' }
  $a = Read-Host "$Question $h"
  if (-not $a) { return $Default }
  return ($a -match '^[Yy]')
}

function Read-SkInput([string]$Header, [string]$Default = '', [string]$Placeholder = '') {
  if ($script:UI -eq 'gum') { return (& $script:Gum input --header $Header --value $Default --placeholder $Placeholder --header.foreground $script:Accent) }
  $a = Read-Host "$Header [$Default]"
  if (-not $a) { return $Default }
  return $a
}

# ------------------------------------------------------------------------------
# Progress: run one item in its own runspace (so a spinner can draw), with
# all of serverkit loaded there and its output going to the log.
# ------------------------------------------------------------------------------
function Invoke-SkTask([string]$Label, [string]$Id) {
  $start = Get-Date
  if ($script:VerboseRun -or $script:DryRun -or $script:UI -eq 'none') {
    Write-Host "> $Label"
    $code = Invoke-SkItem $Id
  } else {
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($Root, $Context, $Id)
        . ([IO.Path]::Combine($Root, 'win', 'lib', 'load.ps1'))
        Import-SkContext $Context
        $script:TaskMode = $true
        Invoke-SkItem $Id
      }).AddArgument($script:Root).AddArgument((Join-Path $script:RunDir 'context.json')).AddArgument($Id)
    $handle = $ps.BeginInvoke()
    $frames = '|/-\'
    $i = 0
    while (-not $handle.IsCompleted) {
      $el = [int]((Get-Date) - $start).TotalSeconds
      Write-Host -NoNewline ("`r  {0} {1} {2}s " -f $frames[$i++ % 4], $Label, $el)
      Start-Sleep -Milliseconds 120
    }
    $out = $null
    try { $out = $ps.EndInvoke($handle) } catch { Add-Content -LiteralPath $script:Log -Value "$_" -Encoding UTF8 }
    foreach ($e in $ps.Streams.Error) { Add-Content -LiteralPath $script:Log -Value "$e" -Encoding UTF8 }
    $ps.Dispose()
    $code = 1
    if ($out -and $out.Count -gt 0) { $code = [int]"$($out[$out.Count - 1])" }
    Write-Host -NoNewline ("`r{0}`r" -f (' ' * ([Console]::WindowWidth - 1)))
  }
  $el = [int]((Get-Date) - $start).TotalSeconds
  if ($code -eq 0) { Write-SkLine Green '  ✓' "$Label ${el}s" }
  elseif ($code -eq $script:NA) {
    $why = 'not applicable'
    $f = Join-Path $script:RunDir ".na-$Id"
    if (Test-Path -LiteralPath $f) { $why = (Get-Content -LiteralPath $f -Encoding UTF8 | Select-Object -First 1) }
    Write-SkLine Cyan '  –' "$Label ($why)"
  } else { Write-SkLine Red '  ✗' "$Label (failed — details in the log)" }
  return $code
}
