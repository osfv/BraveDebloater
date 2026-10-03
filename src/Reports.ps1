#requires -Version 5.1

function Show-PolicyList {
    param(
        [string[]]$PolicyNames,
        [hashtable]$PolicyDefinitions,
        [string[]]$RemoveNames = @()
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
    foreach ($name in $RemoveNames) {
        Write-Step "Remove if present: $name. Brave settings control this value again."
    }
    Write-Step "Policy plan: $(@($PolicyNames).Count) to set, $(@($RemoveNames).Count) to remove if present."
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

function Show-VersionInfo {
    param(
        [Parameter(Mandatory = $true)][string]$ToolVersion,
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$PlatformName
    )

    $edition = if ($PSVersionTable.ContainsKey('PSEdition')) { [string]$PSVersionTable['PSEdition'] } else { 'Desktop' }
    Write-Host "BraveDebloater $ToolVersion"
    Write-Host "Policy template version: $($Manifest.policyTemplateVersion) (manifest schema $($Manifest.schemaVersion))"
    Write-Host "PowerShell: $($PSVersionTable.PSVersion) ($edition) on $PlatformName"
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
    # -PolicyPath only affects file targets (Linux JSON, macOS machine plist). Passing it to both
    # scopes keeps Linux on a single report for the selected file instead of also scanning the default path.
    $currentUserTarget = Get-PolicyTarget -PlatformName $PlatformName -ScopeName 'CurrentUser' -OverridePath $PolicyPath -ReadOnly
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
    if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
        Write-Step 'Profile root: unknown for this platform. Pass -ProfileRoot with the Brave "User Data" folder to check profile files.'
    }
    elseif (Test-Path -LiteralPath $ProfileRoot) {
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

    $deprecatedPolicyNames = @(Get-DeprecatedPolicyNames -Manifest $Manifest)
    $obsoleteRows = New-Object System.Collections.Generic.List[object]
    $unknownRows = New-Object System.Collections.Generic.List[object]
    foreach ($report in $reports) {
        foreach ($entry in @($report.Entries)) {
            $entryName = [string]$entry.Name
            $row = [pscustomobject]@{
                Scope = $report.Scope
                Policy = $entryName
                Value = $entry.Value
                Kind = [string]$entry.Kind
            }
            if ($deprecatedPolicyNames -contains $entryName) {
                [void]$obsoleteRows.Add($row)
            }
            elseif (-not $PolicyDefinitions.ContainsKey($entryName)) {
                [void]$unknownRows.Add($row)
            }
        }
    }

    if ($obsoleteRows.Count -gt 0) {
        Write-Step 'Obsolete leftover policies: detected. Rerun with -Apply to remove them.'
        $obsoleteRows.ToArray() | Format-Table -AutoSize -Wrap
    }

    if ($unknownRows.Count -gt 0) {
        Write-Step 'Unknown Brave policies: detected. These may have been set by Brave, another tool, or an organization.'
        $unknownRows.ToArray() | Format-Table -AutoSize -Wrap
    }
    else {
        Write-Step 'Unknown Brave policies: none detected.'
    }
}

function Assert-RunReportPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $extension = [System.IO.Path]::GetExtension($Path)
    if (@('.html', '.htm') -notcontains $extension.ToLowerInvariant()) {
        throw "-ReportPath must end in .html or .htm, for example -ReportPath .\brave-report.html. No changes were made."
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        throw "-ReportPath '$Path' is a folder. Pass a file name such as brave-report.html. No changes were made."
    }
}

function Get-RunReportValueText {
    param($Value)

    if ($null -eq $Value) {
        return ''
    }
    if ($Value -is [bool]) {
        if ($Value) { return '1' } else { return '0' }
    }
    if ($Value -is [System.Array]) {
        return (@($Value | ForEach-Object { [string]$_ }) -join ', ')
    }
    return [string]$Value
}

function Get-RunReportCurrentText {
    param(
        [hashtable]$CurrentValues,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $CurrentValues -or -not $CurrentValues.ContainsKey($Name)) {
        return 'Unknown'
    }
    $current = $CurrentValues[$Name]
    if (-not $current.Exists) {
        return 'Not set'
    }
    return (Get-RunReportValueText -Value $current.Value)
}

function Get-RunReportLogoDataUri {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $logoPath = Join-Path (Join-Path (Join-Path $ProjectRoot 'assets') 'icons') 'debloater.png'
    if (-not [System.IO.File]::Exists($logoPath)) {
        return $null
    }
    return 'data:image/png;base64,' + [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($logoPath))
}

function ConvertTo-RunReportHtml {
    param(
        [Parameter(Mandatory = $true)]$Report
    )

    $e = { param($Text) [System.Net.WebUtility]::HtmlEncode([string]$Text) }
    $rows = @($Report.Rows)
    $changes = @($rows | Where-Object { $_.Status -in @('Would set', 'Set', 'Would remove', 'Removed') })
    $already = @($rows | Where-Object { $_.Status -eq 'Already set' })
    $skipped = @($rows | Where-Object { $_.Status -eq 'Skipped' })
    $applied = $Report.Mode -eq 'Apply'

    $modeLabel = switch ($Report.Mode) { 'Apply' { 'Applied' } 'WhatIf' { 'WhatIf preview' } default { 'Dry run' } }
    $verb = if (-not $applied) { 'would be made' } elseif ($changes.Count -eq 1) { 'was made' } else { 'were made' }
    $lead = "$($changes.Count) change$(if ($changes.Count -ne 1) { 's' }) $verb."
    if ($already.Count -gt 0) {
        $lead += " $($already.Count) already set."
    }
    if (-not $applied) {
        $lead += ' Nothing was changed.'
    }

    $renderItem = {
        param($Row)
        $label = if ([string]::IsNullOrWhiteSpace($Row.Feature)) { $Row.Name } else { $Row.Feature }
        $label = $label.Substring(0, 1).ToUpperInvariant() + $label.Substring(1)
        $value = if ($Row.Kind -eq 'Policy') { "$(& $e $Row.Before) &rarr; $(& $e $Row.NewValue)" } else { 'removed' }
        "<li><div><b>$(& $e $label)</b><code>$(& $e $Row.Name)</code></div><span>$value</span></li>"
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<title>BraveDebloater report</title>
<style>
body{margin:0;background:#fafafa;color:#1d1d1f;font:15px/1.5 -apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
main{max-width:720px;margin:0 auto;padding:48px 24px}
header{display:flex;align-items:center;gap:14px}
header img{width:52px;height:52px}
h1{font-size:22px;margin:0}
header p{margin:0;color:#6e6e73;font-size:13px}
.lead{font-size:17px;margin:28px 0 16px}
h2{font-size:15px;margin:32px 0 8px}
ul{list-style:none;margin:0;padding:0;background:#fff;border:1px solid #e5e5ea;border-radius:12px}
li{display:flex;justify-content:space-between;align-items:center;gap:16px;padding:10px 16px;border-top:1px solid #f0f0f3}
li:first-child{border-top:0}
li b{display:block;font-weight:500}
li code{color:#86868b;font-size:12px}
li span{color:#fb542b;font-family:Consolas,Menlo,monospace;font-size:13px;white-space:nowrap}
details{margin-top:12px;color:#6e6e73}
details ul{margin-top:8px}
details li span{color:#6e6e73}
summary{cursor:pointer}
.undo{display:flex;gap:10px;align-items:center;background:#fff;border:1px solid #e5e5ea;border-radius:12px;padding:12px 16px}
.undo code{flex:1;font-size:13px;word-break:break-all}
button{border:0;background:#fb542b;color:#fff;border-radius:8px;padding:6px 14px;font:inherit;font-size:13px;cursor:pointer}
.muted{color:#6e6e73}
footer{margin-top:40px;color:#86868b;font-size:12px}
</style>
</head>
<body>
<main>
'@)
    $logo = if ($Report.LogoDataUri) { "<img src=""$($Report.LogoDataUri)"" alt="""">" } else { '' }
    [void]$sb.Append("<header>$logo<div><h1>BraveDebloater</h1><p>$(& $e $modeLabel) &middot; $(& $e $Report.GeneratedAt)</p></div></header>")
    [void]$sb.Append("<p class=""lead"">$(& $e $lead)</p>")

    if ($changes.Count -gt 0) {
        [void]$sb.Append('<ul>')
        foreach ($row in $changes) { [void]$sb.Append((& $renderItem $row)) }
        [void]$sb.Append('</ul>')
    }
    foreach ($group in @(@{ Title = 'already set'; Items = $already }, @{ Title = 'skipped'; Items = $skipped })) {
        if (@($group.Items).Count -gt 0) {
            [void]$sb.Append("<details><summary>$(@($group.Items).Count) $($group.Title)</summary><ul>")
            foreach ($row in @($group.Items)) { [void]$sb.Append((& $renderItem $row)) }
            [void]$sb.Append('</ul></details>')
        }
    }

    [void]$sb.Append('<h2>Undo</h2>')
    if (-not [string]::IsNullOrWhiteSpace($Report.UndoCommand)) {
        [void]$sb.Append("<div class=""undo""><code id=""undo"">$(& $e $Report.UndoCommand)</code><button type=""button"" id=""copy"">Copy</button></div>")
        [void]$sb.Append('<p class="muted">Run it from the BraveDebloater folder, then restart Brave.</p>')
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Report.UndoText)) {
        [void]$sb.Append("<p class=""muted"">$(& $e $Report.UndoText)</p>")
    }
    elseif ($applied) {
        [void]$sb.Append('<p class="muted">No backup was written (-NoBackup), so there is no undo command.</p>')
    }
    else {
        [void]$sb.Append('<p class="muted">Nothing to undo. Run with -Apply and the report will include the undo command.</p>')
    }

    $footer = @($Report.Details.GetEnumerator() | ForEach-Object { "$(& $e $_.Key): $(& $e $_.Value)" }) -join ' &middot; '
    [void]$sb.Append("<footer>$footer<br>BraveDebloater $(& $e $Report.ToolVersion)</footer>")
    [void]$sb.Append(@'
</main>
<script>
var b=document.getElementById('copy');
if(b){b.onclick=function(){var c=document.getElementById('undo');function done(){b.textContent='Copied';}
function fallback(){var r=document.createRange();r.selectNodeContents(c);var s=getSelection();s.removeAllRanges();s.addRange(r);try{if(document.execCommand('copy')){done();}}catch(x){}}
if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(c.textContent).then(done,fallback);}else{fallback();}};}
</script>
</body>
</html>
'@)
    return $sb.ToString()
}

function Open-RunReport {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($env:CI -or -not [Environment]::UserInteractive) {
        return $false
    }
    $fullPath = Get-FullFileSystemPath -Path $Path
    try {
        if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
            Invoke-Item -LiteralPath $fullPath
        }
        elseif (Test-Path -LiteralPath '/usr/bin/open') {
            & /usr/bin/open $fullPath
        }
        elseif (($env:DISPLAY -or $env:WAYLAND_DISPLAY) -and (Get-Command xdg-open -ErrorAction SilentlyContinue)) {
            Start-Process -FilePath 'xdg-open' -ArgumentList @($fullPath) | Out-Null
        }
        else {
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}
