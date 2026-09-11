#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TemplateZipPath,

    # By default a newer template than the manifest records is accepted with a warning, because
    # the "latest" zip moves with every Brave release. Pass this for release checks that must match.
    [switch]$RequireVersionMatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path (Join-Path $root 'config') 'policies.json'

. (Join-Path $PSScriptRoot 'PolicyTemplateVersion.ps1')

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-ZipEntryText {
    param(
        [Parameter(Mandatory = $true)]$Zip,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    $entry = $Zip.GetEntry($EntryName)
    if ($null -eq $entry) {
        throw "Template zip is missing '$EntryName'."
    }

    $stream = $entry.Open()
    try {
        $reader = New-Object System.IO.StreamReader($stream, $true)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function ConvertTo-VersionOrNull {
    param([string]$Text)

    $parsed = $null
    if ([version]::TryParse($Text, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-AdmxDecimalValues {
    param(
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)][string]$XPath
    )

    $values = New-Object System.Collections.Generic.List[long]
    foreach ($decimal in $Node.SelectNodes($XPath)) {
        $text = [string]$decimal.GetAttribute('value')
        $number = [long]0
        if ([long]::TryParse($text, [ref]$number)) {
            [void]$values.Add($number)
        }
    }
    return $values.ToArray()
}

function Assert-AdmxValueType {
    param(
        [Parameter(Mandatory = $true)][string]$PolicyName,
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $true)]$Node
    )

    # Linux JSON and macOS plist writers turn DWord 0/1 into booleans and keep other numbers as
    # integers, so a manifest DWord must be a boolean policy when its value is 0/1 and an enum or
    # integer policy otherwise. Brave rejects a boolean where it expects an integer and vice versa.
    $type = [string]$Policy.type
    $enabledValues = @(Get-AdmxDecimalValues -Node $Node -XPath 'enabledValue/decimal')
    $disabledValues = @(Get-AdmxDecimalValues -Node $Node -XPath 'disabledValue/decimal')
    $enumValues = @(Get-AdmxDecimalValues -Node $Node -XPath 'elements/enum/item/value/decimal')
    $decimalElements = @($Node.SelectNodes('elements/decimal'))
    $textElements = @($Node.SelectNodes('elements/text'))

    if ($type -eq 'String') {
        if ($textElements.Count -eq 0) {
            throw "Manifest policy '$PolicyName' is a String but the official Brave ADMX template does not define it as a text policy."
        }
        return
    }

    $value = [long]$Policy.value
    $isBooleanPolicy = $enabledValues.Count -gt 0 -and $disabledValues.Count -gt 0
    if ($isBooleanPolicy -and $enumValues.Count -eq 0 -and $decimalElements.Count -eq 0) {
        if ($value -ne 0 -and $value -ne 1) {
            throw "Manifest policy '$PolicyName' has value $value but the official Brave ADMX template defines it as a boolean policy (0 or 1)."
        }
        return
    }

    if ($enumValues.Count -gt 0) {
        if ($enumValues -notcontains $value) {
            throw "Manifest policy '$PolicyName' has value $value which is not one of the enum values in the official Brave ADMX template: $($enumValues -join ', ')."
        }
        if ($value -eq 0 -or $value -eq 1) {
            throw "Manifest policy '$PolicyName' uses value $value for an enum policy. Managed JSON and plist writers would emit a boolean, which Brave rejects for integer policies. Pick a different representation before adding this policy."
        }
        return
    }

    if ($decimalElements.Count -gt 0) {
        if ($value -eq 0 -or $value -eq 1) {
            throw "Manifest policy '$PolicyName' uses value $value for an integer policy. Managed JSON and plist writers would emit a boolean, which Brave rejects for integer policies."
        }
        return
    }

    throw "Manifest policy '$PolicyName' is a DWord but the official Brave ADMX template does not define it as a boolean, enum, or integer policy."
}

if (-not (Test-Path -LiteralPath $TemplateZipPath)) {
    throw "Missing template zip: $TemplateZipPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$manifestVersion = [string]$manifest.policyTemplateVersion
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $TemplateZipPath))
try {
    $versionText = Read-ZipEntryText -Zip $zip -EntryName 'VERSION'
    $templateVersion = Get-PolicyTemplateVersionFromText -VersionText $versionText
    $versionNote = ''
    if ($templateVersion -ne $manifestVersion) {
        $parsedTemplate = ConvertTo-VersionOrNull -Text $templateVersion
        $parsedManifest = ConvertTo-VersionOrNull -Text $manifestVersion
        $templateIsNewer = ($null -ne $parsedTemplate) -and ($null -ne $parsedManifest) -and ($parsedTemplate -gt $parsedManifest)
        if ($RequireVersionMatch -or -not $templateIsNewer) {
            throw "Manifest policyTemplateVersion '$manifestVersion' does not match template '$templateVersion'. Run scripts/Update-PolicyTemplateVersion.ps1 -TemplateZipPath '$TemplateZipPath' after checking the policy changes."
        }
        Write-Warning "Template '$templateVersion' is newer than the manifest's recorded '$manifestVersion'. Policies still validate; run scripts/Update-PolicyTemplateVersion.ps1 to record the new version."
        $versionNote = " (manifest records $manifestVersion)"
    }

    $admxText = Read-ZipEntryText -Zip $zip -EntryName 'windows/admx/brave.admx'
    [xml]$admx = $admxText
    $templatePolicies = @{}
    $deprecatedInTemplate = @{}
    foreach ($node in $admx.SelectNodes('//policy')) {
        $templatePolicyName = [string]$node.GetAttribute('name')
        if ([string]::IsNullOrWhiteSpace($templatePolicyName) -or $templatePolicyName -match '_recommended$') {
            continue
        }
        $templatePolicies[$templatePolicyName] = $node

        $parentCategory = $node.SelectSingleNode('parentCategory')
        $parentRef = if ($null -ne $parentCategory) { [string]$parentCategory.GetAttribute('ref') } else { '' }
        if ($parentRef -eq 'DeprecatedPolicies' -or [string]$node.GetAttribute('deprecated') -eq 'true') {
            $deprecatedInTemplate[$templatePolicyName] = $true
        }
    }

    foreach ($policyName in @($manifest.policies.PSObject.Properties.Name)) {
        if (-not $templatePolicies.ContainsKey($policyName)) {
            throw "Manifest policy '$policyName' is not present in the official Brave ADMX template."
        }
        if ($deprecatedInTemplate.ContainsKey($policyName)) {
            throw "Manifest policy '$policyName' is marked deprecated in the official Brave ADMX template."
        }
        Assert-AdmxValueType -PolicyName $policyName -Policy $manifest.policies.$policyName -Node $templatePolicies[$policyName]
    }

    $deprecatedPolicyNames = @()
    if ($null -ne $manifest.PSObject.Properties['deprecatedPolicies']) {
        $deprecatedPolicyNames = @($manifest.deprecatedPolicies)
    }
    foreach ($policyName in $deprecatedPolicyNames) {
        if ($templatePolicies.ContainsKey($policyName) -and -not $deprecatedInTemplate.ContainsKey($policyName)) {
            throw "Manifest deprecatedPolicies entry '$policyName' is still present in the official Brave ADMX template without a DeprecatedPolicies category."
        }
    }

    $iosSupported = @($manifest.platformSupport.iOS)
    foreach ($policyName in $iosSupported) {
        if ($null -eq $manifest.policies.PSObject.Properties[$policyName]) {
            throw "iOS platform support references undefined policy '$policyName'."
        }
    }
}
finally {
    $zip.Dispose()
}

Write-Host "Latest Brave template validation passed for $templateVersion$versionNote."
