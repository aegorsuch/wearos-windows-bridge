BeforeAll {
    . (Join-Path $PSScriptRoot '..\wearos-windows-bridge.ps1')
}

Describe 'Automation argument validation' {
    It 'accepts order-independent modifiers and spaced paths' {
        $options = Read-AutomationArguments @('--install', '--json', '--profile', 'DEV', 'C:\my app\debug.apk', '--timeout', '30')
        $options.values[0] | Should -Be 'C:\my app\debug.apk'
        $options.profile | Should -Be 'DEV'
        $options.timeout | Should -Be 30
        $options.nonInteractive | Should -BeTrue
    }

    It 'rejects invalid options before running anything' -ForEach @(
        @{ Arguments = @('--install', 'app.apk', '--serial', 'one', '--profile', 'DEV') }
        @{ Arguments = @('--install', '--json') }
        @{ Arguments = @('--install', 'app.apk', 'extra') }
        @{ Arguments = @('--mirror', '--timeout', '0') }
        @{ Arguments = @('--mirror', '--timeout', '3601') }
        @{ Arguments = @('--mirror', '--timeout', 'oops') }
        @{ Arguments = @('--mirror', '--json', '--json') }
        @{ Arguments = @('--mirror', '--unknown') }
        @{ Arguments = @('--pair-connect-mirror', '--non-interactive') }
        @{ Arguments = @('--bulk-install', 'app.apk', '--serial', 'one') }
        @{ Arguments = @('--connect', '192.168.1.33', '5555', '--profile', 'DEV') }
        @{ Arguments = @('--connect', '192.168.1.33:5555', '5555') }
        @{ Arguments = @('--connect', '192.168.1.33', '65536') }
        @{ Arguments = @('--tap', '1; reboot', '2') }
        @{ Arguments = @('--swipe', '1', '2', '3', '-4') }
        @{ Arguments = @('--key', 'HOME; reboot') }
        @{ Arguments = @('--launch', 'com.example/.Main; reboot') }
        @{ Arguments = @('--force-stop', 'com.example; reboot') }
    ) {
        { Read-AutomationArguments $Arguments } | Should -Throw
    }
}

