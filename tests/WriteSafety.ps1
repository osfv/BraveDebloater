#requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$TempRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'Invoke-BraveDebloat.ps1'
foreach ($module in @('Common', 'Manifest', 'PlatformPolicy', 'Backup', 'ProfilePreferences')) {
    . (Join-Path $root "src/$module.ps1")
}

# Every export format must preserve existing files and avoid creating parent directories in WhatIf.
foreach ($case in @(@{ Platform = 'Windows'; Extension = 'reg' }, @{ Platform = 'Linux'; Extension = 'json' }, @{ Platform = 'macOS'; Extension = 'plist' }, @{ Platform = 'macOS'; Extension = 'mobileconfig' })) {
    $exportDirectory = Join-Path $TempRoot $case.Extension
    $exportPath = Join-Path $exportDirectory ("policies." + $case.Extension)
    & $scriptPath -Platform $case.Platform -OnlyFeature Rewards -ExportPolicyPath $exportPath -WhatIf *> $null
    if (Test-Path -LiteralPath $exportDirectory) { throw 'WhatIf created an export directory.' }
    New-DirectoryLiteral -Path $exportDirectory
    Set-TextFileContent -Path $exportPath -Content 'keep this file'
    & $scriptPath -Platform $case.Platform -OnlyFeature Rewards -ExportPolicyPath $exportPath -Apply -WhatIf *> $null
    if ((Get-Utf8FileContent -Path $exportPath) -cne 'keep this file') { throw 'WhatIf overwrote an export.' }
}

# An export or report is written without -Apply and without a backup, so it must be refused when it
# names the policy file of the run. Uses synthetic policy files only, never a real Brave location.
function Get-OutputGuardMessage {
    param([Parameter(Mandatory = $true)][hashtable]$Parameters)

    try { & $scriptPath @Parameters *> $null }
    catch { return $_.Exception.Message }
    return ''
}
$guardDirectory = Join-Path $TempRoot 'output-guard'
New-DirectoryLiteral -Path $guardDirectory
$guardOriginal = '{"HomepageLocation":"https://example.com"}'
foreach ($case in @(@{ Platform = 'Linux'; Scope = 'CurrentUser'; Name = 'live.json' }, @{ Platform = 'macOS'; Scope = 'LocalMachine'; Name = 'live.plist' })) {
    $livePolicy = Join-Path $guardDirectory $case.Name
    Set-TextFileContent -Path $livePolicy -Content $guardOriginal
    $base = @{ Platform = $case.Platform; Scope = $case.Scope; OnlyFeature = 'Rewards'; PolicyPath = $livePolicy }
    $respelledPolicy = Join-Path (Join-Path (Join-Path $guardDirectory 'missing') '..') $case.Name
    foreach ($extra in @(@{ ExportPolicyPath = $livePolicy }, @{ ExportPolicyPath = $respelledPolicy }, @{ ExportPolicyPath = $livePolicy; Apply = $true }, @{ ExportPolicyPath = $livePolicy; WhatIf = $true })) {
        $message = Get-OutputGuardMessage -Parameters ($base + $extra)
        if ($message -notlike "-ExportPolicyPath '*' is the Brave policy file this command targets*No changes were made.") { throw "$($case.Platform) export onto the policy file was not refused: $message" }
        if ((Get-Utf8FileContent -Path $livePolicy) -cne $guardOriginal) { throw "$($case.Platform) export overwrote the policy file." }
    }

    # A different file in the same folder still exports and leaves the policy file alone.
    $separateExport = Join-Path $guardDirectory ('export-' + $case.Name)
    $message = Get-OutputGuardMessage -Parameters ($base + @{ ExportPolicyPath = $separateExport })
    if ($message -ne '' -or -not (Test-Path -LiteralPath $separateExport)) { throw "$($case.Platform) export next to the policy file failed: $message" }
    if ((Get-Utf8FileContent -Path $livePolicy) -cne $guardOriginal) { throw "$($case.Platform) export next to the policy file changed it." }
}

# The same file reached through a symlinked folder is refused too, and so is a policy folder whose
# entries are symlinks, in both directions. Skipped where symlinks need extra rights.
$livePolicy = Join-Path $guardDirectory 'live.json'
$linkedDirectory = Join-Path $TempRoot 'output-guard-link'
$policyFolder = Join-Path $TempRoot 'output-guard-policies'
$outsideFolder = Join-Path $TempRoot 'output-guard-outside'
$outsideFile = Join-Path $outsideFolder 'real.json'
foreach ($directory in @($outsideFolder, (Join-Path $outsideFolder 'managed'), (Join-Path $policyFolder 'recommended'))) { New-DirectoryLiteral -Path $directory }
Set-TextFileContent -Path $outsideFile -Content $guardOriginal
$linksCreated = $false
try {
    New-Item -ItemType SymbolicLink -Path $linkedDirectory -Target $guardDirectory -ErrorAction Stop | Out-Null
    New-Item -ItemType SymbolicLink -Path (Join-Path $policyFolder 'managed') -Target (Join-Path $outsideFolder 'managed') -ErrorAction Stop | Out-Null
    New-Item -ItemType SymbolicLink -Path (Join-Path $policyFolder 'recommended/linked.json') -Target $outsideFile -ErrorAction Stop | Out-Null
    $linksCreated = $true
}
catch { Write-Host 'Skipped the symlink export checks: this session cannot create symlinks.' }
try {
    if ($linksCreated) {
        $message = Get-OutputGuardMessage -Parameters @{ Platform = 'Linux'; OnlyFeature = 'Rewards'; PolicyPath = $livePolicy; ExportPolicyPath = (Join-Path $linkedDirectory 'live.json') }
        if ($message -notlike '*is the Brave policy file this command targets*') { throw "Export through a symlinked folder was not refused: $message" }
        if ((Get-Utf8FileContent -Path $livePolicy) -cne $guardOriginal) { throw 'Export through a symlinked folder overwrote the policy file.' }

        $unrelatedTarget = [pscustomobject]@{ Platform = 'Windows'; Kind = 'Registry'; Path = 'HKCU:\Software\Policies\BraveSoftware\Brave' }
        $locations = @(foreach ($directory in @($policyFolder, (Join-Path $policyFolder 'managed'), (Join-Path $policyFolder 'recommended'))) { @{ Directory = $directory; Leaf = '*' } })
        foreach ($refused in @((Join-Path $policyFolder 'managed/new.json'), (Join-Path $outsideFolder 'managed/new.json'), (Join-Path $policyFolder 'recommended/new.json'), (Join-Path $policyFolder 'recommended/linked.json'), $outsideFile)) {
            if ((Get-PolicyOutputPathConflict -Path $refused -Target $unrelatedTarget -PolicyLocations $locations) -eq '') { throw "An output path linked to a policy folder was allowed: $refused" }
        }
        foreach ($allowed in @((Join-Path $outsideFolder 'other.json'), (Join-Path $guardDirectory 'new.json'))) {
            $conflict = Get-PolicyOutputPathConflict -Path $allowed -Target $unrelatedTarget -PolicyLocations $locations
            if ($conflict -ne '') { throw "An output path outside the policy folder was refused: $allowed $conflict" }
        }
    }
}
finally {
    # Remove the links themselves so the temp folder cleanup never follows them.
    foreach ($link in @($linkedDirectory, (Join-Path $policyFolder 'managed'))) {
        if ([System.IO.Directory]::Exists($link)) { [System.IO.Directory]::Delete($link) }
    }
    $fileLink = Join-Path $policyFolder 'recommended/linked.json'
    if ([System.IO.File]::Exists($fileLink)) { [System.IO.File]::Delete($fileLink) }
}

