#requires -Version 5.1

function Assert-BackupRegistryPath {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [string]$AllowedPolicyPath,
        [string]$AllowedUserPolicyPath,
        [switch]$DoApply
    )

    $allowedPaths = @(
        'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave',
        'Registry::HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave',
        '/etc/brave/policies/managed/BraveDebloater.json',
        '/Library/Managed Preferences/com.brave.Browser.plist',
        'com.brave.Browser'
    )

    $isTargetUserPolicyPath = $false
    $targetUserSid = ''
    if ($RegistryPath -like 'Registry::HKEY_USERS\*') {
        $targetUserPathMatch = [regex]::Match($RegistryPath, '^Registry::HKEY_USERS\\(S-[^\\]+)\\Software\\Policies\\BraveSoftware\\Brave$', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if (-not $targetUserPathMatch.Success) {
            throw "Backup contains untrusted registry path '$RegistryPath'. Restore stopped before writing anything."
        }
        $targetUserSid = $targetUserPathMatch.Groups[1].Value
        Assert-UserSid -UserSid $targetUserSid
        $isTargetUserPolicyPath = $true
        if ($RegistryPath -ne $AllowedUserPolicyPath) {
            throw "Backup contains untrusted registry path '$RegistryPath'. Restore stopped before writing anything."
        }
    }

    if (-not $isTargetUserPolicyPath -and $allowedPaths -notcontains $RegistryPath -and -not (Test-AllowedPolicyPathMatches -RegistryPath $RegistryPath -AllowedPolicyPath $AllowedPolicyPath)) {
        throw "Backup contains untrusted registry path '$RegistryPath'. Restore stopped before writing anything."
    }

    if ($DoApply -and $RegistryPath -ieq 'Registry::HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave' -and -not (Test-IsAdministrator)) {
        throw 'Restoring a LocalMachine backup needs an elevated PowerShell session. Reopen PowerShell as administrator/root, then rerun the restore command.'
    }

    if ($DoApply -and $RegistryPath -eq '/etc/brave/policies/managed/BraveDebloater.json' -and -not (Test-IsAdministrator)) {
        throw "Restoring the Linux managed policy file '$RegistryPath' needs root. Rerun the restore command with sudo."
    }

    if ($DoApply -and $isTargetUserPolicyPath) {
        if (-not (Test-IsAdministrator)) {
            throw 'Restoring a target-user backup needs an elevated PowerShell session. Reopen PowerShell as administrator, then rerun the restore command.'
        }
        if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$targetUserSid")) {
            throw "The registry hive for user SID '$targetUserSid' is not loaded. Sign in that user, then rerun the elevated restore command."
        }
    }

    if ($DoApply -and $RegistryPath -eq '/Library/Managed Preferences/com.brave.Browser.plist' -and -not (Test-IsAdministrator)) {
        throw "Restoring a macOS managed-preferences backup writes to '$RegistryPath' and needs root. Rerun the restore command with sudo."
    }
}

function Test-AllowedPolicyPathMatches {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [string]$AllowedPolicyPath
    )

    if ([string]::IsNullOrWhiteSpace($AllowedPolicyPath)) {
        return $false
    }
    if ($RegistryPath -eq $AllowedPolicyPath) {
        return $true
    }

    # Older backups may record the -PolicyPath exactly as typed (for example a relative path).
    # Compare the resolved filesystem paths too, but never for registry keys or defaults domains.
    if (-not (Test-ManagedPolicyPath -Path $RegistryPath) -or -not (Test-ManagedPolicyPath -Path $AllowedPolicyPath)) {
        return $false
    }

    try {
        return ((Get-FullFileSystemPath -Path $RegistryPath) -eq (Get-FullFileSystemPath -Path $AllowedPolicyPath))
    }
    catch {
        return $false
    }
}

