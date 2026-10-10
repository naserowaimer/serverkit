# Loads every serverkit library and module into the current scope.
# Used by the entry script and by each spinner runspace.
$script:Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
foreach ($_skLib in 'core', 'platform', 'pkg', 'ui', 'catalog', 'main') { . ([IO.Path]::Combine($script:Root, 'win', 'lib', "$_skLib.ps1")) }
foreach ($_skMod in Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Root, 'win', 'modules')) -Filter '*.ps1') { . $_skMod.FullName }
$script:Version = 'dev'
$_skVf = [IO.Path]::Combine($script:Root, 'VERSION')
if (Test-Path -LiteralPath $_skVf) { $script:Version = ([IO.File]::ReadAllText($_skVf)).Trim() }
$_skHome = $env:USERPROFILE; if (-not $_skHome) { $_skHome = $HOME }
$_skLocal = $env:LOCALAPPDATA; if (-not $_skLocal) { $_skLocal = [IO.Path]::Combine($_skHome, '.local', 'share') }
$script:StateDir = [IO.Path]::Combine($_skLocal, 'serverkit', 'state')
$script:DataDir = [IO.Path]::Combine($_skLocal, 'serverkit')
$_skAppData = $env:APPDATA; if (-not $_skAppData) { $_skAppData = [IO.Path]::Combine($_skHome, '.config') }
$script:ConfigDir = [IO.Path]::Combine($_skAppData, 'serverkit')
foreach ($d in $script:StateDir, $script:ConfigDir) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
