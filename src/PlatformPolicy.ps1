#requires -Version 5.1

function Test-IsAdministrator {
    $isWindowsVariable = Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue
    if ($isWindowsVariable -and -not $IsWindows) {
        return ([System.Environment]::UserName -eq 'root')
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-PlatformName {
    param([string]$Name)

    if ($Name -ne 'Auto') {
        return $Name
    }
    if ((Get-Variable -Name IsMacOS -Scope Global -ErrorAction SilentlyContinue) -and $IsMacOS) {
        return 'macOS'
    }
    if ((Get-Variable -Name IsLinux -Scope Global -ErrorAction SilentlyContinue) -and $IsLinux) {
        return 'Linux'
    }
    return 'Windows'
}

function Get-DefaultProfileRoot {
    param(
        [string]$PlatformName,
        [ValidateSet('Stable', 'Beta', 'Nightly')]
        [string]$Channel = 'Stable'
    )

    $suffix = switch ($Channel) {
        'Beta' { '-Beta' }
        'Nightly' { '-Nightly' }
        default { '' }
    }
    $browserDirectory = "Brave-Browser$suffix"

    # A forced -Platform on another OS (for example exporting Windows policies from Linux) has no
    # matching base directory. Return '' so profile cleanup is skipped instead of failing on Join-Path.
    switch ($PlatformName) {
        'Windows' {
            if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return '' }
            return (Join-Path $env:LOCALAPPDATA "BraveSoftware\$browserDirectory\User Data")
        }
        'macOS' {
            if ([string]::IsNullOrWhiteSpace($HOME)) { return '' }
            return (Join-Path $HOME "Library/Application Support/BraveSoftware/$browserDirectory")
        }
        'Linux' {
            if ([string]::IsNullOrWhiteSpace($HOME)) { return '' }
            return (Join-Path $HOME ".config/BraveSoftware/$browserDirectory")
        }
        default { return '' }
    }
}

function Assert-UserSid {
    param([Parameter(Mandatory = $true)][string]$UserSid)

    if ($UserSid -cnotmatch '^S-1-(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*)){1,15}$') {
        throw "Invalid user SID '$UserSid'. Supply a Windows SID such as S-1-5-21-1000-1000-1000-1001."
    }

    $parts = $UserSid.Split('-')
    $identifierAuthority = [uint64]0
    if (-not [uint64]::TryParse($parts[2], [ref]$identifierAuthority) -or $identifierAuthority -gt 281474976710655) {
        throw "Invalid user SID '$UserSid'. The SID identifier authority is out of range."
    }

    for ($index = 3; $index -lt $parts.Count; $index++) {
        $subAuthority = [uint32]0
        if (-not [uint32]::TryParse($parts[$index], [ref]$subAuthority)) {
            throw "Invalid user SID '$UserSid'. SID sub-authorities must be 32-bit unsigned integers."
        }
    }
}

function Get-RegistryPolicyPath {
    param(
        [string]$ScopeName,
        [string]$UserSid
    )

    if (-not [string]::IsNullOrWhiteSpace($UserSid)) {
        Assert-UserSid -UserSid $UserSid
        return "Registry::HKEY_USERS\$UserSid\Software\Policies\BraveSoftware\Brave"
    }

    if ($ScopeName -eq 'LocalMachine') {
        return 'Registry::HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave'
    }

    return 'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave'
}

function Get-RegistryBasePath {
    param(
        [string]$ScopeName,
        [string]$UserSid,
        [switch]$Apply,
        [switch]$ReadOnly
    )

    if (-not [string]::IsNullOrWhiteSpace($UserSid)) {
        if ($ScopeName -ne 'CurrentUser') {
            throw '-UserSid cannot be combined with -Scope LocalMachine. A target user SID selects that user policy hive directly.'
        }
        if ($Apply -and -not $ReadOnly -and -not (Test-IsAdministrator)) {
            throw 'Applying policies for -UserSid needs an elevated PowerShell session. Reopen PowerShell as administrator, then rerun the command.'
        }
        if ($Apply -and -not $ReadOnly) {
            $userHivePath = "Registry::HKEY_USERS\$UserSid"
            if (-not (Test-Path -LiteralPath $userHivePath)) {
                throw "The registry hive for user SID '$UserSid' is not loaded. Sign in that user, then rerun the elevated command."
            }
        }
    }

    if ($ScopeName -eq 'LocalMachine' -and -not $ReadOnly) {
        if (-not (Test-IsAdministrator)) {
            throw 'LocalMachine scope needs an elevated PowerShell session. Use -Scope CurrentUser, or reopen PowerShell as administrator/root and run the command again.'
        }
    }

    return (Get-RegistryPolicyPath -ScopeName $ScopeName -UserSid $UserSid)
}

function Get-PolicyTarget {
    param(
        [string]$PlatformName,
        [string]$ScopeName,
        [string]$OverridePath,
        [string]$UserSid,
        [switch]$Apply,
        [switch]$ReadOnly
    )

    switch ($PlatformName) {
        'Windows' {
            return [pscustomobject]@{ Platform = $PlatformName; Kind = 'Registry'; Path = (Get-RegistryBasePath -ScopeName $ScopeName -UserSid $UserSid -Apply:$Apply -ReadOnly:$ReadOnly) }
        }
        'Linux' {
            $path = if ([string]::IsNullOrWhiteSpace($OverridePath)) { '/etc/brave/policies/managed/BraveDebloater.json' } else { $OverridePath }
            if ($Apply -and -not $ReadOnly -and [string]::IsNullOrWhiteSpace($OverridePath) -and -not (Test-IsAdministrator)) {
                throw "Linux managed policies are written to '$path' and need root. Rerun the command with sudo, or use -PolicyPath to write a test file somewhere you can access."
            }
            return [pscustomobject]@{ Platform = $PlatformName; Kind = 'JsonFile'; Path = $path }
        }
        'macOS' {
            if ($ScopeName -eq 'LocalMachine') {
                $path = if ([string]::IsNullOrWhiteSpace($OverridePath)) { '/Library/Managed Preferences/com.brave.Browser.plist' } else { $OverridePath }
                if (-not $ReadOnly -and [string]::IsNullOrWhiteSpace($OverridePath) -and -not (Test-IsAdministrator)) {
                    throw "macOS LocalMachine scope writes to '$path' and needs root. Use -Scope CurrentUser, or rerun the command with sudo."
                }
                return [pscustomobject]@{ Platform = $PlatformName; Kind = 'MacOSPlist'; Path = $path }
            }
            return [pscustomobject]@{ Platform = $PlatformName; Kind = 'MacOSDefaults'; Path = 'com.brave.Browser' }
        }
        default {
            return [pscustomobject]@{ Platform = $PlatformName; Kind = 'MobileMDM'; Path = 'MDM profile' }
        }
    }
}

function Get-ManagedPolicyJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    # An empty managed policy file is treated as "no policies" instead of a parse failure so the
    # first apply on a machine with a placeholder file still succeeds.
    $raw = Get-Utf8FileContent -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{}
    }

    $json = $raw | ConvertFrom-Json
    if ($json -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Managed policy file $Path does not contain a JSON object. Fix or remove the file, then rerun the command."
    }

    return $json
}

