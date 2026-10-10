# ==============================================================================
#  core — logging, dry-run aware command execution, safe file writes.
#  Windows PowerShell 5.1 compatible (no ternary, no ??, no && in scripts).
#
#  Same contract as the bash side (lib/core.sh): every change goes through
#  Invoke-SkCmd / Write-SkFile / Set-SkBlock, so --dry-run is exact; a file
#  serverkit didn't write is never overwritten (ours lands as FILE.new).
# ==============================================================================

$script:Marker = 'managed-by:serverkit'
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:DryRun = $false
$script:AssumeYes = $false
$script:VerboseRun = $false
$script:Force = $false
$script:Quiet = $false
$script:Log = $null
$script:RunDir = $null
$script:EventsFile = $null
$script:CurrentItem = ''
$script:NA = 3          # item return code: not applicable here
$script:UseColor = (-not $env:NO_COLOR)
$script:Utf8 = New-Object System.Text.UTF8Encoding $false   # no BOM

function Write-SkLine([string]$Color, [string]$Symbol, [string]$Message) {
  if ($script:TaskMode) {
    if ($script:Log) { Add-Content -LiteralPath $script:Log -Value ("{0} {1} {2}" -f (Get-Date -Format 'HH:mm:ss'), $Symbol, $Message) -Encoding UTF8 }
    return
  }
  if ($script:UseColor) { Write-Host -NoNewline -ForegroundColor $Color $Symbol } else { Write-Host -NoNewline $Symbol }
  Write-Host " $Message"
  if ($script:Log) { Add-Content -LiteralPath $script:Log -Value ("{0} {1} {2}" -f (Get-Date -Format 'HH:mm:ss'), $Symbol, $Message) -Encoding UTF8 }
}
function Write-SkLog([string]$m) { if (-not $script:Quiet) { Write-SkLine Blue '•' $m } }
function Write-SkOk([string]$m) {
  if ($script:DryRun) { Write-SkLine DarkGray '○' "would then be: $m" } else { Write-SkLine Green '✓' $m }
}
function Write-SkSkip([string]$m) { if (-not $script:Quiet) { Write-SkLine Cyan '=' $m } }
function Write-SkWarn([string]$m) {
  Write-SkLine Yellow '!' $m
  if ($script:RunDir) { Add-Content -LiteralPath (Join-Path $script:RunDir 'warnings') -Value ("{0}`t{1}" -f $script:CurrentItem, $m) -Encoding UTF8 }
}
function Write-SkErr([string]$m) { Write-SkLine Red '✗' $m }
# Fatal error: report and stop. Throws (instead of exit) so a spinner runspace
# fails just its item and tests can catch it; the entry script exits with 1.
function Stop-Sk([string]$m) { Write-SkErr $m; throw 'serverkit-stop' }

# Follow-ups the person must do by hand: shown once, at the end of the run.
function Add-SkHint([string]$m) {
  if (-not $script:RunDir) { Write-SkLine Magenta '→' $m; return }
  $f = Join-Path $script:RunDir 'hints'
  if ((Test-Path -LiteralPath $f) -and ((Get-Content -LiteralPath $f -Encoding UTF8) -contains $m)) { return }
  Add-Content -LiteralPath $f -Value $m -Encoding UTF8
}

# Item doesn't apply here: record why, return the NA code.
function Skip-SkNA([string]$why) {
  Write-SkSkip $why
  if ($script:RunDir) { Set-Content -LiteralPath (Join-Path $script:RunDir ".na-$script:CurrentItem") -Value $why -Encoding UTF8 }
  return $script:NA
}

function Write-SkEvent([string]$Type, [hashtable]$Data = @{}) {
  if (-not $script:EventsFile) { return }
  $o = [ordered]@{ event = $Type; ts = [int][double]::Parse((Get-Date -UFormat %s)) }
  foreach ($k in $Data.Keys) { $o[$k] = [string]$Data[$k] }
  Add-Content -LiteralPath $script:EventsFile -Value ($o | ConvertTo-Json -Compress) -Encoding UTF8
}