Describe 'Safe ADB operations' {
    BeforeEach {
        Mock Get-AdbExecutable { 'adb.exe' }
        Mock Write-UiLine {}
        Mock Save-IpCache {}
        Mock Save-CurrentProfileFromState {}
        Mock Load-IpCache { [pscustomobject]@{ ip = '192.168.1.33'; pairPort = '4000'; connPort = '5555' } }
        Mock Start-Sleep {}
        Mock Recover-Adb {}
        Mock Invoke-NativeTool { [pscustomobject]@{ exitCode = 0; output = '' } }
    }

    It 'reuses an authorized connection without native connect/disconnect/server calls' {
        Mock Get-DeviceStateByTarget { 'device' }
        Connect-Watch -Ip '192.168.1.33' -Port '5555' -NoSave | Should -BeTrue
        Should -Invoke Invoke-NativeTool -Times 0
        Should -Invoke Save-IpCache -Times 0
        Should -Invoke Save-CurrentProfileFromState -Times 0
    }

    It 'preserves normal connect saving behavior on a healthy connection' {
        Mock Get-DeviceStateByTarget { 'device' }
        Connect-Watch -Ip '192.168.1.33' -Port '5555' | Should -BeTrue
        Should -Invoke Save-IpCache -Times 1
        Should -Invoke Save-CurrentProfileFromState -Times 1
    }

    It 'never restarts the server or disconnects other devices when a target is offline' {
        Mock Get-DeviceStateByTarget { 'offline' }
        Connect-Watch -Ip '192.168.1.33' -Port '5555' -Retries 2 -NoSave | Should -BeFalse
        Should -Invoke Recover-Adb -Times 0
        Should -Invoke Invoke-NativeTool -Times 0 -ParameterFilter { 'kill-server' -in $Arguments -or 'disconnect' -in $Arguments }
        Should -Invoke Invoke-NativeTool -Times 2 -ParameterFilter { 'connect' -in $Arguments }
    }

    It 'does not restart shared ADB after pairing failure or save failed pairing' {
        Mock Invoke-NativeTool {
            if ($Arguments[0] -eq 'pair') { return [pscustomobject]@{ exitCode = 1; output = 'Pairing failed' } }
            [pscustomobject]@{ exitCode = 0; output = '' }
        }
        Invoke-PairWatch -Ip '192.168.1.33' -PairPort '4000' -PairCode '123456' | Should -BeFalse
        Should -Invoke Recover-Adb -Times 0
        Should -Invoke Save-IpCache -Times 0
    }

    It 'requires both zero exit code and confirmed Success for an install' -ForEach @(
        @{ Code = 1; Output = 'Success' }
        @{ Code = 0; Output = 'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]' }
        @{ Code = 0; Output = '' }
    ) {
        $apk = Join-Path $TestDrive 'my app.apk'
        Set-Content -Path $apk -Value 'fixture'
        Mock Invoke-NativeTool { [pscustomobject]@{ exitCode = $Code; output = $Output } }
        { Install-ApkToTarget -ApkPath $apk -Serial 'emulator-5554' } | Should -Throw
    }

    It 'installs successfully to an explicit target with replacement and wireless-safe flags' {
        $apk = Join-Path $TestDrive 'my app.apk'
        Set-Content -Path $apk -Value 'fixture'
        Mock Invoke-NativeTool { [pscustomobject]@{ exitCode = 0; output = "Performing Push Install`nSuccess" } }
        Install-ApkToTarget -ApkPath $apk -Serial 'emulator-5554'
        Should -Invoke Invoke-NativeTool -Times 1 -ParameterFilter {
            $Arguments[1] -eq 'emulator-5554' -and '-r' -in $Arguments -and '-g' -in $Arguments -and '--no-streaming' -in $Arguments -and $Arguments[-1] -eq $apk
        }
    }

    It 'continues bulk installs but fails overall when one target fails' {
        $apk = Join-Path $TestDrive 'app.apk'
        Set-Content -Path $apk -Value 'fixture'
        Mock Get-DeviceEntries {
            @([pscustomobject]@{ serial = 'one'; state = 'device' }, [pscustomobject]@{ serial = 'two'; state = 'device' }, [pscustomobject]@{ serial = 'three'; state = 'offline' })
        }
        Mock Install-ApkToTarget { if ($Serial -eq 'one') { throw 'Install failed' } }
        { Invoke-BulkSideload $apk } | Should -Throw '*Bulk install failed*'
        Should -Invoke Install-ApkToTarget -Times 2
    }

    It 'treats native device-list failure as an error, not an empty list' {
        Mock Invoke-NativeTool { [pscustomobject]@{ exitCode = 1; output = 'Cannot connect to server' } }
        { Get-DeviceEntries } | Should -Throw '*Listing ADB devices failed*'
    }

    It 'uses the chosen ADB for scrcpy and propagates mirror failure' {
        Mock Get-ScrcpyExecutable { 'scrcpy.exe' }
        Mock Get-OperationTarget { 'emulator-5554' }
        Mock Ensure-OperationTarget {}
        $script:observedAdb = $null
        Mock Invoke-NativeTool {
            $script:observedAdb = $env:ADB
            [pscustomobject]@{ exitCode = 1; output = 'scrcpy failed' }
        }
        $original = $env:ADB
        { Invoke-Mirror } | Should -Throw '*Screen mirroring failed*'
        $script:observedAdb | Should -Be 'adb.exe'
        $env:ADB | Should -Be $original
    }
}

