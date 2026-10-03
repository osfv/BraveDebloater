#requires -Version 5.1

function Get-JsonPathResult {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )

    # Blocked means a parent on the path exists but is not a JSON object (null, a scalar, or an array),
    # so the value cannot be created there without replacing that parent.
    $current = $Object
    foreach ($part in ($Path -split '\.')) {
        if ($current -isnot [System.Management.Automation.PSCustomObject]) {
            return [pscustomobject]@{ exists = $false; value = $null; blocked = $true }
        }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) {
            return [pscustomobject]@{ exists = $false; value = $null; blocked = $false }
        }
        $current = $property.Value
    }

    return [pscustomobject]@{ exists = $true; value = $current; blocked = $false }
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
        if ($current -isnot [System.Management.Automation.PSCustomObject]) {
            return $false
        }
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
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return $files.ToArray()
    }
    if (-not (Test-Path -LiteralPath $Root)) {
        return $files.ToArray()
    }

    Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $preferencesPath = Join-Path $_.FullName 'Preferences'
            if (Test-Path -LiteralPath $preferencesPath) {
                [void]$files.Add($preferencesPath)
            }
        }

    return $files.ToArray()
}

function Invoke-ProfilePreferenceCleanup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Root,
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$BackupPath,
        [string[]]$SelectedFeatureIds = @(),
        [switch]$UseFeatureFilter,
        [switch]$DoApply,
        [System.Collections.Generic.List[object]]$ReportRows
    )

    if ([string]::IsNullOrWhiteSpace($Root)) {
        Write-Warning 'No Brave profile root is known for this platform, so profile preference cleanup was skipped. Pass -ProfileRoot with the Brave "User Data" folder, or omit -IncludeProfilePreferences.'
        return
    }

    $files = @(Get-BraveProfilePreferenceFiles -Root $Root)
    if ($files.Count -eq 0) {
        Write-Warning "No Brave profile Preferences files were found under $Root. Profile preference cleanup was skipped. Check -ProfileRoot or -Channel if Brave is installed."
        return
    }

    if (Test-BraveRunning) {
        if ($DoApply) {
            Write-Warning 'Brave is running, so profile preference cleanup was skipped. Close Brave, then rerun with -IncludeProfilePreferences -Apply.'
            return
        }
        Write-Step 'Note: Brave is running. Close it before adding -Apply, or profile preference cleanup will be skipped.'
    }

    $profileBackups = New-Object System.Collections.Generic.List[object]
    $patches = @($Manifest.profilePreferencePatches)
    if ($UseFeatureFilter) {
        $patches = @($patches | Where-Object {
                $featureId = [string]$_.feature
                [string]::IsNullOrWhiteSpace($featureId) -or ($SelectedFeatureIds -contains $featureId)
            })
    }

    $datesMayChange = Test-JsonDatesMayChange

    foreach ($file in $files) {
        if (-not $DoApply) {
            Write-DryRun "Would inspect profile file $file."
        }

        $json = $null
        try {
            $raw = Get-Utf8FileContent -Path $file
            if ([string]::IsNullOrWhiteSpace($raw)) {
                throw 'The file is empty.'
            }
            $json = ConvertFrom-JsonText -Json $raw
        }
        catch {
            Write-Warning "Skipping invalid profile Preferences file: $file ($($_.Exception.Message)) No changes were made to this file."
            continue
        }

        if ($json -isnot [System.Management.Automation.PSCustomObject]) {
            Write-Warning "Skipping invalid profile Preferences file: $file (top-level value is not a JSON object). No changes were made to this file."
            continue
        }

        if ($datesMayChange -and (Test-JsonValueContainsDate -Value $json)) {
            Write-Warning "Skipping profile Preferences file: $file (it contains date values that PowerShell $($PSVersionTable.PSVersion) would rewrite). No changes were made to this file. Rerun with PowerShell 7.5 or newer, or Windows PowerShell 5.1."
            continue
        }

        $changed = $false
        $fileRows = New-Object System.Collections.Generic.List[object]
        $profileLabel = "Profile $(Split-Path -Leaf (Split-Path -Parent $file))"

        foreach ($patch in $patches) {
            $path = [string]$patch.path
            if ($path -match '(?i)shield') {
                throw "Refusing profile preference patch that mentions Shields: $path. Profile cleanup will not change Brave Shields settings."
            }

            $current = Get-JsonPathResult -Object $json -Path $path
            $createMissing = [bool]$patch.createMissing

            $beforeText = ''
            $newText = ''
            if ($null -ne $ReportRows) {
                $formatValue = { param($Value) if ($Value -is [bool]) { $Value.ToString().ToLowerInvariant() } else { Get-RunReportValueText -Value $Value } }
                $beforeText = if ($current.exists) { & $formatValue $current.value } else { 'Not set' }
                $newText = & $formatValue $patch.value
            }
            $newRow = { param($Before, $Status) [pscustomobject]@{ Kind = 'Profile'; Name = $path; Feature = $profileLabel; Reason = $file; Before = $Before; NewValue = $newText; Status = $Status } }
            if ($current.blocked) {
                Write-Warning "Skipping $path in $file because a parent value is not a JSON object. This setting was not changed."
                [void]$fileRows.Add((& $newRow 'Not an object' 'Skipped'))
                continue
            }
            if (-not $current.exists -and -not $createMissing) {
                continue
            }

            # Compare JSON scalars without PowerShell's boolean/string coercion.
            if ($current.exists -and (ConvertTo-Json -InputObject $current.value -Compress -Depth 100) -ceq (ConvertTo-Json -InputObject $patch.value -Compress -Depth 100)) {
                if (-not $DoApply) {
                    Write-DryRun "Already set: $path in $file. No change needed."
                }
                [void]$fileRows.Add((& $newRow $beforeText 'Already set'))
                continue
            }

            if (-not $DoApply) {
                if ($current.exists) {
                    Write-DryRun "Would set $path in $file from '$($current.value)' to '$($patch.value)'."
                }
                else {
                    Write-DryRun "Would create $path in $file with '$($patch.value)'."
                }
                [void]$fileRows.Add((& $newRow $beforeText 'Would set'))
                continue
            }

            if (Set-JsonPathValue -Object $json -Path $path -Value $patch.value -CreateMissing:$createMissing) {
                $changed = $true
                [void]$fileRows.Add((& $newRow $beforeText 'Pending'))
            }
        }
        $pendingStatus = 'Set'

        if ($DoApply -and $changed -and -not $PSCmdlet.ShouldProcess($file, 'Update Brave profile preferences')) {
            Write-Step "Skipped profile preferences in $file. No changes were made to this file."
            $pendingStatus = 'Skipped'
        }
        elseif ($DoApply -and $changed) {
            # Each backup gets its own folder under profile-files/ so a later apply run cannot
            # overwrite the original Preferences copy that an earlier backup still points to.
            $profileBackupDirectory = Get-ProfileBackupDirectory -BackupPath $BackupPath
            New-DirectoryLiteral -Path $profileBackupDirectory

            $safeName = ($file -replace '[:\\\/ ]', '_')
            $profileBackupPath = Join-Path $profileBackupDirectory "$safeName.bak"
            # Different profile folders can map to the same safe name (for example 'Profile 1' and
            # 'Profile_1'), so never let one profile's copy overwrite another's in the same backup.
            $copyNumber = 1
            while (@($profileBackups | Where-Object { $_.backupPath -ieq $profileBackupPath }).Count -gt 0) {
                $copyNumber++
                $profileBackupPath = Join-Path $profileBackupDirectory "$safeName-$copyNumber.bak"
            }
            Copy-FileLiteral -SourcePath $file -DestinationPath $profileBackupPath
            [void]$profileBackups.Add([pscustomobject]@{
                originalPath = $file
                backupPath = $profileBackupPath
            })

            # Persist recovery information before each write. A later profile failure must not
            # leave already modified profiles absent from the restore record.
            Update-BackupProfileFiles -BackupPath $BackupPath -ProfileFiles $profileBackups.ToArray()
            Set-JsonFileContent -Path $file -Object $json -Depth 100
            Write-Step "Updated profile preferences in $file."
        }
        elseif ($DoApply) {
            Write-Step "No profile preference changes needed in $file."
        }
        if ($null -ne $ReportRows) {
            foreach ($row in $fileRows) {
                if ($row.Status -eq 'Pending') {
                    $row.Status = $pendingStatus
                }
                [void]$ReportRows.Add($row)
            }
        }
    }
}
