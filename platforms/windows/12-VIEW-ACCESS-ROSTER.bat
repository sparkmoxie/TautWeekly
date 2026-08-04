@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VIEW-ACCESS-ROSTER.ps1"
echo.
pause