function Test-SkCommand([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# Path from segments; works in Windows PowerShell 5.1 and on any OS (tests).
function Join-SkPath { [IO.Path]::Combine([string[]]$args) }

function Test-SkAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

# ------------------------------------------------------------------------------
# Running commands. Native programs only; returns the exit code.
# ------------------------------------------------------------------------------
function Format-SkCmd([string]$File, [string[]]$Arguments) {
  $parts = @($File) + @($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
  return ($parts -join ' ')
}

function Invoke-SkCmd {
  param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @())
  if ($script:DryRun) {
    Write-Host "    would run: $(Format-SkCmd $File $Arguments)" -ForegroundColor DarkGray
    return 0
  }
  if ($script:Log) { Add-Content -LiteralPath $script:Log -Value ("{0} $ {1}" -f (Get-Date -Format 'HH:mm:ss'), (Format-SkCmd $File $Arguments)) -Encoding UTF8 }
  $global:LASTEXITCODE = 0
  if ($script:TaskMode -and $script:Log) {
    & $File @Arguments 2>&1 | ForEach-Object { "$_" } | Add-Content -LiteralPath $script:Log -Encoding UTF8
  } else {
    & $File @Arguments 2>&1 | ForEach-Object { "$_" } | Out-Host
  }
  return $LASTEXITCODE
}

# Same, but the output is returned (for messages), not shown.
function Invoke-SkCapture {
  param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @())
  $global:LASTEXITCODE = 0
  $out = & $File @Arguments 2>&1 | ForEach-Object { "$_" }
  return @{ Code = $LASTEXITCODE; Output = ($out -join "`n") }
}

# Download over HTTPS only (TLS 1.2+: PowerShell 5.1 defaults to older).
function Get-SkDownload([string]$Url, [string]$Dest) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  if ($Url -notmatch '^https://') { throw "refusing non-HTTPS download: $Url" }
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
}

# Official installers are saved first and then run, never piped into iex,
# so --dry-run can show them.
function Invoke-SkScript([string]$Url, [string[]]$Arguments = @()) {
  if ($script:DryRun) { Write-Host "    would download and run: $Url $($Arguments -join ' ')" -ForegroundColor DarkGray; return 0 }
  $f = Join-Path (Get-SkTemp) ("installer-{0}.ps1" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
  try { Get-SkDownload $Url $f } catch { Write-SkErr "download failed: $Url"; return 1 }
  return (Invoke-SkCmd -File (Get-SkPowerShell) -Arguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $f) + $Arguments))
}

function Get-SkPowerShell {
  # the shell running us: pwsh 7 or Windows PowerShell 5.1
  $p = (Get-Process -Id $PID).Path
  if ($p) { return $p }
  return 'powershell.exe'
}

