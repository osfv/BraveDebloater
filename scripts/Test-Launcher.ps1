#requires -Version 5.1
<#
.SYNOPSIS
Smoke tests a built BraveDebloat.exe next to this repository's Invoke-BraveDebloat.ps1.

.DESCRIPTION
Copies the launcher into the repository root, then checks that it forwards arguments, propagates the
script's exit code, and reports the expected tool version. The copy is removed afterwards.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LauncherPath,

    [string]$ExpectedVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
    throw "Launcher not found: $LauncherPath"
}
$testId = [guid]::NewGuid().ToString('N')
$launcher = Join-Path $root "BraveDebloat-test-$testId.exe"
[System.IO.File]::Copy((Resolve-Path -LiteralPath $LauncherPath).ProviderPath, $launcher, $false)
try {
    # The failing run comes first so the step's final $LASTEXITCODE reflects a passing run.
    # Windows PowerShell 5.1 turns a native command's stderr into an error record, which 'Stop' would make fatal.
    $ErrorActionPreference = 'Continue'
    & $launcher -Preset NotAPreset *> $null
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -eq 0) {
        throw 'BraveDebloat.exe returned 0 although the script rejected -Preset NotAPreset.'
    }

    $listOutput = (& $launcher -Preset Extreme -ExcludeFeature News,LeoAI -List 2>&1 | Out-String -Width 4096)
    if ($LASTEXITCODE -ne 0) {
        throw "BraveDebloat.exe -List exited with $LASTEXITCODE. Output: $listOutput"
    }
    if ($listOutput.Contains('BraveNewsDisabled') -or -not $listOutput.Contains('BraveRewardsDisabled')) {
        throw "Comma-separated -ExcludeFeature did not pass through the launcher. Output: $listOutput"
    }

    $versionOutput = (& $launcher -Version 2>&1 | Out-String -Width 4096)
    if ($LASTEXITCODE -ne 0) {
        throw "BraveDebloat.exe -Version exited with $LASTEXITCODE. Output: $versionOutput"
    }
    $expectedText = if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) { 'BraveDebloater ' } else { "BraveDebloater $ExpectedVersion" }
    if (-not $versionOutput.Contains($expectedText)) {
        throw "BraveDebloat.exe -Version did not report '$expectedText'. Output: $versionOutput"
    }

    # Relative paths resolve against the caller's folder, as when the script runs directly, not against the
    # launcher's folder (for winget, a package folder that upgrades replace).
    $callerRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('BraveDebloat Caller {0}' -f [guid]::NewGuid().ToString('N'))
    $exportName = "relative-export-$testId.json"
    $strayExport = Join-Path $root $exportName
    if (Test-Path -LiteralPath $strayExport) {
        throw "Test export path already exists: $strayExport"
    }
    New-Item -ItemType Directory -Path $callerRoot -Force | Out-Null
    Push-Location -LiteralPath $callerRoot
    try {
        $relativeExportOutput = (& $launcher -Platform Linux -OnlyFeature Rewards -ExportPolicyPath $exportName 2>&1 | Out-String -Width 4096)
        if ($LASTEXITCODE -ne 0) {
            throw "BraveDebloat.exe relative export exited with $LASTEXITCODE. Output: $relativeExportOutput"
        }
        $exportPath = Join-Path $callerRoot $exportName
        if (-not (Test-Path -LiteralPath $exportPath)) {
            throw "BraveDebloat.exe did not write a relative -ExportPolicyPath into the caller's folder. Output: $relativeExportOutput"
        }
        $payload = Get-Content -LiteralPath $exportPath -Raw | ConvertFrom-Json
        if ($payload.BraveRewardsDisabled -isnot [bool] -or -not $payload.BraveRewardsDisabled) {
            throw 'BraveDebloat.exe wrote an incorrect relative export payload.'
        }

        $relativeApplyOutput = (& $launcher -Platform Linux -OnlyFeature Rewards -PolicyPath 'policy.json' -BackupDirectory 'backups' -Apply 2>&1 | Out-String -Width 4096)
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $callerRoot 'policy.json'))) {
            throw "BraveDebloat.exe did not apply to a relative policy path. Output: $relativeApplyOutput"
        }
        $backups = @(Get-ChildItem -LiteralPath (Join-Path $callerRoot 'backups') -Filter 'BraveDebloater-*.json' -File)
        if ($backups.Count -ne 1) {
            throw 'BraveDebloat.exe did not write a backup into the relative backup directory.'
        }
        $relativeUndoOutput = (& $launcher -UndoFromBackup (Join-Path 'backups' $backups[0].Name) -PolicyPath 'policy.json' -Apply 2>&1 | Out-String -Width 4096)
        if ($LASTEXITCODE -ne 0 -or (Get-Content -LiteralPath (Join-Path $callerRoot 'policy.json') -Raw) -match 'BraveRewardsDisabled') {
            throw "BraveDebloat.exe did not restore from a relative backup path. Output: $relativeUndoOutput"
        }
    }
    finally {
        Pop-Location
        Remove-Item -LiteralPath $callerRoot -Recurse -Force
        if (Test-Path -LiteralPath $strayExport) {
            Remove-Item -LiteralPath $strayExport -Force
        }
    }
    # The undo hint printed through the launcher must still restore when pasted into cmd.exe.
    $undoRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('BraveDebloat Launcher {0}' -f [guid]::NewGuid().ToString('N'))
    try {
        $undoApplyOutput = (& $launcher -Platform Linux -PolicyPath (Join-Path $undoRoot 'policy.json') -OnlyFeature Rewards -BackupDirectory (Join-Path $undoRoot 'backups') -Apply 2>&1 | Out-String -Width 4096)
        $undoHint = [regex]::Match($undoApplyOutput, 'rerun BraveDebloater with: (.+) -Apply').Groups[1].Value
        if (-not $undoHint.Contains('-UndoFromBackup "')) {
            throw "BraveDebloat.exe did not print a cmd.exe-quoted undo hint. Output: $undoApplyOutput"
        }
        $cmdStart = New-Object System.Diagnostics.ProcessStartInfo
        $cmdStart.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $cmdStart.Arguments = '/d /s /c ""' + $launcher + '" ' + $undoHint + '"'
        $cmdStart.UseShellExecute = $false
        $cmdStart.RedirectStandardOutput = $true
        $cmdStart.RedirectStandardError = $true
        $cmdProcess = [System.Diagnostics.Process]::Start($cmdStart)
        $undoRestoreOutput = $cmdProcess.StandardOutput.ReadToEnd() + $cmdProcess.StandardError.ReadToEnd()
        $cmdProcess.WaitForExit()
        if (-not $undoRestoreOutput.Contains('Would remove BraveRewardsDisabled')) {
            throw "The undo hint did not restore when pasted into cmd.exe. Hint: $undoHint Output: $undoRestoreOutput"
        }
    }
    finally {
        if (Test-Path -LiteralPath $undoRoot) {
            Remove-Item -LiteralPath $undoRoot -Recurse -Force
        }
    }

    Write-Host $versionOutput.Trim()
    Write-Host 'Launcher smoke test passed.'
}
finally {
    if (Test-Path -LiteralPath $launcher) {
        Remove-Item -LiteralPath $launcher -Force
    }
}
