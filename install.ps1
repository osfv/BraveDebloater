#requires -Version 5.1
<#
.SYNOPSIS
Downloads the latest BraveDebloater release, verifies its SHA256 checksum, and extracts it to a folder you control.

.DESCRIPTION
One-line install (Windows PowerShell 5.1 or PowerShell 7 on any platform):

    irm https://raw.githubusercontent.com/osfv/BraveDebloater/main/install.ps1 | iex

Pass options by turning the download into a script block:

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/osfv/BraveDebloater/main/install.ps1))) -Version 0.4.0 -Destination C:\Tools\BraveDebloater

Nothing about Brave is changed by this script. It only places the tool on disk and prints the preview command to run next.
Re-running it upgrades an existing install in place and keeps the backups/ folder.

.PARAMETER Version
Release to install, for example 0.4.0 or v0.4.0. Default: the latest GitHub release.

.PARAMETER Destination
Folder to install into. Default: %LOCALAPPDATA%\Programs\BraveDebloater on Windows, $XDG_DATA_HOME/BraveDebloater or ~/.local/share/BraveDebloater elsewhere.

.PARAMETER ArchivePath
Install from a release zip you already downloaded instead of fetching one. The matching SHA256SUMS.txt is still required.

.PARAMETER ChecksumPath
SHA256SUMS.txt that belongs to -ArchivePath. Default: SHA256SUMS.txt next to the archive.
#>
[CmdletBinding()]
param(
    [string]$Version,

    [string]$Destination,

    [string]$ArchivePath,

    [string]$ChecksumPath
)

