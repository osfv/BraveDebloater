#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TemplateZipPath
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

if (-not (Test-Path -LiteralPath $TemplateZipPath)) {
    throw "Missing template zip: $TemplateZipPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $TemplateZipPath))
try {
    $versionText = Read-ZipEntryText -Zip $zip -EntryName 'VERSION'
    $templateVersion = Get-PolicyTemplateVersionFromText -VersionText $versionText
    if ($templateVersion -ne [string]$manifest.policyTemplateVersion) {
        throw "Manifest policyTemplateVersion '$($manifest.policyTemplateVersion)' does not match template '$templateVersion'."
    }

    $admx = Read-ZipEntryText -Zip $zip -EntryName 'windows/admx/brave.admx'
    $templatePolicies = @([regex]::Matches($admx, '<policy\b[^>]*\bname="([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -notmatch '_recommended$' } |
        Sort-Object -Unique)

    $deprecatedInTemplate = @{}
    foreach ($policyMatch in [regex]::Matches($admx, '<policy\b[^>]*\bname="([^"]+)"[^>]*>\s*<parentCategory\s+ref="DeprecatedPolicies"\s*/>')) {
        $templatePolicyName = $policyMatch.Groups[1].Value
        if ($templatePolicyName -match '_recommended$') {
            continue
        }
        $deprecatedInTemplate[$templatePolicyName] = $true
    }

    foreach ($tagMatch in [regex]::Matches($admx, '<policy\b[^>]*>')) {
        $tag = $tagMatch.Value
        $nameMatch = [regex]::Match($tag, '\bname="([^"]+)"')
        if (-not $nameMatch.Success) {
            continue
        }

        $templatePolicyName = $nameMatch.Groups[1].Value
        if ($templatePolicyName -match '_recommended$' -or $tag -notmatch '\bdeprecated="true"') {
            continue
        }
        $deprecatedInTemplate[$templatePolicyName] = $true
    }

    foreach ($policyName in @($manifest.policies.PSObject.Properties.Name)) {
        if ($templatePolicies -notcontains $policyName) {
            throw "Manifest policy '$policyName' is not present in the official Brave ADMX template."
        }
        if ($deprecatedInTemplate.ContainsKey($policyName)) {
            throw "Manifest policy '$policyName' is marked deprecated in the official Brave ADMX template."
        }
    }

    $deprecatedPolicyNames = @()
    if ($null -ne $manifest.PSObject.Properties['deprecatedPolicies']) {
        $deprecatedPolicyNames = @($manifest.deprecatedPolicies)
    }
    foreach ($policyName in $deprecatedPolicyNames) {
        if ($templatePolicies -contains $policyName -and -not $deprecatedInTemplate.ContainsKey($policyName)) {
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

Write-Host "Latest Brave template validation passed for $($manifest.policyTemplateVersion)."