# A preview report is refused the same way, before the run prints or writes anything.
$htmlPolicy = Join-Path $guardDirectory 'live.html'
Set-TextFileContent -Path $htmlPolicy -Content $guardOriginal
foreach ($extra in @(@{}, @{ Apply = $true; NoBackup = $true })) {
    $message = Get-OutputGuardMessage -Parameters (@{ Platform = 'Linux'; OnlyFeature = 'Rewards'; PolicyPath = $htmlPolicy; ReportPath = $htmlPolicy; NoOpenReport = $true } + $extra)
    if ($message -notlike "-ReportPath '*' is the Brave policy file this command targets*No changes were made.") { throw "Report onto the policy file was not refused: $message" }
    if ((Get-Utf8FileContent -Path $htmlPolicy) -cne $guardOriginal) { throw 'Report overwrote the policy file.' }
}

# Brave's own policy locations on this host are refused whatever -Platform or -PolicyPath says: the
# Linux policy folders on Linux, the plist names on macOS. Path checks only, plus -WhatIf runs that
# cannot write even if the guard regressed.
if ([System.IO.Path]::DirectorySeparatorChar -eq [char]'/') {
    $registryTarget = [pscustomobject]@{ Platform = 'Windows'; Kind = 'Registry'; Path = 'HKCU:\Software\Policies\BraveSoftware\Brave' }
    $defaultsTarget = [pscustomobject]@{ Platform = 'macOS'; Kind = 'MacOSDefaults'; Path = 'com.brave.Browser' }
    $userPlist = Join-Path $HOME 'Library/Preferences/com.brave.Browser.plist'
    $linuxPaths = @('/etc/brave/policies/managed/BraveDebloater.json', '/etc/brave/policies/managed/other.json', '/etc/brave/policies/recommended/other.json')
    $macPaths = @('/Library/Managed Preferences/com.brave.Browser.plist', '/Library/Managed Preferences/someone/com.brave.Browser.plist', $userPlist)
    $neutralPaths = @('/Library/Managed Preferences/com.example.plist', (Join-Path $HOME 'Library/Preferences/com.example.plist'), (Join-Path $guardDirectory 'com.brave.Browser.plist'), '/etc/brave/export.json')
    $onMac = [bool]((Get-Variable -Name IsMacOS -Scope Global -ErrorAction SilentlyContinue) -and $IsMacOS)
    $refusedPaths = if ($onMac) { $macPaths } else { $linuxPaths }
    $otherHostPaths = if ($onMac) { $linuxPaths } else { $macPaths }
    foreach ($refused in $refusedPaths) {
        if ((Get-PolicyOutputPathConflict -Path $refused -Target $registryTarget) -eq '') { throw "An output path in a Brave policy location was allowed: $refused" }
    }
    foreach ($allowed in @($otherHostPaths) + $neutralPaths) {
        $conflict = Get-PolicyOutputPathConflict -Path $allowed -Target $registryTarget
        if ($conflict -ne '') { throw "An output path outside this host's Brave policy locations was refused: $allowed $conflict" }
    }
    if ((Get-PolicyOutputPathConflict -Path $userPlist -Target $defaultsTarget) -notlike 'is the Brave policy file this command targets*') { throw 'The macOS user defaults file was not treated as the policy target.' }

    # The default Linux policy file is the target of a Linux run on any host; other runs are refused on Linux.
    $runs = @(@{ Platform = 'Linux' })
    if (-not $onMac) { $runs += @(@{ Platform = 'Windows' }, @{ Platform = 'Linux'; PolicyPath = $livePolicy }) }
    foreach ($parameters in $runs) {
        $message = Get-OutputGuardMessage -Parameters ($parameters + @{ OnlyFeature = 'Rewards'; ExportPolicyPath = '/etc/brave/policies/managed/BraveDebloater.json'; WhatIf = $true })
        if ($message -notlike "-ExportPolicyPath '*No changes were made.") { throw "Export into Brave's Linux policy folder was not refused: $message" }
    }
}

# Read-only modes cannot fall through to destructive retention, restore, or export operations.
$retentionDirectory = Join-Path $TempRoot 'ModeBackups'
New-DirectoryLiteral -Path $retentionDirectory
$retainedFile = Join-Path $retentionDirectory 'BraveDebloater-retain.json'
Set-TextFileContent -Path $retainedFile -Content '{}'
foreach ($parameters in @(
    @{ Doctor = $true; KeepLatestBackups = 0 },
    @{ List = $true; PruneBackupsOlderThanDays = 0 },
    @{ ListFeatures = $true; UndoFromBackup = 'missing.json' },
    @{ Doctor = $true; UndoFromBackup = 'missing.json' },
    @{ UndoFromBackup = 'missing.json'; KeepLatestBackups = 0 },
    @{ ExportPolicyPath = (Join-Path $TempRoot 'conflict.json'); KeepLatestBackups = 0 }
)) {
    $message = ''
    try { & $scriptPath @parameters -Apply -BackupDirectory $retentionDirectory *> $null }
    catch { $message = $_.Exception.Message }
    if ($message -notlike 'Conflicting command modes:*') { throw "Mode conflict was not rejected: $message" }
    if (-not (Test-Path -LiteralPath $retainedFile)) { throw 'Conflicting modes deleted a backup.' }
}
# Listing and retention intentionally remain a single compatible mode.
& $scriptPath -ListBackups -KeepLatestBackups 1 -BackupDirectory $retentionDirectory *> $null

