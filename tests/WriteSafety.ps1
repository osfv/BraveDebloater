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

# PowerShell 7 without -DateKind parses date strings as DateTime; those files must be skipped, not rewritten.
if ($PSVersionTable.PSVersion.Major -ge 6) {
    function Invoke-CleanupWithoutDateKind {
        function Test-JsonDateKindSupported { return $false }
        Invoke-ProfilePreferenceCleanup -Root $profileRoot -Manifest $manifest -BackupPath $noOpBackup -SelectedFeatureIds Rewards -UseFeatureFilter -DoApply
    }
    $dateContent = '{"sync":{"last_synced":"2023-01-01T12:00:00.1234567+13:00"},"brave":{"rewards":{"enabled":true}}}'
    Set-TextFileContent -Path $firstProfile -Content $dateContent
    $dateOutput = Invoke-CleanupWithoutDateKind *>&1 | Out-String
    if ($dateOutput -notlike '*it contains date values*') { throw 'Cleanup without -DateKind did not explain the skipped file.' }
    if ((Get-Utf8FileContent -Path $firstProfile) -cne $dateContent) { throw 'Cleanup without -DateKind rewrote a Preferences file with date values.' }

    # The same applies to the managed policy file, which every set or remove re-serializes.
    function Invoke-PolicyWriteWithoutDateKind {
        param([scriptblock]$Write)
        function Test-JsonDateKindSupported { return $false }
        & $Write
    }
    $datePolicyContent = '{"HomepageLocation":"2023-01-01T12:00:00.1234567+13:00","BraveRewardsDisabled":false}'
    foreach ($write in @(
        { Set-PolicyValue -Target $target -Name 'BraveRewardsDisabled' -Definition ([pscustomobject]@{ type = 'DWord'; value = 1 }) },
        { Remove-PolicyValue -Target $target -Name 'BraveRewardsDisabled' }
    )) {
        Set-TextFileContent -Path $policyPath -Content $datePolicyContent
        $failure = ''
        try { Invoke-PolicyWriteWithoutDateKind -Write $write *> $null }
        catch { $failure = $_.Exception.Message }
        if ($failure -notlike '*contains date values*') { throw "Policy write without -DateKind was not refused: $failure" }
        if ((Get-Utf8FileContent -Path $policyPath) -cne $datePolicyContent) { throw 'Policy write without -DateKind rewrote a policy file with date values.' }
    }
}

# A matching -PolicyPath must never authorize an unrelated registry key.
foreach ($untrustedPath in @('Registry::HKEY_CURRENT_USER\Software\NotBrave', 'Registry::HKEY_LOCAL_MACHINE\Software\NotBrave')) {
    $failure = ''
    try { Assert-BackupRegistryPath -RegistryPath $untrustedPath -AllowedPolicyPath $untrustedPath }
    catch { $failure = $_.Exception.Message }
    if ($failure -notlike '*untrusted registry path*') { throw 'PolicyPath bypassed the Brave registry restore allowlist.' }
}

# Setting and removing a managed policy must preserve deeply nested unrelated values.
$nested = [pscustomobject]@{ marker = 'keep me'; values = @(1, 'two', $false) }
for ($level = 0; $level -lt 30; $level++) {
    $nested = [pscustomobject]@{ child = $nested }
}
$deepPolicy = [pscustomobject]@{ UnrelatedPolicy = $nested; BraveRewardsDisabled = $false }
$expectedNested = ConvertTo-Json -InputObject $nested -Depth 100 -Compress
Set-JsonFileContent -Path $policyPath -Object $deepPolicy -Depth 100
foreach ($write in @(
    { Set-PolicyValue -Target $target -Name 'BraveRewardsDisabled' -Definition ([pscustomobject]@{ type = 'DWord'; value = 1 }) },
    { Remove-PolicyValue -Target $target -Name 'BraveRewardsDisabled' }
)) {
    & $write
    $actualNested = ConvertTo-Json -InputObject (Get-JsonFileContent -Path $policyPath).UnrelatedPolicy -Depth 100 -Compress
    if ($actualNested -cne $expectedNested) { throw 'Policy write truncated unrelated nested JSON.' }
}

# Refuse depth overflow before touching an existing file, including nested arrays.
foreach ($container in @('Object', 'Array')) {
    $tooDeep = [pscustomobject]@{ marker = 'keep me' }
    for ($level = 0; $level -lt 102; $level++) {
        if ($container -eq 'Object') { $tooDeep = [pscustomobject]@{ child = $tooDeep } }
        else { $tooDeep = ,$tooDeep }
    }
    $originalBytes = Get-Utf8FileContent -Path $policyPath
    $failure = ''
    try { Set-JsonFileContent -Path $policyPath -Object $tooDeep -Depth 100 }
    catch { $failure = $_.Exception.Message }
    if ($failure -notlike 'JSON nesting exceeds*') { throw "Depth overflow was not rejected for ${container}: $failure" }
    if ((Get-Utf8FileContent -Path $policyPath) -cne $originalBytes) { throw 'Depth overflow changed the original file.' }
}

foreach ($mode in @('Unmanaged', 'Automatic', 'Off')) {
    $listing = & $scriptPath -Platform Linux -OnlyFeature Rewards -DnsOverHttps $mode -List *>&1 | Out-String
    if ($listing -notlike '*Remove if present: DnsOverHttpsTemplates.*') { throw 'DNS listing omitted resolver removal.' }
    if ($mode -eq 'Unmanaged' -and $listing -notlike '*Remove if present: DnsOverHttpsMode.*') { throw 'DNS listing omitted mode removal.' }
    if ($listing -notlike '*Policy plan:*') { throw 'Policy listing omitted totals.' }
}

Write-Host 'Write safety checks passed.'
