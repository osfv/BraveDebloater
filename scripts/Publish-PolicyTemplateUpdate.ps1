#requires -Version 5.1
<#
.SYNOPSIS
Publishes what the weekly Brave policy template check found: a pull request from automation/policy-templates, or
one issue when GitHub Actions may not open pull requests in this repository.

.DESCRIPTION
Runs in .github/workflows/policy-templates.yml after Compare-PolicyTemplates.ps1 -Update and
Update-PolicyTemplateVersion.ps1 rewrote the working tree on -BaseBranch.

With -TemplatesChanged, it commits those files to -Branch and force-pushes it, unless a maintainer pushed commits
there. It then edits the open pull request from -Branch or creates one. When GitHub refuses with "not permitted to
create or approve pull requests", it opens or updates a single issue that carries a hidden marker, with the
comparison and a link to open the pull request. Any other failure stops the script.

Every run then closes that issue once it is done: a pull request from -Branch is open, or the templates did not
change, which means -BaseBranch already records the latest templates.

-ToolRunner replaces the git and gh calls in tests. It receives the tool name and its arguments and returns an
object with ExitCode and Text.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Repository,
    [switch]$TemplatesChanged,
    [string]$SummaryPath,
    [string]$ServerUrl = 'https://github.com',
    [string]$Branch = 'automation/policy-templates',
    [string]$BaseBranch = 'main',
    [string]$WorkDirectory = [System.IO.Path]::GetTempPath(),
    [scriptblock]$ToolRunner
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$marker = '<!-- brave-policy-template-check -->'
$botEmail = '41898282+github-actions[bot]@users.noreply.github.com'
$changedFiles = @('config/policies.json', 'config/policy-template-snapshot.json', 'docs/debloatable-validation.md')
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($null -eq $ToolRunner) {
    $ToolRunner = {
        param([string]$Name, [string[]]$Arguments)
        # Native stderr must not stop the script under Windows PowerShell; Invoke-Tool checks the exit code.
        $ErrorActionPreference = 'Continue'
        $text = @(& $Name @Arguments 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text }
    }
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    $result = & $ToolRunner $Name $Arguments
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        throw "$Name $($Arguments -join ' ') failed with exit code $($result.ExitCode): $($result.Text)"
    }
    return $result
}

# gh prints one JSON object per line with --jq '.[]', which parses the same way in every PowerShell version.
function ConvertFrom-JsonLines {
    param([string]$Text)

    foreach ($line in @($Text -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            ConvertFrom-Json -InputObject $line
        }
    }
}

function Get-OpenPullRequest {
    $result = Invoke-Tool -Name 'gh' -Arguments @('pr', 'list', '--repo', $Repository, '--head', $Branch, '--state', 'open', '--json', 'number,url', '--jq', '.[]')
    return @(ConvertFrom-JsonLines -Text $result.Text) | Select-Object -First 1
}

function Get-TrackingIssue {
    # Reads every page of open issues. The issues endpoint lists pull requests too, so those are skipped.
    $result = Invoke-Tool -Name 'gh' -Arguments @('api', '--paginate', "repos/$Repository/issues?state=open&per_page=100", '--jq', '.[]')
    foreach ($item in @(ConvertFrom-JsonLines -Text $result.Text)) {
        if ($null -ne $item.PSObject.Properties['pull_request']) {
            continue
        }
        $body = if ($null -ne $item.PSObject.Properties['body'] -and $null -ne $item.body) { [string]$item.body } else { '' }
        if ($body.Contains($marker)) {
            return $item
        }
    }
    return $null
}

function Write-BodyFile {
    param([string]$Name, [string[]]$Lines)

    $path = Join-Path $WorkDirectory $Name
    [System.IO.File]::WriteAllText($path, (($Lines -join "`n") + "`n"), $utf8NoBom)
    return $path
}