# Use only synthetic profile files; the tests never write to an installed Brave profile.
function Test-BraveRunning { return $false }
$manifest = Get-JsonFileContent -Path (Join-Path $root 'config/policies.json')
$profileRoot = Join-Path $TempRoot 'Profiles'
$firstProfile = Join-Path $profileRoot 'Default/Preferences'
$secondProfile = Join-Path $profileRoot 'Profile 1/Preferences'
$original = '{"brave":{"rewards":{"enabled":true}}}'
Set-TextFileContent -Path $firstProfile -Content $original
Set-TextFileContent -Path $secondProfile -Content $original
$policyPath = Join-Path $TempRoot 'policies.json'
$target = [pscustomobject]@{ Platform = 'Linux'; Kind = 'JsonFile'; Path = $policyPath }
$backupPath = New-Backup -Directory (Join-Path $TempRoot 'Backups') -ScopeName CurrentUser -Target $target -PolicyNames @('BraveRewardsDisabled') -ProfileRoot $profileRoot -Manifest $manifest

# Inject a failure on the second Preferences write, after the first profile was changed.
function Invoke-InterruptedCleanup {
    $writer = (Get-Command Set-JsonFileContent).ScriptBlock
    function Set-JsonFileContent {
        param($Path, $Object, [int]$Depth = 20)
        if ($Path -eq $secondProfile) { throw 'Injected second profile write failure' }
        & $writer -Path $Path -Object $Object -Depth $Depth
    }
    Invoke-ProfilePreferenceCleanup -Root $profileRoot -Manifest $manifest -BackupPath $backupPath -SelectedFeatureIds Rewards -UseFeatureFilter -DoApply
}
$failure = ''
try { Invoke-InterruptedCleanup *> $null }
catch { $failure = $_.Exception.Message }
if ($failure -ne 'Injected second profile write failure') { throw "Unexpected profile failure: $failure" }
if ((Get-JsonFileContent -Path $firstProfile).brave.rewards.enabled -ne $false) { throw 'First profile was not changed before injected failure.' }
$backup = Get-JsonFileContent -Path $backupPath
if (@($backup.profileFiles).Count -ne 2) { throw 'Interrupted cleanup lost profile recovery records.' }
foreach ($file in $backup.profileFiles) {
    if ((Get-Utf8FileContent -Path $file.backupPath) -cne $original) { throw 'Interrupted cleanup lost the original profile content.' }
}
Restore-RegistryBackup -BackupPath $backupPath -Manifest $manifest -ProfileRoot $profileRoot -AllowedPolicyPath $policyPath -DoApply *> $null
if ((Get-Utf8FileContent -Path $firstProfile) -cne $original) { throw 'Interrupted cleanup could not be restored.' }

# Restore passes the validated absolute file path to both policy writers, but leaves defaults domains unchanged.
function Test-RestorePolicyTarget {
    param([string]$Kind, [string]$RecordedPath, [string]$AllowedPath, [string]$ExpectedPath, [switch]$SimulateManagedPlist, [switch]$ExpectRefusal)

    $resolver = (Get-Command Get-FullFileSystemPath).ScriptBlock
    function Get-FullFileSystemPath {
        param([string]$Path)
        if ($SimulateManagedPlist -and $Path -in @('com.brave.Browser.plist', '/Library/Managed Preferences/com.brave.Browser.plist')) {
            return '/Library/Managed Preferences/com.brave.Browser.plist'
        }
        & $resolver -Path $Path
    }
    function Resolve-PlatformName { param([string]$Name) return 'macOS' }
    function Test-IsAdministrator { return $true }
    $writes = New-Object System.Collections.Generic.List[object]
    function Set-PolicyValue { param($Target, $Name, $Definition) [void]$writes.Add(@{ Operation = 'set'; Path = $Target.Path }) }
    function Remove-PolicyValue { param($Target, $Name) [void]$writes.Add(@{ Operation = 'remove'; Path = $Target.Path }) }

    $restorePath = Join-Path $TempRoot 'relative-target-backup.json'
    $restoreBackup = [ordered]@{
        schemaVersion = 1
        platform = 'macOS'
        policyKind = $Kind
        registryPath = $RecordedPath
        policies = @(
            @{ name = 'BraveRewardsDisabled'; existed = $true; kind = 'DWord'; value = 1 },
            @{ name = 'BraveWalletDisabled'; existed = $false }
        )
        profileFiles = @()
    }
    Set-JsonFileContent -Path $restorePath -Object $restoreBackup
    if ($ExpectRefusal) {
        # The preview is refused too, and an unelevated run is not sent to sudo: root cannot restore this either.
        function Test-IsAdministrator { return $false }
        foreach ($apply in @($false, $true)) {
            $refusal = ''
            try { Restore-RegistryBackup -BackupPath $restorePath -Manifest $manifest -AllowedPolicyPath $AllowedPath -DoApply:$apply *> $null }
            catch { $refusal = $_.Exception.Message }
            if ($refusal -notlike "This backup targets $ExpectedPath, which macOS only fills from a configuration profile*") { throw "Restore to $ExpectedPath was not refused (apply: $apply): $refusal" }
            if ($writes.Count -ne 0) { throw 'A refused restore called a policy writer.' }
        }
        return
    }
    Restore-RegistryBackup -BackupPath $restorePath -Manifest $manifest -AllowedPolicyPath $AllowedPath *> $null
    if ($writes.Count -ne 0) { throw 'Restore preview called a policy writer.' }
    Restore-RegistryBackup -BackupPath $restorePath -Manifest $manifest -AllowedPolicyPath $AllowedPath -DoApply *> $null
    if ($writes.Count -ne 2 -or $writes[0].Operation -ne 'set' -or $writes[1].Operation -ne 'remove') {
        throw 'Restore did not call both policy writers.'
    }
    foreach ($write in $writes) {
        if ($write.Path -cne $ExpectedPath) { throw "Restore $($write.Operation) used '$($write.Path)' instead of '$ExpectedPath'." }
    }
}

