<p align="center">
  <img src="assets/icons/debloater.png" alt="BraveDebloater" width="180" />
</p>

# BraveDebloater <a href="https://www.producthunt.com/products/bravedebloater?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-bravedebloater" target="_blank" rel="noopener noreferrer"><img alt="BraveDebloater - A safer, reversible debloater for Brave Browser | Product Hunt" width="200" height="48" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1254570&amp;theme=dark&amp;t=1789727875338"></a>

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

Before an apply run, BraveDebloater writes a backup unless you use `-NoBackup` for policy-only changes.

PowerShell is the cross-platform runtime. The files it writes are native to each platform: Windows registry policies, macOS defaults or plist payloads, and Linux JSON policy files.

## What It Does Not Do

- It does not disable Brave updates. Update policies are on the blocklist and the tool refuses to write them.
- It does not turn off Brave Shields, add Shield allowlists, or weaken Safe Browsing. The optional `-LockShields` add-on only enforces stricter Shields defaults.
- It does not edit your hosts file, remove extensions, patch Brave binaries, or install anything into Brave.
- It does not run hidden. Every policy it sets is listed in `brave://policy` with its value, and `-Doctor` reports the current state read-only.
- It does not change anything without `-Apply`. Unless you use `-NoBackup` for a policy-only run, every apply run leaves a JSON backup that `-UndoFromBackup` can restore.

## What It Can Remove

Brave-specific surfaces:

- Rewards, Wallet, VPN, Leo AI Chat, News, Talk, Playlist, Email Aliases, Speedreader, and Wayback prompts

Telemetry and suggestions:

- Brave P3A, stats ping, Web Discovery, Chromium metrics, URL-keyed collection, remote search suggestions, network prediction, and remote spellcheck

Extra UI in the `Extreme` preset:

- Background mode, promotions, Browser Labs, new tab cards, shopping list, QR generator, translate prompts, autofill, and the Google search side panel

Optional profile preference cleanup can also hide some new tab, sponsored background, and toolbar surfaces. That part edits per-profile `Preferences` JSON, so close Brave before applying it.

Optional DNS control (`-DnsOverHttps`) sets Brave's DNS-over-HTTPS mode to off, automatic, or secure with a resolver you choose, or removes those policies again.

## Disable One Feature

