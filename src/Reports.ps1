#requires -Version 5.1

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
        [string]$BackupDirectory,
        [string]$PlatformName,
        [string]$PolicyPath
    )

    Write-Step 'Doctor report (read-only). No policy, backup, or profile files will be changed.'
    Write-Step 'Use this report to see what Brave already has, then decide whether to run a preview or apply command.'

    $knownPolicyNames = @($PolicyDefinitions.Keys)
    $currentUserTarget = Get-PolicyTarget -PlatformName $PlatformName -ScopeName 'CurrentUser' -OverridePath '' -ReadOnly
    $localMachineTarget = Get-PolicyTarget -PlatformName $PlatformName -ScopeName 'LocalMachine' -OverridePath $PolicyPath -ReadOnly
    $currentUserReport = Get-PolicyReport -Target $currentUserTarget -ScopeName 'CurrentUser' -PolicyNames $knownPolicyNames
    $localMachineReport = Get-PolicyReport -Target $localMachineTarget -ScopeName 'LocalMachine' -PolicyNames $knownPolicyNames
    $reports = @($currentUserReport, $localMachineReport)
    if ($currentUserTarget.Kind -ne 'Registry' -and $currentUserTarget.Path -eq $localMachineTarget.Path) {
        # Platforms like Linux expose a single machine-wide managed policy file, so both
        # scopes resolve to the same path. List it once to avoid double-counting entries.
        $reports = @($localMachineReport)
    }
    $unreadableScopes = New-Object System.Collections.Generic.List[string]

    foreach ($report in $reports) {
        if (-not $report.CanRead) {
            [void]$unreadableScopes.Add([string]$report.Scope)
            Write-Step "$($report.Scope) policies: could not be read ($($report.ErrorMessage))"
            continue
        }

        if ($report.Entries.Count -gt 0) {
            Write-Step "$($report.Scope) policies: found $($report.Entries.Count) value(s)."
        }
        elseif ($report.KeyExists) {
            Write-Step "$($report.Scope) policies: the policy location exists, but it has no values."
        }
        else {
            Write-Step "$($report.Scope) policies: none detected."
        }
    }

    if (-not $localMachineReport.CanRead) {
        Write-Step 'Machine-wide policies: unknown because LocalMachine policies could not be read.'
    }
    elseif ($localMachineReport.Entries.Count -gt 0) {
        Write-Step 'Machine-wide policies: detected. Brave may show managed settings for every user on this device.'
    }
    else {
        Write-Step 'Machine-wide policies: none detected.'
    }

    $allPolicyNames = @($reports | ForEach-Object { @($_.Entries) } | ForEach-Object { [string]$_.Name })
    $safetyFindings = @(Get-PolicySafetyFinding -PolicyNames $allPolicyNames -Manifest $Manifest)
    if ($unreadableScopes.Count -gt 0) {
        Write-Warning "Safety check incomplete: $($unreadableScopes.ToArray() -join ', ') policies could not be read."
    }

    if ($safetyFindings.Count -eq 0 -and $unreadableScopes.Count -eq 0) {
        Write-Step 'Safety: no protected Brave policy names were detected.'
    }
    elseif ($safetyFindings.Count -gt 0) {
        foreach ($finding in $safetyFindings) {
            Write-Warning "Safety issue: $finding"
        }
    }

    $braveProcesses = @(Get-BraveProcess)
    if ($braveProcesses.Count -gt 0) {
        Write-Step "Brave process: running ($($braveProcesses.Count) process(es)). Profile preference cleanup would be skipped until Brave is closed."
    }
    else {
        Write-Step 'Brave process: not running.'
    }

    $profileFiles = @(Get-BraveProfilePreferenceFiles -Root $ProfileRoot)
    if (-not [string]::IsNullOrWhiteSpace($ProfileRoot) -and (Test-Path -LiteralPath $ProfileRoot)) {
        Write-Step "Profile root: found $($profileFiles.Count) Preferences file(s) under $ProfileRoot"
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
