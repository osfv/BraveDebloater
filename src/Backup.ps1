#requires -Version 5.1

function Assert-BackupRegistryPath {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [string]$AllowedPolicyPath,
        [switch]$DoApply
    )

    $allowedPaths = @(
        'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave',
        'Registry::HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave',
        '/etc/brave/policies/managed/BraveDebloater.json',
        '/Library/Managed Preferences/com.brave.Browser.plist',
        'com.brave.Browser'
    )

    if ($allowedPaths -notcontains $RegistryPath -and $RegistryPath -ne $AllowedPolicyPath) {
        throw "Backup contains untrusted registry path '$RegistryPath'. Restore stopped before writing anything."
    }

    if ($DoApply -and $RegistryPath -ieq 'Registry::HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave' -and -not (Test-IsAdministrator)) {
        throw 'Restoring a LocalMachine backup needs an elevated PowerShell session. Reopen PowerShell as administrator/root, then rerun the restore command.'
    }

    if ($DoApply -and $RegistryPath -eq '/Library/Managed Preferences/com.brave.Browser.plist' -and -not (Test-IsAdministrator)) {
        throw "Restoring a macOS managed-preferences backup writes to '$RegistryPath' and needs root. Rerun the restore command with sudo."
    }
}

function Assert-BackupPolicyList {
    param(
        [Parameter(Mandatory = $true)]$Backup,
        [Parameter(Mandatory = $true)][hashtable]$PolicyDefinitions
    )

    if ($null -eq $Backup.PSObject.Properties['policies']) {
        throw "Backup is missing required property 'policies'."
    }

    foreach ($policy in @($Backup.policies)) {
        $name = [string](Get-RequiredPropertyValue -Object $policy -Name 'name' -Context 'Backup policy')
        $existed = Get-RequiredPropertyValue -Object $policy -Name 'existed' -Context "Backup policy '$name'"

        if (-not ($existed -is [bool])) {
            throw "Backup policy '$name' has a non-boolean 'existed' value."
        }
        if (-not $PolicyDefinitions.ContainsKey($name)) {
            throw "Backup policy '$name' is not managed by this manifest."
        }

        if ($existed) {
            $kind = [string](Get-RequiredPropertyValue -Object $policy -Name 'kind' -Context "Backup policy '$name'")
            if (@('DWord', 'String') -notcontains $kind) {
                throw "Backup policy '$name' has unsupported registry kind '$kind'."
            }
            if ($kind -ne [string]$PolicyDefinitions[$name].type) {
                throw "Backup policy '$name' registry kind '$kind' does not match the manifest type '$($PolicyDefinitions[$name].type)'."
            }

            $value = Get-RequiredPropertyValue -Object $policy -Name 'value' -Context "Backup policy '$name'"
            if ($kind -eq 'DWord' -and $value -isnot [int] -and $value -isnot [long] -and $value -isnot [bool]) {
                throw "Backup policy '$name' is DWord but has non-integer value '$value'."
            }
            if ($kind -eq 'String' -and $value -isnot [string]) {
                throw "Backup policy '$name' is String but has non-string value '$value'."
            }
        }
    }
}

function Assert-BackupProfileFile {
    param(
        [Parameter(Mandatory = $true)]$ProfileFile,
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$ProfileRoot
    )

    $source = [string](Get-RequiredPropertyValue -Object $ProfileFile -Name 'backupPath' -Context 'Backup profile file')
    $target = [string](Get-RequiredPropertyValue -Object $ProfileFile -Name 'originalPath' -Context 'Backup profile file')
    $backupDirectory = Split-Path -Parent (Get-FullFileSystemPath -Path $BackupPath)
    $profileBackupDirectory = Join-Path $backupDirectory 'profile-files'

    # Profile restores should only read files created beside the selected backup.
    if (-not (Test-PathIsUnderDirectory -Path $source -Directory $profileBackupDirectory)) {
        throw "Backup profile source is outside the expected backup folder: $source"
    }

    # Profile restores should only write Brave Preferences files under the selected profile root.
    if (-not (Test-PathIsUnderDirectory -Path $target -Directory $ProfileRoot)) {
        throw "Backup profile target is outside the selected profile root: $target"
    }
    if ((Split-Path -Leaf $target) -ne 'Preferences') {
        throw "Backup profile target is not a Brave Preferences file: $target"
    }
}

function Assert-BackupObject {
    param(
        [Parameter(Mandatory = $true)]$Backup,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$ProfileRoot,
        [string]$AllowedPolicyPath,
        [switch]$DoApply
    )

    $schemaVersion = Get-RequiredPropertyValue -Object $Backup -Name 'schemaVersion' -Context 'Backup'
    if ($schemaVersion -ne 1) {
        throw "Unsupported backup schema version '$schemaVersion'."
    }

    $registryPath = [string](Get-RequiredPropertyValue -Object $Backup -Name 'registryPath' -Context 'Backup')
    Assert-BackupRegistryPath -RegistryPath $registryPath -AllowedPolicyPath $AllowedPolicyPath -DoApply:$DoApply

    $policyDefinitions = Get-ManifestMap -Object $Manifest.policies
    Assert-BackupPolicyList -Backup $Backup -PolicyDefinitions $policyDefinitions

    $profileFiles = @()
    if ($null -ne $Backup.PSObject.Properties['profileFiles']) {
        $profileFiles = @($Backup.profileFiles)
    }

    foreach ($profileFile in $profileFiles) {
        Assert-BackupProfileFile -ProfileFile $profileFile -BackupPath $BackupPath -ProfileRoot $ProfileRoot
    }
}