$relativeTargetDirectory = Join-Path $TempRoot 'relative-target'
New-DirectoryLiteral -Path $relativeTargetDirectory
Push-Location -LiteralPath $relativeTargetDirectory
try {
    $plistPath = Join-Path $relativeTargetDirectory 'custom.plist'
    Test-RestorePolicyTarget -Kind MacOSPlist -RecordedPath 'custom.plist' -AllowedPath $plistPath -ExpectedPath $plistPath
    Test-RestorePolicyTarget -Kind MacOSPlist -RecordedPath 'com.brave.Browser.plist' -ExpectedPath '/Library/Managed Preferences/com.brave.Browser.plist' -SimulateManagedPlist -ExpectRefusal
    $jsonPath = Join-Path $relativeTargetDirectory 'custom.json'
    Test-RestorePolicyTarget -Kind JsonFile -RecordedPath 'custom.json' -AllowedPath $jsonPath -ExpectedPath $jsonPath
    Test-RestorePolicyTarget -Kind MacOSDefaults -RecordedPath 'com.brave.Browser' -ExpectedPath 'com.brave.Browser'
}
finally { Pop-Location }

# Restore must not treat differently cased sibling paths as trusted on case-sensitive systems.
if ((Get-Variable -Name IsLinux -Scope Global -ErrorAction SilentlyContinue) -and $IsLinux) {
    $outsideProfile = Join-Path (Join-Path $TempRoot 'profiles') 'Default/Preferences'
    $outsidePolicy = Join-Path $TempRoot 'Policies.json'
    $outsideBackup = Join-Path (Join-Path (Split-Path -Parent $backupPath) 'PROFILE-FILES') 'copy.bak'
    Set-TextFileContent -Path $outsideProfile -Content 'outside profile'
    Set-TextFileContent -Path $outsidePolicy -Content '{"BraveRewardsDisabled":false}'
    Set-TextFileContent -Path $outsideBackup -Content $original
    Set-TextFileContent -Path $policyPath -Content '{"BraveRewardsDisabled":true}'

    foreach ($case in @(
        @{ Field = 'originalPath'; Path = $outsideProfile; Error = 'Backup profile target is outside the selected profile root:*' },
        @{ Field = 'backupPath'; Path = $outsideBackup; Error = 'Backup profile source is outside the expected backup folder:*' },
        @{ Field = 'originalPath'; Path = (Join-Path $profileRoot 'Default/preferences'); Error = 'Backup profile target is not a Brave Preferences file:*' },
        @{ Field = 'registryPath'; Path = $outsidePolicy; Error = 'Backup contains untrusted registry path*' }
    )) {
        $tamperedBackup = Get-JsonFileContent -Path $backupPath
        if ($case.Field -eq 'registryPath') { $tamperedBackup.registryPath = $case.Path }
        else { $tamperedBackup.profileFiles[0].($case.Field) = $case.Path }
        $tamperedPath = Join-Path (Split-Path -Parent $backupPath) 'case-tampered.json'
        Set-JsonFileContent -Path $tamperedPath -Object $tamperedBackup
        foreach ($apply in @($false, $true)) {
            $failure = ''
            try { Restore-RegistryBackup -BackupPath $tamperedPath -Manifest $manifest -ProfileRoot $profileRoot -AllowedPolicyPath $policyPath -DoApply:$apply *> $null }
            catch { $failure = $_.Exception.Message }
            if ($failure -notlike $case.Error) { throw "Case-mismatched $($case.Field) was not rejected: $failure" }
            if ((Get-Utf8FileContent -Path $policyPath) -cne '{"BraveRewardsDisabled":true}' -or
                (Get-Utf8FileContent -Path $outsideProfile) -cne 'outside profile' -or
                (Get-Utf8FileContent -Path $outsidePolicy) -cne '{"BraveRewardsDisabled":false}') {
                throw 'Rejected restore changed a policy or profile file.'
            }
        }
    }
    $failure = ''
    try { Assert-BackupRegistryPath -RegistryPath '/etc/BRAVE/policies/managed/BraveDebloater.json' }
    catch { $failure = $_.Exception.Message }
    if ($failure -notlike 'Backup contains untrusted registry path*') { throw 'Case-mismatched default policy path was not rejected.' }
}
elseif ([System.IO.Path]::DirectorySeparatorChar -eq [char]'\') {
    if (-not (Test-PathIsUnderDirectory -Path ((Join-Path $profileRoot 'Default/Preferences').ToUpperInvariant()) -Directory $profileRoot)) {
        throw 'Windows path containment rejected a case-only difference.'
    }
    if (-not (Test-AllowedPolicyPathMatches -RegistryPath ($policyPath.ToUpperInvariant()) -AllowedPolicyPath $policyPath)) {
        throw 'Windows policy path comparison rejected a case-only difference.'
    }
}

# A failed journal write must leave the profile untouched.
function Invoke-UnrecordedCleanup {
    function Update-BackupProfileFiles { throw 'Injected backup record write failure' }
    Invoke-ProfilePreferenceCleanup -Root $profileRoot -Manifest $manifest -BackupPath $backupPath -SelectedFeatureIds Rewards -UseFeatureFilter -DoApply
}
$failure = ''
try { Invoke-UnrecordedCleanup *> $null }
catch { $failure = $_.Exception.Message }
if ($failure -ne 'Injected backup record write failure') { throw "Unexpected backup failure: $failure" }
if ((Get-Utf8FileContent -Path $firstProfile) -cne $original) { throw 'Cleanup modified a profile without recording its backup.' }

# Missing recovery files must stop restore before policies change, including in previews.
$missingBackup = Get-JsonFileContent -Path $backupPath
$missingBackup.profileFiles[1].backupPath = Join-Path (Get-ProfileBackupDirectory -BackupPath $backupPath) 'missing.bak'
Set-JsonFileContent -Path $backupPath -Object $missingBackup
Set-TextFileContent -Path $policyPath -Content '{"BraveRewardsDisabled":true}'
foreach ($apply in @($false, $true)) {
    $failure = ''
    try { Restore-RegistryBackup -BackupPath $backupPath -Manifest $manifest -ProfileRoot $profileRoot -AllowedPolicyPath $policyPath -DoApply:$apply *> $null }
    catch { $failure = $_.Exception.Message }
    if ($failure -notlike 'Profile backup file is missing:*') { throw "Missing profile copy was not rejected: $failure" }
    if ((Get-Utf8FileContent -Path $policyPath) -cne '{"BraveRewardsDisabled":true}') { throw 'Incomplete restore changed policies.' }
}

