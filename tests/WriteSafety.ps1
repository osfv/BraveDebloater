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

$definitions = Get-ManifestMap -Object $manifest.policies
if (-not $definitions.ContainsKey('AutofillSettings')) { throw 'Autofill must use the supported AutofillSettings policy.' }
$autofill = $definitions['AutofillSettings']
$expectedAutofill = '[{"url_pattern":"*","blocked_types":["contact_info","payments"]}]'
$autofillPayload = Get-PolicyPayload -PolicyNames AutofillSettings -PolicyDefinitions $definitions
$reordered = ConvertFrom-JsonText -Json '{"rules":[{"blocked_types":["contact_info","payments"],"url_pattern":"*"}]}'
foreach ($actual in @($expectedAutofill, $reordered.rules)) {
    if (-not (Test-PolicyValueMatches -ActualValue $actual -ExpectedValue $autofill.value -Type Json)) { throw 'Structured policy comparison depends on encoding or object property order.' }
}
if (-not (Test-JsonValuesEqual -Left ([pscustomobject]@{}) -Right ([pscustomobject]@{}))) { throw 'Structured policy comparison rejected empty objects.' }
if (Test-PolicyValueMatches -ActualValue '[{"url_pattern":"*","blocked_types":["payments"]}]' -ExpectedValue $autofill.value -Type Json) { throw 'Structured policy comparison ignored different values.' }
if ((ConvertTo-Json -InputObject $autofillPayload.AutofillSettings -Compress -Depth 20) -cne $expectedAutofill) { throw 'AutofillSettings lost its array or blocked the wrong data types.' }
$autofillReg = ConvertTo-RegFileDocument -RegistryPath (Get-RegistryPolicyPath -ScopeName CurrentUser) -Payload $autofillPayload
if (-not $autofillReg.Contains(('"AutofillSettings"="' + $expectedAutofill.Replace('"', '\"') + '"'))) { throw 'Registry export did not serialize AutofillSettings as a JSON string.' }
foreach ($mobileConfig in @($false, $true)) {
    [xml]$plist = ConvertTo-PlistDocument -Payload $autofillPayload -MobileConfig:$mobileConfig
    $rules = $plist.SelectSingleNode('//key[text()="AutofillSettings"]/following-sibling::*[1]')
    if ($rules.Name -ne 'array' -or $rules.SelectNodes('dict').Count -ne 1) { throw 'Plist export did not encode AutofillSettings as an array of dictionaries.' }
    if ($rules.SelectSingleNode('dict/key[text()="url_pattern"]/following-sibling::*[1]').InnerText -cne '*') { throw 'Plist export lost the Autofill URL pattern.' }
    if (($rules.SelectNodes('dict/key[text()="blocked_types"]/following-sibling::*[1]/string') | ForEach-Object { $_.InnerText }) -join ',' -cne 'contact_info,payments') { throw 'Plist export lost the blocked Autofill types.' }
}

function Test-AutofillRegistryWriter {
    function Test-Path { param($LiteralPath) return $true }
    function New-ItemProperty {
        param($LiteralPath, $Name, $Value, $PropertyType, [switch]$Force)
        if ($Name -ne 'AutofillSettings' -or $PropertyType -ne 'String' -or $Value -cne $expectedAutofill) { throw 'Registry writer did not store AutofillSettings as REG_SZ JSON.' }
    }
    Set-BravePolicy -BasePath (Get-RegistryPolicyPath -ScopeName CurrentUser) -Name AutofillSettings -Definition $autofill
}
Test-AutofillRegistryWriter

$autofillRoot = Join-Path $TempRoot 'Autofill'
New-DirectoryLiteral -Path $autofillRoot
$autofillPath = Join-Path $autofillRoot 'policy.json'
foreach ($priorRules in @('[]', '[{"url_pattern":"https://example.com","blocked_types":["payments"]}]', '[{"url_pattern":"*","blocked_types":["identity_docs"]},{"url_pattern":"https://example.com","blocked_types":["travel"]}]')) {
    $before = '{"AutofillSettings":' + $priorRules + ',"AutofillCreditCardEnabled":true,"AutofillAddressEnabled":false,"Unrelated":"keep"}'
    Set-TextFileContent -Path $autofillPath -Content $before
    $autofillBackups = Join-Path $autofillRoot ([guid]::NewGuid().ToString('N'))
    $preview = & $scriptPath -Platform Linux -OnlyFeature Autofill -PolicyPath $autofillPath -BackupDirectory $autofillBackups *>&1 | Out-String
    if ($preview -notlike '*Would set AutofillSettings*' -or $preview -notlike '*Would remove AutofillCreditCardEnabled*' -or $preview -notlike '*Would remove AutofillAddressEnabled*') { throw 'Autofill migration preview omitted a policy change.' }
    if ((Get-Utf8FileContent -Path $autofillPath) -cne $before -or (Test-Path -LiteralPath $autofillBackups)) { throw 'Autofill preview wrote files.' }
    & $scriptPath -Platform Linux -OnlyFeature Autofill -PolicyPath $autofillPath -BackupDirectory $autofillBackups -Apply -Confirm:$false *> $null
    $applied = Get-JsonFileContent -Path $autofillPath
    if ((ConvertTo-Json -InputObject $applied.AutofillSettings -Compress -Depth 20) -cne $expectedAutofill -or $applied.Unrelated -cne 'keep') { throw 'Autofill migration wrote the wrong structured policy or changed unrelated data.' }
    if ($applied.PSObject.Properties['AutofillCreditCardEnabled'] -or $applied.PSObject.Properties['AutofillAddressEnabled']) { throw 'Autofill migration kept deprecated policies.' }
    $backupFile = @(Get-ChildItem -LiteralPath $autofillBackups -Filter 'BraveDebloater-*.json')[0].FullName
    $backup = Get-JsonFileContent -Path $backupFile
    $savedAutofill = @($backup.policies | Where-Object { $_.name -eq 'AutofillSettings' })[0]
    if ($savedAutofill.kind -ne 'Json' -or (ConvertTo-Json -InputObject $savedAutofill.value -Compress -Depth 20) -cne $priorRules) { throw 'Backup did not preserve the original structured Autofill policy.' }
    Restore-RegistryBackup -BackupPath $backupFile -Manifest $manifest -AllowedPolicyPath $autofillPath -DoApply *> $null
    $restored = Get-JsonFileContent -Path $autofillPath
    if ((ConvertTo-Json -InputObject $restored.AutofillSettings -Compress -Depth 20) -cne $priorRules -or $restored.AutofillCreditCardEnabled -ne $true -or $restored.AutofillAddressEnabled -ne $false -or $restored.Unrelated -cne 'keep') { throw 'Autofill undo did not restore both structured and deprecated policies.' }
}

