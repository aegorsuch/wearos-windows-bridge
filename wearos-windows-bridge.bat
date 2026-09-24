@echo off
setlocal EnableDelayedExpansion
title Galaxy Watch Ultra ADB Helper
color 0A
chdir /d "%~dp0"

set "SAVED_IP=None"
set "SAVED_PAIR_PORT="
set "SAVED_CONN_PORT="
set "PATH_SETUP=0"

if exist "%~dp0ip_cache.txt" (
    < "%~dp0ip_cache.txt" (
        set /p SAVED_IP=
        set /p SAVED_PAIR_PORT=
        set /p SAVED_CONN_PORT=
    )
)

if "!SAVED_CONN_PORT:~5,1!" NEQ "" set "SAVED_CONN_PORT="

if exist "%~dp0path_configured.txt" (
    set "PATH_SETUP=1"
)

:MENU
cls
set "STEP0_STATUS="
set "STEP1_STATUS= (Not Paired)"
set "STEP2_STATUS= (Not Connected)"

set "STEP0_STATUS= (Not Configured)"
if "!PATH_SETUP!"=="1" set "STEP0_STATUS= (Configured)"

if not "!SAVED_PAIR_PORT!"=="" (
    if not "!SAVED_PAIR_PORT!"=="ECHO is off." (
        set "STEP1_STATUS= (Paired to !SAVED_IP!:!SAVED_PAIR_PORT!)"
    )
) else if not "!SAVED_IP!"=="None" (
    set "STEP1_STATUS= (Paired to !SAVED_IP!)"
)

if not "!SAVED_CONN_PORT!"=="" (
    set "STEP2_STATUS= (Connected to !SAVED_IP!:!SAVED_CONN_PORT!)"
)

echo ===================================================
echo         GALAXY WATCH ULTRA ADB HELPER
echo ===================================================
echo  1. Setup scrcpy System PATH!STEP0_STATUS!
echo  2. First Time Setup: Pair Watch via Wi-Fi!STEP1_STATUS!
echo  3. Connect to Watch!STEP2_STATUS!
echo  4. Launch Screen Mirroring
echo  5. Sideload an APK File
echo  6. Capture Watch Logs
echo  7. Reset ADB Server / Clear Status
echo  8. Exit
echo ===================================================
set "choice="
set /p choice="Select an option (1-8): "

if "%choice%"=="1" goto SETUP_PATH
if "%choice%"=="2" goto PAIR
if "%choice%"=="3" goto CONNECT
if "%choice%"=="4" goto MIRROR
if "%choice%"=="5" goto SIDELOAD
if "%choice%"=="6" goto LOGS
if "%choice%"=="7" goto RESET
if "%choice%"=="8" exit
goto MENU

:SETUP_PATH
cls
echo SETUP SCRCPY SYSTEM PATH
echo ---------------------------------------------------
echo Instructions:
echo 1. Extract scrcpy anywhere on your PC (e.g., C:\Tools\scrcpy-win64).
echo 2. Paste the full folder path below to automatically add it to your
echo    Windows User PATH environment variable.
echo.
echo Manual Steps (If preferred):
echo - Press Windows Key, type 'env', and open Environment Variables.
echo - Under User Variables, edit 'Path', click New, and paste folder path.
echo ---------------------------------------------------
echo.
set /p user_scrcpy_path="Enter full path to scrcpy folder (e.g., C:\Tools\scrcpy-win64): "

if not exist "!user_scrcpy_path!\scrcpy.exe" (
    echo.
    echo WARNING: Could not find scrcpy.exe inside "!user_scrcpy_path!".
    echo Please double check the folder path and try again.
    echo.
    pause
    goto MENU
)

if not exist "!user_scrcpy_path!\adb.exe" (
    echo.
    echo WARNING: Could not find adb.exe inside "!user_scrcpy_path!".
    echo Please use the folder containing both scrcpy.exe and adb.exe.
    echo.
    pause
    goto MENU
)

