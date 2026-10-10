# managed-by:serverkit — loaded from your PowerShell profile (profile.ps1).
# Put your own settings in that profile, after the serverkit block; serverkit
# never edits them. Every integration is guarded: a missing tool means
# silence, not errors. Works in PowerShell 7 and Windows PowerShell 5.1.

# ---- PSReadLine: predictive history, better keys ----
if (Get-Module -ListAvailable -Name PSReadLine) {
  Import-Module PSReadLine -ErrorAction SilentlyContinue
  Set-PSReadLineOption -HistoryNoDuplicates -HistorySearchCursorMovesToEnd -BellStyle None
  try { Set-PSReadLineOption -PredictionSource History -PredictionViewStyle ListView -ErrorAction Stop } catch { }
  Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
  Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
  Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}

# ---- tools ----
if (Get-Command starship -ErrorAction SilentlyContinue) { Invoke-Expression (& starship init powershell) }
if (Get-Command zoxide -ErrorAction SilentlyContinue) { Invoke-Expression (& { (zoxide init powershell | Out-String) }) }
if (Get-Command mise -ErrorAction SilentlyContinue) { mise activate pwsh | Out-String | Invoke-Expression }
if (Get-Module -ListAvailable -Name Terminal-Icons) { Import-Module Terminal-Icons -ErrorAction SilentlyContinue }
if ((Get-Module -ListAvailable -Name PSFzf) -and (Get-Command fzf -ErrorAction SilentlyContinue)) {
  Import-Module PSFzf -ErrorAction SilentlyContinue
  Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
}

# ---- shortcuts: additive only; PowerShell's own commands and aliases keep working ----
if (Get-Command eza -ErrorAction SilentlyContinue) {
  function ll { eza -lah --git --group-directories-first @args }
  function lt { eza --tree --level=2 @args }
}
if (Get-Command lazygit -ErrorAction SilentlyContinue) { Set-Alias -Name lg -Value lazygit }
if (Get-Command lazydocker -ErrorAction SilentlyContinue) { Set-Alias -Name lzd -Value lazydocker }
if (Get-Command kubectl -ErrorAction SilentlyContinue) { Set-Alias -Name k -Value kubectl }
if (Get-Command nvim -ErrorAction SilentlyContinue) { Set-Alias -Name vi -Value nvim }
if (Get-Command docker -ErrorAction SilentlyContinue) { function dc { docker compose @args } }
function gst { git status -sb @args }
function .. { Set-Location .. }
function ... { Set-Location ..\.. }
