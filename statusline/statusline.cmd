@echo off
setlocal
if not defined COPILOT_HOME for %%I in ("%~dp0..") do set "COPILOT_HOME=%%~fI"
chcp 65001 >nul
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0statusline.ps1"
exit /b %ERRORLEVEL%
