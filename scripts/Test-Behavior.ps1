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
    $listOutput = (& $scriptPath -Preset Core -List -IncludeProfilePreferences -ProfileRoot $missingProfileRoot *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $listOutput -Expected 'Profile preference patches' -Context '-List output'
    Assert-TextContains -Text $listOutput -Expected 'brave.new_tab_page.show_branded_background_image' -Context '-List output'
    Assert-TextDoesNotContain -Text $listOutput -Unexpected '[dry-run]' -Context '-List output'

    $featureOutput = (& $scriptPath -Preset Extreme -ListFeatures *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $featureOutput -Expected 'LeoAI' -Context '-ListFeatures output'
    Assert-TextContains -Text $featureOutput -Expected 'Brave Rewards' -Context '-ListFeatures output'

    $doctorBackupDirectory = Join-Path $tempRoot 'DoctorBackups'
    New-Item -ItemType Directory -Path $doctorBackupDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $doctorBackupDirectory 'BraveDebloater-20260101-010101-001.json') -Value '{}' -Encoding UTF8

    $doctorOutput = (& $scriptPath -Doctor -ProfileRoot $missingProfileRoot -BackupDirectory $doctorBackupDirectory *>&1 | Out-String -Width 4096)
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
    $doctorApplyOutput = (& $scriptPath -Doctor -Apply -ProfileRoot $missingProfileRoot -BackupDirectory $doctorApplyBackupDirectory *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $doctorApplyOutput -Expected '-Doctor is read-only. -Apply was ignored. No policy, backup, or profile files will be changed.' -Context '-Doctor -Apply output'
    Assert-TextContains -Text $doctorApplyOutput -Expected 'Doctor report (read-only)' -Context '-Doctor -Apply output'
    Assert-TextDoesNotContain -Text $doctorApplyOutput -Unexpected 'Backup written' -Context '-Doctor -Apply output'
    Assert-TextDoesNotContain -Text $doctorApplyOutput -Unexpected 'Would set' -Context '-Doctor -Apply output'
    if (Test-Path -LiteralPath $doctorApplyBackupDirectory) {
        throw '-Doctor -Apply created a backup directory.'
    }

    $excludeOutput = (& $scriptPath -Preset Extreme -ExcludeFeature News,LeoAI -List *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $excludeOutput -Expected 'BraveRewardsDisabled' -Context '-ExcludeFeature output'
    Assert-TextDoesNotContain -Text $excludeOutput -Unexpected 'BraveNewsDisabled' -Context '-ExcludeFeature output'
    Assert-TextDoesNotContain -Text $excludeOutput -Unexpected 'BraveAIChatEnabled' -Context '-ExcludeFeature output'

    $includeOutput = (& $scriptPath -Preset Standard -IncludeFeature Translate -List *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $includeOutput -Expected 'TranslateEnabled' -Context '-IncludeFeature output'

    $onlyOutput = (& $scriptPath -OnlyFeature Rewards,Wallet -List *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $onlyOutput -Expected 'BraveRewardsDisabled' -Context '-OnlyFeature output'
    Assert-TextContains -Text $onlyOutput -Expected 'BraveWalletDisabled' -Context '-OnlyFeature output'
    Assert-TextDoesNotContain -Text $onlyOutput -Unexpected 'BraveVPNDisabled' -Context '-OnlyFeature output'
    Assert-TextDoesNotContain -Text $onlyOutput -Unexpected 'BraveAIChatEnabled' -Context '-OnlyFeature output'

    $extremeListOutput = (& $scriptPath -Preset Extreme -List *>&1 | Out-String -Width 4096)
    Assert-TextDoesNotContain -Text $extremeListOutput -Unexpected 'PrivacySandboxPromptEnabled' -Context 'Extreme -List output'
    Assert-TextDoesNotContain -Text $extremeListOutput -Unexpected 'PromotionalTabsEnabled' -Context 'Extreme -List output'
    Assert-TextDoesNotContain -Text $extremeListOutput -Unexpected 'IPFSEnabled' -Context 'Extreme -List output'

    $onlyPatchOutput = (& $scriptPath -OnlyFeature Rewards -List -IncludeProfilePreferences *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $onlyPatchOutput -Expected 'brave.rewards.enabled' -Context '-OnlyFeature profile patch output'
    Assert-TextDoesNotContain -Text $onlyPatchOutput -Unexpected 'brave.new_tab_page.show_branded_background_image' -Context '-OnlyFeature profile patch output'
    Assert-TextDoesNotContain -Text $onlyPatchOutput -Unexpected 'brave.wallet.show_wallet_icon_on_toolbar' -Context '-OnlyFeature profile patch output'

    $onlyDryRunOutput = (& $scriptPath -OnlyFeature Rewards *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $onlyDryRunOutput -Expected 'Preset: (none - OnlyFeature mode)' -Context '-OnlyFeature dry-run output'
    Assert-TextContains -Text $onlyDryRunOutput -Expected 'Custom features: Rewards' -Context '-OnlyFeature dry-run output'
    Assert-TextDoesNotContain -Text $onlyDryRunOutput -Unexpected 'Preset: Extreme' -Context '-OnlyFeature dry-run output'

    $targetUserSid = 'S-1-5-21-1000-2000-3000-1001'
    $targetUserPath = "Registry::HKEY_USERS\$targetUserSid\Software\Policies\BraveSoftware\Brave"
    $targetUserOutput = (& $scriptPath -Platform Windows -UserSid $targetUserSid -OnlyFeature Rewards -ProfileRoot $missingProfileRoot *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $targetUserOutput -Expected 'Scope: CurrentUser' -Context '-UserSid dry-run output'
    Assert-TextContains -Text $targetUserOutput -Expected $targetUserPath -Context '-UserSid dry-run output'
    Assert-TextContains -Text $targetUserOutput -Expected 'Dry-run mode. No policy, backup, or profile files will be changed.' -Context '-UserSid dry-run output'
    Assert-TextContains -Text $targetUserOutput -Expected 'Would set BraveRewardsDisabled' -Context '-UserSid dry-run output'

    $targetUserListModeCommands = @(
        { & $scriptPath -Platform Windows -UserSid $targetUserSid -List | Out-Null },
        { & $scriptPath -Platform Windows -UserSid $targetUserSid -ListFeatures | Out-Null },
        { & $scriptPath -Platform Windows -UserSid $targetUserSid -ListBackups | Out-Null }
    )
    foreach ($targetUserListModeCommand in $targetUserListModeCommands) {
        $targetUserListModeFailed = $false
        try {
            & $targetUserListModeCommand
        }
        catch {
            $targetUserListModeFailed = $_.Exception.Message -match 'cannot be combined with -List'
        }
        if (-not $targetUserListModeFailed) {
            throw '-UserSid did not reject a non-target-specific list mode.'
        }
    }

    $invalidUserSidFailed = $false
    try {
        & $scriptPath -Platform Windows -UserSid 'S-1-5-21-1000\Software' -OnlyFeature Rewards | Out-Null
    }
    catch {
        $invalidUserSidFailed = $_.Exception.Message -match 'Invalid user SID'
    }
    if (-not $invalidUserSidFailed) {
        throw '-UserSid did not reject a path-like value.'
    }

    $nonWindowsUserSidFailed = $false
    try {
        & $scriptPath -Platform Linux -UserSid $targetUserSid -OnlyFeature Rewards | Out-Null
    }
    catch {
        $nonWindowsUserSidFailed = $_.Exception.Message -match 'supported only for Windows registry policies'
    }
    if (-not $nonWindowsUserSidFailed) {
        throw '-UserSid did not reject a non-Windows target.'
    }

    $machineScopeUserSidFailed = $false
    try {
        & $scriptPath -Platform Windows -Scope LocalMachine -UserSid $targetUserSid -OnlyFeature Rewards | Out-Null
    }
    catch {
        $machineScopeUserSidFailed = $_.Exception.Message -match 'cannot be combined with -Scope LocalMachine'
    }
    if (-not $machineScopeUserSidFailed) {
        throw '-UserSid did not reject LocalMachine scope.'
    }

    $blankTargetProfileRootFailed = $false
    try {
        & $scriptPath -Platform Windows -UserSid $targetUserSid -IncludeProfilePreferences -ProfileRoot '' -OnlyFeature Rewards | Out-Null
    }
    catch {
        $blankTargetProfileRootFailed = $_.Exception.Message -match 'requires an explicit -ProfileRoot'
    }
    if (-not $blankTargetProfileRootFailed) {
        throw '-UserSid did not reject a blank profile root for profile cleanup.'
    }

    function Test-UnelevatedUserSidTarget {
        . (Join-Path $root 'src/PlatformPolicy.ps1')
        function Test-IsAdministrator { return $false }

        try {
            Get-PolicyTarget -PlatformName Windows -ScopeName CurrentUser -OverridePath '' -UserSid $targetUserSid -Apply | Out-Null
        }
        catch {
            return ($_.Exception.Message -match 'needs an elevated PowerShell session')
        }

        return $false
    }

    if (-not (Test-UnelevatedUserSidTarget)) {
        throw '-UserSid apply target construction did not require elevation.'
    }

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

    $filteredPatchOutput = (& $scriptPath -Preset Extreme -ExcludeFeature News,Rewards,Wallet -List -IncludeProfilePreferences *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $filteredPatchOutput -Expected 'brave.new_tab_page.show_branded_background_image' -Context 'filtered profile patch output'
    Assert-TextDoesNotContain -Text $filteredPatchOutput -Unexpected 'brave.today.should_show_toolbar_button' -Context 'filtered profile patch output'
    Assert-TextDoesNotContain -Text $filteredPatchOutput -Unexpected 'brave.rewards.enabled' -Context 'filtered profile patch output'
    Assert-TextDoesNotContain -Text $filteredPatchOutput -Unexpected 'brave.wallet.show_wallet_icon_on_toolbar' -Context 'filtered profile patch output'

    $whatIfBackupDirectory = Join-Path $tempRoot 'WhatIfBackups'
    $whatIfOutput = (& $scriptPath -Preset Core -Apply -WhatIf -BackupDirectory $whatIfBackupDirectory *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $whatIfOutput -Expected 'WhatIf mode. No policy, backup, or profile files will be changed.' -Context '-WhatIf output'
    Assert-TextDoesNotContain -Text $whatIfOutput -Unexpected 'Backup written' -Context '-WhatIf output'
    Assert-TextDoesNotContain -Text $whatIfOutput -Unexpected 'Done. Restart Brave' -Context '-WhatIf output'
    if (Test-Path -LiteralPath $whatIfBackupDirectory) {
        throw '-WhatIf created a backup directory.'
    }

    $channelOutput = (& $scriptPath -Preset Core -Channel Beta -ProfileRoot '' *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $channelOutput -Expected 'Channel: Beta' -Context '-Channel Beta output'

    $retentionDirectory = Join-Path $tempRoot 'RetentionBackups'
    New-Item -ItemType Directory -Path $retentionDirectory -Force | Out-Null
    $oldBackup = Join-Path $retentionDirectory 'BraveDebloater-20240101-010101-001.json'
    $newBackup = Join-Path $retentionDirectory 'BraveDebloater-20260101-010101-001.json'
    Set-Content -LiteralPath $oldBackup -Value '{}' -Encoding UTF8
    Set-Content -LiteralPath $newBackup -Value '{}' -Encoding UTF8
    (Get-Item -LiteralPath $oldBackup).LastWriteTime = (Get-Date).AddDays(-60)
    (Get-Item -LiteralPath $newBackup).LastWriteTime = Get-Date

    $listBackupsOutput = (& $scriptPath -BackupDirectory $retentionDirectory -ListBackups *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $listBackupsOutput -Expected 'Backups: 2 found' -Context '-ListBackups output'
    Assert-TextDoesNotContain -Text $listBackupsOutput -Unexpected 'Backup cleanup: nothing to remove.' -Context '-ListBackups output'

    $retentionPreview = (& $scriptPath -BackupDirectory $retentionDirectory -PruneBackupsOlderThanDays 30 *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $retentionPreview -Expected 'Would remove backup BraveDebloater-20240101-010101-001.json' -Context 'backup retention preview'
    if (-not (Test-Path -LiteralPath $oldBackup)) {
        throw 'Backup retention preview deleted a backup.'
    }

    $retentionApply = (& $scriptPath -BackupDirectory $retentionDirectory -KeepLatestBackups 1 -Apply *>&1 | Out-String -Width 4096)
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

    $restoreOutput = (& $scriptPath -UndoFromBackup $validBackup *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $restoreOutput -Expected 'Would remove BraveRewardsDisabled' -Context 'restore dry-run output'

    $targetUserBackup = Join-Path $tempRoot 'target-user-backup.json'
    [ordered]@{
        schemaVersion = 1
        registryPath = $targetUserPath
        policies = @(
            [ordered]@{
                name = 'BraveRewardsDisabled'
                existed = $false
                value = $null
                kind = $null
            }
        )
        profileFiles = @()
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $targetUserBackup -Encoding UTF8

    $targetUserRestoreRejected = $false
    try {
        & $scriptPath -Platform Windows -ProfileRoot $missingProfileRoot -UndoFromBackup $targetUserBackup | Out-Null
    }
    catch {
        $targetUserRestoreRejected = $_.Exception.Message -match 'untrusted registry path'
    }
    if (-not $targetUserRestoreRejected) {
        throw 'Target-user backup restore did not require the matching -UserSid.'
    }

    $targetUserRestoreOutput = (& $scriptPath -Platform Windows -UserSid $targetUserSid -ProfileRoot $missingProfileRoot -UndoFromBackup $targetUserBackup *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $targetUserRestoreOutput -Expected 'Would remove BraveRewardsDisabled' -Context 'target-user restore dry-run output'

    $unsafeTargetUserBackup = Join-Path $tempRoot 'unsafe-target-user-backup.json'
    [ordered]@{
        schemaVersion = 1
        registryPath = "Registry::HKEY_USERS\$targetUserSid\Software\Microsoft"
        policies = @()
        profileFiles = @()
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $unsafeTargetUserBackup -Encoding UTF8

    $unsafeTargetUserRestoreRejected = $false
    try {
        & $scriptPath -Platform Windows -ProfileRoot $missingProfileRoot -PolicyPath "Registry::HKEY_USERS\$targetUserSid\Software\Microsoft" -UndoFromBackup $unsafeTargetUserBackup | Out-Null
    }
    catch {
        $unsafeTargetUserRestoreRejected = $_.Exception.Message -match 'untrusted registry path'
    }
    if (-not $unsafeTargetUserRestoreRejected) {
        throw 'Target-user restore accepted a path outside the exact Brave policy suffix.'
    }

    $policyPathTargetUserRestoreRejected = $false
    try {
        & $scriptPath -Platform Windows -ProfileRoot $missingProfileRoot -PolicyPath $targetUserPath -UndoFromBackup $targetUserBackup | Out-Null
    }
    catch {
        $policyPathTargetUserRestoreRejected = $_.Exception.Message -match 'untrusted registry path'
    }
    if (-not $policyPathTargetUserRestoreRejected) {
        throw '-PolicyPath authorized a target-user restore without the matching -UserSid.'
    }

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

    $invalidJsonOutput = (& $scriptPath -Preset Core -IncludeProfilePreferences -ProfileRoot $mixedProfileRoot *>&1 | Out-String -Width 4096)
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
    $linuxApplyOutput = (& $scriptPath -Platform Linux -PolicyPath $linuxPolicyPath -OnlyFeature Rewards -Apply -BackupDirectory $linuxBackupDirectory *>&1 | Out-String -Width 4096)
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
    Assert-TextDoesNotContain -Text $linuxApplyOutput -Unexpected 'obsolete' -Context 'Linux policy apply output'

    $leftoverPolicyPath = Join-Path $tempRoot 'leftover-obsolete-policy.json'
    $leftoverBackupDirectory = Join-Path $tempRoot 'LeftoverBackups'
    [ordered]@{
        PrivacySandboxPromptEnabled = $false
        PromotionalTabsEnabled = $false
    } | ConvertTo-Json | Set-Content -LiteralPath $leftoverPolicyPath -Encoding UTF8

    $leftoverDoctorOutput = (& $scriptPath -Doctor -Platform Linux -PolicyPath $leftoverPolicyPath -ProfileRoot $missingProfileRoot -BackupDirectory $leftoverBackupDirectory *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $leftoverDoctorOutput -Expected 'Obsolete leftover policies: detected. Rerun with -Apply to remove them.' -Context 'Doctor obsolete leftover output'
    Assert-TextContains -Text $leftoverDoctorOutput -Expected 'PrivacySandboxPromptEnabled' -Context 'Doctor obsolete leftover output'
    Assert-TextContains -Text $leftoverDoctorOutput -Expected 'PromotionalTabsEnabled' -Context 'Doctor obsolete leftover output'

    $leftoverDryRunOutput = (& $scriptPath -Platform Linux -PolicyPath $leftoverPolicyPath -OnlyFeature Rewards -BackupDirectory $leftoverBackupDirectory *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $leftoverDryRunOutput -Expected 'Would remove PrivacySandboxPromptEnabled because Brave marks it obsolete.' -Context 'obsolete leftover dry-run output'
    Assert-TextContains -Text $leftoverDryRunOutput -Expected 'Would remove PromotionalTabsEnabled because Brave marks it obsolete.' -Context 'obsolete leftover dry-run output'
    Assert-TextContains -Text $leftoverDryRunOutput -Expected '2 obsolete leftover(s) to remove' -Context 'obsolete leftover dry-run output'
    $leftoverDryRunJson = Get-Content -LiteralPath $leftoverPolicyPath -Raw | ConvertFrom-Json
    if ($null -eq $leftoverDryRunJson.PSObject.Properties['PrivacySandboxPromptEnabled'] -or $null -eq $leftoverDryRunJson.PSObject.Properties['PromotionalTabsEnabled']) {
        throw 'Dry-run removed leftover obsolete policies.'
    }

    $leftoverApplyOutput = (& $scriptPath -Platform Linux -PolicyPath $leftoverPolicyPath -OnlyFeature Rewards -Apply -BackupDirectory $leftoverBackupDirectory *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $leftoverApplyOutput -Expected 'Removed obsolete PrivacySandboxPromptEnabled.' -Context 'obsolete leftover apply output'
    Assert-TextContains -Text $leftoverApplyOutput -Expected 'Removed obsolete PromotionalTabsEnabled.' -Context 'obsolete leftover apply output'
    Assert-TextContains -Text $leftoverApplyOutput -Expected 'Removed 2 obsolete leftover(s).' -Context 'obsolete leftover apply output'
    $leftoverApplyJson = Get-Content -LiteralPath $leftoverPolicyPath -Raw | ConvertFrom-Json
    if ($null -ne $leftoverApplyJson.PSObject.Properties['PrivacySandboxPromptEnabled']) {
        throw 'Linux policy apply left PrivacySandboxPromptEnabled in place.'
    }
    if ($null -ne $leftoverApplyJson.PSObject.Properties['PromotionalTabsEnabled']) {
        throw 'Linux policy apply left PromotionalTabsEnabled in place.'
    }
    if ($leftoverApplyJson.BraveRewardsDisabled -isnot [bool] -or -not $leftoverApplyJson.BraveRewardsDisabled) {
        throw 'Linux leftover apply did not write BraveRewardsDisabled = true.'
    }
    $leftoverBackups = @(Get-ChildItem -LiteralPath $leftoverBackupDirectory -Filter 'BraveDebloater-*.json')
    if ($leftoverBackups.Count -ne 1) {
        throw "Linux leftover apply did not create exactly one backup, found $($leftoverBackups.Count)."
    }
    $leftoverBackup = Get-Content -LiteralPath $leftoverBackups[0].FullName -Raw | ConvertFrom-Json
    $leftoverBackupNames = @($leftoverBackup.policies | ForEach-Object { [string]$_.name })
    if ($leftoverBackupNames -notcontains 'PrivacySandboxPromptEnabled' -or $leftoverBackupNames -notcontains 'PromotionalTabsEnabled') {
        throw 'Linux leftover backup did not snapshot the obsolete policies.'
    }

    $leftoverRestoreOutput = (& $scriptPath -UndoFromBackup $leftoverBackups[0].FullName -PolicyPath $leftoverPolicyPath *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $leftoverRestoreOutput -Expected 'Would restore PrivacySandboxPromptEnabled' -Context 'obsolete leftover restore dry-run output'
    Assert-TextContains -Text $leftoverRestoreOutput -Expected 'Would restore PromotionalTabsEnabled' -Context 'obsolete leftover restore dry-run output'

    $oldDeprecatedBackup = Join-Path $tempRoot 'old-deprecated-backup.json'
    [ordered]@{
        schemaVersion = 1
        platform = 'Linux'
        policyKind = 'JsonFile'
        registryPath = $leftoverPolicyPath
        policies = @(
            [ordered]@{
                name = 'PrivacySandboxPromptEnabled'
                existed = $true
                value = 0
                kind = 'DWord'
            }
        )
        profileFiles = @()
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $oldDeprecatedBackup -Encoding UTF8
    $oldDeprecatedRestoreOutput = (& $scriptPath -UndoFromBackup $oldDeprecatedBackup -PolicyPath $leftoverPolicyPath *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $oldDeprecatedRestoreOutput -Expected 'Would restore PrivacySandboxPromptEnabled' -Context 'old deprecated backup restore dry-run output'

    $malformedPolicyPath = Join-Path $tempRoot 'malformed-linux-policy.json'
    $malformedPolicyContent = '{ this is not valid json'
    Set-Content -LiteralPath $malformedPolicyPath -Value $malformedPolicyContent -Encoding UTF8 -NoNewline
    $malformedDryRunOutput = (& $scriptPath -Platform Linux -PolicyPath $malformedPolicyPath -OnlyFeature Rewards *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $malformedDryRunOutput -Expected 'Would set BraveRewardsDisabled' -Context 'malformed Linux policy dry-run output'
    Assert-TextContains -Text $malformedDryRunOutput -Expected 'leftover obsolete policies were not checked' -Context 'malformed Linux policy dry-run output'
    Assert-TextContains -Text $malformedDryRunOutput -Expected 'Dry-run complete.' -Context 'malformed Linux policy dry-run output'
    Assert-TextDoesNotContain -Text $malformedDryRunOutput -Unexpected 'Would remove PrivacySandboxPromptEnabled' -Context 'malformed Linux policy dry-run output'
    $malformedAfterDryRun = Get-Content -LiteralPath $malformedPolicyPath -Raw
    if ($malformedAfterDryRun -ne $malformedPolicyContent) {
        throw 'Dry-run modified a malformed Linux policy JSON file.'
    }
    $malformedWhatIfOutput = (& $scriptPath -Platform Linux -PolicyPath $malformedPolicyPath -OnlyFeature Rewards -Apply -WhatIf *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $malformedWhatIfOutput -Expected 'Would set BraveRewardsDisabled' -Context 'malformed Linux policy WhatIf output'
    Assert-TextContains -Text $malformedWhatIfOutput -Expected 'WhatIf complete.' -Context 'malformed Linux policy WhatIf output'
    $malformedAfterWhatIf = Get-Content -LiteralPath $malformedPolicyPath -Raw
    if ($malformedAfterWhatIf -ne $malformedPolicyContent) {
        throw 'WhatIf modified a malformed Linux policy JSON file.'
    }
    $malformedApplyBackupDirectory = Join-Path $tempRoot 'MalformedApplyBackups'
    $malformedApplyFailed = $false
    try {
        & $scriptPath -Platform Linux -PolicyPath $malformedPolicyPath -OnlyFeature Rewards -Apply -BackupDirectory $malformedApplyBackupDirectory *>&1 | Out-Null
    }
    catch {
        $malformedApplyFailed = $true
    }
    if (-not $malformedApplyFailed) {
        throw 'Apply did not fail on malformed Linux policy JSON.'
    }
    if ((Test-Path -LiteralPath $malformedApplyBackupDirectory) -and (@(Get-ChildItem -LiteralPath $malformedApplyBackupDirectory -Filter 'BraveDebloater-*.json').Count -gt 0)) {
        throw 'Apply wrote a backup before failing on malformed Linux policy JSON.'
    }
    $malformedAfterApply = Get-Content -LiteralPath $malformedPolicyPath -Raw
    if ($malformedAfterApply -ne $malformedPolicyContent) {
        throw 'Apply modified a malformed Linux policy JSON file.'
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

    $customRestoreOutput = (& $scriptPath -UndoFromBackup $customLinuxBackup -PolicyPath $linuxPolicyPath *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $customRestoreOutput -Expected 'Would remove BraveRewardsDisabled' -Context 'custom Linux restore dry-run output'

    $androidDryRunOutput = (& $scriptPath -Platform Android -OnlyFeature Rewards *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $androidDryRunOutput -Expected 'Platform: Android' -Context 'Android dry-run output'
    Assert-TextContains -Text $androidDryRunOutput -Expected 'MDM profile' -Context 'Android dry-run output'
    Assert-TextContains -Text $androidDryRunOutput -Expected 'Would set BraveRewardsDisabled' -Context 'Android dry-run output'

    $androidPolicyPath = Join-Path $tempRoot 'brave-android-mdm.json'
    $androidExportOutput = (& $scriptPath -Platform Android -OnlyFeature Rewards -ExportPolicyPath $androidPolicyPath *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $androidExportOutput -Expected 'Exported 1 policy value(s) for Android' -Context 'Android export output'
    $androidPolicyJson = Get-Content -LiteralPath $androidPolicyPath -Raw | ConvertFrom-Json
    if ($androidPolicyJson.BraveRewardsDisabled -isnot [bool] -or -not $androidPolicyJson.BraveRewardsDisabled) {
        throw 'Android policy export did not write BraveRewardsDisabled = true.'
    }

    $iosPolicyPath = Join-Path $tempRoot 'brave-ios.mobileconfig'
    $iosExportOutput = (& $scriptPath -Platform iOS -OnlyFeature Rewards -ExportPolicyPath $iosPolicyPath *>&1 | Out-String -Width 4096)
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

    $iosSupportedDryRun = (& $scriptPath -Platform iOS -OnlyFeature Rewards *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $iosSupportedDryRun -Expected 'Would set BraveRewardsDisabled' -Context 'iOS supported dry-run output'

    $regExportPath = Join-Path $tempRoot 'brave-policies.reg'
    $regExportOutput = (& $scriptPath -Platform Windows -OnlyFeature Rewards,NetworkPrediction -ProfileRoot $missingProfileRoot -ExportPolicyPath $regExportPath *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $regExportOutput -Expected 'Exported 2 policy value(s) for Windows' -Context 'Windows .reg export output'
    Assert-TextContains -Text $regExportOutput -Expected 'reg import' -Context 'Windows .reg export output'
    $regBytes = [System.IO.File]::ReadAllBytes($regExportPath)
    if ($regBytes.Length -lt 2 -or $regBytes[0] -ne 0xff -or $regBytes[1] -ne 0xfe) {
        throw 'Windows .reg export was not written as UTF-16LE with a byte order mark.'
    }
    $regExport = [System.IO.File]::ReadAllText($regExportPath, [System.Text.Encoding]::Unicode)
    Assert-TextContains -Text $regExport -Expected 'Windows Registry Editor Version 5.00' -Context 'Windows .reg export'
    Assert-TextContains -Text $regExport -Expected '[HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave]' -Context 'Windows .reg export'
    Assert-TextContains -Text $regExport -Expected '"BraveRewardsDisabled"=dword:00000001' -Context 'Windows .reg export'
    Assert-TextContains -Text $regExport -Expected '"NetworkPredictionOptions"=dword:00000002' -Context 'Windows .reg export'
    Assert-TextDoesNotContain -Text $regExport -Unexpected '<plist' -Context 'Windows .reg export'

    $regExportMachinePath = Join-Path $tempRoot 'brave-policies-machine.reg'
    & $scriptPath -Platform Windows -Scope LocalMachine -OnlyFeature Rewards -ProfileRoot $missingProfileRoot -ExportPolicyPath $regExportMachinePath *>&1 | Out-Null
    $regExportMachine = [System.IO.File]::ReadAllText($regExportMachinePath, [System.Text.Encoding]::Unicode)
    Assert-TextContains -Text $regExportMachine -Expected '[HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave]' -Context 'Windows LocalMachine .reg export'

    $regExportNonWindowsFailed = $false
    try {
        & $scriptPath -Platform Linux -OnlyFeature Rewards -ExportPolicyPath (Join-Path $tempRoot 'wrong-platform.reg') | Out-Null
    }
    catch {
        $regExportNonWindowsFailed = $_.Exception.Message -match 'needs a Windows registry target'
    }
    if (-not $regExportNonWindowsFailed) {
        throw '.reg export did not reject a non-registry target.'
    }

    # Previews must work without elevation on every platform; only -Apply performs the admin/root checks.
    $machinePreview = (& $scriptPath -Platform Windows -Scope LocalMachine -OnlyFeature Rewards -ProfileRoot $missingProfileRoot *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $machinePreview -Expected 'Scope: LocalMachine (Registry::HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave)' -Context 'unelevated LocalMachine preview'
    Assert-TextContains -Text $machinePreview -Expected 'Dry-run complete.' -Context 'unelevated LocalMachine preview'
    $macMachinePreview = (& $scriptPath -Platform macOS -Scope LocalMachine -OnlyFeature Rewards -ProfileRoot $missingProfileRoot *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $macMachinePreview -Expected 'Dry-run complete.' -Context 'unelevated macOS LocalMachine preview'
    $linuxDefaultPreview = (& $scriptPath -Platform Linux -OnlyFeature Rewards -ProfileRoot $missingProfileRoot *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $linuxDefaultPreview -Expected '/etc/brave/policies/managed/BraveDebloater.json' -Context 'unelevated Linux default path preview'
    Assert-TextContains -Text $linuxDefaultPreview -Expected 'Dry-run complete.' -Context 'unelevated Linux default path preview'

    $ignoredPolicyPathOutput = (& $scriptPath -Platform Windows -OnlyFeature Rewards -ProfileRoot $missingProfileRoot -PolicyPath (Join-Path $tempRoot 'ignored.json') *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $ignoredPolicyPathOutput -Expected '-PolicyPath is ignored for Windows CurrentUser policies' -Context 'ignored -PolicyPath output'
    $linuxPolicyPathOutput = (& $scriptPath -Platform Linux -OnlyFeature Rewards -ProfileRoot $missingProfileRoot -PolicyPath (Join-Path $tempRoot 'used.json') *>&1 | Out-String -Width 4096)
    Assert-TextDoesNotContain -Text $linuxPolicyPathOutput -Unexpected '-PolicyPath is ignored' -Context 'Linux -PolicyPath output'

    # A forced Windows platform on another OS has no LOCALAPPDATA; the run must still preview cleanly.
    $forcedWindowsOutput = (& $scriptPath -Platform Windows -OnlyFeature Rewards *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $forcedWindowsOutput -Expected 'Would set BraveRewardsDisabled' -Context 'forced Windows platform preview'

    $utf8ProfileRoot = Join-Path $tempRoot 'Utf8ProfileRoot'
    $utf8ProfileDirectory = Join-Path $utf8ProfileRoot 'Default'
    New-Item -ItemType Directory -Path $utf8ProfileDirectory -Force | Out-Null
    $utf8Preferences = Join-Path $utf8ProfileDirectory 'Preferences'
    $utf8Name = [char]0x004A + [char]0x006F + [char]0x0073 + [char]0x00E9 + ' ' + [char]0x2713
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($utf8Preferences, ('{"profile":{"name":"' + $utf8Name + '"},"brave":{"rewards":{"enabled":true}}}'), $utf8NoBom)
    $utf8PolicyPath = Join-Path $tempRoot 'utf8-policy.json'
    $utf8BackupDirectory = Join-Path $tempRoot 'Utf8Backups'
    $utf8ApplyOutput = (& $scriptPath -Platform Linux -PolicyPath $utf8PolicyPath -OnlyFeature Rewards -IncludeProfilePreferences -ProfileRoot $utf8ProfileRoot -BackupDirectory $utf8BackupDirectory -Apply *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $utf8ApplyOutput -Expected 'Updated profile preferences in' -Context 'UTF-8 profile apply output'
    $utf8Bytes = [System.IO.File]::ReadAllBytes($utf8Preferences)
    if ($utf8Bytes.Length -ge 3 -and $utf8Bytes[0] -eq 0xef -and $utf8Bytes[1] -eq 0xbb -and $utf8Bytes[2] -eq 0xbf) {
        throw 'Profile preference cleanup wrote a UTF-8 BOM to Preferences.'
    }
    $utf8Json = [System.IO.File]::ReadAllText($utf8Preferences, $utf8NoBom) | ConvertFrom-Json
    if ([string]$utf8Json.profile.name -ne $utf8Name) {
        throw "Profile preference cleanup changed non-ASCII text from '$utf8Name' to '$($utf8Json.profile.name)'."
    }
    if ($utf8Json.brave.rewards.enabled -ne $false) {
        throw 'Profile preference cleanup did not apply the Rewards patch.'
    }
    $utf8PolicyBytes = [System.IO.File]::ReadAllBytes($utf8PolicyPath)
    if ($utf8PolicyBytes.Length -ge 3 -and $utf8PolicyBytes[0] -eq 0xef -and $utf8PolicyBytes[1] -eq 0xbb -and $utf8PolicyBytes[2] -eq 0xbf) {
        throw 'Linux policy apply wrote a UTF-8 BOM to the managed policy file.'
    }
    $utf8Backup = @(Get-ChildItem -LiteralPath $utf8BackupDirectory -Filter 'BraveDebloater-*.json')[0].FullName
    $utf8RestoreOutput = (& $scriptPath -UndoFromBackup $utf8Backup -PolicyPath $utf8PolicyPath -ProfileRoot $utf8ProfileRoot -Apply *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $utf8RestoreOutput -Expected 'Restored profile file' -Context 'UTF-8 profile restore output'
    $restoredJson = [System.IO.File]::ReadAllText($utf8Preferences, $utf8NoBom) | ConvertFrom-Json
    if ([string]$restoredJson.profile.name -ne $utf8Name -or $restoredJson.brave.rewards.enabled -ne $true) {
        throw 'Profile restore did not bring back the original Preferences content.'
    }

    # Rewriting Preferences must keep unrelated date strings exactly as written. PowerShell 7 before
    # 7.5 cannot parse them as text, so those versions skip the file instead of changing it.
    $dateProfileRoot = Join-Path $tempRoot 'DateProfileRoot'
    $datePreferences = Join-Path (Join-Path $dateProfileRoot 'Default') 'Preferences'
    New-Item -ItemType Directory -Path (Split-Path -Parent $datePreferences) -Force | Out-Null
    $dateStamp = '2023-01-01T12:00:00.1234567+13:00'
    $dateOriginal = '{"sync":{"last_synced":"' + $dateStamp + '"},"brave":{"rewards":{"enabled":true}}}'
    [System.IO.File]::WriteAllText($datePreferences, $dateOriginal, $utf8NoBom)
    $dateApplyOutput = (& $scriptPath -Platform Linux -PolicyPath (Join-Path $tempRoot 'date-policy.json') -OnlyFeature Rewards -IncludeProfilePreferences -ProfileRoot $dateProfileRoot -BackupDirectory (Join-Path $tempRoot 'DateBackups') -Apply *>&1 | Out-String -Width 4096)
    $dateText = [System.IO.File]::ReadAllText($datePreferences, $utf8NoBom)
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        Assert-TextContains -Text $dateApplyOutput -Expected 'it contains date values' -Context 'date Preferences apply output'
        if ($dateText -cne $dateOriginal) {
            throw 'Profile preference cleanup changed a Preferences file it could not rewrite safely.'
        }
    }
    else {
        Assert-TextContains -Text $dateApplyOutput -Expected 'Updated profile preferences in' -Context 'date Preferences apply output'
        Assert-TextContains -Text $dateText -Expected "`"$dateStamp`"" -Context 'date Preferences content'
        if (($dateText | ConvertFrom-Json).brave.rewards.enabled -ne $false) {
            throw 'Profile preference cleanup did not apply the Rewards patch next to a date value.'
        }
    }

    $versionOutput = (& $scriptPath -Version *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $versionOutput -Expected 'BraveDebloater 0.5.0' -Context '-Version output'
    Assert-TextContains -Text $versionOutput -Expected 'Policy template version: 153.1.97.22' -Context '-Version output'
    Assert-TextContains -Text $versionOutput -Expected 'PowerShell: ' -Context '-Version output'
    Assert-TextDoesNotContain -Text $versionOutput -Unexpected '[dry-run]' -Context '-Version output'

    function Test-RegFileStringEscaping {
        . (Join-Path $root 'src/Common.ps1')
        . (Join-Path $root 'src/PlatformPolicy.ps1')

        $payload = [ordered]@{ Sample = 'C:\Brave "quoted"'; Flag = $true; Level = 2 }
        return (ConvertTo-RegFileDocument -RegistryPath 'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave' -Payload $payload)
    }
    $regDocument = Test-RegFileStringEscaping
    Assert-TextContains -Text $regDocument -Expected '"Sample"="C:\\Brave \"quoted\""' -Context '.reg string escaping'
    Assert-TextDoesNotContain -Text $regDocument -Unexpected '\\\\' -Context '.reg string escaping'
    Assert-TextContains -Text $regDocument -Expected '"Flag"=dword:00000001' -Context '.reg boolean value'
    Assert-TextContains -Text $regDocument -Expected '"Level"=dword:00000002' -Context '.reg integer value'

    # Two apply runs against the same profile must keep two distinct Preferences copies so the
    # first backup still restores the original content.
    $collisionProfileRoot = Join-Path $tempRoot 'CollisionProfileRoot'
    $collisionProfileDirectory = Join-Path $collisionProfileRoot 'Default'
    New-Item -ItemType Directory -Path $collisionProfileDirectory -Force | Out-Null
    $collisionPreferences = Join-Path $collisionProfileDirectory 'Preferences'
    [System.IO.File]::WriteAllText($collisionPreferences, '{"brave":{"rewards":{"enabled":true}}}', $utf8NoBom)
    $collisionPolicyPath = Join-Path $tempRoot 'collision-policy.json'
    $collisionBackupDirectory = Join-Path $tempRoot 'CollisionBackups'
    & $scriptPath -Platform Linux -PolicyPath $collisionPolicyPath -OnlyFeature Rewards -IncludeProfilePreferences -ProfileRoot $collisionProfileRoot -BackupDirectory $collisionBackupDirectory -Apply *>&1 | Out-Null
    $firstCollisionBackup = @(Get-ChildItem -LiteralPath $collisionBackupDirectory -Filter 'BraveDebloater-*.json')[0]
    Start-Sleep -Milliseconds 1200
    [System.IO.File]::WriteAllText($collisionPreferences, '{"brave":{"rewards":{"enabled":true}},"marker":"second-run"}', $utf8NoBom)
    & $scriptPath -Platform Linux -PolicyPath $collisionPolicyPath -OnlyFeature Rewards -IncludeProfilePreferences -ProfileRoot $collisionProfileRoot -BackupDirectory $collisionBackupDirectory -Apply *>&1 | Out-Null
    $collisionBackups = @(Get-ChildItem -LiteralPath $collisionBackupDirectory -Filter 'BraveDebloater-*.json' | Sort-Object LastWriteTime)
    if ($collisionBackups.Count -ne 2) {
        throw "Expected 2 backups after two profile apply runs, found $($collisionBackups.Count)."
    }
    $firstCollisionJson = Get-Content -LiteralPath $firstCollisionBackup.FullName -Raw | ConvertFrom-Json
    $secondCollisionJson = Get-Content -LiteralPath ($collisionBackups | Where-Object { $_.Name -ne $firstCollisionBackup.Name } | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
    $firstProfileBackup = [string]@($firstCollisionJson.profileFiles)[0].backupPath
    $secondProfileBackup = [string]@($secondCollisionJson.profileFiles)[0].backupPath
    if ($firstProfileBackup -eq $secondProfileBackup) {
        throw 'Two apply runs shared the same profile Preferences backup file.'
    }
    if (-not (Test-Path -LiteralPath $firstProfileBackup) -or -not (Test-Path -LiteralPath $secondProfileBackup)) {
        throw 'A profile Preferences backup file is missing after two apply runs.'
    }
    Assert-TextDoesNotContain -Text ([System.IO.File]::ReadAllText($firstProfileBackup, $utf8NoBom)) -Unexpected 'second-run' -Context 'first profile backup content'
    Assert-TextContains -Text ([System.IO.File]::ReadAllText($secondProfileBackup, $utf8NoBom)) -Expected 'second-run' -Context 'second profile backup content'
    $firstRestoreOutput = (& $scriptPath -UndoFromBackup $firstCollisionBackup.FullName -PolicyPath $collisionPolicyPath -ProfileRoot $collisionProfileRoot -Apply *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $firstRestoreOutput -Expected 'Restored profile file' -Context 'first backup restore output'
    $restoredCollisionText = [System.IO.File]::ReadAllText($collisionPreferences, $utf8NoBom)
    Assert-TextDoesNotContain -Text $restoredCollisionText -Unexpected 'second-run' -Context 'restored Preferences from first backup'
    if (($restoredCollisionText | ConvertFrom-Json).brave.rewards.enabled -ne $true) {
        throw 'Restoring the first backup did not bring back the original Rewards preference.'
    }

    # Pruning a backup also removes the profile Preferences copies that belong only to it.
    $collisionPrunePreview = (& $scriptPath -BackupDirectory $collisionBackupDirectory -KeepLatestBackups 1 *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $collisionPrunePreview -Expected "Would remove backup $($firstCollisionBackup.Name)" -Context 'profile backup prune preview'
    Assert-TextContains -Text $collisionPrunePreview -Expected 'Would remove profile backup' -Context 'profile backup prune preview'
    if (-not (Test-Path -LiteralPath $firstProfileBackup)) {
        throw 'Backup prune preview deleted a profile Preferences backup.'
    }
    $collisionPruneApply = (& $scriptPath -BackupDirectory $collisionBackupDirectory -KeepLatestBackups 1 -Apply *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $collisionPruneApply -Expected "Removed backup $($firstCollisionBackup.Name)." -Context 'profile backup prune apply'
    Assert-TextContains -Text $collisionPruneApply -Expected 'Removed profile backup' -Context 'profile backup prune apply'
    if (Test-Path -LiteralPath $firstProfileBackup) {
        throw 'Backup prune did not remove the pruned backup profile Preferences copy.'
    }
    if (Test-Path -LiteralPath (Split-Path -Parent $firstProfileBackup)) {
        throw 'Backup prune left an empty per-backup profile-files folder behind.'
    }
    if (-not (Test-Path -LiteralPath $secondProfileBackup)) {
        throw 'Backup prune removed a profile Preferences copy that belongs to a kept backup.'
    }

    # A pruned backup that points at another backup's Preferences copy must not take it along.
    $decoyBackup = Join-Path $collisionBackupDirectory 'BraveDebloater-20000101-000000-000.json'
    [ordered]@{
        schemaVersion = 1
        platform = 'Linux'
        policyKind = 'JsonFile'
        registryPath = $collisionPolicyPath
        policies = @()
        profileFiles = @([ordered]@{ backupPath = $secondProfileBackup; originalPath = $collisionPreferences })
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $decoyBackup -Encoding UTF8
    (Get-Item -LiteralPath $decoyBackup).LastWriteTime = (Get-Date).AddDays(-30)
    $decoyPruneOutput = (& $scriptPath -BackupDirectory $collisionBackupDirectory -KeepLatestBackups 1 -Apply *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $decoyPruneOutput -Expected 'Removed backup BraveDebloater-20000101-000000-000.json.' -Context 'decoy backup prune output'
    Assert-TextDoesNotContain -Text $decoyPruneOutput -Unexpected 'Removed profile backup' -Context 'decoy backup prune output'
    if (-not (Test-Path -LiteralPath $secondProfileBackup)) {
        throw 'Pruning a backup removed a profile Preferences copy stored under another backup''s folder.'
    }

    # Profile paths with wildcard characters must be handled literally on every PowerShell version.
    $bracketProfileRoot = Join-Path $tempRoot 'Bracket [Profile] Root'
    $bracketProfileDirectory = Join-Path $bracketProfileRoot 'Profile [1]'
    [System.IO.Directory]::CreateDirectory($bracketProfileDirectory) | Out-Null
    $bracketPreferences = Join-Path $bracketProfileDirectory 'Preferences'
    [System.IO.File]::WriteAllText($bracketPreferences, '{"brave":{"rewards":{"enabled":true}}}', $utf8NoBom)
    $bracketPolicyPath = Join-Path (Join-Path $tempRoot 'Bracket [Policies]') 'brave-policy.json'
    $bracketBackupDirectory = Join-Path $tempRoot 'Bracket [Backups]'
    $bracketApplyOutput = (& $scriptPath -Platform Linux -PolicyPath $bracketPolicyPath -OnlyFeature Rewards -IncludeProfilePreferences -ProfileRoot $bracketProfileRoot -BackupDirectory $bracketBackupDirectory -Apply *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $bracketApplyOutput -Expected 'Updated profile preferences in' -Context 'bracket path apply output'
    if (-not (Test-Path -LiteralPath $bracketPolicyPath)) {
        throw 'Apply did not create the policy JSON file under a bracket path.'
    }
    if (([System.IO.File]::ReadAllText($bracketPreferences, $utf8NoBom) | ConvertFrom-Json).brave.rewards.enabled -ne $false) {
        throw 'Profile preference cleanup did not patch a Preferences file under a bracket path.'
    }
    $bracketBackup = @(Get-ChildItem -LiteralPath $bracketBackupDirectory -Filter 'BraveDebloater-*.json')[0].FullName
    $bracketBackupJson = Get-Content -LiteralPath $bracketBackup -Raw | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath ([string]@($bracketBackupJson.profileFiles)[0].backupPath))) {
        throw 'Profile Preferences backup copy is missing for a bracket path.'
    }
    $bracketRestoreOutput = (& $scriptPath -UndoFromBackup $bracketBackup -PolicyPath $bracketPolicyPath -ProfileRoot $bracketProfileRoot -Apply *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $bracketRestoreOutput -Expected 'Restored profile file' -Context 'bracket path restore output'
    if (([System.IO.File]::ReadAllText($bracketPreferences, $utf8NoBom) | ConvertFrom-Json).brave.rewards.enabled -ne $true) {
        throw 'Restore did not bring back the original Preferences under a bracket path.'
    }

    # Restore refuses a backup whose policy kind does not match its recorded path.
    $kindMismatchBackup = Join-Path $tempRoot 'kind-mismatch-backup.json'
    [ordered]@{
        schemaVersion = 1
        platform = 'Linux'
        policyKind = 'JsonFile'
        registryPath = 'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave'
        policies = @()
        profileFiles = @()
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $kindMismatchBackup -Encoding UTF8
    $kindMismatchRejected = $false
    try {
        & $scriptPath -UndoFromBackup $kindMismatchBackup | Out-Null
    }
    catch {
        $kindMismatchRejected = $_.Exception.Message -match 'does not match its policy path'
    }
    if (-not $kindMismatchRejected) {
        throw 'Restore accepted a backup whose policy kind does not match its path.'
    }
    if (Test-Path -LiteralPath (Join-Path (Get-Location).Path 'HKEY_CURRENT_USER')) {
        throw 'Restore wrote a registry-named file into the working directory.'
    }

    # File kinds only pair with their own platform's default path, so JSON is never written into the
    # macOS managed plist and `defaults` never targets the Linux managed JSON file.
    $crossKindCases = @(
        @{ Kind = 'JsonFile'; Path = '/Library/Managed Preferences/com.brave.Browser.plist' },
        @{ Kind = 'MacOSPlist'; Path = '/etc/brave/policies/managed/BraveDebloater.json' }
    )
    foreach ($crossKindCase in $crossKindCases) {
        $crossKindBackup = Join-Path $tempRoot "cross-kind-$($crossKindCase.Kind).json"
        [ordered]@{
            schemaVersion = 1
            policyKind = $crossKindCase.Kind
            registryPath = $crossKindCase.Path
            policies = @()
            profileFiles = @()
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $crossKindBackup -Encoding UTF8
        $crossKindRejected = $false
        try {
            & $scriptPath -UndoFromBackup $crossKindBackup | Out-Null
        }
        catch {
            $crossKindRejected = $_.Exception.Message -match 'does not match its policy path'
        }
        if (-not $crossKindRejected) {
            throw "Restore accepted a $($crossKindCase.Kind) backup that points at $($crossKindCase.Path)."
        }
    }

    $unknownKindBackup = Join-Path $tempRoot 'unknown-kind-backup.json'
    [ordered]@{
        schemaVersion = 1
        policyKind = 'Mystery'
        registryPath = 'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave'
        policies = @()
        profileFiles = @()
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $unknownKindBackup -Encoding UTF8
    $unknownKindRejected = $false
    try {
        & $scriptPath -UndoFromBackup $unknownKindBackup | Out-Null
    }
    catch {
        $unknownKindRejected = $_.Exception.Message -match 'unsupported policy kind'
    }
    if (-not $unknownKindRejected) {
        throw 'Restore accepted a backup with an unknown policy kind.'
    }

    function Test-UnelevatedLinuxDefaultRestore {
        . (Join-Path $root 'src/Common.ps1')
        . (Join-Path $root 'src/PlatformPolicy.ps1')
        . (Join-Path $root 'src/Backup.ps1')
        function Test-IsAdministrator { return $false }

        try {
            Assert-BackupRegistryPath -RegistryPath '/etc/brave/policies/managed/BraveDebloater.json' -DoApply
        }
        catch {
            return ($_.Exception.Message -match 'needs root')
        }

        return $false
    }
    if (-not (Test-UnelevatedLinuxDefaultRestore)) {
        throw 'Restoring the Linux default policy file did not require root.'
    }

    # Previews annotate each policy with its current state when the target is readable.
    $statePolicyPath = Join-Path $tempRoot 'state-policy.json'
    [ordered]@{
        BraveRewardsDisabled = $true
        BraveWalletDisabled = $false
    } | ConvertTo-Json | Set-Content -LiteralPath $statePolicyPath -Encoding UTF8
    $stateOutput = (& $scriptPath -Platform Linux -PolicyPath $statePolicyPath -OnlyFeature Rewards,Wallet,VPN *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $stateOutput -Expected 'Would set BraveRewardsDisabled = 1' -Context 'state annotation output'
    Assert-TextContains -Text $stateOutput -Expected 'Already set, no change.' -Context 'state annotation output'
    Assert-TextContains -Text $stateOutput -Expected 'Would set BraveWalletDisabled = 1' -Context 'state annotation output'
    Assert-TextContains -Text $stateOutput -Expected 'Currently 0.' -Context 'state annotation output'
    Assert-TextContains -Text $stateOutput -Expected 'Would set BraveVPNDisabled = 1' -Context 'state annotation output'
    Assert-TextContains -Text $stateOutput -Expected 'Currently not set.' -Context 'state annotation output'
    Assert-TextContains -Text $stateOutput -Expected '3 policy value(s) planned (1 already set)' -Context 'state annotation summary'
    Assert-TextDoesNotContain -Text $malformedDryRunOutput -Unexpected 'Currently' -Context 'malformed policy file state annotations'

    # Restores write managed values back with their recorded JSON type: an integer policy that was
    # 0 must not come back as `false`, and a boolean policy must stay a boolean.
    $typePolicyPath = Join-Path $tempRoot 'type-policy.json'
    $typeBackupDirectory = Join-Path $tempRoot 'TypeBackups'
    [System.IO.File]::WriteAllText($typePolicyPath, '{"BraveRewardsDisabled":false,"NetworkPredictionOptions":0}', $utf8NoBom)
    $typeDryRun = (& $scriptPath -Platform Linux -PolicyPath $typePolicyPath -OnlyFeature Rewards,NetworkPrediction *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $typeDryRun -Expected 'Would set NetworkPredictionOptions = 2 (Disable network prediction and preconnect.) Currently 0.' -Context 'integer policy state annotation'
    & $scriptPath -Platform Linux -PolicyPath $typePolicyPath -OnlyFeature Rewards,NetworkPrediction -BackupDirectory $typeBackupDirectory -Apply *>&1 | Out-Null
    $typeAppliedJson = Get-Content -LiteralPath $typePolicyPath -Raw | ConvertFrom-Json
    if ($typeAppliedJson.BraveRewardsDisabled -isnot [bool] -or $typeAppliedJson.NetworkPredictionOptions -is [bool] -or [int]$typeAppliedJson.NetworkPredictionOptions -ne 2) {
        throw 'Apply did not write BraveRewardsDisabled as a boolean and NetworkPredictionOptions as the integer 2.'
    }
    $typeBackup = @(Get-ChildItem -LiteralPath $typeBackupDirectory -Filter 'BraveDebloater-*.json')[0].FullName
    & $scriptPath -UndoFromBackup $typeBackup -PolicyPath $typePolicyPath -Apply *>&1 | Out-Null
    $typeRestoredJson = Get-Content -LiteralPath $typePolicyPath -Raw | ConvertFrom-Json
    if ($typeRestoredJson.BraveRewardsDisabled -isnot [bool] -or $typeRestoredJson.BraveRewardsDisabled) {
        throw 'Restore did not bring BraveRewardsDisabled back to boolean false.'
    }
    if ($typeRestoredJson.NetworkPredictionOptions -is [bool] -or [int]$typeRestoredJson.NetworkPredictionOptions -ne 0) {
        throw "Restore wrote NetworkPredictionOptions as '$($typeRestoredJson.NetworkPredictionOptions)' instead of the integer 0."
    }

    # The profile preference hint appears only when a selected feature has profile patches.
    Assert-TextContains -Text $onlyDryRunOutput -Expected 'Add -IncludeProfilePreferences' -Context 'profile preference hint'
    $vpnOnlyOutput = (& $scriptPath -OnlyFeature VPN *>&1 | Out-String -Width 4096)
    Assert-TextDoesNotContain -Text $vpnOnlyOutput -Unexpected 'Add -IncludeProfilePreferences' -Context 'profile preference hint for VPN'
    Assert-TextDoesNotContain -Text $utf8ApplyOutput -Unexpected 'Add -IncludeProfilePreferences' -Context 'profile preference hint when included'

    # A forced platform with no known profile root explains what to pass instead of printing an empty path.
    # The Windows root comes from LOCALAPPDATA, so clear it while this runs to get the same result on Windows.
    $savedLocalAppData = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = ''
        $blankRootOutput = (& $scriptPath -Platform Windows -OnlyFeature Rewards -IncludeProfilePreferences *>&1 | Out-String -Width 4096)
    }
    finally {
        $env:LOCALAPPDATA = $savedLocalAppData
    }
    Assert-TextContains -Text $blankRootOutput -Expected 'No Brave profile root is known for this platform' -Context 'blank profile root output'
    Assert-TextContains -Text $blankRootOutput -Expected 'Dry-run complete.' -Context 'blank profile root output'

    # Exports never write to the policy target, so -Apply is ignored instead of demanding elevation or MDM.
    $androidApplyExportPath = Join-Path $tempRoot 'brave-android-apply-export.json'
    $androidApplyExportOutput = (& $scriptPath -Platform Android -OnlyFeature Rewards -Apply -ExportPolicyPath $androidApplyExportPath *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $androidApplyExportOutput -Expected '-Apply was ignored' -Context 'Android export with -Apply output'
    Assert-TextContains -Text $androidApplyExportOutput -Expected 'Exported 1 policy value(s) for Android' -Context 'Android export with -Apply output'
    if (-not (Test-Path -LiteralPath $androidApplyExportPath)) {
        throw 'Android export with -Apply did not write the export file.'
    }
    function Test-UnelevatedExportTarget {
        . (Join-Path $root 'src/Common.ps1')
        . (Join-Path $root 'src/PlatformPolicy.ps1')
        function Test-IsAdministrator { return $false }

        $writeRejected = $false
        try {
            Get-PolicyTarget -PlatformName Linux -ScopeName LocalMachine -OverridePath '' -Apply | Out-Null
        }
        catch {
            $writeRejected = $_.Exception.Message -match 'need root'
        }
        if (-not $writeRejected) {
            return $false
        }

        $target = Get-PolicyTarget -PlatformName Linux -ScopeName LocalMachine -OverridePath '' -ReadOnly
        return ($target.Path -eq '/etc/brave/policies/managed/BraveDebloater.json')
    }
    if (-not (Test-UnelevatedExportTarget)) {
        throw 'Unelevated target construction did not reject writes and allow read-only exports for the Linux default path.'
    }

    # A relative -PolicyPath resolves to the same full path for the target, backups, and restores.
    $relativePolicyName = 'relative-policy.json'
    $relativeBackupDirectory = Join-Path $tempRoot 'RelativeBackups'
    Push-Location -LiteralPath $tempRoot
    try {
        $relativeApplyOutput = (& $scriptPath -Platform Linux -PolicyPath (Join-Path '.' $relativePolicyName) -OnlyFeature Rewards -BackupDirectory $relativeBackupDirectory -Apply *>&1 | Out-String -Width 4096)
        Assert-TextContains -Text $relativeApplyOutput -Expected (Join-Path $tempRoot $relativePolicyName) -Context 'relative -PolicyPath apply output'
        $relativeBackup = @(Get-ChildItem -LiteralPath $relativeBackupDirectory -Filter 'BraveDebloater-*.json')[0].FullName
        $relativeBackupJson = Get-Content -LiteralPath $relativeBackup -Raw | ConvertFrom-Json
        if ([string]$relativeBackupJson.registryPath -ne (Join-Path $tempRoot $relativePolicyName)) {
            throw "Backup recorded '$($relativeBackupJson.registryPath)' instead of the full policy path."
        }
        $relativeRestoreOutput = (& $scriptPath -UndoFromBackup $relativeBackup -PolicyPath (Join-Path '.' $relativePolicyName) *>&1 | Out-String -Width 4096)
        Assert-TextContains -Text $relativeRestoreOutput -Expected 'Would remove BraveRewardsDisabled' -Context 'relative -PolicyPath restore output'
    }
    finally {
        Pop-Location
    }

    # Doctor reports the value kind of managed JSON entries from their JSON type.
    $doctorKindPolicyPath = Join-Path $tempRoot 'doctor-kind-policy.json'
    [ordered]@{
        BraveRewardsDisabled = $true
        HomepageLocation = 'https://example.invalid'
    } | ConvertTo-Json | Set-Content -LiteralPath $doctorKindPolicyPath -Encoding UTF8
    $doctorKindOutput = (& $scriptPath -Doctor -Platform Linux -PolicyPath $doctorKindPolicyPath -ProfileRoot $missingProfileRoot -BackupDirectory (Join-Path $tempRoot 'DoctorKindBackups') *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $doctorKindOutput -Expected 'Unknown Brave policies: detected' -Context 'Doctor JSON kind output'
    Assert-TextContains -Text $doctorKindOutput -Expected 'HomepageLocation' -Context 'Doctor JSON kind output'
    Assert-TextContains -Text $doctorKindOutput -Expected 'String' -Context 'Doctor JSON kind output'
    Assert-TextDoesNotContain -Text $doctorKindOutput -Unexpected 'CurrentUser policies:' -Context 'Doctor Linux -PolicyPath output'

    # DNS control is opt-in and never part of a preset.
    $defaultDryRun = (& $scriptPath -Platform Linux -PolicyPath (Join-Path $tempRoot 'dns-absent.json') *>&1 | Out-String -Width 4096)
    Assert-TextDoesNotContain -Text $defaultDryRun -Unexpected 'DnsOverHttps' -Context 'default preset dry-run'

    $dnsPolicyPath = Join-Path $tempRoot 'dns-policy.json'
    $dnsBackupDirectory = Join-Path $tempRoot 'DnsBackups'
    $dnsResolver = 'https://dns.quad9.net/dns-query'
    $dnsSecurePreview = (& $scriptPath -Platform Linux -PolicyPath $dnsPolicyPath -OnlyFeature Rewards -DnsOverHttps Secure -DnsOverHttpsTemplates $dnsResolver *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $dnsSecurePreview -Expected "DNS over HTTPS: Secure with resolver $dnsResolver." -Context 'DNS secure preview'
    Assert-TextContains -Text $dnsSecurePreview -Expected 'Would set DnsOverHttpsMode = secure' -Context 'DNS secure preview'
    Assert-TextContains -Text $dnsSecurePreview -Expected "Would set DnsOverHttpsTemplates = $dnsResolver" -Context 'DNS secure preview'
    Assert-TextContains -Text $dnsSecurePreview -Expected '3 policy value(s) planned' -Context 'DNS secure preview summary'
    if (Test-Path -LiteralPath $dnsPolicyPath) {
        throw 'DNS control dry-run wrote the policy file.'
    }

    & $scriptPath -Platform Linux -PolicyPath $dnsPolicyPath -OnlyFeature Rewards -DnsOverHttps Secure -DnsOverHttpsTemplates $dnsResolver -BackupDirectory $dnsBackupDirectory -Apply *>&1 | Out-Null
    $dnsAppliedJson = Get-Content -LiteralPath $dnsPolicyPath -Raw | ConvertFrom-Json
    if ([string]$dnsAppliedJson.DnsOverHttpsMode -ne 'secure' -or [string]$dnsAppliedJson.DnsOverHttpsTemplates -ne $dnsResolver) {
        throw 'Apply did not write the DNS-over-HTTPS mode and resolver template as strings.'
    }

    # Switching to a mode without templates removes a leftover custom resolver.
    $dnsAutomaticPreview = (& $scriptPath -Platform Linux -PolicyPath $dnsPolicyPath -OnlyFeature Rewards -DnsOverHttps Automatic *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $dnsAutomaticPreview -Expected 'Would set DnsOverHttpsMode = automatic' -Context 'DNS automatic preview'
    Assert-TextContains -Text $dnsAutomaticPreview -Expected 'Currently secure.' -Context 'DNS automatic preview'
    Assert-TextContains -Text $dnsAutomaticPreview -Expected 'Would remove DnsOverHttpsTemplates so Brave settings control it again.' -Context 'DNS automatic preview'
    Assert-TextContains -Text $dnsAutomaticPreview -Expected '1 DNS policy value(s) to remove' -Context 'DNS automatic preview summary'
    $dnsAutomaticApply = (& $scriptPath -Platform Linux -PolicyPath $dnsPolicyPath -OnlyFeature Rewards -DnsOverHttps Automatic -BackupDirectory $dnsBackupDirectory -Apply *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $dnsAutomaticApply -Expected 'Removed 1 DNS policy value(s).' -Context 'DNS automatic apply'
    $dnsAutomaticJson = Get-Content -LiteralPath $dnsPolicyPath -Raw | ConvertFrom-Json
    if ([string]$dnsAutomaticJson.DnsOverHttpsMode -ne 'automatic' -or $null -ne $dnsAutomaticJson.PSObject.Properties['DnsOverHttpsTemplates']) {
        throw 'Switching to Automatic did not update the mode and remove the resolver template.'
    }

    # Unmanaged removes both policies; the backup taken first restores the previous state.
    $dnsUnmanagedApply = (& $scriptPath -Platform Linux -PolicyPath $dnsPolicyPath -OnlyFeature Rewards -DnsOverHttps Unmanaged -BackupDirectory $dnsBackupDirectory -Apply *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $dnsUnmanagedApply -Expected 'DNS over HTTPS: Unmanaged.' -Context 'DNS unmanaged apply'
    Assert-TextContains -Text $dnsUnmanagedApply -Expected 'Removed DnsOverHttpsMode.' -Context 'DNS unmanaged apply'
    $dnsUnmanagedJson = Get-Content -LiteralPath $dnsPolicyPath -Raw | ConvertFrom-Json
    if ($null -ne $dnsUnmanagedJson.PSObject.Properties['DnsOverHttpsMode'] -or $null -ne $dnsUnmanagedJson.PSObject.Properties['DnsOverHttpsTemplates']) {
        throw 'Unmanaged did not remove the DNS-over-HTTPS policies.'
    }
    $dnsBackups = @(Get-ChildItem -LiteralPath $dnsBackupDirectory -Filter 'BraveDebloater-*.json' | Sort-Object Name)
    if ($dnsBackups.Count -ne 3) {
        throw "Expected 3 DNS control backups, found $($dnsBackups.Count)."
    }
    & $scriptPath -UndoFromBackup $dnsBackups[1].FullName -PolicyPath $dnsPolicyPath -Apply *>&1 | Out-Null
    $dnsRestoredJson = Get-Content -LiteralPath $dnsPolicyPath -Raw | ConvertFrom-Json
    if ([string]$dnsRestoredJson.DnsOverHttpsMode -ne 'secure' -or [string]$dnsRestoredJson.DnsOverHttpsTemplates -ne $dnsResolver) {
        throw 'Restoring the pre-Automatic backup did not bring back the secure mode and resolver template.'
    }

    # .reg exports carry the string policies.
    $dnsRegExportPath = Join-Path $tempRoot 'dns-export.reg'
    & $scriptPath -Platform Windows -OnlyFeature Rewards -ProfileRoot $missingProfileRoot -DnsOverHttps Secure -DnsOverHttpsTemplates $dnsResolver -ExportPolicyPath $dnsRegExportPath *>&1 | Out-Null
    $dnsRegDocument = [System.IO.File]::ReadAllText($dnsRegExportPath, [System.Text.Encoding]::Unicode)
    Assert-TextContains -Text $dnsRegDocument -Expected '"DnsOverHttpsMode"="secure"' -Context 'DNS .reg export'
    Assert-TextContains -Text $dnsRegDocument -Expected "`"DnsOverHttpsTemplates`"=`"$dnsResolver`"" -Context 'DNS .reg export'

    # .reg exports delete the policies a mode removes; other formats say the removal must be done by hand.
    $dnsRegRemovePath = Join-Path $tempRoot 'dns-remove.reg'
    $dnsRegRemoveOutput = (& $scriptPath -Platform Windows -OnlyFeature Rewards -ProfileRoot $missingProfileRoot -DnsOverHttps Unmanaged -ExportPolicyPath $dnsRegRemovePath *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $dnsRegRemoveOutput -Expected 'also deletes DnsOverHttpsMode and DnsOverHttpsTemplates when imported' -Context 'DNS Unmanaged .reg export output'
    $dnsRegRemoveDocument = [System.IO.File]::ReadAllText($dnsRegRemovePath, [System.Text.Encoding]::Unicode)
    Assert-TextContains -Text $dnsRegRemoveDocument -Expected '"DnsOverHttpsMode"=-' -Context 'DNS Unmanaged .reg export'
    Assert-TextContains -Text $dnsRegRemoveDocument -Expected '"DnsOverHttpsTemplates"=-' -Context 'DNS Unmanaged .reg export'
    $dnsRegAutomaticPath = Join-Path $tempRoot 'dns-automatic.reg'
    & $scriptPath -Platform Windows -OnlyFeature Rewards -ProfileRoot $missingProfileRoot -DnsOverHttps Automatic -ExportPolicyPath $dnsRegAutomaticPath *>&1 | Out-Null
    $dnsRegAutomaticDocument = [System.IO.File]::ReadAllText($dnsRegAutomaticPath, [System.Text.Encoding]::Unicode)
    Assert-TextContains -Text $dnsRegAutomaticDocument -Expected '"DnsOverHttpsMode"="automatic"' -Context 'DNS Automatic .reg export'
    Assert-TextContains -Text $dnsRegAutomaticDocument -Expected '"DnsOverHttpsTemplates"=-' -Context 'DNS Automatic .reg export'
    $dnsJsonExportPath = Join-Path $tempRoot 'dns-automatic-export.json'
    $dnsJsonExportOutput = (& $scriptPath -Platform Linux -OnlyFeature Rewards -DnsOverHttps Automatic -ExportPolicyPath $dnsJsonExportPath *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $dnsJsonExportOutput -Expected 'export cannot remove policies. Remove DnsOverHttpsTemplates' -Context 'DNS JSON export warning'

    # iOS exports reject DNS control even when it only removes policies.
    $dnsIosRejected = ''
    try {
        & $scriptPath -Platform iOS -OnlyFeature Rewards -DnsOverHttps Unmanaged -ExportPolicyPath (Join-Path $tempRoot 'dns-ios.mobileconfig') | Out-Null
    }
    catch {
        $dnsIosRejected = $_.Exception.Message
    }
    Assert-TextContains -Text $dnsIosRejected -Expected 'DnsOverHttpsMode' -Context 'iOS DNS Unmanaged export rejection'

    # Invalid DNS control combinations stop before anything is planned.
    $dnsErrorCases = @(
        @{ Arguments = @{ DnsOverHttps = 'Secure' }; Expected = 'needs -DnsOverHttpsTemplates' },
        @{ Arguments = @{ DnsOverHttpsTemplates = $dnsResolver }; Expected = 'needs -DnsOverHttps Secure or Automatic' },
        @{ Arguments = @{ DnsOverHttps = 'Off'; DnsOverHttpsTemplates = $dnsResolver }; Expected = 'has no effect with -DnsOverHttps Off' },
        @{ Arguments = @{ DnsOverHttps = 'Unmanaged'; DnsOverHttpsTemplates = $dnsResolver }; Expected = 'cannot be combined with -DnsOverHttps Unmanaged' },
        @{ Arguments = @{ DnsOverHttps = 'Secure'; DnsOverHttpsTemplates = 'http://insecure.invalid/dns-query' }; Expected = 'is not an https:// URI' },
        @{ Arguments = @{ DnsOverHttps = 'Secure'; DnsOverHttpsTemplates = 'https://dns.example/dns query' }; Expected = 'is not an https:// URI' },
        @{ Arguments = @{ DnsOverHttps = 'Secure'; DnsOverHttpsTemplates = 'https:///dns-query' }; Expected = 'is not an https:// URI' },
        @{ Arguments = @{ DnsOverHttps = 'Secure'; DnsOverHttpsTemplates = 'https://' }; Expected = 'is not an https:// URI' }
    )
    $dnsTemplateVariantOutput = (& $scriptPath -Platform Linux -PolicyPath $dnsPolicyPath -OnlyFeature Rewards -DnsOverHttps Secure -DnsOverHttpsTemplates 'https://dns.google/dns-query{?dns}' *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $dnsTemplateVariantOutput -Expected 'Would set DnsOverHttpsTemplates = https://dns.google/dns-query{?dns}' -Context 'DNS template with URI variable'
    foreach ($dnsErrorCase in $dnsErrorCases) {
        $dnsErrorMessage = ''
        $dnsErrorArguments = $dnsErrorCase.Arguments
        try {
            & $scriptPath -Platform Linux -PolicyPath $dnsPolicyPath -OnlyFeature Rewards @dnsErrorArguments | Out-Null
        }
        catch {
            $dnsErrorMessage = $_.Exception.Message
        }
        Assert-TextContains -Text $dnsErrorMessage -Expected $dnsErrorCase.Expected -Context "DNS control error for $(($dnsErrorArguments.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' ')"
    }

    # `powershell -File` and the BraveDebloat.exe launcher pass "News,LeoAI" as one literal string.
    $commaExcludeOutput = (& $scriptPath -Preset Extreme -ExcludeFeature 'News,LeoAI' -List *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $commaExcludeOutput -Expected 'BraveRewardsDisabled' -Context 'comma-separated -ExcludeFeature output'
    Assert-TextDoesNotContain -Text $commaExcludeOutput -Unexpected 'BraveNewsDisabled' -Context 'comma-separated -ExcludeFeature output'
    Assert-TextDoesNotContain -Text $commaExcludeOutput -Unexpected 'BraveAIChatEnabled' -Context 'comma-separated -ExcludeFeature output'
    $commaOnlyOutput = (& $scriptPath -OnlyFeature 'Rewards, Wallet' -List *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $commaOnlyOutput -Expected 'BraveRewardsDisabled' -Context 'comma-separated -OnlyFeature output'
    Assert-TextContains -Text $commaOnlyOutput -Expected 'BraveWalletDisabled' -Context 'comma-separated -OnlyFeature output'
    Assert-TextDoesNotContain -Text $commaOnlyOutput -Unexpected 'BraveVPNDisabled' -Context 'comma-separated -OnlyFeature output'

    # install.ps1 from a local release archive: checksum verification, extraction, upgrades that keep backups/.
    $installScriptPath = Join-Path $root 'install.ps1'
    $installRoot = Join-Path $tempRoot 'Install'
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function New-FakeReleaseArchive {
        param([string]$Version, [string]$Folder)
        $treeRoot = Join-Path $Folder "tree-$Version"
        $tree = Join-Path $treeRoot "BraveDebloater-v$Version"
        New-Item -ItemType Directory -Path (Join-Path $tree 'src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'Invoke-BraveDebloat.ps1') -Value "`$ToolVersion = '$Version'" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $tree "src/Release-$Version.ps1") -Value '# release file' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $tree 'LICENSE') -Value 'MIT' -Encoding ASCII
        $archivePath = Join-Path $Folder "BraveDebloater-v$Version.zip"
        [System.IO.Compression.ZipFile]::CreateFromDirectory($treeRoot, $archivePath)
        $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $Folder 'SHA256SUMS.txt') -Value "$hash  BraveDebloater-v$Version.zip" -Encoding ASCII
        return $archivePath
    }
    $firstArchiveFolder = Join-Path $installRoot 'first'
    New-Item -ItemType Directory -Path $firstArchiveFolder -Force | Out-Null
    $firstArchive = New-FakeReleaseArchive -Version '9.9.9' -Folder $firstArchiveFolder
    $installDestination = Join-Path $installRoot 'Destination'
    $installOutput = (& $installScriptPath -ArchivePath $firstArchive -Destination $installDestination *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $installOutput -Expected 'Checksum OK: BraveDebloater-v9.9.9.zip' -Context 'install.ps1 first install output'
    Assert-TextContains -Text $installOutput -Expected "Installed BraveDebloater 9.9.9 to $installDestination" -Context 'install.ps1 first install output'
    Assert-TextContains -Text $installOutput -Expected 'Nothing is written until you add -Apply.' -Context 'install.ps1 first install output'
    if (-not (Test-Path -LiteralPath (Join-Path $installDestination 'src/Release-9.9.9.ps1'))) {
        throw 'install.ps1 did not extract the release tree into the destination.'
    }

    New-Item -ItemType Directory -Path (Join-Path $installDestination 'backups') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $installDestination 'backups/keep.json') -Value '{}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $installDestination 'notes.txt') -Value 'mine' -Encoding UTF8
    $secondArchiveFolder = Join-Path $installRoot 'second'
    New-Item -ItemType Directory -Path $secondArchiveFolder -Force | Out-Null
    $secondArchive = New-FakeReleaseArchive -Version '9.9.10' -Folder $secondArchiveFolder
    $upgradeOutput = (& $installScriptPath -ArchivePath $secondArchive -Destination $installDestination *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $upgradeOutput -Expected 'Updated BraveDebloater 9.9.9 -> 9.9.10' -Context 'install.ps1 upgrade output'
    Assert-TextContains -Text $upgradeOutput -Expected 'Existing backups were kept.' -Context 'install.ps1 upgrade output'
    foreach ($keptPath in @('backups/keep.json', 'notes.txt', 'src/Release-9.9.10.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $installDestination $keptPath))) {
            throw "install.ps1 upgrade lost $keptPath."
        }
    }
    if (Test-Path -LiteralPath (Join-Path $installDestination 'src/Release-9.9.9.ps1')) {
        throw 'install.ps1 upgrade left a stale file inside a replaced folder.'
    }

    # A failed upgrade must leave the previous install intact. Windows blocks moving a file that is open
    # without FileShare.Delete, which fails the swap after staging (LICENSE is only moved, never read, so
    # the lock cannot trip the version detection first); elsewhere a read-only destination fails the
    # staging copy before anything is touched. Root ignores permissions, so that case is skipped.
    $rollbackDestination = Join-Path $installRoot 'Rollback'
    & $installScriptPath -ArchivePath $firstArchive -Destination $rollbackDestination *> $null
    New-Item -ItemType Directory -Path (Join-Path $rollbackDestination 'backups') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $rollbackDestination 'backups/keep.json') -Value '{}' -Encoding UTF8
    $rollbackLock = $null
    $rollbackReadOnly = $false
    if ($env:OS -eq 'Windows_NT') {
        $rollbackLock = [System.IO.File]::Open((Join-Path $rollbackDestination 'LICENSE'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    }
    elseif ((& id -u) -ne '0') {
        & chmod 555 $rollbackDestination
        $rollbackReadOnly = $true
    }
    if ($null -ne $rollbackLock -or $rollbackReadOnly) {
        $rollbackMessage = ''
        try {
            & $installScriptPath -ArchivePath $secondArchive -Destination $rollbackDestination *> $null
        }
        catch {
            $rollbackMessage = $_.Exception.Message
        }
        finally {
            if ($null -ne $rollbackLock) {
                $rollbackLock.Dispose()
            }
            if ($rollbackReadOnly) {
                & chmod 755 $rollbackDestination
            }
        }
        if ($null -ne $rollbackLock) {
            Assert-TextContains -Text $rollbackMessage -Expected 'The previous files were restored and nothing changed.' -Context "install.ps1 failed swap (got: $rollbackMessage)"
        }
        else {
            Assert-TextContains -Text $rollbackMessage -Expected 'The existing files were not touched.' -Context "install.ps1 failed staging copy (got: $rollbackMessage)"
        }
        if ((Get-Content -LiteralPath (Join-Path $rollbackDestination 'Invoke-BraveDebloat.ps1') -Raw) -notmatch '9\.9\.9') {
            throw 'install.ps1 left a failed upgrade half applied (entrypoint changed).'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $rollbackDestination 'src/Release-9.9.9.ps1')) -or (Test-Path -LiteralPath (Join-Path $rollbackDestination 'src/Release-9.9.10.ps1'))) {
            throw 'install.ps1 left a failed upgrade half applied (src changed).'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $rollbackDestination 'backups/keep.json'))) {
            throw 'install.ps1 lost backups during a failed upgrade.'
        }
        if (@(Get-ChildItem -LiteralPath $rollbackDestination -Force -Filter '.install-*').Count -ne 0) {
            throw 'install.ps1 left staging folders behind after a failed upgrade.'
        }
    }

    $tamperedChecksumPath = Join-Path $installRoot 'tampered-SHA256SUMS.txt'
    Set-Content -LiteralPath $tamperedChecksumPath -Value ('{0}  BraveDebloater-v9.9.9.zip' -f ('0' * 64)) -Encoding ASCII
    $installErrorCases = @(
        @{ Arguments = @{ ArchivePath = $firstArchive; ChecksumPath = $tamperedChecksumPath }; Expected = 'Checksum mismatch for BraveDebloater-v9.9.9.zip' },
        @{ Arguments = @{ ArchivePath = $firstArchive; ChecksumPath = (Join-Path $secondArchiveFolder 'SHA256SUMS.txt') }; Expected = 'has no SHA256 entry for BraveDebloater-v9.9.9.zip' },
        @{ Arguments = @{ ArchivePath = $firstArchive; Version = '9.9.9' }; Expected = '-Version has no effect with -ArchivePath' },
        @{ Arguments = @{ ArchivePath = (Join-Path $installRoot 'missing.zip') }; Expected = 'Archive not found' }
    )
    foreach ($installErrorCase in $installErrorCases) {
        $installErrorMessage = ''
        $installErrorArguments = $installErrorCase.Arguments
        try {
            & $installScriptPath -Destination (Join-Path $installRoot 'ErrorDestination') @installErrorArguments *> $null
        }
        catch {
            $installErrorMessage = $_.Exception.Message
        }
        Assert-TextContains -Text $installErrorMessage -Expected $installErrorCase.Expected -Context "install.ps1 error for $(($installErrorArguments.Keys | Sort-Object) -join ', ')"
    }
    if (Test-Path -LiteralPath (Join-Path $installRoot 'ErrorDestination/Invoke-BraveDebloat.ps1')) {
        throw 'install.ps1 installed files although a check failed.'
    }
    if ((Get-Content -LiteralPath (Join-Path $installDestination 'Invoke-BraveDebloat.ps1') -Raw) -notmatch "9\.9\.10") {
        throw 'install.ps1 changed an existing install while a check failed.'
    }
    $foreignDestination = Join-Path $installRoot 'Foreign'
    New-Item -ItemType Directory -Path $foreignDestination -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $foreignDestination 'other.txt') -Value 'not ours' -Encoding UTF8
    $foreignMessage = ''
    try {
        & $installScriptPath -ArchivePath $firstArchive -Destination $foreignDestination *> $null
    }
    catch {
        $foreignMessage = $_.Exception.Message
    }
    Assert-TextContains -Text $foreignMessage -Expected 'does not contain Invoke-BraveDebloat.ps1' -Context 'install.ps1 non-empty foreign destination'
    if (Test-Path -LiteralPath (Join-Path $foreignDestination 'Invoke-BraveDebloat.ps1')) {
        throw 'install.ps1 wrote into a folder that is not a BraveDebloater install.'
    }

    # New-PackageManifests.ps1 writes the winget manifests and the Scoop manifest from SHA256SUMS.txt.
    $packageRoot = Join-Path $tempRoot 'Packages'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    $packageChecksumPath = Join-Path $packageRoot 'SHA256SUMS.txt'
    Set-Content -LiteralPath $packageChecksumPath -Value @(
        ('{0}  BraveDebloater-v1.2.3.zip' -f ('a' * 64)),
        ('{0}  BraveDebloater-v1.2.3-windows.zip' -f ('b' * 64))
    ) -Encoding ASCII
    $packageScoopPath = Join-Path $packageRoot 'scoop/bravedebloater.json'
    $packageWingetPath = Join-Path $packageRoot 'winget'
    & (Join-Path $root 'scripts/New-PackageManifests.ps1') -Version v1.2.3 -ChecksumPath $packageChecksumPath -ReleaseDate 2026-01-02 -WingetOutputPath $packageWingetPath -ScoopManifestPath $packageScoopPath *> $null
    $wingetDirectory = Join-Path $packageWingetPath 'o/osfv/BraveDebloater/1.2.3'
    $installerManifest = Get-Content -LiteralPath (Join-Path $wingetDirectory 'osfv.BraveDebloater.installer.yaml') -Raw
    foreach ($expectedLine in @(
            'PackageIdentifier: osfv.BraveDebloater',
            'PackageVersion: 1.2.3',
            'InstallerType: zip',
            'NestedInstallerType: portable',
            'RelativeFilePath: BraveDebloat.exe',
            'ArchiveBinariesDependOnPath: true',
            'ReleaseDate: 2026-01-02',
            'InstallerUrl: https://github.com/osfv/BraveDebloater/releases/download/v1.2.3/BraveDebloater-v1.2.3-windows.zip',
            ('InstallerSha256: {0}' -f ('B' * 64)),
            'ManifestVersion: 1.10.0')) {
        Assert-TextContains -Text $installerManifest -Expected $expectedLine -Context 'winget installer manifest'
    }
    $versionManifest = Get-Content -LiteralPath (Join-Path $wingetDirectory 'osfv.BraveDebloater.yaml') -Raw
    Assert-TextContains -Text $versionManifest -Expected 'ManifestType: version' -Context 'winget version manifest'
    Assert-TextContains -Text $versionManifest -Expected 'DefaultLocale: en-US' -Context 'winget version manifest'
    $localeManifest = Get-Content -LiteralPath (Join-Path $wingetDirectory 'osfv.BraveDebloater.locale.en-US.yaml') -Raw
    Assert-TextContains -Text $localeManifest -Expected 'ManifestType: defaultLocale' -Context 'winget locale manifest'
    Assert-TextContains -Text $localeManifest -Expected 'License: MIT' -Context 'winget locale manifest'
    Assert-TextContains -Text $localeManifest -Expected 'ReleaseNotesUrl: https://github.com/osfv/BraveDebloater/releases/tag/v1.2.3' -Context 'winget locale manifest'
    $generatedScoop = Get-Content -LiteralPath $packageScoopPath -Raw | ConvertFrom-Json
    if ([string]$generatedScoop.version -ne '1.2.3' -or [string]$generatedScoop.hash -ne ('a' * 64) -or [string]$generatedScoop.extract_dir -ne 'BraveDebloater-v1.2.3') {
        throw 'New-PackageManifests.ps1 wrote a Scoop manifest with the wrong version, hash, or extract_dir.'
    }
    $scoopBytes = [System.IO.File]::ReadAllBytes($packageScoopPath)
    if ($scoopBytes.Length -ge 3 -and $scoopBytes[0] -eq 0xef -and $scoopBytes[1] -eq 0xbb -and $scoopBytes[2] -eq 0xbf) {
        throw 'New-PackageManifests.ps1 wrote a UTF-8 BOM.'
    }
    # Releases without a Windows zip only get the Scoop manifest.
    Set-Content -LiteralPath $packageChecksumPath -Value ('{0}  BraveDebloater-v1.2.4.zip' -f ('c' * 64)) -Encoding ASCII
    $scoopOnlyOutput = (& (Join-Path $root 'scripts/New-PackageManifests.ps1') -Version 1.2.4 -ChecksumPath $packageChecksumPath -WingetOutputPath $packageWingetPath -ScoopManifestPath $packageScoopPath *>&1 | Out-String -Width 4096)
    Assert-TextContains -Text $scoopOnlyOutput -Expected 'no winget manifests were written' -Context 'New-PackageManifests.ps1 without a Windows zip'
    if (Test-Path -LiteralPath (Join-Path $packageWingetPath 'o/osfv/BraveDebloater/1.2.4')) {
        throw 'New-PackageManifests.ps1 wrote winget manifests without a Windows zip hash.'
    }

    # The committed Scoop manifest must point at a real release layout.
    $committedScoop = Get-Content -LiteralPath (Join-Path $root 'packaging/scoop/bravedebloater.json') -Raw | ConvertFrom-Json
    $committedScoopVersion = [string]$committedScoop.version
    if ($committedScoopVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "packaging/scoop/bravedebloater.json has an invalid version '$committedScoopVersion'."
    }
    if ([string]$committedScoop.url -ne "https://github.com/osfv/BraveDebloater/releases/download/v$committedScoopVersion/BraveDebloater-v$committedScoopVersion.zip") {
        throw 'packaging/scoop/bravedebloater.json url does not match its version.'
    }
    if ([string]$committedScoop.extract_dir -ne "BraveDebloater-v$committedScoopVersion") {
        throw 'packaging/scoop/bravedebloater.json extract_dir does not match its version.'
    }
    if ([string]$committedScoop.hash -notmatch '^[0-9a-f]{64}$') {
        throw 'packaging/scoop/bravedebloater.json hash is not a lowercase SHA256.'
    }
    if ([string]$committedScoop.bin[0][0] -ne 'Invoke-BraveDebloat.ps1' -or [string]$committedScoop.persist -ne 'backups') {
        throw 'packaging/scoop/bravedebloater.json must shim Invoke-BraveDebloat.ps1 and persist backups.'
    }

    & (Join-Path $root 'tests/WriteSafety.ps1') -TempRoot (Join-Path $tempRoot 'WriteSafety')
    Write-Host 'Behavior checks passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