# Already-correct preferences keep their bytes and timestamp and create no profile backup copies.
Set-TextFileContent -Path $firstProfile -Content '{ "brave": { "rewards": { "enabled": false } } }'
Set-TextFileContent -Path $secondProfile -Content '{ "brave": { "rewards": { "enabled": false } } }'
$before = Get-Utf8FileContent -Path $firstProfile
$timestamp = [datetime]'2020-01-01T00:00:00Z'
[System.IO.File]::SetLastWriteTimeUtc($firstProfile, $timestamp)
$timestamp = [System.IO.File]::GetLastWriteTimeUtc($firstProfile)
$noOpBackup = New-Backup -Directory (Join-Path $TempRoot 'NoOpBackups') -ScopeName CurrentUser -Target $target -PolicyNames @('BraveRewardsDisabled') -ProfileRoot $profileRoot -Manifest $manifest
$preview = Invoke-ProfilePreferenceCleanup -Root $profileRoot -Manifest $manifest -SelectedFeatureIds Rewards -UseFeatureFilter *>&1 | Out-String
if ($preview -notlike '*Already set:*') { throw 'Preview did not explain unchanged preferences.' }
Invoke-ProfilePreferenceCleanup -Root $profileRoot -Manifest $manifest -BackupPath $noOpBackup -SelectedFeatureIds Rewards -UseFeatureFilter -DoApply *> $null
if ((Get-Utf8FileContent -Path $firstProfile) -cne $before -or [System.IO.File]::GetLastWriteTimeUtc($firstProfile) -ne $timestamp) { throw 'Already-correct Preferences was rewritten.' }
if (@((Get-JsonFileContent -Path $noOpBackup).profileFiles).Count -ne 0) { throw 'Unchanged preferences created backup copies.' }

# A string that spells a boolean still needs correction to the JSON boolean type.
Set-TextFileContent -Path $firstProfile -Content '{"brave":{"rewards":{"enabled":"false"}}}'
Invoke-ProfilePreferenceCleanup -Root $profileRoot -Manifest $manifest -BackupPath $noOpBackup -SelectedFeatureIds Rewards -UseFeatureFilter -DoApply *> $null
$correctedValue = (Get-JsonFileContent -Path $firstProfile).brave.rewards.enabled
if ($correctedValue -isnot [bool] -or $correctedValue) { throw 'Cleanup confused a string with a boolean preference.' }

# PowerShell 7 without -DateKind parses date strings as DateTime; those files must be skipped, not rewritten.
if ($PSVersionTable.PSVersion.Major -ge 6) {
    function Invoke-CleanupWithoutDateKind {
        function Test-JsonDateKindSupported { return $false }
        Invoke-ProfilePreferenceCleanup -Root $profileRoot -Manifest $manifest -BackupPath $noOpBackup -SelectedFeatureIds Rewards -UseFeatureFilter -DoApply
    }
    $dateContent = '{"sync":{"last_synced":"2023-01-01T12:00:00.1234567+13:00"},"brave":{"rewards":{"enabled":true}}}'
    Set-TextFileContent -Path $firstProfile -Content $dateContent
    $dateOutput = Invoke-CleanupWithoutDateKind *>&1 | Out-String
    if ($dateOutput -notlike '*it contains date values*') { throw 'Cleanup without -DateKind did not explain the skipped file.' }
    if ((Get-Utf8FileContent -Path $firstProfile) -cne $dateContent) { throw 'Cleanup without -DateKind rewrote a Preferences file with date values.' }

    # The same applies to the managed policy file, which every set or remove re-serializes.
    function Invoke-PolicyWriteWithoutDateKind {
        param([scriptblock]$Write)
        function Test-JsonDateKindSupported { return $false }
        & $Write
    }
    $datePolicyContent = '{"HomepageLocation":"2023-01-01T12:00:00.1234567+13:00","BraveRewardsDisabled":false}'
    foreach ($write in @(
        { Set-PolicyValue -Target $target -Name 'BraveRewardsDisabled' -Definition ([pscustomobject]@{ type = 'DWord'; value = 1 }) },
        { Remove-PolicyValue -Target $target -Name 'BraveRewardsDisabled' }
    )) {
        Set-TextFileContent -Path $policyPath -Content $datePolicyContent
        $failure = ''
        try { Invoke-PolicyWriteWithoutDateKind -Write $write *> $null }
        catch { $failure = $_.Exception.Message }
        if ($failure -notlike '*contains date values*') { throw "Policy write without -DateKind was not refused: $failure" }
        if ((Get-Utf8FileContent -Path $policyPath) -cne $datePolicyContent) { throw 'Policy write without -DateKind rewrote a policy file with date values.' }
    }
}

# A matching -PolicyPath must never authorize an unrelated registry key.
foreach ($untrustedPath in @('Registry::HKEY_CURRENT_USER\Software\NotBrave', 'Registry::HKEY_LOCAL_MACHINE\Software\NotBrave')) {
    $failure = ''
    try { Assert-BackupRegistryPath -RegistryPath $untrustedPath -AllowedPolicyPath $untrustedPath }
    catch { $failure = $_.Exception.Message }
    if ($failure -notlike '*untrusted registry path*') { throw 'PolicyPath bypassed the Brave registry restore allowlist.' }
}

# Setting and removing a managed policy must preserve deeply nested unrelated values.
$nested = [pscustomobject]@{ marker = 'keep me'; values = @(1, 'two', $false) }
for ($level = 0; $level -lt 30; $level++) {
    $nested = [pscustomobject]@{ child = $nested }
}
$deepPolicy = [pscustomobject]@{ UnrelatedPolicy = $nested; BraveRewardsDisabled = $false }
$expectedNested = ConvertTo-Json -InputObject $nested -Depth 100 -Compress
Set-JsonFileContent -Path $policyPath -Object $deepPolicy -Depth 100
foreach ($write in @(
    { Set-PolicyValue -Target $target -Name 'BraveRewardsDisabled' -Definition ([pscustomobject]@{ type = 'DWord'; value = 1 }) },
    { Remove-PolicyValue -Target $target -Name 'BraveRewardsDisabled' }
)) {
    & $write
    $actualNested = ConvertTo-Json -InputObject (Get-JsonFileContent -Path $policyPath).UnrelatedPolicy -Depth 100 -Compress
    if ($actualNested -cne $expectedNested) { throw 'Policy write truncated unrelated nested JSON.' }
}

