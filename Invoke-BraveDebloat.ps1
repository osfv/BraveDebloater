#!/usr/bin/env pwsh
#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Standard', 'High', 'Extreme', 'Core', 'Privacy', 'Aggressive')]
    [string]$Preset = 'Extreme',

    [ValidateSet('Auto', 'Windows', 'macOS', 'Linux', 'Android', 'iOS')]
    [string]$Platform = 'Auto',

    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$Scope = 'CurrentUser',

    [switch]$Apply,

    [switch]$Doctor,

    [switch]$LockShields,

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

    [switch]$List,

    [switch]$ListFeatures,

    [switch]$NoBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
    $BackupDirectory = Join-Path $ProjectRoot 'backups'
}

. (Join-Path $ProjectRoot 'scripts\Shared.ps1')

$moduleDir = Join-Path $ProjectRoot 'src'
foreach ($moduleName in @('Common.ps1', 'Manifest.ps1', 'PlatformPolicy.ps1', 'Backup.ps1', 'ProfilePreferences.ps1', 'Reports.ps1')) {
    . (Join-Path $moduleDir $moduleName)
}

$manifest = Get-Manifest
$platformName = Resolve-PlatformName -Name $Platform
if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
    $ProfileRoot = Get-DefaultProfileRoot -PlatformName $platformName
}
$applyChanges = $Apply -and -not $WhatIfPreference
$isWhatIf = $Apply -and $WhatIfPreference

if ($UndoFromBackup) {
    Restore-RegistryBackup -BackupPath $UndoFromBackup -Manifest $manifest -ProfileRoot $ProfileRoot -AllowedPolicyPath $PolicyPath -DoApply:$applyChanges
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

$policyTarget = Get-PolicyTarget -PlatformName $platformName -ScopeName $Scope -OverridePath $PolicyPath
if ($policyTarget.Kind -eq 'MobileMDM' -and $applyChanges) {
    throw "$platformName policies require MDM deployment. This script can list or export the selected policies, but it cannot apply them on-device."
}

# Enforce the iOS/iPadOS MDM allowlist for every run (dry-run, apply, and export) so the
# preview never implies on-device support for policies Brave's mobile MDM cannot accept.
Assert-MobilePolicySupport -PlatformName $platformName -PolicyNames $policyNames.ToArray() -Manifest $manifest

if (-not [string]::IsNullOrWhiteSpace($ExportPolicyPath)) {
    $payload = Get-PolicyPayload -PolicyNames $policyNames.ToArray() -PolicyDefinitions $policyDefinitions
    Export-PolicyPayload -Target $policyTarget -Payload $payload -Path $ExportPolicyPath
    Write-Step "Exported $($policyNames.Count) policy value(s) for $platformName to $ExportPolicyPath. Apply that file with your device or policy manager."
    return
}

if ($onlyFeatureMode) {
    Write-Step 'Preset: (none - OnlyFeature mode)'
}
else {
    Write-Step "Preset: $Preset"
}
Write-Step "Platform: $platformName"
Write-Step "Scope: $Scope ($($policyTarget.Path))"
if ($LockShields) {
    Write-Step 'Shield baseline: enabled. Brave will keep ad blocking, standard fingerprinting protection, HTTPS upgrades, and referrer capping on by policy.'
}
else {
    Write-Step 'Shield baseline: not locked. This run will still refuse policies that disable or whitelist Brave Shields.'
}
if ($customFeatureRequested) {
    Write-Step "Custom features: $($selectedFeatureIds -join ', ')"
}

if (-not $applyChanges) {
    if ($isWhatIf) {
        Write-Step 'WhatIf mode. No policy, backup, or profile files will be changed.'
    }
    else {
        Write-Step 'Dry-run mode. No policy, backup, or profile files will be changed.'
    }
    Write-Step 'Review the [dry-run] lines. Add -Apply only when the planned changes look right.'
}

if ($IncludeProfilePreferences -and $applyChanges -and $NoBackup) {
    throw 'Profile preference cleanup requires backups. Remove -NoBackup, or omit -IncludeProfilePreferences and apply policy-only changes.'
}

$backupPath = $null
if ($applyChanges -and -not $NoBackup) {
    $backupPath = New-Backup -Directory $BackupDirectory -ScopeName $Scope -Target $policyTarget -PolicyNames $policyNames.ToArray() -ProfileRoot $ProfileRoot -Manifest $manifest
    Write-Step "Backup written to $backupPath"
}

foreach ($policyName in $policyNames) {
    $definition = $policyDefinitions[$policyName]
    if (-not $applyChanges) {
        Write-DryRun "Would set $policyName = $($definition.value) ($($definition.reason))"
        continue
    }

    if ($PSCmdlet.ShouldProcess($policyTarget.Path, "Set $policyName to $($definition.value)")) {
        Set-PolicyValue -Target $policyTarget -Name $policyName -Definition $definition
        Write-Step "Set $policyName."
    }
}

if ($IncludeProfilePreferences) {
    Invoke-ProfilePreferenceCleanup -Root $ProfileRoot -Manifest $manifest -BackupPath $backupPath -SelectedFeatureIds $selectedFeatureIds -UseFeatureFilter:$customFeatureRequested -DoApply:$applyChanges
}

if (-not $applyChanges) {
    if ($isWhatIf) {
        Write-Step 'WhatIf complete. No changes were made. Rerun with -Apply without -WhatIf when you are ready.'
    }
    else {
        Write-Step 'Dry-run complete. No changes were made. Rerun with -Apply when you are ready.'
    }
}
else {
    Write-Step 'Done. Restart Brave, then open brave://policy to check the applied policies.'
}
