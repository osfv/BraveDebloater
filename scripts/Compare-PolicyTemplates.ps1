#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TemplateZipPath,
    [string]$SnapshotPath,
    [string]$SummaryPath,
    [switch]$Update
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PolicyTemplateVersion.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $SnapshotPath = Join-Path (Join-Path $root 'config') 'policy-template-snapshot.json'
}
if (-not (Test-Path -LiteralPath $TemplateZipPath)) {
    throw "Missing template zip: $TemplateZipPath"
}

function Read-TemplateEntryText {
    param($Zip, [string]$EntryName)

    $entry = $Zip.GetEntry($EntryName)
    if ($null -eq $entry) {
        throw "Template zip is missing '$EntryName'."
    }
    $reader = New-Object System.IO.StreamReader($entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $TemplateZipPath))
try {
    $templateVersion = Get-PolicyTemplateVersionFromText -VersionText (Read-TemplateEntryText -Zip $zip -EntryName 'VERSION')
    [xml]$admx = Read-TemplateEntryText -Zip $zip -EntryName 'windows/admx/brave.admx'
}
finally {
    $zip.Dispose()
}

$active = New-Object System.Collections.Generic.SortedSet[string]([System.StringComparer]::Ordinal)
$deprecated = New-Object System.Collections.Generic.SortedSet[string]([System.StringComparer]::Ordinal)
foreach ($node in $admx.SelectNodes('//policy')) {
    $name = [string]$node.GetAttribute('name')
    if ([string]::IsNullOrWhiteSpace($name) -or $name -match '_recommended$') {
        continue
    }
    $parentCategory = $node.SelectSingleNode('parentCategory')
    $parentRef = if ($null -ne $parentCategory) { [string]$parentCategory.GetAttribute('ref') } else { '' }
    if ($parentRef -eq 'DeprecatedPolicies' -or [string]$node.GetAttribute('deprecated') -eq 'true') {
        [void]$deprecated.Add($name)
    }
    else {
        [void]$active.Add($name)
    }
}

$previousVersion = ''
$previousActive = @()
$previousDeprecated = @()
if (Test-Path -LiteralPath $SnapshotPath) {
    $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json
    $previousVersion = [string]$snapshot.templateVersion
    $previousActive = @($snapshot.policies)
    $previousDeprecated = @($snapshot.deprecatedPolicies)
}

$added = @($active | Where-Object { $previousActive -notcontains $_ -and $previousDeprecated -notcontains $_ })
$removed = @(@($previousActive) + @($previousDeprecated) | Where-Object { -not $active.Contains($_) -and -not $deprecated.Contains($_) } | Sort-Object -Unique)
$newlyDeprecated = @($deprecated | Where-Object { $previousDeprecated -notcontains $_ })
$reactivated = @($active | Where-Object { $previousDeprecated -contains $_ })

$manifest = Get-Content -LiteralPath (Join-Path (Join-Path $root 'config') 'policies.json') -Raw | ConvertFrom-Json
$managed = @($manifest.policies.PSObject.Properties.Name)
$managedAffected = @($managed | Where-Object { $removed -contains $_ -or $newlyDeprecated -contains $_ })

$policiesChanged = ($added.Count + $removed.Count + $newlyDeprecated.Count + $reactivated.Count) -gt 0
$changed = $policiesChanged -or ($templateVersion -ne $previousVersion)

$lines = New-Object System.Collections.Generic.List[string]
$fromText = if ($previousVersion) { $previousVersion } else { '(no snapshot)' }
[void]$lines.Add("Brave policy templates: $fromText -> $templateVersion")
[void]$lines.Add('')
if ($managedAffected.Count -gt 0) {
    [void]$lines.Add("**Action needed:** BraveDebloater manages $($managedAffected.Count) policy value(s) that Brave removed or deprecated: $(($managedAffected | ForEach-Object { '`' + $_ + '`' }) -join ', '). Update config/policies.json and docs/debloatable-validation.md before merging.")
    [void]$lines.Add('')
}
foreach ($section in @(
        @{ Title = 'New policies'; Items = $added },
        @{ Title = 'Removed policies'; Items = $removed },
        @{ Title = 'Newly deprecated policies'; Items = $newlyDeprecated },
        @{ Title = 'No longer deprecated policies'; Items = $reactivated }
    )) {
    [void]$lines.Add("### $($section.Title) ($(@($section.Items).Count))")
    if (@($section.Items).Count -eq 0) {
        [void]$lines.Add('None.')
    }
    foreach ($item in @($section.Items)) {
        $marker = if ($managed -contains $item) { ' (managed by BraveDebloater)' } else { '' }
        [void]$lines.Add("- ``$item``$marker")
    }
    [void]$lines.Add('')
}
if (-not $policiesChanged) {
    [void]$lines.Add('Only the template version changed. No policies were added, removed, deprecated, or reactivated.')
}
$summary = $lines.ToArray() -join "`n"

if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
    [System.IO.File]::WriteAllText($SummaryPath, $summary + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

if ($Update -and $changed) {
    $newSnapshot = [ordered]@{
        templateVersion = $templateVersion
        policies = @($active)
        deprecatedPolicies = @($deprecated)
    }
    $json = ConvertTo-Json -InputObject $newSnapshot -Depth 4
    [System.IO.File]::WriteAllText($SnapshotPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host $summary
if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "changed=$($changed.ToString().ToLowerInvariant())"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "template_version=$templateVersion"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "managed_affected=$($managedAffected.Count)"
}
