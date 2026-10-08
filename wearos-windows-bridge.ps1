$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$IpCachePath = Join-Path $ScriptDir 'ip_cache.txt'
$ProfilesPath = Join-Path $ScriptDir 'watch_profiles.json'
$ActiveProfilePath = Join-Path $ScriptDir 'active_profile.txt'
$PathConfiguredPath = Join-Path $ScriptDir 'path_configured.txt'
$LogsDir = Join-Path $ScriptDir 'watch_logs'
$script:AdbOverride = $null
$script:TargetOverride = $null
$script:CommandTimeoutSeconds = 120
$script:AutomationMode = $false
$script:JsonMessages = $null

function Write-UiLine {
    param(
        [string]$Message,
        [string]$Color = 'Gray'
    )

    if ($null -ne $script:JsonMessages) {
        $script:JsonMessages.Add($Message)
        return
    }
    Write-Host $Message -ForegroundColor $Color
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)

    # ProcessStartInfo on Windows PowerShell requires Windows command-line quoting.
    return '"' + ([regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
}

function Invoke-NativeTool {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = $script:CommandTimeoutSeconds,
        [string]$OutputPath
    )

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.WorkingDirectory = (Get-Location).ProviderPath
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $stream = $null
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw "Unable to start $Executable." }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($OutputPath) {
            $stream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::CreateNew)
            $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stream)
        }
        else {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        }
        if ($TimeoutSeconds -gt 0) {
            $finished = $process.WaitForExit($TimeoutSeconds * 1000)
        }
        else {
            $process.WaitForExit()
            $finished = $true
        }
        if (-not $finished) {
            $process.Kill()
            $process.WaitForExit()
            throw "Command timed out after $TimeoutSeconds seconds: $Executable"
        }
        $stdoutTask.GetAwaiter().GetResult() | Out-Null
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $stdout = if ($OutputPath) { '' } else { $stdoutTask.Result }
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            output = ($stdout.TrimEnd() + "`n" + $stderr).Trim()
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        if ($stream) { $stream.Dispose() }
        $process.Dispose()
    }
}

function Assert-NativeSuccess {
    param($Result, [string]$Operation)

    if ($Result.exitCode -ne 0) {
        throw "$Operation failed (exit code $($Result.exitCode)): $($Result.output)"
    }
}

function Get-AdbCommandPaths {
    $matches = @(Get-Command adb.exe -All -ErrorAction SilentlyContinue)
    $paths = @()

    foreach ($match in $matches) {
        $value = if ($match.Source) { $match.Source } elseif ($match.Definition) { $match.Definition } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $paths += $value
        }
    }

    return @($paths | Select-Object -Unique)
}

function Get-AdbHealthWarning {
    $warning = [ordered]@{
        conflictDetected = $false
        message = ''
        advice = ''
        paths = @()
    }

    $paths = @(Get-AdbCommandPaths)
    if ($paths.Count -gt 1) {
        $warning.conflictDetected = $true
        $warning.paths = $paths
        $warning.message = "Multiple adb.exe paths were detected on PATH: $($paths -join '; ')"
        $warning.advice = "Configure WEAROS_BRIDGE_ADB to use Android Studio's SDK platform-tools\adb.exe so both tools share the same ADB version."
    }

    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        return [pscustomobject]$warning
    }

    $raw = @()
    try {
        $raw += (& $Adb version 2>&1 | Out-String)
    }
    catch {
        $raw += $_.Exception.Message
    }

    try {
        $raw += (& $Adb devices 2>&1 | Out-String)
    }
    catch {
        $raw += $_.Exception.Message
    }

    $combined = ($raw -join "`n")
    if ($combined -match 'adb server is out of date|unable to connect to adb|failed to start daemon|internal error') {
        $warning.message = $combined.Trim()
        $warning.advice = "Use Android Studio's SDK ADB via WEAROS_BRIDGE_ADB. Only restart the shared server explicitly with --recover-adb if necessary."
        $warning.conflictDetected = $true
    }

    return [pscustomobject]$warning
}

function Write-AdbHealthWarning {
    $warning = Get-AdbHealthWarning
    if (-not $warning.conflictDetected) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($warning.message)) {
        Write-UiLine $warning.message -Color Yellow
    }

    if (-not [string]::IsNullOrWhiteSpace($warning.advice)) {
        Write-UiLine $warning.advice -Color Yellow
    }
}

function Get-ConfiguredScrcpyFolder {
    if (-not (Test-Path $PathConfiguredPath -PathType Leaf)) {
        return $null
    }

    $folder = (Get-Content -Path $PathConfiguredPath -TotalCount 1 -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($folder) -or $folder -eq 'configured') {
        return $null
    }

    $folder = $folder.Trim().Trim('"')
    if ((Test-Path (Join-Path $folder 'scrcpy.exe') -PathType Leaf) -and (Test-Path (Join-Path $folder 'adb.exe') -PathType Leaf)) {
        return $folder
    }

    return $null
}

function Get-ConnectionFailureAdvice {
    param(
        [string]$Ip,
        [string]$Port,
        [string]$State = 'unknown'
    )

    $message = [System.Collections.Generic.List[string]]::new()

    switch ($State) {
        'unauthorized' {
            $message.Add("The watch at ${Ip}:${Port} is paired but not yet authorized by ADB.")
            $message.Add('Accept the debugging prompt on the watch and retry the connection.')
        }
        'offline' {
            $message.Add("The device at ${Ip}:${Port} is offline or unreachable.")
            $message.Add('Keep the watch awake and confirm it is connected to the same Wi-Fi network.')
        }
        'not-found' {
            $message.Add("ADB does not currently see ${Ip}:${Port}.")
            $message.Add('Confirm the port is the main Wireless Debugging connection port, not the pairing port.')
        }
        default {
            $message.Add("Connection to ${Ip}:${Port} failed.")
            $message.Add('Check that the watch is awake, the Wi-Fi network is reachable, and the port matches the Wireless Debugging screen.')
        }
    }

    $message.Add('If you see "adb server is out of date", configure WEAROS_BRIDGE_ADB to use the same SDK ADB as Android Studio.')
    return ($message -join ' ')
}

function Invoke-ConnectionRecovery {
    param(
        [string]$Ip,
        [string]$Port,
        [string]$Reason = 'connection recovery'
    )

    $state = Get-DeviceStateByTarget -Ip $Ip -Port $Port
    Write-UiLine "Connection state for ${Ip}:${Port} is '$state'. Recovering ADB for $Reason." -Color Yellow

    if ($state -eq 'unauthorized') {
        Write-UiLine 'The device is unauthorized. Accept the debugging prompt on the watch before retrying.' -Color Yellow
    }
    elseif ($state -eq 'offline' -or $state -eq 'not-found') {
        Write-UiLine 'The watch is not reachable over ADB. Confirm the connection port, network, and wake state, then retry.' -Color Yellow
    }

    Write-UiLine 'Retrying only this target; the shared ADB server will not be restarted.' -Color Yellow
}