function Assert-BackupPolicyKind {
    param(
        [Parameter(Mandatory = $true)]$Backup,
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [string]$AllowedPolicyPath
    )

    $kind = 'Registry'
    if ($null -ne $Backup.PSObject.Properties['policyKind']) {
        $kind = [string]$Backup.policyKind
    }

    # The kind decides which writer runs, so it must agree with the recorded path. Otherwise a
    # tampered backup could turn a registry key name into a file written under the working directory,
    # or write JSON into the macOS managed plist. File kinds only accept their own platform's default
    # path or the -PolicyPath the user passed for this restore.
    $overrideMatches = Test-AllowedPolicyPathMatches -RegistryPath $RegistryPath -AllowedPolicyPath $AllowedPolicyPath
    $consistent = switch ($kind) {
        'Registry' { $RegistryPath -like 'Registry::HKEY_*' }
        'JsonFile' { (Test-ManagedPolicyPath -Path $RegistryPath) -and ($RegistryPath -eq '/etc/brave/policies/managed/BraveDebloater.json' -or $overrideMatches) }
        'MacOSPlist' { (Test-ManagedPolicyPath -Path $RegistryPath) -and ($RegistryPath -eq '/Library/Managed Preferences/com.brave.Browser.plist' -or $overrideMatches) }
        'MacOSDefaults' { $RegistryPath -eq 'com.brave.Browser' }
        default { throw "Backup has unsupported policy kind '$kind'. Restore stopped before writing anything." }
    }

    if (-not $consistent) {
        throw "Backup policy kind '$kind' does not match its policy path '$RegistryPath'. Restore stopped before writing anything."
    }
}

function Assert-BackupPolicyList {
    param(
        [Parameter(Mandatory = $true)]$Backup,
        [Parameter(Mandatory = $true)][hashtable]$PolicyDefinitions,
        [string[]]$DeprecatedPolicyNames = @()
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
        $isDeprecated = $DeprecatedPolicyNames -contains $name
        if (-not $PolicyDefinitions.ContainsKey($name) -and -not $isDeprecated) {
            throw "Backup policy '$name' is not managed by this manifest."
        }

        if ($existed) {
            $kind = [string](Get-RequiredPropertyValue -Object $policy -Name 'kind' -Context "Backup policy '$name'")
            if (@('DWord', 'String') -notcontains $kind) {
                throw "Backup policy '$name' has unsupported registry kind '$kind'."
            }
            if (-not $isDeprecated -and $kind -ne [string]$PolicyDefinitions[$name].type) {
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
        [string]$ProfileRoot
    )

    if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
        throw 'This backup includes profile Preferences files, but no Brave profile root is known for this platform. Pass -ProfileRoot with the Brave "User Data" folder those files came from, then rerun the restore command.'
    }

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
        [string]$ProfileRoot,
        [string]$AllowedPolicyPath,
        [string]$AllowedUserPolicyPath,
        [switch]$DoApply
    )

    $schemaVersion = Get-RequiredPropertyValue -Object $Backup -Name 'schemaVersion' -Context 'Backup'
    if ($schemaVersion -ne 1) {
        throw "Unsupported backup schema version '$schemaVersion'."
    }

    $registryPath = [string](Get-RequiredPropertyValue -Object $Backup -Name 'registryPath' -Context 'Backup')
    Assert-BackupRegistryPath -RegistryPath $registryPath -AllowedPolicyPath $AllowedPolicyPath -AllowedUserPolicyPath $AllowedUserPolicyPath -DoApply:$DoApply
    Assert-BackupPolicyKind -Backup $Backup -RegistryPath $registryPath -AllowedPolicyPath $AllowedPolicyPath

    $policyDefinitions = Get-ManifestMap -Object $Manifest.policies
    Assert-BackupPolicyList -Backup $Backup -PolicyDefinitions $policyDefinitions -DeprecatedPolicyNames @(Get-DeprecatedPolicyNames -Manifest $Manifest)

    $profileFiles = @()
    if ($null -ne $Backup.PSObject.Properties['profileFiles']) {
        $profileFiles = @($Backup.profileFiles)
    }

    foreach ($profileFile in $profileFiles) {
        Assert-BackupProfileFile -ProfileFile $profileFile -BackupPath $BackupPath -ProfileRoot $ProfileRoot
        if (-not (Test-Path -LiteralPath ([string]$profileFile.backupPath) -PathType Leaf)) {
            throw "Profile backup file is missing: $($profileFile.backupPath). Restore stopped before writing anything."
        }
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

function Get-BackupFiles {
    param([string]$Directory)

    $fullDirectory = Get-FullFileSystemPath -Path $Directory
    if (-not (Test-Path -LiteralPath $fullDirectory)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $fullDirectory -Filter 'BraveDebloater-*.json' | Where-Object { -not $_.PSIsContainer } | Sort-Object LastWriteTime -Descending)
}

function Resolve-BackupPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Directory
    )

    if ($Path -ne 'Latest') {
        return $Path
    }

    $latest = (Get-BackupSummary -Directory $Directory).Latest
    if ([string]::IsNullOrWhiteSpace($latest)) {
        throw "No backups found in $(Get-FullFileSystemPath -Path $Directory). Pass a backup file to -UndoFromBackup, or point -BackupDirectory at the folder that holds your backups."
    }
    Write-Step "Latest backup: $latest"
    return $latest
}