foreach ($case in @(
    @{ Target = 'Registry'; Name = 'AutofillSettings'; Kind = 'String'; Value = $expectedAutofill; Valid = $true },
    @{ Target = 'Registry'; Name = 'AutofillSettings'; Kind = 'Json'; Value = $autofill.value; Valid = $false },
    @{ Target = 'JsonFile'; Name = 'AutofillSettings'; Kind = 'String'; Value = $expectedAutofill; Valid = $false },
    @{ Target = 'JsonFile'; Name = 'BraveRewardsDisabled'; Kind = 'Json'; Value = $autofill.value; Valid = $false },
    @{ Target = 'JsonFile'; Name = 'AutofillSettings'; Kind = 'Json'; Value = 1; Valid = $false },
    @{ Target = 'Registry'; Name = 'AutofillCreditCardEnabled'; Kind = 'DWord'; Value = 0; Valid = $true },
    @{ Target = 'Registry'; Name = 'AutofillAddressEnabled'; Kind = 'DWord'; Value = 0; Valid = $true }
)) {
    $candidate = [pscustomobject]@{ policyKind = $case.Target; policies = @([pscustomobject]@{ name = $case.Name; existed = $true; kind = $case.Kind; value = $case.Value }) }
    $accepted = $true
    try { Assert-BackupPolicyList -Backup $candidate -PolicyDefinitions $definitions -DeprecatedPolicyNames @(Get-DeprecatedPolicyNames -Manifest $manifest) }
    catch { $accepted = $false }
    if ($accepted -ne $case.Valid) { throw "Incorrect structured backup validation for $($case.Target)/$($case.Name)/$($case.Kind)." }
}

if ((Resolve-PlatformName -Name Auto) -eq 'macOS') {
    $macTarget = [pscustomobject]@{ Platform = 'macOS'; Kind = 'MacOSPlist'; Path = (Join-Path $autofillRoot 'native.plist') }
    Set-PolicyValue -Target $macTarget -Name DnsOverHttpsMode -Definition ([pscustomobject]@{ type = 'String'; value = 'automatic' })
    foreach ($priorRules in @('[]', '[{"url_pattern":"https://example.com","blocked_types":["payments"]}]')) {
        $prior = ConvertFrom-JsonText -Json ('{"rules":' + $priorRules + '}')
        Set-PolicyValue -Target $macTarget -Name AutofillSettings -Definition ([pscustomobject]@{ type = 'Json'; value = $prior.rules })
        $macBackup = New-Backup -Directory (Join-Path $autofillRoot 'mac-backups') -ScopeName LocalMachine -Target $macTarget -PolicyNames AutofillSettings -Manifest $manifest
        Set-PolicyValue -Target $macTarget -Name AutofillSettings -Definition $autofill
        $value = Get-PolicyValue -Target $macTarget -Name AutofillSettings
        if ($value.ReadError -or $value.Kind -ne 'Json' -or $value.Value -isnot [System.Collections.IList] -or $value.Value.Count -ne 1 -or $value.Value[0].url_pattern -cne '*' -or ($value.Value[0].blocked_types -join ',') -cne 'contact_info,payments') { throw 'Native macOS Autofill policy did not round-trip as a structured array.' }
        Restore-RegistryBackup -BackupPath $macBackup -Manifest $manifest -AllowedPolicyPath $macTarget.Path -DoApply *> $null
        $restored = Get-PolicyValue -Target $macTarget -Name AutofillSettings
        if ($restored.ReadError -or $restored.Value -isnot [System.Collections.IList] -or $restored.Value.Count -ne $prior.rules.Count) { throw 'Native macOS Autofill restore changed the array shape.' }
        if ($restored.Value.Count -gt 0 -and ($restored.Value[0].url_pattern -cne 'https://example.com' -or ($restored.Value[0].blocked_types -join ',') -cne 'payments')) { throw 'Native macOS Autofill restore changed the saved rule.' }
        if ((Get-PolicyValue -Target $macTarget -Name DnsOverHttpsMode).Value -cne 'automatic') { throw 'Native macOS Autofill write changed an unrelated policy.' }
    }
}

Write-Host 'Write safety checks passed.'