function Get-AdbExecutable {
    if ($script:AdbOverride) {
        return $script:AdbOverride
    }
    if (-not [string]::IsNullOrWhiteSpace($env:WEAROS_BRIDGE_ADB)) {
        if (-not (Test-Path -LiteralPath $env:WEAROS_BRIDGE_ADB -PathType Leaf)) {
            throw "Configured ADB executable not found: $env:WEAROS_BRIDGE_ADB"
        }
        return (Get-Item -LiteralPath $env:WEAROS_BRIDGE_ADB).FullName
    }
    $configuredFolder = Get-ConfiguredScrcpyFolder
    if ($configuredFolder) {
        $configuredAdb = Join-Path $configuredFolder 'adb.exe'
        if (Test-Path $configuredAdb -PathType Leaf) {
            return $configuredAdb
        }
    }

    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    foreach ($segment in ($env:PATH -split ';')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $candidate = Join-Path $segment 'adb.exe'
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-ScrcpyExecutable {
    $configuredFolder = Get-ConfiguredScrcpyFolder
    if ($configuredFolder) {
        $configuredScrcpy = Join-Path $configuredFolder 'scrcpy.exe'
        if (Test-Path $configuredScrcpy -PathType Leaf) {
            return $configuredScrcpy
        }
    }

    $cmd = Get-Command scrcpy.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    foreach ($segment in ($env:PATH -split ';')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $candidate = Join-Path $segment 'scrcpy.exe'
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Ensure-PathConfiguredMarker {
    param([string]$Folder)

    $folder = $Folder
    if ([string]::IsNullOrWhiteSpace($folder)) {
        return
    }

    Set-Content -Path $PathConfiguredPath -Value $folder -Encoding ASCII
}

function Test-DevMode {
    $value = $env:WEAROS_DEV_MODE
    if ([string]::IsNullOrEmpty($value)) {
        return $false
    }

    return $value -match '^(1|true|yes)$'
}

function Set-DevMode {
    $env:WEAROS_DEV_MODE = '1'
}

function Set-ScrcpyPathFromFolder {
    param(
        [string]$Folder
    )

    $candidate = if ($null -eq $Folder) { '' } else { $Folder.Trim().Trim('"') }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw 'A scrcpy folder path is required.'
    }

    $resolvedRoot = $candidate
    if (Test-Path $candidate -PathType Leaf) {
        $resolvedRoot = Split-Path -Parent $candidate
    }

    if (-not (Test-Path $resolvedRoot -PathType Container)) {
        throw "Folder not found: $candidate"
    }

    $scrcpy = Join-Path $resolvedRoot 'scrcpy.exe'
    $adb = Join-Path $resolvedRoot 'adb.exe'
    if (-not (Test-Path $scrcpy) -or -not (Test-Path $adb)) {
        throw 'The folder does not contain both scrcpy.exe and adb.exe.'
    }

    $env:SCRCPY_PATH = $resolvedRoot
    $env:PATH = "$resolvedRoot;$($env:PATH)"
    Ensure-PathConfiguredMarker -Folder $resolvedRoot
    Write-UiLine "Configured scrcpy PATH from '$resolvedRoot'." -Color Green
    return $resolvedRoot
}

function Load-IpCache {
    $result = [ordered]@{
        ip = 'None'
        pairPort = ''
        connPort = ''
    }

    if (-not (Test-Path $IpCachePath)) {
        return [pscustomobject]$result
    }

    $lines = Get-Content -Path $IpCachePath -ErrorAction SilentlyContinue
    if ($lines -and $lines.Count -ge 1) {
        $rawIp = if ($lines[0]) { $lines[0].Trim() } else { 'None' }
        $result.ip = $rawIp
    }
    if ($lines -and $lines.Count -ge 2) {
        $rawPairPort = if ($lines[1]) { $lines[1].Trim() } else { '' }
        $result.pairPort = $rawPairPort
    }
    if ($lines -and $lines.Count -ge 3) {
        $rawConnPort = if ($lines[2]) { $lines[2].Trim() } else { '' }
        $result.connPort = $rawConnPort
    }

    if ([string]::IsNullOrWhiteSpace($result.ip)) {
        $result.ip = 'None'
    }

    return [pscustomobject]$result
}

function Save-IpCache {
    param(
        [string]$Ip,
        [string]$PairPort,
        [string]$ConnPort
    )

    $ipValue = if ([string]::IsNullOrWhiteSpace($Ip)) { 'None' } else { $Ip }
    $pairValue = if ($null -eq $PairPort) { '' } else { [string]$PairPort }
    $connValue = if ($null -eq $ConnPort) { '' } else { [string]$ConnPort }

    Set-Content -Path $IpCachePath -Value @($ipValue, $pairValue, $connValue) -Encoding ASCII
}

function Load-ProfileStore {
    param([switch]$ReadOnly)
    $defaultProfile = [ordered]@{
        name = 'default'
        ip = 'None'
        pairPort = ''
        connPort = ''
    }

    $store = [ordered]@{
        activeProfile = 'default'
        profiles = [ordered]@{
            default = [ordered]@{
                name = 'default'
                ip = 'None'
                pairPort = ''
                connPort = ''
            }
        }
    }

    if (Test-Path $ProfilesPath) {
        try {
            $json = Get-Content -Raw -Path $ProfilesPath -ErrorAction Stop | ConvertFrom-Json
            if ($json -and $json.profiles) {
                $store = [ordered]@{
                    activeProfile = if ($json.activeProfile) { [string]$json.activeProfile } else { 'default' }
                    profiles = [ordered]@{}
                }

                foreach ($key in $json.profiles.PSObject.Properties.Name) {
                    $profile = $json.profiles.$key
                    $store.profiles[$key] = [ordered]@{
                        name = if ($profile.name) { [string]$profile.name } else { $key }
                        ip = if ($profile.ip) { [string]$profile.ip } else { 'None' }
                        pairPort = if ($profile.pairPort) { [string]$profile.pairPort } else { '' }
                        connPort = if ($profile.connPort) { [string]$profile.connPort } else { '' }
                    }
                }

                if (-not $store.profiles.Contains($store.activeProfile)) {
                    $store.activeProfile = 'default'
                }
            }
        }
        catch {
            if ($ReadOnly) {
                throw "Unable to read watch profiles: $($_.Exception.Message)"
            }
            $store = [ordered]@{
                activeProfile = 'default'
                profiles = [ordered]@{
                    default = [ordered]@{
                        name = 'default'
                        ip = 'None'
                        pairPort = ''
                        connPort = ''
                    }
                }
            }
        }
    }

    if (-not (Test-Path $ActiveProfilePath)) {
        if (-not $ReadOnly) {
            Set-Content -Path $ActiveProfilePath -Value $store.activeProfile -Encoding ASCII
        }
    }
    else {
        $profileName = (Get-Content -Path $ActiveProfilePath -TotalCount 1 -ErrorAction SilentlyContinue).Trim()
        if (-not [string]::IsNullOrWhiteSpace($profileName) -and $store.profiles.Contains($profileName)) {
            $store.activeProfile = $profileName
        }
        else {
            $store.activeProfile = 'default'
            if (-not $ReadOnly) {
                Set-Content -Path $ActiveProfilePath -Value 'default' -Encoding ASCII
            }
        }
    }

    return [pscustomobject]$store
}

function Save-ProfileStore {
    param($Store)

    $json = $Store | ConvertTo-Json -Depth 6
    Set-Content -Path $ProfilesPath -Value $json -Encoding UTF8
    Set-Content -Path $ActiveProfilePath -Value $Store.activeProfile -Encoding ASCII
}

function Get-CurrentProfile {
    param([switch]$ReadOnly)

    $store = Load-ProfileStore -ReadOnly:$ReadOnly
    $name = $store.activeProfile
    if (-not $store.profiles.Contains($name)) {
        $name = 'default'
    }

    $profileValue = $store.profiles[$name]
    return [pscustomobject]@{
        name = $profileValue.name
        ip = $profileValue.ip
        pairPort = $profileValue.pairPort
        connPort = $profileValue.connPort
    }
}

function Set-CurrentProfile {
    param([string]$ProfileName)

    $store = Load-ProfileStore
    if (-not $store.profiles.Contains($ProfileName)) {
        $store.profiles[$ProfileName] = [ordered]@{
            name = $ProfileName
            ip = 'None'
            pairPort = ''
            connPort = ''
        }
    }

    $store.activeProfile = $ProfileName
    Save-ProfileStore $store
    $profile = $store.profiles[$ProfileName]
    Save-IpCache -Ip $profile.ip -PairPort $profile.pairPort -ConnPort $profile.connPort
    return $profile
}

function Ensure-ProfileExists {
    param(
        [string]$ProfileName,
        [string]$Ip = 'None',
        [string]$PairPort = '',
        [string]$ConnPort = ''
    )

    $store = Load-ProfileStore
    if (-not $store.profiles.Contains($ProfileName)) {
        $store.profiles[$ProfileName] = [ordered]@{
            name = $ProfileName
            ip = $Ip
            pairPort = $PairPort
            connPort = $ConnPort
        }
        Save-ProfileStore $store
    }
}

function Save-CurrentProfileFromState {
    param(
        [string]$Ip,
        [string]$PairPort,
        [string]$ConnPort
    )

    $store = Load-ProfileStore
    $active = $store.activeProfile
    if (-not $store.profiles.Contains($active)) {
        $active = 'default'
        $store.activeProfile = $active
    }

    $store.profiles[$active] = [ordered]@{
        name = $active
        ip = $Ip
        pairPort = $PairPort
        connPort = $ConnPort
    }

    Save-ProfileStore $store
}

function Remove-Profile {
    param([string]$ProfileName)

    if ([string]::IsNullOrWhiteSpace($ProfileName)) {
        throw 'A profile name is required.'
    }

    $normalized = $ProfileName.Trim()
    if ($normalized -eq 'default') {
        throw "The 'default' profile cannot be deleted."
    }

    $store = Load-ProfileStore
    if (-not $store.profiles.Contains($normalized)) {
        throw "Profile '$normalized' was not found."
    }

    $store.profiles.Remove($normalized)

    if ($store.activeProfile -eq $normalized) {
        if (-not $store.profiles.Contains('default')) {
            $store.profiles['default'] = [ordered]@{
                name = 'default'
                ip = 'None'
                pairPort = ''
                connPort = ''
            }
        }

        $store.activeProfile = 'default'
    }

    Save-ProfileStore $store

    $activeProfile = $store.profiles[$store.activeProfile]
    Save-IpCache -Ip $activeProfile.ip -PairPort $activeProfile.pairPort -ConnPort $activeProfile.connPort
    return $store
}

function Refresh-InternetState {
    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        return [pscustomobject]@{ ok = $false; message = 'ADB is not installed or not on PATH.' }
    }

    $out = & $Adb devices 2>&1 | Out-String
    return [pscustomobject]@{ ok = $true; message = $out }
}

function Recover-Adb {
    param([string]$Reason = 'recovering ADB')

    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        throw 'ADB is not installed or not on PATH.'
    }

    Write-UiLine "Recovering ADB: $Reason" -Color Yellow
    $result = Invoke-NativeTool -Executable $Adb -Arguments @('kill-server')
    Assert-NativeSuccess $result 'Stopping the shared ADB server'
    $result = Invoke-NativeTool -Executable $Adb -Arguments @('start-server')
    Assert-NativeSuccess $result 'Starting the shared ADB server'
}

function Get-DeviceEntries {
    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        return @()
    }

    $result = Invoke-NativeTool -Executable $Adb -Arguments @('devices')
    Assert-NativeSuccess $result 'Listing ADB devices'
    $raw = $result.output

    $entries = @()

    foreach ($line in ($raw -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match 'List of devices attached|^\*|daemon not running|starting now|adb.exe') { continue }

        $parts = $line -split '\s+'
        if ($parts.Count -lt 2 -or $parts[1] -notin @('device', 'offline', 'unauthorized', 'recovery', 'sideload', 'bootloader', 'no')) { continue }
        $serial = $parts[0].Trim()
        $state = $parts[1].Trim()
        $entries += [pscustomobject]@{
            serial = $serial
            state = $state
        }
    }

    return $entries
}

function Get-DeviceStateByTarget {
    param(
        [string]$Ip,
        [string]$Port
    )

    $entries = Get-DeviceEntries
    $target = "${Ip}:$Port"
    foreach ($entry in $entries) {
        if ($entry.serial -eq $target) {
            return $entry.state
        }
    }

    return 'not-found'
}