# Refuse depth overflow before touching an existing file, including nested arrays.
foreach ($container in @('Object', 'Array')) {
    $tooDeep = [pscustomobject]@{ marker = 'keep me' }
    for ($level = 0; $level -lt 102; $level++) {
        if ($container -eq 'Object') { $tooDeep = [pscustomobject]@{ child = $tooDeep } }
        else { $tooDeep = ,$tooDeep }
    }
    $originalBytes = Get-Utf8FileContent -Path $policyPath
    $failure = ''
    try { Set-JsonFileContent -Path $policyPath -Object $tooDeep -Depth 100 }
    catch { $failure = $_.Exception.Message }
    if ($failure -notlike 'JSON nesting exceeds*') { throw "Depth overflow was not rejected for ${container}: $failure" }
    if ((Get-Utf8FileContent -Path $policyPath) -cne $originalBytes) { throw 'Depth overflow changed the original file.' }
}

foreach ($mode in @('Unmanaged', 'Automatic', 'Off')) {
    $listing = & $scriptPath -Platform Linux -OnlyFeature Rewards -DnsOverHttps $mode -List *>&1 | Out-String
    if ($listing -notlike '*Remove if present: DnsOverHttpsTemplates.*') { throw 'DNS listing omitted resolver removal.' }
    if ($mode -eq 'Unmanaged' -and $listing -notlike '*Remove if present: DnsOverHttpsMode.*') { throw 'DNS listing omitted mode removal.' }
    if ($listing -notlike '*Policy plan:*') { throw 'Policy listing omitted totals.' }
}

$definitions = Get-ManifestMap -Object $manifest.policies
if (-not $definitions.ContainsKey('AutofillSettings')) { throw 'Autofill must use the supported AutofillSettings policy.' }
$autofill = $definitions['AutofillSettings']
$expectedAutofill = '[{"url_pattern":"*","blocked_types":["contact_info","payments"]}]'
$autofillPayload = Get-PolicyPayload -PolicyNames AutofillSettings -PolicyDefinitions $definitions
$reordered = ConvertFrom-JsonText -Json '{"rules":[{"blocked_types":["contact_info","payments"],"url_pattern":"*"}]}'
foreach ($actual in @($expectedAutofill, $reordered.rules)) {
    if (-not (Test-PolicyValueMatches -ActualValue $actual -ExpectedValue $autofill.value -Type Json)) { throw 'Structured policy comparison depends on encoding or object property order.' }
}
if (-not (Test-JsonValuesEqual -Left ([pscustomobject]@{}) -Right ([pscustomobject]@{}))) { throw 'Structured policy comparison rejected empty objects.' }
if (Test-PolicyValueMatches -ActualValue '[{"url_pattern":"*","blocked_types":["payments"]}]' -ExpectedValue $autofill.value -Type Json) { throw 'Structured policy comparison ignored different values.' }
if ((ConvertTo-Json -InputObject $autofillPayload.AutofillSettings -Compress -Depth 20) -cne $expectedAutofill) { throw 'AutofillSettings lost its array or blocked the wrong data types.' }
$autofillReg = ConvertTo-RegFileDocument -RegistryPath (Get-RegistryPolicyPath -ScopeName CurrentUser) -Payload $autofillPayload
if (-not $autofillReg.Contains(('"AutofillSettings"="' + $expectedAutofill.Replace('"', '\"') + '"'))) { throw 'Registry export did not serialize AutofillSettings as a JSON string.' }
foreach ($mobileConfig in @($false, $true)) {
    [xml]$plist = ConvertTo-PlistDocument -Payload $autofillPayload -MobileConfig:$mobileConfig
    $rules = $plist.SelectSingleNode('//key[text()="AutofillSettings"]/following-sibling::*[1]')
    if ($rules.Name -ne 'array' -or $rules.SelectNodes('dict').Count -ne 1) { throw 'Plist export did not encode AutofillSettings as an array of dictionaries.' }
    if ($rules.SelectSingleNode('dict/key[text()="url_pattern"]/following-sibling::*[1]').InnerText -cne '*') { throw 'Plist export lost the Autofill URL pattern.' }
    if (($rules.SelectNodes('dict/key[text()="blocked_types"]/following-sibling::*[1]/string') | ForEach-Object { $_.InnerText }) -join ',' -cne 'contact_info,payments') { throw 'Plist export lost the blocked Autofill types.' }
}

function Test-AutofillRegistryWriter {
    function Test-Path { param($LiteralPath) return $true }
    function New-ItemProperty {
        param($LiteralPath, $Name, $Value, $PropertyType, [switch]$Force)
        if ($Name -ne 'AutofillSettings' -or $PropertyType -ne 'String' -or $Value -cne $expectedAutofill) { throw 'Registry writer did not store AutofillSettings as REG_SZ JSON.' }
    }
    Set-BravePolicy -BasePath (Get-RegistryPolicyPath -ScopeName CurrentUser) -Name AutofillSettings -Definition $autofill
}
Test-AutofillRegistryWriter

