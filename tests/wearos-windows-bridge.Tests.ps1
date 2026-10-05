BeforeAll {
    . (Join-Path $PSScriptRoot '..\wearos-windows-bridge.ps1')
}

Describe 'Get-PairInputError' {
    It 'accepts valid pairing values' {
        Get-PairInputError -Ip '192.168.1.33' -PairPort '41131' -PairCode '952775' | Should -BeNullOrEmpty
    }

    It 'rejects an IP address that includes a port' {
        Get-PairInputError -Ip '192.168.1.33:41131' -PairPort '41131' -PairCode '952775' | Should -Match 'IP address only'
    }

    It 'rejects pairing ports outside the valid range' {
        Get-PairInputError -Ip '192.168.1.33' -PairPort '65536' -PairCode '952775' | Should -Match 'pairing port'
    }

    It 'rejects pairing codes that are not six digits' {
        Get-PairInputError -Ip '192.168.1.33' -PairPort '41131' -PairCode '95277x' | Should -Match 'six-digit'
    }
}

Describe 'Set-ScrcpyPathFromFolder' {
    It 'accepts a quoted folder path with scrcpy and adb' {
        $folder = Join-Path $TestDrive 'scrcpy package'
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $folder 'scrcpy.exe') -ItemType File | Out-Null
        New-Item -Path (Join-Path $folder 'adb.exe') -ItemType File | Out-Null
        Mock Ensure-PathConfiguredMarker {}

        $originalPath = $env:PATH
        $originalScrcpyPath = $env:SCRCPY_PATH
        $hadScrcpyPath = Test-Path Env:SCRCPY_PATH

        try {
            $result = Set-ScrcpyPathFromFolder -Folder ('"{0}"' -f $folder)

            $result | Should -Be $folder
            $env:SCRCPY_PATH | Should -Be $folder
        }
        finally {
            $env:PATH = $originalPath
            if ($hadScrcpyPath) {
                $env:SCRCPY_PATH = $originalScrcpyPath
            }
            else {
                Remove-Item Env:SCRCPY_PATH -ErrorAction SilentlyContinue
            }
        }
    }

    It 'rejects a folder missing either executable' {
        $folder = Join-Path $TestDrive 'incomplete scrcpy package'
        New-Item -Path $folder -ItemType Directory -Force | Out-Null

        { Set-ScrcpyPathFromFolder -Folder $folder } | Should -Throw '*does not contain both scrcpy.exe and adb.exe*'
    }
}

Describe 'New-DiagnosticBundle' {
    BeforeEach {
        $script:LogsDir = Join-Path $TestDrive 'watch_logs'
        Mock Get-StatusJson {
            [pscustomobject]@{
                activeProfile = 'ODIN-WEARTAK'
                saved = [pscustomobject]@{ ip = '192.168.1.33'; pairPort = '41131'; connPort = '5555' }
                profiles = @([pscustomobject]@{ name = 'ODIN-WEARTAK'; ip = '192.168.1.33' })
                deviceSummary = @([pscustomobject]@{ serial = '192.168.1.33:5555'; state = 'device' })
            }
        }
        Mock Get-AdbExecutable { $null }
        Mock Get-ScrcpyExecutable { $null }
    }

    It 'redacts identifiers in status and opted-in logs' {
        New-Item -Path $script:LogsDir -ItemType Directory -Force | Out-Null
        $logPath = Join-Path $script:LogsDir '192.168.1.33_5555_watch_log_none_20261003-120000_20261003-120100.txt'
        Set-Content -Path $logPath -Value 'watch 192.168.1.33:5555 serial=DEVICE123' -Encoding UTF8
        $outputDirectory = Join-Path $TestDrive 'bundles'

        $bundle = New-DiagnosticBundle -IncludeLogs -RedactIdentifiers $true -LogFiles @((Get-Item $logPath)) -OutputDirectory $outputDirectory
        $extractDirectory = Join-Path $TestDrive 'expanded-redacted'
        Expand-Archive -Path $bundle -DestinationPath $extractDirectory
        $diagnostics = Get-Content -Path (Join-Path $extractDirectory 'diagnostics.json') -Raw | ConvertFrom-Json
        $log = Get-Content -Path (Join-Path $extractDirectory 'watch_logs\watch-log-01.txt') -Raw

        $diagnostics.bridgeStatus.saved.ip | Should -Be '[REDACTED]'
        $diagnostics.bridgeStatus.profiles[0].name | Should -Be '[REDACTED]'
        $diagnostics.bridgeStatus.deviceSummary[0].serial | Should -Be '[REDACTED]'
        $log | Should -Not -Match '192\.168\.1\.33|DEVICE123'

        $manifest = Get-Content -Path (Join-Path $extractDirectory 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.uploadPerformed | Should -BeFalse
    }

    It 'omits watch logs unless explicitly requested' {
        $outputDirectory = Join-Path $TestDrive 'bundles-without-logs'

        $bundle = New-DiagnosticBundle -OutputDirectory $outputDirectory
        $extractDirectory = Join-Path $TestDrive 'expanded-no-logs'
        Expand-Archive -Path $bundle -DestinationPath $extractDirectory
        $manifest = Get-Content -Path (Join-Path $extractDirectory 'manifest.json') -Raw | ConvertFrom-Json

        $manifest.logsIncluded | Should -BeNullOrEmpty
        Test-Path (Join-Path $extractDirectory 'watch_logs') | Should -BeFalse
    }
}