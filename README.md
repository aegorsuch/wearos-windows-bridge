# Wear OS Windows Bridge

A Windows command-line helper for pairing a Wear OS watch over Wi-Fi, connecting with Android Debug Bridge (ADB), mirroring the watch with scrcpy, and sideloading APK files.

Repository: https://git.tak.gov/aegorsuch/wearos-windows-bridge

## Requirements

- Windows 10 or later
- A Wear OS watch and Windows PC on the same network
- A scrcpy release containing both `scrcpy.exe` and `adb.exe`
- Wireless debugging enabled on the watch
- PowerShell, available by default on supported Windows versions

## New to Batch Files?

A `.bat` file is a small script that Windows runs like a program. To use this helper:

1. Double-click `wearos-windows-bridge.bat` (or right-click it and choose **Open**) to launch it. A black console window will open with a numbered menu.
2. If Windows shows a **Windows protected your PC** SmartScreen warning, click **More info**, then **Run anyway**. This warning is common for downloaded batch files; before running it, confirm you downloaded it from the expected repository or a trusted source.
3. Type the number of the menu option you want and press Enter. Follow the on-screen prompts.
4. To type a folder or file path when asked, you can drag the file/folder from File Explorer directly into the console window instead of typing it out.
5. Press `Ctrl+C` to cancel a running command (such as Live Watch Logs), or close the window at any time to quit.

## First Run

1. Download scrcpy from https://github.com/Genymobile/scrcpy/releases (the `scrcpy-win64` zip from the latest release) and extract it to a folder on the PC.
2. Run `wearos-windows-bridge.bat`.
3. Select **1. Setup scrcpy System Path**.
4. Drag and drop the folder containing both `scrcpy.exe` and `adb.exe` into the window, or type/paste its path.
5. Restart any separate Command Prompt windows if necessary.

The helper adds the folder to the current user's PATH. It does not modify the system-wide PATH.

## Enable Developer Options and Wireless Debugging

Before pairing, enable the required settings on the watch:

1. Swipe down from the top of the watch screen to open the quick panel.
2. Tap the **Settings** gear icon, then select **About Watch**.
3. Select **Software**, then tap **Software Version** repeatedly until the watch displays **Developer mode turned on**.
4. Return to the main Settings screen and open **Developer Options**. It is usually at the bottom of the list or just below **About Watch**.
5. Turn on **ADB Debugging**.
6. Open **Wireless Debugging** and turn it on.
7. Make sure the watch is connected to a Wi-Fi network.

## Pair the Watch

On the watch:

1. Open **Developer Options > Wireless Debugging**.
2. Select **Pair new device**.
3. Note the IP address and pairing port shown in the pairing screen.
4. Note the six-digit number at the top labeled **Wi-Fi pairing code**.

In the helper, select **2. First Time Setup: Pair Watch via Wi-Fi** and enter those values when prompted.

Pairing and connection use different ports. The pairing port is shown after selecting **Pair new device**. The connection port is shown on the main **Wireless Debugging** screen.

## Connect to the Watch

1. Return to the main **Wireless Debugging** screen on the watch.
2. Select **3. Connect to Watch**.
3. If the saved watch is unavailable, the helper will check which authorized devices are currently visible through ADB and offer the active one automatically.
4. Use the saved IP address when offered, or enter it manually.
5. Enter the connection port shown after the colon on the main screen.

The helper saves the IP address and connection ports in `ip_cache.txt`. This file is local-only and is ignored by Git.

If the first connection attempt is stale, offline, or waiting for watch approval, the helper retries up to three times. It restarts its local ADB server once during recovery and lets you enter a replacement connection port if the watch regenerated it. Press Enter to retry the current port. The helper preserves the previous saved connection if all attempts fail.

## Device Overview and Recovery

The bottom of the main menu shows a live device overview with counts for authorized, unauthorized, and offline watches detected by ADB. The menu labels saved pairing and connection details as cached information rather than claiming that the watch is currently paired or connected. If the saved watch is not currently active, the helper now automatically checks the visible authorized devices, resolves mDNS device names to their actual IP address and port, and offers the correct one before falling back to manual entry.

If you select **3. Connect to Watch** before pairing a watch through the helper, it explains that pairing is required and directs you to **2. First Time Setup: Pair Watch via Wi-Fi**.

## Screen Mirroring

After connecting, select **4. Launch Screen Mirroring**. The helper passes the saved `IP:connection-port` to scrcpy so duplicate ADB entries, including mDNS entries, do not cause an ambiguous-device error.

## Sideload an APK

After connecting, select **5. Sideload an APK File**, then drag an APK file into the window and press Enter. The APK is installed on the selected watch with replacement and runtime permissions enabled.

