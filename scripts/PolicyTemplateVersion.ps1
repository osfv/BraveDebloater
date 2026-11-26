#requires -Version 5.1

function Get-PolicyTemplateVersionFromText {
    param([Parameter(Mandatory = $true)][string]$VersionText)

    $values = @{}
    foreach ($line in ($VersionText -split "`n")) {
        if ($line.Trim() -match '^(MAJOR|MINOR|BUILD|PATCH)=(.+)$') {
            $values[$Matches[1]] = $Matches[2].Trim()
        }
    }

    $keys = @('MAJOR', 'MINOR', 'BUILD', 'PATCH')
    foreach ($key in $keys) {
        if (-not $values.ContainsKey($key)) {
            throw 'Template VERSION file did not contain MAJOR, MINOR, BUILD, and PATCH.'
        }
    }

    return (($keys | ForEach-Object { $values[$_] }) -join '.')
}
