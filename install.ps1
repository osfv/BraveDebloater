#requires -Version 5.1
<#
.SYNOPSIS
Downloads the latest BraveDebloater release, verifies its SHA256 checksum, and extracts it to a folder you control.

.DESCRIPTION
One-line install (Windows PowerShell 5.1 or PowerShell 7 on any platform):

    irm https://raw.githubusercontent.com/osfv/BraveDebloater/main/install.ps1 | iex

Pass options by turning the download into a script block:

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/osfv/BraveDebloater/main/install.ps1))) -Version 0.5.0 -Destination C:\Tools\BraveDebloater

Nothing about Brave is changed by this script. It only places the tool on disk and prints the preview command to run next.
Re-running it upgrades an existing install in place and keeps the backups/ folder.

.PARAMETER Version
Release to install, for example 0.5.0 or v0.5.0. Default: the latest GitHub release.

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
            throw "Could not read the latest release tag from GitHub (got '$tag'). Pass -Version, for example -Version 0.5.0."
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

    function Move-FileSystemEntry {
        param([string]$Source, [string]$Target)
        if ([System.IO.Directory]::Exists($Source)) {
            [System.IO.Directory]::Move($Source, $Target)
        }
        else {
            [System.IO.File]::Move($Source, $Target)
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
            throw "-Version must look like 0.5.0 or v0.5.0, got '$Version'."
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

        # Only the entries the release ships are replaced; backups/ and any files you added stay in place.
        # The new tree is copied completely into a staging folder inside the destination first (the step
        # that can run out of disk or hit a locked file), then swapped in with same-volume renames. A
        # failure during the swap moves the previous files back, so the install never ends up half done.
        $stageId = [guid]::NewGuid().ToString('N')
        $newStage = Join-Path $Destination ".install-new-$stageId"
        $oldStage = Join-Path $Destination ".install-old-$stageId"
        try {
            Copy-DirectoryTree -Source $contentRoot -Target $newStage
        }
        catch {
            if ([System.IO.Directory]::Exists($newStage)) {
                [System.IO.Directory]::Delete($newStage, $true)
            }
            throw "Copying the release into $Destination failed ($($_.Exception.Message)). The existing files were not touched."
        }

        $entryNames = @([System.IO.Directory]::GetFileSystemEntries($newStage) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
        $movedOut = New-Object System.Collections.Generic.List[string]
        $movedIn = New-Object System.Collections.Generic.List[string]
        try {
            [void][System.IO.Directory]::CreateDirectory($oldStage)
            foreach ($entryName in $entryNames) {
                $target = Join-Path $Destination $entryName
                if ([System.IO.Directory]::Exists($target) -or [System.IO.File]::Exists($target)) {
                    Move-FileSystemEntry -Source $target -Target (Join-Path $oldStage $entryName)
                    [void]$movedOut.Add($entryName)
                }
                Move-FileSystemEntry -Source (Join-Path $newStage $entryName) -Target $target
                [void]$movedIn.Add($entryName)
            }
        }
        catch {
            $swapError = $_.Exception.Message
            try {
                foreach ($entryName in $movedIn) {
                    Move-FileSystemEntry -Source (Join-Path $Destination $entryName) -Target (Join-Path $newStage $entryName)
                }
                foreach ($entryName in $movedOut) {
                    Move-FileSystemEntry -Source (Join-Path $oldStage $entryName) -Target (Join-Path $Destination $entryName)
                }
            }
            catch {
                throw "Replacing files in $Destination failed ($swapError) and restoring the previous files also failed ($($_.Exception.Message)). The previous files are in $oldStage; move them back by hand, then delete $newStage."
            }
            # The previous files are back in place; the staged copy of the new release is ours to discard.
            [System.IO.Directory]::Delete($newStage, $true)
            [System.IO.Directory]::Delete($oldStage, $true)
            throw "Replacing files in $Destination failed ($swapError). The previous files were restored and nothing changed. Close programs that use that folder, then run the installer again."
        }
        # Success: the new staging folder is empty and the old one holds only replaced files.
        [System.IO.Directory]::Delete($newStage, $true)
        [System.IO.Directory]::Delete($oldStage, $true)

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