function Get-StatusJson {
    $Adb = Get-AdbExecutable
    $Scrcpy = Get-ScrcpyExecutable
    $profile = Get-CurrentProfile -ReadOnly
    $cache = Load-IpCache
    $store = Load-ProfileStore -ReadOnly
    $summary = Get-DeviceEntries

    # Pairing is an authorization saved by ADB; it is not listed by `adb devices`.
    $paired = ($cache.ip -ne 'None' -and -not [string]::IsNullOrWhiteSpace($cache.pairPort))
    $connected = $false
    if ($cache.ip -ne 'None' -and -not [string]::IsNullOrWhiteSpace($cache.connPort)) {
        foreach ($entry in $summary) {
            if ($entry.serial -eq "$($cache.ip):$($cache.connPort)" -and $entry.state -eq 'device') {
                $connected = $true
                break
            }
        }
    }

    $result = [ordered]@{
        adbInstalled = if ($Adb) { $true } else { $false }
        scrcpyInstalled = if ($Scrcpy) { $true } else { $false }
        scrcpyConfigured = if ($Scrcpy) { $true } else { $false }
        watchPaired = $paired
        watchConnected = $connected
        activeProfile = $profile.name
        saved = [ordered]@{
            ip = $cache.ip
            pairPort = $cache.pairPort
            connPort = $cache.connPort
        }
        profiles = @()
        deviceSummary = @()
    }

    foreach ($key in $store.profiles.Keys) {
        $entry = $store.profiles[$key]
        $result.profiles += [pscustomobject]@{
            name = $key
            ip = $entry.ip
            pairPort = $entry.pairPort
            connPort = $entry.connPort
        }
    }

    foreach ($entry in $summary) {
        $result.deviceSummary += [ordered]@{
            serial = $entry.serial
            state = $entry.state
        }
    }

    return $result
}

function Show-Status {
    $Adb = Get-AdbExecutable
    $Scrcpy = Get-ScrcpyExecutable
    $profile = Get-CurrentProfile
    $cache = Load-IpCache
    $entries = Get-DeviceEntries
    # Pairing is an authorization saved by ADB; it is not listed by `adb devices`.
    $paired = ($cache.ip -ne 'None' -and -not [string]::IsNullOrWhiteSpace($cache.pairPort))
    $connected = $false
    if ($cache.ip -ne 'None' -and -not [string]::IsNullOrWhiteSpace($cache.connPort)) {
        foreach ($entry in $entries) {
            if ($entry.serial -eq "$($cache.ip):$($cache.connPort)" -and $entry.state -eq 'device') {
                $connected = $true
                break
            }
        }
    }

    Write-UiLine 'DEVICE STATUS' -Color Cyan
    Write-UiLine '---------------------------------------------------' -Color DarkCyan
    Write-UiLine "Setup: $(if ($Adb -and $Scrcpy) { 'Ready' } else { 'Not ready' })"
    Write-UiLine "Pair status: $(if ($paired) { 'Paired (saved)' } else { 'Not paired' })"
    Write-UiLine "Connect status: $(if ($connected) { 'Connected' } else { 'Not connected' })"
    Write-UiLine "ADB: $(if ($Adb) { 'Configured' } else { 'Not configured' })"
    Write-UiLine "scrcpy: $(if ($Scrcpy) { 'Configured' } else { 'Not configured' })"
    Write-UiLine "Active profile: $($profile.name)"
    Write-UiLine "Saved IP: $($cache.ip)"
    Write-UiLine "Saved pairing port: $(if ([string]::IsNullOrWhiteSpace($cache.pairPort)) { 'None' } else { $cache.pairPort })"
    Write-UiLine "Saved connection port: $(if ([string]::IsNullOrWhiteSpace($cache.connPort)) { 'None' } else { $cache.connPort })"
    Write-UiLine 'Detected devices:'

    if (-not $entries -or $entries.Count -eq 0) {
        Write-UiLine '  None'
    }
    else {
        foreach ($entry in $entries) {
            Write-UiLine "  $($entry.serial) -> $($entry.state)"
        }
    }
}

function Show-DiagnoseInfo {
    $Adb = Get-AdbExecutable
    $Scrcpy = Get-ScrcpyExecutable
    $cache = Load-IpCache
    $profile = Get-CurrentProfile

    Write-UiLine 'DIAGNOSE ENVIRONMENT' -Color Cyan
    Write-UiLine '---------------------------------------------------' -Color DarkCyan
    Write-UiLine "ADB path: $(if ($Adb) { $Adb } else { 'Not found' })"
    Write-UiLine "scrcpy path: $(if ($Scrcpy) { $Scrcpy } else { 'Not found' })"
    Write-UiLine "User PATH includes scrcpy: $(if ($Scrcpy) { 'Yes' } else { 'No' })"
    Write-UiLine "Active profile: $($profile.name)"
    Write-UiLine "Saved cache: $($cache.ip) / $($cache.pairPort) / $($cache.connPort)"
    if ($Adb) {
        Write-UiLine 'adb devices output:'
        $output = & $Adb devices 2>&1 | Out-String
        Write-UiLine $output
    }
}

function Protect-DiagnosticText {
    param([string]$Text)

    $safeText = $Text -replace '(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?(?![\w.])', '[REDACTED-IP]'
    $safeText = $safeText -replace '(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b', '[REDACTED-MAC]'
    $safeText = $safeText -replace '(?i)\b(serial|device[_ -]?id|android[_ -]?id)\s*[:=]\s*("[^"]*"|[^\s,;]+)', '$1=[REDACTED]'
    return $safeText
}

function Get-DiagnosticToolVersion {
    param(
        [string]$Executable,
        [string[]]$Arguments
    )

    if ([string]::IsNullOrWhiteSpace($Executable)) {
        return 'Not found'
    }

    try {
        return (& $Executable @Arguments 2>&1 | Out-String).Trim()
    }
    catch {
        return "Version query failed: $($_.Exception.Message)"
    }
}