function Get-PolicyTargetElevationHint {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [string]$ScopeName,
        [string]$UserSid,
        [string]$OverridePath
    )

    # Called for previews only. Says up front whether the matching -Apply run will need elevation,
    # so users are not surprised after reviewing a dry-run in an unelevated session.
    if (Test-IsAdministrator) {
        return ''
    }

    switch ($Target.Kind) {
        'Registry' {
            if (-not [string]::IsNullOrWhiteSpace($UserSid)) {
                return 'Applying for -UserSid needs an elevated PowerShell session. Reopen PowerShell as administrator before adding -Apply.'
            }
            if ($ScopeName -eq 'LocalMachine') {
                return 'Applying LocalMachine scope needs an elevated PowerShell session. Reopen PowerShell as administrator before adding -Apply.'
            }
        }
        'JsonFile' {
            if ([string]::IsNullOrWhiteSpace($OverridePath)) {
                return "Applying to $($Target.Path) needs root. Rerun with sudo before adding -Apply."
            }
        }
        'MacOSPlist' {
            if ([string]::IsNullOrWhiteSpace($OverridePath)) {
                return "Applying to $($Target.Path) needs root. Rerun with sudo before adding -Apply."
            }
        }
    }

    return ''
}

function Get-PolicyValue {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Target.Kind -eq 'Registry') {
        if (Test-Path -LiteralPath $Target.Path) {
            try {
                $key = Get-Item -LiteralPath $Target.Path
                $value = $key.GetValue($Name, $null)
                if ($null -ne $value) {
                    return [pscustomobject]@{ Exists = $true; Value = $value; Kind = $key.GetValueKind($Name).ToString(); ReadError = $false }
                }
            }
            catch {
                # The value could not be read (e.g. access denied). We cannot tell whether it was
                # absent or merely unreadable, so flag it as a read error. The snapshot records this so
                # a later restore skips the value instead of deleting one that may actually be present.
                Write-Warning "Could not read registry value '$Name' under '$($Target.Path)', so it was excluded from the backup: $($_.Exception.Message)"
                return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null; ReadError = $true }
            }
        }
        return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null; ReadError = $false }
    }

    if ($Target.Kind -eq 'JsonFile') {
        if (Test-Path -LiteralPath $Target.Path) {
            $json = Get-ManagedPolicyJson -Path $Target.Path
            $property = $json.PSObject.Properties[$Name]
            if ($null -ne $property) {
                return [pscustomobject]@{ Exists = $true; Value = $property.Value; Kind = 'DWord'; ReadError = $false }
            }
        }
        return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null; ReadError = $false }
    }

    if ($Target.Kind -eq 'MacOSDefaults' -or $Target.Kind -eq 'MacOSPlist') {
        $arguments = if ($Target.Kind -eq 'MacOSDefaults') { @('read', $Target.Path, $Name) } else { @('read', ($Target.Path -replace '\.plist$', ''), $Name) }
        $output = & /usr/bin/defaults @arguments 2>$null
        $readSucceeded = $LASTEXITCODE -eq 0
        # `defaults read` exits non-zero when the key is absent (the common case during a scan).
        # Clear LASTEXITCODE so a missing key does not leak a failure exit code to the script.
        $global:LASTEXITCODE = 0
        if ($readSucceeded) {
            $text = $output -join "`n"
            $number = 0
            $value = if ([int]::TryParse($text, [ref]$number)) { $number } else { $text }
            $kind = if ($value -is [int]) { 'DWord' } else { 'String' }
            return [pscustomobject]@{ Exists = $true; Value = $value; Kind = $kind; ReadError = $false }
        }
    }

    return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null; ReadError = $false }
}

