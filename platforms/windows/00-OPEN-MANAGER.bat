@echo off
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0START-MANAGER.ps1"
if errorlevel 1 (
  echo.
  echo TautWeekly Manager could not be opened. Review the message above.
  pause
)
