# Pester 5 tests for the Windows side. Platform-neutral logic only, so they
# also run in PowerShell on Linux:  Invoke-Pester tests/win
BeforeAll {
  $script:SkRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
  $env:USERPROFILE = Join-Path ([IO.Path]::GetTempPath()) ("skhome-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
  $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData/Local'
  $env:APPDATA = Join-Path $env:USERPROFILE 'AppData/Roaming'
  . (Join-Path $SkRoot 'win/lib/load.ps1')
  $script:Root = $SkRoot
  Import-SkCatalog
  $script:IsAdmin = $false
  Initialize-SkResolution
}

Describe 'catalog on Windows' {
  It 'uses win= targets' { Resolve-SkSpec 'ripgrep' | Should -Be 'scoop:ripgrep' }
  It 'uses winget for desktop apps' { Resolve-SkSpec 'vscode' | Should -Be 'winget:Microsoft.VisualStudioCode' }
  It 'accepts all= only for npm/builtin/none' {
    Resolve-SkSpec 'gemini' | Should -Be 'npm:@google/gemini-cli'
    Resolve-SkSpec 'zsh-setup' | Should -Be ''
  }
  It 'hides Unix-only items' { Test-SkAvailable 'fail2ban' | Should -BeFalse }
  It 'maps a homebrew need to scoop' { Get-SkDeps 'pwsh-setup' | Should -Contain 'scoop' }
  It 'adds implicit dependencies' {
    Get-SkDeps 'vscode' | Should -Contain 'winget'
    Get-SkDeps 'gemini' | Should -Contain 'runtimes'
  }
  It 'orders a plan by the catalog' {
    (Resolve-SkPlan @('ripgrep')).Plan -join ' ' | Should -Be 'scoop ripgrep'
  }
  It 'marks administrator items' {
    Test-SkSystemItem 'developer-mode' | Should -BeTrue
    Test-SkSystemItem 'ripgrep' | Should -BeFalse
  }
  It 'skips Scoop items when running as administrator' {
    $script:IsAdmin = $true; Initialize-SkResolution
    Test-SkAvailable 'ripgrep' | Should -BeFalse
    (Resolve-SkPlan @('ripgrep', 'developer-mode')).Plan | Should -Be @('developer-mode')
    $script:IsAdmin = $false; Initialize-SkResolution
  }
  It 'produces valid JSON' {
    $j = Get-SkCatalogJson | ConvertFrom-Json
    $j.platform.os | Should -Be 'win'
    @($j.items).Count | Should -BeGreaterThan 100
  }
}

Describe 'settings' {
  It 'loads every profile; multi-line values join' {
    foreach ($p in 'desktop', 'minimal', 'personal', 'apps') {
      Import-SkSettings $p
      Get-SkSetting 'ITEMS' | Should -Not -BeNullOrEmpty
      (Get-SkSetting 'ITEMS') | Should -Not -Match "`n"
    }
  }
  It 'never executes a value' {
    New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
    $flag = Join-Path $env:USERPROFILE 'pwned'
    Set-Content (Join-Path $script:ConfigDir 'config.conf') "DOMAIN=`$(New-Item $flag)"
    Import-SkSettings ''
    Test-Path $flag | Should -BeFalse
    Get-SkSetting 'DOMAIN' | Should -Be "`$(New-Item $flag)"
    Remove-Item (Join-Path $script:ConfigDir 'config.conf')
  }
  It 'rejects unknown --set names' {
    $script:OptSet = @('NOPE=1')
    { Import-SkSettings '' } | Should -Throw
    $script:OptSet = @()
  }
}

Describe 'files' {
  BeforeEach { $script:TestFile = Join-Path $env:USERPROFILE ("f-" + [guid]::NewGuid().ToString('N').Substring(0, 6)); $script:DryRun = $false; $script:Force = $false }
  It 'creates, then leaves an identical file alone' {
    Write-SkFile $TestFile "# $Marker`nx" | Should -BeTrue
    Write-SkFile $TestFile "# $Marker`nx" | Should -BeFalse
  }
  It 'never overwrites a file it did not write' {
    Set-Content $TestFile 'mine'
    Write-SkFile $TestFile "# $Marker`nours" | Should -BeFalse
    (Get-Content $TestFile) | Should -Be 'mine'
    Get-Content "$TestFile.new" -Raw | Should -Match 'ours'
  }
  It 'updates its own file and keeps a backup' {
    Write-SkFile $TestFile "# $Marker`nold" | Out-Null
    Write-SkFile $TestFile "# $Marker`nnew" | Should -BeTrue
    Get-Content "$TestFile.bak.$Stamp" -Raw | Should -Match 'old'
  }
  It 'tracks unmarked (JSON) files by checksum until you edit them' {
    Write-SkFile $TestFile '{ "a": 1 }' | Out-Null
    Write-SkFile $TestFile '{ "a": 2 }' | Should -BeTrue
    Set-Content $TestFile '{ "mine": true }'
    Write-SkFile $TestFile '{ "a": 3 }' | Should -BeFalse
    Test-Path "$TestFile.new" | Should -BeTrue
  }
  It 'writes nothing in a dry run' {
    $script:DryRun = $true
    Write-SkFile $TestFile 'x' | Out-Null
    Test-Path $TestFile | Should -BeFalse
    $script:DryRun = $false
  }
  It 'keeps your profile around its block, idempotently' {
    Set-Content $TestFile "mine 1`nmine 2"
    Set-SkBlock $TestFile 'demo' 'ours'
    Set-SkBlock $TestFile 'demo' 'ours v2'
    Set-SkBlock $TestFile 'demo' 'ours v2'
    $t = Get-Content $TestFile
    $t[0] | Should -Be 'mine 1'
    ($t | Where-Object { $_ -eq '# >>> serverkit:demo >>>' }).Count | Should -Be 1
    $t | Should -Contain 'ours v2'
    $t | Should -Not -Contain 'ours'
  }
  It 'writes UTF-8 without a BOM' {
    Write-SkFile $TestFile "# $Marker ✓" | Out-Null
    [IO.File]::ReadAllBytes($TestFile)[0] | Should -Not -Be 0xEF
  }
}

Describe 'items' {
  It 'takes the last value an item emits as its exit code' {
    function item_fake_noisy { 'some output'; 3 }
    $script:Res['fake'] = 'ps:fake_noisy'
    Invoke-SkItem 'fake' | Should -Be 3
  }
  It 'every ps/psadmin function named by the catalog exists' {
    foreach ($id in $script:ItemOrder) {
      foreach ($tok in ($script:Items[$id].Spec -split '\s+')) {
        if ($tok -match '^win=(ps|psadmin):(.+)$') { Get-Command "item_$($Matches[2])" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because $id }
      }
    }
  }
}