function Get-BackupSummary {
    param([string]$Directory)

    $fullDirectory = Get-FullFileSystemPath -Path $Directory
    $files = @()
    if (Test-Path -LiteralPath $fullDirectory) {
        $files = @(Get-ChildItem -LiteralPath $fullDirectory -Filter 'BraveDebloater-*.json' | Where-Object { -not $_.PSIsContainer } | Sort-Object LastWriteTime -Descending)
    }

    $latest = ''
    if ($files.Count -gt 0) {
        $latest = $files[0].FullName
    }

    return [pscustomobject]@{
        Directory = $fullDirectory
        Count = $files.Count
        Latest = $latest
    }
}

function New-BackupPath {
    param([string]$Directory)

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $path = Join-Path $Directory "BraveDebloater-$timestamp.json"
    if (-not (Test-Path -LiteralPath $path)) {
        return $path
    }

    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return (Join-Path $Directory "BraveDebloater-$timestamp-$suffix.json")
}

function New-Backup {
    param(
        [string]$Directory,
        [string]$ScopeName,
        [Parameter(Mandatory = $true)]$Target,
        [string[]]$PolicyNames,
        [string]$ProfileRoot,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $Directory = Get-FullFileSystemPath -Path $Directory
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    $path = New-BackupPath -Directory $Directory
    $backup = [ordered]@{
        schemaVersion = 1
        createdAt = (Get-Date).ToString('o')
        manifestSchemaVersion = $Manifest.schemaVersion
        policyTemplateVersion = $Manifest.policyTemplateVersion
        scope = $ScopeName
        platform = $Target.Platform
        policyKind = $Target.Kind
        registryPath = $Target.Path
        profileRoot = $ProfileRoot
        policies = @(Get-PolicySnapshot -Target $Target -PolicyNames $PolicyNames)
        profileFiles = @()
    }

    Set-JsonFileContent -Path $path -Object $backup -Depth 20
    return $path
}

function Update-BackupProfileFiles {
    param(
        [string]$BackupPath,
        [object[]]$ProfileFiles
    )

    if (-not $BackupPath) {
        return
    }
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        Write-Warning "Backup file not found when updating profile metadata: $BackupPath"
        return
    }

    $backup = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
    $backup.profileFiles = @($ProfileFiles)
    Set-JsonFileContent -Path $BackupPath -Object $backup -Depth 20
}

function Restore-RegistryBackup {
    param(
        [string]$BackupPath,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ProfileRoot,
        [string]$AllowedPolicyPath,
        [switch]$DoApply
    )

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        throw "Backup file not found: $BackupPath. Check the path, then rerun the restore command."
    }

    $backup = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
    Assert-BackupObject -Backup $backup -Manifest $Manifest -BackupPath $BackupPath -ProfileRoot $ProfileRoot -AllowedPolicyPath $AllowedPolicyPath -DoApply:$DoApply
    $policyTarget = [pscustomobject]@{
        Platform = if ($backup.PSObject.Properties['platform']) { [string]$backup.platform } else { 'Windows' }
        Kind = if ($backup.PSObject.Properties['policyKind']) { [string]$backup.policyKind } else { 'Registry' }
        Path = [string]$backup.registryPath
    }

    foreach ($policy in @($backup.policies)) {
        $name = [string]$policy.name
        $existed = [bool]$policy.existed
        if (-not $DoApply) {
            if ($existed) {
                Write-DryRun "Would restore $name to '$($policy.value)' ($($policy.kind))."
            }
            else {
                Write-DryRun "Would remove $name because it did not exist before."
            }
            continue
        }

        if ($existed) {
            $kind = [string]$policy.kind
            $value = $policy.value
            $definition = [pscustomobject]@{ type = $kind; value = $value }
            Set-PolicyValue -Target $policyTarget -Name $name -Definition $definition
            Write-Step "Restored $name."
        }
        else {
            Remove-PolicyValue -Target $policyTarget -Name $name
            Write-Step "Removed $name."
        }
    }

    foreach ($profileFile in @($backup.profileFiles)) {
        $source = [string]$profileFile.backupPath
        $target = [string]$profileFile.originalPath

        if (-not $DoApply) {
            Write-DryRun "Would restore profile file $target."
            continue
        }

        if (Test-Path -LiteralPath $source) {
            $targetDirectory = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $targetDirectory)) {
                New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
            }
            Copy-Item -LiteralPath $source -Destination $target -Force
            Write-Step "Restored profile file $target."
        }
        else {
            Write-Warning "Profile backup file is missing, so this profile file was not restored: $source"
        }
    }
}
