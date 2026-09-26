# Wear OS Windows Bridge

A Windows command-line helper for pairing a Wear OS watch over Wi-Fi, connecting with Android Debug Bridge (ADB), mirroring the watch with scrcpy, and sideloading APK files.

Repository: https://git.tak.gov/aegorsuch/wearos-windows-bridge

## Requirements

- Windows 10 or later
- A Wear OS watch and Windows PC on the same network
- A scrcpy release containing both `scrcpy.exe` and `adb.exe`
- Wireless debugging enabled on the watch
- PowerShell, available by default on supported Windows versions

## Getting Started

A `.bat` file is a small script that Windows runs like a program. To use this helper:

1. Double-click `wearos-windows-bridge.bat` (or right-click it and choose **Open**) to launch it. A console window will open with a numbered menu.
2. If Windows shows a **Windows protected your PC** SmartScreen warning, click **More info**, then **Run anyway**. This warning is common for downloaded batch files; before running it, confirm you downloaded it from the expected repository or a trusted source.
3. Type the number of the menu option you want and press Enter. Follow the on-screen prompts. Close the console window to quit.
4. To type a folder or file path when asked, you can drag the file/folder from File Explorer directly into the console window instead of typing it out.
5. Press `Ctrl+C` to cancel a running command (such as Live Watch Logs).

## First Run

1. Download scrcpy from https://github.com/Genymobile/scrcpy/releases (the `scrcpy-win64` zip from the latest release) and extract it to a folder on the PC.
2. Run `wearos-windows-bridge.bat`.
3. Select **1. Setup scrcpy System Path**.
4. Drag and drop the folder containing both `scrcpy.exe` and `adb.exe` into the window, or type/paste its path.
5. This makes the tools available for the current bridge session. If the scrcpy folder is not already on your Windows PATH, repeat this step the next time you launch the bridge.

The helper does not modify your permanent user or system PATH.

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

In the helper, select **2. Pair Watch via Wi-Fi** and enter those values when prompted. Pairing saves the watch IP and pairing port for the active profile; it does not mean the watch is currently connected.

Pairing and connection use different ports. The pairing port is shown after selecting **Pair new device**. The connection port is shown on the main **Wireless Debugging** screen.

## Connect to the Watch

1. Return to the main **Wireless Debugging** screen on the watch.
2. In the helper, select **3. Connect to Watch**.
3. Enter the watch IP address and the connection port shown on the main Wireless Debugging screen. Leave the IP blank to use the saved IP. The connection port can change when Wireless Debugging restarts.

The helper saves the IP address and ports in `ip_cache.txt` and in the active profile. These are local settings and are ignored by Git.

The bridge starts the ADB server before attempting a connection and retries unsuccessful connections. The menu reports pairing from saved settings and connection from the live ADB device list, so a saved pairing can remain even when the watch is offline.

## Screen Mirroring

After connecting, select **4. Launch Screen Mirroring**. The helper reconnects to the saved `IP:connection-port` and passes that endpoint to scrcpy.

## Sideload an APK

After connecting, select **5. Sideload an APK File**, then enter or drag an APK file path into the window and press Enter. The bridge checks the connection, displays install progress, and reports ADB's install result. The APK is installed on the selected watch with replacement and runtime permissions enabled.

The install uses the saved direct ADB connection and disables streamed installation for better reliability over wireless debugging. If the watch disconnects during installation, wake it, enable Wireless Debugging, reconnect, and retry if ADB did not report `Success`.

## View Live Watch Logs

After connecting, select **6. Live Watch Logs** to stream new log lines to the console while saving them to a timestamped file. Enter an optional keyword to show and save only matching lines, or press Enter to see all logs. Keywords may contain letters, numbers, periods, underscores, and hyphens, such as `weartak` or `takserver.aftakcoe.org`.

Reproduce the issue while the stream is running, then press `Ctrl+C` to stop capture and return to the menu.

Log filenames use this format:

`ip_port_watch_log_keyword_startdatetime_enddatetime.txt`

For example: `10.0.0.169_34419_watch_log_takserver.aftakcoe.org_20260923-211500_20260923-211745.txt`.

When no keyword is supplied, the filename uses `none`.