echo.
echo Adding "!user_scrcpy_path!" to User PATH environment variable...
set "SCRCPY_PATH=!user_scrcpy_path!"
powershell.exe -NoProfile -Command "$folder=$env:SCRCPY_PATH; $current=[Environment]::GetEnvironmentVariable('Path','User'); $parts=@($current -split ';' | Where-Object { $_ }); if ($parts -notcontains $folder) { [Environment]::SetEnvironmentVariable('Path', (($parts + $folder) -join ';'), 'User') }"
if errorlevel 1 (
    echo.
    echo WARNING: Could not update the User PATH environment variable.
    echo.
    pause
    goto MENU
)
set "PATH=!user_scrcpy_path!;%PATH%"
set "PATH_SETUP=1"
echo Configured > "%~dp0path_configured.txt"

echo.
echo SUCCESS: PATH configured successfully!
echo Note: If launching from a separate terminal window, restart CMD to apply.
echo.
pause
goto MENU

:PAIR
cls
echo PAIRING WATCH
echo ---------------------------------------------------
echo 1. On watch: Developer Options - Wireless Debugging
echo 2. Tap Pair new device
echo.
set /p watch_ip="Enter Watch IP Address (e.g., 10.0.0.169): "
set "CHECK_IP=!watch_ip!"
powershell.exe -NoProfile -Command "if ($env:CHECK_IP -notmatch '^(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$') { exit 1 }" >nul
if errorlevel 1 (
    echo Invalid IP address.
    pause
    goto MENU
)
echo.
set /p pair_port="Enter Pairing Port (the number after the colon, e.g. 38583): "
set "CHECK_PORT=!pair_port!"
powershell.exe -NoProfile -Command "if ($env:CHECK_PORT -notmatch '^\d{1,5}$' -or [int]$env:CHECK_PORT -lt 1) { exit 1 }" >nul
if errorlevel 1 (
    echo Invalid pairing port.
    pause
    goto MENU
)
echo.
set /p pair_code="Enter 6-Digit Pairing Code (the number at the top labeled Wi-Fi pairing code): "
set "CHECK_CODE=!pair_code!"
powershell.exe -NoProfile -Command "if ($env:CHECK_CODE -notmatch '^\d{6}$') { exit 1 }" >nul
if errorlevel 1 (
    echo Invalid pairing code.
    pause
    goto MENU
)
echo.
adb pair !watch_ip!:!pair_port! !pair_code!
echo.
if errorlevel 1 (
    echo Pairing failed. Nothing was saved.
    pause
    goto MENU
)
set "SAVED_IP=!watch_ip!"
set "SAVED_PAIR_PORT=!pair_port!"
call :SAVE_CACHE

pause
goto MENU

:CONNECT
cls
echo CONNECT TO WATCH
echo ---------------------------------------------------
echo Note: Use the Port listed on the MAIN Wireless Debugging screen
echo.
set "use_saved=N"
if not "!SAVED_IP!"=="None" (
    echo Saved IP detected: !SAVED_IP!
    set /p use_saved="Use saved IP? (Y/N): "
)

if /i "!use_saved!"=="Y" (
    set "watch_ip=!SAVED_IP!"
) else (
    set /p watch_ip="Enter Watch IP Address: "
)

set "CHECK_IP=!watch_ip!"
powershell.exe -NoProfile -Command "if ($env:CHECK_IP -notmatch '^(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$') { exit 1 }" >nul
if errorlevel 1 (
    echo Invalid IP address.
    pause
    goto MENU
)

echo.
set /p conn_port="Enter Connection Port (the number after the colon, e.g. 45625): "
set "CHECK_PORT=!conn_port!"
powershell.exe -NoProfile -Command "if ($env:CHECK_PORT -notmatch '^\d{1,5}$' -or [int]$env:CHECK_PORT -lt 1) { exit 1 }" >nul
if errorlevel 1 (
    echo Invalid connection port.
    pause
    goto MENU
)
echo.
adb connect !watch_ip!:!conn_port!
echo.
if errorlevel 1 (
    echo Connection failed. Nothing was saved.
    pause
    goto MENU
)
set "SAVED_IP=!watch_ip!"
set "SAVED_CONN_PORT=!conn_port!"
call :SAVE_CACHE

pause
goto MENU

:MIRROR
cls
echo LAUNCHING SCRCPY
echo ---------------------------------------------------
if "!SAVED_IP!"=="None" (
    echo No saved watch connection. Connect to the watch first.
    echo.
    pause
    goto MENU
)
if "!SAVED_CONN_PORT!"=="" (
    echo No saved connection port. Connect to the watch first.
    echo.
    pause
    goto MENU
)
echo Running stream...
echo.
scrcpy.exe --serial="!SAVED_IP!:!SAVED_CONN_PORT!" --max-size=360 --video-bit-rate=1M
echo.
pause
goto MENU

