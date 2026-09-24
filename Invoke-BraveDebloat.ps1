#!/usr/bin/env pwsh
#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Standard', 'High', 'Extreme', 'Core', 'Privacy', 'Aggressive')]
    [string]$Preset = 'Extreme',

    [ValidateSet('Auto', 'Windows', 'macOS', 'Linux', 'Android', 'iOS')]
    [string]$Platform = 'Auto',

    [ValidateSet('Stable', 'Beta', 'Nightly')]
    [string]$Channel = 'Stable',

    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$Scope = 'CurrentUser',

    [string]$UserSid,

    [switch]$Apply,

    [switch]$Doctor,

    [switch]$LockShields,

    [ValidateSet('Off', 'Automatic', 'Secure', 'Unmanaged')]
    [string]$DnsOverHttps,

    [string[]]$DnsOverHttpsTemplates = @(),

    [switch]$Customize,

    [string[]]$OnlyFeature = @(),

    [string[]]$IncludeFeature = @(),

    [string[]]$ExcludeFeature = @(),

    [switch]$IncludeProfilePreferences,

    [string]$ProfileRoot,

    [string]$PolicyPath,

    [string]$ExportPolicyPath,

    [string]$BackupDirectory,

    [string]$UndoFromBackup,

    [switch]$ListBackups,

    [ValidateRange(-1, 36500)]
    [int]$PruneBackupsOlderThanDays = -1,

    [ValidateRange(-1, 100000)]
    [int]$KeepLatestBackups = -1,

    [switch]$List,

    [switch]$ListFeatures,

    [switch]$NoBackup,

    [switch]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ToolVersion = '0.6.0'

$ProjectRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
    $BackupDirectory = Join-Path $ProjectRoot 'backups'
}

$moduleDir = Join-Path $ProjectRoot 'src'
foreach ($moduleName in @('Common.ps1', 'Manifest.ps1', 'PlatformPolicy.ps1', 'Backup.ps1', 'ProfilePreferences.ps1', 'Reports.ps1')) {
    . (Join-Path $moduleDir $moduleName)
}

$manifest = Get-Manifest
$platformName = Resolve-PlatformName -Name $Platform

Assert-CommandModes -Parameters $PSBoundParameters

if ($Version) {
    Show-VersionInfo -ToolVersion $ToolVersion -Manifest $manifest -PlatformName $platformName
    return
}

$userSidSpecified = -not [string]::IsNullOrWhiteSpace($UserSid)
if ($userSidSpecified) {
    Assert-UserSid -UserSid $UserSid
    if ($platformName -ne 'Windows') {
        throw '-UserSid is supported only for Windows registry policies. Remove -UserSid or use -Platform Windows.'
    }
    if ($Scope -ne 'CurrentUser') {
        throw '-UserSid cannot be combined with -Scope LocalMachine. A target user SID selects that user policy hive directly.'
    }
    if ($Doctor) {
        throw '-UserSid cannot be combined with -Doctor. Use a normal dry-run to preview the target user policy path.'
    }
    if ($IncludeProfilePreferences -and [string]::IsNullOrWhiteSpace($ProfileRoot)) {
        throw '-IncludeProfilePreferences with -UserSid requires an explicit -ProfileRoot for that user.'
    }
    if ($List -or $ListFeatures -or $ListBackups -or $PruneBackupsOlderThanDays -ge 0 -or $KeepLatestBackups -ge 0) {
        throw '-UserSid cannot be combined with -List, -ListFeatures, or backup listing/retention options.'
    }
}
if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
    $ProfileRoot = Get-DefaultProfileRoot -PlatformName $platformName -Channel $Channel
}
$applyChanges = $Apply -and -not $WhatIfPreference
$isWhatIf = $Apply -and $WhatIfPreference

if ($ListBackups -or $PruneBackupsOlderThanDays -ge 0 -or $KeepLatestBackups -ge 0) {
    Invoke-BackupRetention -Directory $BackupDirectory -Manifest $manifest -OlderThanDays $PruneBackupsOlderThanDays -KeepLatest $KeepLatestBackups -DoApply:$applyChanges
    return
}

