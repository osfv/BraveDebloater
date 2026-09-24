#requires -Version 5.1

function Assert-CommandModes {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Parameters)

    $modes = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('Version', 'Doctor', 'List', 'ListFeatures', 'UndoFromBackup', 'ExportPolicyPath')) {
        if ($Parameters.Keys -contains $name -and $Parameters[$name]) {
            [void]$modes.Add("-$name")
        }
    }
    $backupMode = $Parameters.Keys -contains 'ListBackups' -and $Parameters['ListBackups']
    foreach ($name in @('PruneBackupsOlderThanDays', 'KeepLatestBackups')) {
        if ($Parameters.Keys -contains $name -and $Parameters[$name] -ge 0) {
            $backupMode = $true
        }
    }
    if ($backupMode) {
        [void]$modes.Add('backup listing/retention')
    }
    if ($modes.Count -gt 1) {
        throw "Conflicting command modes: $($modes -join ', '). Run one mode at a time. No changes were made."
    }
}

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

function Get-ProfileBackupDirectory {
    param([Parameter(Mandatory = $true)][string]$BackupPath)

    # Profile Preferences copies live in a folder named after their backup JSON so runs never share files.
    $backupDirectory = Split-Path -Parent (Get-FullFileSystemPath -Path $BackupPath)
    $backupName = [System.IO.Path]::GetFileNameWithoutExtension($BackupPath)
    return (Join-Path (Join-Path $backupDirectory 'profile-files') $backupName)
}

function Test-JsonDateKindSupported {
    return (Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')
}

function Test-JsonDatesMayChange {
    return (-not (Test-JsonDateKindSupported) -and $PSVersionTable.PSVersion.Major -ge 6)
}

function ConvertFrom-JsonText {
    param([Parameter(Mandatory = $true)][string]$Json)

    # PowerShell 7 parses ISO 8601 strings into DateTime values, and ConvertTo-Json then writes them
    # back in local time, so a rewrite would change unrelated values. -DateKind String (PowerShell 7.5+)
    # keeps them as the original text. Windows PowerShell 5.1 never converts them.
    $options = @{}
    if (Test-JsonDateKindSupported) {
        $options['DateKind'] = 'String'
    }
    return ($Json | ConvertFrom-Json @options)
}

function Test-JsonValueContainsDate {
    param($Value)

    $pending = New-Object System.Collections.Generic.Stack[object]
    $pending.Push($Value)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        if ($current -is [datetime] -or $current -is [datetimeoffset]) {
            return $true
        }
        if ($current -is [System.Management.Automation.PSCustomObject]) {
            foreach ($property in $current.PSObject.Properties) {
                $pending.Push($property.Value)
            }
        }
        elseif ($current -is [System.Collections.IList]) {
            foreach ($item in $current) {
                $pending.Push($item)
            }
        }
    }
    return $false
}

function Get-JsonFileContent {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = Get-Utf8FileContent -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "The file is empty: $Path"
    }

    return (ConvertFrom-JsonText -Json $raw)
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
    New-DirectoryLiteral -Path $directory

    $tempDirectory = if ([string]::IsNullOrWhiteSpace($directory)) { '.' } else { $directory }
    $tempPath = Join-Path $tempDirectory ('.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, $Encoding)
        Move-FileLiteral -SourcePath $tempPath -DestinationPath $fullPath
    }
    finally {
        if ([System.IO.File]::Exists($tempPath)) {
            [System.IO.File]::Delete($tempPath)
        }
    }
}

function Move-FileLiteral {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    # Move-Item/Copy-Item treat -Destination as a wildcard pattern on Windows PowerShell 5.1, so a
    # profile path containing '[' or ']' could land somewhere else. .NET file APIs are always literal.
    # File.Replace keeps the swap atomic on the same volume; fall back to an overwrite copy elsewhere.
    if ([System.IO.File]::Exists($DestinationPath)) {
        try {
            [System.IO.File]::Replace($SourcePath, $DestinationPath, [NullString]::Value)
            return
        }
        catch {
            [System.IO.File]::Copy($SourcePath, $DestinationPath, $true)
            [System.IO.File]::Delete($SourcePath)
            return
        }
    }

    [System.IO.File]::Move($SourcePath, $DestinationPath)
}

function Copy-FileLiteral {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $fullDestination = Get-FullFileSystemPath -Path $DestinationPath
    New-DirectoryLiteral -Path (Split-Path -Parent $fullDestination)
    [System.IO.File]::Copy((Get-FullFileSystemPath -Path $SourcePath), $fullDestination, $true)
}

function New-DirectoryLiteral {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $fullPath = Get-FullFileSystemPath -Path $Path
    if (-not [System.IO.Directory]::Exists($fullPath)) {
        [System.IO.Directory]::CreateDirectory($fullPath) | Out-Null
    }
}

function Assert-JsonSerializationDepth {
    param($Value, [int]$Depth)

    # ConvertTo-Json silently stringifies deeper containers on Windows PowerShell 5.1.
    # Refuse that lossy conversion before any file is opened for writing.
    $pending = New-Object System.Collections.Generic.Stack[object]
    $pending.Push(@{ Value = $Value; Level = 0 })
    while ($pending.Count -gt 0) {
        $entry = $pending.Pop()
        $current = $entry.Value
        if ($current -isnot [System.Collections.IDictionary] -and $current -isnot [System.Collections.IList] -and $current -isnot [System.Management.Automation.PSCustomObject]) {
            continue
        }
        if ($entry.Level -gt $Depth) {
            throw "JSON nesting exceeds the supported depth of $Depth. The file was not changed."
        }
        if ($current -is [System.Collections.IDictionary]) {
            foreach ($child in $current.Values) {
                $pending.Push(@{ Value = $child; Level = ($entry.Level + 1) })
            }
        }
        elseif ($current -is [System.Collections.IList]) {
            foreach ($child in $current) {
                $pending.Push(@{ Value = $child; Level = ($entry.Level + 1) })
            }
        }
        else {
            foreach ($property in $current.PSObject.Properties) {
                $pending.Push(@{ Value = $property.Value; Level = ($entry.Level + 1) })
            }
        }
    }
}

function Set-JsonFileContent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object,
        [int]$Depth = 20
    )

    Assert-JsonSerializationDepth -Value $Object -Depth $Depth
    $json = ConvertTo-Json -InputObject $Object -Depth $Depth
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
