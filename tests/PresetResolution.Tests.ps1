#requires -Version 5.1

Describe 'Preset resolution' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        . (Join-Path $root 'src/Common.ps1')
        . (Join-Path $root 'src/Manifest.ps1')

        $manifest = Get-Content -LiteralPath (Join-Path (Join-Path $root 'config') 'policies.json') -Raw | ConvertFrom-Json
        $presets = Get-ManifestMap -Object $manifest.presets
    }

    It 'resolves preset aliases to the same policies' {
        (Resolve-PresetPolicies -Name 'Standard' -Presets $presets) -join ',' | Should -Be ((Resolve-PresetPolicies -Name 'Core' -Presets $presets) -join ',')
        (Resolve-PresetPolicies -Name 'High' -Presets $presets) -join ',' | Should -Be ((Resolve-PresetPolicies -Name 'Privacy' -Presets $presets) -join ',')
        (Resolve-PresetPolicies -Name 'Extreme' -Presets $presets) -join ',' | Should -Be ((Resolve-PresetPolicies -Name 'Aggressive' -Presets $presets) -join ',')
    }

    It 'rejects unknown presets clearly' {
        { Resolve-PresetPolicies -Name 'Missing' -Presets $presets } | Should -Throw "Unknown preset 'Missing'."
    }

    It 'rejects preset cycles' {
        $cycle = @{
            A = @('@B')
            B = @('@A')
        }

        { Resolve-PresetPolicies -Name 'A' -Presets $cycle } | Should -Throw "Preset cycle detected at 'A'."
    }
}

Describe 'Brave process detection' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        . (Join-Path $root 'src/Common.ps1')
    }

    It 'detects the macOS process name as well as brave' {
        Mock Get-Process {
            if ($Name -contains 'Brave Browser*') {
                return [pscustomobject]@{ ProcessName = 'Brave Browser' }
            }
        }

        Test-BraveRunning | Should -BeTrue
    }

    It 'reports not running when no Brave process exists' {
        Mock Get-Process { }

        Test-BraveRunning | Should -BeFalse
    }
}