if ($UndoFromBackup) {
    $allowedUserPolicyPath = if ($userSidSpecified) { Get-RegistryPolicyPath -ScopeName 'CurrentUser' -UserSid $UserSid } else { $null }
    $restoreBackupPath = Resolve-BackupPath -Path $UndoFromBackup -Directory $BackupDirectory
    Restore-RegistryBackup -BackupPath $restoreBackupPath -Manifest $manifest -ProfileRoot $ProfileRoot -AllowedPolicyPath $PolicyPath -AllowedUserPolicyPath $allowedUserPolicyPath -DoApply:$applyChanges
    if (-not $applyChanges) {
        if ($isWhatIf) {
            Write-Step 'Undo preview complete. No files or policies were restored. Rerun with -Apply without -WhatIf to restore the backup.'
        }
        else {
            Write-Step 'Undo dry-run complete. No files or policies were restored. Rerun with -Apply to restore the backup.'
        }
    }
    else {
        Write-Step 'Undo complete. Restart Brave, then open brave://policy to check the restored policies.'
    }
    return
}

$presets = Get-ManifestMap -Object $manifest.presets
$policyDefinitions = Get-ManifestMap -Object $manifest.policies
$features = @($manifest.features)
$featureMap = Get-FeatureMap -Features $features
Assert-FeatureReferences -Features $features -PolicyDefinitions $policyDefinitions

if ($Doctor) {
    if ($Apply) {
        Write-Warning '-Doctor is read-only. -Apply was ignored. No policy, backup, or profile files will be changed.'
    }
    Show-DoctorReport -Manifest $manifest -Features $features -PolicyDefinitions $policyDefinitions -ProfileRoot $ProfileRoot -BackupDirectory $BackupDirectory -PlatformName $platformName -PolicyPath $PolicyPath
    return
}

$normalizedOnlyFeature = @(Get-NormalizedFeatureName -Names $OnlyFeature)
$normalizedIncludeFeature = @(Get-NormalizedFeatureName -Names $IncludeFeature)
$normalizedExcludeFeature = @(Get-NormalizedFeatureName -Names $ExcludeFeature)

if ($PSBoundParameters.ContainsKey('OnlyFeature') -and $normalizedOnlyFeature.Count -eq 0) {
    throw 'Specified -OnlyFeature contains only blank entries. Add at least one feature name, for example: -OnlyFeature Rewards'
}

Assert-FeatureNames -Names $normalizedIncludeFeature -FeatureMap $featureMap
Assert-FeatureNames -Names $normalizedExcludeFeature -FeatureMap $featureMap
Assert-FeatureNames -Names $normalizedOnlyFeature -FeatureMap $featureMap
foreach ($featureName in $normalizedIncludeFeature) {
    if ($normalizedExcludeFeature -contains $featureName) {
        throw "Feature '$featureName' is in both -IncludeFeature and -ExcludeFeature. Pick one list for that feature."
    }
}

$onlyFeatureMode = $normalizedOnlyFeature.Count -gt 0
if ($onlyFeatureMode -and ($Customize -or $normalizedIncludeFeature.Count -gt 0 -or $normalizedExcludeFeature.Count -gt 0)) {
    throw '-OnlyFeature cannot be combined with -Customize, -IncludeFeature, or -ExcludeFeature. Use -OnlyFeature by itself when you want an exact feature list.'
}

$policyNames = New-Object System.Collections.Generic.List[string]

if (-not $onlyFeatureMode) {
    foreach ($name in Resolve-PresetPolicies -Name $Preset -Presets $presets) {
        [void]$policyNames.Add($name)
    }
}

$customFeatureRequested = $onlyFeatureMode -or $Customize -or $normalizedIncludeFeature.Count -gt 0 -or $normalizedExcludeFeature.Count -gt 0
$featurePresetName = if ($onlyFeatureMode) { '__OnlyFeature' } else { $Preset }
$featureIncludeNames = if ($onlyFeatureMode) { $normalizedOnlyFeature } else { $normalizedIncludeFeature }
$featureExcludeNames = if ($onlyFeatureMode) { @() } else { $normalizedExcludeFeature }
$selectedFeatureIds = @(Resolve-FeatureSelection -Features $features -FeatureMap $featureMap -PolicyNames $policyNames -PresetName $featurePresetName -IncludeNames $featureIncludeNames -ExcludeNames $featureExcludeNames -UsePrompt:$Customize)

if ($LockShields) {
    foreach ($name in Resolve-PresetPolicies -Name 'ShieldBaseline' -Presets $presets) {
        if (-not $policyNames.Contains($name)) {
            [void]$policyNames.Add($name)
        }
    }
}

foreach ($policyName in $policyNames) {
    if (-not $policyDefinitions.ContainsKey($policyName)) {
        throw "Policy '$policyName' is listed in a preset but missing from config/policies.json."
    }
}