Describe 'Automation results and per-call targeting' {
    BeforeEach {
        Mock Read-Host { throw 'Automation must never prompt' }
        Mock Get-AdbExecutable { 'adb.exe' }
        Mock Get-ScrcpyExecutable { 'scrcpy.exe' }
        Mock Save-IpCache {}
        Mock Save-ProfileStore {}
        Mock Set-CurrentProfile {}
        Mock Load-ProfileStore {
            [pscustomobject]@{ activeProfile = 'default'; profiles = [ordered]@{
                default = @{ name = 'default'; ip = '192.168.1.20'; pairPort = '4000'; connPort = '5555' }
                DEV = @{ name = 'DEV'; ip = '192.168.1.33'; pairPort = '4001'; connPort = '5556' }
            } }
        }
        Mock Load-IpCache { [pscustomobject]@{ ip = '192.168.1.20'; pairPort = '4000'; connPort = '5555' } }
        Mock Get-DeviceEntries { @([pscustomobject]@{ serial = '192.168.1.33:5556'; state = 'device' }) }
    }

    It 'returns one JSON object and targets a profile without switching or saving it' {
        $script:observedTarget = $null
        Mock Invoke-Sideload {
            $script:observedTarget = Get-OperationTarget
            Write-UiLine 'Install progress'
        }
        $lines = @(Invoke-AutomationCommand @('--install', 'app.apk', '--profile', 'DEV', '--json'))
        $response = ($lines -join "`n") | ConvertFrom-Json
        $response.schemaVersion | Should -Be 1
        $response.success | Should -BeTrue
        $response.serial | Should -Be '192.168.1.33:5556'
        $response.messages | Should -Contain 'Install progress'
        $script:observedTarget | Should -Be '192.168.1.33:5556'
        $script:TargetOverride | Should -BeNullOrEmpty
        Should -Invoke Set-CurrentProfile -Times 0
        Should -Invoke Save-ProfileStore -Times 0
        Should -Invoke Save-IpCache -Times 0
        Should -Invoke Read-Host -Times 0
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'reports invalid commands and missing profiles as structured failures' -ForEach @(
        @{ Arguments = @('--pair-connect-mirror', '--json') }
        @{ Arguments = @('--install', 'app.apk', '--profile', 'missing', '--json') }
        @{ Arguments = @('--install', '--json') }
        @{ Arguments = @('--install', 'app.apk', '--adb', 'Z:\missing\adb.exe', '--json') }
    ) {
        $response = (Invoke-AutomationCommand $Arguments | Out-String) | ConvertFrom-Json
        $response.success | Should -BeFalse
        $response.error | Should -Not -BeNullOrEmpty
        $global:LASTEXITCODE | Should -Be 1
        Should -Invoke Read-Host -Times 0
    }

    It 'returns operation errors as JSON with a nonzero result' {
        Mock Invoke-Sideload { throw 'Install failed' }
        $response = (Invoke-AutomationCommand @('--install', 'app.apk', '--serial', 'usb-device', '--json') | Out-String) | ConvertFrom-Json
        $response.success | Should -BeFalse
        $response.serial | Should -Be 'usb-device'
        $response.error | Should -Be 'Install failed'
        $global:LASTEXITCODE | Should -Be 1
    }

    It 'connects noninteractively without modifying saved settings' {
        Mock Connect-Watch { $true }
        $response = (Invoke-AutomationCommand @('--connect', '192.168.1.33', '5556', '--json') | Out-String) | ConvertFrom-Json
        $response.success | Should -BeTrue
        $response.serial | Should -Be '192.168.1.33:5556'
        Should -Invoke Connect-Watch -Times 1 -ParameterFilter { $NoSave }
    }

    It 'does not report a different port, offline, or unauthorized target as connected' -ForEach @(
        @{ Serial = '192.168.1.20:9999'; State = 'device' }
        @{ Serial = '192.168.1.20:5555'; State = 'offline' }
        @{ Serial = '192.168.1.20:5555'; State = 'unauthorized' }
    ) {
        Mock Get-DeviceEntries { @([pscustomobject]@{ serial = $Serial; state = $State }) }
        (Get-StatusJson).watchConnected | Should -BeFalse
    }

    It 'reports saved and per-call status separately' {
        $response = (Invoke-AutomationCommand @('--status-json', '--profile', 'DEV', '--json') | Out-String) | ConvertFrom-Json
        $response.success | Should -BeTrue
        $response.data.activeProfile | Should -Be 'default'
        $response.data.watchConnected | Should -BeFalse
        $response.data.selectedConnected | Should -BeTrue
        $response.data.selectedSerial | Should -Be '192.168.1.33:5556'
    }

    It 'fails activity launch even when am returns zero with an error message' {
        Mock Ensure-OperationTarget {}
        Mock Invoke-NativeTool { [pscustomobject]@{ exitCode = 0; output = 'Error type 3: Activity class does not exist' } }
        $response = (Invoke-AutomationCommand @('--launch', 'com.example/.Missing', '--serial', 'usb-device', '--json') | Out-String) | ConvertFrom-Json
        $response.success | Should -BeFalse
        $response.error | Should -Match 'App launch failed'
    }

    It 'routes screen and app controls to the selected serial with exact arguments' -ForEach @(
        @{ Command = '--tap'; Values = @('180', '120'); NativeArguments = @('shell', 'input', 'tap', '180', '120') }
        @{ Command = '--swipe'; Values = @('1', '2', '3', '4', '300'); NativeArguments = @('shell', 'input', 'swipe', '1', '2', '3', '4', '300') }
        @{ Command = '--key'; Values = @('KEYCODE_HOME'); NativeArguments = @('shell', 'input', 'keyevent', 'KEYCODE_HOME') }
        @{ Command = '--launch'; Values = @('com.example/.MainActivity'); NativeArguments = @('shell', 'am', 'start', '-W', '-n', 'com.example/.MainActivity') }
        @{ Command = '--force-stop'; Values = @('com.example'); NativeArguments = @('shell', 'am', 'force-stop', 'com.example') }
    ) {
        Mock Ensure-OperationTarget {}
        Mock Invoke-NativeTool { [pscustomobject]@{ exitCode = 0; output = 'Status: ok' } }
        $response = (Invoke-AutomationCommand (@($Command) + $Values + @('--serial', 'usb-device', '--json')) | Out-String) | ConvertFrom-Json
        $response.success | Should -BeTrue
        $response.data.output | Should -Be 'Status: ok'
        Should -Invoke Invoke-NativeTool -Times 1 -ParameterFilter { ($Arguments -join '|') -eq (@('-s', 'usb-device') + $NativeArguments -join '|') }
    }
}

Describe 'ADB configuration and read-only profiles' {
    It 'prefers an explicit executable over the environment and bundled ADB' {
        $override = $script:AdbOverride
        $environment = $env:WEAROS_BRIDGE_ADB
        try {
            $script:AdbOverride = 'explicit-adb.exe'
            $env:WEAROS_BRIDGE_ADB = 'missing-adb.exe'
            Get-AdbExecutable | Should -Be 'explicit-adb.exe'
        }
        finally {
            $script:AdbOverride = $override
            $env:WEAROS_BRIDGE_ADB = $environment
        }
    }

    It 'fails instead of falling back when the configured environment executable is missing' {
        $environment = $env:WEAROS_BRIDGE_ADB
        try {
            $env:WEAROS_BRIDGE_ADB = Join-Path $TestDrive 'missing-adb.exe'
            { Get-AdbExecutable } | Should -Throw '*Configured ADB executable not found*'
        }
        finally { $env:WEAROS_BRIDGE_ADB = $environment }
    }

    It 'does not create an active profile marker for read-only automation' {
        $ProfilesPath = Join-Path $TestDrive 'missing-profiles.json'
        $ActiveProfilePath = Join-Path $TestDrive 'missing-active.txt'
        $store = Load-ProfileStore -ReadOnly
        $store.activeProfile | Should -Be 'default'
        Test-Path $ProfilesPath | Should -BeFalse
        Test-Path $ActiveProfilePath | Should -BeFalse
    }

    It 'surfaces corrupt profile files for automation without replacing them' {
        $ProfilesPath = Join-Path $TestDrive 'corrupt-profiles.json'
        Set-Content -Path $ProfilesPath -Value 'not JSON'
        { Load-ProfileStore -ReadOnly } | Should -Throw '*Unable to read watch profiles*'
        Get-Content $ProfilesPath | Should -Be 'not JSON'
    }
}

Describe 'Screenshot output' {
    BeforeEach {
        Mock Get-AdbExecutable { 'adb.exe' }
        Mock Ensure-OperationTarget {}
        $captureDirectory = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -Path $captureDirectory -ItemType Directory | Out-Null
    }

    It 'preserves PNG bytes and returns the absolute path' {
        Mock Invoke-NativeTool {
            [System.IO.File]::WriteAllBytes($OutputPath, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1kAAAAASUVORK5CYII='))
            [pscustomobject]@{ exitCode = 0; output = '' }
        }
        $path = Join-Path $captureDirectory 'watch shot.png'
        $result = Save-WatchScreenshot -OutputPath $path -Serial 'usb-device'
        $result.path | Should -Be $path
        [BitConverter]::ToString([System.IO.File]::ReadAllBytes($path)[0..7]) | Should -Be '89-50-4E-47-0D-0A-1A-0A'
        @(Get-ChildItem $captureDirectory -File).Count | Should -Be 1
    }

    It 'preserves existing output and removes temporary data on invalid capture' {
        Mock Invoke-NativeTool {
            [System.IO.File]::WriteAllText($OutputPath, 'not a PNG')
            [pscustomobject]@{ exitCode = 0; output = '' }
        }
        $path = Join-Path $captureDirectory 'previous.png'
        Set-Content -Path $path -Value 'previous screenshot'
        { Save-WatchScreenshot -OutputPath $path -Serial 'usb-device' } | Should -Throw '*PNG screenshot*'
        Get-Content $path | Should -Be 'previous screenshot'
        @(Get-ChildItem $captureDirectory -File).Count | Should -Be 1
    }
}

Describe 'Native runner and process-level CLI' {
    BeforeAll {
        $shell = (Get-Command powershell.exe).Source
        $bridge = Join-Path $PSScriptRoot '..\wearos-windows-bridge.ps1'
        $launcher = Join-Path $PSScriptRoot '..\wearos-windows-bridge.bat'
        $fakeAdb = Join-Path $TestDrive 'fake adb.exe'
        $source = @'
using System;
using System.IO;
public class FakeAdb {
    public static int Main(string[] args) {
        if (args.Length == 1 && args[0] == "devices") {
            Console.WriteLine("List of devices attached\nfixture-device\tdevice");
            return 0;
        }
        if (args.Length < 3 || args[0] != "-s" || args[1] != "fixture-device") {
            Console.Error.WriteLine("Unexpected target or arguments");
            return 2;
        }
        if (args[2] == "install" && args.Length == 7 && args[3] == "-r" &&
            args[4] == "-g" && args[5] == "--no-streaming" && File.Exists(args[6])) {
            Console.WriteLine("Success");
            return 0;
        }
        if (args[2] == "exec-out" && args.Length == 5 &&
            args[3] == "screencap" && args[4] == "-p") {
            byte[] png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1kAAAAASUVORK5CYII=");
            Console.OpenStandardOutput().Write(png, 0, png.Length);
            return 0;
        }
        Console.Error.WriteLine("Unexpected operation");
        return 3;
    }
}
'@
        $compile = "Add-Type -TypeDefinition '$($source.Replace("'", "''"))' -OutputAssembly '$($fakeAdb.Replace("'", "''"))' -OutputType ConsoleApplication"
        $compiled = Invoke-NativeTool -Executable $shell -Arguments @('-NoProfile', '-Command', $compile)
        Assert-NativeSuccess $compiled 'Compiling isolated ADB fixture'
    }

    It 'captures stdout, stderr, exit status, and quoted arguments under Windows PowerShell' {
        $result = Invoke-NativeTool -Executable $shell -Arguments @('-NoProfile', '-Command', '[Console]::WriteLine(''a "quoted" path C:\folder with spaces\''); [Console]::Error.WriteLine(''diagnostic''); exit 7')
        $result.exitCode | Should -Be 7
        $result.output | Should -Match 'a "quoted" path C:\\folder with spaces\\'
        $result.output | Should -Match 'diagnostic'
    }

    It 'fails and terminates a timed-out child command' {
        { Invoke-NativeTool -Executable $shell -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 10') -TimeoutSeconds 1 } | Should -Throw '*timed out after 1 seconds*'
    }

    It 'preserves binary stdout without PowerShell text conversion' {
        $path = Join-Path $TestDrive 'binary.png'
        $result = Invoke-NativeTool -Executable $shell -Arguments @('-NoProfile', '-Command', '$bytes = [byte[]](137,80,78,71,13,10,26,10,0,255); [Console]::OpenStandardOutput().Write($bytes,0,$bytes.Length)') -OutputPath $path
        $result.exitCode | Should -Be 0
        [BitConverter]::ToString([System.IO.File]::ReadAllBytes($path)) | Should -Be '89-50-4E-47-0D-0A-1A-0A-00-FF'
    }

    It 'returns parseable error JSON and exit code 1 through the batch launcher' {
        $output = & $launcher --install --json
        $LASTEXITCODE | Should -Be 1
        $response = ($output -join "`n") | ConvertFrom-Json
        $response.success | Should -BeFalse
        $response.command | Should -Be '--install'
    }

    It 'resolves relative output from the caller directory, not the bridge directory' {
        Push-Location $TestDrive
        try {
            $output = & $launcher --screenshot 'missing folder\watch.png' --serial 'usb-device' --json
            $LASTEXITCODE | Should -Be 1
            $response = ($output -join "`n") | ConvertFrom-Json
            $response.error | Should -Be "Screenshot directory not found: $(Join-Path $TestDrive 'missing folder')"
        }
        finally { Pop-Location }
    }

    It 'installs through the launcher with an isolated executable and spaced relative APK path' {
        Set-Content -Path (Join-Path $TestDrive 'my app.apk') -Value 'fixture'
        Push-Location $TestDrive
        try {
            $output = & $launcher --install 'my app.apk' --serial fixture-device --adb $fakeAdb --json
            $LASTEXITCODE | Should -Be 0
            $response = ($output -join "`n") | ConvertFrom-Json
            $response.success | Should -BeTrue
            $response.serial | Should -Be 'fixture-device'
            $response.messages | Should -Contain 'Success'
        }
        finally { Pop-Location }
    }

    It 'captures a screenshot through the launcher with no live ADB or device interaction' {
        Push-Location $TestDrive
        try {
            $output = & $launcher --screenshot 'watch shot.png' --serial fixture-device --adb $fakeAdb --json
            $LASTEXITCODE | Should -Be 0
            $response = ($output -join "`n") | ConvertFrom-Json
            $response.success | Should -BeTrue
            $response.data.path | Should -Be (Join-Path $TestDrive 'watch shot.png')
            [BitConverter]::ToString([System.IO.File]::ReadAllBytes($response.data.path)[0..7]) | Should -Be '89-50-4E-47-0D-0A-1A-0A'
        }
        finally { Pop-Location }
    }
}
