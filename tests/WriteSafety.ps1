#requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$TempRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'Invoke-BraveDebloat.ps1'
foreach ($module in @('Common', 'Manifest', 'PlatformPolicy', 'Backup', 'ProfilePreferences')) {
    . (Join-Path $root "src/$module.ps1")
}

# Every export format must preserve existing files and avoid creating parent directories in WhatIf.
foreach ($case in @(@{ Platform = 'Windows'; Extension = 'reg' }, @{ Platform = 'Linux'; Extension = 'json' }, @{ Platform = 'macOS'; Extension = 'plist' }, @{ Platform = 'macOS'; Extension = 'mobileconfig' })) {
    $exportDirectory = Join-Path $TempRoot $case.Extension
    $exportPath = Join-Path $exportDirectory ("policies." + $case.Extension)
    & $scriptPath -Platform $case.Platform -OnlyFeature Rewards -ExportPolicyPath $exportPath -WhatIf *> $null
    if (Test-Path -LiteralPath $exportDirectory) { throw 'WhatIf created an export directory.' }
    New-DirectoryLiteral -Path $exportDirectory
    Set-TextFileContent -Path $exportPath -Content 'keep this file'
    & $scriptPath -Platform $case.Platform -OnlyFeature Rewards -ExportPolicyPath $exportPath -Apply -WhatIf *> $null
    if ((Get-Utf8FileContent -Path $exportPath) -cne 'keep this file') { throw 'WhatIf overwrote an export.' }
}

# Read-only modes cannot fall through to destructive retention, restore, or export operations.
$retentionDirectory = Join-Path $TempRoot 'ModeBackups'
New-DirectoryLiteral -Path $retentionDirectory
$retainedFile = Join-Path $retentionDirectory 'BraveDebloater-retain.json'
Set-TextFileContent -Path $retainedFile -Content '{}'
foreach ($parameters in @(
    @{ Doctor = $true; KeepLatestBackups = 0 },
    @{ List = $true; PruneBackupsOlderThanDays = 0 },
    @{ ListFeatures = $true; UndoFromBackup = 'missing.json' },
    @{ Doctor = $true; UndoFromBackup = 'missing.json' },
    @{ UndoFromBackup = 'missing.json'; KeepLatestBackups = 0 },
    @{ ExportPolicyPath = (Join-Path $TempRoot 'conflict.json'); KeepLatestBackups = 0 }
)) {
    $message = ''
    try { & $scriptPath @parameters -Apply -BackupDirectory $retentionDirectory *> $null }
    catch { $message = $_.Exception.Message }
    if ($message -notlike 'Conflicting command modes:*') { throw "Mode conflict was not rejected: $message" }
    if (-not (Test-Path -LiteralPath $retainedFile)) { throw 'Conflicting modes deleted a backup.' }
}
# Listing and retention intentionally remain a single compatible mode.
& $scriptPath -ListBackups -KeepLatestBackups 1 -BackupDirectory $retentionDirectory *> $null

# Use only synthetic profile files; the tests never write to an installed Brave profile.
function Test-BraveRunning { return $false }
$manifest = Get-JsonFileContent -Path (Join-Path $root 'config/policies.json')
$profileRoot = Join-Path $TempRoot 'Profiles'
$firstProfile = Join-Path $profileRoot 'Default/Preferences'
$secondProfile = Join-Path $profileRoot 'Profile 1/Preferences'
$original = '{"brave":{"rewards":{"enabled":true}}}'
Set-TextFileContent -Path $firstProfile -Content $original
Set-TextFileContent -Path $secondProfile -Content $original
$policyPath = Join-Path $TempRoot 'policies.json'
$target = [pscustomobject]@{ Platform = 'Linux'; Kind = 'JsonFile'; Path = $policyPath }
$backupPath = New-Backup -Directory (Join-Path $TempRoot 'Backups') -ScopeName CurrentUser -Target $target -PolicyNames @('BraveRewardsDisabled') -ProfileRoot $profileRoot -Manifest $manifest

# Inject a failure on the second Preferences write, after the first profile was changed.
function Invoke-InterruptedCleanup {
    $writer = (Get-Command Set-JsonFileContent).ScriptBlock
    function Set-JsonFileContent {
        param($Path, $Object, [int]$Depth = 20)
        if ($Path -eq $secondProfile) { throw 'Injected second profile write failure' }
        & $writer -Path $Path -Object $Object -Depth $Depth
    }
    Invoke-ProfilePreferenceCleanup -Root $profileRoot -Manifest $manifest -BackupPath $backupPath -SelectedFeatureIds Rewards -UseFeatureFilter -DoApply
}
$failure = ''
try { Invoke-InterruptedCleanup *> $null }
catch { $failure = $_.Exception.Message }
if ($failure -ne 'Injected second profile write failure') { throw "Unexpected profile failure: $failure" }
if ((Get-JsonFileContent -Path $firstProfile).brave.rewards.enabled -ne $false) { throw 'First profile was not changed before injected failure.' }
$backup = Get-JsonFileContent -Path $backupPath
if (@($backup.profileFiles).Count -ne 2) { throw 'Interrupted cleanup lost profile recovery records.' }
foreach ($file in $backup.profileFiles) {
    if ((Get-Utf8FileContent -Path $file.backupPath) -cne $original) { throw 'Interrupted cleanup lost the original profile content.' }
}
Restore-RegistryBackup -BackupPath $backupPath -Manifest $manifest -ProfileRoot $profileRoot -AllowedPolicyPath $policyPath -DoApply *> $null
if ((Get-Utf8FileContent -Path $firstProfile) -cne $original) { throw 'Interrupted cleanup could not be restored.' }

