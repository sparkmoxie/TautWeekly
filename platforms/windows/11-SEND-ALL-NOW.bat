@echo off
cd /d "%~dp0"
echo.
echo ============================================================
echo TAUTWEEKLY FOR PLEX - SEND THE WEEKLY NEWSLETTER
echo This sends real email to all eligible users and their eligible household copies.
echo Review 02-LIST-USERS.bat and exclusions before continuing.
echo ============================================================
echo.
set /p CONFIRM=Type SEND to continue:
if /I not "%CONFIRM%"=="SEND" (
  echo Cancelled.
  pause
  exit /b 0
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TautWeekly.ps1" -Mode SendAll -ConfirmSendAll
echo.
pause