$script:Temp = $null
function Get-SkTemp {
  if (-not $script:Temp) {
    $script:Temp = Join-Path ([IO.Path]::GetTempPath()) ("serverkit-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Temp -Force | Out-Null
  }
  return $script:Temp
}
function Clear-SkTemp { if ($script:Temp -and (Test-Path -LiteralPath $script:Temp)) { Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue } }

# ------------------------------------------------------------------------------
# Files
# ------------------------------------------------------------------------------
function Get-SkSha256([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $bytes = $script:Utf8.GetBytes($Text + "`n")
  return (-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }))
}
function Read-SkText([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $t = [IO.File]::ReadAllText($Path)
  return $t.TrimEnd("`r", "`n")
}
function Write-SkText([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [IO.File]::WriteAllText($Path, ($Text + "`n"), $script:Utf8)
}

# Ours = carries the marker, or still matches the checksum recorded when we
# wrote it (for formats that can't hold a comment, like JSON). Edited since?
# Then it's yours, and we leave it alone.
function Get-SkSumsFile { Join-Path $script:StateDir 'checksums' }
function Test-SkOurs([string]$Path) {
  $cur = Read-SkText $Path
  if ($null -eq $cur) { return $false }
  if ($cur.Contains($script:Marker)) { return $true }
  $sums = Get-SkSumsFile
  if (-not (Test-Path -LiteralPath $sums)) { return $false }
  return ((Get-Content -LiteralPath $sums -Encoding UTF8) -contains ("{0}  {1}" -f (Get-SkSha256 $cur), $Path))
}
function Save-SkSum([string]$Path, [string]$Content) {
  if ($script:DryRun) { return }
  $sums = Get-SkSumsFile
  $lines = @()
  if (Test-Path -LiteralPath $sums) { $lines = @(Get-Content -LiteralPath $sums -Encoding UTF8 | Where-Object { $_ -and -not $_.EndsWith("  $Path") }) }
  $lines += ("{0}  {1}" -f (Get-SkSha256 $Content), $Path)
  Write-SkText $sums ($lines -join "`n")
}
function Add-SkTracked([string]$Path) {
  if ($script:DryRun) { return }
  $f = Join-Path $script:StateDir 'managed.list'
  if ((Test-Path -LiteralPath $f) -and ((Get-Content -LiteralPath $f -Encoding UTF8) -contains $Path)) { return }
  Add-Content -LiteralPath $f -Value $Path -Encoding UTF8
}

# Write-SkFile PATH CONTENT -> $true when the file changed.
function Write-SkFile([string]$Path, [string]$Content) {
  $Content = $Content.TrimEnd("`r", "`n")
  Add-SkTracked $Path
  if (Test-Path -LiteralPath $Path) {
    $cur = Read-SkText $Path
    if ($cur -eq $Content) { Write-SkSkip "unchanged: $Path"; return $false }
    if ((Test-SkOurs $Path) -or $script:Force) {
      if ($script:DryRun) { Write-SkLog "would update: $Path"; return $true }
      Copy-Item -LiteralPath $Path -Destination "$Path.bak.$script:Stamp" -Force
      Write-SkText $Path $Content
      Save-SkSum $Path $Content
      Write-SkOk "updated: $Path  (previous: $Path.bak.$script:Stamp)"
      return $true
    }
    if ($script:DryRun) { Write-SkLog "would keep your $Path and write ours as $Path.new"; return $false }
    Write-SkText "$Path.new" $Content
    Write-SkWarn "kept your $Path — ours is $Path.new (review it, or re-run with --force to adopt)"
    return $false
  }
  if ($script:DryRun) { Write-SkLog "would create: $Path"; return $true }
  Write-SkText $Path $Content
  Save-SkSum $Path $Content
  Write-SkOk "created: $Path"
  return $true
}

# Keep one marked block inside a file you own (your PowerShell profile), so
# serverkit adds a line without owning the file. Re-runs replace the block.
function Set-SkBlock([string]$Path, [string]$Id, [string]$Body) {
  $begin = "# >>> serverkit:$Id >>>"
  $end = "# <<< serverkit:$Id <<<"
  $cur = Read-SkText $Path
  if ($null -eq $cur) { $cur = '' }
  if ($cur.Contains($begin)) {
    $out = New-Object System.Collections.Generic.List[string]
    $skipping = $false
    foreach ($l in ($cur -split "`r?`n")) {
      if ($l -eq $begin) { $out.Add($l); $out.Add($Body); $skipping = $true; continue }
      if ($l -eq $end) { $skipping = $false }
      if (-not $skipping) { $out.Add($l) }
    }
    $new = $out -join "`n"
  } else {
    $new = $cur
    if ($cur) { $new += "`n" }
    $new += "$begin`n$Body`n$end"
  }
  if ($new -eq ($cur -replace "`r`n", "`n")) { Write-SkSkip "unchanged: $Path ($Id)"; return }
  if ($script:DryRun) { Write-SkLog "would add the '$Id' block to $Path"; return }
  if (Test-Path -LiteralPath $Path) { Copy-Item -LiteralPath $Path -Destination "$Path.bak.$script:Stamp" -Force }
  Write-SkText $Path $new
  Write-SkOk "updated: $Path ($Id)"
}

function Restore-SkFile([string]$Path) {
  if ($script:DryRun) { return }
  $bak = "$Path.bak.$script:Stamp"
  if (Test-Path -LiteralPath $bak) { Move-Item -LiteralPath $bak -Destination $Path -Force } else { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

# Registry values (HKCU or HKLM) — idempotent, dry-run aware. Returns $true on change.
function Set-SkRegistry([string]$Key, [string]$Name, $Value, [string]$Type = 'DWord') {
  $cur = $null
  try { $cur = (Get-ItemProperty -LiteralPath $Key -Name $Name -ErrorAction Stop).$Name } catch { }
  if ($null -ne $cur -and "$cur" -eq "$Value") { Write-SkSkip "already set: $Key\$Name = $Value"; return $false }
  if ($script:DryRun) { Write-SkLog "would set $Key\$Name = $Value"; return $true }
  if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
  New-ItemProperty -LiteralPath $Key -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
  Write-SkOk "set $Key\$Name = $Value"
  return $true
}
