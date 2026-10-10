# managed-by:serverkit — loaded from your PowerShell profile (profile.ps1).
# Put your own settings in that profile, after the serverkit block; serverkit
# never edits them. Every integration is guarded: a missing tool means
# silence, not errors (-ErrorAction Ignore keeps your $Error list clean too).
# Works in PowerShell 7 and Windows PowerShell 5.1.

# ---- PSReadLine: predictive history, better keys (interactive consoles only) ----
# Everything is checked up front rather than tried: PowerShell records even a
# caught error in your $Error list.
if ((Get-Module -ListAvailable -Name PSReadLine) -and -not [Console]::IsOutputRedirected) {
  Import-Module PSReadLine -ErrorAction Ignore
  Set-PSReadLineOption -HistoryNoDuplicates -HistorySearchCursorMovesToEnd -BellStyle None
  # predictions need PSReadLine 2.1+ (Windows PowerShell 5.1 ships 2.0); ListView needs 50x5
  $_skPsrl = Get-Module PSReadLine
  if ($_skPsrl -and $_skPsrl.Version -ge [version]'2.1.0') {
    $_skView = 'InlineView'
    # safe to read here: output isn't redirected (checked above)
    if ([Console]::WindowWidth -ge 50 -and [Console]::WindowHeight -ge 5) { $_skView = 'ListView' }
    Set-PSReadLineOption -PredictionSource History -PredictionViewStyle $_skView -ErrorAction Ignore
  }
  Remove-Variable _skPsrl, _skView -ErrorAction Ignore
  Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
  Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
  Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}

# ---- tools ----
if (Get-Command starship -ErrorAction Ignore) { Invoke-Expression (& starship init powershell) }
if (Get-Command zoxide -ErrorAction Ignore) { Invoke-Expression (& { (zoxide init powershell | Out-String) }) }
if (Get-Command mise -ErrorAction Ignore) { mise activate pwsh | Out-String | Invoke-Expression }
if (Get-Module -ListAvailable -Name Terminal-Icons) { Import-Module Terminal-Icons -ErrorAction Ignore }
if ((Get-Module -ListAvailable -Name PSFzf) -and (Get-Command fzf -ErrorAction Ignore)) {
  Import-Module PSFzf -ErrorAction Ignore
  Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
}

# ---- shortcuts: additive only; PowerShell's own commands and aliases keep working ----
if (Get-Command eza -ErrorAction Ignore) {
  function ll { eza -lah --git --group-directories-first @args }
  function lt { eza --tree --level=2 @args }
}
if (Get-Command lazygit -ErrorAction Ignore) { Set-Alias -Name lg -Value lazygit }
if (Get-Command lazydocker -ErrorAction Ignore) { Set-Alias -Name lzd -Value lazydocker }
if (Get-Command kubectl -ErrorAction Ignore) { Set-Alias -Name k -Value kubectl }
if (Get-Command nvim -ErrorAction Ignore) { Set-Alias -Name vi -Value nvim }
if (Get-Command docker -ErrorAction Ignore) { function dc { docker compose @args } }
function gst { git status -sb @args }
function .. { Set-Location .. }
function ... { Set-Location ..\.. }
