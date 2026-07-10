#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'Invoke-BraveDebloat.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('BraveDebloaterBehavior-{0}' -f [guid]::NewGuid().ToString('N'))

function Assert-TextContains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not $Text.Contains($Expected)) {
        throw "$Context did not contain expected text: $Expected"
    }
}

function Assert-TextDoesNotContain {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Unexpected,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Text.Contains($Unexpected)) {
        throw "$Context contained unexpected text: $Unexpected"
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $missingProfileRoot = Join-Path $tempRoot 'MissingProfileRoot'
    $listOutput = (& $scriptPath -Preset Core -List -IncludeProfilePreferences -ProfileRoot $missingProfileRoot *>&1 | Out-String)
    Assert-TextContains -Text $listOutput -Expected 'Profile preference patches' -Context '-List output'
    Assert-TextContains -Text $listOutput -Expected 'brave.new_tab_page.show_branded_background_image' -Context '-List output'
    Assert-TextDoesNotContain -Text $listOutput -Unexpected '[dry-run]' -Context '-List output'

    $featureOutput = (& $scriptPath -Preset Extreme -ListFeatures *>&1 | Out-String)
    Assert-TextContains -Text $featureOutput -Expected 'LeoAI' -Context '-ListFeatures output'
    Assert-TextContains -Text $featureOutput -Expected 'Brave Rewards' -Context '-ListFeatures output'

    $doctorBackupDirectory = Join-Path $tempRoot 'DoctorBackups'
    New-Item -ItemType Directory -Path $doctorBackupDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $doctorBackupDirectory 'BraveDebloater-20260101-010101-001.json') -Value '{}' -Encoding UTF8

    $doctorOutput = (& $scriptPath -Doctor -ProfileRoot $missingProfileRoot -BackupDirectory $doctorBackupDirectory *>&1 | Out-String)
    Assert-TextContains -Text $doctorOutput -Expected 'Doctor report (read-only)' -Context '-Doctor output'
    Assert-TextContains -Text $doctorOutput -Expected 'LocalMachine policies' -Context '-Doctor output'
    # Linux exposes a single machine-wide managed policy file, so both scopes resolve to the
    # same path and the report lists it once. Platforms with a distinct user scope still show both.
    $isLinuxPlatform = $false
    $isLinuxVariable = Get-Variable -Name IsLinux -Scope Global -ErrorAction SilentlyContinue
    if ($isLinuxVariable -and $isLinuxVariable.Value) {
        $isLinuxPlatform = $true
    }
    if (-not $isLinuxPlatform) {
        Assert-TextContains -Text $doctorOutput -Expected 'CurrentUser policies' -Context '-Doctor output'
    }
    Assert-TextContains -Text $doctorOutput -Expected 'Feature status' -Context '-Doctor output'
    Assert-TextContains -Text $doctorOutput -Expected 'Backups: 1 found' -Context '-Doctor output'
    Assert-TextContains -Text $doctorOutput -Expected 'Profile root: missing' -Context '-Doctor output'
    Assert-TextDoesNotContain -Text $doctorOutput -Unexpected '[dry-run]' -Context '-Doctor output'
    Assert-TextDoesNotContain -Text $doctorOutput -Unexpected 'Would set' -Context '-Doctor output'

    $doctorApplyBackupDirectory = Join-Path $tempRoot 'DoctorApplyBackups'
    $doctorApplyOutput = (& $scriptPath -Doctor -Apply -ProfileRoot $missingProfileRoot -BackupDirectory $doctorApplyBackupDirectory *>&1 | Out-String)
    Assert-TextContains -Text $doctorApplyOutput -Expected '-Doctor is read-only. -Apply was ignored. No policy, backup, or profile files will be changed.' -Context '-Doctor -Apply output'
    Assert-TextContains -Text $doctorApplyOutput -Expected 'Doctor report (read-only)' -Context '-Doctor -Apply output'
    Assert-TextDoesNotContain -Text $doctorApplyOutput -Unexpected 'Backup written' -Context '-Doctor -Apply output'
    Assert-TextDoesNotContain -Text $doctorApplyOutput -Unexpected 'Would set' -Context '-Doctor -Apply output'
    if (Test-Path -LiteralPath $doctorApplyBackupDirectory) {
        throw '-Doctor -Apply created a backup directory.'
    }

    $excludeOutput = (& $scriptPath -Preset Extreme -ExcludeFeature News,LeoAI -List *>&1 | Out-String)
    Assert-TextContains -Text $excludeOutput -Expected 'BraveRewardsDisabled' -Context '-ExcludeFeature output'
    Assert-TextDoesNotContain -Text $excludeOutput -Unexpected 'BraveNewsDisabled' -Context '-ExcludeFeature output'
    Assert-TextDoesNotContain -Text $excludeOutput -Unexpected 'BraveAIChatEnabled' -Context '-ExcludeFeature output'

    $includeOutput = (& $scriptPath -Preset Standard -IncludeFeature Translate -List *>&1 | Out-String)
    Assert-TextContains -Text $includeOutput -Expected 'TranslateEnabled' -Context '-IncludeFeature output'

    $onlyOutput = (& $scriptPath -OnlyFeature Rewards,Wallet -List *>&1 | Out-String)
    Assert-TextContains -Text $onlyOutput -Expected 'BraveRewardsDisabled' -Context '-OnlyFeature output'
    Assert-TextContains -Text $onlyOutput -Expected 'BraveWalletDisabled' -Context '-OnlyFeature output'
    Assert-TextDoesNotContain -Text $onlyOutput -Unexpected 'BraveVPNDisabled' -Context '-OnlyFeature output'
    Assert-TextDoesNotContain -Text $onlyOutput -Unexpected 'BraveAIChatEnabled' -Context '-OnlyFeature output'

    $onlyPatchOutput = (& $scriptPath -OnlyFeature Rewards -List -IncludeProfilePreferences *>&1 | Out-String)
    Assert-TextContains -Text $onlyPatchOutput -Expected 'brave.rewards.enabled' -Context '-OnlyFeature profile patch output'
    Assert-TextDoesNotContain -Text $onlyPatchOutput -Unexpected 'brave.new_tab_page.show_branded_background_image' -Context '-OnlyFeature profile patch output'
    Assert-TextDoesNotContain -Text $onlyPatchOutput -Unexpected 'brave.wallet.show_wallet_icon_on_toolbar' -Context '-OnlyFeature profile patch output'

    $onlyDryRunOutput = (& $scriptPath -OnlyFeature Rewards *>&1 | Out-String)
    Assert-TextContains -Text $onlyDryRunOutput -Expected 'Preset: (none - OnlyFeature mode)' -Context '-OnlyFeature dry-run output'
    Assert-TextContains -Text $onlyDryRunOutput -Expected 'Custom features: Rewards' -Context '-OnlyFeature dry-run output'
    Assert-TextDoesNotContain -Text $onlyDryRunOutput -Unexpected 'Preset: Extreme' -Context '-OnlyFeature dry-run output'

    $blankOnlyFeatureFailed = $false
    try {
        & $scriptPath -OnlyFeature ' ' | Out-Null
    }
    catch {
        $blankOnlyFeatureFailed = $_.Exception.Message -match 'Specified -OnlyFeature contains only blank entries'
    }
    if (-not $blankOnlyFeatureFailed) {
        throw '-OnlyFeature did not reject blank-only input.'
    }

    $onlyConflictCommands = @(
        { & $scriptPath -OnlyFeature Rewards -ExcludeFeature Wallet -List | Out-Null },
        { & $scriptPath -OnlyFeature Rewards -IncludeFeature Wallet -List | Out-Null },
        { & $scriptPath -OnlyFeature Rewards -Customize -List | Out-Null }
    )
    foreach ($command in $onlyConflictCommands) {
        $onlyConflictFailed = $false
        try {
            & $command
        }
        catch {
            $onlyConflictFailed = $_.Exception.Message -match 'OnlyFeature cannot be combined'
        }
        if (-not $onlyConflictFailed) {
            throw '-OnlyFeature did not reject a conflicting custom feature switch.'
        }
    }

    $filteredPatchOutput = (& $scriptPath -Preset Extreme -ExcludeFeature News,Rewards,Wallet -List -IncludeProfilePreferences *>&1 | Out-String)
    Assert-TextContains -Text $filteredPatchOutput -Expected 'brave.new_tab_page.show_branded_background_image' -Context 'filtered profile patch output'
    Assert-TextDoesNotContain -Text $filteredPatchOutput -Unexpected 'brave.today.should_show_toolbar_button' -Context 'filtered profile patch output'
    Assert-TextDoesNotContain -Text $filteredPatchOutput -Unexpected 'brave.rewards.enabled' -Context 'filtered profile patch output'
    Assert-TextDoesNotContain -Text $filteredPatchOutput -Unexpected 'brave.wallet.show_wallet_icon_on_toolbar' -Context 'filtered profile patch output'

    $whatIfBackupDirectory = Join-Path $tempRoot 'WhatIfBackups'
    $whatIfOutput = (& $scriptPath -Preset Core -Apply -WhatIf -BackupDirectory $whatIfBackupDirectory *>&1 | Out-String)
    Assert-TextContains -Text $whatIfOutput -Expected 'WhatIf mode. No policy, backup, or profile files will be changed.' -Context '-WhatIf output'
    Assert-TextDoesNotContain -Text $whatIfOutput -Unexpected 'Backup written' -Context '-WhatIf output'
    Assert-TextDoesNotContain -Text $whatIfOutput -Unexpected 'Done. Restart Brave' -Context '-WhatIf output'
    if (Test-Path -LiteralPath $whatIfBackupDirectory) {
        throw '-WhatIf created a backup directory.'
    }

    $channelOutput = (& $scriptPath -Preset Core -Channel Beta -ProfileRoot '' *>&1 | Out-String)
    Assert-TextContains -Text $channelOutput -Expected 'Channel: Beta' -Context '-Channel Beta output'

    $retentionDirectory = Join-Path $tempRoot 'RetentionBackups'
    New-Item -ItemType Directory -Path $retentionDirectory -Force | Out-Null
    $oldBackup = Join-Path $retentionDirectory 'BraveDebloater-20240101-010101-001.json'
    $newBackup = Join-Path $retentionDirectory 'BraveDebloater-20260101-010101-001.json'
    Set-Content -LiteralPath $oldBackup -Value '{}' -Encoding UTF8
    Set-Content -LiteralPath $newBackup -Value '{}' -Encoding UTF8
    (Get-Item -LiteralPath $oldBackup).LastWriteTime = (Get-Date).AddDays(-60)
    (Get-Item -LiteralPath $newBackup).LastWriteTime = Get-Date

    $listBackupsOutput = (& $scriptPath -BackupDirectory $retentionDirectory -ListBackups *>&1 | Out-String)
    Assert-TextContains -Text $listBackupsOutput -Expected 'Backups: 2 found' -Context '-ListBackups output'
    Assert-TextDoesNotContain -Text $listBackupsOutput -Unexpected 'Backup cleanup: nothing to remove.' -Context '-ListBackups output'

    $retentionPreview = (& $scriptPath -BackupDirectory $retentionDirectory -PruneBackupsOlderThanDays 30 *>&1 | Out-String)
    Assert-TextContains -Text $retentionPreview -Expected 'Would remove backup BraveDebloater-20240101-010101-001.json' -Context 'backup retention preview'
    if (-not (Test-Path -LiteralPath $oldBackup)) {
        throw 'Backup retention preview deleted a backup.'
    }

    $retentionApply = (& $scriptPath -BackupDirectory $retentionDirectory -KeepLatestBackups 1 -Apply *>&1 | Out-String)
    Assert-TextContains -Text $retentionApply -Expected 'Removed backup BraveDebloater-20240101-010101-001.json.' -Context 'backup retention apply'
    if (Test-Path -LiteralPath $oldBackup) {
        throw 'Backup retention apply did not remove the old backup.'
    }

    $tamperedBackup = Join-Path $tempRoot 'tampered-backup.json'
    [ordered]@{
        schemaVersion = 1
        registryPath = 'Registry::HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows'
        policies = @()
        profileFiles = @()
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tamperedBackup -Encoding UTF8

    $failedAsExpected = $false
    try {
        & $scriptPath -UndoFromBackup $tamperedBackup | Out-Null
    }
    catch {
        $failedAsExpected = $_.Exception.Message -match 'untrusted registry path'
    }
    if (-not $failedAsExpected) {
        throw 'Tampered backup did not fail with the expected restore validation error.'
    }

    $validBackup = Join-Path $tempRoot 'valid-backup.json'
    [ordered]@{
        schemaVersion = 1
        registryPath = 'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave'
        policies = @(
            [ordered]@{
                name = 'BraveRewardsDisabled'
                existed = $false
                value = $null
                kind = $null
            }
        )
        profileFiles = @()
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $validBackup -Encoding UTF8

    $restoreOutput = (& $scriptPath -UndoFromBackup $validBackup *>&1 | Out-String)
    Assert-TextContains -Text $restoreOutput -Expected 'Would remove BraveRewardsDisabled' -Context 'restore dry-run output'

    $mixedProfileRoot = Join-Path $tempRoot 'MixedProfileRoot'
    $invalidProfileDirectory = Join-Path $mixedProfileRoot 'Default'
    $emptyProfileDirectory = Join-Path $mixedProfileRoot 'Profile 1'
    $validProfileDirectory = Join-Path $mixedProfileRoot 'Profile 2'
    New-Item -ItemType Directory -Path $invalidProfileDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $emptyProfileDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $validProfileDirectory -Force | Out-Null
    $invalidPreferences = Join-Path $invalidProfileDirectory 'Preferences'
    $emptyPreferences = Join-Path $emptyProfileDirectory 'Preferences'
    $validPreferences = Join-Path $validProfileDirectory 'Preferences'
    Set-Content -LiteralPath $invalidPreferences -Value '{ this is not valid json' -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath $emptyPreferences -Value '' -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath $validPreferences -Value '{}' -Encoding UTF8 -NoNewline

    $invalidJsonOutput = (& $scriptPath -Preset Core -IncludeProfilePreferences -ProfileRoot $mixedProfileRoot *>&1 | Out-String)
    $skipCount = ([regex]::Matches($invalidJsonOutput, 'Skipping invalid profile Preferences file')).Count
    if ($skipCount -ne 2) {
        throw "Expected 2 skipped profile Preferences files, found $skipCount."
    }
    Assert-TextContains -Text $invalidJsonOutput -Expected 'Would create brave.new_tab_page.show_branded_background_image' -Context 'valid Preferences dry-run output'
    Assert-TextContains -Text $invalidJsonOutput -Expected 'Dry-run complete.' -Context 'invalid Preferences dry-run output'

    $invalidJsonContentBefore = Get-Content -LiteralPath $invalidPreferences -Raw
    if ($invalidJsonContentBefore -ne '{ this is not valid json') {
        throw 'Dry-run modified an invalid profile Preferences file.'
    }

    $linuxPolicyPath = Join-Path $tempRoot 'BraveDebloater-linux-policy.json'
    $linuxBackupDirectory = Join-Path $tempRoot 'LinuxBackups'
    $linuxApplyOutput = (& $scriptPath -Platform Linux -PolicyPath $linuxPolicyPath -OnlyFeature Rewards -Apply -BackupDirectory $linuxBackupDirectory *>&1 | Out-String)
    Assert-TextContains -Text $linuxApplyOutput -Expected 'Platform: Linux' -Context 'Linux policy apply output'
    Assert-TextContains -Text $linuxApplyOutput -Expected 'Backup written' -Context 'Linux policy apply output'
    Assert-TextContains -Text $linuxApplyOutput -Expected 'Set BraveRewardsDisabled.' -Context 'Linux policy apply output'
    if (-not (Test-Path -LiteralPath $linuxPolicyPath)) {
        throw 'Linux policy apply did not create the policy JSON file.'
    }
    if (@(Get-ChildItem -LiteralPath $linuxBackupDirectory -Filter 'BraveDebloater-*.json').Count -ne 1) {
        throw 'Linux policy apply did not create exactly one backup.'
    }
    $linuxPolicyJson = Get-Content -LiteralPath $linuxPolicyPath -Raw | ConvertFrom-Json
    if ($linuxPolicyJson.BraveRewardsDisabled -isnot [bool] -or -not $linuxPolicyJson.BraveRewardsDisabled) {
        throw 'Linux policy apply did not write BraveRewardsDisabled = true.'
    }

    $customLinuxBackup = Join-Path $tempRoot 'custom-linux-backup.json'
    [ordered]@{
        schemaVersion = 1
        platform = 'Linux'
        policyKind = 'JsonFile'
        registryPath = $linuxPolicyPath
        policies = @(
            [ordered]@{
                name = 'BraveRewardsDisabled'
                existed = $false
                value = $null
                kind = $null
            }
        )
        profileFiles = @()
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $customLinuxBackup -Encoding UTF8

    $customRestoreRejected = $false
    try {
        & $scriptPath -UndoFromBackup $customLinuxBackup | Out-Null
    }
    catch {
        $customRestoreRejected = $_.Exception.Message -match 'untrusted registry path'
    }
    if (-not $customRestoreRejected) {
        throw 'Custom Linux backup restore did not require the matching -PolicyPath.'
    }

    $customRestoreOutput = (& $scriptPath -UndoFromBackup $customLinuxBackup -PolicyPath $linuxPolicyPath *>&1 | Out-String)
    Assert-TextContains -Text $customRestoreOutput -Expected 'Would remove BraveRewardsDisabled' -Context 'custom Linux restore dry-run output'

    $androidDryRunOutput = (& $scriptPath -Platform Android -OnlyFeature Rewards *>&1 | Out-String)
    Assert-TextContains -Text $androidDryRunOutput -Expected 'Platform: Android' -Context 'Android dry-run output'
    Assert-TextContains -Text $androidDryRunOutput -Expected 'MDM profile' -Context 'Android dry-run output'
    Assert-TextContains -Text $androidDryRunOutput -Expected 'Would set BraveRewardsDisabled' -Context 'Android dry-run output'

    $androidPolicyPath = Join-Path $tempRoot 'brave-android-mdm.json'
    $androidExportOutput = (& $scriptPath -Platform Android -OnlyFeature Rewards -ExportPolicyPath $androidPolicyPath *>&1 | Out-String)
    Assert-TextContains -Text $androidExportOutput -Expected 'Exported 1 policy value(s) for Android' -Context 'Android export output'
    $androidPolicyJson = Get-Content -LiteralPath $androidPolicyPath -Raw | ConvertFrom-Json
    if ($androidPolicyJson.BraveRewardsDisabled -isnot [bool] -or -not $androidPolicyJson.BraveRewardsDisabled) {
        throw 'Android policy export did not write BraveRewardsDisabled = true.'
    }

    $iosPolicyPath = Join-Path $tempRoot 'brave-ios.mobileconfig'
    $iosExportOutput = (& $scriptPath -Platform iOS -OnlyFeature Rewards -ExportPolicyPath $iosPolicyPath *>&1 | Out-String)
    Assert-TextContains -Text $iosExportOutput -Expected 'Exported 1 policy value(s) for iOS' -Context 'iOS export output'
    $iosMobileConfig = Get-Content -LiteralPath $iosPolicyPath -Raw
    Assert-TextContains -Text $iosMobileConfig -Expected 'com.apple.ManagedClient.preferences' -Context 'iOS mobileconfig'
    Assert-TextContains -Text $iosMobileConfig -Expected 'BraveRewardsDisabled' -Context 'iOS mobileconfig'
    Assert-TextContains -Text $iosMobileConfig -Expected '<true/>' -Context 'iOS mobileconfig'

    $iosUnsupportedFailed = $false
    try {
        & $scriptPath -Platform iOS -Preset Extreme -ExportPolicyPath (Join-Path $tempRoot 'unsupported.mobileconfig') | Out-Null
    }
    catch {
        $iosUnsupportedFailed = $_.Exception.Message -match 'unsupported selected policies'
    }
    if (-not $iosUnsupportedFailed) {
        throw 'iOS export did not reject unsupported policies.'
    }

    $iosDryRunRejected = $false
    try {
        & $scriptPath -Platform iOS -Preset Extreme | Out-Null
    }
    catch {
        $iosDryRunRejected = $_.Exception.Message -match 'unsupported selected policies'
    }
    if (-not $iosDryRunRejected) {
        throw 'iOS dry-run did not reject unsupported policies.'
    }

    $iosSupportedDryRun = (& $scriptPath -Platform iOS -OnlyFeature Rewards *>&1 | Out-String)
    Assert-TextContains -Text $iosSupportedDryRun -Expected 'Would set BraveRewardsDisabled' -Context 'iOS supported dry-run output'

    Write-Host 'Behavior checks passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
