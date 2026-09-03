#requires -Version 5.1

function Get-Manifest {
    $manifestPath = Join-Path (Join-Path $ProjectRoot 'config') 'policies.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Cannot find policy manifest at $manifestPath."
    }

    return (Get-JsonFileContent -Path $manifestPath)
}

function Resolve-PresetPolicies {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Presets,
        [hashtable]$Seen = @{}
    )

    if (-not $Presets.ContainsKey($Name)) {
        throw "Unknown preset '$Name'."
    }
    if ($Seen.ContainsKey($Name)) {
        throw "Preset cycle detected at '$Name'."
    }

    $Seen[$Name] = $true
    $resolved = New-Object System.Collections.Generic.List[string]

    foreach ($entry in @($Presets[$Name])) {
        if ($entry -isnot [string]) {
            throw "Preset '$Name' contains a non-string entry."
        }

        if ($entry.StartsWith('@')) {
            $childName = $entry.Substring(1)
            foreach ($childPolicy in Resolve-PresetPolicies -Name $childName -Presets $Presets -Seen ($Seen.Clone())) {
                if (-not $resolved.Contains($childPolicy)) {
                    [void]$resolved.Add($childPolicy)
                }
            }
        }
        elseif (-not $resolved.Contains($entry)) {
            [void]$resolved.Add($entry)
        }
    }

    return $resolved.ToArray()
}

function Get-FeatureMap {
    param([object[]]$Features)

    $map = @{}
    foreach ($feature in @($Features)) {
        $id = [string]$feature.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'Feature entry is missing an id.'
        }
        if ($map.ContainsKey($id)) {
            throw "Duplicate feature id '$id'."
        }
        $map[$id] = $feature
    }
    return $map
}

function Get-FeaturePolicies {
    param([Parameter(Mandatory = $true)]$Feature)

    return @($Feature.policies) | ForEach-Object { [string]$_ }
}

function Test-FeatureSelectedByPolicy {
    param(
        [Parameter(Mandatory = $true)]$Feature,
        [Parameter(Mandatory = $true)]$PolicyNames,
        [Parameter(Mandatory = $true)][string]$PresetName
    )

    $policies = @(Get-FeaturePolicies -Feature $Feature)
    if ($policies.Count -eq 0) {
        return (@($Feature.defaultPresets) -contains $PresetName)
    }

    foreach ($policyName in $policies) {
        if (-not $PolicyNames.Contains($policyName)) {
            return $false
        }
    }
    return $true
}

function Assert-FeatureNames {
    param(
        [string[]]$Names,
        [Parameter(Mandatory = $true)][hashtable]$FeatureMap
    )

    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace([string]$name)) {
            continue
        }
        if (-not $FeatureMap.ContainsKey($name)) {
            $available = ($FeatureMap.Keys | Sort-Object) -join ', '
            throw "Unknown feature '$name'. Run -ListFeatures to see descriptions. Available feature names: $available"
        }
    }
}

function Get-NormalizedFeatureName {
    param([string[]]$Names)

    $normalized = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Names)) {
        $trimmed = ([string]$name).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }
        Add-StringIfMissing -List $normalized -Value $trimmed
    }
    return $normalized.ToArray()
}

function Assert-FeatureReferences {
    param(
        [object[]]$Features,
        [Parameter(Mandatory = $true)][hashtable]$PolicyDefinitions
    )

    foreach ($feature in @($Features)) {
        foreach ($policyName in Get-FeaturePolicies -Feature $feature) {
            if (-not $PolicyDefinitions.ContainsKey($policyName)) {
                throw "Feature '$($feature.id)' references undefined policy '$policyName'."
            }
        }
    }
}

function Set-FeatureSelection {
    param(
        [Parameter(Mandatory = $true)]$Feature,
        [Parameter(Mandatory = $true)]$PolicyNames,
        [Parameter(Mandatory = $true)]$SelectedFeatureIds,
        [Parameter(Mandatory = $true)][bool]$Selected
    )

    $featureId = [string]$Feature.id
    if ($Selected) {
        Add-StringIfMissing -List $SelectedFeatureIds -Value $featureId
        foreach ($policyName in Get-FeaturePolicies -Feature $Feature) {
            Add-StringIfMissing -List $PolicyNames -Value $policyName
        }
        return
    }

    Remove-StringFromList -List $SelectedFeatureIds -Value $featureId
    foreach ($policyName in Get-FeaturePolicies -Feature $Feature) {
        Remove-StringFromList -List $PolicyNames -Value $policyName
    }
}