The log is written directly to `watch_logs\` as it streams, using a temporary `..._inprogress.txt` name that is renamed to include the end time once capture stops. This means a capture is never stranded elsewhere if the window is closed or the batch job is terminated mid-stream.

The `watch_logs` folder is ignored by Git because logs may contain device, application, or user data. Open `watch_logs` beside the bridge files in File Explorer to review captures. Share a log only after checking it for sensitive information.

## Local Files

The helper creates these local files beside the batch file:

- `ip_cache.txt` - saved watch IP and ports; ignored by Git
- `path_configured.txt` - local marker indicating PATH setup was completed; ignored by Git
- `watch_profiles.json` and `active_profile.txt` - saved watch profiles and the selected profile; ignored by Git
- `watch_logs/` - captured logs; ignored by Git

The six-digit pairing code is used only during pairing and is not saved.

## PowerShell core, profiles, and automation

The helper now ships with a PowerShell-based core and a small batch launcher for compatibility. This gives the project more robust ADB recovery, structured status output, and profile support for multiple watches.

### Multi-watch profiles

Profiles are optional. If you only use one Wear OS watch, you can ignore them and keep using the default setup. The profile system is mainly a convenience for multi-watch setups, where each watch keeps its own saved IP, pairing port, and connection port.

This is useful when you have more than one Wear OS device in your setup. For example, you might keep one profile for your primary watch (`ODIN-WEARTAK`) and another for a dev device (`ODIN-WEARTAK-4`). That way each device keeps its own saved settings, and you can switch without retyping setup details each time.

If you do want to manage profiles, either use the menu flow or the command-line options:

- `--profile-list`
- `--profile-use NAME`
- `--profile-delete NAME`

The `default` profile cannot be deleted, but you can create and switch to other names like `ODIN-WEARTAK` or `ODIN-WEARTAK-4` for separate devices. For a quick menu-based removal, enter `DELETE NAME` in the profile management prompt.

### Developer Tools

Developer Tools is always available as **7. Developer Tools** on the main menu. It contains:

- **Manage Profiles** - create, switch, and delete saved watch profiles.
- **Bulk Sideload APK** - install an APK to all currently authorized ADB devices.
- **Diagnose Environment** - show ADB, scrcpy, profile, and device information.
- **Export Diagnostic Bundle** - currently a placeholder; bundle export is not implemented yet.
- **Pair + Connect + Mirror** - run the pairing, connection, and mirroring flow.

Profiles are optional. For more than one watch, create a profile for each device (for example, `ODIN-WEARTAK` and `ODIN-WEARTAK-4`) and switch profiles before pairing or connecting. Each profile stores its own IP and ports. The `default` profile cannot be deleted.

The bulk sideload action targets every ADB device currently in the authorized `device` state. Check the listed devices before using it if more than one watch or Android device is connected.

### Structured status output

The PowerShell script exposes `--status-json` for scripts or automation. It returns installation/configuration flags, saved pairing and connection state, the active profile, profile settings, and the current ADB device summary as JSON.

### Self-healing ADB recovery

The PowerShell core starts the local ADB server before wireless connection attempts and retries failed connections. Pairing failures also trigger ADB recovery. The connection port shown in Wireless Debugging can change, so update it when reconnecting if needed.

### One-click pair + connect + mirror

Use **7. Developer Tools > 5. Pair + Connect + Mirror** for the guided flow, or run `wearos-windows-bridge.bat --pair-connect-mirror` for the command-line flow. The command prompts for any values not supplied as arguments.

## Troubleshooting

### More than one ADB device

Reconnect through option 3. Mirroring and APK installation use the saved direct `IP:port` connection to select the correct watch.

### Pairing fails

Confirm that Wireless Debugging and **Pair new device** are open on the watch, then verify the pairing port and six-digit Wi-Fi pairing code.

### Connection fails

Use the port from the main Wireless Debugging screen, not the pairing port. Enter the current IP address and connection port in **3. Connect to Watch**. The connection port can change when Wireless Debugging restarts. Confirm the PC and watch are on the same network and keep the watch awake while connecting or installing.

### Watch shows "unauthorized"

If ADB reports the watch as `unauthorized`, confirm the **Allow debugging?** prompt on the watch, then connect again.

### "adb server is out of date" or devices behave inconsistently

If another program that bundles its own `adb.exe` is also installed (for example Android Studio), it can start a conflicting ADB server on the same port. Close other ADB-based tools and retry. If pairing fails with a protocol-fault error, the bridge attempts ADB recovery; reopen **Pair new device** on the watch for a fresh code and port, then retry **2. Pair Watch via Wi-Fi**.

### Text entry through scrcpy does not save

Some watch apps require pressing their own Done, Enter, or checkmark control to commit text. If text works when entered directly on the watch but not through scrcpy, the behavior is likely specific to the app's text-field handling.
