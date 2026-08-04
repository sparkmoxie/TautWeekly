@echo off
cd /d "%~dp0"
echo ============================================================
echo PLEXWEEKLY - PREVIEW ALL EMAIL TYPES
echo Creates SIX local HTML previews. No email is sent.
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlexWeekly.ps1" -Mode ListUsers
echo.
set /p USERID=Enter UserId, username, friendly name, or email to simulate:
if "%USERID%"=="" exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlexWeekly.ps1" -Mode PreviewAll -UserId "%USERID%"
echo.
pause
