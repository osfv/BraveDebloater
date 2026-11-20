# Usage guide

Detailed reference for `Invoke-BraveDebloat.ps1`, with examples. New here? Start with the [README](../README.md).

Every command below leaves Brave's policies and profile files alone unless it includes `-Apply`. Commands with `-ReportPath` or `-ExportPolicyPath` write that file in a preview too; add `-WhatIf` to skip it.

## Contents

- [Common tasks](#common-tasks)
- [Presets](#presets)
- [Feature toggles](#feature-toggles)
- [DNS control](#dns-control)
- [Profile preferences](#profile-preferences)
- [Doctor mode](#doctor-mode)
- [Restore](#restore)
- [Machine-wide mode](#machine-wide-mode)
- [Platform support](#platform-support)
- [Brave channels](#brave-channels)

## Common tasks

Read a preview: each `[dry-run]` line ends with the current state of that policy when the target can be read: `Currently not set.`, `Currently 0.`, or `Already set, no change.` The closing summary counts how many values are already set, so a second preview after an apply run shows what still differs.

See what would be changed, including profile preference patches:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -List -IncludeProfilePreferences
```

`-List` includes policy totals and any DNS policies to remove if present. For example, `-List -DnsOverHttps Unmanaged` lists both DNS policy removals alongside the selected preset.

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

Save an HTML report of a dry run or an applied run. It lists every policy with its current and new value, and after `-Apply` it includes the exact undo command:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -ReportPath .\brave-report.html
.\Invoke-BraveDebloat.ps1 -Preset Extreme -Apply -ReportPath .\brave-report.html
```

The report is one self-contained file, so you can open it offline or send it to someone. It opens in your browser when the run finishes (add `-NoOpenReport` to skip that) and is not written under `-WhatIf`.

Exports also honor `-WhatIf`: add it to an `-ExportPolicyPath` command to preview without creating or overwriting the export file. Use one command mode at a time; combining diagnostics, policy listings, exports, restores, or backup maintenance now stops with a clear error. `-ListBackups` can still be combined with backup retention options.

## Presets

`Standard` removes Brave-specific bloat and Brave telemetry.

`High` includes `Standard` and adds privacy-preserving policy defaults.

`Extreme` includes `High` and removes more UI and convenience surfaces.

`Core`, `Privacy`, and `Aggressive` are aliases for `Standard`, `High`, and `Extreme`.

`-LockShields` is an optional add-on. It enforces default ad blocking, standard fingerprinting protection, HTTPS upgrades, and stricter referrer behavior.

By default, the tool uses `Extreme` and does not lock Shields. It refuses to apply policies that disable Shields, add Shield-disabled URLs, weaken Safe Browsing, or disable updates.

## Feature toggles

Use `-Customize` for an interactive yes/no prompt for each cleanup.

Use `-IncludeFeature` and `-ExcludeFeature` for repeatable commands. Names can be separated by spaces or commas, so `-ExcludeFeature News,LeoAI` also works through `powershell -File`, scheduled tasks, and the `BraveDebloat.exe` launcher, where PowerShell hands the list over as one string.

Use `-OnlyFeature` when you want exactly the named cleanups without starting from a preset. Copy-ready examples are in [Turn off one feature](../README.md#turn-off-one-feature).

Feature names are shown by `-ListFeatures`. Examples include `Rewards`, `Wallet`, `VPN`, `LeoAI`, `News`, `Talk`, `EmailAliases`, `Autofill`, `Translate`, and `GoogleSearchSidePanel`.

`Autofill` uses `AutofillSettings` to block filling and saving contact information and payment methods on all sites. Brave's current template deprecates `AutofillAddressEnabled` and `AutofillCreditCardEnabled`; apply backs up and removes those old values, and undo can restore them. If an older Brave build reports `AutofillSettings` as unknown, update Brave before applying this feature.

When `-IncludeProfilePreferences` is combined with custom feature choices, profile preference patches are filtered to the selected features.

## DNS control

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

## Profile preferences

Policies are the main path because Brave shows them in `brave://policy`.

Some cosmetic cleanup lives in each Brave profile instead. Close Brave first, then run:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -IncludeProfilePreferences -Apply
```

If Brave is running, profile preference cleanup is skipped. This avoids writing files that Brave may overwrite. Restores that include profile files stop for the same reason until Brave is closed. A preview tells you up front when Brave is running, and when a selected feature has profile patches that `-IncludeProfilePreferences` would add.

Preferences files are read and written as UTF-8 without a byte order mark on every PowerShell version, so profile names and site entries with non-ASCII characters are preserved. Date strings elsewhere in the file are kept exactly as written. PowerShell 7.0 to 7.4 cannot read them without converting them, so those versions skip a Preferences file that contains dates and say so; use PowerShell 7.5 or newer, or Windows PowerShell 5.1, to clean it.

Already-correct preferences are marked `Already set` in previews. Apply skips those settings and leaves unchanged profile files untouched. Each changed profile's backup is recorded before its Preferences file is written, so earlier changes remain restorable if a later profile fails.

## Doctor mode

Use `-Doctor` when you want to inspect Brave without changing anything.

It checks policy locations, detected feature status, DNS-over-HTTPS mode and resolver, unknown Brave policies, protected policy names, Brave process state, profile preference files, and backups. DNS is printed as one line: `DNS over HTTPS: <mode> (<resolver>)`, or `DNS over HTTPS: not managed` when those policies are absent.

On macOS, Doctor reads managed, obsolete, and explicitly blocked policy names individually. It does not enumerate other names, including policies covered only by a safety pattern. The report identifies this limit and marks policy read failures as an incomplete safety check. Open `brave://policy` to review the full list.

This helps after testing other debloat tools. Machine-wide policies can make Brave settings appear managed for every Windows user, even when current-user policies look empty.

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

Every apply run ends with the exact restore arguments for its backup, ready to paste into PowerShell, or into `cmd.exe` when you ran `BraveDebloat.exe`. Because `BraveDebloat.exe` can run from either shell, a launcher run whose paths contain `%`, `!`, `$`, or a backtick lists the values instead, for you to quote. They include `-PolicyPath` and `-UserSid` when the run used them, and `-ProfileRoot` with the resolved profile folder whenever the backup holds profile files. Use `-UndoFromBackup Latest` to pick the newest backup in `-BackupDirectory`; the run prints which file it chose, so preview it before adding `-Apply`.

Restore validates the backup before it writes. Registry restores are limited to Brave policy keys, the recorded policy kind must match the recorded path (a Linux JSON backup only restores to the Linux managed file or your `-PolicyPath`, a macOS plist backup only to the managed plist or your `-PolicyPath`), and Linux JSON or macOS values are written back with the exact type the backup recorded. Profile file restores are limited to `Preferences` files under the selected `-ProfileRoot`; each backup keeps its own copies under `backups/profile-files/<backup-name>/`, and pruning only deletes copies inside the pruned backup's own folder.

If a profile copy referenced by a backup is missing, restore stops before changing any policies or profiles. Keep the JSON backup and its `profile-files/` copies together.

## Machine-wide mode

Current-user policy is the default and does not require administrator/root rights.

Previewing machine-wide policy works from a normal session and prints a note when the matching `-Apply` run will need elevation. To apply machine-wide policy, run PowerShell as administrator/root:

```powershell
.\Invoke-BraveDebloat.ps1 -Preset Extreme -Scope LocalMachine -Apply
```

On Linux the default target `/etc/brave/policies/managed/BraveDebloater.json` also needs root, so run the apply command with `sudo pwsh`.

## Platform support

Windows writes Brave policy values under the current-user or local-machine registry policy key.

To target another loaded Windows user's policy hive from an elevated PowerShell session, read that user's SID with `whoami /user` and pass it explicitly:

```powershell
.\Invoke-BraveDebloat.ps1 -Platform Windows -UserSid S-1-5-21-1000-2000-3000-1001 -Preset Extreme
.\Invoke-BraveDebloat.ps1 -Platform Windows -UserSid S-1-5-21-1000-2000-3000-1001 -Preset Extreme -Apply
```

The target is exactly `HKEY_USERS\<SID>\Software\Policies\BraveSoftware\Brave`. The hive must already be loaded, and restores require the same explicit `-UserSid`; `-PolicyPath` cannot authorize an `HKEY_USERS` restore. Pass that user's `-ProfileRoot` explicitly when also using `-IncludeProfilePreferences`.

macOS current-user mode uses `defaults write com.brave.Browser`. macOS machine-wide mode writes `/Library/Managed Preferences/com.brave.Browser.plist`.

Linux writes JSON policy values to `/etc/brave/policies/managed/BraveDebloater.json`. Other values in that file, including date strings, are kept as written. On PowerShell 7.0 to 7.4, which cannot keep date strings as text, apply and restore stop before changing a policy file that contains them.

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

## Brave channels

Profile preference cleanup targets Brave Stable by default. Use `-Channel` when you want the default profile path for Beta or Nightly:

```powershell
.\Invoke-BraveDebloat.ps1 -Channel Beta -IncludeProfilePreferences
.\Invoke-BraveDebloat.ps1 -Channel Nightly -IncludeProfilePreferences
```

Stable policy behavior is unchanged. `-ProfileRoot` still overrides the detected profile path.
