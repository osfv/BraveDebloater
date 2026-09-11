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
    Write-Host $versionOutput.Trim()
    Write-Host 'Launcher smoke test passed.'
}
finally {
    if (Test-Path -LiteralPath $launcher) {
        Remove-Item -LiteralPath $launcher -Force
    }
}
