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

function Get-Utf8FileContent {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Windows PowerShell 5.1 reads files as ANSI by default, which mangles the UTF-8 that Brave
    # and this tool write. Always read policy, backup, and Preferences JSON as UTF-8.
    return [System.IO.File]::ReadAllText((Get-FullFileSystemPath -Path $Path), [System.Text.Encoding]::UTF8)
}

function Get-JsonFileContent {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = Get-Utf8FileContent -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "The file is empty: $Path"
    }

    return ($raw | ConvertFrom-Json)
}

function Set-TextFileContent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content,
        [System.Text.Encoding]$Encoding = $null
    )

    # Brave and most policy readers expect UTF-8 without a byte order mark. Windows PowerShell 5.1
    # `Set-Content -Encoding UTF8` writes a BOM, so write the bytes directly instead.
    if ($null -eq $Encoding) {
        $Encoding = New-Object System.Text.UTF8Encoding($false)
    }

    $fullPath = Get-FullFileSystemPath -Path $Path
    $directory = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tempDirectory = if ([string]::IsNullOrWhiteSpace($directory)) { '.' } else { $directory }
    $tempPath = Join-Path $tempDirectory ('.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, $Encoding)
        Move-Item -LiteralPath $tempPath -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Set-JsonFileContent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object,
        [int]$Depth = 20
    )

    $json = $Object | ConvertTo-Json -Depth $Depth
    Set-TextFileContent -Path $Path -Content ($json + [Environment]::NewLine)
}

function Get-BraveProcess {
    # Windows and Linux run Brave as `brave`; macOS runs it as `Brave Browser`, `Brave Browser Beta`,
    # or `Brave Browser Nightly`. Check every name so profile writes are never attempted while Brave is open.
    return @(Get-Process -Name 'brave', 'Brave Browser*' -ErrorAction SilentlyContinue)
}

function Test-BraveRunning {
    return (@(Get-BraveProcess).Count -gt 0)
}
