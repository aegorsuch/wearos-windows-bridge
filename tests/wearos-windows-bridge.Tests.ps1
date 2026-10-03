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