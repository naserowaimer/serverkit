# ==============================================================================
#  platform — Windows version, architecture, privileges, package managers.
#  Mirrors lib/platform.sh: OS=win FAMILY=win DISTRO_ID=windows.
# ==============================================================================

$script:OS = 'win'
$script:FAMILY = 'win'
$script:DISTRO_ID = 'windows'
$script:DistroName = 'Windows'
$script:Arch = 'amd64'
$script:IsAdmin = $false
$script:IsServer = $false
$script:Build = 0

function Initialize-SkPlatform {
  $script:IsAdmin = Test-SkAdmin
  $a = $env:PROCESSOR_ARCHITECTURE
  if ($env:PROCESSOR_ARCHITEW6432) { $a = $env:PROCESSOR_ARCHITEW6432 }
  switch ($a) { 'ARM64' { $script:Arch = 'arm64' } 'AMD64' { $script:Arch = 'amd64' } default { $script:Arch = "$a".ToLower() } }
  try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $script:Build = [int]$cv.CurrentBuildNumber
    $name = "$($cv.ProductName)"
    # ProductName still says "Windows 10" on Windows 11; the build number tells
    if ($script:Build -ge 22000) { $name = $name -replace 'Windows 10', 'Windows 11' }
    $ver = "$($cv.DisplayVersion)"
    $script:DistroName = ("$name $ver").Trim()
    $script:IsServer = ($cv.InstallationType -eq 'Server')
  } catch {
    $script:DistroName = 'Windows'
  }
}

function Get-SkPlatformLine {
  $bits = @($script:DistroName, $script:Arch)
  if ($script:IsAdmin) { $bits += 'administrator' }
  return ($bits -join ' · ')
}

# Scoop is per-user and refuses to run elevated unless told to; serverkit
# follows it (like Homebrew and root). SERVERKIT_SCOOP_AS_ADMIN=1 is for CI
# machines, which only have an elevated account.
function Test-SkScoopSupported {
  if (-not $script:IsAdmin) { return $true }
  return ($env:SERVERKIT_SCOOP_AS_ADMIN -eq '1')
}

function Get-SkScoopRoot {
  if ($env:SCOOP) { return $env:SCOOP }
  return (Join-Path $env:USERPROFILE 'scoop')
}

function Find-SkScoop {
  $shim = Join-SkPath (Get-SkScoopRoot) 'shims' 'scoop.ps1'
  if (Test-Path -LiteralPath $shim) { return $shim }
  $c = Get-Command scoop -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return $null
}

function Find-SkWinget {
  $c = Get-Command winget -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $p = Join-SkPath $env:LOCALAPPDATA 'Microsoft' 'WindowsApps' 'winget.exe'
  if (Test-Path -LiteralPath $p) { return $p }
  return $null
}

# New tools land in PATH for new shells; make them visible to this one too.
function Update-SkPath {
  $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $u = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "$m;$u"
}
