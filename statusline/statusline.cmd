@echo off
chcp 65001 >nul
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0statusline.ps1"
exit /b %ERRORLEVEL%
