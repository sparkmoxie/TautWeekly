@echo off
cd /d "%~dp0"
echo.
echo ============================================================
echo PLEXWEEKLY - REAL BULK SEND
echo WARNING: One personalized email is sent to every eligible user.
echo Review 02-LIST-USERS.bat and exclusions before continuing.
echo ============================================================
echo.
set /p CONFIRM=Type SEND to continue:
if /I not "%CONFIRM%"=="SEND" (
  echo Cancelled.
  pause
  exit /b 0
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlexWeekly.ps1" -Mode SendAll -ConfirmSendAll
echo.
pause