Each command previews first. Add `-Apply` to write the policy, then restart Brave. To undo, follow the complete preview and apply commands in [Restore](#restore).

| I want to | Command | Policy set |
| --- | --- | --- |
| Disable Brave Rewards and BAT prompts permanently | `.\Invoke-BraveDebloat.ps1 -OnlyFeature Rewards` | `BraveRewardsDisabled` |
| Remove the Brave Wallet icon and prompts | `.\Invoke-BraveDebloat.ps1 -OnlyFeature Wallet` | `BraveWalletDisabled` |
| Hide Brave VPN | `.\Invoke-BraveDebloat.ps1 -OnlyFeature VPN` | `BraveVPNDisabled` |
| Turn off Leo AI (sidebar, address bar, context menu) | `.\Invoke-BraveDebloat.ps1 -OnlyFeature LeoAI` | `BraveAIChatEnabled` |
| Remove Brave News from the new tab page | `.\Invoke-BraveDebloat.ps1 -OnlyFeature News` | `BraveNewsDisabled` |
| Disable Brave Talk | `.\Invoke-BraveDebloat.ps1 -OnlyFeature Talk` | `BraveTalkDisabled` |
| Disable Playlist | `.\Invoke-BraveDebloat.ps1 -OnlyFeature Playlist` | `BravePlaylistEnabled` |
| Disable Email Aliases | `.\Invoke-BraveDebloat.ps1 -OnlyFeature EmailAliases` | `EmailAliasesEnabled` |
| Stop Brave telemetry (P3A, stats ping, Web Discovery) | `.\Invoke-BraveDebloat.ps1 -OnlyFeature BraveTelemetry` | `BraveP3AEnabled`, `BraveStatsPingEnabled`, `BraveWebDiscoveryEnabled` |
| Stop Chromium metrics and URL-keyed data collection | `.\Invoke-BraveDebloat.ps1 -OnlyFeature ChromiumTelemetry` | `MetricsReportingEnabled`, `UrlKeyedAnonymizedDataCollectionEnabled` |
| Hide sponsored new tab backgrounds and cards | `.\Invoke-BraveDebloat.ps1 -OnlyFeature NewTabBackgrounds,NewTabCards -IncludeProfilePreferences` | `NTPCardsVisible` plus profile preferences |
| Force secure DNS through a resolver of my choice | `.\Invoke-BraveDebloat.ps1 -DnsOverHttps Secure -DnsOverHttpsTemplates https://dns.quad9.net/dns-query` | `DnsOverHttpsMode`, `DnsOverHttpsTemplates` |

Combine several with commas (`-OnlyFeature Rewards,Wallet,VPN,LeoAI`) or start from a preset and exclude what you want to keep. `-ListFeatures` prints every feature id.

## Why Policies Instead of Settings

Brave can reset or re-promote settings after updates. Enterprise policies stay enforced on every start, show up in `brave://policy`, and come off cleanly when you restore the backup.

| Approach | Survives Brave updates | Visible in `brave://policy` | Undo | Touches binaries, hosts, or extensions |
| --- | --- | --- | --- | --- |
| **BraveDebloater policies** | Yes | Yes | Backup restore | No |
| `brave://settings` toggles | Often reset or re-promoted | No | Manual | No |
| A random `.reg` gist | Maybe | If the gist used policies | Only if you kept a copy | Sometimes |
| Scripts that disable Shields or updates | Yes, but they weaken Brave | Yes | Painful | Sometimes |

On Windows and macOS, Brave Origin is a paid stripped-down build. This tool keeps the Brave you already have and applies the same class of official policies for free.

## Install

One line in PowerShell (Windows PowerShell 5.1 or PowerShell 7 on Windows, macOS, or Linux):

```powershell
irm https://raw.githubusercontent.com/osfv/BraveDebloater/main/install.ps1 | iex
```

It downloads the latest release zip and `SHA256SUMS.txt`, refuses to continue if the hash does not match, extracts to `%LOCALAPPDATA%\Programs\BraveDebloater` (Windows) or `~/.local/share/BraveDebloater`, and prints the preview command. Running it again upgrades in place and keeps `backups/`. It does not touch Brave. To pick a version or folder:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/osfv/BraveDebloater/main/install.ps1))) -Version 0.5.0 -Destination C:\Tools\BraveDebloater
```

Scoop users can install straight from this repository, with a `bravedebloat` shim and `backups/` persisted across upgrades:

```powershell
scoop install https://raw.githubusercontent.com/osfv/BraveDebloater/main/packaging/scoop/bravedebloater.json
```

winget: releases from 0.5.0 ship `BraveDebloater-vX.Y.Z-windows.zip` with a `BraveDebloat.exe` launcher so the package can be listed in [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) as `osfv.BraveDebloater`. Once that listing is accepted, `winget install osfv.BraveDebloater` puts `BraveDebloat` on your `PATH`; it runs `Invoke-BraveDebloat.ps1` with the same arguments (`BraveDebloat -Preset Extreme`). Because winget owns its package folder and upgrades reinstall it, pass `-BackupDirectory` pointing outside that folder (for example `"$env:LOCALAPPDATA\BraveDebloater\backups"`) so restore points survive. See `packaging/README.md`.

Manual install: download `BraveDebloater-vX.Y.Z.zip` from the Releases page, then extract it to a folder you control, such as `Downloads\BraveDebloater`. To verify the archive first, download `SHA256SUMS.txt` from the same release and compare it with:

```powershell
Get-FileHash .\BraveDebloater-vX.Y.Z.zip -Algorithm SHA256
```

Open PowerShell in the extracted folder and run the default dry-run:

```powershell
.\Invoke-BraveDebloat.ps1
```

Review the output before applying changes. If Windows PowerShell blocks local scripts (`Restricted` execution policy), allow them for your user once with `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`; the installer prints this hint when it applies.

## Start Here

Preview the default cleanup first:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme
```

Each `[dry-run]` line ends with the current state of that policy when the target can be read: `Currently not set.`, `Currently 0.`, or `Already set, no change.` The closing summary counts how many values are already set, so a second preview after an apply run shows what still differs.

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

Print the tool version, the Brave policy template version it was validated against, and your PowerShell version for bug reports:

```powershell
.\Invoke-BraveDebloat.ps1 -Version
```

List backups or preview retention cleanup:

