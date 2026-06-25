#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Standard', 'High', 'Extreme', 'Core', 'Privacy', 'Aggressive')]
    [string]$Preset = 'Extreme',

    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$Scope = 'CurrentUser',

    [switch]$Apply,

    [switch]$Doctor,

    [switch]$LockShields,

    [switch]$Customize,

    [string[]]$OnlyFeature = @(),

    [string[]]$IncludeFeature = @(),

    [string[]]$ExcludeFeature = @(),

    [switch]$IncludeProfilePreferences,

    [string]$ProfileRoot = (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'),

    [string]$BackupDirectory,

    [string]$UndoFromBackup,

    [switch]$List,

    [switch]$ListFeatures,

    [switch]$NoBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
    $BackupDirectory = Join-Path $ProjectRoot 'backups'
}

function Write-Step {
    param([string]$Message)
    Write-Host "[BraveDebloater] $Message"
}

function Write-DryRun {
    param([string]$Message)
    Write-Host "[dry-run] $Message"
}

function Get-Manifest {
    $manifestPath = Join-Path $ProjectRoot 'config\policies.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Cannot find policy manifest at $manifestPath."
    }

    return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

function Get-ManifestMap {
    param([Parameter(Mandatory = $true)]$Object)

    $map = @{}
    foreach ($property in $Object.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }
    return $map
}

function Resolve-PresetPolicies {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Presets,
        [hashtable]$Seen = @{}
    )

    if (-not $Presets.ContainsKey($Name)) {
        throw "Unknown preset '$Name'."
    }
    if ($Seen.ContainsKey($Name)) {
        throw "Preset cycle detected at '$Name'."
    }

    $Seen[$Name] = $true
    $resolved = New-Object System.Collections.Generic.List[string]

    foreach ($entry in @($Presets[$Name])) {
        if ($entry -isnot [string]) {
            throw "Preset '$Name' contains a non-string entry."
        }

        if ($entry.StartsWith('@')) {
            $childName = $entry.Substring(1)
            foreach ($childPolicy in Resolve-PresetPolicies -Name $childName -Presets $Presets -Seen ($Seen.Clone())) {
                if (-not $resolved.Contains($childPolicy)) {
                    [void]$resolved.Add($childPolicy)
                }
            }
        }
        elseif (-not $resolved.Contains($entry)) {
            [void]$resolved.Add($entry)
        }
    }

    return $resolved.ToArray()
}

function Get-FeatureMap {
    param([object[]]$Features)

    $map = @{}
    foreach ($feature in @($Features)) {
        $id = [string]$feature.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'Feature entry is missing an id.'
        }
        if ($map.ContainsKey($id)) {
            throw "Duplicate feature id '$id'."
        }
        $map[$id] = $feature
    }
    return $map
}

function Get-FeaturePolicies {
    param([Parameter(Mandatory = $true)]$Feature)

    return @($Feature.policies) | ForEach-Object { [string]$_ }
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

function Test-FeatureSelectedByPolicy {
    param(
        [Parameter(Mandatory = $true)]$Feature,
        [Parameter(Mandatory = $true)]$PolicyNames,
        [Parameter(Mandatory = $true)][string]$PresetName
    )

    $policies = @(Get-FeaturePolicies -Feature $Feature)
    if ($policies.Count -eq 0) {
        return (@($Feature.defaultPresets) -contains $PresetName)
    }

    foreach ($policyName in $policies) {
        if (-not $PolicyNames.Contains($policyName)) {
            return $false
        }
    }
    return $true
}

function Assert-FeatureNames {
    param(
        [string[]]$Names,
        [Parameter(Mandatory = $true)][hashtable]$FeatureMap
    )

    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace([string]$name)) {
            continue
        }
        if (-not $FeatureMap.ContainsKey($name)) {
            $available = ($FeatureMap.Keys | Sort-Object) -join ', '
            throw "Unknown feature '$name'. Available features: $available"
        }
    }
}

function Get-NormalizedFeatureName {
    param([string[]]$Names)

    $normalized = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Names)) {
        $trimmed = ([string]$name).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }
        Add-StringIfMissing -List $normalized -Value $trimmed
    }
    return $normalized.ToArray()
}

function Assert-FeatureReferences {
    param(
        [object[]]$Features,
        [Parameter(Mandatory = $true)][hashtable]$PolicyDefinitions
    )

    foreach ($feature in @($Features)) {
        foreach ($policyName in Get-FeaturePolicies -Feature $feature) {
            if (-not $PolicyDefinitions.ContainsKey($policyName)) {
                throw "Feature '$($feature.id)' references undefined policy '$policyName'."
            }
        }
    }
}

