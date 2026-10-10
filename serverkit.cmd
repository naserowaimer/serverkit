@echo off
rem serverkit launcher for Windows: prefers PowerShell 7, falls back to the built-in 5.1.
rem -ExecutionPolicy Bypass applies to this process only; nothing system-wide changes.
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0win\serverkit.ps1" %*
) else (
  powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0win\serverkit.ps1" %*
)
exit /b %ERRORLEVEL%
