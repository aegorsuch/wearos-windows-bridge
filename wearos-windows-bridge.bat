@echo off
setlocal EnableDelayedExpansion
title WearOS Windows Bridge
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
echo             WEAROS WINDOWS BRIDGE
echo ===================================================
echo  1. Setup scrcpy System Path!STEP0_STATUS!
echo  2. First Time Setup: Pair Watch via Wi-Fi!STEP1_STATUS!
echo  3. Connect to Watch!STEP2_STATUS!
echo  4. Launch Screen Mirroring
echo  5. Sideload an APK File
echo  6. Bulk Sideload APK (All Connected Devices)
echo  7. Live Watch Logs
echo  8. Open Logs Folder
echo  9. Reset ADB Server / Clear Status
echo 10. Diagnose Environment
echo 11. Export Diagnostic Bundle
echo 12. Report an Issue
echo 13. Exit
echo ===================================================
set "choice="
set /p choice="Select an option (1-13): "

if "%choice%"=="1" goto SETUP_PATH
if "%choice%"=="2" goto PAIR
if "%choice%"=="3" goto CONNECT
if "%choice%"=="4" goto MIRROR
if "%choice%"=="5" goto SIDELOAD
if "%choice%"=="6" goto BULK_SIDELOAD
if "%choice%"=="7" goto LIVE_LOGS
if "%choice%"=="8" goto OPEN_LOGS_FOLDER
if "%choice%"=="9" goto RESET
if "%choice%"=="10" goto DIAGNOSE_ENVIRONMENT
if "%choice%"=="11" goto EXPORT_DIAGNOSTICS
if "%choice%"=="12" goto REPORT_ISSUE
if "%choice%"=="13" exit
goto MENU

:SETUP_PATH
cls
echo SETUP SCRCPY SYSTEM PATH
echo ---------------------------------------------------
echo Download scrcpy (includes adb.exe) from:
echo https://github.com/Genymobile/scrcpy/releases
echo Grab the "scrcpy-win64" zip from the latest release.
echo.
echo Instructions:
echo 1. Extract scrcpy anywhere on your PC (e.g., C:\Tools\scrcpy-win64).
echo 2. Drag and drop the extracted folder here, or paste its full path,
echo    to automatically add it to your Windows User PATH environment
echo    variable.
echo.
echo Manual Steps (If preferred):
echo - Press Windows Key, type 'env', and open Environment Variables.
echo - Under User Variables, edit 'Path', click New, and paste folder path.
echo ---------------------------------------------------
echo.
set /p user_scrcpy_path="Drag & drop or enter full path to scrcpy folder (e.g., C:\Tools\scrcpy-win64): "
set "user_scrcpy_path=!user_scrcpy_path:"=!"
for %%I in ("!user_scrcpy_path!") do set "user_scrcpy_path=%%~fI"
set "CHECK_PATH=!user_scrcpy_path!"
powershell.exe -NoProfile -Command "if ($env:CHECK_PATH -match '[!&|<>^]') { exit 1 }" >nul
if errorlevel 1 (
    echo.
    echo WARNING: Folder path contains unsupported command characters.
    echo Use a normal Windows folder path such as C:\Tools\scrcpy-win64.
    echo.
    pause
    goto MENU
)

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
echo Before pairing, enable these settings on the watch:
echo 1. Swipe down from the top and open Settings.
echo 2. Select About Watch - Software.
echo 3. Tap Software Version repeatedly until you see:
echo    Developer mode turned on
echo 4. Return to Settings and open Developer Options.
echo 5. Turn on ADB Debugging.
echo 6. Open Wireless Debugging and turn it on.
echo 7. Make sure the watch is connected to Wi-Fi.
echo.
echo In Wireless Debugging, tap Pair new device.
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
set "PAIR_LOG=%TEMP%\wearos-pair-!RANDOM!.txt"
adb pair !watch_ip!:!pair_port! !pair_code! > "!PAIR_LOG!" 2>&1
set "PAIR_RESULT=!errorlevel!"
type "!PAIR_LOG!"
echo.
if not "!PAIR_RESULT!"=="0" (
    echo Pairing failed. Nothing was saved.
    set "PAIR_STALE_HINT=0"
    findstr /i /c:"protocol fault" "!PAIR_LOG!" >nul
    if not errorlevel 1 set "PAIR_STALE_HINT=1"
    set "PAIR_NET_HINT=0"
    findstr /i /c:"failed to connect" /c:"connection refused" /c:"no route to host" /c:"connection timed out" "!PAIR_LOG!" >nul
    if not errorlevel 1 set "PAIR_NET_HINT=1"
    if "!PAIR_STALE_HINT!"=="1" (
        echo.
        echo This is usually caused by a stale or mismatched adb server left running
        echo by another program such as Android Studio's bundled adb, or by a
        echo pairing code/port that expired or was already used.
        echo Restarting the adb server now so the next attempt starts clean...
        adb kill-server >nul 2>nul
        call :KILL_LOCAL_ADB
        echo Done. Select "Pair Watch via Wi-Fi" again to retry - on the watch,
        echo reopen "Pair new device" first for a fresh code and port.
        echo.
        echo If it keeps failing with the SAME "protocol fault" error even with a
        echo fresh code, an adb.exe process tied to this helper may still be stuck.
        echo Run option 9 "Reset ADB Server / Clear Status" to clear this helper's
        echo local ADB state, then pair again.
    )
    if "!PAIR_NET_HINT!"=="1" (
        echo.
        echo This usually means the IP address or pairing port is wrong, or the
        echo watch and PC are not on the same Wi-Fi network.
    )
    del "!PAIR_LOG!" >nul 2>nul
    pause
    goto MENU
)
del "!PAIR_LOG!" >nul 2>nul
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