function Install-BraveDebloater {
    [CmdletBinding()]
    param(
        [string]$Version,
        [string]$Destination,
        [string]$ArchivePath,
        [string]$ChecksumPath
    )

    # Everything lives inside this function so `irm | iex` leaves the caller's session settings alone.
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $repository = 'osfv/BraveDebloater'
    $entrypointName = 'Invoke-BraveDebloat.ps1'
    $checksumFileName = 'SHA256SUMS.txt'
    $isWindowsHost = $env:OS -eq 'Windows_NT'

    function Write-InstallStep {
        param([string]$Message)
        Write-Host $Message
    }

    function Get-DefaultDestination {
        if ($isWindowsHost) {
            if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
                return Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'BraveDebloater'
            }
            return Join-Path $HOME 'BraveDebloater'
        }
        $dataHome = $env:XDG_DATA_HOME
        if ([string]::IsNullOrWhiteSpace($dataHome)) {
            $dataHome = Join-Path (Join-Path $HOME '.local') 'share'
        }
        return Join-Path $dataHome 'BraveDebloater'
    }

    function Get-FullPath {
        param([string]$Path)
        if ([System.IO.Path]::IsPathRooted($Path)) {
            return [System.IO.Path]::GetFullPath($Path)
        }
        return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path))
    }

    function Get-LatestReleaseTag {
        # The /releases/latest redirect needs no API quota. The REST API is the fallback.
        $latestUrl = "https://github.com/$repository/releases/latest"
        $location = ''
        try {
            $request = [System.Net.HttpWebRequest]::Create($latestUrl)
            $request.AllowAutoRedirect = $false
            $request.UserAgent = 'BraveDebloater-install'
            $request.Timeout = 30000
            $response = $request.GetResponse()
            try {
                $location = [string]$response.Headers['Location']
            }
            finally {
                $response.Close()
            }
        }
        catch [System.Net.WebException] {
            $errorResponse = $_.Exception.Response
            if ($null -ne $errorResponse) {
                $location = [string]$errorResponse.Headers['Location']
            }
        }
        if ($location -match '/releases/tag/(v[0-9]+\.[0-9]+\.[0-9]+)/?$') {
            return $Matches[1]
        }

        $apiUrl = "https://api.github.com/repos/$repository/releases/latest"
        $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'BraveDebloater-install'; Accept = 'application/vnd.github+json' } -UseBasicParsing
        $tag = [string]$release.tag_name
        if ($tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
            throw "Could not read the latest release tag from GitHub (got '$tag'). Pass -Version, for example -Version 0.4.0."
        }
        return $tag
    }

    function Save-ReleaseFile {
        param([string]$Url, [string]$OutFile)
        Write-InstallStep "Downloading $Url"
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -Headers @{ 'User-Agent' = 'BraveDebloater-install' }
        }
        catch {
            throw "Download failed for $Url ($($_.Exception.Message)). Check the version exists at https://github.com/$repository/releases and that you are online."
        }
    }

    function Get-ExpectedChecksum {
        param([string]$Path, [string]$FileName)
        foreach ($line in @(Get-Content -LiteralPath $Path)) {
            if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $FileName) {
                return $Matches[1].ToLowerInvariant()
            }
        }
        throw "$(Split-Path -Leaf $Path) has no SHA256 entry for $FileName. Download both files from the same release."
    }

    function Get-ArchiveContentRoot {
        param([string]$ExtractRoot)
        if (Test-Path -LiteralPath (Join-Path $ExtractRoot $entrypointName)) {
            return $ExtractRoot
        }
        $candidates = @([System.IO.Directory]::GetDirectories($ExtractRoot) | Where-Object { Test-Path -LiteralPath (Join-Path $_ $entrypointName) })
        if ($candidates.Count -ne 1) {
            throw "The archive does not contain $entrypointName at its top level or in a single folder. Is this a BraveDebloater release zip?"
        }
        return $candidates[0]
    }

    function Get-ToolVersionFromFolder {
        param([string]$Folder)
        $entrypoint = Join-Path $Folder $entrypointName
        if (-not (Test-Path -LiteralPath $entrypoint)) {
            return ''
        }
        $match = Select-String -LiteralPath $entrypoint -Pattern "^\`$ToolVersion = '([^']+)'" | Select-Object -First 1
        if ($null -eq $match) {
            return ''
        }
        return $match.Matches[0].Groups[1].Value
    }

    function Copy-DirectoryTree {
        param([string]$Source, [string]$Target)
        # .NET calls keep paths literal, so folders with [ or ] in the name copy correctly on PowerShell 5.1.
        [void][System.IO.Directory]::CreateDirectory($Target)
        foreach ($file in [System.IO.Directory]::GetFiles($Source)) {
            [System.IO.File]::Copy($file, (Join-Path $Target ([System.IO.Path]::GetFileName($file))), $true)
        }
        foreach ($directory in [System.IO.Directory]::GetDirectories($Source)) {
            Copy-DirectoryTree -Source $directory -Target (Join-Path $Target ([System.IO.Path]::GetFileName($directory)))
        }
    }

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }

    if ([string]::IsNullOrWhiteSpace($Destination)) {
        $Destination = Get-DefaultDestination
    }
    $Destination = Get-FullPath -Path $Destination

    $requestedVersion = ''
    if (-not [string]::IsNullOrWhiteSpace($Version) -and $Version -ne 'latest') {
        if ($Version -notmatch '^v?([0-9]+\.[0-9]+\.[0-9]+)$') {
            throw "-Version must look like 0.4.0 or v0.4.0, got '$Version'."
        }
        $requestedVersion = $Matches[1]
    }
    if (-not [string]::IsNullOrWhiteSpace($ArchivePath) -and -not [string]::IsNullOrWhiteSpace($requestedVersion)) {
        throw '-Version has no effect with -ArchivePath. The archive decides which version is installed.'
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('BraveDebloaterInstall-{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        [void][System.IO.Directory]::CreateDirectory($tempRoot)

        if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
            if ([string]::IsNullOrWhiteSpace($requestedVersion)) {
                $tag = Get-LatestReleaseTag
                Write-InstallStep "Latest release: $tag"
            }
            else {
                $tag = "v$requestedVersion"
            }
            $archiveName = "BraveDebloater-$tag.zip"
            $downloadBase = "https://github.com/$repository/releases/download/$tag"
            $ArchivePath = Join-Path $tempRoot $archiveName
            $ChecksumPath = Join-Path $tempRoot $checksumFileName
            Save-ReleaseFile -Url "$downloadBase/$archiveName" -OutFile $ArchivePath
            Save-ReleaseFile -Url "$downloadBase/$checksumFileName" -OutFile $ChecksumPath
        }
        else {
            $ArchivePath = Get-FullPath -Path $ArchivePath
            if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
                throw "Archive not found: $ArchivePath"
            }
            if ([string]::IsNullOrWhiteSpace($ChecksumPath)) {
                $ChecksumPath = Join-Path (Split-Path -Parent $ArchivePath) $checksumFileName
            }
            $ChecksumPath = Get-FullPath -Path $ChecksumPath
            if (-not (Test-Path -LiteralPath $ChecksumPath -PathType Leaf)) {
                throw "Checksum file not found: $ChecksumPath. Download $checksumFileName from the same release, or pass -ChecksumPath."
            }
            $archiveName = Split-Path -Leaf $ArchivePath
        }

        $expectedHash = Get-ExpectedChecksum -Path $ChecksumPath -FileName $archiveName
        $actualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "Checksum mismatch for $archiveName. Expected $expectedHash but the file hashes to $actualHash. Nothing was installed. Download the release again; if it keeps failing, report it at https://github.com/$repository/issues."
        }
        Write-InstallStep "Checksum OK: $archiveName"

        $extractRoot = Join-Path $tempRoot 'extract'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $extractRoot)
        $contentRoot = Get-ArchiveContentRoot -ExtractRoot $extractRoot
        $newVersion = Get-ToolVersionFromFolder -Folder $contentRoot
        if ([string]::IsNullOrWhiteSpace($newVersion)) {
            throw "Could not read `$ToolVersion from the extracted $entrypointName."
        }
        if (-not [string]::IsNullOrWhiteSpace($requestedVersion) -and $newVersion -ne $requestedVersion) {
            throw "The archive for v$requestedVersion contains tool version $newVersion. Nothing was installed."
        }

        $previousVersion = ''
        if (Test-Path -LiteralPath $Destination) {
            if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
                throw "Destination $Destination is a file. Pass a folder with -Destination."
            }
            $previousVersion = Get-ToolVersionFromFolder -Folder $Destination
            $existingEntries = @([System.IO.Directory]::GetFileSystemEntries($Destination))
            if ($existingEntries.Count -gt 0 -and [string]::IsNullOrWhiteSpace($previousVersion)) {
                throw "Destination $Destination is not empty and does not contain $entrypointName. Pick an empty folder or an existing BraveDebloater folder with -Destination."
            }
        }
        else {
            [void][System.IO.Directory]::CreateDirectory($Destination)
        }

        # Replace only the entries the release ships. backups/ and any files you added stay in place.
        foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($contentRoot)) {
            $target = Join-Path $Destination ([System.IO.Path]::GetFileName($entry))
            if ([System.IO.Directory]::Exists($target)) {
                [System.IO.Directory]::Delete($target, $true)
            }
            elseif ([System.IO.File]::Exists($target)) {
                [System.IO.File]::Delete($target)
            }
            if ([System.IO.Directory]::Exists($entry)) {
                Copy-DirectoryTree -Source $entry -Target $target
            }
            else {
                [System.IO.File]::Copy($entry, $target, $true)
            }
        }

        if ($isWindowsHost) {
            Get-ChildItem -LiteralPath $Destination -Filter '*.ps1' -Recurse -File | Unblock-File
        }

        if ([string]::IsNullOrWhiteSpace($previousVersion)) {
            Write-InstallStep "Installed BraveDebloater $newVersion to $Destination"
        }
        elseif ($previousVersion -eq $newVersion) {
            Write-InstallStep "Reinstalled BraveDebloater $newVersion in $Destination. Existing backups were kept."
        }
        else {
            Write-InstallStep "Updated BraveDebloater $previousVersion -> $newVersion in $Destination. Existing backups were kept."
        }

        $runCommand = if ($isWindowsHost) { ".\$entrypointName" } else { "./$entrypointName" }
        Write-InstallStep ''
        Write-InstallStep 'Next: preview what would change. Nothing is written until you add -Apply.'
        Write-InstallStep "  Set-Location '$Destination'"
        Write-InstallStep "  $runCommand"
        if ($isWindowsHost -and @('Restricted', 'AllSigned') -contains [string](Get-ExecutionPolicy)) {
            Write-InstallStep ''
            Write-InstallStep "PowerShell's execution policy is $(Get-ExecutionPolicy), which blocks local scripts. Allow them for your user first:"
            Write-InstallStep '  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$installParameters = @{}
foreach ($parameterName in @('Version', 'Destination', 'ArchivePath', 'ChecksumPath')) {
    if ($PSBoundParameters.ContainsKey($parameterName)) {
        $installParameters[$parameterName] = $PSBoundParameters[$parameterName]
    }
}
Install-BraveDebloater @installParameters