Describe 'Brave profile in use' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        . (Join-Path $root 'src/Common.ps1')
        . (Join-Path $root 'src/PlatformPolicy.ps1')
        $profileRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('BraveDebloaterProfileInUse-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null
    }

    AfterAll {
        Remove-Item -LiteralPath $profileRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'allows a folder Brave does not use while Brave runs' {
        Mock Test-BraveRunning { $true }
        Mock Get-DefaultProfileRoot { '' }

        Test-BraveUsingProfileRoot -Root $profileRoot | Should -BeFalse
    }

    It 'blocks a folder that holds the <Lock> lock on <Platform> only' -TestCases @(
        @{ Lock = 'SingletonLock'; Platform = 'Linux'; Blocked = $true }, @{ Lock = 'SingletonLock'; Platform = 'macOS'; Blocked = $true }, @{ Lock = 'SingletonLock'; Platform = 'Windows'; Blocked = $false },
        @{ Lock = 'lockfile'; Platform = 'Windows'; Blocked = $true }, @{ Lock = 'lockfile'; Platform = 'Linux'; Blocked = $false },
        @{ Lock = 'singletonlock'; Platform = 'Linux'; Blocked = $false }, @{ Lock = 'LOCKFILE'; Platform = 'Windows'; Blocked = $true }
    ) {
        Mock Test-BraveRunning { $true }
        Mock Get-DefaultProfileRoot { '' }
        Mock Resolve-PlatformName { $Platform }
        $lockPath = Join-Path $profileRoot $Lock
        New-Item -ItemType File -Path $lockPath -Force | Out-Null
        try {
            Test-BraveUsingProfileRoot -Root $profileRoot | Should -Be $Blocked
        }
        finally {
            Remove-Item -LiteralPath $lockPath -Force
        }
    }

    It 'allows a folder that does not exist' {
        Mock Test-BraveRunning { $true }
        Mock Get-DefaultProfileRoot { '' }

        Test-BraveUsingProfileRoot -Root (Join-Path $profileRoot 'missing') | Should -BeFalse
    }

    It 'finds the lock of a relative folder after Set-Location' {
        Mock Test-BraveRunning { $true }
        Mock Get-DefaultProfileRoot { '' }
        Mock Resolve-PlatformName { 'Linux' }
        $active = Join-Path $profileRoot 'active'
        $offline = Join-Path $profileRoot 'offline'
        foreach ($folder in @($active, $offline)) {
            New-Item -ItemType Directory -Path (Join-Path $folder 'UserData') -Force | Out-Null
        }
        New-Item -ItemType File -Path (Join-Path $active 'UserData/SingletonLock') | Out-Null
        $processDirectory = [Environment]::CurrentDirectory
        Push-Location -LiteralPath $active
        try {
            [Environment]::CurrentDirectory = $offline
            Test-BraveUsingProfileRoot -Root './UserData' | Should -BeTrue
        }
        finally {
            [Environment]::CurrentDirectory = $processDirectory
            Pop-Location
        }
    }

    It 'compares the default folder by the case rules of <Platform>' -TestCases @(@{ Platform = 'Linux'; Blocked = $false }, @{ Platform = 'macOS'; Blocked = $true }, @{ Platform = 'Windows'; Blocked = $true }) {
        Mock Test-BraveRunning { $true }
        Mock Resolve-PlatformName { $Platform }
        Mock Get-DefaultProfileRoot { $profileRoot.ToUpperInvariant() }
        Mock Resolve-FileSystemLinkPath { $Path }

        Test-BraveUsingProfileRoot -Root $profileRoot | Should -Be $Blocked
    }

    It 'blocks a default Brave profile folder' {
        Mock Test-BraveRunning { $true }
        Mock Get-DefaultProfileRoot { $profileRoot }

        Test-BraveUsingProfileRoot -Root $profileRoot | Should -BeTrue
    }

    It 'allows the default folder when Brave is not running' {
        Mock Test-BraveRunning { $false }
        Mock Get-DefaultProfileRoot { $profileRoot }

        Test-BraveUsingProfileRoot -Root $profileRoot | Should -BeFalse
    }
}

