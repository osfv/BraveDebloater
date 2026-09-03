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

    $extremeListOutput = (& $scriptPath -Preset Extreme -List *>&1 | Out-String)
    Assert-TextDoesNotContain -Text $extremeListOutput -Unexpected 'PrivacySandboxPromptEnabled' -Context 'Extreme -List output'
    Assert-TextDoesNotContain -Text $extremeListOutput -Unexpected 'PromotionalTabsEnabled' -Context 'Extreme -List output'
    Assert-TextDoesNotContain -Text $extremeListOutput -Unexpected 'IPFSEnabled' -Context 'Extreme -List output'

    $onlyPatchOutput = (& $scriptPath -OnlyFeature Rewards -List -IncludeProfilePreferences *>&1 | Out-String)
    Assert-TextContains -Text $onlyPatchOutput -Expected 'brave.rewards.enabled' -Context '-OnlyFeature profile patch output'
    Assert-TextDoesNotContain -Text $onlyPatchOutput -Unexpected 'brave.new_tab_page.show_branded_background_image' -Context '-OnlyFeature profile patch output'
    Assert-TextDoesNotContain -Text $onlyPatchOutput -Unexpected 'brave.wallet.show_wallet_icon_on_toolbar' -Context '-OnlyFeature profile patch output'

    $onlyDryRunOutput = (& $scriptPath -OnlyFeature Rewards *>&1 | Out-String)
    Assert-TextContains -Text $onlyDryRunOutput -Expected 'Preset: (none - OnlyFeature mode)' -Context '-OnlyFeature dry-run output'
    Assert-TextContains -Text $onlyDryRunOutput -Expected 'Custom features: Rewards' -Context '-OnlyFeature dry-run output'
    Assert-TextDoesNotContain -Text $onlyDryRunOutput -Unexpected 'Preset: Extreme' -Context '-OnlyFeature dry-run output'

    $targetUserSid = 'S-1-5-21-1000-2000-3000-1001'
    $targetUserPath = "Registry::HKEY_USERS\$targetUserSid\Software\Policies\BraveSoftware\Brave"
    $targetUserOutput = (& $scriptPath -Platform Windows -UserSid $targetUserSid -OnlyFeature Rewards -ProfileRoot $missingProfileRoot *>&1 | Out-String)
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

    $targetUserRestoreOutput = (& $scriptPath -Platform Windows -UserSid $targetUserSid -ProfileRoot $missingProfileRoot -UndoFromBackup $targetUserBackup *>&1 | Out-String)
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
    Assert-TextDoesNotContain -Text $linuxApplyOutput -Unexpected 'obsolete' -Context 'Linux policy apply output'

    $leftoverPolicyPath = Join-Path $tempRoot 'leftover-obsolete-policy.json'
    $leftoverBackupDirectory = Join-Path $tempRoot 'LeftoverBackups'
    [ordered]@{
        PrivacySandboxPromptEnabled = $false
        PromotionalTabsEnabled = $false
    } | ConvertTo-Json | Set-Content -LiteralPath $leftoverPolicyPath -Encoding UTF8

    $leftoverDoctorOutput = (& $scriptPath -Doctor -Platform Linux -PolicyPath $leftoverPolicyPath -ProfileRoot $missingProfileRoot -BackupDirectory $leftoverBackupDirectory *>&1 | Out-String)
    Assert-TextContains -Text $leftoverDoctorOutput -Expected 'Obsolete leftover policies: detected. Rerun with -Apply to remove them.' -Context 'Doctor obsolete leftover output'
    Assert-TextContains -Text $leftoverDoctorOutput -Expected 'PrivacySandboxPromptEnabled' -Context 'Doctor obsolete leftover output'
    Assert-TextContains -Text $leftoverDoctorOutput -Expected 'PromotionalTabsEnabled' -Context 'Doctor obsolete leftover output'

    $leftoverDryRunOutput = (& $scriptPath -Platform Linux -PolicyPath $leftoverPolicyPath -OnlyFeature Rewards -BackupDirectory $leftoverBackupDirectory *>&1 | Out-String)
    Assert-TextContains -Text $leftoverDryRunOutput -Expected 'Would remove PrivacySandboxPromptEnabled because Brave marks it obsolete.' -Context 'obsolete leftover dry-run output'
    Assert-TextContains -Text $leftoverDryRunOutput -Expected 'Would remove PromotionalTabsEnabled because Brave marks it obsolete.' -Context 'obsolete leftover dry-run output'
    Assert-TextContains -Text $leftoverDryRunOutput -Expected '2 obsolete leftover(s) to remove' -Context 'obsolete leftover dry-run output'
    $leftoverDryRunJson = Get-Content -LiteralPath $leftoverPolicyPath -Raw | ConvertFrom-Json
    if ($null -eq $leftoverDryRunJson.PSObject.Properties['PrivacySandboxPromptEnabled'] -or $null -eq $leftoverDryRunJson.PSObject.Properties['PromotionalTabsEnabled']) {
        throw 'Dry-run removed leftover obsolete policies.'
    }

    $leftoverApplyOutput = (& $scriptPath -Platform Linux -PolicyPath $leftoverPolicyPath -OnlyFeature Rewards -Apply -BackupDirectory $leftoverBackupDirectory *>&1 | Out-String)
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

    $leftoverRestoreOutput = (& $scriptPath -UndoFromBackup $leftoverBackups[0].FullName -PolicyPath $leftoverPolicyPath *>&1 | Out-String)
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
    $oldDeprecatedRestoreOutput = (& $scriptPath -UndoFromBackup $oldDeprecatedBackup -PolicyPath $leftoverPolicyPath *>&1 | Out-String)
    Assert-TextContains -Text $oldDeprecatedRestoreOutput -Expected 'Would restore PrivacySandboxPromptEnabled' -Context 'old deprecated backup restore dry-run output'

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

    $regExportPath = Join-Path $tempRoot 'brave-policies.reg'
    $regExportOutput = (& $scriptPath -Platform Windows -OnlyFeature Rewards,NetworkPrediction -ProfileRoot $missingProfileRoot -ExportPolicyPath $regExportPath *>&1 | Out-String)
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
    $machinePreview = (& $scriptPath -Platform Windows -Scope LocalMachine -OnlyFeature Rewards -ProfileRoot $missingProfileRoot *>&1 | Out-String)
    Assert-TextContains -Text $machinePreview -Expected 'Scope: LocalMachine (Registry::HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave)' -Context 'unelevated LocalMachine preview'
    Assert-TextContains -Text $machinePreview -Expected 'Dry-run complete.' -Context 'unelevated LocalMachine preview'
    $macMachinePreview = (& $scriptPath -Platform macOS -Scope LocalMachine -OnlyFeature Rewards -ProfileRoot $missingProfileRoot *>&1 | Out-String)
    Assert-TextContains -Text $macMachinePreview -Expected 'Dry-run complete.' -Context 'unelevated macOS LocalMachine preview'
    $linuxDefaultPreview = (& $scriptPath -Platform Linux -OnlyFeature Rewards -ProfileRoot $missingProfileRoot *>&1 | Out-String)
    Assert-TextContains -Text $linuxDefaultPreview -Expected '/etc/brave/policies/managed/BraveDebloater.json' -Context 'unelevated Linux default path preview'
    Assert-TextContains -Text $linuxDefaultPreview -Expected 'Dry-run complete.' -Context 'unelevated Linux default path preview'

    $ignoredPolicyPathOutput = (& $scriptPath -Platform Windows -OnlyFeature Rewards -ProfileRoot $missingProfileRoot -PolicyPath (Join-Path $tempRoot 'ignored.json') *>&1 | Out-String)
    Assert-TextContains -Text $ignoredPolicyPathOutput -Expected '-PolicyPath is ignored for Windows CurrentUser policies' -Context 'ignored -PolicyPath output'
    $linuxPolicyPathOutput = (& $scriptPath -Platform Linux -OnlyFeature Rewards -ProfileRoot $missingProfileRoot -PolicyPath (Join-Path $tempRoot 'used.json') *>&1 | Out-String)
    Assert-TextDoesNotContain -Text $linuxPolicyPathOutput -Unexpected '-PolicyPath is ignored' -Context 'Linux -PolicyPath output'

    # A forced Windows platform on another OS has no LOCALAPPDATA; the run must still preview cleanly.
    $forcedWindowsOutput = (& $scriptPath -Platform Windows -OnlyFeature Rewards *>&1 | Out-String)
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
    $utf8ApplyOutput = (& $scriptPath -Platform Linux -PolicyPath $utf8PolicyPath -OnlyFeature Rewards -IncludeProfilePreferences -ProfileRoot $utf8ProfileRoot -BackupDirectory $utf8BackupDirectory -Apply *>&1 | Out-String)
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
    $utf8RestoreOutput = (& $scriptPath -UndoFromBackup $utf8Backup -PolicyPath $utf8PolicyPath -ProfileRoot $utf8ProfileRoot -Apply *>&1 | Out-String)
    Assert-TextContains -Text $utf8RestoreOutput -Expected 'Restored profile file' -Context 'UTF-8 profile restore output'
    $restoredJson = [System.IO.File]::ReadAllText($utf8Preferences, $utf8NoBom) | ConvertFrom-Json
    if ([string]$restoredJson.profile.name -ne $utf8Name -or $restoredJson.brave.rewards.enabled -ne $true) {
        throw 'Profile restore did not bring back the original Preferences content.'
    }

    Write-Host 'Behavior checks passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
