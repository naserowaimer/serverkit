# ==============================================================================
#  pkg — Scoop (command-line tools, per user, no admin) and winget (apps).
#  Scoop plays Homebrew's role on Windows: same tool names, no admin, its own
#  folder (~\scoop) with shims on the user's PATH.
# ==============================================================================

function Invoke-SkScoop([string[]]$Arguments) {
  $s = Find-SkScoop
  if (-not $s -and $script:DryRun) { $s = 'scoop' }
  if (-not $s) { Write-SkErr 'Scoop is not installed'; return 1 }
  $a = @($Arguments)
  if ($s.EndsWith('.ps1')) {
    return (Invoke-SkCmd -File (Get-SkPowerShell) -Arguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $s) + $a))
  }
  return (Invoke-SkCmd -File $s -Arguments $a)
}

function Test-SkScoopInstalled([string]$Name) {
  $n = $Name.Split('/')[-1]
  return (Test-Path -LiteralPath (Join-SkPath (Get-SkScoopRoot) "apps" $n "current"))
}

function Add-SkScoopBucket([string]$Bucket) {
  if ($Bucket -eq 'main') { return 0 }
  if (Test-Path -LiteralPath (Join-SkPath (Get-SkScoopRoot) "buckets" $Bucket)) { return 0 }
  Write-SkLog "adding Scoop bucket '$Bucket'"
  if ($Bucket -eq 'nerd-fonts' -or $Bucket -eq 'extras') {
    return (Invoke-SkScoop @('bucket', 'add', $Bucket))
  }
  Write-SkErr "unknown Scoop bucket: $Bucket"
  return 1
}

# Install-SkScoop NAME... (names may be bucket/name)
function Install-SkScoop([string[]]$Names) {
  if (-not (Find-SkScoop) -and -not $script:DryRun) {
    if ((item_scoop) -ne 0) { return 1 }
  }
  foreach ($n in $Names) {
    if (Test-SkScoopInstalled $n) { Write-SkSkip "$n already installed"; continue }
    if ($n.Contains('/')) {
      if ((Add-SkScoopBucket $n.Split('/')[0]) -ne 0) { return 1 }
    }
    Write-SkLog "scoop install $n"
    if ((Invoke-SkScoop @('install', $n)) -ne 0) { Write-SkErr "Scoop could not install $n"; return 1 }
  }
  Update-SkPath
  return 0
}

function Test-SkWingetInstalled([string]$Id) {
  $w = Find-SkWinget
  if (-not $w) { return $false }
  $r = Invoke-SkCapture -File $w -Arguments @('list', '--id', $Id, '--exact', '--accept-source-agreements', '--disable-interactivity')
  return ($r.Code -eq 0 -and $r.Output -match [regex]::Escape($Id))
}

function Install-SkWinget([string]$Id, [string[]]$Extra = @()) {
  $w = Find-SkWinget
  if (-not $w) {
    if ($script:DryRun) { $w = 'winget' } else {
      Write-SkErr 'winget is not available — install "App Installer" from the Microsoft Store (serverkit item: winget)'
      return 1
    }
  }
  if (-not $script:DryRun -and (Test-SkWingetInstalled $Id)) { Write-SkSkip "$Id already installed"; return 0 }
  Write-SkLog "winget install $Id"
  $rc = Invoke-SkCmd -File $w -Arguments (@('install', '--id', $Id, '--exact', '--silent', '--accept-package-agreements',
      '--accept-source-agreements', '--disable-interactivity') + $Extra)
  if ($rc -eq 0) { Update-SkPath; return 0 }
  # -1978335189: already installed, no newer version
  if ($rc -eq -1978335189) { Write-SkSkip "$Id already installed"; return 0 }
  Write-SkErr ("winget could not install {0} (exit code 0x{1:X8})" -f $Id, $rc)
  return 1
}

# uv:PACKAGE items: a Python command-line tool in its own environment.
function Install-SkUv([string]$Package) {
  $uv = Join-SkPath (Get-SkScoopRoot) 'shims' 'uv.exe'
  if (-not (Test-Path -LiteralPath $uv)) {
    if ($script:DryRun) { $uv = 'uv' } else { Write-SkErr "uv not found — the 'uv' item provides it"; return 1 }
  }
  $have = $false
  if (-not $script:DryRun) {
    $r = Invoke-SkCapture -File $uv -Arguments @('tool', 'list')
    $have = ($r.Code -eq 0 -and $r.Output -match ('(?m)^' + [regex]::Escape($Package) + ' '))
  }
  if ($have) { Write-SkSkip "$Package already installed" } else {
    Write-SkLog "uv tool install $Package"
    if ((Invoke-SkCmd -File $uv -Arguments @('tool', 'install', $Package)) -ne 0) { Write-SkErr "uv could not install $Package"; return 1 }
  }
  # uv puts the tools' commands in ~\.local\bin
  return (Add-SkUserPath (Join-SkPath $env:USERPROFILE '.local' 'bin'))
}

# Global npm packages through mise's Node (the 'runtimes' item): no admin.
function Install-SkNpm([string]$Package) {
  $mise = Join-SkPath (Get-SkScoopRoot) 'shims' 'mise.exe'
  if (-not (Test-Path -LiteralPath $mise)) {
    if ($script:DryRun) { $mise = 'mise' } else { Write-SkErr "mise not found — the 'runtimes' item provides Node for npm packages"; return 1 }
  }
  if (-not $script:DryRun) {
    $r = Invoke-SkCapture -File $mise -Arguments @('exec', '--', 'npm', 'ls', '-g', '--depth=0', $Package)
    if ($r.Code -eq 0) { Write-SkSkip "$Package already installed"; return 0 }
  }
  $rc = Invoke-SkCmd -File $mise -Arguments @('exec', '--', 'npm', 'install', '-g', '--no-fund', '--no-audit', $Package)
  if ($rc -ne 0) { return 1 }
  [void](Invoke-SkCmd -File $mise -Arguments @('reshim'))
  return 0
}