set "AUTO_TARGET=0"
set "watch_ip="
set "conn_port="
if /i "!use_saved!"=="Y" (
    set "watch_ip=!SAVED_IP!"
    if not "!SAVED_CONN_PORT!"=="" (
        set "conn_port=!SAVED_CONN_PORT!"
    )
) else (
    set "AUTO_TARGET=1"
    set "TARGET_COUNT=0"
    for /f "skip=1 tokens=1,2" %%A in ('adb devices 2^>nul') do (
        if "%%B"=="device" (
            set /a TARGET_COUNT+=1
            set "TARGET_SERIAL_!TARGET_COUNT!=%%A"
        )
    )
    if "!TARGET_COUNT!"=="1" (
        set "watch_ip=!TARGET_SERIAL_1!"
        set "watch_ip=!watch_ip: =!"
        set "AUTO_TARGET=0"
    ) else if "!TARGET_COUNT!" GTR "1" (
        echo Multiple authorized devices were found.
        echo.
        for /l %%N in (1,1,!TARGET_COUNT!) do (
            echo   %%N. !TARGET_SERIAL_%%N!
        )
        set /p target_choice="Select the device number to connect to: "
        if not "!target_choice!"=="" (
            set /a PICKED=!target_choice! 2>nul
            if not "!PICKED!"=="" if !PICKED! GEQ 1 if !PICKED! LEQ !TARGET_COUNT! (
                set "watch_ip=!TARGET_SERIAL_!PICKED!!"
                set "watch_ip=!watch_ip: =!"
                set "AUTO_TARGET=0"
            )
        )
    )
)

