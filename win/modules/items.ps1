# ==============================================================================
#  Windows items. Each returns 0 (done), 1 (failed) or Skip-SkNA "why".
#  Change things only through Invoke-SkCmd / Invoke-SkAction / Write-SkFile /
#  Set-SkBlock / Set-SkRegistry, so --dry-run stays exact. Check first; a
#  second run must change nothing.
# ==============================================================================

# Run a PowerShell action (a cmdlet, not a program) unless this is a dry run.
function Invoke-SkAction([string]$Description, [scriptblock]$Action) {
  if ($script:DryRun) { Write-Host "    would: $Description" -ForegroundColor DarkGray; return $true }
  try { & $Action | Out-Null; return $true }
  catch { Write-SkErr "$Description failed: $($_.Exception.Message)"; return $false }
}

function Get-SkDocuments { [Environment]::GetFolderPath('MyDocuments') }

# The execution policy a new PowerShell window will have — i.e. ignoring the
# Process scope, which serverkit's own launcher sets to Bypass.
function Get-SkUserPolicy {
  foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
    $p = "$(Get-ExecutionPolicy -Scope $scope)"
    if ($p -and $p -ne 'Undefined') { return $p }
  }
  if ($script:IsServer) { return 'RemoteSigned' }   # Windows Server's default
  return 'Restricted'                               # Windows client default
}

# Appx cmdlets live in Windows PowerShell 5.1; PowerShell 7 often can't load
# them (notably on Windows Server), so run them through powershell.exe.
function Invoke-SkAppx([string]$Command) {
  $ps51 = Join-SkPath $env:SystemRoot 'System32' 'WindowsPowerShell' 'v1.0' 'powershell.exe'
  return (Invoke-SkCapture -File $ps51 -Arguments @('-NoProfile', '-NonInteractive', '-Command', $Command))
}

# ---- package managers ---------------------------------------------------------
function item_scoop {
  if (Find-SkScoop) { Write-SkSkip "Scoop present: $(Get-SkScoopRoot)"; return 0 }
  if (-not (Test-SkScoopSupported)) { return (Skip-SkNA "Scoop doesn't run as administrator — start serverkit from a normal PowerShell") }
  # Scoop's shims and your PowerShell profile are scripts: the default policy
  # on Windows clients ("Restricted") blocks them. RemoteSigned for this user
  # only is what Scoop documents; it still blocks unsigned downloaded scripts.
  $pol = Get-SkUserPolicy
  if (@('Restricted', 'AllSigned') -contains $pol) {
    $gpo = "$(Get-ExecutionPolicy -Scope MachinePolicy)$(Get-ExecutionPolicy -Scope UserPolicy)"
    if ($gpo -match 'Restricted|AllSigned') {
      Write-SkWarn 'your organization enforces an execution policy that blocks Scoop shims — ask IT, or use winget items only'
    } else {
      $ok = Invoke-SkAction 'set execution policy RemoteSigned for this user' {
        # PowerShell reports success-but-overridden as an error when a more
        # specific scope (here: this process's own -ExecutionPolicy Bypass)
        # wins. The setting is saved all the same; verify it below.
        try { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop } catch { }
        if ("$(Get-ExecutionPolicy -Scope CurrentUser)" -ne 'RemoteSigned') { throw 'the policy did not change' }
      }
      if (-not $ok) { return 1 }
      Write-SkOk "execution policy for $env:USERNAME`: RemoteSigned (needed by Scoop and your PowerShell profile)"
    }
  } else { Write-SkSkip "execution policy already allows local scripts ($pol)" }
  Write-SkLog 'installing Scoop (official installer)'
  $args_ = @()
  if ($script:IsAdmin) { $args_ = @('-RunAsAdmin') }   # only reachable with SERVERKIT_SCOOP_AS_ADMIN=1
  if ((Invoke-SkScript 'https://get.scoop.sh' $args_) -ne 0) { Write-SkErr 'Scoop installation failed — see the log'; return 1 }
  Update-SkPath
  if (-not $script:DryRun -and -not (Find-SkScoop)) { Write-SkErr 'Scoop installed but was not found'; return 1 }
  Write-SkOk 'Scoop installed'
  return 0
}