function Set-FeatureSelection {
    param(
        [Parameter(Mandatory = $true)]$Feature,
        [Parameter(Mandatory = $true)]$PolicyNames,
        [Parameter(Mandatory = $true)]$SelectedFeatureIds,
        [Parameter(Mandatory = $true)][bool]$Selected
    )

    $featureId = [string]$Feature.id
    if ($Selected) {
        Add-StringIfMissing -List $SelectedFeatureIds -Value $featureId
        foreach ($policyName in Get-FeaturePolicies -Feature $Feature) {
            Add-StringIfMissing -List $PolicyNames -Value $policyName
        }
        return
    }

    Remove-StringFromList -List $SelectedFeatureIds -Value $featureId
    foreach ($policyName in Get-FeaturePolicies -Feature $Feature) {
        Remove-StringFromList -List $PolicyNames -Value $policyName
    }
}

function Read-FeatureChoice {
    param(
        [Parameter(Mandatory = $true)]$Feature,
        [Parameter(Mandatory = $true)][bool]$Default
    )

    $defaultLabel = if ($Default) { 'Y/n' } else { 'y/N' }
    $prompt = "Apply $($Feature.label) cleanup? [$defaultLabel]"
    while ($true) {
        $answer = (Read-Host $prompt).Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }
        switch ($answer.ToLowerInvariant()) {
            { $_ -in @('y', 'yes') } { return $true }
            { $_ -in @('n', 'no') } { return $false }
            default { Write-Host 'Please answer y or n.' }
        }
    }
}