# DNS control is opt-in: the DNS-over-HTTPS policies are only touched when -DnsOverHttps is given.
$dnsPlan = $null
$dnsRemovePolicyNames = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace($DnsOverHttps)) {
    $dnsPlan = Resolve-DnsControlPlan -Manifest $manifest -Mode $DnsOverHttps -Templates $DnsOverHttpsTemplates -PolicyDefinitions $policyDefinitions
    foreach ($entry in $dnsPlan.Definitions.GetEnumerator()) {
        $policyDefinitions[$entry.Key] = $entry.Value
        Add-StringIfMissing -List $policyNames -Value $entry.Key
    }
    foreach ($name in $dnsPlan.RemoveNames) {
        [void]$dnsRemovePolicyNames.Add($name)
    }
}
elseif (@($DnsOverHttpsTemplates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw '-DnsOverHttpsTemplates needs -DnsOverHttps Secure or Automatic to say how the resolver is used.'
}

Assert-PolicySafety -PolicyNames $policyNames.ToArray() -Manifest $manifest

if ($ListFeatures) {
    Show-FeatureList -Features $features -SelectedFeatureIds $selectedFeatureIds
    return
}

if ($List) {
    Show-PolicyList -PolicyNames $policyNames.ToArray() -PolicyDefinitions $policyDefinitions
    if ($IncludeProfilePreferences) {
        Write-Step 'Profile preference patches that would be considered:'
        $patchesToList = @($manifest.profilePreferencePatches)
        if ($customFeatureRequested) {
            $patchesToList = @($patchesToList | Where-Object {
                    $featureId = [string]$_.feature
                    [string]::IsNullOrWhiteSpace($featureId) -or ($selectedFeatureIds -contains $featureId)
                })
        }
        Show-ProfilePreferencePatchList -Patches $patchesToList
    }
    return
}

# Previews and exports never write to the policy target, so they must not demand elevation.
# Only a real apply run performs the administrator/root and loaded-hive checks.
$exportRequested = -not [string]::IsNullOrWhiteSpace($ExportPolicyPath)
if ($exportRequested -and $Apply) {
    Write-Warning '-ExportPolicyPath only writes the export file. -Apply was ignored and the policy target was not changed.'
}
$writesPolicyTarget = $applyChanges -and -not $exportRequested
$policyTarget = Get-PolicyTarget -PlatformName $platformName -ScopeName $Scope -OverridePath $PolicyPath -UserSid $UserSid -Apply:$writesPolicyTarget -ReadOnly:(-not $writesPolicyTarget)
if ($policyTarget.Kind -eq 'MobileMDM' -and $writesPolicyTarget) {
    throw "$platformName policies require MDM deployment. This script can list or export the selected policies, but it cannot apply them on-device."
}
if (-not [string]::IsNullOrWhiteSpace($PolicyPath) -and $policyTarget.Kind -notin @('JsonFile', 'MacOSPlist')) {
    Write-Warning "-PolicyPath is ignored for $platformName $Scope policies, which are written to $($policyTarget.Path). It only selects a file for Linux or macOS LocalMachine targets."
}

# Enforce the iOS/iPadOS MDM allowlist for every run (dry-run, apply, and export) so the
# preview never implies on-device support for policies Brave's mobile MDM cannot accept.
Assert-MobilePolicySupport -PlatformName $platformName -PolicyNames (@($policyNames.ToArray()) + @($dnsRemovePolicyNames.ToArray())) -Manifest $manifest

if ($exportRequested) {
    $payload = Get-PolicyPayload -PolicyNames $policyNames.ToArray() -PolicyDefinitions $policyDefinitions
    # Validate the format even during a preview, but do not create or overwrite files.
    $exportFormat = Get-PolicyExportFormat -Target $policyTarget -Path $ExportPolicyPath
    if (-not $PSCmdlet.ShouldProcess($ExportPolicyPath, "Export $($policyNames.Count) policy value(s) as $exportFormat")) {
        Write-Step 'Export skipped. No export file was written.'
        return
    }
    $exportFormat = Export-PolicyPayload -Target $policyTarget -Payload $payload -Path $ExportPolicyPath -RemoveNames $dnsRemovePolicyNames.ToArray()
    $exportHint = switch ($exportFormat) {
        'Reg' { 'Double-click it or run `reg import` on the target Windows machine, then restart Brave.' }
        'MobileConfig' { 'Install that profile with your MDM or device manager.' }
        default { 'Apply that file with your device or policy manager.' }
    }
    Write-Step "Exported $($policyNames.Count) policy value(s) for $platformName to $ExportPolicyPath. $exportHint"
    if ($dnsRemovePolicyNames.Count -gt 0) {
        if ($exportFormat -eq 'Reg') {
            Write-Step "The .reg file also deletes $($dnsRemovePolicyNames -join ' and ') when imported."
        }
        else {
            Write-Warning "A $exportFormat export cannot remove policies. Remove $($dnsRemovePolicyNames -join ' and ') from the device's Brave policies yourself, or the old DNS setting stays in effect."
        }
    }
    return
}

if ($onlyFeatureMode) {
    Write-Step 'Preset: (none - OnlyFeature mode)'
}
else {
    Write-Step "Preset: $Preset"
}
Write-Step "Platform: $platformName"
if ($Channel -ne 'Stable') {
    Write-Step "Channel: $Channel"
}
Write-Step "Scope: $Scope ($($policyTarget.Path))"
if ($LockShields) {
    Write-Step 'Shield baseline: enabled. Brave will keep ad blocking, standard fingerprinting protection, HTTPS upgrades, and referrer capping on by policy.'
}
else {
    Write-Step 'Shield baseline: not locked. This run will still refuse policies that disable or whitelist Brave Shields.'
}
if ($null -ne $dnsPlan) {
    Write-Step "DNS over HTTPS: $($dnsPlan.Summary)"
}
if ($customFeatureRequested) {
    Write-Step "Custom features: $($selectedFeatureIds -join ', ')"
}
if (-not $IncludeProfilePreferences -and $policyTarget.Kind -ne 'MobileMDM') {
    $profilePatchFeatures = @(Get-ProfilePatchFeatureIds -Manifest $manifest -SelectedFeatureIds $selectedFeatureIds)
    if ($profilePatchFeatures.Count -gt 0) {
        Write-Step "Note: profile preference cleanup is not included. Add -IncludeProfilePreferences to also patch per-profile settings for: $($profilePatchFeatures -join ', ')."
    }
}

if (-not $applyChanges) {
    if ($isWhatIf) {
        Write-Step 'WhatIf mode. No policy, backup, or profile files will be changed.'
    }
    else {
        Write-Step 'Dry-run mode. No policy, backup, or profile files will be changed.'
    }
    Write-Step 'Review the [dry-run] lines. Add -Apply only when the planned changes look right.'
    $elevationHint = Get-PolicyTargetElevationHint -Target $policyTarget -ScopeName $Scope -UserSid $UserSid -OverridePath $PolicyPath
    if (-not [string]::IsNullOrWhiteSpace($elevationHint)) {
        Write-Step "Note: $elevationHint"
    }
}

if ($IncludeProfilePreferences -and $applyChanges -and $NoBackup) {
    throw 'Profile preference cleanup requires backups. Remove -NoBackup, or omit -IncludeProfilePreferences and apply policy-only changes.'
}

$obsoletePolicyNames = New-Object System.Collections.Generic.List[string]
$dnsPresentRemovals = New-Object System.Collections.Generic.List[string]
if ($policyTarget.Kind -ne 'MobileMDM') {
    try {
        foreach ($name in @(Get-PresentPolicyNames -Target $policyTarget -PolicyNames @(Get-DeprecatedPolicyNames -Manifest $manifest))) {
            [void]$obsoletePolicyNames.Add($name)
        }
        foreach ($name in @(Get-PresentPolicyNames -Target $policyTarget -PolicyNames $dnsRemovePolicyNames.ToArray())) {
            [void]$dnsPresentRemovals.Add($name)
        }
    }
    catch {
        if ($applyChanges) {
            throw
        }
        Write-Warning "Could not read existing policies at '$($policyTarget.Path)', so leftover obsolete policies were not checked: $($_.Exception.Message)"
    }
}

$backupPolicyNames = New-Object System.Collections.Generic.List[string]
foreach ($name in $policyNames) {
    [void]$backupPolicyNames.Add($name)
}
foreach ($name in $obsoletePolicyNames) {
    Add-StringIfMissing -List $backupPolicyNames -Value $name
}
foreach ($name in $dnsPresentRemovals) {
    Add-StringIfMissing -List $backupPolicyNames -Value $name
}

$backupPath = $null
if ($applyChanges -and -not $NoBackup) {
    if ($policyTarget.Kind -eq 'JsonFile' -and (Test-Path -LiteralPath $policyTarget.Path)) {
        if ($backupPolicyNames.Count -gt 0) {
            Get-ManagedPolicyJsonForWrite -Path $policyTarget.Path | Out-Null
        }
        else {
            Get-ManagedPolicyJson -Path $policyTarget.Path | Out-Null
        }
    }
    $backupPath = New-Backup -Directory $BackupDirectory -ScopeName $Scope -Target $policyTarget -PolicyNames $backupPolicyNames.ToArray() -ProfileRoot $ProfileRoot -Manifest $manifest
    Write-Step "Backup written to $backupPath"
}

# Preview runs annotate each planned write with the value Brave currently has, when the target is readable.
$currentPolicyValues = $null
if (-not $applyChanges -and $policyTarget.Kind -ne 'MobileMDM') {
    $currentPolicyValues = Get-PolicyValueMap -Target $policyTarget -PolicyNames $policyNames.ToArray()
}

$appliedPolicyCount = 0
$alreadySetCount = 0
foreach ($policyName in $policyNames) {
    $definition = $policyDefinitions[$policyName]
    if (-not $applyChanges) {
        $stateNote = Get-PolicyStateNote -CurrentValues $currentPolicyValues -Name $policyName -Definition $definition
        if ($stateNote.AlreadySet) {
            $alreadySetCount++
        }
        Write-DryRun "Would set $policyName = $($definition.value) ($($definition.reason))$($stateNote.Text)"
        continue
    }

    if ($PSCmdlet.ShouldProcess($policyTarget.Path, "Set $policyName to $($definition.value)")) {
        Set-PolicyValue -Target $policyTarget -Name $policyName -Definition $definition
        $appliedPolicyCount++
        Write-Step "Set $policyName."
    }
}

$removedObsoleteCount = 0
foreach ($policyName in $obsoletePolicyNames) {
    if (-not $applyChanges) {
        Write-DryRun "Would remove $policyName because Brave marks it obsolete."
        continue
    }

    if ($PSCmdlet.ShouldProcess($policyTarget.Path, "Remove obsolete policy $policyName")) {
        Remove-PolicyValue -Target $policyTarget -Name $policyName
        $removedObsoleteCount++
        Write-Step "Removed obsolete $policyName."
    }
}

$removedDnsCount = 0
foreach ($policyName in $dnsPresentRemovals) {
    if (-not $applyChanges) {
        Write-DryRun "Would remove $policyName so Brave settings control it again."
        continue
    }

    if ($PSCmdlet.ShouldProcess($policyTarget.Path, "Remove DNS policy $policyName")) {
        Remove-PolicyValue -Target $policyTarget -Name $policyName
        $removedDnsCount++
        Write-Step "Removed $policyName."
    }
}

if ($IncludeProfilePreferences) {
    Invoke-ProfilePreferenceCleanup -Root $ProfileRoot -Manifest $manifest -BackupPath $backupPath -SelectedFeatureIds $selectedFeatureIds -UseFeatureFilter:$customFeatureRequested -DoApply:$applyChanges
}

$obsoletePlanSummary = if ($obsoletePolicyNames.Count -gt 0) { ", $($obsoletePolicyNames.Count) obsolete leftover(s) to remove" } else { '' }
$obsoleteDoneSummary = if ($removedObsoleteCount -gt 0) { " Removed $removedObsoleteCount obsolete leftover(s)." } else { '' }
if ($dnsPresentRemovals.Count -gt 0) {
    $obsoletePlanSummary += ", $($dnsPresentRemovals.Count) DNS policy value(s) to remove"
}
if ($removedDnsCount -gt 0) {
    $obsoleteDoneSummary += " Removed $removedDnsCount DNS policy value(s)."
}
$alreadySetSummary = if ($alreadySetCount -gt 0) { " ($alreadySetCount already set)" } else { '' }
if (-not $applyChanges) {
    if ($isWhatIf) {
        Write-Step "WhatIf complete. $($policyNames.Count) policy value(s) planned$alreadySetSummary$obsoletePlanSummary, no changes were made. Rerun with -Apply without -WhatIf when you are ready."
    }
    else {
        Write-Step "Dry-run complete. $($policyNames.Count) policy value(s) planned$alreadySetSummary$obsoletePlanSummary, no changes were made. Rerun with -Apply when you are ready."
    }
}
else {
    Write-Step "Done. Set $appliedPolicyCount of $($policyNames.Count) policy value(s).$obsoleteDoneSummary Restart Brave, then open brave://policy to check the applied policies."
    if ($null -ne $backupPath) {
        Write-Step (Get-UndoHint -BackupPath $backupPath -Target $policyTarget -UserSid $UserSid -PolicyPathUsed:(-not [string]::IsNullOrWhiteSpace($PolicyPath)) -ProfileRoot $ProfileRoot)
    }
}
