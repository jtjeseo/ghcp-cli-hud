@echo off
setlocal
if not defined COPILOT_HOME for %%I in ("%~dp0..") do set "COPILOT_HOME=%%~fI"
chcp 65001 >nul
"%SystemRoot%\System32\where.exe" pwsh.exe >nul 2>nul
if errorlevel 1 goto windows_powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0statusline.ps1"
exit /b %ERRORLEVEL%
:windows_powershell
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0statusline.ps1"
exit /b %ERRORLEVEL%
