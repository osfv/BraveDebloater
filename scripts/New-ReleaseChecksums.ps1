#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [string]$OutputPath = 'SHA256SUMS.txt'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines = foreach ($item in $Path) {
    $hash = Get-FileHash -LiteralPath $item -Algorithm SHA256
    '{0}  {1}' -f $hash.Hash.ToLowerInvariant(), (Split-Path -Leaf $hash.Path)
}

$lines | Set-Content -LiteralPath $OutputPath -Encoding ASCII
Write-Host "Wrote $OutputPath"