if "!AUTO_TARGET!"=="1" (
    set /p watch_ip="Enter Watch IP Address: "
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
) else (
    if "!watch_ip!"=="" (
        echo No device selected.
        pause
        goto MENU
    )
    if "!conn_port!"=="" (
        set /p conn_port="Enter Connection Port (the number after the colon, e.g. 45625): "
        set "CHECK_PORT=!conn_port!"
        powershell.exe -NoProfile -Command "if ($env:CHECK_PORT -notmatch '^\d{1,5}$' -or [int]$env:CHECK_PORT -lt 1) { exit 1 }" >nul
        if errorlevel 1 (
            echo Invalid connection port.
            pause
            goto MENU
        )
    )
)
echo.
set "PREV_SAVED_IP=!SAVED_IP!"
set "PREV_SAVED_CONN_PORT=!SAVED_CONN_PORT!"
set "CONN_RETRY_COUNT=0"
set "CONN_MAX_RETRIES=3"
:CONNECT_RETRY
set /a CONN_ATTEMPT=CONN_RETRY_COUNT+1
echo Connection attempt !CONN_ATTEMPT! of !CONN_MAX_RETRIES!...
if !CONN_RETRY_COUNT! GTR 0 adb disconnect !watch_ip!:!conn_port! >nul 2>nul
adb connect !watch_ip!:!conn_port!
echo.
set "SAVED_IP=!watch_ip!"
set "SAVED_CONN_PORT=!conn_port!"
call :CHECK_CONNECTION
if "!CONN_STATE!"=="unauthorized" (
    if !CONN_ATTEMPT! LSS !CONN_MAX_RETRIES! (
        set /a CONN_RETRY_COUNT+=1
        echo Watch is waiting for approval. Please accept the prompt on the watch,
        echo then the helper will retry automatically in 3 seconds.
        timeout /t 3 /nobreak >nul
        goto CONNECT_RETRY
    )
    echo Connection still unauthorized. Nothing was saved.
    set "SAVED_IP=!PREV_SAVED_IP!"
    set "SAVED_CONN_PORT=!PREV_SAVED_CONN_PORT!"
    pause
    goto MENU
)
if "!CONN_OK!"=="0" (
    if !CONN_ATTEMPT! LSS !CONN_MAX_RETRIES! (
        set /a CONN_RETRY_COUNT+=1
        if "!CONN_RETRY_COUNT!"=="1" (
            echo Connection failed or is stale. Restarting the local ADB server...
            adb kill-server >nul 2>nul
            call :KILL_LOCAL_ADB
        ) else (
            echo Connection is still unavailable. Retrying automatically in 3 seconds...
        )
        timeout /t 3 /nobreak >nul
        goto CONNECT_RETRY
    )
    echo Connection failed. Nothing was saved.
    set "SAVED_IP=!PREV_SAVED_IP!"
    set "SAVED_CONN_PORT=!PREV_SAVED_CONN_PORT!"
    pause
    goto MENU
)
call :SAVE_CACHE

pause
if not "!CONNECT_RETURN!"=="" (
    set "RETURN_TARGET=!CONNECT_RETURN!"
    set "CONNECT_RETURN="
    goto !RETURN_TARGET!
)
goto MENU

