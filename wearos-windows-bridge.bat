@echo off
setlocal
chdir /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0wearos-windows-bridge.ps1" %*
exit /b %ERRORLEVEL%
