#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path (Join-Path $root 'config') 'policies.json'
$scriptPath = Join-Path $root 'Invoke-BraveDebloat.ps1'

function Get-ObjectMap {
    param([Parameter(Mandatory = $true)]$Object)

    $map = @{}
    foreach ($property in $Object.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }
    return $map
}

function Resolve-Preset {
    param(
        [string]$Name,
        [hashtable]$Presets,
        [hashtable]$Seen = @{}
    )

    if (-not $Presets.ContainsKey($Name)) {
        throw "Unknown preset '$Name'."
    }
    if ($Seen.ContainsKey($Name)) {
        throw "Preset cycle detected at '$Name'."
    }

    $Seen[$Name] = $true
    $items = New-Object System.Collections.Generic.List[string]

    foreach ($entry in @($Presets[$Name])) {
        if ($entry -isnot [string]) {
            throw "Preset '$Name' contains a non-string entry."
        }
        if ($entry.StartsWith('@')) {
            foreach ($child in Resolve-Preset -Name $entry.Substring(1) -Presets $Presets -Seen ($Seen.Clone())) {
                if (-not $items.Contains($child)) {
                    [void]$items.Add($child)
                }
            }
        }
        elseif (-not $items.Contains($entry)) {
            [void]$items.Add($entry)
        }
    }

    return $items.ToArray()
}

