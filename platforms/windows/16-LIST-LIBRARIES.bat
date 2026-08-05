@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Library-Selection.ps1" -ListOnly
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" echo Library listing failed with exit code %EXITCODE%.
pause
exit /b %EXITCODE%
