#requires -Version 5.1
<#
.SYNOPSIS
    Shared utility functions used by test scripts and the main application.
#>

Set-StrictMode -Version Latest

function ConvertTo-PropertyMap {
    param([Parameter(Mandatory = $true)]$Object)

    $map = @{}
    foreach ($property in $Object.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }
    return $map
}

function Resolve-PresetEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Presets,
        [hashtable]$Seen = @{}
    )

    if (-not $Presets.ContainsKey($Name)) {
        throw "Unknown preset '$Name'."
    }
    if ($Seen.ContainsKey($Name)) {
        throw "Preset cycle detected at '$Name'."
    }

    $Seen[$Name] = $true
    $resolved = New-Object System.Collections.Generic.List[string]

    foreach ($entry in @($Presets[$Name])) {
        if ($entry -isnot [string]) {
            throw "Preset '$Name' contains a non-string entry."
        }

        if ($entry.StartsWith('@')) {
            $childName = $entry.Substring(1)
            foreach ($childPolicy in Resolve-PresetEntries -Name $childName -Presets $Presets -Seen ($Seen.Clone())) {
                if (-not $resolved.Contains($childPolicy)) {
                    [void]$resolved.Add($childPolicy)
                }
            }
        }
        elseif (-not $resolved.Contains($entry)) {
            [void]$resolved.Add($entry)
        }
    }

    return $resolved.ToArray()
}

function Get-PolicySafetyFindings {
    param(
        [string[]]$PolicyNames,
        [Parameter(Mandatory = $true)]$Manifest,
        [switch]$Throw
    )

    $findings = New-Object System.Collections.Generic.List[string]
    $blockedNames = @($Manifest.safety.blockedPolicyNames)
    $blockedPatterns = @($Manifest.safety.blockedNamePatterns)

    foreach ($policyName in $PolicyNames) {
        if ($blockedNames -contains $policyName) {
            if ($Throw) {
                throw "Refusing to apply protected policy '$policyName'."
            }
            [void]$findings.Add("Protected policy '$policyName' is present.")
            continue
        }

        foreach ($pattern in $blockedPatterns) {
            if ($policyName -match $pattern) {
                if ($Throw) {
                    throw "Refusing to apply '$policyName' because it matches protected pattern '$pattern'."
                }
                [void]$findings.Add("Policy '$policyName' matches protected pattern '$pattern'.")
                break
            }
        }
    }

    return $findings.ToArray()
}

function Format-TableOutput {
    param([Parameter(Mandatory = $true)]$Rows)

    $Rows | Format-Table -AutoSize -Wrap
}

function Assert-TextContains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not $Text.Contains($Expected)) {
        throw "$Context did not contain expected text: $Expected"
    }
}

function Assert-TextDoesNotContain {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Unexpected,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Text.Contains($Unexpected)) {
        throw "$Context contained unexpected text: $Unexpected"
    }
}
