# ==============================================================================
#  serverkit installer for Windows (PowerShell 5.1 or 7)
#
#    irm https://raw.githubusercontent.com/naserowaimer/serverkit/main/install.ps1 | iex
#
#  Prefer reading it first?
#    irm .../install.ps1 -OutFile install.ps1; notepad install.ps1; .\install.ps1
#
#  Puts serverkit in %LOCALAPPDATA%\serverkit\src, adds a `serverkit` command
#  to your user PATH, and starts the interactive setup - which asks before it
#  changes anything. No administrator rights needed for this step.
#
#  Environment:  SERVERKIT_VERSION=v0.1.0  (default: latest release, else main)
#                SERVERKIT_NO_RUN=1        install only
#                SERVERKIT_REPO=owner/name install from a fork
# ==============================================================================
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$repo = if ($env:SERVERKIT_REPO) { $env:SERVERKIT_REPO } else { 'naserowaimer/serverkit' }
$base = Join-Path $env:LOCALAPPDATA 'serverkit'
$dest = Join-Path $base 'src'
$bin = Join-Path $base 'bin'

function Say([string]$m) { Write-Host '> ' -ForegroundColor Magenta -NoNewline; Write-Host $m }

$version = $env:SERVERKIT_VERSION
if (-not $version) {
  try { $version = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name } catch { }
  if (-not $version) { $version = 'main' }
}

# Never replace a folder that isn't a serverkit checkout.
if ((Test-Path $dest) -and -not (Test-Path (Join-Path $dest 'win\serverkit.ps1'))) {
  throw "$dest exists and is not serverkit - move it away first"
}

$url = if ($version -eq 'main') { "https://github.com/$repo/archive/refs/heads/main.zip" } else { "https://github.com/$repo/archive/refs/tags/$version.zip" }
Say "installing serverkit $version into $dest"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("serverkit-install-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
  Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmp 'src.zip') -UseBasicParsing
  Expand-Archive -LiteralPath (Join-Path $tmp 'src.zip') -DestinationPath $tmp -Force
  $extracted = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
  if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
  New-Item -ItemType Directory -Path $base -Force | Out-Null
  Move-Item -LiteralPath $extracted.FullName -Destination $dest
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# A tiny launcher on the user's PATH.
New-Item -ItemType Directory -Path $bin -Force | Out-Null
Set-Content -LiteralPath (Join-Path $bin 'serverkit.cmd') -Encoding ASCII -Value "@call `"$dest\serverkit.cmd`" %*"
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($userPath -split ';') -contains $bin)) {
  # Raw read and write: entries like %USERPROFILE%\bin must stay unexpanded.
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  try {
    $raw = "$($key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))"
    $key.SetValue('Path', ((@($raw.TrimEnd(';'), $bin) | Where-Object { $_ }) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
  } finally { $key.Close() }
  # setting any user variable tells Explorer and new terminals to reload
  [Environment]::SetEnvironmentVariable('SERVERKIT_PATH_CHANGED', '1', 'User')
  [Environment]::SetEnvironmentVariable('SERVERKIT_PATH_CHANGED', $null, 'User')
  Say "added $bin to your PATH (new terminals pick it up)"
}
$env:Path = "$env:Path;$bin"
Say "serverkit command: $bin\serverkit.cmd"

if (-not $env:SERVERKIT_NO_RUN -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
  Say 'starting the setup (nothing changes until you confirm)'
  & (Join-Path $bin 'serverkit.cmd')
} else {
  Say "run 'serverkit' to start the setup"
}
