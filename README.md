# Wear OS Windows Bridge

A Windows command-line helper for pairing a Wear OS watch over Wi-Fi, connecting with Android Debug Bridge (ADB), mirroring the watch with scrcpy, and sideloading APK files.

Repository: https://git.tak.gov/aegorsuch/wearos-windows-bridge

## Requirements

- Windows 10 or later
- A Wear OS watch and Windows PC on the same network
- A scrcpy release containing both `scrcpy.exe` and `adb.exe`
- Wireless debugging enabled on the watch
- PowerShell, available by default on supported Windows versions

## First Run

1. Download and extract scrcpy to a folder on the PC.
2. Run `wearos-windows-bridge.bat`.
3. Select **1. Setup scrcpy System PATH**.
4. Enter the path to the folder containing both `scrcpy.exe` and `adb.exe`.
5. Restart any separate Command Prompt windows if necessary.

The helper adds the folder to the current user's PATH. It does not modify the system-wide PATH.

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
3. Use the saved IP address when offered, or enter it manually.
4. Enter the connection port shown after the colon on the main screen.

The helper saves the IP address and connection ports in `ip_cache.txt`. This file is local-only and is ignored by Git.

## Screen Mirroring

After connecting, select **4. Launch Screen Mirroring**. The helper passes the saved `IP:connection-port` to scrcpy so duplicate ADB entries, including mDNS entries, do not cause an ambiguous-device error.

## Sideload an APK

After connecting, select **5. Sideload an APK File**, then drag an APK file into the window and press Enter. The APK is installed on the selected watch with replacement and runtime permissions enabled.

The install uses the saved direct ADB connection and disables streamed installation for better reliability over wireless debugging.

## Reset

Select **6. Reset ADB Server / Clear Status** to:

- Stop the ADB server
- Clear the saved IP and port values
- Delete `ip_cache.txt`
- Clear the local PATH-setup marker

This does not remove the scrcpy folder from the user PATH, unpair the watch, remove installed apps, or delete ADB keys.

Option **7. Exit** closes the helper without resetting anything.

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

Use the port from the main Wireless Debugging screen, not the pairing port. Confirm the PC and watch are on the same network.

### Text entry through scrcpy does not save

Some watch apps require pressing their own Done, Enter, or checkmark control to commit text. If text works when entered directly on the watch but not through scrcpy, the behavior is likely specific to the app's text-field handling.
