# Contributing

[![Contributions welcome](https://img.shields.io/badge/contributions-welcome-2ea44f?style=flat-square&logo=github&logoColor=white)](https://github.com/osfv/BraveDebloater/issues)

Thanks for helping make BraveDebloater safer and cleaner.

## Rules For Policy Changes

- Prefer official Brave or Chromium enterprise policies over profile JSON edits.
- Do not add policies that disable Brave Shields, whitelist URLs from Shields, weaken Safe Browsing, or disable browser/component updates.
- Add every policy to `config/policies.json` with a clear category and reason.
- Add or update a friendly feature toggle when a policy should be user-selectable.
- Keep dry-run output understandable for non-experts.
- Keep restore behavior working whenever a new write path is added.
- Treat `-List` and `-WhatIf` as read-only paths.

## AI Agent And LLM Contributions

If an AI agent, coding assistant, or autonomous workflow changes this repository, it must follow `AGENTS.md`.

Agent-made changes must stay coherent across code, docs, tests, and configuration. If a change touches policy behavior, platform behavior, restore behavior, user-facing output, or CI, update every affected file in the same pull request.

Do not submit agent output that only patches the visible symptom. Trace the shared path, fix the common cause, and run the checks below.

## Checks

New behavior needs a test in the same pull request: a Pester test in `tests/` or a case in `scripts/Test-Behavior.ps1`. Bug fixes should add a test that fails without the fix.

Before opening a pull request, run:

```powershell
.\scripts\Test-PolicyManifest.ps1
.\scripts\Test-Behavior.ps1
.\Invoke-BraveDebloat.ps1 -Preset Extreme -LockShields
```

The second command should stay a dry-run unless you pass `-Apply`.

## Policy Template Checks

Validate against a downloaded Brave policy template zip:

```powershell
.\scripts\Test-LatestPolicyTemplates.ps1 -TemplateZipPath .\policy_templates.zip
```

Every Monday, `.github/workflows/policy-templates.yml` downloads the latest templates and compares them with `config/policy-template-snapshot.json`. When Brave adds, removes, or deprecates a policy, or ships a new template version, it opens or updates one pull request from `automation/policy-templates` that records the new snapshot and version and lists the changed policies. It flags any policy BraveDebloater manages that Brave removed or deprecated. To run the same comparison locally:

```powershell
.\scripts\Compare-PolicyTemplates.ps1 -TemplateZipPath .\policy_templates.zip
```

Each run also writes the comparison to its run page. When the templates changed, it adds the manifest validation result. With **Settings > Actions > General > Allow GitHub Actions to create and approve pull requests** turned off, GitHub Actions cannot open the pull request, so the workflow still pushes `automation/policy-templates` and opens or updates one issue with the comparison and a link to open the pull request yourself. Later runs close that issue once a pull request from the branch is open, or once `main` records the latest templates. `scripts/Publish-PolicyTemplateUpdate.ps1` does the publishing.

A zip newer than the recorded template version passes with a warning, because Brave's `latest` download changes with every release. Add `-RequireVersionMatch` before a release so the recorded version is exact. The check also confirms each manifest value fits the ADMX definition (boolean, enum, integer, or text).

Update the recorded template version after downloading a newer official zip:

```powershell
.\scripts\Update-PolicyTemplateVersion.ps1 -TemplateZipPath .\policy_templates.zip
```

## Releasing

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`. It reruns the project checks on Windows, Ubuntu, macOS, and Windows PowerShell 5.1 against the tagged commit and compiles `BraveDebloat.exe` from `packaging/launcher/BraveDebloat.cs`, and only then confirms the tag matches `$ToolVersion` in `Invoke-BraveDebloat.ps1` and has a `## X.Y.Z - <date>` section in `CHANGELOG.md`, builds `BraveDebloater-vX.Y.Z.zip` from the tagged tree and `BraveDebloater-vX.Y.Z-windows.zip` (same tree, flattened, plus the launcher), writes `SHA256SUMS.txt`, signs a build provenance for both archives (`BraveDebloater-vX.Y.Z.sigstore.json`), and publishes the GitHub release with that changelog section as the notes. It also stores ready-to-submit winget and Scoop manifests in the run's `package-manifests` artifact, and opens the winget-pkgs pull request when a `WINGET_TOKEN` secret exists.

```powershell
git tag -a vX.Y.Z -m "BraveDebloater vX.Y.Z"
git push origin vX.Y.Z
```

After the release is published, refresh the committed Scoop manifest (and the winget manifests, if you keep them in the repository) from the release checksums and commit the result:

```powershell
.\scripts\New-PackageManifests.ps1 -Version X.Y.Z
```

To build checksums by hand, for example for a manually assembled archive:

```powershell
.\scripts\New-ReleaseChecksums.ps1 -Path .\BraveDebloater-vX.Y.Z.zip -OutputPath .\SHA256SUMS.txt
```

## Pull Request Review

Greptile review guidance lives in `greptile.json`. It covers PowerShell compatibility, policy writes, registry writes, profile JSON writes, and feature-toggle behavior.
