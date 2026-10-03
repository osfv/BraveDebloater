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

    switch ($Report.Mode) {
        'Apply' { $modeLabel = 'Applied'; $modeClass = 'applied'; $headline = 'These changes were made.' }
        'WhatIf' { $modeLabel = 'WhatIf'; $modeClass = 'preview'; $headline = 'Preview only. Nothing was changed.' }
        default { $modeLabel = 'Dry run'; $modeClass = 'preview'; $headline = 'Preview only. Nothing was changed. Add -Apply to make these changes.' }
    }

    $rows = @($Report.Rows)
    $changeCount = @($rows | Where-Object { $_.Status -in @('Would set', 'Set', 'Would remove', 'Removed') }).Count
    $alreadyCount = @($rows | Where-Object { $_.Status -eq 'Already set' }).Count
    $skippedCount = @($rows | Where-Object { $_.Status -eq 'Skipped' }).Count
    $removeCount = @($rows | Where-Object { $_.Status -in @('Would remove', 'Removed') }).Count

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
:root{--bg:#0f1115;--panel:#171a21;--line:#262b36;--text:#e8eaf0;--muted:#9aa3b2;--accent:#fb542b;--ok:#3ecf8e;--warn:#f5a623;--rm:#ff6b81}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:32px 24px 48px}
header{display:flex;align-items:center;gap:18px;margin-bottom:8px}
header img{width:64px;height:64px;border-radius:14px}
h1{font-size:24px;margin:0}
h2{font-size:16px;margin:32px 0 12px}
.sub{color:var(--muted);margin:2px 0 0}
.badge{display:inline-block;padding:2px 10px;border-radius:999px;font-size:12px;font-weight:600;letter-spacing:.02em;vertical-align:middle;margin-left:8px}
.badge.preview{background:rgba(245,166,35,.15);color:var(--warn)}
.badge.applied{background:rgba(62,207,142,.15);color:var(--ok)}
.headline{margin:20px 0;padding:14px 16px;border-left:3px solid var(--accent);background:var(--panel);border-radius:8px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px}
.card b{display:block;font-size:26px}
.card span{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--muted);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.04em;background:#1b1f27}
tr:last-child td{border-bottom:0}
.meta td:first-child{color:var(--muted);width:200px}
code,.mono{font-family:Consolas,"SFMono-Regular",Menlo,monospace;font-size:13px}
.status{font-weight:600;white-space:nowrap}
.s-set,.s-would-set{color:var(--accent)}
.s-already-set{color:var(--ok)}
.s-skipped{color:var(--muted)}
.s-removed,.s-would-remove{color:var(--rm)}
.reason{color:var(--muted)}
.toolbar{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px}
.toolbar input{flex:1;min-width:200px;background:var(--panel);border:1px solid var(--line);color:var(--text);border-radius:8px;padding:8px 10px}
.toolbar button,.copy{background:var(--panel);border:1px solid var(--line);color:var(--text);border-radius:8px;padding:7px 12px;cursor:pointer}
.toolbar button.on{border-color:var(--accent);color:var(--accent)}
.cmd{display:flex;gap:10px;align-items:flex-start;background:#0b0d11;border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.cmd code{flex:1;white-space:pre-wrap;word-break:break-all}
.note{color:var(--muted)}
footer{margin-top:40px;color:var(--muted);font-size:12px}
</style>
</head>
<body>
<div class="wrap">
'@)

    $logo = if ($Report.LogoDataUri) { "<img src=""$($Report.LogoDataUri)"" alt=""BraveDebloater logo"">" } else { '' }
    [void]$sb.Append("<header>$logo<div><h1>BraveDebloater report<span class=""badge $modeClass"">$(& $e $modeLabel)</span></h1><p class=""sub"">$(& $e $Report.GeneratedAt) &middot; BraveDebloater $(& $e $Report.ToolVersion)</p></div></header>")
    [void]$sb.Append("<div class=""headline"">$(& $e $headline)</div>")

    $changeLabel = if ($Report.Mode -eq 'Apply') { 'Changed' } else { 'Would change' }
    [void]$sb.Append('<div class="cards">')
    [void]$sb.Append("<div class=""card""><span>Policies selected</span><b>$(@($rows | Where-Object { $_.Kind -eq 'Policy' }).Count)</b></div>")
    [void]$sb.Append("<div class=""card""><span>$changeLabel</span><b>$changeCount</b></div>")
    [void]$sb.Append("<div class=""card""><span>Already set</span><b>$alreadyCount</b></div>")
    [void]$sb.Append("<div class=""card""><span>Removals</span><b>$removeCount</b></div>")
    if ($skippedCount -gt 0) {
        [void]$sb.Append("<div class=""card""><span>Skipped</span><b>$skippedCount</b></div>")
    }
    [void]$sb.Append('</div>')

    [void]$sb.Append('<h2>Run details</h2><table class="meta">')
    foreach ($entry in $Report.Details.GetEnumerator()) {
        [void]$sb.Append("<tr><td>$(& $e $entry.Key)</td><td class=""mono"">$(& $e $entry.Value)</td></tr>")
    }
    [void]$sb.Append('</table>')

    [void]$sb.Append('<h2>Policies</h2>')
    [void]$sb.Append('<div class="toolbar"><input id="q" type="search" placeholder="Filter by policy, feature, or reason" aria-label="Filter policies"><button type="button" data-f="all" class="on">All</button><button type="button" data-f="change">Changes</button><button type="button" data-f="already">Already set</button></div>')
    [void]$sb.Append('<table id="policies"><thead><tr><th>Policy</th><th>Feature</th><th>Before</th><th>New value</th><th>Status</th></tr></thead><tbody>')
    foreach ($row in $rows) {
        $statusClass = 's-' + ($row.Status.ToLowerInvariant() -replace '[^a-z]+', '-')
        $group = if ($row.Status -eq 'Already set') { 'already' } elseif ($row.Status -eq 'Skipped') { 'skipped' } else { 'change' }
        $newValue = if ($row.Kind -eq 'Policy') { $row.NewValue } else { '(removed)' }
        [void]$sb.Append("<tr data-g=""$group""><td><code>$(& $e $row.Name)</code><div class=""reason"">$(& $e $row.Reason)</div></td><td>$(& $e $row.Feature)</td><td class=""mono"">$(& $e $row.Before)</td><td class=""mono"">$(& $e $newValue)</td><td class=""status $statusClass"">$(& $e $row.Status)</td></tr>")
    }
    [void]$sb.Append('</tbody></table>')

    [void]$sb.Append('<h2>Undo</h2>')
    if (-not [string]::IsNullOrWhiteSpace($Report.UndoCommand)) {
        [void]$sb.Append('<p class="note">Run this from the BraveDebloater folder to put every value above back the way it was, then restart Brave.</p>')
        [void]$sb.Append("<div class=""cmd""><code id=""undo"">$(& $e $Report.UndoCommand)</code><button type=""button"" class=""copy"" data-copy=""undo"">Copy</button></div>")
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Report.UndoText)) {
        [void]$sb.Append("<p class=""note"">$(& $e $Report.UndoText)</p>")
    }
    elseif ($Report.Mode -eq 'Apply') {
        [void]$sb.Append('<p class="note">No backup was written for this run (-NoBackup), so there is no undo command. Remove the policies above by hand to undo it.</p>')
    }
    else {
        [void]$sb.Append('<p class="note">Nothing to undo yet. When you rerun with -Apply, a backup is written first and the report shows the exact undo command. You can also list earlier backups with -ListBackups and restore one with -UndoFromBackup &lt;file&gt; -Apply.</p>')
    }

    [void]$sb.Append("<footer>Generated by BraveDebloater $(& $e $Report.ToolVersion). Shields, Safe Browsing, and Brave updates are never weakened by this tool. After applying, open brave://policy to confirm.</footer>")
    [void]$sb.Append(@'
</div>
<script>
(function(){
  var q=document.getElementById('q'),f='all',rows=[].slice.call(document.querySelectorAll('#policies tbody tr'));
  function apply(){var t=q.value.toLowerCase();rows.forEach(function(r){var ok=(f==='all'||r.getAttribute('data-g')===f)&&r.textContent.toLowerCase().indexOf(t)>=0;r.style.display=ok?'':'none';});}
  q.addEventListener('input',apply);
  [].forEach.call(document.querySelectorAll('.toolbar button'),function(b){b.addEventListener('click',function(){f=b.getAttribute('data-f');[].forEach.call(document.querySelectorAll('.toolbar button'),function(x){x.className=x===b?'on':'';});apply();});});
  [].forEach.call(document.querySelectorAll('[data-copy]'),function(b){b.addEventListener('click',function(){var t=document.getElementById(b.getAttribute('data-copy')).textContent;function done(){b.textContent='Copied';}function fallback(){var r=document.createRange();r.selectNodeContents(document.getElementById(b.getAttribute('data-copy')));var sel=window.getSelection();sel.removeAllRanges();sel.addRange(r);try{if(document.execCommand('copy')){done();}}catch(e){}}if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).then(done,fallback);}else{fallback();}});});
})();
</script>
</body>
</html>
'@)
    return $sb.ToString()
}
