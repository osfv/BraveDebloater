#requires -Version 5.1
<#
.SYNOPSIS
Compiles packaging/launcher/BraveDebloat.cs into BraveDebloat.exe for the Windows release zip and winget.

.DESCRIPTION
Uses the C# compiler that ships with .NET Framework (csc.exe), which exists on every Windows 10/11 and
Windows Server machine, so no SDK download is needed. Pass -CompilerPath to use another compiler with the
same command line, for example mcs from Mono when testing on Linux or macOS.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$Version,

    [string]$OutputPath = 'BraveDebloat.exe',

    [string]$CompilerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path (Join-Path (Join-Path $root 'packaging') 'launcher') 'BraveDebloat.cs'
if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Launcher source not found: $sourcePath"
}

if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    if ($env:OS -ne 'Windows_NT') {
        throw 'csc.exe from .NET Framework is only available on Windows. Pass -CompilerPath to use another C# compiler.'
    }
    $frameworkRoot = Join-Path $env:WINDIR 'Microsoft.NET'
    $candidates = @(
        (Join-Path $frameworkRoot 'Framework64\v4.0.30319\csc.exe'),
        (Join-Path $frameworkRoot 'Framework\v4.0.30319\csc.exe')
    )
    $CompilerPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
        throw "csc.exe was not found under $frameworkRoot. Install .NET Framework 4.x or pass -CompilerPath."
    }
}

$outputFull = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $OutputPath))
if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $outputFull = [System.IO.Path]::GetFullPath($OutputPath)
}
$outputDirectory = Split-Path -Parent $outputFull
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$assemblyInfoPath = Join-Path ([System.IO.Path]::GetTempPath()) ('BraveDebloatAssemblyInfo-{0}.cs' -f [guid]::NewGuid().ToString('N'))
try {
    @(
        'using System.Reflection;'
        '[assembly: AssemblyTitle("BraveDebloat launcher")]'
        '[assembly: AssemblyDescription("Runs Invoke-BraveDebloat.ps1 from the same folder. Dry-run by default; nothing changes without -Apply.")]'
        '[assembly: AssemblyProduct("BraveDebloater")]'
        '[assembly: AssemblyCompany("osfv")]'
        '[assembly: AssemblyCopyright("MIT License. https://github.com/osfv/BraveDebloater")]'
        "[assembly: AssemblyVersion(`"$Version.0`")]"
        "[assembly: AssemblyFileVersion(`"$Version.0`")]"
        "[assembly: AssemblyInformationalVersion(`"$Version`")]"
    ) | Set-Content -LiteralPath $assemblyInfoPath -Encoding ASCII

    $compilerArguments = @(
        '-nologo',
        '-target:exe',
        '-platform:anycpu',
        '-optimize+',
        '-warnaserror+',
        "-out:$outputFull",
        $sourcePath,
        $assemblyInfoPath
    )
    & $CompilerPath @compilerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "C# compiler exited with code $LASTEXITCODE."
    }
}
finally {
    if (Test-Path -LiteralPath $assemblyInfoPath) {
        Remove-Item -LiteralPath $assemblyInfoPath -Force
    }
}

Write-Host "Built $outputFull (launcher $Version)."