:MIRROR
cls
echo LAUNCHING SCRCPY
echo ---------------------------------------------------
call :REQUIRE_ADB
if "!TOOLS_OK!"=="0" (
    pause
    goto MENU
)
where scrcpy.exe >nul 2>nul
if errorlevel 1 (
    echo.
    echo scrcpy was not found on your PATH. Select "1. Setup scrcpy System Path"
    echo from the main menu, then try again. Restart this window if you already
    echo completed setup.
    echo.
    pause
    goto MENU
)
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
echo Checking connection to !SAVED_IP!:!SAVED_CONN_PORT!...
call :CHECK_CONNECTION
if "!CONN_OK!"=="0" (
    set "CONNECT_RETURN=MIRROR"
    call :OFFER_RECONNECT
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
call :REQUIRE_ADB
if "!TOOLS_OK!"=="0" (
    pause
    goto MENU
)
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
echo Checking connection to !SAVED_IP!:!SAVED_CONN_PORT!...
call :CHECK_CONNECTION
if "!CONN_OK!"=="0" (
    set "CONNECT_RETURN=SIDELOAD"
    call :OFFER_RECONNECT
    goto MENU
)

echo.
set /p apk_path="APK Path: "
set "apk_path=!apk_path:"=!"
for %%I in ("!apk_path!") do set "apk_path=%%~fI"
if not exist "!apk_path!" (
    echo APK file not found.
    pause
    goto MENU
)
if /i not "!apk_path:~-4!"==".apk" (
    echo WARNING: "!apk_path!" does not end in .apk. Make sure you dragged the correct file.
    pause
    goto MENU
)
set "CHECK_PATH=!apk_path!"
powershell.exe -NoProfile -Command "if ($env:CHECK_PATH -match '[!&|<>^]') { exit 1 }" >nul
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

:BULK_SIDELOAD
cls
echo BULK SIDELOAD APK (ALL CONNECTED DEVICES)
echo ---------------------------------------------------
call :REQUIRE_ADB
if "!TOOLS_OK!"=="0" (
    pause
    goto MENU
)
echo Scanning for connected and paired devices...
echo.
call :LIST_DEVICE_SUMMARY
set "BULK_COUNT=0"
for /f "skip=1 tokens=1,2" %%A in ('adb devices') do (
    if "%%B"=="device" (
        set /a BULK_COUNT+=1
        set "BULK_SERIAL_!BULK_COUNT!=%%A"
    )
)
if "!BULK_COUNT!"=="0" (
    echo No authorized devices were found. Make sure watches are paired,
    echo Wireless Debugging is turned on, and they are on this network.
    echo If a watch shows "unauthorized" or "offline", accept the prompt or
    echo reconnect it before retrying bulk install.
    echo.
    pause
    goto MENU
)
echo Found !BULK_COUNT! authorized device(s^):
for /l %%I in (1,1,!BULK_COUNT!) do echo   - !BULK_SERIAL_%%I!
echo.
echo Drag and drop your APK file here, then press ENTER.
echo.
set /p apk_path="APK Path: "
set "apk_path=!apk_path:"=!"
for %%I in ("!apk_path!") do set "apk_path=%%~fI"
if not exist "!apk_path!" (
    echo APK file not found.
    pause
    goto MENU
)
if /i not "!apk_path:~-4!"==".apk" (
    echo WARNING: "!apk_path!" does not end in .apk. Make sure you dragged the correct file.
    pause
    goto MENU
)
set "CHECK_PATH=!apk_path!"
powershell.exe -NoProfile -Command "if ($env:CHECK_PATH -match '[!&|<>^]') { exit 1 }" >nul
if errorlevel 1 (
    echo APK path contains unsupported command characters.
    pause
    goto MENU
)
echo.
set "BULK_OK=0"
set "BULK_FAIL=0"
for /l %%I in (1,1,!BULK_COUNT!) do (
    set "CUR_SERIAL=!BULK_SERIAL_%%I!"
    echo ---------------------------------------------------
    echo Installing to !CUR_SERIAL!...
    adb -s "!CUR_SERIAL!" install -r -g --no-streaming "!apk_path!"
    if errorlevel 1 (
        echo RESULT: FAILED - !CUR_SERIAL!
        set /a BULK_FAIL+=1
    ) else (
        echo RESULT: SUCCESS - !CUR_SERIAL!
        set /a BULK_OK+=1
    )
)
echo ---------------------------------------------------
echo.
echo Bulk sideload complete: !BULK_OK! succeeded, !BULK_FAIL! failed out of !BULK_COUNT!.
echo.
pause
goto MENU

:RESET
cls
echo RESET ADB SERVER / CLEAR STATUS
echo ---------------------------------------------------
echo This stops the ADB server, clears the saved IP/ports, and deletes
echo ip_cache.txt and path_configured.txt.
echo It does not remove the scrcpy install itself or your watch pairing.
echo.
set "reset_confirm="
set /p reset_confirm="Type CONFIRM and press Enter to continue: "
if /i not "!reset_confirm!"=="CONFIRM" goto MENU
echo.
echo Resetting ADB server and clearing session memory...
adb kill-server >nul 2>nul
call :KILL_LOCAL_ADB
set "SAVED_IP=None"
set "SAVED_PAIR_PORT="
set "SAVED_CONN_PORT="
set "PATH_SETUP=0"
if exist "%~dp0ip_cache.txt" del "%~dp0ip_cache.txt"
if exist "%~dp0path_configured.txt" del "%~dp0path_configured.txt"
echo Done!
timeout /t 2 >nul
goto MENU

:LIVE_LOGS
cls
echo LIVE WATCH LOGS
echo ---------------------------------------------------
call :REQUIRE_ADB
if "!TOOLS_OK!"=="0" (
    pause
    goto MENU
)
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
for /f "delims=" %%T in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "LOG_START=%%T"
set "LOG_SERIAL=!SAVED_IP!:!SAVED_CONN_PORT!"
set "LOG_FILTER="
set /p LOG_FILTER="Optional keyword filter (press ENTER for all logs): "
set "CHECK_FILTER=!LOG_FILTER!"
powershell.exe -NoProfile -Command "if ($env:CHECK_FILTER -notmatch '^[A-Za-z0-9._-]*$') { exit 1 }" >nul
if errorlevel 1 (
    echo Log filter may contain only letters, numbers, periods, underscores, and hyphens.
    pause
    goto MENU
)
if "!LOG_FILTER!"=="" (set "LOG_FILTER_TAG=none") else (set "LOG_FILTER_TAG=!LOG_FILTER!")
rem write straight to the final logs folder so a capture is never stranded in %TEMP% if interrupted
set "LIVE_LOG_FILE=%~dp0watch_logs\!SAVED_IP!_!SAVED_CONN_PORT!_watch_log_!LOG_FILTER_TAG!_!LOG_START!_inprogress.txt"
echo Streaming logs from !LOG_SERIAL!...
echo Press Ctrl+C to stop and return to the menu.
echo Logs are being saved live to:
echo !LIVE_LOG_FILE!
echo.
powershell.exe -NoProfile -Command "& adb.exe -s $env:LOG_SERIAL logcat -v time | ForEach-Object { if ([string]::IsNullOrWhiteSpace($env:LOG_FILTER) -or $_.ToString().IndexOf($env:LOG_FILTER, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Add-Content -Path $env:LIVE_LOG_FILE -Value $_; Write-Output $_ } }"
for /f "delims=" %%T in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "LOG_END=%%T"
set "FINAL_LOG_NAME=!SAVED_IP!_!SAVED_CONN_PORT!_watch_log_!LOG_FILTER_TAG!_!LOG_START!_!LOG_END!.txt"
if exist "!LIVE_LOG_FILE!" ren "!LIVE_LOG_FILE!" "!FINAL_LOG_NAME!"
echo.
echo Live log capture saved to:
if exist "%~dp0watch_logs\!FINAL_LOG_NAME!" (echo %~dp0watch_logs\!FINAL_LOG_NAME!) else (echo !LIVE_LOG_FILE!)
pause
goto MENU

:REPORT_ISSUE
cls
echo REPORT AN ISSUE
echo ---------------------------------------------------
echo This opens a browser to file an issue on GitHub with your
echo answers pre-filled into the title and description.
echo.
echo Which step had the issue?
echo  1. Setup scrcpy System Path
echo  2. Pair Watch via Wi-Fi
echo  3. Connect to Watch
echo  4. Launch Screen Mirroring
echo  5. Sideload an APK File
echo  6. Bulk Sideload APK (All Connected Devices)
echo  7. Live Watch Logs
echo  8. Open Logs Folder
echo  9. Reset ADB Server / Clear Status
echo 10. Diagnose Environment
echo 11. Export Diagnostic Bundle
echo 12. Other / Not listed
echo.
set /p issue_step="Enter the step number (1-12): "
set "ISSUE_STEP_DESC=Other / Not listed"
if "!issue_step!"=="1" set "ISSUE_STEP_DESC=Setup scrcpy System Path"
if "!issue_step!"=="2" set "ISSUE_STEP_DESC=Pair Watch via Wi-Fi"
if "!issue_step!"=="3" set "ISSUE_STEP_DESC=Connect to Watch"
if "!issue_step!"=="4" set "ISSUE_STEP_DESC=Launch Screen Mirroring"
if "!issue_step!"=="5" set "ISSUE_STEP_DESC=Sideload an APK File"
if "!issue_step!"=="6" set "ISSUE_STEP_DESC=Bulk Sideload APK (All Connected Devices)"
if "!issue_step!"=="7" set "ISSUE_STEP_DESC=Live Watch Logs"
if "!issue_step!"=="8" set "ISSUE_STEP_DESC=Open Logs Folder"
if "!issue_step!"=="9" set "ISSUE_STEP_DESC=Reset ADB Server / Clear Status"
if "!issue_step!"=="10" set "ISSUE_STEP_DESC=Diagnose Environment"
if "!issue_step!"=="11" set "ISSUE_STEP_DESC=Export Diagnostic Bundle"
echo.
set /p issue_comment="Describe what happened: "
set "ISSUE_COMMENT=!issue_comment!"
powershell.exe -NoProfile -Command "$title = 'Issue with Step ' + $env:issue_step + ' - ' + $env:ISSUE_STEP_DESC; $body = $env:ISSUE_COMMENT; $encTitle = [uri]::EscapeDataString($title); $encBody = [uri]::EscapeDataString($body); $url = 'https://github.com/aegorsuch/wearos-windows-bridge/issues/new?title=' + $encTitle + '&body=' + $encBody; Start-Process $url"
echo.
echo Opening the issue form in your browser...
echo.
pause
goto MENU

:DIAGNOSE_ENVIRONMENT
cls
echo DIAGNOSE ENVIRONMENT
echo ---------------------------------------------------
call :REQUIRE_ADB
if "!TOOLS_OK!"=="0" (
    pause
    goto MENU
)
where scrcpy.exe >nul 2>nul
if errorlevel 1 (
    echo scrcpy.exe was not found on PATH.
) else (
    echo scrcpy.exe: found on PATH
)
for /f "delims=" %%P in ('where adb.exe 2^>nul') do echo adb.exe: %%P
for /f "delims=" %%A in ('adb version 2^>nul') do echo ADB version: %%A
for /f "delims=" %%A in ('adb devices 2^>nul') do echo %%A
call :LIST_DEVICE_SUMMARY
pause
goto MENU

:EXPORT_DIAGNOSTICS
cls
echo EXPORT DIAGNOSTIC BUNDLE
echo ---------------------------------------------------
set "DIAG_ROOT=%~dp0diagnostics"
set "DIAG_TS=%DATE:/=-%_%TIME::=-%"
set "DIAG_TS=!DIAG_TS: =_!"
set "DIAG_OUT=%DIAG_ROOT%\wearos-diagnostics_!DIAG_TS!"
if exist "!DIAG_OUT!" rd /s /q "!DIAG_OUT!"
if exist "!DIAG_OUT!.zip" del "!DIAG_OUT!.zip"
mkdir "!DIAG_OUT!" >nul

echo Collecting environment and ADB details...
where adb.exe >nul 2>nul
if errorlevel 1 (
    echo adb.exe not found on PATH > "!DIAG_OUT!\adb_status.txt"
) else (
    adb version > "!DIAG_OUT!\adb_version.txt" 2>&1
    adb devices > "!DIAG_OUT!\adb_devices.txt" 2>&1
    if not "!SAVED_IP!"=="None" if not "!SAVED_CONN_PORT!"=="" (
        adb -s "!SAVED_IP!:!SAVED_CONN_PORT!" get-state > "!DIAG_OUT!\saved_device_state.txt" 2>&1
    )
)
where scrcpy.exe >nul 2>nul
if errorlevel 1 (
    echo scrcpy.exe not found on PATH > "!DIAG_OUT!\scrcpy_status.txt"
) else (
    echo scrcpy.exe found on PATH > "!DIAG_OUT!\scrcpy_status.txt"
)

set "ENV_SUMMARY=!DIAG_OUT!\environment.txt"
(
    echo Windows version:
    systeminfo | findstr /B /C:"OS Name" /C:"OS Version"
    echo.
    echo Current PATH:
    echo %PATH%
    echo.
    echo Saved values:
    echo Saved IP: !SAVED_IP!
    echo Saved Pair Port: !SAVED_PAIR_PORT!
    echo Saved Connection Port: !SAVED_CONN_PORT!
) > "!ENV_SUMMARY!"

if exist "%~dp0ip_cache.txt" copy "%~dp0ip_cache.txt" "!DIAG_OUT!\ip_cache.txt" >nul
if exist "%~dp0path_configured.txt" copy "%~dp0path_configured.txt" "!DIAG_OUT!\path_configured.txt" >nul
if exist "%~dp0watch_logs" xcopy "%~dp0watch_logs" "!DIAG_OUT!\watch_logs\" /E /I /Q >nul

powershell.exe -NoProfile -Command "Compress-Archive -Path '""!DIAG_OUT!""\*' -DestinationPath '""!DIAG_OUT!.zip""' -Force"
if errorlevel 1 (
    echo.
    echo Archive creation failed.
    pause
    goto MENU
)

echo.
echo Diagnostic bundle created at:
echo !DIAG_OUT!.zip
echo.
start "" "!DIAG_OUT!.zip"
pause
goto MENU

:OPEN_LOGS_FOLDER
if not exist "%~dp0watch_logs" mkdir "%~dp0watch_logs"
start "" "%~dp0watch_logs"
goto MENU

:REQUIRE_ADB
where adb.exe >nul 2>nul
if errorlevel 1 (
    echo.
    echo ADB was not found on your PATH. Select "1. Setup scrcpy System Path"
    echo from the main menu, then try again. Restart this window if you already
    echo completed setup.
    echo.
    set "TOOLS_OK=0"
) else (
    set "TOOLS_OK=1"
)
exit /b

:KILL_LOCAL_ADB
set "ADB_PATH="
for /f "delims=" %%P in ('where adb.exe 2^>nul') do (
    set "ADB_PATH=%%P"
    goto :KILL_LOCAL_ADB_PROCESS
)
exit /b

:KILL_LOCAL_ADB_PROCESS
if not "!ADB_PATH!"=="" (
    powershell.exe -NoProfile -Command "$path = $env:ADB_PATH; if ($path) { Get-CimInstance Win32_Process -Filter \"Name='adb.exe'\" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.ToLower() -eq $path.ToLower() } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }"
)
exit /b

:SAVE_CACHE
(
    echo(!SAVED_IP!
    echo(!SAVED_PAIR_PORT!
    echo(!SAVED_CONN_PORT!
) > "%~dp0ip_cache.txt"
exit /b

:CHECK_CONNECTION
set "CONN_STATE="
for /f "usebackq delims=" %%S in (`adb -s "!SAVED_IP!:!SAVED_CONN_PORT!" get-state 2^>nul`) do set "CONN_STATE=%%S"
if "!CONN_STATE!"=="device" (
    set "CONN_OK=1"
) else if "!CONN_STATE!"=="unauthorized" (
    set "CONN_OK=0"
) else (
    set "CONN_OK=0"
    if "!CONN_STATE!"=="" (
        set "CONN_STATE=offline"
    )
)
exit /b

:SCAN_FOR_TARGET
set "TARGET_DEVICE="
for /f "skip=1 tokens=1,2" %%A in ('adb devices 2^>nul') do (
    if "%%B"=="device" (
        if not "!TARGET_DEVICE!"=="" (
            set "TARGET_DEVICE=!TARGET_DEVICE!, %%A"
        ) else (
            set "TARGET_DEVICE=%%A"
        )
    )
)
exit /b

:SPLIT_SERIAL
set "TARGET_IP=%~1"
set "TARGET_PORT="
for /f "delims=: tokens=1,2" %%I in ("%~1") do (
    set "TARGET_IP=%%I"
    set "TARGET_PORT=%%J"
)
exit /b

:LIST_DEVICE_SUMMARY
echo Device status summary:
for /f "skip=1 tokens=1,2" %%A in ('adb devices 2^>nul') do (
    if "%%B"=="device" (
        echo   - %%A: authorized
    ) else if "%%B"=="unauthorized" (
        echo   - %%A: unauthorized (tap Allow on the watch)
    ) else if "%%B"=="offline" (
        echo   - %%A: offline (device unreachable or sleeping)
    ) else if not "%%A"=="List" (
        echo   - %%A: %%B
    )
)
if errorlevel 1 (
    echo   - none detected
)
echo.
exit /b

:CHOOSE_DEVICE
echo.
echo Available devices:
set "DEVICE_COUNT=0"
for /f "skip=1 tokens=1,2" %%A in ('adb devices 2^>nul') do (
    if "%%B"=="device" (
        set /a DEVICE_COUNT+=1
        set "DEVICE_SERIAL_!DEVICE_COUNT!=%%A"
        echo   !DEVICE_COUNT!. %%A
    )
)
if "!DEVICE_COUNT!"=="0" (
    echo No authorized devices found.
    echo.
    set "DEVICE_CHOICE="
    exit /b
)
set /p DEVICE_CHOICE="Select a device number (1-!DEVICE_COUNT!): "
if not "!DEVICE_CHOICE!"=="" (
    set /a DEV_NUM=!DEVICE_CHOICE! 2>nul
    if "!DEV_NUM!"=="" goto CHOOSE_DEVICE
    if !DEV_NUM! GEQ 1 if !DEV_NUM! LEQ !DEVICE_COUNT! (
        set "SELECTED_DEVICE="
        for /l %%N in (1,1,!DEVICE_COUNT!) do if "%%N"=="!DEV_NUM!" set "SELECTED_DEVICE=!DEVICE_SERIAL_%%N!"
        echo Selected: !SELECTED_DEVICE!
        exit /b
    )
)
echo Invalid device selection.
set "SELECTED_DEVICE="
exit /b

:OFFER_RECONNECT
echo.
if "!CONN_STATE!"=="unauthorized" (
    echo Watch !SAVED_IP!:!SAVED_CONN_PORT! reports "unauthorized".
    echo This usually means the watch is waiting for your approval.
    echo Check the watch screen for an "Allow debugging?" prompt and tap Allow,
    echo then try again. If you have multiple watches, confirm this is the right one.
    echo.
    set "reconnect_choice="
    set /p reconnect_choice="Retry connection now? (Y/N): "
    if /i "!reconnect_choice!"=="Y" goto CONNECT
    set "CONNECT_RETURN="
    pause
    exit /b
)
if "!CONN_STATE!"=="offline" (
    echo Saved connection !SAVED_IP!:!SAVED_CONN_PORT! is offline or unreachable.
    echo The watch may be asleep, moved off-network, or on a different wireless port.
    echo.
) else (
    echo Saved connection !SAVED_IP!:!SAVED_CONN_PORT! is stale or unreachable.
    echo The watch's wireless debugging port likely changed since last time.
    echo.
)
set "reconnect_choice="
set /p reconnect_choice="Reconnect now? (Y/N): "
if /i "!reconnect_choice!"=="Y" goto CONNECT
set "CONNECT_RETURN="
pause
exit /b