# serverkit for Windows — entry point. Started by serverkit.cmd (or directly:
#   powershell -ExecutionPolicy Bypass -File win\serverkit.ps1 [args]).
# Works in Windows PowerShell 5.1 and PowerShell 7.
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
. ([IO.Path]::Combine($PSScriptRoot, 'lib', 'load.ps1'))
$code = 1
try { $code = [int]"$(@(Invoke-SkMain $args)[-1])" }
catch { if ("$($_.Exception.Message)" -ne 'serverkit-stop') { Write-SkErr "$_" }; $code = 1 }
finally { Clear-SkTemp }
exit $code