function Get-PolicySnapshot {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [string[]]$PolicyNames
    )

    $snapshot = New-Object System.Collections.Generic.List[object]
    foreach ($policyName in $PolicyNames) {
        $value = Get-PolicyValue -Target $Target -Name $policyName
        [void]$snapshot.Add([pscustomobject]@{
                name = $policyName
                existed = [bool]$value.Exists
                value = $value.Value
                kind = $value.Kind
                readError = [bool]$value.ReadError
            })
    }
    return $snapshot.ToArray()
}

function Set-PolicyValue {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [string]$Name,
        [Parameter(Mandatory = $true)]$Definition
    )

    if ($Target.Kind -eq 'Registry') {
        Set-BravePolicy -BasePath $Target.Path -Name $Name -Definition $Definition
        return
    }

    $value = ConvertTo-ManagedPolicyValue -Definition $Definition
    if ($Target.Kind -eq 'JsonFile') {
        $json = [pscustomobject]@{}
        if (Test-Path -LiteralPath $Target.Path) {
            $json = Get-ManagedPolicyJson -Path $Target.Path
        }
        if ($null -eq $json.PSObject.Properties[$Name]) {
            $json | Add-Member -NotePropertyName $Name -NotePropertyValue $value
        }
        else {
            $json.PSObject.Properties[$Name].Value = $value
        }
        Set-JsonFileContent -Path $Target.Path -Object $json
        return
    }

    if ($Target.Kind -eq 'MacOSDefaults' -or $Target.Kind -eq 'MacOSPlist') {
        $domain = if ($Target.Kind -eq 'MacOSDefaults') { $Target.Path } else { $Target.Path -replace '\.plist$', '' }
        $typeFlag = if ($value -is [bool]) { '-bool' } elseif ($value -is [int]) { '-int' } else { '-string' }
        if ($Target.Kind -eq 'MacOSPlist') {
            $directory = Split-Path -Parent $Target.Path
            if (-not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
        }
        & /usr/bin/defaults write $domain $Name $typeFlag $value
        if ($LASTEXITCODE -ne 0) {
            throw "Could not write macOS policy '$Name' to $($Target.Path). Check file permissions, then rerun with -Apply."
        }
        return
    }

    throw "$($Target.Platform) policies are managed by MDM and cannot be written locally by this script. Use -ExportPolicyPath to create a payload for your device manager."
}