function New-DiagnosticBundle {
    param(
        [switch]$IncludeLogs,
        [bool]$RedactIdentifiers = $true,
        [System.IO.FileInfo[]]$LogFiles = @(),
        [string]$OutputDirectory = (Join-Path $ScriptDir 'diagnostic_bundles')
    )

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("wearos-diagnostics-{0}" -f [guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $OutputDirectory "wearos-diagnostics-$stamp.zip"
    New-Item -Path $staging -ItemType Directory -Force | Out-Null

    try {
        $adb = Get-AdbExecutable
        $scrcpy = Get-ScrcpyExecutable
        $status = try { Get-StatusJson } catch { [pscustomobject]@{ error = $_.Exception.Message } }

        if ($RedactIdentifiers) {
            if ($status.PSObject.Properties['saved'] -and $status.saved) { $status.saved.ip = '[REDACTED]' }
            if ($status.PSObject.Properties['activeProfile']) { $status.activeProfile = '[REDACTED]' }
            if ($status.PSObject.Properties['profiles']) {
                foreach ($profile in @($status.profiles)) {
                    if ($profile) {
                        $profile.name = '[REDACTED]'
                        $profile.ip = '[REDACTED]'
                    }
                }
            }
            if ($status.PSObject.Properties['deviceSummary']) {
                foreach ($device in @($status.deviceSummary)) {
                    if ($device) { $device.serial = '[REDACTED]' }
                }
            }
        }

        $operatingSystem = try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            [pscustomobject]@{
                caption = $os.Caption
                version = $os.Version
                buildNumber = $os.BuildNumber
                architecture = $os.OSArchitecture
            }
        }
        catch {
            [pscustomobject]@{
                caption = $env:OS
                version = [Environment]::OSVersion.Version.ToString()
                buildNumber = ''
                architecture = if ([Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }
            }
        }

        $adbPath = if ($RedactIdentifiers -and $adb -and $env:USERPROFILE) { $adb.Replace($env:USERPROFILE, '%USERPROFILE%') } else { $adb }
        $scrcpyPath = if ($RedactIdentifiers -and $scrcpy -and $env:USERPROFILE) { $scrcpy.Replace($env:USERPROFILE, '%USERPROFILE%') } else { $scrcpy }
        $diagnostics = [ordered]@{
            generatedUtc = [DateTime]::UtcNow.ToString('o')
            operatingSystem = $operatingSystem
            powershell = [ordered]@{
                version = $PSVersionTable.PSVersion.ToString()
                edition = $PSVersionTable.PSEdition
            }
            tools = [ordered]@{
                adbPath = if ($adbPath) { $adbPath } else { 'Not found' }
                adbVersion = Get-DiagnosticToolVersion -Executable $adb -Arguments @('version')
                scrcpyPath = if ($scrcpyPath) { $scrcpyPath } else { 'Not found' }
                scrcpyVersion = Get-DiagnosticToolVersion -Executable $scrcpy -Arguments @('--version')
            }
            bridgeStatus = $status
            identifiersRedacted = $RedactIdentifiers
            logsIncluded = [bool]$IncludeLogs
        }

        $diagnosticJson = $diagnostics | ConvertTo-Json -Depth 8
        if ($RedactIdentifiers) {
            if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                $diagnosticJson = [regex]::Replace($diagnosticJson, [regex]::Escape($env:USERPROFILE), '%USERPROFILE%', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            }
            $diagnosticJson = Protect-DiagnosticText -Text $diagnosticJson
        }
        Set-Content -Path (Join-Path $staging 'diagnostics.json') -Value $diagnosticJson -Encoding UTF8

        $includedLogs = @()
        if ($IncludeLogs) {
            $logDirectory = Join-Path $staging 'watch_logs'
            foreach ($log in @($LogFiles | Where-Object { $_ -and $_.Exists -and $_.Length -le 5MB } | Sort-Object LastWriteTime -Descending | Select-Object -First 5)) {
                if (-not (Test-Path $logDirectory -PathType Container)) {
                    New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
                }

                $contents = Get-Content -Path $log.FullName -Raw -ErrorAction Stop
                if ($RedactIdentifiers) {
                    $contents = Protect-DiagnosticText -Text $contents
                }
                $safeName = 'watch-log-{0:D2}.txt' -f ($includedLogs.Count + 1)
                Set-Content -Path (Join-Path $logDirectory $safeName) -Value $contents -Encoding UTF8
                $includedLogs += $safeName
            }
        }

        $manifest = [ordered]@{
            logsIncluded = $includedLogs
            identifiersRedacted = $RedactIdentifiers
            uploadPerformed = $false
        } | ConvertTo-Json -Depth 4
        Set-Content -Path (Join-Path $staging 'manifest.json') -Value $manifest -Encoding UTF8

        New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $archivePath -Force
        return $archivePath
    }
    finally {
        Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DiagnosticBundleExport {
    $includeLogsAnswer = Read-Host 'Include up to five recent watch logs? (y/N)'
    $includeLogs = $includeLogsAnswer -match '^(?i)y(es)?$'
    $redactAnswer = Read-Host 'Redact watch IPs and device identifiers? (Y/n)'
    $redactIdentifiers = $redactAnswer -notmatch '^(?i)n(o)?$'

    $logs = @()
    $tooLargeLogs = 0
    if ($includeLogs -and (Test-Path $LogsDir -PathType Container)) {
        $availableLogs = @(Get-ChildItem -Path $LogsDir -Filter '*_watch_log_*.txt' -File | Where-Object { $_.Name -notlike '*_inprogress.txt' } | Sort-Object LastWriteTime -Descending)
        $tooLargeLogs = @($availableLogs | Where-Object { $_.Length -gt 5MB }).Count
        $logs = @($availableLogs | Where-Object { $_.Length -le 5MB } | Select-Object -First 5)
    }

    Write-UiLine ''
    Write-UiLine 'Diagnostic bundle preview:' -Color Cyan
    Write-UiLine '  diagnostics.json: OS, PowerShell, ADB/scrcpy versions and paths, and bridge status'
    Write-UiLine "  Identifier redaction: $(if ($redactIdentifiers) { 'On' } else { 'Off' })"
    if ($redactIdentifiers) {
        Write-UiLine '  Redaction is pattern-based and may miss identifiers in free-text logs.' -Color Yellow
    }
    if ($includeLogs) {
        Write-UiLine '  Watch logs:'
        if ($logs.Count -eq 0) {
            Write-UiLine '    None eligible to include'
        }
        else {
            foreach ($log in $logs) {
                Write-UiLine "    $($log.Name) ($([math]::Round($log.Length / 1KB, 1)) KB)"
            }
        }
        if ($tooLargeLogs -gt 0) {
            Write-UiLine "  Skipped $tooLargeLogs log(s) larger than 5 MB each."
        }
    }
    else {
        Write-UiLine '  Watch logs: Not included'
    }

    $confirmation = Read-Host 'Create this ZIP locally? (y/N)'
    if ($confirmation -notmatch '^(?i)y(es)?$') {
        Write-UiLine 'Diagnostic bundle export cancelled.' -Color Yellow
        return
    }

    try {
        $bundlePath = New-DiagnosticBundle -IncludeLogs:$includeLogs -RedactIdentifiers:$redactIdentifiers -LogFiles $logs
        Write-UiLine "Diagnostic bundle saved to $bundlePath" -Color Green
        Write-UiLine 'Review the ZIP before sharing it. Nothing was uploaded.' -Color Yellow
    }
    catch {
        Write-UiLine "Diagnostic bundle export failed: $($_.Exception.Message)" -Color Red
    }
}

function Connect-Watch {
    param(
        [string]$Ip,
        [string]$Port,
        [int]$Retries = 3,
        [switch]$NoSave
    )

    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        throw 'ADB is not installed or not on PATH.'
    }

    if ([string]::IsNullOrWhiteSpace($Ip) -or [string]::IsNullOrWhiteSpace($Port)) {
        throw 'Both IP and port are required.'
    }

    $target = "${Ip}:$Port"
    if ((Get-DeviceStateByTarget -Ip $Ip -Port $Port) -eq 'device') {
        if (-not $NoSave) {
            Save-IpCache -Ip $Ip -PairPort (Load-IpCache).pairPort -ConnPort $Port
            Save-CurrentProfileFromState -Ip $Ip -PairPort (Load-IpCache).pairPort -ConnPort $Port
        }
        return $true
    }
    $result = Invoke-NativeTool -Executable $Adb -Arguments @('start-server')
    Assert-NativeSuccess $result 'Starting ADB'

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $result = Invoke-NativeTool -Executable $Adb -Arguments @('connect', $target)
        $raw = $result.output

        $state = Get-DeviceStateByTarget -Ip $Ip -Port $Port
        if ($state -eq 'device') {
            if (-not $NoSave) {
                Save-IpCache -Ip $Ip -PairPort (Load-IpCache).pairPort -ConnPort $Port
                Save-CurrentProfileFromState -Ip $Ip -PairPort (Load-IpCache).pairPort -ConnPort $Port
            }
            return $true
        }

        if ($state -eq 'unauthorized') {
            Write-UiLine "The watch at ${Ip}:${Port} is unauthorized. Accept the debugging prompt on the watch and retry." -Color Yellow
            Invoke-ConnectionRecovery -Ip $Ip -Port $Port -Reason 'unauthorized device'
            if ($attempt -lt $Retries) {
                Start-Sleep -Seconds 2
            }
            continue
        }

        if ($state -eq 'offline' -or $state -eq 'not-found') {
            Write-UiLine "The watch at ${Ip}:${Port} is not currently reachable over ADB. Check the Wi-Fi network and the current Wireless Debugging port, then retry." -Color Yellow
            Invoke-ConnectionRecovery -Ip $Ip -Port $Port -Reason 'target not reachable'
            if ($attempt -lt $Retries) {
                Start-Sleep -Seconds 2
            }
            continue
        }

        if ($raw -match 'adb server is out of date|unable to connect to adb|failed to start daemon|cannot connect') {
            Write-UiLine $raw -Color Yellow
            Invoke-ConnectionRecovery -Ip $Ip -Port $Port -Reason 'ADB server conflict during connect'
        }

        if ($attempt -lt $Retries) {
            Start-Sleep -Seconds 2
        }
    }

    $finalState = Get-DeviceStateByTarget -Ip $Ip -Port $Port
    Write-UiLine (Get-ConnectionFailureAdvice -Ip $Ip -Port $Port -State $finalState) -Color Red
    return $false
}

function Get-OperationTarget {
    if ($script:TargetOverride) { return $script:TargetOverride }
    $cache = Load-IpCache
    if ($cache.ip -eq 'None' -or [string]::IsNullOrWhiteSpace($cache.connPort)) {
        throw 'No saved watch connection is available. Run connect first or specify --serial or --profile.'
    }
    return "$($cache.ip):$($cache.connPort)"
}

function Ensure-OperationTarget {
    param([string]$Serial)

    if (-not (Get-AdbExecutable)) { throw 'ADB is required but was not found.' }
    $entry = @(Get-DeviceEntries | Where-Object { $_.serial -eq $Serial -and $_.state -eq 'device' })
    if ($entry.Count -gt 0) { return }
    if ($Serial -match '^([^:]+):([0-9]+)$') {
        if (Connect-Watch -Ip $Matches[1] -Port $Matches[2] -Retries 2 -NoSave) { return }
    }
    throw "Device '$Serial' is not authorized and connected. Check the device, Wireless Debugging port, and debugging authorization."
}

function Invoke-Mirror {
    $Adb = Get-AdbExecutable
    $Scrcpy = Get-ScrcpyExecutable
    if (-not $Adb) {
        throw 'ADB is required but was not found.'
    }

    if (-not $Scrcpy) {
        throw 'scrcpy.exe is required but was not found on PATH.'
    }

    $target = Get-OperationTarget
    Ensure-OperationTarget $target
    $previousAdb = $env:ADB
    try {
        $env:ADB = $Adb
        $timeout = if ($script:AutomationMode) { $script:CommandTimeoutSeconds } else { 0 }
        $result = Invoke-NativeTool -Executable $Scrcpy -Arguments @("--serial=$target", '--max-size=360', '--video-bit-rate=1M') -TimeoutSeconds $timeout
        Assert-NativeSuccess $result 'Screen mirroring'
        Write-UiLine $result.output
    }
    finally {
        $env:ADB = $previousAdb
    }
}

function Invoke-Sideload {
    param([string]$ApkPath)

    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        throw 'ADB is required but was not found.'
    }

    if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
        throw "APK not found: $ApkPath"
    }

    $target = Get-OperationTarget
    Ensure-OperationTarget $target
    Install-ApkToTarget -ApkPath $ApkPath -Serial $target
}

function Install-ApkToTarget {
    param([string]$ApkPath, [string]$Serial)

    Write-UiLine "Installing $(Split-Path -Leaf $ApkPath) to ${Serial}..." -Color Yellow
    $result = Invoke-NativeTool -Executable (Get-AdbExecutable) -Arguments @('-s', $Serial, 'install', '-r', '-g', '--no-streaming', (Get-Item -LiteralPath $ApkPath).FullName)
    Write-UiLine $result.output
    Assert-NativeSuccess $result 'APK installation'
    if ($result.output -notmatch '(?m)^Success\s*$') {
        throw "ADB did not confirm APK installation: $($result.output)"
    }
}