The install uses the saved direct ADB connection and disables streamed installation for better reliability over wireless debugging.

## Bulk Sideload an APK to Multiple Watches

Select **6. Bulk Sideload APK (All Connected Devices)** to install one APK across every watch `adb` currently sees in the `device` (authorized) state, without connecting to each one individually first.

Each watch must already be paired with this PC at least once (see **2. First Time Setup**) and have Wireless Debugging turned on while on the same network; already-paired watches are typically auto-discovered by `adb` over mDNS and require no manual Connect step. Run `adb devices` yourself first if you want to confirm which watches will be targeted.

The helper lists every detected serial, then installs the chosen APK to each in turn with the same flags as single-device sideloading (`-r -g --no-streaming`), printing a per-device result and a final success/failure summary.

## View Live Watch Logs

After connecting, select **7. Live Watch Logs** to stream new log lines to the console while saving them to a timestamped file. Enter an optional keyword to show and save only matching lines, or press Enter to see all logs. Keywords may contain letters, numbers, periods, underscores, and hyphens, such as `weartak` or `takserver.aftakcoe.org`.

Reproduce the issue while the stream is running, then press `Ctrl+C` to stop capture and return to the menu.

Log filenames use this format:

`ip_port_watch_log_keyword_startdatetime_enddatetime.txt`

For example: `10.0.0.169_34419_watch_log_takserver.aftakcoe.org_20260923-211500_20260923-211745.txt`.

When no keyword is supplied, the filename uses `none`.

The log is written directly to `watch_logs\` as it streams, using a temporary `..._inprogress.txt` name that is renamed to include the end time once capture stops. This means a capture is never stranded elsewhere if the window is closed or the batch job is terminated mid-stream.

The `watch_logs` folder is ignored by Git because logs may contain device, application, or user data. Share a log only after reviewing it for sensitive information. Select **8. Open Logs Folder** from the main menu at any time to open this folder in File Explorer.

## Reset

Select **9. Reset ADB Server / Clear Status** to:

- Stop the ADB server
- Clear the saved IP and port values
- Delete `ip_cache.txt`
- Clear the local PATH-setup marker

You'll be asked to type `CONFIRM` before anything is cleared. The reset targets the ADB process associated with the helper's configured `adb.exe`; it does not remove the scrcpy folder from the user PATH, unpair the watch, remove installed apps, or delete ADB keys.

## Diagnose and Export Support Data

Select **10. Diagnose Environment** to check the local ADB and scrcpy setup, PATH visibility, and detected device states. Select **11. Export Diagnostic Bundle** to create a zip containing environment details, ADB state, saved connection metadata, and local logs for troubleshooting. Review the contents for sensitive information before sharing the zip.

## Report an Issue

Select **12. Report an Issue** to open a browser to file an issue on GitHub (https://github.com/aegorsuch/wearos-windows-bridge/issues). Enter the step number that had the problem and a description of what happened; the helper pre-fills the issue title and description with your answers.

Option **13. Exit** closes the helper without resetting anything.

## Local Files

The helper creates these local files beside the batch file:

- `ip_cache.txt` - saved watch IP and ports; ignored by Git
- `path_configured.txt` - local marker indicating PATH setup was completed; ignored by Git

The six-digit pairing code is used only during pairing and is not saved.

## Troubleshooting

### More than one ADB device

Reconnect through option 3. Mirroring and APK installation use the saved direct `IP:port` connection to select the correct watch.

### Pairing fails

Confirm that Wireless Debugging and **Pair new device** are open on the watch, then verify the pairing port and six-digit Wi-Fi pairing code.

### Connection fails

Use the port from the main Wireless Debugging screen, not the pairing port. If the first connection attempt fails and the watch shows a different port, enter that new port when prompted. Confirm the PC and watch are on the same network.

### Watch shows "unauthorized"

If the watch's screen has an "Allow debugging?" prompt, confirm it there, then reconnect. The helper detects this case and asks if you want to retry.

### "adb server is out of date" or devices behave inconsistently

If another program that bundles its own `adb.exe` is also installed (for example Android Studio), it can start a conflicting adb server on the same port. Close other adb-based tools, or run **9. Reset ADB Server / Clear Status** to stop the ADB process associated with this helper before reconnecting. If pairing fails with a "protocol fault" style error, the helper restarts the adb server for you — reopen "Pair new device" on the watch for a fresh code and port, then select **2. First Time Setup: Pair Watch via Wi-Fi** again. If it keeps failing the same way, use the reset option and pair again.

### Text entry through scrcpy does not save

Some watch apps require pressing their own Done, Enter, or checkmark control to commit text. If text works when entered directly on the watch but not through scrcpy, the behavior is likely specific to the app's text-field handling.
