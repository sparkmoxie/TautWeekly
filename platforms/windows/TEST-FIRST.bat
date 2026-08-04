@echo off
cd /d "%~dp0"
echo ============================================================
echo TAUTWEEKLY FOR PLEX - GUIDED FIRST TEST
echo Nothing is sent to real Plex users in this workflow.
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TautWeekly.ps1" -Mode ListUsers
echo.
set /p USERID=Enter UserId, username, friendly name, or email to simulate:
if "%USERID%"=="" exit /b 1
echo.
echo STEP 1 - Browser preview
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TautWeekly.ps1" -Mode Preview -UserId "%USERID%"
if errorlevel 1 (
  echo Preview failed. Fix that before sending a test.
  pause
  exit /b 1
)
echo.
choice /C YN /N /M "Send the same personalized version to TestEmail? [Y/N]: "
if errorlevel 2 (
  echo Test email skipped.
  pause
  exit /b 0
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TautWeekly.ps1" -Mode SendTest -UserId "%USERID%"
echo.
pause
