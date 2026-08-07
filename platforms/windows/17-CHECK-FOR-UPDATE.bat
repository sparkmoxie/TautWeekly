@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Update.ps1"
if errorlevel 1 pause
