@echo off
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RESET-MANAGER-ACCESS.ps1"
if errorlevel 1 (
  echo.
  echo TautWeekly Manager access could not be reset. Review the message above.
  pause
)
