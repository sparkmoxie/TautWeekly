@echo off
cd /d "%~dp0"
echo ============================================================
echo TAUTWEEKLY FOR PLEX - SEND SIX TEST MESSAGES
echo This sends six test messages only to TestEmail in config.json.
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TautWeekly.ps1" -Mode ListUsers
echo.
set /p USERID=Enter UserId, username, friendly name, or email to simulate:
if "%USERID%"=="" exit /b 1
choice /C YN /N /M "Send six test messages to TestEmail now? [Y/N]: "
if errorlevel 2 exit /b 0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TautWeekly.ps1" -Mode SendTestAll -UserId "%USERID%"
echo.
pause
