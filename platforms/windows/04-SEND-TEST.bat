@echo off
cd /d "%~dp0"
echo ============================================================
echo TAUTWEEKLY FOR PLEX - SEND ONE SAFE TEST
echo The personalized message is sent ONLY to TestEmail in config.json.
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TautWeekly.ps1" -Mode ListUsers
echo.
set /p USERID=Enter UserId, username, friendly name, or email to simulate:
if "%USERID%"=="" exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TautWeekly.ps1" -Mode SendTest -UserId "%USERID%"
echo.
pause
