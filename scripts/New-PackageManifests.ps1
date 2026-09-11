#requires -Version 5.1
<#
.SYNOPSIS
Writes the winget manifests and the Scoop manifest for a published BraveDebloater release.

.DESCRIPTION
Reads the release's SHA256SUMS.txt (downloaded from GitHub unless -ChecksumPath points at a local copy),
then writes:

- packaging/winget/manifests/o/osfv/BraveDebloater/<version>/osfv.BraveDebloater.*.yaml, ready for
  `wingetcreate submit` or a pull request to microsoft/winget-pkgs. Uses BraveDebloater-v<version>-windows.zip.
- packaging/scoop/bravedebloater.json, which Scoop can install straight from the raw GitHub URL. Uses
  BraveDebloater-v<version>.zip.

Releases without a -windows.zip asset (before 0.5.0) only get the Scoop manifest.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v?[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$Version,

    [string]$ChecksumPath,

    [ValidatePattern('^[0-9]{4}-[0-9]{2}-[0-9]{2}$')]
    [string]$ReleaseDate = [DateTime]::UtcNow.ToString('yyyy-MM-dd'),

    [string]$WingetOutputPath,

    [string]$ScoopManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$repository = 'osfv/BraveDebloater'
$packageIdentifier = 'osfv.BraveDebloater'
$manifestVersion = '1.10.0'
$Version = $Version.TrimStart('v')
$tag = "v$Version"
$downloadBase = "https://github.com/$repository/releases/download/$tag"
$sourceArchiveName = "BraveDebloater-$tag.zip"
$windowsArchiveName = "BraveDebloater-$tag-windows.zip"

function Get-FullPath {
    param([string]$Path)

    # .NET file APIs resolve relative paths against the process directory, not the PowerShell location.
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path))
}

if ([string]::IsNullOrWhiteSpace($WingetOutputPath)) {
    $WingetOutputPath = Join-Path (Join-Path (Join-Path $root 'packaging') 'winget') 'manifests'
}
if ([string]::IsNullOrWhiteSpace($ScoopManifestPath)) {
    $ScoopManifestPath = Join-Path (Join-Path (Join-Path $root 'packaging') 'scoop') 'bravedebloater.json'
}
$WingetOutputPath = Get-FullPath -Path $WingetOutputPath
$ScoopManifestPath = Get-FullPath -Path $ScoopManifestPath
if (-not [string]::IsNullOrWhiteSpace($ChecksumPath)) {
    $ChecksumPath = Get-FullPath -Path $ChecksumPath
}

function Get-ChecksumMap {
    param([string]$Path)

    $map = @{}
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
            $map[$Matches[2]] = $Matches[1].ToLowerInvariant()
        }
    }
    if ($map.Count -eq 0) {
        throw "$Path contains no 'sha256  filename' lines."
    }
    return $map
}