function Resolve-FeatureSelection {
    param(
        [object[]]$Features,
        [Parameter(Mandatory = $true)][hashtable]$FeatureMap,
        [Parameter(Mandatory = $true)]$PolicyNames,
        [Parameter(Mandatory = $true)][string]$PresetName,
        [string[]]$IncludeNames,
        [string[]]$ExcludeNames,
        [switch]$UsePrompt
    )

    $selectedFeatureIds = New-Object System.Collections.Generic.List[string]
    foreach ($feature in @($Features)) {
        if (Test-FeatureSelectedByPolicy -Feature $feature -PolicyNames $PolicyNames -PresetName $PresetName) {
            Add-StringIfMissing -List $selectedFeatureIds -Value ([string]$feature.id)
        }
    }

    if ($UsePrompt) {
        foreach ($feature in @($Features)) {
            $default = $selectedFeatureIds.Contains([string]$feature.id)
            $selected = Read-FeatureChoice -Feature $feature -Default $default
            Set-FeatureSelection -Feature $feature -PolicyNames $PolicyNames -SelectedFeatureIds $selectedFeatureIds -Selected:$selected
        }
    }

    foreach ($featureName in @($IncludeNames)) {
        if ([string]::IsNullOrWhiteSpace([string]$featureName)) {
            continue
        }
        Set-FeatureSelection -Feature $FeatureMap[$featureName] -PolicyNames $PolicyNames -SelectedFeatureIds $selectedFeatureIds -Selected:$true
    }

    foreach ($featureName in @($ExcludeNames)) {
        if ([string]::IsNullOrWhiteSpace([string]$featureName)) {
            continue
        }
        Set-FeatureSelection -Feature $FeatureMap[$featureName] -PolicyNames $PolicyNames -SelectedFeatureIds $selectedFeatureIds -Selected:$false
    }

    return $selectedFeatureIds.ToArray()
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RegistryPolicyPath {
    param([string]$ScopeName)

    if ($ScopeName -eq 'LocalMachine') {
        return 'Registry::HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave'
    }

    return 'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave'
}

function Get-RegistryBasePath {
    param([string]$ScopeName)

    if ($ScopeName -eq 'LocalMachine') {
        if (-not (Test-IsAdministrator)) {
            throw 'LocalMachine scope requires an elevated PowerShell session. Use -Scope CurrentUser or run as administrator.'
        }
    }

    return (Get-RegistryPolicyPath -ScopeName $ScopeName)
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

function Assert-BackupRegistryPath {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [switch]$DoApply
    )

    $allowedPaths = @(
        'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave',
        'Registry::HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave'
    )

    if ($allowedPaths -notcontains $RegistryPath) {
        throw "Backup contains untrusted registry path '$RegistryPath'."
    }

    if ($DoApply -and $RegistryPath -ieq 'Registry::HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave' -and -not (Test-IsAdministrator)) {
        throw 'Restoring a LocalMachine backup requires an elevated PowerShell session.'
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
            if ($kind -eq 'DWord' -and $value -isnot [int] -and $value -isnot [long]) {
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
        [switch]$DoApply
    )

    $schemaVersion = Get-RequiredPropertyValue -Object $Backup -Name 'schemaVersion' -Context 'Backup'
    if ($schemaVersion -ne 1) {
        throw "Unsupported backup schema version '$schemaVersion'."
    }

    $registryPath = [string](Get-RequiredPropertyValue -Object $Backup -Name 'registryPath' -Context 'Backup')
    Assert-BackupRegistryPath -RegistryPath $registryPath -DoApply:$DoApply

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

function Assert-PolicySafety {
    param(
        [string[]]$PolicyNames,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $blockedNames = @($Manifest.safety.blockedPolicyNames)
    $blockedPatterns = @($Manifest.safety.blockedNamePatterns)

    foreach ($policyName in $PolicyNames) {
        if ($blockedNames -contains $policyName) {
            throw "Refusing to apply protected policy '$policyName'."
        }

        foreach ($pattern in $blockedPatterns) {
            if ($policyName -match $pattern) {
                throw "Refusing to apply '$policyName' because it matches protected pattern '$pattern'."
            }
        }
    }
}

function Get-PolicySafetyFinding {
    param(
        [string[]]$PolicyNames,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $findings = New-Object System.Collections.Generic.List[string]
    $blockedNames = @($Manifest.safety.blockedPolicyNames)
    $blockedPatterns = @($Manifest.safety.blockedNamePatterns)

    foreach ($policyName in $PolicyNames) {
        if ($blockedNames -contains $policyName) {
            [void]$findings.Add("Protected policy '$policyName' is present.")
            continue
        }

        foreach ($pattern in $blockedPatterns) {
            if ($policyName -match $pattern) {
                [void]$findings.Add("Policy '$policyName' matches protected pattern '$pattern'.")
                break
            }
        }
    }

    return $findings.ToArray()
}

function Get-RegistrySnapshot {
    param(
        [string]$BasePath,
        [string[]]$PolicyNames
    )

    $snapshot = New-Object System.Collections.Generic.List[object]
    $keyExists = Test-Path -LiteralPath $BasePath
    $key = $null
    if ($keyExists) {
        $key = Get-Item -LiteralPath $BasePath
    }

    foreach ($policyName in $PolicyNames) {
        $entry = [ordered]@{
            name = $policyName
            existed = $false
            value = $null
            kind = $null
        }

        if ($keyExists) {
            try {
                $value = $key.GetValue($policyName, $null)
                if ($null -ne $value) {
                    $entry.existed = $true
                    $entry.value = $value
                    $entry.kind = $key.GetValueKind($policyName).ToString()
                }
            }
            catch {
                Write-Warning "Failed to read registry value '$policyName': $($_.Exception.Message)"
                $entry.existed = $false
            }
        }

        [void]$snapshot.Add([pscustomobject]$entry)
    }

    return $snapshot.ToArray()
}

function Get-RegistryPolicyReport {
    param([string]$ScopeName)

    $path = Get-RegistryPolicyPath -ScopeName $ScopeName
    $entries = New-Object System.Collections.Generic.List[object]
    $keyExists = $false
    $canRead = $true
    $errorMessage = ''

    try {
        $keyExists = Test-Path -LiteralPath $path
        if ($keyExists) {
            $key = Get-Item -LiteralPath $path
            foreach ($name in $key.GetValueNames()) {
                if ([string]::IsNullOrWhiteSpace($name)) {
                    continue
                }

                [void]$entries.Add([pscustomobject]@{
                        Name = [string]$name
                        Value = $key.GetValue($name, $null)
                        Kind = $key.GetValueKind($name).ToString()
                    })
            }
        }
    }
    catch {
        $canRead = $false
        $errorMessage = $_.Exception.Message
        $entries.Clear()
    }

    return [pscustomobject]@{
        Scope = $ScopeName
        Path = $path
        KeyExists = $keyExists
        CanRead = $canRead
        ErrorMessage = $errorMessage
        Entries = $entries.ToArray()
    }
}

function Get-PolicyEntryMap {
    param([object[]]$Entries)

    $map = @{}
    foreach ($entry in @($Entries)) {
        $map[[string]$entry.Name] = $entry
    }
    return $map
}

function Test-PolicyValueMatches {
    param(
        $ActualValue,
        $ExpectedValue,
        [string]$Type
    )

    try {
        if ($Type -eq 'DWord' -or $Type -eq 'QWord') {
            return ([int64]$ActualValue -eq [int64]$ExpectedValue)
        }
        if ($Type -eq 'String') {
            return ([string]$ActualValue -eq [string]$ExpectedValue)
        }
    }
    catch {
        Write-Warning "Policy value comparison failed for type '$Type': $($_.Exception.Message)"
        return $false
    }

    return $false
}

function Get-FeaturePolicyStatus {
    param(
        [Parameter(Mandatory = $true)]$Feature,
        [hashtable]$PolicyEntries,
        [hashtable]$PolicyDefinitions
    )

    $policies = @($Feature.policies)
    if ($policies.Count -eq 0) {
        return 'Profile-only'
    }

    $present = 0
    $matching = 0
    foreach ($policyName in $policies) {
        if (-not $PolicyEntries.ContainsKey($policyName)) {
            continue
        }

        $present++
        $definition = $PolicyDefinitions[$policyName]
        if (Test-PolicyValueMatches -ActualValue $PolicyEntries[$policyName].Value -ExpectedValue $definition.value -Type ([string]$definition.type)) {
            $matching++
        }
    }

    if ($present -eq 0) {
        return 'Not applied'
    }
    if ($matching -eq $policies.Count) {
        return 'Applied'
    }
    if ($matching -gt 0) {
        return 'Partial'
    }
    return 'Different'
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

function Set-JsonFileContent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object,
        [int]$Depth = 20
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tempPath = Join-Path $directory ('.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
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

function New-Backup {
    param(
        [string]$Directory,
        [string]$ScopeName,
        [string]$RegistryPath,
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
        registryPath = $RegistryPath
        profileRoot = $ProfileRoot
        policies = @(Get-RegistrySnapshot -BasePath $RegistryPath -PolicyNames $PolicyNames)
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

function Set-BravePolicy {
    param(
        [string]$BasePath,
        [string]$Name,
        [Parameter(Mandatory = $true)]$Definition
    )

    if (-not (Test-Path -LiteralPath $BasePath)) {
        New-Item -Path $BasePath -Force | Out-Null
    }

    $propertyType = switch ($Definition.type) {
        'DWord' { 'DWord' }
        'String' { 'String' }
        default { throw "Unsupported registry type '$($Definition.type)' for policy '$Name'." }
    }

    $value = $Definition.value
    if ($Definition.type -eq 'DWord') {
        $value = [int]$value
    }

    New-ItemProperty -LiteralPath $BasePath -Name $Name -Value $value -PropertyType $propertyType -Force | Out-Null
}

function Restore-RegistryBackup {
    param(
        [string]$BackupPath,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ProfileRoot,
        [switch]$DoApply
    )

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        throw "Backup file not found: $BackupPath"
    }

    $backup = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
    Assert-BackupObject -Backup $backup -Manifest $Manifest -BackupPath $BackupPath -ProfileRoot $ProfileRoot -DoApply:$DoApply
    $registryPath = [string]$backup.registryPath

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
            if (-not (Test-Path -LiteralPath $registryPath)) {
                New-Item -Path $registryPath -Force | Out-Null
            }

            $kind = [string]$policy.kind
            $value = $policy.value
            if ($kind -eq 'DWord') {
                $value = [int]$value
            }

            New-ItemProperty -LiteralPath $registryPath -Name $name -Value $value -PropertyType $kind -Force | Out-Null
            Write-Step "Restored $name."
        }
        elseif (Test-Path -LiteralPath $registryPath) {
            try {
                Remove-ItemProperty -LiteralPath $registryPath -Name $name -ErrorAction Stop
                Write-Step "Removed $name."
            }
            catch {
                Write-Warning "Failed to remove registry value '$name': $($_.Exception.Message)"
            }
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
            Write-Warning "Profile backup missing: $source"
        }
    }
}

function Get-JsonPathResult {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $current = $Object
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $current -or $null -eq $current.PSObject.Properties[$part]) {
            return [pscustomobject]@{ exists = $false; value = $null }
        }
        $current = $current.PSObject.Properties[$part].Value
    }

    return [pscustomobject]@{ exists = $true; value = $current }
}

function Set-JsonPathValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [bool]$CreateMissing = $false
    )

    $parts = $Path -split '\.'
    $current = $Object

    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        $part = $parts[$i]
        if ($null -eq $current.PSObject.Properties[$part]) {
            if (-not $CreateMissing) {
                return $false
            }
            $child = [pscustomobject]@{}
            $current | Add-Member -NotePropertyName $part -NotePropertyValue $child
        }
        $current = $current.PSObject.Properties[$part].Value
    }

    $leaf = $parts[-1]
    if ($null -eq $current.PSObject.Properties[$leaf]) {
        if (-not $CreateMissing) {
            return $false
        }
        $current | Add-Member -NotePropertyName $leaf -NotePropertyValue $Value
    }
    else {
        $current.PSObject.Properties[$leaf].Value = $Value
    }

    return $true
}

function Get-BraveProfilePreferenceFiles {
    param([string]$Root)

    $files = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Root)) {
        return $files.ToArray()
    }

    try {
        Get-ChildItem -LiteralPath $Root -Directory -ErrorAction Stop |
            ForEach-Object {
                $preferencesPath = Join-Path $_.FullName 'Preferences'
                if (Test-Path -LiteralPath $preferencesPath) {
                    [void]$files.Add($preferencesPath)
                }
            }
    }
    catch {
        Write-Warning "Failed to enumerate profile directories under '$Root': $($_.Exception.Message)"
    }

    return $files.ToArray()
}