# A failed journal write must leave the profile untouched.
function Invoke-UnrecordedCleanup {
    function Update-BackupProfileFiles { throw 'Injected backup record write failure' }
    Invoke-ProfilePreferenceCleanup -Root $profileRoot -Manifest $manifest -BackupPath $backupPath -SelectedFeatureIds Rewards -UseFeatureFilter -DoApply
}
$failure = ''
try { Invoke-UnrecordedCleanup *> $null }
catch { $failure = $_.Exception.Message }
if ($failure -ne 'Injected backup record write failure') { throw "Unexpected backup failure: $failure" }
if ((Get-Utf8FileContent -Path $firstProfile) -cne $original) { throw 'Cleanup modified a profile without recording its backup.' }

# Missing recovery files must stop restore before policies change, including in previews.
$missingBackup = Get-JsonFileContent -Path $backupPath
$missingBackup.profileFiles[1].backupPath = Join-Path (Get-ProfileBackupDirectory -BackupPath $backupPath) 'missing.bak'
Set-JsonFileContent -Path $backupPath -Object $missingBackup
Set-TextFileContent -Path $policyPath -Content '{"BraveRewardsDisabled":true}'
foreach ($apply in @($false, $true)) {
    $failure = ''
    try { Restore-RegistryBackup -BackupPath $backupPath -Manifest $manifest -ProfileRoot $profileRoot -AllowedPolicyPath $policyPath -DoApply:$apply *> $null }
    catch { $failure = $_.Exception.Message }
    if ($failure -notlike 'Profile backup file is missing:*') { throw "Missing profile copy was not rejected: $failure" }
    if ((Get-Utf8FileContent -Path $policyPath) -cne '{"BraveRewardsDisabled":true}') { throw 'Incomplete restore changed policies.' }
}

# Already-correct preferences keep their bytes and timestamp and create no profile backup copies.
Set-TextFileContent -Path $firstProfile -Content '{ "brave": { "rewards": { "enabled": false } } }'
Set-TextFileContent -Path $secondProfile -Content '{ "brave": { "rewards": { "enabled": false } } }'
$before = Get-Utf8FileContent -Path $firstProfile
$timestamp = [datetime]'2020-01-01T00:00:00Z'
[System.IO.File]::SetLastWriteTimeUtc($firstProfile, $timestamp)
$timestamp = [System.IO.File]::GetLastWriteTimeUtc($firstProfile)
$noOpBackup = New-Backup -Directory (Join-Path $TempRoot 'NoOpBackups') -ScopeName CurrentUser -Target $target -PolicyNames @('BraveRewardsDisabled') -ProfileRoot $profileRoot -Manifest $manifest
$preview = Invoke-ProfilePreferenceCleanup -Root $profileRoot -Manifest $manifest -SelectedFeatureIds Rewards -UseFeatureFilter *>&1 | Out-String
if ($preview -notlike '*Already set:*') { throw 'Preview did not explain unchanged preferences.' }
Invoke-ProfilePreferenceCleanup -Root $profileRoot -Manifest $manifest -BackupPath $noOpBackup -SelectedFeatureIds Rewards -UseFeatureFilter -DoApply *> $null
if ((Get-Utf8FileContent -Path $firstProfile) -cne $before -or [System.IO.File]::GetLastWriteTimeUtc($firstProfile) -ne $timestamp) { throw 'Already-correct Preferences was rewritten.' }
if (@((Get-JsonFileContent -Path $noOpBackup).profileFiles).Count -ne 0) { throw 'Unchanged preferences created backup copies.' }

# A string that spells a boolean still needs correction to the JSON boolean type.
Set-TextFileContent -Path $firstProfile -Content '{"brave":{"rewards":{"enabled":"false"}}}'
Invoke-ProfilePreferenceCleanup -Root $profileRoot -Manifest $manifest -BackupPath $noOpBackup -SelectedFeatureIds Rewards -UseFeatureFilter -DoApply *> $null
$correctedValue = (Get-JsonFileContent -Path $firstProfile).brave.rewards.enabled
if ($correctedValue -isnot [bool] -or $correctedValue) { throw 'Cleanup confused a string with a boolean preference.' }

Write-Host 'Write safety checks passed.'
