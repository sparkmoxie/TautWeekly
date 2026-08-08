@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Update.ps1" -PromptForUpdate
set "EXITCODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXITCODE%
