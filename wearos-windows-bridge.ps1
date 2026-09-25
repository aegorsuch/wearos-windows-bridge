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

function Get-AdbExecutable {
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    foreach ($segment in ($env:PATH -split ';')) {
        $candidate = Join-Path $segment 'adb.exe'
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-ScrcpyExecutable {
    $cmd = Get-Command scrcpy.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    foreach ($segment in ($env:PATH -split ';')) {
        $candidate = Join-Path $segment 'scrcpy.exe'
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Ensure-PathConfiguredMarker {
    $folder = $env:SCRCPY_PATH
    if ([string]::IsNullOrWhiteSpace($folder)) {
        return
    }

    Set-Content -Path $PathConfiguredPath -Value 'configured' -Encoding ASCII
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
    Ensure-PathConfiguredMarker
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
    & $Adb kill-server *> $null 2>&1

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
    & $Adb start-server *> $null 2>&1
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

        try {
            $raw = & $Adb connect "${Ip}:$Port" 2>&1 | Out-String
        }
        catch {
            # Check the device list anyway: ADB can connect successfully while emitting daemon startup text on stderr.
            $raw = $_.Exception.Message
        }

        $state = Get-DeviceStateByTarget -Ip $Ip -Port $Port
        if ($state -match 'device|unauthorized') {
            Save-IpCache -Ip $Ip -PairPort (Load-IpCache).pairPort -ConnPort $Port
            Save-CurrentProfileFromState -Ip $Ip -PairPort (Load-IpCache).pairPort -ConnPort $Port
            return $true
        }

        if ($attempt -lt $Retries) {
            Start-Sleep -Seconds 2
        }
    }

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
        throw "Unable to connect to $($cache.ip):$($cache.connPort) before mirroring."
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
        throw "Unable to connect to $($cache.ip):$($cache.connPort) before installing."
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

    $lineSource = & $Adb -s "$($cache.ip):$($cache.connPort)" logcat -v time 2>$null
    if ([string]::IsNullOrWhiteSpace($Keyword)) {
        $lineSource | ForEach-Object { $_ | Out-File -FilePath $fullPath -Append -Encoding UTF8 }
    }
    else {
        $lineSource | Where-Object { $_ -match [regex]::Escape($Keyword) } | ForEach-Object { $_ | Out-File -FilePath $fullPath -Append -Encoding UTF8 }
    }

    $endStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $finalName = [string]::Format('{0}_{1}_watch_log_{2}_{3}_{4}.txt', $cache.ip, $cache.connPort, $tag, $startStamp, $endStamp)
    $finalPath = Join-Path $LogsDir $finalName
    Move-Item -Path $fullPath -Destination $finalPath -Force
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

    $raw = & $Adb pair "${Ip}:$PairPort" $PairCode 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-UiLine $raw -Color Red
        Recover-Adb -Reason 'pairing failed'
        return $false
    }

    Save-IpCache -Ip $Ip -PairPort $PairPort -ConnPort $ConnectionPort
    Save-CurrentProfileFromState -Ip $Ip -PairPort $PairPort -ConnPort $ConnectionPort
    return $true
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
    Write-Host '  6. Back to main menu'
    Write-Host '===================================================' -ForegroundColor DarkGreen

    $choice = Read-Host 'Select an option (1-6)'
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
    Write-Host '===================================================' -ForegroundColor DarkGreen
    $choice = Read-Host 'Select an option (1-7)'

    switch ($choice) {
        '1' {
            $folder = Read-Host 'Drag and drop or enter full path to scrcpy folder'
            if ([string]::IsNullOrWhiteSpace($folder)) { return }
            try {
                Set-ScrcpyPathFromFolder -Folder $folder
            }
            catch {
                Write-UiLine $_.Exception.Message -Color Red
            }
            Show-Menu
        }
        '2' {
            $ip = Read-Host 'Enter Watch IP Address'
            $pairPort = Read-Host 'Enter Pairing Port'
            $pairCode = Read-Host 'Enter 6-digit Pairing Code'
            if ($ip -and $pairPort -and $pairCode) {
                $ok = Invoke-PairWatch -Ip $ip -PairPort $pairPort -PairCode $pairCode
                if ($ok) { Write-UiLine 'Pairing succeeded.' -Color Green } else { Write-UiLine 'Pairing failed.' -Color Red }
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
            $apk = Read-Host 'Enter APK path'
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
        default {
            Show-Menu
        }
    }
}

function Main {
    param([string[]]$ScriptArgs = @())

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

Main -ScriptArgs $args
