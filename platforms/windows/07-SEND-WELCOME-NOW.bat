@echo off
cd /d "%~dp0"
echo.
echo ============================================================
echo TAUTWEEKLY FOR PLEX - REAL ONE-OFF WELCOME
echo WARNING: This sends to the selected user's ACTUAL email.
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TautWeekly.ps1" -Mode ListUsers
echo.
set /p USERID=Enter UserId, username, friendly name, or email to welcome:
if "%USERID%"=="" exit /b 1
echo.
set /p CONFIRM=Type WELCOME to send to the real user:
if /I not "%CONFIRM%"=="WELCOME" (
  echo Cancelled.
  pause
  exit /b 0
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TautWeekly.ps1" -Mode SendWelcome -UserId "%USERID%" -ConfirmWelcome
echo.
pause