function Remove-PolicyValue {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [string]$Name
    )

    if ($Target.Kind -eq 'Registry') {
        if (Test-Path -LiteralPath $Target.Path) {
            Remove-ItemProperty -LiteralPath $Target.Path -Name $Name -ErrorAction SilentlyContinue
        }
        return
    }
    if ($Target.Kind -eq 'JsonFile') {
        if (Test-Path -LiteralPath $Target.Path) {
            $json = Get-ManagedPolicyJson -Path $Target.Path
            $json.PSObject.Properties.Remove($Name)
            Set-JsonFileContent -Path $Target.Path -Object $json
        }
        return
    }
    if ($Target.Kind -eq 'MacOSDefaults' -or $Target.Kind -eq 'MacOSPlist') {
        $domain = if ($Target.Kind -eq 'MacOSDefaults') { $Target.Path } else { $Target.Path -replace '\.plist$', '' }
        & /usr/bin/defaults delete $domain $Name 2>$null
        # Deleting an absent key exits non-zero; clear it so the exit code is not leaked.
        $global:LASTEXITCODE = 0
    }
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

function Get-PolicyReport {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [string]$ScopeName,
        [string[]]$PolicyNames = @()
    )

    if ($Target.Kind -eq 'Registry') {
        return Get-RegistryPolicyReport -ScopeName $ScopeName
    }

    $entries = New-Object System.Collections.Generic.List[object]
    $keyExists = Test-Path -LiteralPath $Target.Path
    $canRead = $true
    $errorMessage = ''

    try {
        if ($Target.Kind -eq 'JsonFile' -and $keyExists) {
            $json = Get-ManagedPolicyJson -Path $Target.Path
            foreach ($property in $json.PSObject.Properties) {
                [void]$entries.Add([pscustomobject]@{ Name = $property.Name; Value = $property.Value; Kind = 'DWord' })
            }
        }
        elseif ($Target.Kind -eq 'MacOSDefaults' -or $Target.Kind -eq 'MacOSPlist') {
            foreach ($policyName in $PolicyNames) {
                $value = Get-PolicyValue -Target $Target -Name $policyName
                if ($value.Exists) {
                    $keyExists = $true
                    [void]$entries.Add([pscustomobject]@{ Name = $policyName; Value = $value.Value; Kind = $value.Kind })
                }
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
        Path = $Target.Path
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
        return $false
    }

    return $false
}

function ConvertTo-ManagedPolicyValue {
    param([Parameter(Mandatory = $true)]$Definition)

    if ($Definition.type -eq 'DWord') {
        $number = [int]$Definition.value
        if ($number -eq 0 -or $number -eq 1) {
            return [bool]$number
        }
        return $number
    }

    return [string]$Definition.value
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

function Get-PolicyPayload {
    param(
        [string[]]$PolicyNames,
        [hashtable]$PolicyDefinitions
    )

    $payload = [ordered]@{}
    foreach ($policyName in $PolicyNames) {
        $definition = $PolicyDefinitions[$policyName]
        $payload[$policyName] = ConvertTo-ManagedPolicyValue -Definition $definition
    }
    return $payload
}

function ConvertTo-PlistScalar {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [bool]) {
        if ($Value) { return '<true/>' }
        return '<false/>'
    }
    if ($Value -is [int] -or $Value -is [long]) {
        return "<integer>$Value</integer>"
    }

    $escaped = [System.Security.SecurityElement]::Escape([string]$Value)
    return "<string>$escaped</string>"
}

function ConvertTo-PlistDocument {
    param(
        [Parameter(Mandatory = $true)]$Payload,
        [string]$Domain = 'com.brave.Browser',
        [switch]$MobileConfig
    )

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$lines.Add('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">')
    [void]$lines.Add('<plist version="1.0">')

    if ($MobileConfig) {
        $uuid = [guid]::NewGuid().ToString().ToUpperInvariant()
        $payloadUuid = [guid]::NewGuid().ToString().ToUpperInvariant()
        [void]$lines.Add('<dict>')
        [void]$lines.Add('  <key>PayloadContent</key>')
        [void]$lines.Add('  <array>')
        [void]$lines.Add('    <dict>')
        [void]$lines.Add('      <key>PayloadContent</key>')
        [void]$lines.Add('      <dict>')
        [void]$lines.Add("        <key>$Domain</key>")
        [void]$lines.Add('        <dict>')
        [void]$lines.Add('          <key>Forced</key>')
        [void]$lines.Add('          <array>')
        [void]$lines.Add('            <dict>')
        [void]$lines.Add('              <key>mcx_preference_settings</key>')
        [void]$lines.Add('              <dict>')
        foreach ($entry in $Payload.GetEnumerator()) {
            [void]$lines.Add("                <key>$($entry.Key)</key>")
            [void]$lines.Add("                $(ConvertTo-PlistScalar -Value $entry.Value)")
        }
        [void]$lines.Add('              </dict>')
        [void]$lines.Add('            </dict>')
        [void]$lines.Add('          </array>')
        [void]$lines.Add('        </dict>')
        [void]$lines.Add('      </dict>')
        [void]$lines.Add('      <key>PayloadIdentifier</key>')
        [void]$lines.Add('      <string>org.bravedebloater.brave.managed</string>')
        [void]$lines.Add('      <key>PayloadType</key>')
        [void]$lines.Add('      <string>com.apple.ManagedClient.preferences</string>')
        [void]$lines.Add('      <key>PayloadUUID</key>')
        [void]$lines.Add("      <string>$payloadUuid</string>")
        [void]$lines.Add('      <key>PayloadVersion</key>')
        [void]$lines.Add('      <integer>1</integer>')
        [void]$lines.Add('    </dict>')
        [void]$lines.Add('  </array>')
        [void]$lines.Add('  <key>PayloadDisplayName</key>')
        [void]$lines.Add('  <string>BraveDebloater Brave policies</string>')
        [void]$lines.Add('  <key>PayloadIdentifier</key>')
        [void]$lines.Add('  <string>org.bravedebloater.brave</string>')
        [void]$lines.Add('  <key>PayloadType</key>')
        [void]$lines.Add('  <string>Configuration</string>')
        [void]$lines.Add('  <key>PayloadUUID</key>')
        [void]$lines.Add("  <string>$uuid</string>")
        [void]$lines.Add('  <key>PayloadVersion</key>')
        [void]$lines.Add('  <integer>1</integer>')
        [void]$lines.Add('</dict>')
    }
    else {
        [void]$lines.Add('<dict>')
        foreach ($entry in $Payload.GetEnumerator()) {
            [void]$lines.Add("  <key>$($entry.Key)</key>")
            [void]$lines.Add("  $(ConvertTo-PlistScalar -Value $entry.Value)")
        }
        [void]$lines.Add('</dict>')
    }

    [void]$lines.Add('</plist>')
    return ($lines.ToArray() -join "`n")
}

function ConvertTo-RegFileDocument {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)]$Payload
    )

    $keyPath = $RegistryPath -replace '^Registry::', ''
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('Windows Registry Editor Version 5.00')
    [void]$lines.Add('')
    [void]$lines.Add("[$keyPath]")

    foreach ($entry in $Payload.GetEnumerator()) {
        $value = $entry.Value
        if ($value -is [bool]) {
            $value = if ($value) { 1 } else { 0 }
        }

        if ($value -is [int] -or $value -is [long]) {
            [void]$lines.Add(('"{0}"=dword:{1:x8}' -f $entry.Key, [uint32]$value))
        }
        else {
            $escaped = ([string]$value) -replace '\\', '\\\\' -replace '"', '\"'
            [void]$lines.Add(('"{0}"="{1}"' -f $entry.Key, $escaped))
        }
    }

    [void]$lines.Add('')
    # regedit expects "Version 5.00" files to be UTF-16LE with CRLF line endings.
    return (($lines.ToArray() -join "`r`n") + "`r`n")
}