$autofillRoot = Join-Path $TempRoot 'Autofill'
New-DirectoryLiteral -Path $autofillRoot
$autofillPath = Join-Path $autofillRoot 'policy.json'
foreach ($priorRules in @('[]', '[{"url_pattern":"https://example.com","blocked_types":["payments"]}]', '[{"url_pattern":"*","blocked_types":["identity_docs"]},{"url_pattern":"https://example.com","blocked_types":["travel"]}]')) {
    $before = '{"AutofillSettings":' + $priorRules + ',"AutofillCreditCardEnabled":true,"AutofillAddressEnabled":false,"Unrelated":"keep"}'
    Set-TextFileContent -Path $autofillPath -Content $before
    $autofillBackups = Join-Path $autofillRoot ([guid]::NewGuid().ToString('N'))
    $preview = & $scriptPath -Platform Linux -OnlyFeature Autofill -PolicyPath $autofillPath -BackupDirectory $autofillBackups *>&1 | Out-String
    if ($preview -notlike '*Would set AutofillSettings*' -or $preview -notlike '*Would remove AutofillCreditCardEnabled*' -or $preview -notlike '*Would remove AutofillAddressEnabled*') { throw 'Autofill migration preview omitted a policy change.' }
    if ((Get-Utf8FileContent -Path $autofillPath) -cne $before -or (Test-Path -LiteralPath $autofillBackups)) { throw 'Autofill preview wrote files.' }
    & $scriptPath -Platform Linux -OnlyFeature Autofill -PolicyPath $autofillPath -BackupDirectory $autofillBackups -Apply -Confirm:$false *> $null
    $applied = Get-JsonFileContent -Path $autofillPath
    if ((ConvertTo-Json -InputObject $applied.AutofillSettings -Compress -Depth 20) -cne $expectedAutofill -or $applied.Unrelated -cne 'keep') { throw 'Autofill migration wrote the wrong structured policy or changed unrelated data.' }
    if ($applied.PSObject.Properties['AutofillCreditCardEnabled'] -or $applied.PSObject.Properties['AutofillAddressEnabled']) { throw 'Autofill migration kept deprecated policies.' }
    $backupFile = @(Get-ChildItem -LiteralPath $autofillBackups -Filter 'BraveDebloater-*.json')[0].FullName
    $backup = Get-JsonFileContent -Path $backupFile
    $savedAutofill = @($backup.policies | Where-Object { $_.name -eq 'AutofillSettings' })[0]
    if ($savedAutofill.kind -ne 'Json' -or (ConvertTo-Json -InputObject $savedAutofill.value -Compress -Depth 20) -cne $priorRules) { throw 'Backup did not preserve the original structured Autofill policy.' }
    Restore-RegistryBackup -BackupPath $backupFile -Manifest $manifest -AllowedPolicyPath $autofillPath -DoApply *> $null
    $restored = Get-JsonFileContent -Path $autofillPath
    if ((ConvertTo-Json -InputObject $restored.AutofillSettings -Compress -Depth 20) -cne $priorRules -or $restored.AutofillCreditCardEnabled -ne $true -or $restored.AutofillAddressEnabled -ne $false -or $restored.Unrelated -cne 'keep') { throw 'Autofill undo did not restore both structured and deprecated policies.' }
}

foreach ($case in @(
    @{ Target = 'Registry'; Name = 'AutofillSettings'; Kind = 'String'; Value = $expectedAutofill; Valid = $true },
    @{ Target = 'Registry'; Name = 'AutofillSettings'; Kind = 'Json'; Value = $autofill.value; Valid = $false },
    @{ Target = 'JsonFile'; Name = 'AutofillSettings'; Kind = 'String'; Value = $expectedAutofill; Valid = $false },
    @{ Target = 'JsonFile'; Name = 'BraveRewardsDisabled'; Kind = 'Json'; Value = $autofill.value; Valid = $false },
    @{ Target = 'JsonFile'; Name = 'AutofillSettings'; Kind = 'Json'; Value = 1; Valid = $false },
    @{ Target = 'Registry'; Name = 'AutofillCreditCardEnabled'; Kind = 'DWord'; Value = 0; Valid = $true },
    @{ Target = 'Registry'; Name = 'AutofillAddressEnabled'; Kind = 'DWord'; Value = 0; Valid = $true }
)) {
    $candidate = [pscustomobject]@{ policyKind = $case.Target; policies = @([pscustomobject]@{ name = $case.Name; existed = $true; kind = $case.Kind; value = $case.Value }) }
    $accepted = $true
    try { Assert-BackupPolicyList -Backup $candidate -PolicyDefinitions $definitions -DeprecatedPolicyNames @(Get-DeprecatedPolicyNames -Manifest $manifest) }
    catch { $accepted = $false }
    if ($accepted -ne $case.Valid) { throw "Incorrect structured backup validation for $($case.Target)/$($case.Name)/$($case.Kind)." }
}

if ((Resolve-PlatformName -Name Auto) -eq 'macOS') {
    $macTarget = [pscustomobject]@{ Platform = 'macOS'; Kind = 'MacOSPlist'; Path = (Join-Path $autofillRoot 'native.plist') }
    Set-PolicyValue -Target $macTarget -Name DnsOverHttpsMode -Definition ([pscustomobject]@{ type = 'String'; value = 'automatic' })
    foreach ($priorRules in @('[]', '[{"url_pattern":"https://example.com","blocked_types":["payments"]}]')) {
        $prior = ConvertFrom-JsonText -Json ('{"rules":' + $priorRules + '}')
        Set-PolicyValue -Target $macTarget -Name AutofillSettings -Definition ([pscustomobject]@{ type = 'Json'; value = $prior.rules })
        $macBackup = New-Backup -Directory (Join-Path $autofillRoot 'mac-backups') -ScopeName LocalMachine -Target $macTarget -PolicyNames AutofillSettings -Manifest $manifest
        Set-PolicyValue -Target $macTarget -Name AutofillSettings -Definition $autofill
        $value = Get-PolicyValue -Target $macTarget -Name AutofillSettings
        if ($value.ReadError -or $value.Kind -ne 'Json' -or $value.Value -isnot [System.Collections.IList] -or $value.Value.Count -ne 1 -or $value.Value[0].url_pattern -cne '*' -or ($value.Value[0].blocked_types -join ',') -cne 'contact_info,payments') { throw 'Native macOS Autofill policy did not round-trip as a structured array.' }
        Restore-RegistryBackup -BackupPath $macBackup -Manifest $manifest -AllowedPolicyPath $macTarget.Path -DoApply *> $null
        $restored = Get-PolicyValue -Target $macTarget -Name AutofillSettings
        if ($restored.ReadError -or $restored.Value -isnot [System.Collections.IList] -or $restored.Value.Count -ne $prior.rules.Count) { throw 'Native macOS Autofill restore changed the array shape.' }
        if ($restored.Value.Count -gt 0 -and ($restored.Value[0].url_pattern -cne 'https://example.com' -or ($restored.Value[0].blocked_types -join ',') -cne 'payments')) { throw 'Native macOS Autofill restore changed the saved rule.' }
        if ((Get-PolicyValue -Target $macTarget -Name DnsOverHttpsMode).Value -cne 'automatic') { throw 'Native macOS Autofill write changed an unrelated policy.' }
    }

    function Get-UnstoredMacOSWriteMessage {
        function Get-PolicyValue { param($Target, [string]$Name) return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null; ReadError = $false } }
        try { Set-PolicyValue -Target $macTarget -Name BraveRewardsDisabled -Definition ([pscustomobject]@{ type = 'DWord'; value = 1 }) }
        catch { return $_.Exception.Message }
        return ''
    }
    if ((Get-UnstoredMacOSWriteMessage) -notlike "macOS reported success for 'BraveRewardsDisabled', but reading*") { throw 'A macOS write that was not stored was reported as set.' }
    Remove-PolicyValue -Target $macTarget -Name DnsOverHttpsMode
    if ((Get-PolicyValue -Target $macTarget -Name DnsOverHttpsMode).Exists) { throw 'Removing a macOS plist policy left it in place.' }
    Remove-PolicyValue -Target $macTarget -Name DnsOverHttpsMode
}

