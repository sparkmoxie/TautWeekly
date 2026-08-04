@echo off
cd /d "%~dp0"
echo Current users:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlexWeekly.ps1" -Mode ListUsers
echo.
set /p USERID=Enter UserId, username, friendly name, or email to preview:
if "%USERID%"=="" exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlexWeekly.ps1" -Mode Preview -UserId "%USERID%"
echo.
pause