```powershell
.\Invoke-BraveDebloat.ps1 -ListBackups
.\Invoke-BraveDebloat.ps1 -PruneBackupsOlderThanDays 30
.\Invoke-BraveDebloat.ps1 -KeepLatestBackups 10
```

Each listed backup shows how many policy values and profile files it holds and which policy target it restores, or why a restore would reject it (for example a missing profile copy or a policy this version does not manage). Add `-Apply` only after the preview lists the backups you expect to delete. Pruning a backup also removes the profile `Preferences` copies that belong only to it.

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

Exports also honor `-WhatIf`: add it to an `-ExportPolicyPath` command to preview without creating or overwriting the export file. Use one command mode at a time; combining diagnostics, policy listings, exports, restores, or backup maintenance now stops with a clear error. `-ListBackups` can still be combined with backup retention options.

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
.\Invoke-BraveDebloat.ps1 -Platform Windows -Preset Extreme -ExportPolicyPath .\brave-policy.reg
.\Invoke-BraveDebloat.ps1 -Platform Linux -Preset Extreme -ExportPolicyPath .\brave-policy.json
.\Invoke-BraveDebloat.ps1 -Platform iOS -OnlyFeature Rewards -ExportPolicyPath .\brave-ios.mobileconfig
.\Invoke-BraveDebloat.ps1 -Platform Android -OnlyFeature Rewards -ExportPolicyPath .\brave-android-mdm.json
```

`-ExportPolicyPath` picks the format from the platform and file extension: `.reg` for Windows registry policies, `.json` for Linux and Android, `.plist` for macOS, and `.mobileconfig` for iOS/iPadOS. Exports and previews never write to the policy target, so they do not need an elevated session. If `-Apply` is present together with `-ExportPolicyPath`, only the export file is written and `-Apply` is ignored with a warning.

Use `-PolicyPath` when testing, or when your managed Linux or macOS machine-wide policy file lives somewhere custom. It has no effect on Windows registry or macOS `defaults` targets, and the script says so. The path is recorded in full in backups, so a later restore matches even when you pass it as a relative path from another folder.

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

## DNS Control

`-DnsOverHttps` is an optional add-on that manages Brave's DNS-over-HTTPS policies (`DnsOverHttpsMode` and `DnsOverHttpsTemplates`). Nothing DNS-related is written unless you pass it.

```powershell
# Force secure DNS through a resolver you choose (Secure needs at least one https:// template)
.\Invoke-BraveDebloat.ps1 -DnsOverHttps Secure -DnsOverHttpsTemplates https://dns.quad9.net/dns-query

# Upgrade to DNS-over-HTTPS when the system resolver supports it, optionally with a preferred resolver
.\Invoke-BraveDebloat.ps1 -DnsOverHttps Automatic
.\Invoke-BraveDebloat.ps1 -DnsOverHttps Automatic -DnsOverHttpsTemplates https://dns.quad9.net/dns-query

# Turn DNS-over-HTTPS off, or hand DNS back to Brave settings
.\Invoke-BraveDebloat.ps1 -DnsOverHttps Off
.\Invoke-BraveDebloat.ps1 -DnsOverHttps Unmanaged
```

Preview lines show the current mode, and switching to a mode without templates also removes a leftover custom resolver so `brave://policy` stays tidy. `Unmanaged` removes both policies. Combine with `-OnlyFeature` when you do not want the preset applied in the same run. DNS control is not available for iOS/iPadOS exports because Brave's mobile MDM does not document those policies.

`.reg` exports carry those removals as `"Name"=-` deletion entries. JSON and plist exports cannot remove policies, so the export prints a warning naming the policies to remove on the device.

## Feature Toggles

Use `-Customize` for an interactive yes/no prompt for each cleanup.

Use `-IncludeFeature` and `-ExcludeFeature` for repeatable commands. Names can be separated by spaces or commas, so `-ExcludeFeature News,LeoAI` also works through `powershell -File`, scheduled tasks, and the `BraveDebloat.exe` launcher, where PowerShell hands the list over as one string.

