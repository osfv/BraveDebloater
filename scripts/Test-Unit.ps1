#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'Invoke-BraveDebloat.ps1'
$srcDir = Join-Path $root 'src'

# Extract and load function definitions via AST from the main script and all src modules.
$sourceFiles = @($scriptPath)
if (Test-Path -LiteralPath $srcDir) {
    $sourceFiles += @(Get-ChildItem -Path $srcDir -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
}
foreach ($file in $sourceFiles) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
    foreach ($funcAst in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -eq $ast.EndBlock }, $false)) {
        . ([scriptblock]::Create($funcAst.Extent.Text))
    }
}

# Override ProjectRoot so Get-Manifest can find the config directory.
$ProjectRoot = $root

$passed = 0
$failed = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ("$Actual" -ne "$Expected") {
        throw "$Context : expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not $Value) {
        throw "$Context : expected true."
    }
}

function Assert-False {
    param(
        [Parameter(Mandatory = $true)][bool]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Value) {
        throw "$Context : expected false."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $threw = $false
    try {
        & $ScriptBlock
    }
    catch {
        $threw = $true
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) {
            throw "$Context : threw '$($_.Exception.Message)' but expected pattern '$Pattern'."
        }
    }
    if (-not $threw) {
        throw "$Context : expected an exception but none was thrown."
    }
}