function Publish-TemplateUpdate {
    $summary = ''
    if (-not [string]::IsNullOrWhiteSpace($SummaryPath) -and (Test-Path -LiteralPath $SummaryPath)) {
        $summary = [System.IO.File]::ReadAllText($SummaryPath).TrimEnd()
    }
    $title = "Update Brave policy templates to $Version"
    $pullRequestBody = Write-BodyFile -Name 'policy-template-pr.md' -Lines @(
        $summary
        ''
        'Opened by the weekly policy template check. Review new policies before adding any of them to config/policies.json. CI does not run automatically on PRs opened by GitHub Actions; close and reopen this PR to start it.'
    )

    Invoke-Tool -Name 'git' -Arguments @('config', 'user.name', 'github-actions[bot]') | Out-Null
    Invoke-Tool -Name 'git' -Arguments @('config', 'user.email', $botEmail) | Out-Null
    $pullRequest = Get-OpenPullRequest

    # Never overwrite commits a maintainer pushed to the automation branch.
    $fetch = Invoke-Tool -Name 'git' -Arguments @('fetch', '--quiet', 'origin', $Branch) -AllowFailure
    if ($fetch.ExitCode -eq 0) {
        $log = Invoke-Tool -Name 'git' -Arguments @('log', '--format=%ae', "origin/$BaseBranch..FETCH_HEAD")
        $others = @(@($log.Text -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.Trim() -ne $botEmail })
        if ($others.Count -gt 0) {
            Write-Host "::warning::$Branch has maintainer commits, so it was not updated. Merge or close that pull request to get the next update."
            if ($null -ne $pullRequest) {
                $comment = Write-BodyFile -Name 'policy-template-comment.md' -Lines @(
                    "Newer Brave policy templates ($Version) are available, but this branch has maintainer commits, so the weekly check did not overwrite it. Summary for ${Version}:"
                    ''
                    $summary
                )
                Invoke-Tool -Name 'gh' -Arguments @('pr', 'comment', [string]$pullRequest.number, '--repo', $Repository, '--body-file', $comment) | Out-Null
            }
            return
        }
    }

    Invoke-Tool -Name 'git' -Arguments @('checkout', '-B', $Branch) | Out-Null
    Invoke-Tool -Name 'git' -Arguments (@('add', '--') + $changedFiles) | Out-Null
    Invoke-Tool -Name 'git' -Arguments @('commit', '-m', $title) | Out-Null
    Invoke-Tool -Name 'git' -Arguments @('push', '--force', 'origin', $Branch) | Out-Null

    if ($null -ne $pullRequest) {
        Invoke-Tool -Name 'gh' -Arguments @('pr', 'edit', [string]$pullRequest.number, '--repo', $Repository, '--title', $title, '--body-file', $pullRequestBody) | Out-Null
        Write-Host "Updated pull request #$($pullRequest.number)."
        return
    }

    $create = Invoke-Tool -Name 'gh' -Arguments @('pr', 'create', '--repo', $Repository, '--base', $BaseBranch, '--head', $Branch, '--title', $title, '--body-file', $pullRequestBody) -AllowFailure
    if ($create.ExitCode -eq 0) {
        Write-Host "Opened $($create.Text.Trim())"
        return
    }
    if ($create.Text -notmatch 'not permitted to create or approve pull requests') {
        throw "gh pr create failed with exit code $($create.ExitCode): $($create.Text)"
    }

    $compareUrl = "$ServerUrl/$Repository/compare/$BaseBranch...${Branch}?expand=1"
    $issueTitle = "Brave policy templates $Version are available"
    $issueBody = Write-BodyFile -Name 'policy-template-issue.md' -Lines @(
        $marker
        "Brave policy templates **$Version** are available. The weekly check pushed the update to ``$Branch``, but this repository does not let GitHub Actions open pull requests."
        ''
        "**[Open the pull request]($compareUrl)**, or turn on *Settings > Actions > General > Allow GitHub Actions to create and approve pull requests* so the check opens it next time. This issue closes itself once a pull request from ``$Branch`` is open."
        ''
        $summary
    )
    $issue = Get-TrackingIssue
    if ($null -ne $issue) {
        Invoke-Tool -Name 'gh' -Arguments @('issue', 'edit', [string]$issue.number, '--repo', $Repository, '--title', $issueTitle, '--body-file', $issueBody) | Out-Null
        Write-Host "Updated issue #$($issue.number)."
    }
    else {
        $created = Invoke-Tool -Name 'gh' -Arguments @('issue', 'create', '--repo', $Repository, '--title', $issueTitle, '--body-file', $issueBody)
        Write-Host "Opened $($created.Text.Trim())"
    }
    Write-Host "::warning::GitHub Actions may not open pull requests in this repository, so the update for $Version was reported in an issue. Open the pull request: $compareUrl"
}

function Close-FinishedTrackingIssue {
    $issue = Get-TrackingIssue
    if ($null -eq $issue) {
        return
    }
    $pullRequest = Get-OpenPullRequest
    $reason = $null
    if ($null -ne $pullRequest) {
        $reason = "Pull request #$($pullRequest.number) from ``$Branch`` now tracks this update."
    }
    elseif (-not $TemplatesChanged) {
        $reason = "``$BaseBranch`` already records Brave policy templates $Version, so nothing is left to merge."
    }
    if ($null -ne $reason) {
        Invoke-Tool -Name 'gh' -Arguments @('issue', 'close', [string]$issue.number, '--repo', $Repository, '--comment', $reason) | Out-Null
        Write-Host "Closed issue #$($issue.number). $reason"
    }
}

if ($TemplatesChanged) {
    Publish-TemplateUpdate
}
Close-FinishedTrackingIssue