function item_winget {
  if (Find-SkWinget) { Write-SkSkip "winget present: $(Find-SkWinget)"; return 0 }
  # winget ships with "App Installer"; registering it is the documented fix
  # when it's installed but not yet registered for this user.
  if ($script:DryRun) { Write-Host '    would: register App Installer (winget)' -ForegroundColor DarkGray }
  else { [void](Invoke-SkAppx 'Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe') }
  Update-SkPath
  if ($script:DryRun -or (Find-SkWinget)) { Write-SkOk 'winget available'; return 0 }
  Add-SkHint 'install "App Installer" from the Microsoft Store (or https://aka.ms/getwinget), then run serverkit again'
  Write-SkErr 'winget is not available on this system'
  return 1
}

function item_essentials {
  # git: Scoop buckets and most dev tools need it. 7zip: Scoop unpacks with it.
  return (Install-SkScoop @('git', '7zip'))
}

# ---- Windows settings -----------------------------------------------------------
function item_windows_tweaks {
  $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
  $a = Set-SkRegistry $k 'HideFileExt' 0
  $b = Set-SkRegistry $k 'Hidden' 1
  if ($a -or $b) { Add-SkHint 'Explorer shows file extensions and hidden files after you sign out and in (or restart Explorer)' }
  return 0
}

function item_developer_mode {
  [void](Set-SkRegistry 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowDevelopmentWithoutDevLicense' 1)
  return 0
}

function item_long_paths {
  [void](Set-SkRegistry 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1)
  return 0
}

function item_win_firewall {
  # Only makes sure the firewall is on; rules are never changed.
  $off = @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled })
  if ($off.Count -eq 0) { Write-SkSkip 'Windows Firewall is on for all network types'; return 0 }
  $names = @($off | ForEach-Object { $_.Name })
  if (-not (Invoke-SkAction "turn on Windows Firewall ($($names -join ', '))" { Set-NetFirewallProfile -Profile $names -Enabled True })) { return 1 }
  Write-SkOk "Windows Firewall on for: $($names -join ', ') (your rules unchanged)"
  return 0
}