function Run-Test {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    try {
        & $ScriptBlock
        $script:passed++
    }
    catch {
        $script:failed++
        Write-Warning "FAIL: $Name - $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Get-ManifestMap
# ---------------------------------------------------------------------------
Run-Test 'Get-ManifestMap: converts PSObject to hashtable' {
    $obj = [pscustomobject]@{ Alpha = 1; Beta = 'two' }
    $map = Get-ManifestMap -Object $obj
    Assert-Equal -Actual $map['Alpha'] -Expected 1 -Context 'Alpha value'
    Assert-Equal -Actual $map['Beta'] -Expected 'two' -Context 'Beta value'
    Assert-Equal -Actual $map.Count -Expected 2 -Context 'map count'
}

Run-Test 'Get-ManifestMap: empty object returns empty hashtable' {
    $obj = [pscustomobject]@{}
    $map = Get-ManifestMap -Object $obj
    Assert-Equal -Actual $map.Count -Expected 0 -Context 'empty map count'
}

# ---------------------------------------------------------------------------
# Resolve-PresetPolicies
# ---------------------------------------------------------------------------
Run-Test 'Resolve-PresetPolicies: flat preset' {
    $presets = @{ Simple = @('PolicyA', 'PolicyB') }
    $result = Resolve-PresetPolicies -Name 'Simple' -Presets $presets
    Assert-Equal -Actual ($result -join ',') -Expected 'PolicyA,PolicyB' -Context 'flat preset'
}

Run-Test 'Resolve-PresetPolicies: nested preset via @reference' {
    $presets = @{
        Base   = @('PolicyA')
        Child  = @('@Base', 'PolicyB')
    }
    $result = Resolve-PresetPolicies -Name 'Child' -Presets $presets
    Assert-Equal -Actual ($result -join ',') -Expected 'PolicyA,PolicyB' -Context 'nested preset'
}

Run-Test 'Resolve-PresetPolicies: deduplication' {
    $presets = @{
        Base   = @('PolicyA')
        Child  = @('@Base', 'PolicyA', 'PolicyB')
    }
    $result = Resolve-PresetPolicies -Name 'Child' -Presets $presets
    Assert-Equal -Actual ($result -join ',') -Expected 'PolicyA,PolicyB' -Context 'dedup preset'
}

Run-Test 'Resolve-PresetPolicies: unknown preset throws' {
    $presets = @{ Known = @('PolicyA') }
    Assert-Throws -ScriptBlock { Resolve-PresetPolicies -Name 'Missing' -Presets $presets } -Pattern 'Unknown preset' -Context 'unknown preset'
}

Run-Test 'Resolve-PresetPolicies: cycle detection' {
    $presets = @{
        A = @('@B')
        B = @('@A')
    }
    Assert-Throws -ScriptBlock { Resolve-PresetPolicies -Name 'A' -Presets $presets } -Pattern 'cycle detected' -Context 'cycle detection'
}

Run-Test 'Resolve-PresetPolicies: non-string entry throws' {
    $presets = @{ Bad = @(42) }
    Assert-Throws -ScriptBlock { Resolve-PresetPolicies -Name 'Bad' -Presets $presets } -Pattern 'non-string' -Context 'non-string entry'
}

# ---------------------------------------------------------------------------
# Get-FeatureMap
# ---------------------------------------------------------------------------
Run-Test 'Get-FeatureMap: builds map from features' {
    $features = @(
        [pscustomobject]@{ id = 'Rewards'; policies = @('BraveRewardsDisabled') },
        [pscustomobject]@{ id = 'Wallet'; policies = @('BraveWalletDisabled') }
    )
    $map = Get-FeatureMap -Features $features
    Assert-Equal -Actual $map.Count -Expected 2 -Context 'feature map count'
    Assert-Equal -Actual $map['Rewards'].id -Expected 'Rewards' -Context 'Rewards entry'
}

Run-Test 'Get-FeatureMap: duplicate id throws' {
    $features = @(
        [pscustomobject]@{ id = 'Same'; policies = @() },
        [pscustomobject]@{ id = 'Same'; policies = @() }
    )
    Assert-Throws -ScriptBlock { Get-FeatureMap -Features $features } -Pattern 'Duplicate feature' -Context 'duplicate feature'
}

Run-Test 'Get-FeatureMap: missing id throws' {
    $features = @([pscustomobject]@{ id = ''; policies = @() })
    Assert-Throws -ScriptBlock { Get-FeatureMap -Features $features } -Pattern 'missing an id' -Context 'missing id'
}

# ---------------------------------------------------------------------------
# Get-FeaturePolicies
# ---------------------------------------------------------------------------
Run-Test 'Get-FeaturePolicies: returns policy names' {
    $feature = [pscustomobject]@{ policies = @('P1', 'P2') }
    $result = @(Get-FeaturePolicies -Feature $feature)
    Assert-Equal -Actual ($result -join ',') -Expected 'P1,P2' -Context 'feature policies'
}

Run-Test 'Get-FeaturePolicies: empty policies returns empty' {
    $feature = [pscustomobject]@{ policies = @() }
    $result = @(Get-FeaturePolicies -Feature $feature)
    Assert-Equal -Actual $result.Count -Expected 0 -Context 'empty policies'
}

# ---------------------------------------------------------------------------
# Add-StringIfMissing / Remove-StringFromList
# ---------------------------------------------------------------------------
Run-Test 'Add-StringIfMissing: adds new value' {
    $list = New-Object System.Collections.Generic.List[string]
    Add-StringIfMissing -List $list -Value 'hello'
    Assert-Equal -Actual $list.Count -Expected 1 -Context 'list count after add'
    Assert-Equal -Actual $list[0] -Expected 'hello' -Context 'added value'
}

Run-Test 'Add-StringIfMissing: ignores duplicate' {
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add('hello')
    Add-StringIfMissing -List $list -Value 'hello'
    Assert-Equal -Actual $list.Count -Expected 1 -Context 'list count after dup add'
}

Run-Test 'Remove-StringFromList: removes all occurrences' {
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add('a')
    $list.Add('b')
    $list.Add('a')
    Remove-StringFromList -List $list -Value 'a'
    Assert-Equal -Actual $list.Count -Expected 1 -Context 'list count after remove'
    Assert-Equal -Actual $list[0] -Expected 'b' -Context 'remaining value'
}

Run-Test 'Remove-StringFromList: no-op for missing value' {
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add('x')
    Remove-StringFromList -List $list -Value 'y'
    Assert-Equal -Actual $list.Count -Expected 1 -Context 'list count unchanged'
}

# ---------------------------------------------------------------------------
# Test-FeatureSelectedByPolicy
# ---------------------------------------------------------------------------
Run-Test 'Test-FeatureSelectedByPolicy: selected when all policies present' {
    $feature = [pscustomobject]@{ policies = @('P1', 'P2'); defaultPresets = @() }
    $policyNames = New-Object System.Collections.Generic.List[string]
    $policyNames.Add('P1')
    $policyNames.Add('P2')
    $result = Test-FeatureSelectedByPolicy -Feature $feature -PolicyNames $policyNames -PresetName 'Extreme'
    Assert-True -Value $result -Context 'all policies present'
}

Run-Test 'Test-FeatureSelectedByPolicy: not selected when policy missing' {
    $feature = [pscustomobject]@{ policies = @('P1', 'P2'); defaultPresets = @() }
    $policyNames = New-Object System.Collections.Generic.List[string]
    $policyNames.Add('P1')
    $result = Test-FeatureSelectedByPolicy -Feature $feature -PolicyNames $policyNames -PresetName 'Extreme'
    Assert-False -Value $result -Context 'missing policy'
}

Run-Test 'Test-FeatureSelectedByPolicy: falls back to defaultPresets when no policies' {
    $feature = [pscustomobject]@{ policies = @(); defaultPresets = @('Extreme') }
    $policyNames = New-Object System.Collections.Generic.List[string]
    $result = Test-FeatureSelectedByPolicy -Feature $feature -PolicyNames $policyNames -PresetName 'Extreme'
    Assert-True -Value $result -Context 'defaultPreset match'
}

Run-Test 'Test-FeatureSelectedByPolicy: defaultPresets mismatch returns false' {
    $feature = [pscustomobject]@{ policies = @(); defaultPresets = @('Standard') }
    $policyNames = New-Object System.Collections.Generic.List[string]
    $result = Test-FeatureSelectedByPolicy -Feature $feature -PolicyNames $policyNames -PresetName 'Extreme'
    Assert-False -Value $result -Context 'defaultPreset mismatch'
}

# ---------------------------------------------------------------------------
# Assert-FeatureNames
# ---------------------------------------------------------------------------
Run-Test 'Assert-FeatureNames: valid names pass' {
    $featureMap = @{ Rewards = $true; Wallet = $true }
    Assert-FeatureNames -Names @('Rewards', 'Wallet') -FeatureMap $featureMap
}

Run-Test 'Assert-FeatureNames: unknown name throws' {
    $featureMap = @{ Rewards = $true }
    Assert-Throws -ScriptBlock { Assert-FeatureNames -Names @('NoSuchFeature') -FeatureMap $featureMap } -Pattern 'Unknown feature' -Context 'unknown feature name'
}

Run-Test 'Assert-FeatureNames: blank names are skipped' {
    $featureMap = @{ Rewards = $true }
    Assert-FeatureNames -Names @('', '  ') -FeatureMap $featureMap
}

# ---------------------------------------------------------------------------
# Get-NormalizedFeatureName
# ---------------------------------------------------------------------------
Run-Test 'Get-NormalizedFeatureName: trims and deduplicates' {
    $result = @(Get-NormalizedFeatureName -Names @('  Rewards ', 'Wallet', 'Rewards'))
    Assert-Equal -Actual ($result -join ',') -Expected 'Rewards,Wallet' -Context 'normalized names'
}

Run-Test 'Get-NormalizedFeatureName: blank entries are dropped' {
    $result = @(Get-NormalizedFeatureName -Names @('', '  ', 'VPN'))
    Assert-Equal -Actual ($result -join ',') -Expected 'VPN' -Context 'blanks dropped'
}

Run-Test 'Get-NormalizedFeatureName: empty input returns empty' {
    $result = @(Get-NormalizedFeatureName -Names @())
    Assert-Equal -Actual $result.Count -Expected 0 -Context 'empty input'
}

# ---------------------------------------------------------------------------
# Set-FeatureSelection
# ---------------------------------------------------------------------------
Run-Test 'Set-FeatureSelection: selecting adds policies and feature id' {
    $feature = [pscustomobject]@{ id = 'News'; policies = @('BraveNewsDisabled') }
    $policyNames = New-Object System.Collections.Generic.List[string]
    $selectedIds = New-Object System.Collections.Generic.List[string]
    Set-FeatureSelection -Feature $feature -PolicyNames $policyNames -SelectedFeatureIds $selectedIds -Selected $true
    Assert-True -Value ($selectedIds.Contains('News')) -Context 'feature id added'
    Assert-True -Value ($policyNames.Contains('BraveNewsDisabled')) -Context 'policy added'
}

Run-Test 'Set-FeatureSelection: deselecting removes policies and feature id' {
    $feature = [pscustomobject]@{ id = 'News'; policies = @('BraveNewsDisabled') }
    $policyNames = New-Object System.Collections.Generic.List[string]
    $policyNames.Add('BraveNewsDisabled')
    $selectedIds = New-Object System.Collections.Generic.List[string]
    $selectedIds.Add('News')
    Set-FeatureSelection -Feature $feature -PolicyNames $policyNames -SelectedFeatureIds $selectedIds -Selected $false
    Assert-False -Value ($selectedIds.Contains('News')) -Context 'feature id removed'
    Assert-False -Value ($policyNames.Contains('BraveNewsDisabled')) -Context 'policy removed'
}

# ---------------------------------------------------------------------------
# Assert-FeatureReferences
# ---------------------------------------------------------------------------
Run-Test 'Assert-FeatureReferences: valid references pass' {
    $features = @([pscustomobject]@{ id = 'F1'; policies = @('P1') })
    $policyDefs = @{ P1 = $true }
    Assert-FeatureReferences -Features $features -PolicyDefinitions $policyDefs
}

Run-Test 'Assert-FeatureReferences: undefined policy throws' {
    $features = @([pscustomobject]@{ id = 'F1'; policies = @('Missing') })
    $policyDefs = @{ P1 = $true }
    Assert-Throws -ScriptBlock { Assert-FeatureReferences -Features $features -PolicyDefinitions $policyDefs } -Pattern 'undefined policy' -Context 'undefined policy ref'
}

# ---------------------------------------------------------------------------
# Get-RegistryPolicyPath
# ---------------------------------------------------------------------------
Run-Test 'Get-RegistryPolicyPath: CurrentUser' {
    $result = Get-RegistryPolicyPath -ScopeName 'CurrentUser'
    Assert-Equal -Actual $result -Expected 'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave' -Context 'CurrentUser path'
}

Run-Test 'Get-RegistryPolicyPath: LocalMachine' {
    $result = Get-RegistryPolicyPath -ScopeName 'LocalMachine'
    Assert-Equal -Actual $result -Expected 'Registry::HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave' -Context 'LocalMachine path'
}

# ---------------------------------------------------------------------------
# Get-RequiredPropertyValue
# ---------------------------------------------------------------------------
Run-Test 'Get-RequiredPropertyValue: returns existing property' {
    $obj = [pscustomobject]@{ name = 'hello' }
    $result = Get-RequiredPropertyValue -Object $obj -Name 'name' -Context 'test obj'
    Assert-Equal -Actual $result -Expected 'hello' -Context 'existing property'
}

Run-Test 'Get-RequiredPropertyValue: missing property throws' {
    $obj = [pscustomobject]@{ name = 'hello' }
    Assert-Throws -ScriptBlock { Get-RequiredPropertyValue -Object $obj -Name 'missing' -Context 'test obj' } -Pattern 'missing required property' -Context 'missing property'
}

# ---------------------------------------------------------------------------
# Assert-BackupRegistryPath
# ---------------------------------------------------------------------------
Run-Test 'Assert-BackupRegistryPath: allowed CurrentUser path passes' {
    Assert-BackupRegistryPath -RegistryPath 'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave'
}

Run-Test 'Assert-BackupRegistryPath: allowed LocalMachine path passes' {
    Assert-BackupRegistryPath -RegistryPath 'Registry::HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave'
}

Run-Test 'Assert-BackupRegistryPath: untrusted path throws' {
    Assert-Throws -ScriptBlock {
        Assert-BackupRegistryPath -RegistryPath 'Registry::HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows'
    } -Pattern 'untrusted registry path' -Context 'untrusted path'
}

# ---------------------------------------------------------------------------
# Assert-PolicySafety
# ---------------------------------------------------------------------------
Run-Test 'Assert-PolicySafety: safe policies pass' {
    $manifest = [pscustomobject]@{
        safety = [pscustomobject]@{
            blockedPolicyNames = @('BlockedPolicy')
            blockedNamePatterns = @('.*ShieldsDisabled.*')
        }
    }
    Assert-PolicySafety -PolicyNames @('BraveRewardsDisabled') -Manifest $manifest
}

Run-Test 'Assert-PolicySafety: blocked name throws' {
    $manifest = [pscustomobject]@{
        safety = [pscustomobject]@{
            blockedPolicyNames = @('BlockedPolicy')
            blockedNamePatterns = @()
        }
    }
    Assert-Throws -ScriptBlock {
        Assert-PolicySafety -PolicyNames @('BlockedPolicy') -Manifest $manifest
    } -Pattern 'Refusing to apply protected policy' -Context 'blocked name'
}

Run-Test 'Assert-PolicySafety: blocked pattern throws' {
    $manifest = [pscustomobject]@{
        safety = [pscustomobject]@{
            blockedPolicyNames = @()
            blockedNamePatterns = @('.*ShieldsDisabled.*')
        }
    }
    Assert-Throws -ScriptBlock {
        Assert-PolicySafety -PolicyNames @('BraveShieldsDisabledForUrls') -Manifest $manifest
    } -Pattern 'matches protected pattern' -Context 'blocked pattern'
}

# ---------------------------------------------------------------------------
# Get-PolicySafetyFinding
# ---------------------------------------------------------------------------
Run-Test 'Get-PolicySafetyFinding: returns empty for safe policies' {
    $manifest = [pscustomobject]@{
        safety = [pscustomobject]@{
            blockedPolicyNames = @('BlockedPolicy')
            blockedNamePatterns = @('.*ShieldsDisabled.*')
        }
    }
    $findings = @(Get-PolicySafetyFinding -PolicyNames @('BraveRewardsDisabled') -Manifest $manifest)
    Assert-Equal -Actual $findings.Count -Expected 0 -Context 'safe findings'
}

Run-Test 'Get-PolicySafetyFinding: finds blocked name' {
    $manifest = [pscustomobject]@{
        safety = [pscustomobject]@{
            blockedPolicyNames = @('BlockedPolicy')
            blockedNamePatterns = @()
        }
    }
    $findings = @(Get-PolicySafetyFinding -PolicyNames @('BlockedPolicy') -Manifest $manifest)
    Assert-Equal -Actual $findings.Count -Expected 1 -Context 'blocked name finding count'
}

Run-Test 'Get-PolicySafetyFinding: finds blocked pattern' {
    $manifest = [pscustomobject]@{
        safety = [pscustomobject]@{
            blockedPolicyNames = @()
            blockedNamePatterns = @('.*ShieldsDisabled.*')
        }
    }
    $findings = @(Get-PolicySafetyFinding -PolicyNames @('BraveShieldsDisabledForUrls') -Manifest $manifest)
    Assert-Equal -Actual $findings.Count -Expected 1 -Context 'blocked pattern finding count'
}

# ---------------------------------------------------------------------------
# Get-PolicyEntryMap
# ---------------------------------------------------------------------------
Run-Test 'Get-PolicyEntryMap: builds map from entries' {
    $entries = @(
        [pscustomobject]@{ Name = 'P1'; Value = 1 },
        [pscustomobject]@{ Name = 'P2'; Value = 'hello' }
    )
    $map = Get-PolicyEntryMap -Entries $entries
    Assert-Equal -Actual $map.Count -Expected 2 -Context 'entry map count'
    Assert-Equal -Actual $map['P1'].Value -Expected 1 -Context 'P1 value'
}

Run-Test 'Get-PolicyEntryMap: empty entries returns empty map' {
    $map = Get-PolicyEntryMap -Entries @()
    Assert-Equal -Actual $map.Count -Expected 0 -Context 'empty entry map'
}

# ---------------------------------------------------------------------------
# Test-PolicyValueMatches
# ---------------------------------------------------------------------------
Run-Test 'Test-PolicyValueMatches: DWord match' {
    $result = Test-PolicyValueMatches -ActualValue 1 -ExpectedValue 1 -Type 'DWord'
    Assert-True -Value $result -Context 'DWord match'
}

Run-Test 'Test-PolicyValueMatches: DWord mismatch' {
    $result = Test-PolicyValueMatches -ActualValue 0 -ExpectedValue 1 -Type 'DWord'
    Assert-False -Value $result -Context 'DWord mismatch'
}

Run-Test 'Test-PolicyValueMatches: String match' {
    $result = Test-PolicyValueMatches -ActualValue 'hello' -ExpectedValue 'hello' -Type 'String'
    Assert-True -Value $result -Context 'String match'
}

Run-Test 'Test-PolicyValueMatches: String mismatch' {
    $result = Test-PolicyValueMatches -ActualValue 'abc' -ExpectedValue 'xyz' -Type 'String'
    Assert-False -Value $result -Context 'String mismatch'
}

Run-Test 'Test-PolicyValueMatches: unknown type returns false' {
    $result = Test-PolicyValueMatches -ActualValue 'a' -ExpectedValue 'a' -Type 'Binary'
    Assert-False -Value $result -Context 'unknown type'
}

Run-Test 'Test-PolicyValueMatches: QWord match' {
    $result = Test-PolicyValueMatches -ActualValue 100 -ExpectedValue 100 -Type 'QWord'
    Assert-True -Value $result -Context 'QWord match'
}

# ---------------------------------------------------------------------------
# Get-FeaturePolicyStatus
# ---------------------------------------------------------------------------
Run-Test 'Get-FeaturePolicyStatus: returns Applied when all match' {
    $feature = [pscustomobject]@{ policies = @('P1') }
    $entries = @{ P1 = [pscustomobject]@{ Value = 0 } }
    $defs = @{ P1 = [pscustomobject]@{ value = 0; type = 'DWord' } }
    $result = Get-FeaturePolicyStatus -Feature $feature -PolicyEntries $entries -PolicyDefinitions $defs
    Assert-Equal -Actual $result -Expected 'Applied' -Context 'applied status'
}

Run-Test 'Get-FeaturePolicyStatus: returns Not applied when no entries' {
    $feature = [pscustomobject]@{ policies = @('P1') }
    $entries = @{}
    $defs = @{ P1 = [pscustomobject]@{ value = 0; type = 'DWord' } }
    $result = Get-FeaturePolicyStatus -Feature $feature -PolicyEntries $entries -PolicyDefinitions $defs
    Assert-Equal -Actual $result -Expected 'Not applied' -Context 'not applied status'
}

Run-Test 'Get-FeaturePolicyStatus: returns Different when value mismatches' {
    $feature = [pscustomobject]@{ policies = @('P1') }
    $entries = @{ P1 = [pscustomobject]@{ Value = 1 } }
    $defs = @{ P1 = [pscustomobject]@{ value = 0; type = 'DWord' } }
    $result = Get-FeaturePolicyStatus -Feature $feature -PolicyEntries $entries -PolicyDefinitions $defs
    Assert-Equal -Actual $result -Expected 'Different' -Context 'different status'
}

Run-Test 'Get-FeaturePolicyStatus: returns Profile-only when no policies' {
    $feature = [pscustomobject]@{ policies = @() }
    $result = Get-FeaturePolicyStatus -Feature $feature -PolicyEntries @{} -PolicyDefinitions @{}
    Assert-Equal -Actual $result -Expected 'Profile-only' -Context 'profile-only status'
}

Run-Test 'Get-FeaturePolicyStatus: returns Partial when some match' {
    $feature = [pscustomobject]@{ policies = @('P1', 'P2') }
    $entries = @{
        P1 = [pscustomobject]@{ Value = 0 }
        P2 = [pscustomobject]@{ Value = 99 }
    }
    $defs = @{
        P1 = [pscustomobject]@{ value = 0; type = 'DWord' }
        P2 = [pscustomobject]@{ value = 0; type = 'DWord' }
    }
    $result = Get-FeaturePolicyStatus -Feature $feature -PolicyEntries $entries -PolicyDefinitions $defs
    Assert-Equal -Actual $result -Expected 'Partial' -Context 'partial status'
}

# ---------------------------------------------------------------------------
# Get-JsonPathResult
# ---------------------------------------------------------------------------
Run-Test 'Get-JsonPathResult: returns existing nested value' {
    $obj = [pscustomobject]@{ brave = [pscustomobject]@{ rewards = [pscustomobject]@{ enabled = $false } } }
    $result = Get-JsonPathResult -Object $obj -Path 'brave.rewards.enabled'
    Assert-True -Value $result.exists -Context 'exists'
    Assert-False -Value $result.value -Context 'value'
}

Run-Test 'Get-JsonPathResult: returns not exists for missing path' {
    $obj = [pscustomobject]@{ brave = [pscustomobject]@{} }
    $result = Get-JsonPathResult -Object $obj -Path 'brave.rewards.enabled'
    Assert-False -Value $result.exists -Context 'missing path not exists'
}

Run-Test 'Get-JsonPathResult: returns top-level value' {
    $obj = [pscustomobject]@{ name = 'test' }
    $result = Get-JsonPathResult -Object $obj -Path 'name'
    Assert-True -Value $result.exists -Context 'top-level exists'
    Assert-Equal -Actual $result.value -Expected 'test' -Context 'top-level value'
}

# ---------------------------------------------------------------------------
# Set-JsonPathValue
# ---------------------------------------------------------------------------
Run-Test 'Set-JsonPathValue: sets existing value' {
    $obj = [pscustomobject]@{ brave = [pscustomobject]@{ enabled = $true } }
    $result = Set-JsonPathValue -Object $obj -Path 'brave.enabled' -Value $false
    Assert-True -Value $result -Context 'set result'
    Assert-False -Value $obj.brave.enabled -Context 'updated value'
}

Run-Test 'Set-JsonPathValue: returns false when path missing and CreateMissing is false' {
    $obj = [pscustomobject]@{}
    $result = Set-JsonPathValue -Object $obj -Path 'a.b.c' -Value 1 -CreateMissing $false
    Assert-False -Value $result -Context 'no create result'
}

Run-Test 'Set-JsonPathValue: creates missing path when CreateMissing is true' {
    $obj = [pscustomobject]@{}
    $result = Set-JsonPathValue -Object $obj -Path 'a.b.c' -Value 42 -CreateMissing $true
    Assert-True -Value $result -Context 'create result'
    $check = Get-JsonPathResult -Object $obj -Path 'a.b.c'
    Assert-True -Value $check.exists -Context 'created path exists'
    Assert-Equal -Actual $check.value -Expected 42 -Context 'created value'
}

Run-Test 'Set-JsonPathValue: sets top-level value' {
    $obj = [pscustomobject]@{ x = 1 }
    $result = Set-JsonPathValue -Object $obj -Path 'x' -Value 2
    Assert-True -Value $result -Context 'top-level set result'
    Assert-Equal -Actual $obj.x -Expected 2 -Context 'top-level updated value'
}

# ---------------------------------------------------------------------------
# Get-BackupSummary
# ---------------------------------------------------------------------------
Run-Test 'Get-BackupSummary: returns count and latest for matching files' {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('UnitTest-Backup-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $tempDir 'BraveDebloater-20260101-010101-001.json') -Value '{}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $tempDir 'BraveDebloater-20260102-020202-002.json') -Value '{}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $tempDir 'other-file.json') -Value '{}' -Encoding UTF8
        $summary = Get-BackupSummary -Directory $tempDir
        Assert-Equal -Actual $summary.Count -Expected 2 -Context 'backup count'
        Assert-True -Value ($summary.Latest.Length -gt 0) -Context 'latest has value'
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}

Run-Test 'Get-BackupSummary: returns zero for missing directory' {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('UnitTest-Missing-{0}' -f [guid]::NewGuid().ToString('N'))
    $summary = Get-BackupSummary -Directory $tempDir
    Assert-Equal -Actual $summary.Count -Expected 0 -Context 'missing dir count'
    Assert-Equal -Actual $summary.Latest -Expected '' -Context 'missing dir latest'
}

# ---------------------------------------------------------------------------
# New-BackupPath
# ---------------------------------------------------------------------------
Run-Test 'New-BackupPath: generates timestamped path' {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('UnitTest-NewBak-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $path = New-BackupPath -Directory $tempDir
        Assert-True -Value ($path -match 'BraveDebloater-\d{8}-\d{6}-\d{3}') -Context 'path format'
        Assert-True -Value ($path.StartsWith($tempDir)) -Context 'path under directory'
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}

Run-Test 'New-BackupPath: appends suffix for existing file' {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('UnitTest-NewBak2-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $first = New-BackupPath -Directory $tempDir
        Set-Content -LiteralPath $first -Value '{}' -Encoding UTF8
        $second = New-BackupPath -Directory $tempDir
        Assert-True -Value ($first -ne $second) -Context 'unique paths'
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}

# ---------------------------------------------------------------------------
# Set-JsonFileContent
# ---------------------------------------------------------------------------
Run-Test 'Set-JsonFileContent: writes JSON atomically' {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('UnitTest-Json-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $path = Join-Path $tempDir 'test.json'
        $obj = [ordered]@{ key = 'value'; number = 42 }
        Set-JsonFileContent -Path $path -Object $obj
        Assert-True -Value (Test-Path -LiteralPath $path) -Context 'file exists'
        $content = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Assert-Equal -Actual $content.key -Expected 'value' -Context 'json key'
        Assert-Equal -Actual $content.number -Expected 42 -Context 'json number'
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}

Run-Test 'Set-JsonFileContent: creates parent directory' {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('UnitTest-Json2-{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        $path = Join-Path (Join-Path $tempDir 'sub') 'nested.json'
        Set-JsonFileContent -Path $path -Object @{ a = 1 }
        Assert-True -Value (Test-Path -LiteralPath $path) -Context 'nested file exists'
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force
        }
    }
}

# ---------------------------------------------------------------------------
# Get-BraveProfilePreferenceFiles
# ---------------------------------------------------------------------------
Run-Test 'Get-BraveProfilePreferenceFiles: finds Preferences files' {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('UnitTest-Profile-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $profile1 = Join-Path $tempDir 'Default'
        $profile2 = Join-Path $tempDir 'Profile 1'
        $profile3 = Join-Path $tempDir 'EmptyProfile'
        New-Item -ItemType Directory -Path $profile1 -Force | Out-Null
        New-Item -ItemType Directory -Path $profile2 -Force | Out-Null
        New-Item -ItemType Directory -Path $profile3 -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $profile1 'Preferences') -Value '{}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $profile2 'Preferences') -Value '{}' -Encoding UTF8
        $files = @(Get-BraveProfilePreferenceFiles -Root $tempDir)
        Assert-Equal -Actual $files.Count -Expected 2 -Context 'found 2 Preferences files'
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}

Run-Test 'Get-BraveProfilePreferenceFiles: returns empty for missing root' {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('UnitTest-Missing2-{0}' -f [guid]::NewGuid().ToString('N'))
    $files = @(Get-BraveProfilePreferenceFiles -Root $tempDir)
    Assert-Equal -Actual $files.Count -Expected 0 -Context 'missing root count'
}

# ---------------------------------------------------------------------------
# Test-PathIsUnderDirectory
# ---------------------------------------------------------------------------
Run-Test 'Test-PathIsUnderDirectory: child path returns true' {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('UnitTest-Path-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $child = Join-Path (Join-Path $tempDir 'sub') 'file.txt'
        $result = Test-PathIsUnderDirectory -Path $child -Directory $tempDir
        Assert-True -Value $result -Context 'child path under dir'
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}

Run-Test 'Test-PathIsUnderDirectory: sibling path returns false' {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('UnitTest-PathA-{0}' -f [guid]::NewGuid().ToString('N'))
    $siblingDir = Join-Path ([System.IO.Path]::GetTempPath()) ('UnitTest-PathB-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    New-Item -ItemType Directory -Path $siblingDir -Force | Out-Null
    try {
        $child = Join-Path $siblingDir 'file.txt'
        $result = Test-PathIsUnderDirectory -Path $child -Directory $tempDir
        Assert-False -Value $result -Context 'sibling not under dir'
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
        Remove-Item -LiteralPath $siblingDir -Recurse -Force
    }
}

# ---------------------------------------------------------------------------
# Get-FullFileSystemPath
# ---------------------------------------------------------------------------
Run-Test 'Get-FullFileSystemPath: resolves relative-like path' {
    $result = Get-FullFileSystemPath -Path '/tmp/test'
    Assert-True -Value ($result.Length -gt 0) -Context 'non-empty result'
    Assert-True -Value ([System.IO.Path]::IsPathRooted($result)) -Context 'result is rooted'
}

Run-Test 'Get-FullFileSystemPath: empty path throws' {
    Assert-Throws -ScriptBlock { Get-FullFileSystemPath -Path '' } -Pattern 'empty' -Context 'empty path'
}

# ---------------------------------------------------------------------------
# Resolve-FeatureSelection (integration of feature selection logic)
# ---------------------------------------------------------------------------
Run-Test 'Resolve-FeatureSelection: selects features matching preset policies' {
    $features = @(
        [pscustomobject]@{ id = 'Rewards'; policies = @('BraveRewardsDisabled'); defaultPresets = @() },
        [pscustomobject]@{ id = 'Wallet'; policies = @('BraveWalletDisabled'); defaultPresets = @() }
    )
    $featureMap = @{ Rewards = $features[0]; Wallet = $features[1] }
    $policyNames = New-Object System.Collections.Generic.List[string]
    $policyNames.Add('BraveRewardsDisabled')
    $result = @(Resolve-FeatureSelection -Features $features -FeatureMap $featureMap -PolicyNames $policyNames -PresetName 'Core')
    Assert-True -Value ($result -contains 'Rewards') -Context 'Rewards selected'
    Assert-False -Value ($result -contains 'Wallet') -Context 'Wallet not selected'
}

Run-Test 'Resolve-FeatureSelection: IncludeNames adds feature' {
    $features = @(
        [pscustomobject]@{ id = 'Rewards'; policies = @('BraveRewardsDisabled'); defaultPresets = @() },
        [pscustomobject]@{ id = 'Wallet'; policies = @('BraveWalletDisabled'); defaultPresets = @() }
    )
    $featureMap = @{ Rewards = $features[0]; Wallet = $features[1] }
    $policyNames = New-Object System.Collections.Generic.List[string]
    $result = @(Resolve-FeatureSelection -Features $features -FeatureMap $featureMap -PolicyNames $policyNames -PresetName 'Core' -IncludeNames @('Wallet'))
    Assert-True -Value ($result -contains 'Wallet') -Context 'Wallet included'
    Assert-True -Value ($policyNames.Contains('BraveWalletDisabled')) -Context 'Wallet policy added'
}

Run-Test 'Resolve-FeatureSelection: ExcludeNames removes feature' {
    $features = @(
        [pscustomobject]@{ id = 'Rewards'; policies = @('BraveRewardsDisabled'); defaultPresets = @() }
    )
    $featureMap = @{ Rewards = $features[0] }
    $policyNames = New-Object System.Collections.Generic.List[string]
    $policyNames.Add('BraveRewardsDisabled')
    $result = @(Resolve-FeatureSelection -Features $features -FeatureMap $featureMap -PolicyNames $policyNames -PresetName 'Core' -ExcludeNames @('Rewards'))
    Assert-False -Value ($result -contains 'Rewards') -Context 'Rewards excluded'
    Assert-False -Value ($policyNames.Contains('BraveRewardsDisabled')) -Context 'Rewards policy removed'
}

# ---------------------------------------------------------------------------
# Assert-BackupPolicyList
# ---------------------------------------------------------------------------
Run-Test 'Assert-BackupPolicyList: valid backup passes' {
    $backup = [pscustomobject]@{
        policies = @(
            [pscustomobject]@{ name = 'BraveRewardsDisabled'; existed = $false; value = $null; kind = $null }
        )
    }
    $policyDefs = @{ BraveRewardsDisabled = [pscustomobject]@{ type = 'DWord' } }
    Assert-BackupPolicyList -Backup $backup -PolicyDefinitions $policyDefs
}

Run-Test 'Assert-BackupPolicyList: unmanaged policy throws' {
    $backup = [pscustomobject]@{
        policies = @(
            [pscustomobject]@{ name = 'UnknownPolicy'; existed = $false; value = $null; kind = $null }
        )
    }
    $policyDefs = @{ BraveRewardsDisabled = [pscustomobject]@{ type = 'DWord' } }
    Assert-Throws -ScriptBlock {
        Assert-BackupPolicyList -Backup $backup -PolicyDefinitions $policyDefs
    } -Pattern 'not managed' -Context 'unmanaged policy'
}

Run-Test 'Assert-BackupPolicyList: non-boolean existed throws' {
    $backup = [pscustomobject]@{
        policies = @(
            [pscustomobject]@{ name = 'BraveRewardsDisabled'; existed = 'yes'; value = $null; kind = $null }
        )
    }
    $policyDefs = @{ BraveRewardsDisabled = [pscustomobject]@{ type = 'DWord' } }
    Assert-Throws -ScriptBlock {
        Assert-BackupPolicyList -Backup $backup -PolicyDefinitions $policyDefs
    } -Pattern 'non-boolean' -Context 'non-boolean existed'
}

Run-Test 'Assert-BackupPolicyList: existed with kind mismatch throws' {
    $backup = [pscustomobject]@{
        policies = @(
            [pscustomobject]@{ name = 'BraveRewardsDisabled'; existed = $true; value = 1; kind = 'String' }
        )
    }
    $policyDefs = @{ BraveRewardsDisabled = [pscustomobject]@{ type = 'DWord' } }
    Assert-Throws -ScriptBlock {
        Assert-BackupPolicyList -Backup $backup -PolicyDefinitions $policyDefs
    } -Pattern 'does not match' -Context 'kind mismatch'
}

Run-Test 'Assert-BackupPolicyList: existed DWord with non-integer value throws' {
    $backup = [pscustomobject]@{
        policies = @(
            [pscustomobject]@{ name = 'BraveRewardsDisabled'; existed = $true; value = 'notanint'; kind = 'DWord' }
        )
    }
    $policyDefs = @{ BraveRewardsDisabled = [pscustomobject]@{ type = 'DWord' } }
    Assert-Throws -ScriptBlock {
        Assert-BackupPolicyList -Backup $backup -PolicyDefinitions $policyDefs
    } -Pattern 'non-integer' -Context 'DWord non-integer'
}

Run-Test 'Assert-BackupPolicyList: existed String with non-string value throws' {
    $backup = [pscustomobject]@{
        policies = @(
            [pscustomobject]@{ name = 'TestStringPolicy'; existed = $true; value = 123; kind = 'String' }
        )
    }
    $policyDefs = @{ TestStringPolicy = [pscustomobject]@{ type = 'String' } }
    Assert-Throws -ScriptBlock {
        Assert-BackupPolicyList -Backup $backup -PolicyDefinitions $policyDefs
    } -Pattern 'non-string' -Context 'String non-string'
}

# ---------------------------------------------------------------------------
# Assert-BackupObject
# ---------------------------------------------------------------------------
Run-Test 'Assert-BackupObject: valid backup passes' {
    $manifest = Get-Manifest
    $backup = [pscustomobject]@{
        schemaVersion = 1
        registryPath = 'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave'
        policies = @(
            [pscustomobject]@{ name = 'BraveRewardsDisabled'; existed = $false; value = $null; kind = $null }
        )
        profileFiles = @()
    }
    Assert-BackupObject -Backup $backup -Manifest $manifest -BackupPath '/tmp/fake-backup.json' -ProfileRoot '/tmp/profiles'
}

Run-Test 'Assert-BackupObject: wrong schema version throws' {
    $manifest = Get-Manifest
    $backup = [pscustomobject]@{
        schemaVersion = 99
        registryPath = 'Registry::HKEY_CURRENT_USER\Software\Policies\BraveSoftware\Brave'
        policies = @()
    }
    Assert-Throws -ScriptBlock {
        Assert-BackupObject -Backup $backup -Manifest $manifest -BackupPath '/tmp/fake.json' -ProfileRoot '/tmp/profiles'
    } -Pattern 'Unsupported backup schema' -Context 'wrong schema version'
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
if ($failed -eq 0) {
    Write-Host "Unit tests passed: $passed/$($passed + $failed)."
}
else {
    throw "Unit tests: $passed passed, $failed failed."
}
