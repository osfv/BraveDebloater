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
$validationDocPath = Join-Path (Join-Path $root 'docs') 'debloatable-validation.md'

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

function Get-TemplateVersion {
    param([Parameter(Mandatory = $true)]$Zip)

    $versionText = Read-ZipEntryText -Zip $Zip -EntryName 'VERSION'
    return Get-PolicyTemplateVersionFromText -VersionText $versionText
}

function Set-Utf8NoBomText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path), $Content, $encoding)
}

if (-not (Test-Path -LiteralPath $TemplateZipPath)) {
    throw "Missing template zip: $TemplateZipPath"
}

$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $TemplateZipPath))
try {
    $templateVersion = Get-TemplateVersion -Zip $zip
}
finally {
    $zip.Dispose()
}

$manifestText = Get-Content -LiteralPath $manifestPath -Raw
$oldVersion = [regex]::Match($manifestText, '"policyTemplateVersion":\s*"([^"]+)"').Groups[1].Value
if ([string]::IsNullOrWhiteSpace($oldVersion)) {
    throw "Could not find policyTemplateVersion in $manifestPath."
}

$manifestText = [regex]::Replace($manifestText, '"policyTemplateVersion":\s*"[^"]+"', ('"policyTemplateVersion": "{0}"' -f $templateVersion), 1)
Set-Utf8NoBomText -Path $manifestPath -Content $manifestText

$docText = Get-Content -LiteralPath $validationDocPath -Raw
$docText = [regex]::Replace($docText, 'Template version: `[^`]+`', ('Template version: `{0}`' -f $templateVersion), 1)
$docText = [regex]::Replace($docText, 'changed from `([^`]+)` to `[^`]+`', ('changed from `$1` to `{0}`' -f $templateVersion), 1)
Set-Utf8NoBomText -Path $validationDocPath -Content $docText

Write-Host "Updated policy template version from $oldVersion to $templateVersion."
