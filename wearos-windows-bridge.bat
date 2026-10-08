@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0wearos-windows-bridge.ps1" %*
exit /b %ERRORLEVEL%