function Invoke-BulkSideload {
    param([string]$ApkPath)

    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        throw 'ADB is required but was not found.'
    }
    if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) { throw "APK not found: $ApkPath" }

    $authorized = @()
    foreach ($device in Get-DeviceEntries) {
        if ($device.state -eq 'device') {
            $authorized += $device.serial
        }
    }

    if (-not $authorized -or $authorized.Count -eq 0) {
        throw 'No authorized devices were found.'
    }

    $failures = @()
    foreach ($serial in $authorized) {
        try {
            Install-ApkToTarget -ApkPath $ApkPath -Serial $serial
        }
        catch {
            $failures += "${serial}: $($_.Exception.Message)"
            Write-UiLine $failures[-1] -Color Red
        }
    }
    if ($failures.Count -gt 0) { throw "Bulk install failed on $($failures.Count) device(s): $($failures -join '; ')" }
}

function Invoke-LogsCapture {
    param([string]$Keyword = '')

    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        throw 'ADB is required but was not found.'
    }

    $cache = Load-IpCache
    if ($cache.ip -eq 'None' -or [string]::IsNullOrWhiteSpace($cache.connPort)) {
        throw 'No saved watch connection is available. Connect first.'
    }

    if (-not (Test-Path $LogsDir)) {
        New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
    }

    $startStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $tag = if ([string]::IsNullOrWhiteSpace($Keyword)) { 'none' } else { $Keyword }
    $fileName = [string]::Format('{0}_{1}_watch_log_{2}_{3}_inprogress.txt', $cache.ip, $cache.connPort, $tag, $startStamp)
    $fullPath = Join-Path $LogsDir $fileName
    New-Item -Path $fullPath -ItemType File -Force | Out-Null

    Write-UiLine "Live log capture is running for $($cache.ip):$($cache.connPort)." -Color Green
    Write-UiLine 'New matching lines will appear below. Press Ctrl+C to stop and save the log.' -Color Yellow

    try {
        & $Adb -s "$($cache.ip):$($cache.connPort)" logcat -v time 2>$null | ForEach-Object {
            $line = [string]$_
            if ([string]::IsNullOrWhiteSpace($Keyword) -or $line -match [regex]::Escape($Keyword)) {
                Write-UiLine $line
                Add-Content -Path $fullPath -Value $line -Encoding UTF8
            }
        }
    }
    finally {
        if (Test-Path $fullPath -PathType Leaf) {
            $endStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $finalName = [string]::Format('{0}_{1}_watch_log_{2}_{3}_{4}.txt', $cache.ip, $cache.connPort, $tag, $startStamp, $endStamp)
            $finalPath = Join-Path $LogsDir $finalName
            Move-Item -Path $fullPath -Destination $finalPath -Force
        }
    }

    return $finalPath
}

function Invoke-PairWatch {
    param(
        [string]$Ip,
        [string]$PairPort,
        [string]$PairCode,
        [string]$ConnectionPort = ''
    )

    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        throw 'ADB is required but was not found.'
    }

    $startResult = Invoke-NativeTool -Executable $Adb -Arguments @('start-server')
    if ($startResult.exitCode -ne 0) {
        Write-UiLine "ADB server failed to start: $($startResult.output)" -Color Red
        return $false
    }

    $pairResult = Invoke-NativeTool -Executable $Adb -Arguments @('pair', "${Ip}:$PairPort", $PairCode)
    if ($pairResult.exitCode -ne 0) {
        Write-UiLine $pairResult.output -Color Red
        Write-UiLine 'The shared ADB server was left running. Verify the pairing code and port, then retry.' -Color Yellow
        return $false
    }

    Save-IpCache -Ip $Ip -PairPort $PairPort -ConnPort $ConnectionPort
    Save-CurrentProfileFromState -Ip $Ip -PairPort $PairPort -ConnPort $ConnectionPort
    return $true
}

function New-GitHubIssueUrl {
    param(
        [string]$Step = 'general',
        [string]$ErrorText = '',
        [string]$AdditionalContext = ''
    )

    $baseUrl = 'https://github.com/aegorsuch/wearos-windows-bridge/issues/new'
    $cache = Load-IpCache
    $profile = Get-CurrentProfile
    $adb = Get-AdbExecutable
    $scrcpy = Get-ScrcpyExecutable
    $deviceSummary = Get-DeviceEntries

    $body = @()
    $body += '## Problem details'
    $body += "- Step: $Step"
    $body += "- Active profile: $($profile.name)"
    $body += "- Saved IP: $($cache.ip)"
    $body += "- Saved pair port: $(if ([string]::IsNullOrWhiteSpace($cache.pairPort)) { 'None' } else { $cache.pairPort })"
    $body += "- Saved connection port: $(if ([string]::IsNullOrWhiteSpace($cache.connPort)) { 'None' } else { $cache.connPort })"
    $body += "- ADB installed: $(if ($adb) { 'Yes' } else { 'No' })"
    $body += "- scrcpy installed: $(if ($scrcpy) { 'Yes' } else { 'No' })"
    if ($deviceSummary.Count -gt 0) {
        $body += '- Detected devices:'
        foreach ($entry in $deviceSummary) {
            $body += "  - $($entry.serial): $($entry.state)"
        }
    }
    else {
        $body += '- Detected devices: none'
    }
    if (-not [string]::IsNullOrWhiteSpace($AdditionalContext)) {
        $body += ''
        $body += '## Additional context'
        $body += $AdditionalContext.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorText)) {
        $body += ''
        $body += '## Error text'
        $body += $ErrorText.Trim()
    }

    $title = "Bug report: $Step"
    $encodedTitle = [System.Net.WebUtility]::UrlEncode($title)
    $encodedBody = [System.Net.WebUtility]::UrlEncode(($body -join "`r`n"))
    return "${baseUrl}?title=${encodedTitle}&body=${encodedBody}"
}

function Open-IssueReporter {
    param(
        [string]$DefaultStep = 'general',
        [string]$ErrorText = ''
    )

    Write-UiLine ''
    Write-UiLine 'REPORT A BUG' -Color Cyan
    Write-UiLine '---------------------------------------------------' -Color DarkCyan
    Write-UiLine 'Select the stage where the problem happened:' -Color Yellow
    Write-UiLine '  1. Pairing'
    Write-UiLine '  2. Connection'
    Write-UiLine '  3. Screen mirroring'
    Write-UiLine '  4. APK install'
    Write-UiLine '  5. Log capture'
    Write-UiLine '  6. Crash or startup failure'
    Write-UiLine '  7. Other'
    Write-UiLine '  8. Cancel'

    $choice = Read-Host 'Choose an option (1-8)'
    $stepMap = @{
        '1' = 'pairing'
        '2' = 'connection'
        '3' = 'mirroring'
        '4' = 'install'
        '5' = 'logs'
        '6' = 'crash'
        '7' = 'other'
        '8' = $null
    }

    if (-not $stepMap.ContainsKey($choice)) {
        return
    }

    $selectedStep = $stepMap[$choice]
    if ($null -eq $selectedStep) {
        return
    }

    $description = Read-Host 'Give a short description of what happened'
    $errorDetail = if ([string]::IsNullOrWhiteSpace($ErrorText)) { Read-Host 'Paste any error text or leave blank' } else { $ErrorText }
    $url = New-GitHubIssueUrl -Step $selectedStep -ErrorText $errorDetail -AdditionalContext $description

    Write-UiLine "Opening the bug report form for the $selectedStep step..." -Color Green
    try {
        Start-Process $url
    }
    catch {
        Write-UiLine "Open this link manually in your browser: $url" -Color Yellow
    }
}

function Get-PairInputError {
    param(
        [string]$Ip,
        [string]$PairPort,
        [string]$PairCode
    )

    $address = $null
    if ([string]::IsNullOrWhiteSpace($Ip) -or $Ip -match '\s' -or -not [System.Net.IPAddress]::TryParse($Ip, [ref]$address) -or $Ip -match ':') {
        return 'Enter the watch IP address only, such as 192.168.1.33. Do not add the pairing port to the IP address.'
    }

    $portNumber = 0
    if (-not [int]::TryParse($PairPort, [ref]$portNumber) -or $portNumber -lt 1 -or $portNumber -gt 65535) {
        return 'Enter the pairing port as numbers only, such as 41131.'
    }

    if ($PairCode -notmatch '^\d{6}$') {
        return 'Enter the six-digit Wi-Fi pairing code shown on the watch.'
    }

    return $null
}

function Show-Help {
    Write-UiLine 'WearOS Windows Bridge command-line options' -Color Cyan
    Write-UiLine '---------------------------------------------------' -Color DarkCyan
    Write-UiLine 'Profile management (optional):'
    Write-UiLine '  Most users can ignore profiles entirely and just use the default setup.'
    Write-UiLine '  Profiles are only useful when you want separate saved settings for different watches, such as a main watch and a dev watch.'
    Write-UiLine '  If you only have one watch, leave the default profile alone and save time by not thinking about profiles at all.'
    Write-UiLine '  Advanced users can switch profiles when moving between devices or delete old ones later.'
    Write-UiLine '--status                 Show the ADB device status screen'
    Write-UiLine '--status-json            Return structured JSON status data'
    Write-UiLine '--diagnose               Show environment diagnostics'
    Write-UiLine '--mirror                 Launch screen mirroring immediately'
    Write-UiLine '--connect IP PORT        Connect to a watch directly'
    Write-UiLine '--install APK            Sideload an APK without the menu'
    Write-UiLine '--bulk-install APK       Install an APK to all authorized devices'
    Write-UiLine '--logs [KEYWORD]         Capture a log with an optional filter'
    Write-UiLine '--profile-list           Show available watch profiles'
    Write-UiLine '--profile-use NAME       Switch the active watch profile'
    Write-UiLine '--profile-delete NAME    Delete a saved watch profile'
    Write-UiLine '--pair-connect-mirror    Pair a watch, connect, and mirror if possible'
    Write-UiLine '--help                  Show this help screen'
    Write-UiLine '--automation-help       Show noninteractive commands and modifiers'
    Write-UiLine 'Automation uses the same install/mirror functions as the menu; see --automation-help.'
}

