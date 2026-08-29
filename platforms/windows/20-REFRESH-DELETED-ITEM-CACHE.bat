@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
echo TAUTWEEKLY FOR PLEX - REFRESH DELETED-ITEM CACHE
echo Checks every included user and selected library. No email is sent.
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TautWeekly.ps1" -Mode CacheWarm
set "EXITCODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXITCODE%
