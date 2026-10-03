$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$IpCachePath = Join-Path $ScriptDir 'ip_cache.txt'
$ProfilesPath = Join-Path $ScriptDir 'watch_profiles.json'
$ActiveProfilePath = Join-Path $ScriptDir 'active_profile.txt'
$PathConfiguredPath = Join-Path $ScriptDir 'path_configured.txt'
$LogsDir = Join-Path $ScriptDir 'watch_logs'

function Write-UiLine {
    param(
        [string]$Message,
        [string]$Color = 'Gray'
    )

    Write-Host $Message -ForegroundColor $Color
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
        $warning.advice = 'Close other ADB-based tools such as Android Studio, then retry. If needed, remove the extra adb.exe from PATH or launch the bridge from a clean shell.'
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
        $warning.advice = 'ADB is reporting a server conflict or stale daemon. Close other ADB-based tools, then retry pairing or connection.'
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

    $message.Add('If you see "adb server is out of date", close other ADB-based tools such as Android Studio, then retry.')
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

    Recover-Adb -Reason $Reason
    Start-Sleep -Seconds 1
    return $true
}

function Get-AdbExecutable {
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
        Set-Content -Path $ActiveProfilePath -Value $store.activeProfile -Encoding ASCII
    }
    else {
        $profileName = (Get-Content -Path $ActiveProfilePath -TotalCount 1 -ErrorAction SilentlyContinue).Trim()
        if (-not [string]::IsNullOrWhiteSpace($profileName) -and $store.profiles.Contains($profileName)) {
            $store.activeProfile = $profileName
        }
        else {
            $store.activeProfile = 'default'
            Set-Content -Path $ActiveProfilePath -Value 'default' -Encoding ASCII
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
    $store = Load-ProfileStore
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
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Adb kill-server *> $null
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'adb.exe' }
    foreach ($process in $processes) {
        try {
            $process | Invoke-CimMethod -MethodName Terminate | Out-Null
        }
        catch {
            # Ignore cleanup failures; the process may have already exited.
        }
    }

    Start-Sleep -Seconds 1
    try {
        $ErrorActionPreference = 'Continue'
        & $Adb start-server *> $null
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-DeviceEntries {
    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        return @()
    }

    $raw = ''
    try {
        $raw = (& $Adb devices 2>&1 | Out-String)
    }
    catch {
        # ADB sometimes emits daemon startup text on stderr during a recover cycle.
        # Treat that as a benign startup message instead of a terminating script error.
        $raw = ''
    }

    $entries = @()

    foreach ($line in ($raw -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match 'List of devices attached|daemon not running|starting now|adb.exe') { continue }

        $parts = $line -split '\s+'
        if ($parts.Count -lt 2) { continue }
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
    $profile = Get-CurrentProfile
    $cache = Load-IpCache
    $store = Load-ProfileStore
    $summary = Get-DeviceEntries

    # Pairing is an authorization saved by ADB; it is not listed by `adb devices`.
    $paired = ($cache.ip -ne 'None' -and -not [string]::IsNullOrWhiteSpace($cache.pairPort))
    $connected = $false
    if ($cache.ip -ne 'None' -and -not [string]::IsNullOrWhiteSpace($cache.connPort)) {
        foreach ($entry in $summary) {
            if ($entry.serial -eq "$($cache.ip):$($cache.connPort)" -or $entry.serial -like "$($cache.ip):*") {
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
            if ($entry.serial -eq "$($cache.ip):$($cache.connPort)" -or $entry.serial -like "$($cache.ip):*") {
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

function Connect-Watch {
    param(
        [string]$Ip,
        [string]$Port,
        [int]$Retries = 3
    )

    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        throw 'ADB is not installed or not on PATH.'
    }

    if ([string]::IsNullOrWhiteSpace($Ip) -or [string]::IsNullOrWhiteSpace($Port)) {
        throw 'Both IP and port are required.'
    }

    Write-AdbHealthWarning

    try {
        & $Adb start-server *> $null
    }
    catch {
        # ADB may write daemon startup text to stderr even when it starts successfully.
    }
    Start-Sleep -Seconds 1

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            & $Adb disconnect "${Ip}:$Port" *> $null 2>&1
        }
        catch {
            # `adb disconnect` can emit benign startup text while its daemon starts.
        }

        $raw = ''
        try {
            $raw = & $Adb connect "${Ip}:$Port" 2>&1 | Out-String
        }
        catch {
            $raw = $_.Exception.Message
        }

        $state = Get-DeviceStateByTarget -Ip $Ip -Port $Port
        if ($state -eq 'device') {
            Save-IpCache -Ip $Ip -PairPort (Load-IpCache).pairPort -ConnPort $Port
            Save-CurrentProfileFromState -Ip $Ip -PairPort (Load-IpCache).pairPort -ConnPort $Port
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
            Write-UiLine 'ADB reported a daemon or server conflict. Recovering the server and retrying the connection.' -Color Yellow
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

function Invoke-Mirror {
    $Adb = Get-AdbExecutable
    $Scrcpy = Get-ScrcpyExecutable
    if (-not $Adb) {
        throw 'ADB is required but was not found.'
    }

    if (-not $Scrcpy) {
        throw 'scrcpy.exe is required but was not found on PATH.'
    }

    $cache = Load-IpCache
    if ($cache.ip -eq 'None' -or [string]::IsNullOrWhiteSpace($cache.connPort)) {
        throw 'No saved watch connection is available. Run connect first.'
    }

    $connected = Connect-Watch -Ip $cache.ip -Port $cache.connPort -Retries 2
    if (-not $connected) {
        $state = Get-DeviceStateByTarget -Ip $cache.ip -Port $cache.connPort
        throw "Unable to connect to $($cache.ip):$($cache.connPort) before mirroring. $(Get-ConnectionFailureAdvice -Ip $cache.ip -Port $cache.connPort -State $state)"
    }

    & $Scrcpy --serial="$($cache.ip):$($cache.connPort)" --max-size=360 --video-bit-rate=1M
}

function Invoke-Sideload {
    param([string]$ApkPath)

    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        throw 'ADB is required but was not found.'
    }

    $cache = Load-IpCache
    if ($cache.ip -eq 'None' -or [string]::IsNullOrWhiteSpace($cache.connPort)) {
        throw 'No saved watch connection is available. Run connect first.'
    }

    if (-not (Test-Path $ApkPath -PathType Leaf)) {
        throw "APK not found: $ApkPath"
    }

    Write-UiLine "Checking connection to $($cache.ip):$($cache.connPort)..." -Color Yellow
    $connected = Connect-Watch -Ip $cache.ip -Port $cache.connPort -Retries 2
    if (-not $connected) {
        $state = Get-DeviceStateByTarget -Ip $cache.ip -Port $cache.connPort
        throw "Unable to connect to $($cache.ip):$($cache.connPort) before installing. $(Get-ConnectionFailureAdvice -Ip $cache.ip -Port $cache.connPort -State $state)"
    }

    Write-UiLine "Installing $(Split-Path -Leaf $ApkPath) to $($cache.ip):$($cache.connPort)..." -Color Yellow
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $installOutput = & $Adb -s "$($cache.ip):$($cache.connPort)" install -r -g --no-streaming "$ApkPath" 2>&1 | Out-String
        $installExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    Write-UiLine $installOutput
    if ($installOutput -match '(?m)^Success\s*$') {
        if ($installExitCode -ne 0) {
            Write-UiLine 'APK installed, but the watch disconnected immediately afterward.' -Color Yellow
        }
        return
    }

    if ($installExitCode -ne 0) {
        $deviceState = Get-DeviceStateByTarget -Ip $cache.ip -Port $cache.connPort
        if ($deviceState -eq 'offline' -or $deviceState -eq 'not-found') {
            throw 'The watch disconnected during installation. Keep the watch awake with Wireless Debugging enabled, reconnect it, then retry the APK install.'
        }

        throw "APK installation failed (ADB exit code $installExitCode)."
    }
}

function Invoke-BulkSideload {
    param([string]$ApkPath)

    $Adb = Get-AdbExecutable
    if (-not $Adb) {
        throw 'ADB is required but was not found.'
    }

    $authorized = @()
    foreach ($device in Get-DeviceEntries) {
        if ($device.state -eq 'device') {
            $authorized += $device.serial
        }
    }

    if (-not $authorized -or $authorized.Count -eq 0) {
        throw 'No authorized devices were found.'
    }

    foreach ($serial in $authorized) {
        Write-UiLine "Installing to $serial..." -Color Green
        & $Adb -s $serial install -r -g --no-streaming "$ApkPath"
        if ($LASTEXITCODE -ne 0) {
            Write-UiLine "Install failed for $serial" -Color Red
        }
        else {
            Write-UiLine "Install succeeded for $serial" -Color Green
        }
    }
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

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Adb start-server *> $null
        $startExitCode = $LASTEXITCODE
        if ($startExitCode -eq 0) {
            $raw = & $Adb pair "${Ip}:$PairPort" $PairCode 2>&1 | Out-String
            $pairExitCode = $LASTEXITCODE
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($startExitCode -ne 0) {
        Write-UiLine 'ADB server failed to start. Close other ADB-based tools and try again.' -Color Red
        return $false
    }

    if ($pairExitCode -ne 0) {
        Write-UiLine $raw -Color Red
        Recover-Adb -Reason 'pairing failed'
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
}

function Show-DevMenu {
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
            Show-DevMenu
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
            Show-DevMenu
        }
        '3' {
            Show-DiagnoseInfo
            Read-Host 'Press Enter to continue'
            Show-DevMenu
        }
        '4' {
            Write-UiLine 'Diagnostic bundle export is not yet implemented in the PowerShell core. The existing batch helper logic can be restored later.' -Color Yellow
            Read-Host 'Press Enter to continue'
            Show-DevMenu
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
            Show-DevMenu
        }
        '6' {
            Open-IssueReporter
            Show-DevMenu
        }
        '7' {
            Show-Menu
        }
        default {
            Show-DevMenu
        }
    }
}

function Show-Menu {
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
            if ($entry.serial -eq "$($cache.ip):$($cache.connPort)" -or $entry.serial -like "$($cache.ip):*") {
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
                Show-Menu
                return
            }
            try {
                Set-ScrcpyPathFromFolder -Folder $folder
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
            }
            Show-Menu
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
            Show-Menu
        }
        '3' {
            $defaultIp = if ($cache.ip -ne 'None' -and -not [string]::IsNullOrWhiteSpace($cache.ip)) { $cache.ip } else { 'saved paired IP' }
            $ip = Read-Host "Enter Watch IP Address (leave blank to use $defaultIp)"
            $port = Read-Host 'Enter Connection Port'

            $resolvedIp = if ([string]::IsNullOrWhiteSpace($ip)) { $cache.ip } else { $ip }
            $resolvedPort = if ([string]::IsNullOrWhiteSpace($port)) { $cache.connPort } else { $port }

            if ([string]::IsNullOrWhiteSpace($resolvedIp) -or $resolvedIp -eq 'None') {
                Write-UiLine 'No paired watch is available yet. Pair a watch first or enter an IP address manually.' -Color Yellow
                Show-Menu
                return
            }

            if ([string]::IsNullOrWhiteSpace($resolvedPort)) {
                Write-UiLine 'A connection port is required before connecting.' -Color Yellow
                Show-Menu
                return
            }

            try {
                $ok = Connect-Watch -Ip $resolvedIp -Port $resolvedPort
                if ($ok) { Write-UiLine "Connected to ${resolvedIp}:${resolvedPort}." -Color Green } else { Write-UiLine 'Connection failed.' -Color Red }
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
            }
            Show-Menu
        }
        '4' {
            try {
                Invoke-Mirror
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
            }
            Show-Menu
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
            Show-Menu
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
            Show-Menu
        }
        '7' {
            Show-DevMenu
        }
        '8' {
            Open-IssueReporter
            Show-Menu
        }
        default {
            Show-Menu
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
        $reportChoice = Read-Host 'Open GitHub issue now? (Y/N)'
        if ($reportChoice -match '^(?i)y(es)?$') {
            Open-IssueReporter -DefaultStep 'crash' -ErrorText $_.Exception.Message
        }
        exit 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main -ScriptArgs $args
}