function Invoke-ProfilePreferenceCleanup {
    param(
        [string]$Root,
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$BackupPath,
        [string[]]$SelectedFeatureIds = @(),
        [switch]$UseFeatureFilter,
        [switch]$DoApply
    )

    $files = @(Get-BraveProfilePreferenceFiles -Root $Root)
    if ($files.Count -eq 0) {
        Write-Warning "No Brave profile files found under $Root."
        return
    }

    if ($DoApply -and (Get-Process -Name brave -ErrorAction SilentlyContinue)) {
        Write-Warning 'Brave is running, so profile preference cleanup was skipped. Close Brave and rerun with -IncludeProfilePreferences to apply those cosmetic patches.'
        return
    }

    $profileBackups = New-Object System.Collections.Generic.List[object]
    $patches = @($Manifest.profilePreferencePatches)
    if ($UseFeatureFilter) {
        $patches = @($patches | Where-Object {
                $featureId = [string]$_.feature
                [string]::IsNullOrWhiteSpace($featureId) -or ($SelectedFeatureIds -contains $featureId)
            })
    }

    foreach ($file in $files) {
        if (-not $DoApply) {
            Write-DryRun "Would inspect profile file $file."
        }

        $json = $null
        try {
            $raw = Get-Content -LiteralPath $file -Raw
            if ([string]::IsNullOrWhiteSpace($raw)) {
                throw 'The file is empty.'
            }
            $json = $raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "Skipping invalid profile Preferences file: $file ($($_.Exception.Message))"
            continue
        }

        if ($json -isnot [System.Management.Automation.PSCustomObject]) {
            Write-Warning "Skipping invalid profile Preferences file: $file (top-level value is not a JSON object)."
            continue
        }

        $changed = $false

        foreach ($patch in $patches) {
            $path = [string]$patch.path
            if ($path -match '(?i)shield') {
                throw "Refusing profile preference patch that mentions Shields: $path"
            }

            $current = Get-JsonPathResult -Object $json -Path $path
            $createMissing = [bool]$patch.createMissing

            if (-not $current.exists -and -not $createMissing) {
                continue
            }

            if (-not $DoApply) {
                if ($current.exists) {
                    Write-DryRun "Would set $path in $file from '$($current.value)' to '$($patch.value)'."
                }
                else {
                    Write-DryRun "Would create $path in $file with '$($patch.value)'."
                }
                continue
            }

            if (Set-JsonPathValue -Object $json -Path $path -Value $patch.value -CreateMissing:$createMissing) {
                $changed = $true
            }
        }

        if ($DoApply -and $changed) {
            $profileBackupDirectory = Join-Path (Split-Path -Parent $BackupPath) 'profile-files'
            if (-not (Test-Path -LiteralPath $profileBackupDirectory)) {
                New-Item -ItemType Directory -Path $profileBackupDirectory -Force | Out-Null
            }

            $safeName = ($file -replace '[:\\\/ ]', '_')
            $profileBackupPath = Join-Path $profileBackupDirectory "$safeName.bak"
            Copy-Item -LiteralPath $file -Destination $profileBackupPath -Force
            [void]$profileBackups.Add([pscustomobject]@{
                originalPath = $file
                backupPath = $profileBackupPath
            })

            Set-JsonFileContent -Path $file -Object $json -Depth 100
            Write-Step "Updated profile preferences in $file."
        }
    }

    if ($DoApply -and $profileBackups.Count -gt 0) {
        Update-BackupProfileFiles -BackupPath $BackupPath -ProfileFiles $profileBackups.ToArray()
    }
}

