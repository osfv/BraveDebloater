#requires -Version 5.1

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
        Write-Warning "No Brave profile Preferences files were found under $Root. Profile preference cleanup was skipped."
        return
    }

    if ($DoApply -and (Test-BraveRunning)) {
        Write-Warning 'Brave is running, so profile preference cleanup was skipped. Close Brave, then rerun with -IncludeProfilePreferences -Apply.'
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
            $raw = Get-Utf8FileContent -Path $file
            if ([string]::IsNullOrWhiteSpace($raw)) {
                throw 'The file is empty.'
            }
            $json = $raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "Skipping invalid profile Preferences file: $file ($($_.Exception.Message)) No changes were made to this file."
            continue
        }

        if ($json -isnot [System.Management.Automation.PSCustomObject]) {
            Write-Warning "Skipping invalid profile Preferences file: $file (top-level value is not a JSON object). No changes were made to this file."
            continue
        }

        $changed = $false

        foreach ($patch in $patches) {
            $path = [string]$patch.path
            if ($path -match '(?i)shield') {
                throw "Refusing profile preference patch that mentions Shields: $path. Profile cleanup will not change Brave Shields settings."
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