function Read-FeatureChoice {
    param(
        [Parameter(Mandatory = $true)]$Feature,
        [Parameter(Mandatory = $true)][bool]$Default
    )

    $defaultLabel = if ($Default) { 'Y/n' } else { 'y/N' }
    $prompt = "Apply $($Feature.label) cleanup? [$defaultLabel]"
    while ($true) {
        $answer = (Read-Host $prompt).Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }
        switch ($answer.ToLowerInvariant()) {
            { $_ -in @('y', 'yes') } { return $true }
            { $_ -in @('n', 'no') } { return $false }
            default { Write-Host 'Please answer y or n.' }
        }
    }
}

function Resolve-FeatureSelection {
    param(
        [object[]]$Features,
        [Parameter(Mandatory = $true)][hashtable]$FeatureMap,
        [Parameter(Mandatory = $true)]$PolicyNames,
        [Parameter(Mandatory = $true)][string]$PresetName,
        [string[]]$IncludeNames,
        [string[]]$ExcludeNames,
        [switch]$UsePrompt
    )

    $selectedFeatureIds = New-Object System.Collections.Generic.List[string]
    foreach ($feature in @($Features)) {
        if (Test-FeatureSelectedByPolicy -Feature $feature -PolicyNames $PolicyNames -PresetName $PresetName) {
            Add-StringIfMissing -List $selectedFeatureIds -Value ([string]$feature.id)
        }
    }

    if ($UsePrompt) {
        foreach ($feature in @($Features)) {
            $default = $selectedFeatureIds.Contains([string]$feature.id)
            $selected = Read-FeatureChoice -Feature $feature -Default $default
            Set-FeatureSelection -Feature $feature -PolicyNames $PolicyNames -SelectedFeatureIds $selectedFeatureIds -Selected:$selected
        }
    }

    foreach ($featureName in @($IncludeNames)) {
        if ([string]::IsNullOrWhiteSpace([string]$featureName)) {
            continue
        }
        Set-FeatureSelection -Feature $FeatureMap[$featureName] -PolicyNames $PolicyNames -SelectedFeatureIds $selectedFeatureIds -Selected:$true
    }

    foreach ($featureName in @($ExcludeNames)) {
        if ([string]::IsNullOrWhiteSpace([string]$featureName)) {
            continue
        }
        Set-FeatureSelection -Feature $FeatureMap[$featureName] -PolicyNames $PolicyNames -SelectedFeatureIds $selectedFeatureIds -Selected:$false
    }

    return $selectedFeatureIds.ToArray()
}

function Assert-PolicySafety {
    param(
        [string[]]$PolicyNames,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $blockedNames = @($Manifest.safety.blockedPolicyNames)
    $blockedPatterns = @($Manifest.safety.blockedNamePatterns)

    foreach ($policyName in $PolicyNames) {
        if ($blockedNames -contains $policyName) {
            throw "Refusing to apply protected policy '$policyName'."
        }

        foreach ($pattern in $blockedPatterns) {
            if ($policyName -match $pattern) {
                throw "Refusing to apply '$policyName' because it matches protected pattern '$pattern'."
            }
        }
    }
}

function Assert-MobilePolicySupport {
    param(
        [string]$PlatformName,
        [string[]]$PolicyNames,
        [Parameter(Mandatory = $true)]$Manifest
    )

    if ($PlatformName -ne 'iOS') {
        return
    }

    $supported = @($Manifest.platformSupport.iOS)

    $unsupported = @($PolicyNames | Where-Object { $supported -notcontains $_ })
    if ($unsupported.Count -gt 0) {
        throw "iOS/iPadOS can export only Brave's documented mobile MDM policies. unsupported selected policies: $($unsupported -join ', '). Use -OnlyFeature Rewards, News, Talk, VPN, Playlist, or LeoAI, or export this preset for another platform."
    }
}

function Get-PolicySafetyFinding {
    param(
        [string[]]$PolicyNames,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $findings = New-Object System.Collections.Generic.List[string]
    $blockedNames = @($Manifest.safety.blockedPolicyNames)
    $blockedPatterns = @($Manifest.safety.blockedNamePatterns)

    foreach ($policyName in $PolicyNames) {
        if ($blockedNames -contains $policyName) {
            [void]$findings.Add("Protected policy '$policyName' is present.")
            continue
        }

        foreach ($pattern in $blockedPatterns) {
            if ($policyName -match $pattern) {
                [void]$findings.Add("Policy '$policyName' matches protected pattern '$pattern'.")
                break
            }
        }
    }

    return $findings.ToArray()
}