function Show-PolicyList {
    param(
        [string[]]$PolicyNames,
        [hashtable]$PolicyDefinitions
    )

    $rows = foreach ($name in $PolicyNames) {
        $definition = $PolicyDefinitions[$name]
        [pscustomobject]@{
            Policy = $name
            Value = $definition.value
            Category = $definition.category
            Reason = $definition.reason
        }
    }

    $rows | Format-Table -AutoSize -Wrap
}

function Show-FeatureList {
    param(
        [object[]]$Features,
        [string[]]$SelectedFeatureIds
    )

    $rows = foreach ($feature in @($Features)) {
        [pscustomobject]@{
            Feature = [string]$feature.id
            Selected = ($SelectedFeatureIds -contains [string]$feature.id)
            Label = [string]$feature.label
            Reason = [string]$feature.reason
        }
    }

    $rows | Format-Table -AutoSize -Wrap
}

function Show-ProfilePreferencePatchList {
    param([object[]]$Patches)

    $rows = foreach ($patch in @($Patches)) {
        [pscustomobject]@{
            Feature = [string]$patch.feature
            PreferencePath = [string]$patch.path
            Value = $patch.value
            CreateMissing = [bool]$patch.createMissing
            Reason = [string]$patch.reason
        }
    }

    $rows | Format-Table -AutoSize -Wrap
}