$plistHeader = '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0">'
foreach ($case in @(
        @{ Xml = '<string>automatic</string>'; Expected = 'automatic'; Type = 'String' },
        @{ Xml = '<integer>2</integer>'; Expected = 2; Type = 'DWord' },
        @{ Xml = '<false/>'; Expected = 0; Type = 'DWord' },
        @{ Xml = (ConvertTo-PlistScalar -Value $autofill.value); Expected = $autofill.value; Type = 'Json' }
    )) {
    $parsedPlist = ConvertFrom-PlistXml -Text ($plistHeader + $case.Xml + '</plist>')
    if (-not (Test-PolicyValueMatches -ActualValue $parsedPlist -ExpectedValue $case.Expected -Type $case.Type)) { throw "plutil xml1 output $($case.Xml) did not parse to the written value." }
}
$parsedPlistArray = ConvertFrom-PlistXml -Text ($plistHeader + '<array><string>x</string></array></plist>')
if ($parsedPlistArray -isnot [System.Collections.IList] -or $parsedPlistArray.Count -ne 1) { throw 'A one-item plist array did not stay an array.' }

$managedPlistTarget = [pscustomobject]@{ Platform = 'macOS'; Kind = 'MacOSPlist'; Path = '/Library/Managed Preferences/com.brave.Browser.plist' }
foreach ($managedWrite in @(
        { Set-PolicyValue -Target $managedPlistTarget -Name BraveRewardsDisabled -Definition ([pscustomobject]@{ type = 'DWord'; value = 1 }) },
        { Remove-PolicyValue -Target $managedPlistTarget -Name BraveRewardsDisabled }
    )) {
    $managedMessage = ''
    try { & $managedWrite }
    catch { $managedMessage = $_.Exception.Message }
    if ($managedMessage -notlike 'macOS only keeps machine-wide Brave policies from a configuration profile*') { throw "A write to the macOS managed plist was not refused: $managedMessage" }
}

# A restored integer outside the 32-bit range keeps its value instead of failing the restore.
$wideInteger = ConvertTo-ManagedPolicyValue -Definition ([pscustomobject]@{ type = 'DWord'; value = 5000000000; preserveValueType = $true })
if ($wideInteger -isnot [long] -or $wideInteger -ne 5000000000) { throw 'A 64-bit recorded policy value was not preserved.' }
if ((ConvertTo-ManagedPolicyValue -Definition ([pscustomobject]@{ type = 'DWord'; value = [long]2; preserveValueType = $true })) -isnot [int]) { throw 'A small recorded policy value did not stay a 32-bit integer.' }

# Brave reads string policy values case-sensitively, so a differently cased value is not "already set".
if (Test-PolicyValueMatches -ActualValue 'OFF' -ExpectedValue 'off' -Type String) { throw 'String policy comparison ignored case.' }
if (-not (Test-PolicyValueMatches -ActualValue 'off' -ExpectedValue 'off' -Type String)) { throw 'String policy comparison rejected an equal value.' }

if (Test-UnixFileModeSupported) {
    # Rewriting a file must keep its permissions instead of resetting them to the umask default.
    $modeDirectory = Join-Path $TempRoot 'unix-modes'
    New-DirectoryLiteral -Path $modeDirectory
    $privateFile = Join-Path $modeDirectory 'Preferences'
    Set-TextFileContent -Path $privateFile -Content '{}'
    [System.IO.File]::SetUnixFileMode($privateFile, [System.IO.UnixFileMode]384)
    Set-TextFileContent -Path $privateFile -Content '{"changed":true}'
    if ([int][System.IO.File]::GetUnixFileMode($privateFile) -ne 384) { throw 'Rewriting a 0600 file changed its permissions.' }
    if ((Get-Utf8FileContent -Path $privateFile) -cne '{"changed":true}') { throw 'Rewriting a 0600 file did not replace its content.' }

    # The system policy file and the brave/policies/managed folders must be readable by the Brave user.
    $outerDirectory = Join-Path $modeDirectory 'etc'
    $managedDirectory = Join-Path (Join-Path (Join-Path $outerDirectory 'brave') 'policies') 'managed'
    New-DirectoryLiteral -Path $managedDirectory
    $managedFile = Join-Path $managedDirectory 'BraveDebloater.json'
    Set-TextFileContent -Path $managedFile -Content '{}'
    [System.IO.File]::SetUnixFileMode($managedFile, [System.IO.UnixFileMode]384)
    $restrictedDirectories = @($managedDirectory, (Split-Path -Parent $managedDirectory), (Split-Path -Parent (Split-Path -Parent $managedDirectory)), $outerDirectory)
    foreach ($directory in $restrictedDirectories) { [System.IO.File]::SetUnixFileMode($directory, [System.IO.UnixFileMode]448) }
    Grant-ManagedPolicyReadAccess -Path $managedFile
    if ([int][System.IO.File]::GetUnixFileMode($managedFile) -ne 420) { throw 'The managed policy file was not made readable.' }
    foreach ($directory in $restrictedDirectories[0..2]) {
        if ([int][System.IO.File]::GetUnixFileMode($directory) -ne 493) { throw "The managed policy folder was not made readable: $directory" }
    }
    if ([int][System.IO.File]::GetUnixFileMode($outerDirectory) -ne 448) { throw 'Read access was granted above the Brave policy folders.' }
}

Write-Host 'Write safety checks passed.'