:SIDELOAD
cls
echo SIDELOAD APK
echo ---------------------------------------------------
if "!SAVED_IP!"=="None" (
    echo No saved watch connection. Connect to the watch first.
    echo.
    pause
    goto MENU
)
if "!SAVED_CONN_PORT!"=="" (
    echo No saved connection port. Connect to the watch first.
    echo.
    pause
    goto MENU
)
echo Drag and drop your APK file here, then press ENTER.
echo.
set /p apk_path="APK Path: "
set "apk_path=!apk_path:"=!"
if not exist "!apk_path!" (
    echo APK file not found.
    pause
    goto MENU
)
set "CHECK_PATH=!apk_path!"
powershell.exe -NoProfile -Command "if ($env:CHECK_PATH -match '[&|<>^!]') { exit 1 }" >nul
if errorlevel 1 (
    echo APK path contains unsupported command characters.
    pause
    goto MENU
)
echo.
adb -s "!SAVED_IP!:!SAVED_CONN_PORT!" install -r -g --no-streaming "!apk_path!"
if errorlevel 1 (
    echo.
    echo APK installation failed. See the ADB error above for details.
)
echo.
pause
goto MENU

:RESET
cls
echo Resetting ADB server and clearing session memory...
adb kill-server
set "SAVED_IP=None"
set "SAVED_PAIR_PORT="
set "SAVED_CONN_PORT="
set "PATH_SETUP=0"
if exist "%~dp0ip_cache.txt" del "%~dp0ip_cache.txt"
if exist "%~dp0path_configured.txt" del "%~dp0path_configured.txt"
echo Done!
timeout /t 2 >nul
goto MENU

:LOGS
cls
echo CAPTURE WATCH LOGS
echo ---------------------------------------------------
if "!SAVED_IP!"=="None" (
    echo No saved watch connection. Connect to the watch first.
    echo.
    pause
    goto MENU
)
if "!SAVED_CONN_PORT!"=="" (
    echo No saved connection port. Connect to the watch first.
    echo.
    pause
    goto MENU
)
if not exist "%~dp0watch_logs" mkdir "%~dp0watch_logs"
for /f "delims=" %%T in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "LOG_TIMESTAMP=%%T"
set "LOG_FILE=%~dp0watch_logs\watch-log-!LOG_TIMESTAMP!.txt"
set "LOG_FILTER="
set /p LOG_FILTER="Optional keyword filter (press ENTER for all logs): "
set "CHECK_FILTER=!LOG_FILTER!"
powershell.exe -NoProfile -Command "if ($env:CHECK_FILTER -match '[&|<>^]') { exit 1 }" >nul
if errorlevel 1 (
    echo Log filter contains unsupported command characters.
    pause
    goto MENU
)
set "RAW_LOG_FILE=%TEMP%\wearos-watch-log-!LOG_TIMESTAMP!.txt"
echo Capturing logs from !SAVED_IP!:!SAVED_CONN_PORT!...
adb -s "!SAVED_IP!:!SAVED_CONN_PORT!" logcat -d > "!RAW_LOG_FILE!" 2>&1
if errorlevel 1 (
    if exist "!RAW_LOG_FILE!" del "!RAW_LOG_FILE!"
    echo Log capture failed. See the ADB output above for details.
) else (
    if "!LOG_FILTER!"=="" (
        move /y "!RAW_LOG_FILE!" "!LOG_FILE!" >nul
    ) else (
        findstr /i /c:"!LOG_FILTER!" "!RAW_LOG_FILE!" > "!LOG_FILE!"
        del "!RAW_LOG_FILE!"
        if errorlevel 1 echo No log lines matched "!LOG_FILTER!".
    )
    echo Logs saved to:
    echo !LOG_FILE!
)
echo.
pause
goto MENU

:SAVE_CACHE
(
    echo(!SAVED_IP!
    echo(!SAVED_PAIR_PORT!
    echo(!SAVED_CONN_PORT!
) > "%~dp0ip_cache.txt"
exit /b