@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlexWeekly.ps1" -Mode ListUsers
echo.
pause
