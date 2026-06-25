#requires -Version 5.1

function Write-Step {
    param([string]$Message)
    Write-Host "[BraveDebloater] $Message"
}

function Write-DryRun {
    param([string]$Message)
    Write-Host "[dry-run] $Message"
}

function Get-ManifestMap {
    param([Parameter(Mandatory = $true)]$Object)

    $map = @{}
    foreach ($property in $Object.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }
    return $map
}

function Add-StringIfMissing {
    param(
        [Parameter(Mandatory = $true)]$List,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if (-not $List.Contains($Value)) {
        [void]$List.Add($Value)
    }
}

function Remove-StringFromList {
    param(
        [Parameter(Mandatory = $true)]$List,
        [Parameter(Mandatory = $true)][string]$Value
    )

    while ($List.Remove($Value)) {
    }
}

function Get-FullFileSystemPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Expected a non-empty filesystem path.'
    }

    try {
        return [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    }
    catch {
        Write-Verbose "PSPath resolution failed for '$Path', falling back to direct resolution: $($_.Exception.Message)"
        return [System.IO.Path]::GetFullPath($Path)
    }
}

function Test-PathIsUnderDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $fullPath = Get-FullFileSystemPath -Path $Path
    $fullDirectory = Get-FullFileSystemPath -Path $Directory
    $separator = [System.IO.Path]::DirectorySeparatorChar

    if (-not $fullDirectory.EndsWith([string]$separator, [StringComparison]::OrdinalIgnoreCase)) {
        $fullDirectory = "$fullDirectory$separator"
    }

    return $fullPath.StartsWith($fullDirectory, [StringComparison]::OrdinalIgnoreCase)
}

function Get-RequiredPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Context is missing required property '$Name'."
    }

    return $property.Value
}

function Set-JsonFileContent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object,
        [int]$Depth = 20
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tempDirectory = if ([string]::IsNullOrWhiteSpace($directory)) { '.' } else { $directory }
    $tempPath = Join-Path $tempDirectory ('.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        $Object | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $tempPath -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Set-TextFileContent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tempDirectory = if ([string]::IsNullOrWhiteSpace($directory)) { '.' } else { $directory }
    $tempPath = Join-Path $tempDirectory ('.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath $tempPath -Value $Content -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}