function Show-AutomationHelp {
    Write-UiLine 'Android Studio / automation CLI'
    Write-UiLine 'Commands:'
    Write-UiLine '  --install APK | --bulk-install APK | --mirror | --connect IP PORT'
    Write-UiLine '  --status-json | --screenshot OUTPUT.png'
    Write-UiLine '  --tap X Y | --swipe X1 Y1 X2 Y2 [DURATION_MS] | --key KEYCODE'
    Write-UiLine '  --launch PACKAGE/ACTIVITY | --force-stop PACKAGE'
    Write-UiLine '  --recover-adb (explicitly restarts the shared server; interrupts Studio)'
    Write-UiLine 'Modifiers (after the command; order-independent):'
    Write-UiLine '  --serial SERIAL or --profile NAME: target this call without changing saved settings'
    Write-UiLine '  --adb PATH: select SDK adb.exe; alternatively set WEAROS_BRIDGE_ADB'
    Write-UiLine '  --non-interactive: never prompt; reject unsupported interactive commands'
    Write-UiLine '  --json: one JSON result on stdout, including errors; implies noninteractive'
    Write-UiLine '  --timeout SECONDS: native-command timeout, 1-3600 (default 120)'
    Write-UiLine 'Exit codes: 0 = success; 1 = failed operation or invalid arguments.'
    Write-UiLine 'Mirror runs in the foreground; automation timeout closes it. Normal --mirror has no timeout.'
    Write-UiLine 'Target modifiers apply only to device operations/status, not bulk install or server recovery.'
    Write-UiLine 'Connect takes IP/PORT and saves them unless --non-interactive or --json is used.'
}

function Invoke-DeviceControl {
    param([string]$Command, [string[]]$Values, [string]$Serial)

    $arguments = switch ($Command) {
        '--tap' { @('shell', 'input', 'tap') + $Values }
        '--swipe' { @('shell', 'input', 'swipe') + $Values }
        '--key' { @('shell', 'input', 'keyevent') + $Values }
        '--launch' { @('shell', 'am', 'start', '-W', '-n') + $Values }
        '--force-stop' { @('shell', 'am', 'force-stop') + $Values }
    }
    Ensure-OperationTarget $Serial
    $result = Invoke-NativeTool -Executable (Get-AdbExecutable) -Arguments (@('-s', $Serial) + $arguments)
    Assert-NativeSuccess $result 'Device control'
    if ($Command -eq '--launch' -and $result.output -match '(?im)^\s*(Error:|Error type|Exception|Status:\s*(?!\s*ok\b))') {
        throw "App launch failed: $($result.output)"
    }
    Write-UiLine $result.output
    return [pscustomobject]@{ output = $result.output }
}

