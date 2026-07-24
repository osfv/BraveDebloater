# BraveDebloater

![Brave](https://img.shields.io/badge/Brave-FB542B?style=flat-square&logo=brave&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-0078D4?style=flat-square&logo=windows&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-000000?style=flat-square&logo=apple&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=flat-square&logo=linux&logoColor=black)
![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=flat-square&logo=powershell&logoColor=white)
[![CI](https://img.shields.io/github/actions/workflow/status/osfv/BraveDebloater/ci.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=CI)](https://github.com/osfv/BraveDebloater/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/osfv/BraveDebloater?style=flat-square&label=license)](LICENSE)

<p align="center">
  <img src="assets/screenshots/brave-new-tab.jpg" alt="Brave Browser new tab page with Shields stats visible" width="100%" />
</p>

<p>
  <img src="assets/icons/brave.svg" width="18" alt="Brave logo" />
  <strong>BraveDebloater</strong> removes Brave Browser extras with Brave and Chromium enterprise policies.
</p>

<p>
  <img src="assets/icons/windows.svg" width="16" alt="Windows logo" /> Windows/macOS/Linux
  &nbsp;·&nbsp;
  <img src="assets/icons/powershell.svg" width="16" alt="PowerShell logo" /> PowerShell runtime
  &nbsp;·&nbsp;
  <img src="assets/icons/opensource.svg" width="16" alt="Open Source Initiative logo" /> Open source
</p>

The script starts in preview mode. Nothing changes until you add `-Apply`.

Before an apply run, BraveDebloater writes a backup unless you use `-NoBackup` for policy-only changes. It does not disable Brave updates, edit hosts files, remove extensions, turn off Brave Shields, or add Shield allowlists.

PowerShell is the cross-platform runtime. The files it writes are native to each platform: Windows registry policies, macOS defaults or plist payloads, and Linux JSON policy files.

## What It Can Remove

Brave-specific surfaces:

- Rewards, Wallet, VPN, Leo AI Chat, News, Talk, Playlist, Email Aliases, IPFS, Speedreader, and Wayback prompts

Telemetry and suggestions:

- Brave P3A, stats ping, Web Discovery, Chromium metrics, URL-keyed collection, Privacy Sandbox prompts, remote search suggestions, network prediction, and remote spellcheck

Extra UI in the `Extreme` preset:

- Background mode, promotions, Browser Labs, new tab cards, shopping list, QR generator, translate prompts, autofill, and the Google search side panel

Optional profile preference cleanup can also hide some new tab, sponsored background, and toolbar surfaces. That part edits per-profile `Preferences` JSON, so close Brave before applying it.

## Install

Download the latest release from the repository's Releases page, then extract the zip to a folder you control, such as `Downloads\BraveDebloater`.

Open PowerShell in that folder and run the default dry-run:

```powershell
.\Invoke-BraveDebloat.ps1
```

Review the output before applying changes. To verify a release archive first, download `SHA256SUMS.txt` from the same release and compare it with:

```powershell
Get-FileHash .\BraveDebloater-vX.Y.Z.zip -Algorithm SHA256
```

## Start Here

Preview the default cleanup first:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme
```

Read the output. If it looks right, apply it:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -Apply
```

After applying, restart Brave. Then open `brave://policy` and check that the policies loaded.

## Command Output Screenshots

These captures show sanitized, read-only output from the local PowerShell entrypoint:

| Command | Capture |
| --- | --- |
| Default dry-run | [Preview output](assets/screenshots/default-dry-run.png) |
| `-Doctor` | [Doctor report](assets/screenshots/doctor.png) |
| `-ListFeatures` | [Feature list](assets/screenshots/list-features.png) |

The examples use the Linux policy target with temporary paths so they contain no personal machine paths or policy changes. Each image is a native macOS Terminal capture of the visible output viewport; long reports continue below the captured viewport.

## Common Tasks

See what would be changed, including profile preference patches:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -List -IncludeProfilePreferences
```

See the feature names you can include or exclude:

```powershell
.\Invoke-BraveDebloat.ps1 -ListFeatures
```

Run a read-only health check:

```powershell
.\Invoke-BraveDebloat.ps1 -Doctor
```

List backups or preview retention cleanup:

```powershell
.\Invoke-BraveDebloat.ps1 -ListBackups
.\Invoke-BraveDebloat.ps1 -PruneBackupsOlderThanDays 30
.\Invoke-BraveDebloat.ps1 -KeepLatestBackups 10
```

Add `-Apply` only after the preview lists the backups you expect to delete.

Apply the default cleanup and lock a safe Shields baseline:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -LockShields -Apply
```

Choose features one by one:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -Customize
```

Use exact feature choices in scripts:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -ExcludeFeature News,LeoAI
.\Invoke-BraveDebloat.ps1 -Preset Standard -IncludeFeature Translate
.\Invoke-BraveDebloat.ps1 -OnlyFeature Rewards,Wallet,VPN
```

Use PowerShell `-WhatIf` when you want a no-write preview even with `-Apply` present:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -Apply -WhatIf
```

## Platform Support

Windows writes Brave policy values under the current-user or local-machine registry policy key.

To target another loaded Windows user's policy hive from an elevated PowerShell session, read that user's SID with `whoami /user` and pass it explicitly:

```powershell
.\Invoke-BraveDebloat.ps1 -Platform Windows -UserSid S-1-5-21-1000-2000-3000-1001 -Preset Extreme
.\Invoke-BraveDebloat.ps1 -Platform Windows -UserSid S-1-5-21-1000-2000-3000-1001 -Preset Extreme -Apply
```

The target is exactly `HKEY_USERS\<SID>\Software\Policies\BraveSoftware\Brave`. The hive must already be loaded, and restores require the same explicit `-UserSid`; `-PolicyPath` cannot authorize an `HKEY_USERS` restore. Pass that user's `-ProfileRoot` explicitly when also using `-IncludeProfilePreferences`.

macOS current-user mode uses `defaults write com.brave.Browser`. macOS machine-wide mode writes `/Library/Managed Preferences/com.brave.Browser.plist`.

Linux writes JSON policy values to `/etc/brave/policies/managed/BraveDebloater.json`.

Android and iOS/iPadOS do not support local writes from this script. Use `-ExportPolicyPath` to create an MDM payload. Brave documents limited iOS/iPadOS support for Playlist, VPN, News, Talk, Rewards, and AI Chat policies.

Examples:

```powershell
.\Invoke-BraveDebloat.ps1 -Platform macOS -Preset Extreme -Apply
.\Invoke-BraveDebloat.ps1 -Platform Linux -Preset Extreme -Apply
.\Invoke-BraveDebloat.ps1 -Platform Linux -Preset Extreme -ExportPolicyPath .\brave-policy.json
.\Invoke-BraveDebloat.ps1 -Platform iOS -OnlyFeature Rewards -ExportPolicyPath .\brave-ios.mobileconfig
.\Invoke-BraveDebloat.ps1 -Platform Android -OnlyFeature Rewards -ExportPolicyPath .\brave-android-mdm.json
```

Use `-PolicyPath` when testing, or when your managed Linux/macOS policy file lives somewhere custom.

## Brave Channels

Profile preference cleanup targets Brave Stable by default. Use `-Channel` when you want the default profile path for Beta or Nightly:

```powershell
.\Invoke-BraveDebloat.ps1 -Channel Beta -IncludeProfilePreferences
.\Invoke-BraveDebloat.ps1 -Channel Nightly -IncludeProfilePreferences
```

Stable policy behavior is unchanged. `-ProfileRoot` still overrides the detected profile path.

## Presets

`Standard` removes Brave-specific bloat and Brave telemetry.

`High` includes `Standard` and adds privacy-preserving policy defaults.

`Extreme` includes `High` and removes more UI and convenience surfaces.

`Core`, `Privacy`, and `Aggressive` are aliases for `Standard`, `High`, and `Extreme`.

`-LockShields` is an optional add-on. It enforces default ad blocking, standard fingerprinting protection, HTTPS upgrades, and stricter referrer behavior.

By default, the tool uses `Extreme` and does not lock Shields. It refuses to apply policies that disable Shields, add Shield-disabled URLs, weaken Safe Browsing, or disable updates.

## Feature Toggles

Use `-Customize` for an interactive yes/no prompt for each cleanup.

Use `-IncludeFeature` and `-ExcludeFeature` for repeatable commands.

Use `-OnlyFeature` when you want exactly the named cleanups without starting from a preset.

Feature names are shown by `-ListFeatures`. Examples include `Rewards`, `Wallet`, `VPN`, `LeoAI`, `News`, `Talk`, `EmailAliases`, `IPFS`, `Autofill`, `Translate`, and `GoogleSearchSidePanel`.

When `-IncludeProfilePreferences` is combined with custom feature choices, profile preference patches are filtered to the selected features.

## Doctor Mode

Use `-Doctor` when you want to inspect Brave without changing anything.

It checks policy locations, detected feature status, unknown Brave policies, protected policy names, Brave process state, profile preference files, and backups.

This helps after testing other debloat tools. Machine-wide policies can make Brave settings appear managed for every Windows user, even when current-user policies look empty.

## Profile Preferences

Policies are the main path because Brave shows them in `brave://policy`.

Some cosmetic cleanup lives in each Brave profile instead. Close Brave first, then run:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -IncludeProfilePreferences -Apply
```

If Brave is running, profile preference cleanup is skipped. This avoids writing files that Brave may overwrite.

## Restore

Every applied run creates a JSON backup in `backups/` unless `-NoBackup` is used for policy-only changes.

Preview a restore:

```powershell
.\Invoke-BraveDebloat.ps1 -UndoFromBackup .\backups\BraveDebloater-YYYYMMDD-HHMMSS-fff.json
```

Apply a restore:

```powershell
.\Invoke-BraveDebloat.ps1 -UndoFromBackup .\backups\BraveDebloater-YYYYMMDD-HHMMSS-fff.json -Apply
```

Restore validates the backup before it writes. Registry restores are limited to Brave policy keys. Profile file restores are limited to `Preferences` files under the selected `-ProfileRoot`.

## Machine-Wide Mode

Current-user policy is the default and does not require administrator/root rights.

For machine-wide policy, run PowerShell as administrator/root:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -Scope LocalMachine -Apply
```

## Sources

Policy names and values come from Brave's official Group Policy documentation and Brave policy templates:

- <https://support.brave.app/hc/en-us/articles/360039248271-Group-Policy>
- <https://brave-browser-downloads.s3.brave.com/latest/policy_templates.zip>

See `docs/debloatable-validation.md` for the source version, the policy choices, and the validation commands.

See `ROADMAP.md` for planned safety, testing, release trust, user experience, and maintainability work.

## Release Checksums

Generate SHA256 checksums for release artifacts before publishing:

```powershell
.\scripts\New-ReleaseChecksums.ps1 -Path .\BraveDebloater-vX.Y.Z.zip -OutputPath .\SHA256SUMS.txt
```

Upload `SHA256SUMS.txt` beside the release archive.

## Project Checks

Run the local checks:

```powershell
.\scripts\Test-PolicyManifest.ps1
.\scripts\Test-Behavior.ps1
```

Validate against a downloaded Brave policy template zip:

```powershell
.\scripts\Test-LatestPolicyTemplates.ps1 -TemplateZipPath .\policy_templates.zip
```

Update the recorded template version after downloading a newer official zip:

```powershell
.\scripts\Update-PolicyTemplateVersion.ps1 -TemplateZipPath .\policy_templates.zip
```

## Pull Request Review

Greptile review guidance lives in `greptile.json`. It covers PowerShell compatibility, policy writes, registry writes, profile JSON writes, and feature-toggle behavior.