function Show-DoctorReport {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [object[]]$Features,
        [hashtable]$PolicyDefinitions,
        [string]$ProfileRoot,
        [string]$BackupDirectory
    )

    Write-Step 'Doctor report (read-only). No registry, backup, or profile files will be changed.'

    $currentUserReport = Get-RegistryPolicyReport -ScopeName 'CurrentUser'
    $localMachineReport = Get-RegistryPolicyReport -ScopeName 'LocalMachine'
    $reports = @($currentUserReport, $localMachineReport)
    $unreadableScopes = New-Object System.Collections.Generic.List[string]

    foreach ($report in $reports) {
        if (-not $report.CanRead) {
            [void]$unreadableScopes.Add([string]$report.Scope)
            Write-Step "$($report.Scope) policies: read failed ($($report.ErrorMessage))"
            continue
        }

        if ($report.Entries.Count -gt 0) {
            Write-Step "$($report.Scope) policies: found $($report.Entries.Count) value(s)."
        }
        elseif ($report.KeyExists) {
            Write-Step "$($report.Scope) policies: key exists but has no values."
        }
        else {
            Write-Step "$($report.Scope) policies: none detected."
        }
    }

    if (-not $localMachineReport.CanRead) {
        Write-Step 'Machine-wide policies: unknown because LocalMachine policies could not be read.'
    }
    elseif ($localMachineReport.Entries.Count -gt 0) {
        Write-Step 'Machine-wide policies: detected. Brave may show managed settings for all users.'
    }
    else {
        Write-Step 'Machine-wide policies: none detected.'
    }

    $allPolicyNames = @($reports | ForEach-Object { @($_.Entries) } | ForEach-Object { [string]$_.Name })
    $safetyFindings = @(Get-PolicySafetyFinding -PolicyNames $allPolicyNames -Manifest $Manifest)
    if ($unreadableScopes.Count -gt 0) {
        Write-Warning "Safety: check incomplete - $($unreadableScopes.ToArray() -join ', ') policies could not be read."
    }

    if ($safetyFindings.Count -eq 0 -and $unreadableScopes.Count -eq 0) {
        Write-Step 'Safety: no protected Brave policy names detected.'
    }
    elseif ($safetyFindings.Count -gt 0) {
        foreach ($finding in $safetyFindings) {
            Write-Warning "Safety: $finding"
        }
    }

    $braveProcesses = @(Get-Process -Name brave -ErrorAction SilentlyContinue)
    if ($braveProcesses.Count -gt 0) {
        Write-Step "Brave process: running ($($braveProcesses.Count) process(es)). Profile preference cleanup would be skipped."
    }
    else {
        Write-Step 'Brave process: not running.'
    }

    $profileFiles = @(Get-BraveProfilePreferenceFiles -Root $ProfileRoot)
    if (Test-Path -LiteralPath $ProfileRoot) {
        Write-Step "Profile root: found ($($profileFiles.Count) Preferences file(s)) - $ProfileRoot"
    }
    else {
        Write-Step "Profile root: missing - $ProfileRoot"
    }

    $backupSummary = Get-BackupSummary -Directory $BackupDirectory
    Write-Step "Backups: $($backupSummary.Count) found in $($backupSummary.Directory)"
    if (-not [string]::IsNullOrWhiteSpace($backupSummary.Latest)) {
        Write-Step "Latest backup: $($backupSummary.Latest)"
    }

    $currentUserPolicies = Get-PolicyEntryMap -Entries $currentUserReport.Entries
    $localMachinePolicies = Get-PolicyEntryMap -Entries $localMachineReport.Entries

    Write-Step 'Policy scopes:'
    $scopeRows = foreach ($report in $reports) {
        $status = 'Missing'
        if (-not $report.CanRead) {
            $status = 'Read failed'
        }
        elseif ($report.Entries.Count -gt 0) {
            $status = 'Found'
        }
        elseif ($report.KeyExists) {
            $status = 'Empty'
        }

        [pscustomobject]@{
            Scope = $report.Scope
            Status = $status
            Values = $report.Entries.Count
            Path = $report.Path
        }
    }
    $scopeRows | Format-Table -AutoSize -Wrap

    Write-Step 'Feature status:'
    $featureRows = foreach ($feature in @($Features)) {
        [pscustomobject]@{
            Feature = [string]$feature.id
            CurrentUser = if (-not $currentUserReport.CanRead) { 'Read failed' } else { Get-FeaturePolicyStatus -Feature $feature -PolicyEntries $currentUserPolicies -PolicyDefinitions $PolicyDefinitions }
            LocalMachine = if (-not $localMachineReport.CanRead) { 'Read failed' } else { Get-FeaturePolicyStatus -Feature $feature -PolicyEntries $localMachinePolicies -PolicyDefinitions $PolicyDefinitions }
            Label = [string]$feature.label
        }
    }
    $featureRows | Format-Table -AutoSize -Wrap

    $unknownRows = New-Object System.Collections.Generic.List[object]
    foreach ($report in $reports) {
        foreach ($entry in @($report.Entries)) {
            if (-not $PolicyDefinitions.ContainsKey([string]$entry.Name)) {
                [void]$unknownRows.Add([pscustomobject]@{
                        Scope = $report.Scope
                        Policy = [string]$entry.Name
                        Value = $entry.Value
                        Kind = [string]$entry.Kind
                    })
            }
        }
    }

    if ($unknownRows.Count -gt 0) {
        Write-Step 'Unknown Brave policies: detected. These may have been set by Brave, another tool, or an organization.'
        $unknownRows.ToArray() | Format-Table -AutoSize -Wrap
    }
    else {
        Write-Step 'Unknown Brave policies: none detected.'
    }
}