function Save-WatchScreenshot {
    param([string]$OutputPath, [string]$Serial)

    $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $directory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Screenshot directory not found: $directory"
    }
    if (Test-Path -LiteralPath $destination -PathType Container) {
        throw "Screenshot path is a directory: $destination"
    }
    $temporary = Join-Path $directory ([System.IO.Path]::GetRandomFileName())
    try {
        Ensure-OperationTarget $Serial
        $result = Invoke-NativeTool -Executable (Get-AdbExecutable) -Arguments @('-s', $Serial, 'exec-out', 'screencap', '-p') -OutputPath $temporary
        Assert-NativeSuccess $result 'Screenshot capture'
        if ($result.output) { Write-UiLine $result.output }
        $stream = [System.IO.File]::OpenRead($temporary)
        try {
            $header = New-Object byte[] 8
            $read = $stream.Read($header, 0, 8)
            if ($read -ne 8 -or [BitConverter]::ToString($header) -ne '89-50-4E-47-0D-0A-1A-0A') {
                throw 'ADB did not return a PNG screenshot.'
            }
        }
        finally { $stream.Dispose() }
        Move-Item -LiteralPath $temporary -Destination $destination -Force
        return [pscustomobject]@{ path = $destination }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Read-AutomationArguments {
    param([string[]]$ScriptArgs)

    if ($ScriptArgs.Count -eq 0 -or -not $ScriptArgs[0].StartsWith('--')) {
        throw 'Specify a command first. See --automation-help.'
    }
    $options = [ordered]@{
        command = $ScriptArgs[0].ToLowerInvariant()
        values = @()
        serial = $null
        profile = $null
        adb = $null
        timeout = 120
        nonInteractive = $false
        json = $false
    }
    $seen = @{}
    for ($i = 1; $i -lt $ScriptArgs.Count; $i++) {
        $argument = $ScriptArgs[$i]
        if (-not $argument.StartsWith('--')) {
            $options.values += $argument
            continue
        }
        $name = $argument.ToLowerInvariant()
        if ($seen.ContainsKey($name)) { throw "Duplicate option: $argument" }
        $seen[$name] = $true
        if ($name -in @('--json', '--non-interactive')) {
            if ($name -eq '--json') { $options.json = $true }
            $options.nonInteractive = $true
            continue
        }
        if ($name -notin @('--serial', '--profile', '--adb', '--timeout')) {
            throw "Unknown automation option: $argument"
        }
        $i++
        if ($i -ge $ScriptArgs.Count -or [string]::IsNullOrWhiteSpace($ScriptArgs[$i]) -or $ScriptArgs[$i].StartsWith('--')) {
            throw "A value is required for $argument."
        }
        $value = $ScriptArgs[$i]
        if ($name -eq '--timeout') {
            $seconds = 0
            if (-not [int]::TryParse($value, [ref]$seconds) -or $seconds -lt 1 -or $seconds -gt 3600) {
                throw '--timeout must be an integer between 1 and 3600 seconds.'
            }
            $options.timeout = $seconds
        }
        else { $options[$name.Substring(2)] = $value }
    }
    if ($options.serial -and $options.profile) { throw 'Use either --serial or --profile, not both.' }
    $counts = @{
        '--install' = @(1); '--bulk-install' = @(1); '--mirror' = @(0)
        '--connect' = @(2); '--status-json' = @(0); '--screenshot' = @(1)
        '--tap' = @(2); '--swipe' = @(4, 5); '--key' = @(1)
        '--launch' = @(1); '--force-stop' = @(1); '--recover-adb' = @(0)
    }
    if (-not $counts.ContainsKey($options.command)) {
        throw "Command '$($options.command)' does not support automation modifiers. See --automation-help."
    }
    if ($options.values.Count -notin $counts[$options.command]) {
        throw "Incorrect number of arguments for $($options.command). See --automation-help."
    }
    if (($options.serial -or $options.profile) -and $options.command -in @('--connect', '--bulk-install', '--recover-adb')) {
        throw "$($options.command) does not accept --serial or --profile."
    }
    if ($options.serial -and $options.serial -match '[\s\x00-\x1f]') { throw 'Invalid device serial.' }
    if ($options.command -in @('--tap', '--swipe')) {
        foreach ($value in $options.values) {
            $number = 0
            if ($value -notmatch '^[0-9]+$' -or -not [int]::TryParse($value, [ref]$number)) {
                throw 'Coordinates and swipe duration must be nonnegative integers.'
            }
        }
    }
    if ($options.command -eq '--key' -and $options.values[0] -notmatch '^(?:[0-9]{1,4}|KEYCODE_[A-Z0-9_]+)$') {
        throw 'Use a numeric keycode or a KEYCODE_NAME such as KEYCODE_HOME.'
    }
    if ($options.command -eq '--launch' -and $options.values[0] -notmatch '^[A-Za-z][A-Za-z0-9_.]*/[A-Za-z_.][A-Za-z0-9_.$]*$') {
        throw 'Use an explicit PACKAGE/ACTIVITY component for --launch.'
    }
    if ($options.command -eq '--force-stop' -and $options.values[0] -notmatch '^[A-Za-z][A-Za-z0-9_.]*$') {
        throw 'Invalid app package name.'
    }
    if ($options.command -eq '--connect') {
        $address = $null
        $port = 0
        if (-not [System.Net.IPAddress]::TryParse($options.values[0], [ref]$address) -or $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw '--connect requires an IPv4 address without a port.'
        }
        if (-not [int]::TryParse($options.values[1], [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            throw 'Connection port must be between 1 and 65535.'
        }
    }
    return [pscustomobject]$options
}

function Invoke-AutomationCommand {
    param([string[]]$ScriptArgs)

    $previousAdb = $script:AdbOverride
    $previousTarget = $script:TargetOverride
    $previousTimeout = $script:CommandTimeoutSeconds
    $previousMode = $script:AutomationMode
    $previousMessages = $script:JsonMessages
    $json = $ScriptArgs -contains '--json'
    $result = [ordered]@{ schemaVersion = 1; command = $ScriptArgs[0]; success = $false; serial = $null; data = $null; messages = @(); error = $null }
    $exitCode = 0
    try {
        if ($json) { $script:JsonMessages = [System.Collections.Generic.List[string]]::new() }
        $options = Read-AutomationArguments $ScriptArgs
        $script:AutomationMode = $true
        $script:CommandTimeoutSeconds = $options.timeout
        if ($options.adb) {
            if (-not (Test-Path -LiteralPath $options.adb -PathType Leaf)) { throw "ADB executable not found: $($options.adb)" }
            $script:AdbOverride = (Get-Item -LiteralPath $options.adb).FullName
        }
        if ($options.profile) {
            $store = Load-ProfileStore -ReadOnly
            if (-not $store.profiles.Contains($options.profile)) { throw "Profile '$($options.profile)' was not found." }
            $profile = $store.profiles[$options.profile]
            if ($profile.ip -eq 'None' -or [string]::IsNullOrWhiteSpace($profile.connPort)) { throw "Profile '$($options.profile)' has no saved connection." }
            $script:TargetOverride = "$($profile.ip):$($profile.connPort)"
        }
        elseif ($options.serial) { $script:TargetOverride = $options.serial }
        if ($options.command -notin @('--bulk-install', '--recover-adb', '--connect', '--status-json')) {
            $result.serial = Get-OperationTarget
        }
        $values = $options.values
        switch ($options.command) {
            '--connect' {
                $result.serial = "$($values[0]):$($values[1])"
                if (-not (Connect-Watch -Ip $values[0] -Port $values[1] -NoSave:$options.nonInteractive)) { throw 'Connection failed.' }
            }
            '--install' { Invoke-Sideload $values[0] }
            '--bulk-install' { Invoke-BulkSideload $values[0] }
            '--mirror' { Invoke-Mirror }
            '--status-json' {
                $result.data = Get-StatusJson
                if ($script:TargetOverride) {
                    $result.serial = $script:TargetOverride
                    $result.data['selectedSerial'] = $script:TargetOverride
                    $result.data['selectedConnected'] = @($result.data.deviceSummary | Where-Object { $_.serial -eq $script:TargetOverride -and $_.state -eq 'device' }).Count -gt 0
                }
            }
            '--screenshot' { $result.data = Save-WatchScreenshot -OutputPath $values[0] -Serial $result.serial }
            '--recover-adb' { Recover-Adb -Reason 'explicit CLI request' }
            default { $result.data = Invoke-DeviceControl -Command $options.command -Values $values -Serial $result.serial }
        }
        $result.success = $true
    }
    catch {
        $exitCode = 1
        $result.error = $_.Exception.Message
        if (-not $json) { Write-UiLine $result.error -Color Red }
    }
    finally {
        if ($json) { $result.messages = @($script:JsonMessages.ToArray()) }
        $script:AdbOverride = $previousAdb
        $script:TargetOverride = $previousTarget
        $script:CommandTimeoutSeconds = $previousTimeout
        $script:AutomationMode = $previousMode
        $script:JsonMessages = $previousMessages
    }
    if ($json) { $result | ConvertTo-Json -Depth 8 }
    elseif ($result.success) {
        if ($result.command -eq '--status-json') { $result.data | ConvertTo-Json -Depth 6 }
        elseif ($result.data -and $result.data.path) { Write-UiLine "Saved screenshot to $($result.data.path)" -Color Green }
        else { Write-UiLine 'Operation completed.' -Color Green }
    }
    $global:LASTEXITCODE = $exitCode
    return
}

function Show-DevMenu {
    while ($true) {
        Write-Host ''
        Write-Host '===================================================' -ForegroundColor DarkGreen
        Write-Host '              DEVELOPER MODE' -ForegroundColor Yellow
        Write-Host '===================================================' -ForegroundColor DarkGreen
        Write-Host '  1. Manage Profiles'
        Write-Host '  2. Bulk Sideload APK'
        Write-Host '  3. Diagnose Environment'
        Write-Host '  4. Export Diagnostic Bundle'
        Write-Host '  5. Pair + Connect + Mirror'
        Write-Host '  6. Report a Bug'
        Write-Host '  7. Back to main menu'
        Write-Host '===================================================' -ForegroundColor DarkGreen

        $choice = Read-Host 'Select an option (1-7)'
        switch ($choice) {
            '1' {
                $profiles = Load-ProfileStore
                Write-UiLine 'Available profiles:' -Color Cyan
                foreach ($key in $profiles.profiles.Keys) {
                    $entry = $profiles.profiles[$key]
                    $marker = if ($key -eq $profiles.activeProfile) { ' * active' } else { '' }
                    Write-UiLine "  $key -> $($entry.ip)$marker"
                }

                $name = Read-Host 'Enter a profile name to use, or type DELETE NAME to remove a profile, or leave blank to keep the current one'
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    if ($name -match '^(?i)delete\s+(.+)$') {
                        $target = $matches[1].Trim()
                        $confirmation = Read-Host "Delete profile '$target'? This cannot be undone. (y/N)"
                        if ($confirmation -match '^(?i)y(es)?$') {
                            try {
                                Remove-Profile -ProfileName $target
                                Write-UiLine "Deleted profile '$target'." -Color Green
                            }
                            catch {
                                Write-UiLine $_.Exception.Message -Color Red
                            }
                        }
                        else {
                            Write-UiLine "Profile deletion cancelled for '$target'." -Color Yellow
                        }
                    }
                    else {
                        Set-CurrentProfile -ProfileName $name
                        Write-UiLine "Switched to profile '$name'." -Color Green
                    }
                }
            }
            '2' {
                $apk = Read-Host 'Enter APK path for bulk install'
                if (-not [string]::IsNullOrWhiteSpace($apk)) {
                    try {
                        Invoke-BulkSideload -ApkPath $apk.Trim('"')
                    }
                    catch {
                        Write-UiLine $_.Exception.Message -Color Red
                    }
                }
            }
            '3' {
                Show-DiagnoseInfo
                Read-Host 'Press Enter to continue'
            }
            '4' {
                Invoke-DiagnosticBundleExport
                Read-Host 'Press Enter to continue'
            }
            '5' {
                $ip = Read-Host 'Watch IP'
                $pairPort = Read-Host 'Pairing port'
                $pairCode = Read-Host 'Pairing code'
                if (-not [string]::IsNullOrWhiteSpace($ip) -and -not [string]::IsNullOrWhiteSpace($pairPort) -and -not [string]::IsNullOrWhiteSpace($pairCode)) {
                    try {
                        $pairOk = Invoke-PairWatch -Ip $ip -PairPort $pairPort -PairCode $pairCode
                        if ($pairOk) {
                            $connPort = Read-Host 'Connection port'
                            if (-not [string]::IsNullOrWhiteSpace($connPort)) {
                                Connect-Watch -Ip $ip -Port $connPort
                                Invoke-Mirror
                            }
                        }
                    }
                    catch {
                        Write-UiLine $_.Exception.Message -Color Red
                    }
                }
            }
            '6' {
                Open-IssueReporter
            }
            '7' {
                return
            }
            default {
            }
        }
    }
}

function Show-Menu {
    while ($true) {
        $profile = Get-CurrentProfile
        $cache = Load-IpCache
        $Adb = Get-AdbExecutable
        $Scrcpy = Get-ScrcpyExecutable
        $entries = Get-DeviceEntries
        # Pairing is saved authorization and does not appear in `adb devices`.
        $paired = ($cache.ip -ne 'None' -and -not [string]::IsNullOrWhiteSpace($cache.pairPort))
        $connected = $false
        if ($cache.ip -ne 'None' -and -not [string]::IsNullOrWhiteSpace($cache.connPort)) {
            foreach ($entry in $entries) {
                if ($entry.serial -eq "$($cache.ip):$($cache.connPort)" -and $entry.state -eq 'device') {
                    $connected = $true
                    break
                }
            }
        }

        Write-Host ''
        Write-Host '===================================================' -ForegroundColor DarkGreen
        Write-Host '             WEAROS WINDOWS BRIDGE' -ForegroundColor Green
        Write-Host '===================================================' -ForegroundColor DarkGreen
        Write-Host "  Scrcpy System Path: $(if ($Scrcpy) { 'Configured' } else { 'Not configured' })"
        if ($paired) {
            Write-Host "  Pair status: Paired (saved) to $($cache.ip):$($cache.pairPort)"
        }
        else {
            Write-Host '  Pair status: Not paired'
        }
        if ($connected) {
            Write-Host "  Connect status: Connected to $($cache.ip):$($cache.connPort)"
        }
        else {
            Write-Host '  Connect status: Not connected'
        }
        if (-not $Scrcpy) {
            if (Test-Path $PathConfiguredPath -PathType Leaf) {
                Write-Host '  ACTION NEEDED: The saved scrcpy folder was not found. Select 1 to choose its new location.' -ForegroundColor Yellow
            }
            else {
                Write-Host '  ACTION NEEDED: Select 1 to configure scrcpy before pairing or connecting.' -ForegroundColor Yellow
            }
        }
        Write-Host '===================================================' -ForegroundColor DarkGreen
        Write-Host '  --- Setup / Configuration ---'
        Write-Host '  1. Setup scrcpy System Path'
        Write-Host '  2. Pair Watch via Wi-Fi'
        Write-Host '  3. Connect to Watch'
        Write-Host ''
        Write-Host '  --- Watch Actions ---'
        Write-Host '  4. Launch Screen Mirroring'
        Write-Host '  5. Sideload an APK File'
        Write-Host '  6. Live Watch Logs'
        Write-Host ''
        Write-Host '  --- Developer ---'
        Write-Host '  7. Developer Tools'
        Write-Host '  8. Report a Bug'
        Write-Host '===================================================' -ForegroundColor DarkGreen
        $choice = Read-Host 'Select an option (1-8)'

        switch ($choice) {
            '1' {
                Write-UiLine 'scrcpy is the open-source screen-mirroring tool used to display a Wear OS watch on Windows.' -Color Cyan
                Write-UiLine 'Open this clickable link in your browser (Ctrl+click if required by your terminal): https://github.com/Genymobile/scrcpy/releases' -Color Cyan
                Write-UiLine 'Download the latest scrcpy-win64 zip and extract it.' -Color Cyan
                Write-UiLine 'Choose the extracted folder containing both scrcpy.exe and adb.exe.' -Color Cyan
                Write-UiLine 'This only configures the current bridge session; it does not change your permanent Windows PATH.' -Color Cyan
                $folder = Read-Host 'Enter or click and drag the extracted scrcpy folder here (press Enter to cancel)'
                if ([string]::IsNullOrWhiteSpace($folder)) {
                    Write-UiLine 'No folder entered; setup canceled. Returning to the menu.' -Color Yellow
                    continue
                }
                try {
                    Set-ScrcpyPathFromFolder -Folder $folder
                }
                catch {
                    Write-UiLine $_.Exception.Message -Color Red
                }
            }
            '2' {
                $pairCode = Read-Host 'Enter 6-digit Pairing Code (example: 952775)'
                $ip = Read-Host 'Enter Watch IP Address only (example: 192.168.1.33; do not include the port)'
                $pairPort = Read-Host 'Enter Pairing Port only (example: 41131; numbers only)'
                $pairInputError = Get-PairInputError -Ip $ip -PairPort $pairPort -PairCode $pairCode
                if ($pairInputError) {
                    Write-UiLine "Pairing input error: $pairInputError" -Color Red
                }
                else {
                    try {
                        $ok = Invoke-PairWatch -Ip $ip -PairPort $pairPort -PairCode $pairCode
                        if ($ok) { Write-UiLine 'Pairing succeeded.' -Color Green } else { Write-UiLine 'Pairing failed.' -Color Red }
                    }
                    catch {
                        Write-UiLine "Pairing failed: $($_.Exception.Message)" -Color Red
                    }
                }
            }
            '3' {
                $defaultIp = if ($cache.ip -ne 'None' -and -not [string]::IsNullOrWhiteSpace($cache.ip)) { $cache.ip } else { 'saved paired IP' }
                $ip = Read-Host "Enter Watch IP Address (leave blank to use $defaultIp)"
                $port = Read-Host 'Enter Connection Port'

                $resolvedIp = if ([string]::IsNullOrWhiteSpace($ip)) { $cache.ip } else { $ip }
                $resolvedPort = if ([string]::IsNullOrWhiteSpace($port)) { $cache.connPort } else { $port }

                if ([string]::IsNullOrWhiteSpace($resolvedIp) -or $resolvedIp -eq 'None') {
                    Write-UiLine 'No paired watch is available yet. Pair a watch first or enter an IP address manually.' -Color Yellow
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($resolvedPort)) {
                    Write-UiLine 'A connection port is required before connecting.' -Color Yellow
                    continue
                }

                try {
                    $ok = Connect-Watch -Ip $resolvedIp -Port $resolvedPort
                    if ($ok) { Write-UiLine "Connected to ${resolvedIp}:${resolvedPort}." -Color Green } else { Write-UiLine 'Connection failed.' -Color Red }
                }
                catch {
                    Write-UiLine $_.Exception.Message -Color Red
                }
            }
            '4' {
                try {
                    Invoke-Mirror
                }
                catch {
                    Write-UiLine $_.Exception.Message -Color Red
                }
            }
            '5' {
                $apk = Read-Host 'Enter APK path or click and drag the APK file here'
                if (-not [string]::IsNullOrWhiteSpace($apk)) {
                    try {
                        Invoke-Sideload -ApkPath $apk.Trim('"')
                        Write-UiLine 'Install completed.' -Color Green
                    }
                    catch {
                        Write-UiLine $_.Exception.Message -Color Red
                    }
                }
            }
            '6' {
                $keyword = Read-Host 'Optional keyword filter (leave blank for all logs)'
                try {
                    $file = Invoke-LogsCapture -Keyword $keyword
                    Write-UiLine "Saved logs to $file" -Color Green
                }
                catch {
                    Write-UiLine $_.Exception.Message -Color Red
                }
            }
            '7' {
                Show-DevMenu
            }
            '8' {
                Open-IssueReporter
            }
            default {
            }
        }
    }
}

function Main {
    param([string[]]$ScriptArgs = @())

    try {
        if ($ScriptArgs.Count -eq 0) {
            Show-Menu
            return
        }
        if ($ScriptArgs[0] -eq '--automation-help' -and $ScriptArgs.Count -eq 1) {
            Show-AutomationHelp
            return
        }
        $automationCommands = @('--screenshot', '--tap', '--swipe', '--key', '--launch', '--force-stop', '--recover-adb')
        $automationModifiers = @('--serial', '--profile', '--adb', '--non-interactive', '--json', '--timeout')
        if ($ScriptArgs[0] -in $automationCommands -or @($ScriptArgs | Where-Object { $_ -in $automationModifiers }).Count -gt 0) {
            Invoke-AutomationCommand $ScriptArgs
            if ($global:LASTEXITCODE -ne 0) { exit 1 }
            return
        }

        $firstArg = $ScriptArgs[0]
        if (-not $firstArg.StartsWith('--')) {
            try {
                Set-ScrcpyPathFromFolder -Folder $firstArg
                return
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
                Show-Help
                exit 1
            }
        }

        $command = $firstArg.ToLowerInvariant()

        switch ($command) {
        '--help' {
            Show-Help
            return
        }
        '--dev-mode' {
            Set-DevMode
            Show-Menu
            return
        }
        '--status' {
            Show-Status
            return
        }
        '--status-json' {
            $json = Get-StatusJson
            $json | ConvertTo-Json -Depth 6
            return
        }
        '--diagnose' {
            Show-DiagnoseInfo
            return
        }
        '--mirror' {
            try {
                Invoke-Mirror
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
                exit 1
            }
            return
        }
        '--connect' {
            if ($ScriptArgs.Count -lt 3) {
                Write-UiLine 'Usage: --connect IP PORT' -Color Red
                exit 1
            }

            try {
                $ok = Connect-Watch -Ip $ScriptArgs[1] -Port $ScriptArgs[2]
                if ($ok) {
                    Write-UiLine "Connected to $($ScriptArgs[1]):$($ScriptArgs[2])." -Color Green
                    return
                }
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
                exit 1
            }

            Write-UiLine 'Connection failed.' -Color Red
            exit 1
        }
        '--install' {
            if ($ScriptArgs.Count -lt 2) {
                Write-UiLine 'Usage: --install APK_PATH' -Color Red
                exit 1
            }

            try {
                Invoke-Sideload -ApkPath $ScriptArgs[1]
                Write-UiLine 'Install completed.' -Color Green
                return
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
                exit 1
            }
        }
        '--bulk-install' {
            if ($ScriptArgs.Count -lt 2) {
                Write-UiLine 'Usage: --bulk-install APK_PATH' -Color Red
                exit 1
            }

            try {
                Invoke-BulkSideload -ApkPath $ScriptArgs[1]
                return
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
                exit 1
            }
        }
        '--logs' {
            $keyword = if ($ScriptArgs.Count -gt 1) { $ScriptArgs[1] } else { '' }
            try {
                $file = Invoke-LogsCapture -Keyword $keyword
                Write-UiLine "Saved logs to $file" -Color Green
                return
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
                exit 1
            }
        }
        '--profile-list' {
            $store = Load-ProfileStore
            foreach ($key in $store.profiles.Keys) {
                $entry = $store.profiles[$key]
                $status = if ($key -eq $store.activeProfile) { 'active' } else { 'idle' }
                Write-UiLine "$key -> $($entry.ip) [$status]"
            }
            return
        }
        '--profile-use' {
            if ($ScriptArgs.Count -lt 2) {
                Write-UiLine 'Usage: --profile-use NAME' -Color Red
                exit 1
            }

            try {
                $profile = Set-CurrentProfile -ProfileName $ScriptArgs[1]
                Write-UiLine "Switched to profile '$($profile.name)'." -Color Green
                return
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
                exit 1
            }
        }
        '--profile-delete' {
            if ($ScriptArgs.Count -lt 2) {
                Write-UiLine 'Usage: --profile-delete NAME' -Color Red
                exit 1
            }

            try {
                Remove-Profile -ProfileName $ScriptArgs[1]
                Write-UiLine "Deleted profile '$($ScriptArgs[1])'." -Color Green
                return
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
                exit 1
            }
        }
        '--pair-connect-mirror' {
            $ip = if ($ScriptArgs.Count -gt 1) { $ScriptArgs[1] } else { Read-Host 'Watch IP address' }
            $pairPort = if ($ScriptArgs.Count -gt 2) { $ScriptArgs[2] } else { Read-Host 'Pairing port' }
            $pairCode = if ($ScriptArgs.Count -gt 3) { $ScriptArgs[3] } else { Read-Host 'Pairing code' }
            $connPort = if ($ScriptArgs.Count -gt 4) { $ScriptArgs[4] } else { Read-Host 'Connection port' }

            try {
                $pairOk = Invoke-PairWatch -Ip $ip -PairPort $pairPort -PairCode $pairCode -ConnectionPort $connPort
                if (-not $pairOk) {
                    throw 'Pairing failed.'
                }
                $connected = Connect-Watch -Ip $ip -Port $connPort
                if (-not $connected) {
                    throw 'Connection failed after pairing.'
                }
                Invoke-Mirror
                return
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
                exit 1
            }
        }
            default {
                Write-UiLine "Unsupported command-line option: $($ScriptArgs[0])" -Color Red
                Show-Help
                exit 1
            }
        }
    }
    catch {
        Write-UiLine "The bridge hit an unexpected error: $($_.Exception.Message)" -Color Red
        Write-UiLine 'You can open a prefilled bug report to help us fix it.' -Color Yellow
        if ($ScriptArgs.Count -eq 0) {
            $reportChoice = Read-Host 'Open GitHub issue now? (Y/N)'
            if ($reportChoice -match '^(?i)y(es)?$') {
                Open-IssueReporter -DefaultStep 'crash' -ErrorText $_.Exception.Message
            }
        }
        exit 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main -ScriptArgs $args
}