Describe 'Restore safety' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        . (Join-Path $root 'src/Common.ps1')
        . (Join-Path $root 'src/Manifest.ps1')
        . (Join-Path $root 'src/PlatformPolicy.ps1')
        . (Join-Path $root 'src/Backup.ps1')
        $manifest = Get-Content -LiteralPath (Join-Path (Join-Path $root 'config') 'policies.json') -Raw | ConvertFrom-Json
    }

    It 'refuses to restore profile files while Brave is using the profile, with -ProfileRoot <RootName>' -TestCases @(@{ RootName = 'UserData' }, @{ RootName = '.' }) {
        $directory = Join-Path ([System.IO.Path]::GetTempPath()) ('BraveDebloaterPester-{0}' -f [guid]::NewGuid().ToString('N'))
        $profileRoot = Join-Path $directory 'UserData'
        $profileDirectory = Join-Path $profileRoot 'Default'
        $profileBackupDirectory = Join-Path $directory 'profile-files'
        New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
        New-Item -ItemType Directory -Path $profileBackupDirectory -Force | Out-Null
        try {
            $preferences = Join-Path $profileDirectory 'Preferences'
            $preferencesBackup = Join-Path $profileBackupDirectory 'Preferences.bak'
            Set-Content -LiteralPath $preferences -Value '{"changed":true}' -Encoding UTF8
            Set-Content -LiteralPath $preferencesBackup -Value '{"original":true}' -Encoding UTF8
            $policyPath = Join-Path $directory 'policy.json'
            Set-Content -LiteralPath $policyPath -Value '{"BraveRewardsDisabled":true}' -Encoding UTF8

            $backupPath = Join-Path $directory 'BraveDebloater-test.json'
            [ordered]@{
                schemaVersion = 1
                platform = 'Linux'
                policyKind = 'JsonFile'
                registryPath = $policyPath
                policies = @([ordered]@{ name = 'BraveRewardsDisabled'; existed = $false; value = $null; kind = $null })
                profileFiles = @([ordered]@{ originalPath = $preferences; backupPath = $preferencesBackup })
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $backupPath -Encoding UTF8

            New-Item -ItemType File -Path (Join-Path $profileRoot 'SingletonLock') -Force | Out-Null
            Mock Get-Process { return [pscustomobject]@{ ProcessName = 'brave' } }
            Mock Resolve-PlatformName { return 'Linux' }

            # '.' selects the folder above the one Brave locked; the restore must still see the lock.
            $selectedRoot = [System.IO.Path]::GetFullPath((Join-Path $directory $RootName))
            { Restore-RegistryBackup -BackupPath $backupPath -Manifest $manifest -ProfileRoot $selectedRoot -AllowedPolicyPath $policyPath -DoApply } | Should -Throw '*Brave is running*'

            (Get-Content -LiteralPath $preferences -Raw) | Should -BeLike '*"changed":true*'
            (Get-Content -LiteralPath $policyPath -Raw) | Should -BeLike '*BraveRewardsDisabled*'
        }
        finally {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Profile preference preview' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        . (Join-Path $root 'src/Common.ps1')
        . (Join-Path $root 'src/PlatformPolicy.ps1')
        . (Join-Path $root 'src/ProfilePreferences.ps1')
        $manifest = Get-Content -LiteralPath (Join-Path (Join-Path $root 'config') 'policies.json') -Raw | ConvertFrom-Json
    }

    It 'warns during a dry-run that apply will be skipped while Brave is running' {
        $directory = Join-Path ([System.IO.Path]::GetTempPath()) ('BraveDebloaterPester-{0}' -f [guid]::NewGuid().ToString('N'))
        $profileDirectory = Join-Path $directory 'Default'
        New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
        try {
            $preferences = Join-Path $profileDirectory 'Preferences'
            Set-Content -LiteralPath $preferences -Value '{"brave":{"rewards":{"enabled":true}}}' -Encoding UTF8

            New-Item -ItemType File -Path (Join-Path $directory 'SingletonLock') -Force | Out-Null
            Mock Get-Process { return [pscustomobject]@{ ProcessName = 'brave' } }
            Mock Resolve-PlatformName { return 'Linux' }
            Mock Write-Host {}

            Invoke-ProfilePreferenceCleanup -Root $directory -Manifest $manifest -BackupPath ''

            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*Brave is running. Close it before adding -Apply*' }
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*Would set brave.rewards.enabled*' }
            (Get-Content -LiteralPath $preferences -Raw) | Should -BeLike '*"enabled":true*'
        }
        finally {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Backup retention' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        . (Join-Path $root 'src/Common.ps1')
        . (Join-Path $root 'src/Manifest.ps1')
        . (Join-Path $root 'src/PlatformPolicy.ps1')
        . (Join-Path $root 'src/Backup.ps1')
        $manifest = Get-Content -LiteralPath (Join-Path (Join-Path $root 'config') 'policies.json') -Raw | ConvertFrom-Json
    }

    It 'keeps deleting backups after one removal fails' {
        $directory = Join-Path ([System.IO.Path]::GetTempPath()) ('BraveDebloaterPester-{0}' -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        try {
            foreach ($name in @('BraveDebloater-pass1.json', 'BraveDebloater-fail.json', 'BraveDebloater-pass2.json')) {
                Set-Content -LiteralPath (Join-Path $directory $name) -Value '{}' -Encoding UTF8
            }

            Mock Remove-Item {
                if ($LiteralPath -like '*fail.json') {
                    throw 'locked'
                }
            }
            Mock Write-Warning {}

            Invoke-BackupRetention -Directory $directory -Manifest $manifest -KeepLatest 0 -DoApply

            Should -Invoke Remove-Item -Times 3 -Exactly
            Should -Invoke Write-Warning -Times 1 -Exactly
        }
        finally {
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
