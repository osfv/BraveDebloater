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
$launcher = Join-Path $root 'BraveDebloat.exe'
Copy-Item -LiteralPath $LauncherPath -Destination $launcher -Force
try {
    # The failing run comes first so the step's final $LASTEXITCODE reflects a passing run.
    & $launcher -Preset NotAPreset *> $null
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