function Write-Utf8File {
    param([string]$Path, [string[]]$Lines)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    # LF line endings and no BOM match .gitattributes and the winget-pkgs validation pipeline.
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

$tempChecksumPath = ''
try {
    if ([string]::IsNullOrWhiteSpace($ChecksumPath)) {
        $tempChecksumPath = Join-Path ([System.IO.Path]::GetTempPath()) ('BraveDebloaterSums-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        $checksumUrl = "$downloadBase/SHA256SUMS.txt"
        Write-Host "Downloading $checksumUrl"
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }
        Invoke-WebRequest -Uri $checksumUrl -OutFile $tempChecksumPath -UseBasicParsing
        $ChecksumPath = $tempChecksumPath
    }
    $checksums = Get-ChecksumMap -Path $ChecksumPath

    if (-not $checksums.ContainsKey($sourceArchiveName)) {
        throw "SHA256SUMS.txt has no entry for $sourceArchiveName."
    }
    $sourceHash = $checksums[$sourceArchiveName]

    $scoopLines = @(
        '{'
        "    `"version`": `"$Version`","
        '    "description": "Removes Brave Browser extras with Brave and Chromium enterprise policies. Dry-run by default; nothing changes without -Apply.",'
        "    `"homepage`": `"https://github.com/$repository`","
        '    "license": "MIT",'
        "    `"url`": `"$downloadBase/$sourceArchiveName`","
        "    `"hash`": `"$sourceHash`","
        "    `"extract_dir`": `"BraveDebloater-$tag`","
        '    "bin": ['
        '        ['
        '            "Invoke-BraveDebloat.ps1",'
        '            "bravedebloat"'
        '        ]'
        '    ],'
        '    "persist": "backups",'
        '    "checkver": {'
        "        `"github`": `"https://github.com/$repository`""
        '    },'
        '    "autoupdate": {'
        "        `"url`": `"https://github.com/$repository/releases/download/v`$version/BraveDebloater-v`$version.zip`","
        '        "extract_dir": "BraveDebloater-v$version",'
        '        "hash": {'
        '            "url": "$baseurl/SHA256SUMS.txt"'
        '        }'
        '    }'
        '}'
    )
    Write-Utf8File -Path $ScoopManifestPath -Lines $scoopLines
    Write-Host "Wrote $ScoopManifestPath"

    if (-not $checksums.ContainsKey($windowsArchiveName)) {
        Write-Warning "SHA256SUMS.txt has no entry for $windowsArchiveName, so no winget manifests were written. Releases before 0.5.0 have no Windows zip with the BraveDebloat.exe launcher."
        return
    }
    $windowsHash = $checksums[$windowsArchiveName].ToUpperInvariant()

    $manifestDirectory = Join-Path (Join-Path (Join-Path (Join-Path $WingetOutputPath 'o') 'osfv') 'BraveDebloater') $Version

    Write-Utf8File -Path (Join-Path $manifestDirectory "$packageIdentifier.yaml") -Lines @(
        "# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.$manifestVersion.schema.json"
        ''
        "PackageIdentifier: $packageIdentifier"
        "PackageVersion: $Version"
        'DefaultLocale: en-US'
        'ManifestType: version'
        "ManifestVersion: $manifestVersion"
    )

    Write-Utf8File -Path (Join-Path $manifestDirectory "$packageIdentifier.installer.yaml") -Lines @(
        "# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.$manifestVersion.schema.json"
        ''
        "PackageIdentifier: $packageIdentifier"
        "PackageVersion: $Version"
        'InstallerType: zip'
        'NestedInstallerType: portable'
        'NestedInstallerFiles:'
        '- RelativeFilePath: BraveDebloat.exe'
        '  PortableCommandAlias: BraveDebloat'
        # The launcher needs Invoke-BraveDebloat.ps1 and src/ next to it, so the whole extracted folder
        # is added to PATH instead of a lone symlink to the exe.
        'ArchiveBinariesDependOnPath: true'
        'UpgradeBehavior: uninstallPrevious'
        'Commands:'
        '- BraveDebloat'
        "ReleaseDate: $ReleaseDate"
        'Installers:'
        '- Architecture: neutral'
        "  InstallerUrl: $downloadBase/$windowsArchiveName"
        "  InstallerSha256: $windowsHash"
        'ManifestType: installer'
        "ManifestVersion: $manifestVersion"
    )

    Write-Utf8File -Path (Join-Path $manifestDirectory "$packageIdentifier.locale.en-US.yaml") -Lines @(
        "# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.$manifestVersion.schema.json"
        ''
        "PackageIdentifier: $packageIdentifier"
        "PackageVersion: $Version"
        'PackageLocale: en-US'
        'Publisher: osfv'
        'PublisherUrl: https://github.com/osfv'
        "PublisherSupportUrl: https://github.com/$repository/issues"
        'PackageName: BraveDebloater'
        "PackageUrl: https://github.com/$repository"
        'License: MIT'
        "LicenseUrl: https://github.com/$repository/blob/main/LICENSE"
        'Copyright: Copyright (c) osfv'
        'ShortDescription: Removes Brave Browser extras with Brave and Chromium enterprise policies. Dry-run by default.'
        'Description: |-'
        '  BraveDebloater turns off Brave Rewards, Wallet, VPN, Leo AI, News, Talk, Playlist, telemetry pings, and other'
        '  extras through the enterprise policies Brave documents, so the result shows up in brave://policy and can be'
        '  restored from a backup. Run BraveDebloat for a preview; nothing changes until you add -Apply. It never disables'
        '  Brave updates, Shields, or Safe Browsing. Optional DNS-over-HTTPS control and per-profile cleanup are included.'
        'Moniker: bravedebloater'
        'Tags:'
        '- brave'
        '- browser'
        '- debloat'
        '- policy'
        '- powershell'
        '- privacy'
        "ReleaseNotesUrl: https://github.com/$repository/releases/tag/$tag"
        'Documentations:'
        '- DocumentLabel: README'
        "  DocumentUrl: https://github.com/$repository/blob/$tag/README.md"
        'ManifestType: defaultLocale'
        "ManifestVersion: $manifestVersion"
    )
    Write-Host "Wrote winget manifests to $manifestDirectory"
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($tempChecksumPath) -and (Test-Path -LiteralPath $tempChecksumPath)) {
        Remove-Item -LiteralPath $tempChecksumPath -Force
    }
}