function Get-PolicyExportFormat {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -eq '.reg') {
        if ($Target.Kind -ne 'Registry') {
            throw "A .reg export needs a Windows registry target. Add -Platform Windows, or export a .json, .plist, or .mobileconfig file for $($Target.Platform)."
        }
        return 'Reg'
    }
    if ($extension -eq '.json' -or $Target.Platform -eq 'Linux' -or $Target.Platform -eq 'Android') {
        return 'Json'
    }
    if ($extension -eq '.mobileconfig' -or $Target.Platform -eq 'iOS') {
        return 'MobileConfig'
    }
    if ($extension -eq '.plist' -or $Target.Platform -eq 'macOS') {
        return 'Plist'
    }
    if ($Target.Kind -eq 'Registry') {
        return 'Reg'
    }

    return 'Plist'
}

function Export-PolicyPayload {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)]$Payload,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $format = Get-PolicyExportFormat -Target $Target -Path $Path
    switch ($format) {
        'Json' {
            Set-JsonFileContent -Path $Path -Object $Payload
        }
        'Reg' {
            $document = ConvertTo-RegFileDocument -RegistryPath $Target.Path -Payload $Payload
            Set-TextFileContent -Path $Path -Content $document -Encoding ([System.Text.Encoding]::Unicode)
        }
        'MobileConfig' {
            Set-TextFileContent -Path $Path -Content (ConvertTo-PlistDocument -Payload $Payload -MobileConfig)
        }
        default {
            Set-TextFileContent -Path $Path -Content (ConvertTo-PlistDocument -Payload $Payload)
        }
    }

    return $format
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