$manifest = Get-Manifest
$applyChanges = $Apply -and -not $WhatIfPreference
$isWhatIf = $Apply -and $WhatIfPreference

if ($UndoFromBackup) {
    Restore-RegistryBackup -BackupPath $UndoFromBackup -Manifest $manifest -ProfileRoot $ProfileRoot -DoApply:$applyChanges
    if (-not $applyChanges) {
        if ($isWhatIf) {
            Write-Step 'Undo WhatIf complete. Rerun with -Apply without -WhatIf to restore the backup.'
        }
        else {
            Write-Step 'Undo dry-run complete. Rerun with -Apply to restore the backup.'
        }
    }
    else {
        Write-Step 'Undo complete. Restart Brave, then open brave://policy to verify.'
    }
    return
}

$presets = Get-ManifestMap -Object $manifest.presets
$policyDefinitions = Get-ManifestMap -Object $manifest.policies
$features = @($manifest.features)
$featureMap = Get-FeatureMap -Features $features
Assert-FeatureReferences -Features $features -PolicyDefinitions $policyDefinitions

if ($Doctor) {
    if ($Apply) {
        Write-Warning '-Doctor is read-only. -Apply is ignored in Doctor mode.'
    }
    Show-DoctorReport -Manifest $manifest -Features $features -PolicyDefinitions $policyDefinitions -ProfileRoot $ProfileRoot -BackupDirectory $BackupDirectory
    return
}

$normalizedOnlyFeature = @(Get-NormalizedFeatureName -Names $OnlyFeature)
$normalizedIncludeFeature = @(Get-NormalizedFeatureName -Names $IncludeFeature)
$normalizedExcludeFeature = @(Get-NormalizedFeatureName -Names $ExcludeFeature)

if ($PSBoundParameters.ContainsKey('OnlyFeature') -and $normalizedOnlyFeature.Count -eq 0) {
    throw 'Specified -OnlyFeature contains only blank entries; please provide a valid feature name.'
}

Assert-FeatureNames -Names $normalizedIncludeFeature -FeatureMap $featureMap
Assert-FeatureNames -Names $normalizedExcludeFeature -FeatureMap $featureMap
Assert-FeatureNames -Names $normalizedOnlyFeature -FeatureMap $featureMap
foreach ($featureName in $normalizedIncludeFeature) {
    if ($normalizedExcludeFeature -contains $featureName) {
        throw "Feature '$featureName' cannot be both included and excluded."
    }
}

$onlyFeatureMode = $normalizedOnlyFeature.Count -gt 0
if ($onlyFeatureMode -and ($Customize -or $normalizedIncludeFeature.Count -gt 0 -or $normalizedExcludeFeature.Count -gt 0)) {
    throw '-OnlyFeature cannot be combined with -Customize, -IncludeFeature, or -ExcludeFeature.'
}

$policyNames = New-Object System.Collections.Generic.List[string]

if (-not $onlyFeatureMode) {
    foreach ($name in Resolve-PresetPolicies -Name $Preset -Presets $presets) {
        [void]$policyNames.Add($name)
    }
}