Use `-OnlyFeature` when you want exactly the named cleanups without starting from a preset. Copy-ready examples are in [Disable One Feature](#disable-one-feature).

Feature names are shown by `-ListFeatures`. Examples include `Rewards`, `Wallet`, `VPN`, `LeoAI`, `News`, `Talk`, `EmailAliases`, `Autofill`, `Translate`, and `GoogleSearchSidePanel`.

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

If Brave is running, profile preference cleanup is skipped. This avoids writing files that Brave may overwrite. Restores that include profile files stop for the same reason until Brave is closed. A preview tells you up front when Brave is running, and when a selected feature has profile patches that `-IncludeProfilePreferences` would add.

Preferences files are read and written as UTF-8 without a byte order mark on every PowerShell version, so profile names and site entries with non-ASCII characters are preserved. Date strings elsewhere in the file are kept exactly as written. PowerShell 7.0 to 7.4 cannot read them without converting them, so those versions skip a Preferences file that contains dates and say so; use PowerShell 7.5 or newer, or Windows PowerShell 5.1, to clean it.

Already-correct preferences are marked `Already set` in previews. Apply skips those settings and leaves unchanged profile files untouched. Each changed profile's backup is recorded before its Preferences file is written, so earlier changes remain restorable if a later profile fails.

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

Every apply run ends with the exact restore arguments for its backup, ready to paste into PowerShell. They include `-PolicyPath` and `-UserSid` when the run used them, and `-ProfileRoot` with the resolved profile folder whenever the backup holds profile files. Use `-UndoFromBackup Latest` to pick the newest backup in `-BackupDirectory`; the run prints which file it chose, so preview it before adding `-Apply`.

Restore validates the backup before it writes. Registry restores are limited to Brave policy keys, the recorded policy kind must match the recorded path (a Linux JSON backup only restores to the Linux managed file or your `-PolicyPath`, a macOS plist backup only to the managed plist or your `-PolicyPath`), and Linux JSON or macOS values are written back with the exact type the backup recorded. Profile file restores are limited to `Preferences` files under the selected `-ProfileRoot`; each backup keeps its own copies under `backups/profile-files/<backup-name>/`, and pruning only deletes copies inside the pruned backup's own folder.

If a profile copy referenced by a backup is missing, restore stops before changing any policies or profiles. Keep the JSON backup and its `profile-files/` copies together.

## Machine-Wide Mode

Current-user policy is the default and does not require administrator/root rights.

Previewing machine-wide policy works from a normal session and prints a note when the matching `-Apply` run will need elevation. To apply machine-wide policy, run PowerShell as administrator/root:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -Scope LocalMachine -Apply
```

On Linux the default target `/etc/brave/policies/managed/BraveDebloater.json` also needs root, so run the apply command with `sudo pwsh`.

## Sources

Policy names and values come from Brave's official Group Policy documentation and Brave policy templates:

- <https://support.brave.app/hc/en-us/articles/360039248271-Group-Policy>
- <https://brave-browser-downloads.s3.brave.com/latest/policy_templates.zip>

See `docs/debloatable-validation.md` for the source version, the policy choices, and the validation commands.

See `ROADMAP.md` for planned safety, testing, release trust, user experience, and maintainability work.

## Releasing

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`. It reruns the project checks on Windows, Ubuntu, macOS, and Windows PowerShell 5.1 against the tagged commit and compiles `BraveDebloat.exe` from `packaging/launcher/BraveDebloat.cs`, and only then confirms the tag matches `$ToolVersion` in `Invoke-BraveDebloat.ps1` and has a `## X.Y.Z - <date>` section in `CHANGELOG.md`, builds `BraveDebloater-vX.Y.Z.zip` from the tagged tree and `BraveDebloater-vX.Y.Z-windows.zip` (same tree, flattened, plus the launcher), writes `SHA256SUMS.txt`, and publishes the GitHub release with that changelog section as the notes. It also stores ready-to-submit winget and Scoop manifests in the run's `package-manifests` artifact, and opens the winget-pkgs pull request when a `WINGET_TOKEN` secret exists.

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

A zip newer than the recorded template version passes with a warning, because Brave's `latest` download changes with every release. Add `-RequireVersionMatch` before a release so the recorded version is exact. The check also confirms each manifest value fits the ADMX definition (boolean, enum, integer, or text).

Update the recorded template version after downloading a newer official zip:

```powershell
.\scripts\Update-PolicyTemplateVersion.ps1 -TemplateZipPath .\policy_templates.zip
```

## Pull Request Review

Greptile review guidance lives in `greptile.json`. It covers PowerShell compatibility, policy writes, registry writes, profile JSON writes, and feature-toggle behavior.