function Test-PolicyTemplateVersionUpdater {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('BraveDebloaterTemplateVersion-{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path (Join-Path $tempRoot 'scripts') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tempRoot 'config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tempRoot 'docs') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'scripts/Update-PolicyTemplateVersion.ps1') -Destination (Join-Path $tempRoot 'scripts/Update-PolicyTemplateVersion.ps1')
        Copy-Item -LiteralPath (Join-Path $root 'scripts/PolicyTemplateVersion.ps1') -Destination (Join-Path $tempRoot 'scripts/PolicyTemplateVersion.ps1')
        Set-Content -LiteralPath (Join-Path $tempRoot 'config/policies.json') -Value '{"policyTemplateVersion": "0.0.0.0"}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $tempRoot 'docs/debloatable-validation.md') -Value 'Template version: `0.0.0.0`' -Encoding UTF8

        $zipRoot = Join-Path $tempRoot 'zip'
        New-Item -ItemType Directory -Path $zipRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $zipRoot 'VERSION') -Value "PATCH=4`nBUILD=3`nMAJOR=1`nMINOR=2" -Encoding UTF8
        $zipPath = Join-Path $tempRoot 'template.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($zipRoot, $zipPath)

        & (Join-Path $tempRoot 'scripts/Update-PolicyTemplateVersion.ps1') -TemplateZipPath $zipPath *> $null
        $updated = Get-Content -LiteralPath (Join-Path $tempRoot 'config/policies.json') -Raw | ConvertFrom-Json
        if ([string]$updated.policyTemplateVersion -ne '1.2.3.4') {
            throw 'Update-PolicyTemplateVersion.ps1 did not assemble shuffled VERSION keys by name.'
        }
        foreach ($updatedPath in @((Join-Path $tempRoot 'config/policies.json'), (Join-Path $tempRoot 'docs/debloatable-validation.md'))) {
            $bytes = [System.IO.File]::ReadAllBytes($updatedPath)
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
                throw "Update-PolicyTemplateVersion.ps1 wrote a UTF-8 BOM to $updatedPath."
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing manifest: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([int]$manifest.schemaVersion -ne 1) {
    throw "Unsupported manifest schema version '$($manifest.schemaVersion)'."
}
if ([string]::IsNullOrWhiteSpace([string]$manifest.policyTemplateVersion)) {
    throw 'Manifest is missing policyTemplateVersion.'
}

$policies = Get-ObjectMap -Object $manifest.policies
$presets = Get-ObjectMap -Object $manifest.presets
$features = @($manifest.features)
$featureIds = New-Object System.Collections.Generic.List[string]
$blockedNames = @($manifest.safety.blockedPolicyNames)
$blockedPatterns = @($manifest.safety.blockedNamePatterns)
$platformSupport = Get-ObjectMap -Object $manifest.platformSupport
$deprecatedPolicyNames = @('PrivacySandboxPromptEnabled', 'PromotionalTabsEnabled')

foreach ($deprecatedPolicyName in $deprecatedPolicyNames) {
    if ($policies.ContainsKey($deprecatedPolicyName)) {
        throw "Manifest must not include deprecated policy '$deprecatedPolicyName'."
    }
}

foreach ($platformName in @('Windows', 'macOS', 'Linux', 'Android', 'iOS')) {
    if (-not $platformSupport.ContainsKey($platformName)) {
        throw "Manifest platformSupport is missing '$platformName'."
    }
}

foreach ($platformName in @('Windows', 'macOS', 'Linux')) {
    if ([string]$platformSupport[$platformName] -ne 'official-template') {
        throw "Manifest platformSupport '$platformName' must be 'official-template'."
    }
}
if ([string]$platformSupport['Android'] -ne 'mdm-no-template') {
    throw "Manifest platformSupport 'Android' must be 'mdm-no-template'."
}

foreach ($presetName in $presets.Keys) {
    foreach ($policyName in Resolve-Preset -Name $presetName -Presets $presets) {
        if (-not $policies.ContainsKey($policyName)) {
            throw "Preset '$presetName' references undefined policy '$policyName'."
        }
        if ($blockedNames -contains $policyName) {
            throw "Preset '$presetName' references blocked policy '$policyName'."
        }
        foreach ($pattern in $blockedPatterns) {
            if ($policyName -match $pattern) {
                throw "Preset '$presetName' policy '$policyName' matches blocked pattern '$pattern'."
            }
        }
    }
}

foreach ($policyName in $policies.Keys) {
    $policy = $policies[$policyName]
    if (@('DWord', 'String') -notcontains [string]$policy.type) {
        throw "Policy '$policyName' has unsupported type '$($policy.type)'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$policy.reason)) {
        throw "Policy '$policyName' is missing a reason."
    }
    if ([string]::IsNullOrWhiteSpace([string]$policy.category)) {
        throw "Policy '$policyName' is missing a category."
    }
    if ($policy.type -eq 'DWord' -and $policy.value -isnot [int] -and $policy.value -isnot [long]) {
        throw "Policy '$policyName' is DWord but has non-integer value '$($policy.value)'."
    }
    if ($policy.type -eq 'DWord' -and ([long]$policy.value -lt 0 -or [long]$policy.value -gt [uint32]::MaxValue)) {
        throw "Policy '$policyName' has DWord value outside the registry range: $($policy.value)."
    }
}

foreach ($policyName in @($platformSupport['iOS'])) {
    if (-not $policies.ContainsKey([string]$policyName)) {
        throw "Manifest platformSupport iOS references undefined policy '$policyName'."
    }
}

foreach ($feature in $features) {
    $featureId = [string]$feature.id
    if ([string]::IsNullOrWhiteSpace($featureId)) {
        throw 'Feature entry is missing an id.'
    }
    if ($featureIds.Contains($featureId)) {
        throw "Duplicate feature id '$featureId'."
    }
    [void]$featureIds.Add($featureId)

    if ([string]::IsNullOrWhiteSpace([string]$feature.label)) {
        throw "Feature '$featureId' is missing a label."
    }
    if ([string]::IsNullOrWhiteSpace([string]$feature.reason)) {
        throw "Feature '$featureId' is missing a reason."
    }
    if ($null -eq $feature.PSObject.Properties['policies']) {
        throw "Feature '$featureId' is missing policies."
    }

    foreach ($policyName in @($feature.policies)) {
        if (-not $policies.ContainsKey([string]$policyName)) {
            throw "Feature '$featureId' references undefined policy '$policyName'."
        }
    }
}

foreach ($patch in @($manifest.profilePreferencePatches)) {
    if ([string]::IsNullOrWhiteSpace([string]$patch.path)) {
        throw 'Profile patch is missing a path.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$patch.feature)) {
        throw "Profile patch '$($patch.path)' is missing a feature id."
    }
    if (-not $featureIds.Contains([string]$patch.feature)) {
        throw "Profile patch '$($patch.path)' references unknown feature '$($patch.feature)'."
    }
    if ([string]$patch.path -match '(?i)shield') {
        throw "Profile patch '$($patch.path)' mentions Shields."
    }
    if ($patch.createMissing -isnot [bool]) {
        throw "Profile patch '$($patch.path)' has non-boolean createMissing value."
    }
    if ([string]::IsNullOrWhiteSpace([string]$patch.reason)) {
        throw "Profile patch '$($patch.path)' is missing a reason."
    }
}

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
    $messages = $parseErrors | ForEach-Object { $_.Message }
    throw "PowerShell parse errors in Invoke-BraveDebloat.ps1: $($messages -join '; ')"
}

Test-PolicyTemplateVersionUpdater

Write-Host 'Policy manifest and PowerShell syntax checks passed.'