$customFeatureRequested = $onlyFeatureMode -or $Customize -or $normalizedIncludeFeature.Count -gt 0 -or $normalizedExcludeFeature.Count -gt 0
$featurePresetName = if ($onlyFeatureMode) { '__OnlyFeature' } else { $Preset }
$featureIncludeNames = if ($onlyFeatureMode) { $normalizedOnlyFeature } else { $normalizedIncludeFeature }
$featureExcludeNames = if ($onlyFeatureMode) { @() } else { $normalizedExcludeFeature }
$selectedFeatureIds = @(Resolve-FeatureSelection -Features $features -FeatureMap $featureMap -PolicyNames $policyNames -PresetName $featurePresetName -IncludeNames $featureIncludeNames -ExcludeNames $featureExcludeNames -UsePrompt:$Customize)

if ($LockShields) {
    foreach ($name in Resolve-PresetPolicies -Name 'ShieldBaseline' -Presets $presets) {
        if (-not $policyNames.Contains($name)) {
            [void]$policyNames.Add($name)
        }
    }
}

foreach ($policyName in $policyNames) {
    if (-not $policyDefinitions.ContainsKey($policyName)) {
        throw "Policy '$policyName' is referenced by a preset but not defined."
    }
}

Assert-PolicySafety -PolicyNames $policyNames.ToArray() -Manifest $manifest

if ($ListFeatures) {
    Show-FeatureList -Features $features -SelectedFeatureIds $selectedFeatureIds
    return
}

if ($List) {
    Show-PolicyList -PolicyNames $policyNames.ToArray() -PolicyDefinitions $policyDefinitions
    if ($IncludeProfilePreferences) {
        Write-Step 'Profile preference patches:'
        $patchesToList = @($manifest.profilePreferencePatches)
        if ($customFeatureRequested) {
            $patchesToList = @($patchesToList | Where-Object {
                    $featureId = [string]$_.feature
                    [string]::IsNullOrWhiteSpace($featureId) -or ($selectedFeatureIds -contains $featureId)
                })
        }
        Show-ProfilePreferencePatchList -Patches $patchesToList
    }
    return
}

$registryPath = Get-RegistryBasePath -ScopeName $Scope

if ($onlyFeatureMode) {
    Write-Step 'Preset: (none - OnlyFeature mode)'
}
else {
    Write-Step "Preset: $Preset"
}
Write-Step "Scope: $Scope ($registryPath)"
if ($LockShields) {
    Write-Step 'Shield baseline: enabled. This enforces ad blocking, standard fingerprinting protection, HTTPS upgrade, and referrer capping.'
}
else {
    Write-Step 'Shield baseline: not locked. This tool will not disable or whitelist Brave Shields.'
}
if ($customFeatureRequested) {
    Write-Step "Custom features: $($selectedFeatureIds -join ', ')"
}

if (-not $applyChanges) {
    if ($isWhatIf) {
        Write-Step 'WhatIf mode. No registry, backup, or profile files will be changed.'
    }
    else {
        Write-Step 'Dry-run mode. No registry, backup, or profile files will be changed.'
    }
}

if ($IncludeProfilePreferences -and $applyChanges -and $NoBackup) {
    throw 'Profile preference cleanup requires backups. Remove -NoBackup or omit -IncludeProfilePreferences.'
}

$backupPath = $null
if ($applyChanges -and -not $NoBackup) {
    $backupPath = New-Backup -Directory $BackupDirectory -ScopeName $Scope -RegistryPath $registryPath -PolicyNames $policyNames.ToArray() -ProfileRoot $ProfileRoot -Manifest $manifest
    Write-Step "Backup written to $backupPath"
}

foreach ($policyName in $policyNames) {
    $definition = $policyDefinitions[$policyName]
    if (-not $applyChanges) {
        Write-DryRun "Would set $policyName = $($definition.value) ($($definition.reason))"
        continue
    }

    if ($PSCmdlet.ShouldProcess($registryPath, "Set $policyName to $($definition.value)")) {
        Set-BravePolicy -BasePath $registryPath -Name $policyName -Definition $definition
        Write-Step "Set $policyName."
    }
}

if ($IncludeProfilePreferences) {
    Invoke-ProfilePreferenceCleanup -Root $ProfileRoot -Manifest $manifest -BackupPath $backupPath -SelectedFeatureIds $selectedFeatureIds -UseFeatureFilter:$customFeatureRequested -DoApply:$applyChanges
}

if (-not $applyChanges) {
    if ($isWhatIf) {
        Write-Step 'WhatIf complete. Rerun with -Apply without -WhatIf to make changes.'
    }
    else {
        Write-Step 'Dry-run complete. Rerun with -Apply to make changes.'
    }
}
else {
    Write-Step 'Done. Restart Brave, then open brave://policy to verify the applied policies.'
}