function Get-UndoArgumentText {
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)]$Target,
        [string]$UserSid,
        [switch]$PolicyPathUsed,
        [string]$ProfileRoot,
        [string]$Channel = 'Stable'
    )

    # Double quotes keep the arguments usable from PowerShell, cmd.exe (BraveDebloat.exe), and POSIX shells.
    $arguments = New-Object System.Collections.Generic.List[string]
    [void]$arguments.Add("-UndoFromBackup `"$BackupPath`"")
    if (-not [string]::IsNullOrWhiteSpace($UserSid)) {
        [void]$arguments.Add("-UserSid $UserSid")
    }
    if ($PolicyPathUsed -and $Target.Kind -in @('JsonFile', 'MacOSPlist')) {
        [void]$arguments.Add("-PolicyPath `"$($Target.Path)`"")
    }
    if (-not [string]::IsNullOrWhiteSpace($ProfileRoot)) {
        [void]$arguments.Add("-ProfileRoot `"$(Get-FullFileSystemPath -Path $ProfileRoot)`"")
    }
    elseif ($Channel -ne 'Stable') {
        [void]$arguments.Add("-Channel $Channel")
    }
    [void]$arguments.Add('-Apply')
    return ($arguments.ToArray() -join ' ')
}

function Get-BackupDescription {
    param([Parameter(Mandatory = $true)][string]$BackupPath)

    try {
        $backup = Get-JsonFileContent -Path $BackupPath
    }
    catch {
        return 'unreadable'
    }
    if ($backup -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $backup.PSObject.Properties['policies'] -or $null -eq $backup.PSObject.Properties['registryPath']) {
        return 'not a BraveDebloater backup'
    }

    $profileFileCount = 0
    if ($null -ne $backup.PSObject.Properties['profileFiles']) {
        $profileFileCount = @($backup.profileFiles).Count
    }
    $target = ([string]$backup.registryPath) -replace '^Registry::', ''
    return ('{0} policy value(s), {1} profile file(s), target {2}' -f @($backup.policies).Count, $profileFileCount, $target)
}

function Invoke-BackupRetention {
    param(
        [string]$Directory,
        [int]$OlderThanDays = -1,
        [int]$KeepLatest = -1,
        [switch]$DoApply
    )

    $files = @(Get-BackupFiles -Directory $Directory)
    Write-Step "Backups: $($files.Count) found in $(Get-FullFileSystemPath -Path $Directory)"
    foreach ($file in $files) {
        Write-Step ("Backup: {0} ({1:yyyy-MM-dd HH:mm:ss}) - {2}" -f $file.Name, $file.LastWriteTime, (Get-BackupDescription -BackupPath $file.FullName))
    }

    $pruneRequested = $OlderThanDays -ge 0 -or $KeepLatest -ge 0
    $remove = @()
    if ($OlderThanDays -ge 0) {
        $cutoff = (Get-Date).AddDays(-$OlderThanDays)
        $remove += @($files | Where-Object { $_.LastWriteTime -lt $cutoff })
    }
    if ($KeepLatest -ge 0 -and $files.Count -gt $KeepLatest) {
        $remove += @($files | Select-Object -Skip $KeepLatest)
    }
    $remove = @($remove | Sort-Object FullName -Unique)

    if ($remove.Count -eq 0) {
        if ($pruneRequested) {
            Write-Step 'Backup cleanup: nothing to remove.'
        }
        return
    }

    $profileBackupDirectory = Join-Path (Get-FullFileSystemPath -Path $Directory) 'profile-files'
    foreach ($file in $remove) {
        $profileBackupFiles = @(Get-BackupProfileFilePaths -BackupPath $file.FullName -ProfileBackupDirectory (Get-ProfileBackupDirectory -BackupPath $file.FullName))
        if ($DoApply) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                Write-Step "Removed backup $($file.Name)."
            }
            catch {
                Write-Warning ("Failed to remove backup {0}: {1}" -f $file.Name, $_.Exception.Message)
                continue
            }

            foreach ($profileBackupFile in $profileBackupFiles) {
                try {
                    Remove-Item -LiteralPath $profileBackupFile -Force -ErrorAction Stop
                    Write-Step "Removed profile backup $(Split-Path -Leaf $profileBackupFile)."
                }
                catch {
                    Write-Warning ("Failed to remove profile backup {0}: {1}" -f $profileBackupFile, $_.Exception.Message)
                }
            }
            if ($profileBackupFiles.Count -gt 0) {
                Remove-EmptyProfileBackupDirectory -Path (Split-Path -Parent $profileBackupFiles[0]) -ProfileBackupDirectory $profileBackupDirectory
            }
        }
        else {
            Write-DryRun "Would remove backup $($file.Name). Add -Apply to delete it."
            foreach ($profileBackupFile in $profileBackupFiles) {
                Write-DryRun "Would remove profile backup $(Split-Path -Leaf $profileBackupFile) that belongs to it."
            }
        }
    }
}

function Get-BackupProfileFilePaths {
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$ProfileBackupDirectory
    )

    # Only files inside this backup's own profile-files/<backup-name>/ folder are ever removed with
    # it. Copies referenced from anywhere else (another backup's folder, or the shared root used by
    # backups from before 0.4.0) may still belong to a retained backup and are left alone.
    $paths = New-Object System.Collections.Generic.List[string]
    try {
        $backup = Get-JsonFileContent -Path $BackupPath
    }
    catch {
        return $paths.ToArray()
    }

    if ($null -eq $backup -or $null -eq $backup.PSObject.Properties['profileFiles']) {
        return $paths.ToArray()
    }

    foreach ($profileFile in @($backup.profileFiles)) {
        if ($null -eq $profileFile -or $null -eq $profileFile.PSObject.Properties['backupPath']) {
            continue
        }
        $candidate = [string]$profileFile.backupPath
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if ((Test-PathIsUnderDirectory -Path $candidate -Directory $ProfileBackupDirectory) -and (Test-Path -LiteralPath $candidate)) {
            Add-StringIfMissing -List $paths -Value (Get-FullFileSystemPath -Path $candidate)
        }
    }

    return $paths.ToArray()
}

function Remove-EmptyProfileBackupDirectory {
    param(
        [string]$Path,
        [Parameter(Mandatory = $true)][string]$ProfileBackupDirectory
    )

    # Per-backup folders under profile-files/ are removed once empty; profile-files/ itself stays.
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-PathIsUnderDirectory -Path $Path -Directory $ProfileBackupDirectory)) {
        return
    }
    if ((Test-Path -LiteralPath $Path) -and @(Get-ChildItem -LiteralPath $Path -Force).Count -eq 0) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
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
    New-DirectoryLiteral -Path $Directory

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

    if (-not $BackupPath -or -not (Test-Path -LiteralPath $BackupPath)) {
        throw 'The profile backup record is missing. Profile preferences were not changed. Rerun with backups enabled.'
    }

    $backup = Get-JsonFileContent -Path $BackupPath
    $backup.profileFiles = @($ProfileFiles)
    Set-JsonFileContent -Path $BackupPath -Object $backup -Depth 20
}

function Restore-RegistryBackup {
    param(
        [string]$BackupPath,
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$ProfileRoot,
        [string]$AllowedPolicyPath,
        [string]$AllowedUserPolicyPath,
        [switch]$DoApply
    )

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        throw "Backup file not found: $BackupPath. Check the path, then rerun the restore command."
    }

    $backup = Get-JsonFileContent -Path $BackupPath
    Assert-BackupObject -Backup $backup -Manifest $Manifest -BackupPath $BackupPath -ProfileRoot $ProfileRoot -AllowedPolicyPath $AllowedPolicyPath -AllowedUserPolicyPath $AllowedUserPolicyPath -DoApply:$DoApply
    $policyTarget = [pscustomobject]@{
        Platform = if ($backup.PSObject.Properties['platform']) { [string]$backup.platform } else { 'Windows' }
        Kind = if ($backup.PSObject.Properties['policyKind']) { [string]$backup.policyKind } else { 'Registry' }
        Path = [string]$backup.registryPath
    }

    $profileFiles = @()
    if ($null -ne $backup.PSObject.Properties['profileFiles']) {
        $profileFiles = @($backup.profileFiles)
    }

    if ($DoApply) {
        $currentPlatform = Resolve-PlatformName -Name 'Auto'
        if ($policyTarget.Kind -eq 'Registry' -and $currentPlatform -ne 'Windows') {
            throw "This backup restores Windows registry policies and cannot be applied on $currentPlatform. Run the restore on the Windows machine it was created on."
        }
        if ($policyTarget.Kind -in @('MacOSDefaults', 'MacOSPlist') -and $currentPlatform -ne 'macOS') {
            throw "This backup restores macOS policies and cannot be applied on $currentPlatform. Run the restore on the Mac it was created on."
        }

        # Brave rewrites Preferences on exit, so restoring profile files while it runs would be lost
        # or could corrupt the profile. Stop before touching anything so the restore is all-or-nothing.
        if ($profileFiles.Count -gt 0 -and (Test-BraveRunning)) {
            throw 'Brave is running, so this backup was not restored. It includes profile Preferences files. Close Brave, then rerun the restore command.'
        }
    }

    foreach ($policy in @($backup.policies)) {
        $name = [string]$policy.name
        $existed = [bool]$policy.existed
        $readError = if ($policy.PSObject.Properties['readError']) { [bool]$policy.readError } else { $false }
        if ($readError) {
            Write-Warning "Skipping '$name' because its original value could not be read when the backup was created; leaving the current value untouched."
            continue
        }
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
            $definition = [pscustomobject]@{ type = $kind; value = $value; preserveValueType = $true }
            Set-PolicyValue -Target $policyTarget -Name $name -Definition $definition
            Write-Step "Restored $name."
        }
        else {
            Remove-PolicyValue -Target $policyTarget -Name $name
            Write-Step "Removed $name."
        }
    }

    foreach ($profileFile in $profileFiles) {
        $source = [string]$profileFile.backupPath
        $target = [string]$profileFile.originalPath

        if (-not $DoApply) {
            Write-DryRun "Would restore profile file $target."
            continue
        }

        if (Test-Path -LiteralPath $source) {
            Copy-FileLiteral -SourcePath $source -DestinationPath $target
            Write-Step "Restored profile file $target."
        }
        else {
            Write-Warning "Profile backup file is missing, so this profile file was not restored: $source"
        }
    }
}
