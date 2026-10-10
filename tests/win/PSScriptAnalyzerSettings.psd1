# Lint rules for serverkit's PowerShell. Excluded rules, and why:
@{
  Severity     = @('Error', 'Warning')
  ExcludeRules = @(
    'PSAvoidUsingWriteHost',                       # an interactive CLI: Write-Host is its output
    'PSUseShouldProcessForStateChangingFunctions', # every change already honours --dry-run
    'PSUseApprovedVerbs',                          # internal helpers, not a published module
    'PSUseSingularNouns',
    'PSAvoidUsingEmptyCatchBlock',                 # deliberate best-effort probes (older Windows lacks some APIs)
    'PSAvoidGlobalVars'                            # $global:LASTEXITCODE is reset on purpose before native calls
  )
}