function item_app_updates {
  $name = 'serverkit app updates'
  if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Write-SkSkip "scheduled task '$name' exists"; return 0 }
  $cmd = 'if (Get-Command scoop -EA SilentlyContinue) { scoop update; scoop update * }; ' +
  'winget upgrade --all --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
  $ok = Invoke-SkAction "schedule '$name' (Sundays 11:00, as $env:USERNAME)" {
    $action = New-ScheduledTaskAction -Execute (Get-SkPowerShell) -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$cmd`""
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '11:00'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Description 'serverkit: weekly Scoop and winget upgrades'
  }
  if (-not $ok) { return 1 }
  Add-SkHint "apps update weekly (Sundays 11:00); remove with: Unregister-ScheduledTask -TaskName '$name'"
  return 0
}

# ---- system features (administrator) -------------------------------------------
function item_wsl {
  $r = Invoke-SkCapture -File 'wsl.exe' -Arguments @('--status')
  if ($r.Code -eq 0) { Write-SkSkip 'WSL is installed'; return 0 }
  $rc = Invoke-SkCmd -File 'wsl.exe' -Arguments @('--install', '--no-launch')
  if ($rc -ne 0) { Write-SkErr 'wsl --install failed (virtualization disabled in the BIOS?)'; return 1 }
  Add-SkHint 'restart Windows to finish installing WSL, open Ubuntu from the Start menu, then inside it run: curl -fsSL https://raw.githubusercontent.com/naserowaimer/serverkit/main/install.sh | sh'
  return 0
}

function item_openssh_server {
  $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
  if (-not $cap) { return (Skip-SkNA 'this Windows edition has no OpenSSH Server feature') }
  if ($cap.State -ne 'Installed') {
    if (-not (Invoke-SkAction "add Windows feature $($cap.Name)" { Add-WindowsCapability -Online -Name $cap.Name })) { return 1 }
  } else { Write-SkSkip 'OpenSSH Server is installed' }
  [void](Invoke-SkAction 'start sshd now and at boot' { Set-Service -Name sshd -StartupType Automatic; Start-Service sshd })
  if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    [void](Invoke-SkAction 'allow inbound SSH (TCP 22) in Windows Firewall' {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 })
  }
  $shell = Join-SkPath $env:SystemRoot 'System32' 'WindowsPowerShell' 'v1.0' 'powershell.exe'
  $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if ($pwsh) { $shell = $pwsh.Source }
  [void](Set-SkRegistry 'HKLM:\SOFTWARE\OpenSSH' 'DefaultShell' $shell 'String')
  Add-SkHint 'SSH keys: users put theirs in ~\.ssh\authorized_keys; administrators use C:\ProgramData\ssh\administrators_authorized_keys'
  return 0
}

function item_build_tools {
  return (Install-SkWinget 'Microsoft.VisualStudio.2022.BuildTools' @('--override',
      '--wait --quiet --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'))
}

# ---- languages ------------------------------------------------------------------
function item_runtimes {
  if ((Install-SkScoop @('mise')) -ne 0) { return 1 }
  $mise = Join-SkPath (Get-SkScoopRoot) 'shims' 'mise.exe'
  if ($script:DryRun -and -not (Test-Path -LiteralPath $mise)) { $mise = 'mise' }
  foreach ($spec in ((Get-SkSetting 'MISE_TOOLS') -split '\s+' | Where-Object { $_ })) {
    if ((Invoke-SkCmd -File $mise -Arguments @('use', '--global', '--yes', $spec)) -ne 0) { Write-SkErr "mise could not install $spec"; return 1 }
  }
  Write-SkOk "runtimes: $(Get-SkSetting 'MISE_TOOLS') (activated by the PowerShell setup item)"
  return 0
}

function item_rustup {
  if (Test-Path -LiteralPath (Join-SkPath $env:USERPROFILE '.cargo' 'bin' 'rustup.exe')) { Write-SkSkip 'rustup present'; return 0 }
  $a = 'x86_64'; if ($script:Arch -eq 'arm64') { $a = 'aarch64' }
  if ($script:DryRun) { Write-Host "    would download and run: https://win.rustup.rs/$a -y" -ForegroundColor DarkGray; return 0 }
  $exe = Join-SkPath (Get-SkTemp) 'rustup-init.exe'
  try { Get-SkDownload "https://win.rustup.rs/$a" $exe } catch { Write-SkErr 'rustup download failed'; return 1 }
  if ((Invoke-SkCmd -File $exe -Arguments @('-y')) -ne 0) { return 1 }
  Update-SkPath
  Add-SkHint 'Rust on Windows compiles with the MSVC linker: install the "Visual Studio Build Tools" item if cargo build fails'
  return 0
}

function item_claude_code {
  if ((Test-Path -LiteralPath (Join-SkPath $env:USERPROFILE '.local' 'bin' 'claude.exe')) -or (Test-SkCommand claude)) { Write-SkSkip 'Claude Code present'; return 0 }
  if ((Invoke-SkScript 'https://claude.ai/install.ps1') -ne 0) { return 1 }
  Update-SkPath
  Add-SkHint 'start Claude Code in any project with: claude   (open a new terminal first)'
  return 0
}

# ---- shell & terminal -----------------------------------------------------------
function item_git_defaults {
  Update-SkPath
  if (-not (Test-SkCommand git)) {
    if ($script:DryRun) { Write-SkLog 'would set git defaults once git is installed'; return 0 }
    return (Skip-SkNA "git isn't installed (the Essentials item installs it)")
  }
  $pairs = [ordered]@{
    'init.defaultBranch' = 'main'; 'pull.rebase' = 'true'; 'push.autoSetupRemote' = 'true'; 'fetch.prune' = 'true'
    'rerere.enabled' = 'true'; 'diff.colorMoved' = 'default'; 'core.longpaths' = 'true'
  }
  if (Test-SkCommand delta) { $pairs['core.pager'] = 'delta'; $pairs['interactive.diffFilter'] = 'delta --color-only'; $pairs['delta.navigate'] = 'true' }
  foreach ($k in $pairs.Keys) {
    $r = Invoke-SkCapture -File git -Arguments @('config', '--global', '--get', $k)
    if ($r.Code -eq 0) { continue }   # yours: kept
    [void](Invoke-SkCmd -File git -Arguments @('config', '--global', $k, $pairs[$k]))
  }
  if ((Invoke-SkCapture -File git -Arguments @('config', '--global', '--get', 'user.name')).Code -ne 0) { Add-SkHint 'set your git name:  git config --global user.name "Your Name"' }
  if ((Invoke-SkCapture -File git -Arguments @('config', '--global', '--get', 'user.email')).Code -ne 0) { Add-SkHint 'set your git email:  git config --global user.email you@example.com' }
  return 0
}

function item_lazyvim {
  if ((Install-SkScoop @('neovim', 'ripgrep', 'fd')) -ne 0) { return 1 }
  $cfg = Join-SkPath $env:LOCALAPPDATA 'nvim'
  if (Test-Path -LiteralPath $cfg) { return (Skip-SkNA "you already have a Neovim config in $cfg — not replacing it") }
  if ((Invoke-SkCmd -File git -Arguments @('clone', '-q', '--depth=1', 'https://github.com/LazyVim/starter', $cfg)) -ne 0) { return 1 }
  if (-not $script:DryRun) { Remove-Item -LiteralPath (Join-SkPath $cfg '.git') -Recurse -Force }
  Add-SkHint 'open nvim once and let LazyVim finish installing its plugins'
  return 0
}

# PowerShell profile: serverkit's config lives in %APPDATA%\serverkit\profile.ps1
# and your profile (both PowerShell 7 and Windows PowerShell) gets one marked
# line that loads it. Remove the block and it's gone.
function item_pwsh_setup {
  if ((Install-SkScoop @('zoxide', 'fzf', 'eza')) -ne 0) { return 1 }
  $ours = Join-SkPath $script:ConfigDir 'profile.ps1'
  [void](Write-SkFile $ours ([IO.File]::ReadAllText((Join-SkPath $script:Root 'files' 'win' 'profile.ps1'))))
  $line = 'if (Test-Path "$env:APPDATA\serverkit\profile.ps1") { . "$env:APPDATA\serverkit\profile.ps1" }'
  foreach ($dir in 'PowerShell', 'WindowsPowerShell') {
    Set-SkBlock (Join-SkPath (Get-SkDocuments) $dir 'profile.ps1') 'serverkit' $line
  }
  # Optional modules from the PowerShell Gallery: icons in listings, fzf keys.
  foreach ($m in 'Terminal-Icons', 'PSFzf') {
    if (Get-Module -ListAvailable -Name $m) { Write-SkSkip "module $m present"; continue }
    $ok = Invoke-SkAction "install PowerShell module $m (current user)" {
      if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
      }
      Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    if (-not $ok) { Write-SkWarn "module $m wasn't installed — the profile works without it" }
  }
  Add-SkHint 'open a new terminal to use the new PowerShell setup'
  return 0
}

# Windows Terminal reads "fragments" from its own folder and merges them in, so
# serverkit never edits your settings.json.
function item_windows_terminal {
  $dir = Join-SkPath $env:LOCALAPPDATA 'Microsoft' 'Windows Terminal' 'Fragments' 'serverkit'
  [void](Write-SkFile (Join-SkPath $dir 'serverkit.json') ([IO.File]::ReadAllText((Join-SkPath $script:Root 'files' 'win' 'terminal-fragment.json'))))
  $wt = (Test-SkCommand wt) -or (Test-Path -LiteralPath (Join-SkPath $env:LOCALAPPDATA 'Microsoft' 'WindowsApps' 'wt.exe'))
  if (-not $wt -and -not $script:DryRun) { $wt = ((Invoke-SkAppx '(Get-AppxPackage -Name Microsoft.WindowsTerminal) -ne $null').Output -match 'True') }
  if (-not $wt) {
    Add-SkHint 'Windows Terminal is not installed — the "Windows Terminal" desktop item installs it; the setup applies once it is'
  } else {
    Add-SkHint 'restart Windows Terminal: PowerShell profiles now use JetBrains Mono Nerd Font and the serverkit color scheme'
  }
  return 0
}
