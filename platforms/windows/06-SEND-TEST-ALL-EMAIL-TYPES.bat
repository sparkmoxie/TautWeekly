@echo off
cd /d "%~dp0"
echo ============================================================
echo PLEXWEEKLY - SEND ALL EMAIL TYPES TO TESTEMAIL ONLY
echo This sends SIX messages, all to TestEmail in config.json.
echo No Plex user receives them.
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlexWeekly.ps1" -Mode ListUsers
echo.
set /p USERID=Enter UserId, username, friendly name, or email to simulate:
if "%USERID%"=="" exit /b 1
choice /C YN /N /M "Send six test messages to TestEmail now? [Y/N]: "
if errorlevel 2 exit /b 0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlexWeekly.ps1" -Mode SendTestAll -UserId "%USERID%"
echo.
pause
