# Changelog

## Unreleased

- Fixed profile preference cleanup on PowerShell 7 rewriting unrelated date strings in `Preferences` (for example `+02:00` offsets came back in local time). JSON is now parsed with `-DateKind String` on PowerShell 7.5 and newer; PowerShell 7.0 to 7.4 skip a `Preferences` file that contains date values with a warning instead of changing it, and stop before writing a managed policy JSON file that contains them. Managed policy JSON and backups use the same parser, so on PowerShell 7.5 and newer a date-like string policy value also survives a restore.
- Apply runs now end with the exact restore arguments for the backup they wrote, quoted for PowerShell (or for `cmd.exe` and PowerShell when run through `BraveDebloat.exe`, listing the values instead when a path contains `%`, `!`, `$`, or a backtick), including `-PolicyPath` and `-UserSid` when used and the resolved `-ProfileRoot` whenever the backup holds profile files.
- `-UndoFromBackup Latest` restores the newest backup in `-BackupDirectory` and prints which file it picked.
- `-ListBackups` shows each backup's policy value count, profile file count, and policy target, or why a restore would reject it.
- `-Doctor` explains how to pass `-ProfileRoot` when no profile folder is known for the platform, instead of printing an empty path.

## 0.5.0 - 2026-09-23

- Fixed policy exports creating or overwriting files with `-WhatIf`; exports now also honor PowerShell confirmation.
- Reject conflicting command modes before any writes, preventing diagnostics or policy listings combined with backup retention from deleting backups.
- Record each profile backup before changing its Preferences file, preserving recovery information if a later profile write fails. Restores now reject missing profile backup copies before changing policies.
- Skip already-correct profile preferences, show them as `Already set` in previews, and avoid rewriting unchanged profile files or creating redundant profile copies.
- Added an original project mark (`assets/icons/debloater.png`): an orange lion with a teal broom, and used it on the README in place of the Brave Software logo.
- README now has a "What It Does Not Do" safety list, a per-feature command table, and a short comparison of policies vs settings, gists, and Brave Origin.
- Added `install.ps1`, a one-line installer: `irm https://raw.githubusercontent.com/osfv/BraveDebloater/main/install.ps1 | iex` downloads the latest release zip and `SHA256SUMS.txt`, stops on a checksum mismatch, extracts to `%LOCALAPPDATA%\Programs\BraveDebloater` or `~/.local/share/BraveDebloater`, keeps `backups/` and your own files when upgrading in place (the new files are staged completely first and swapped in with rollback, so a failed upgrade leaves the previous install intact), and prints the preview command. `-Version`, `-Destination`, and `-ArchivePath` (install from a downloaded zip, still verified) are available when the script is run from a script block or file. It never changes Brave.
- Added a Scoop manifest at `packaging/scoop/bravedebloater.json` (`scoop install https://raw.githubusercontent.com/osfv/BraveDebloater/main/packaging/scoop/bravedebloater.json`) with a `bravedebloat` shim and persisted `backups/`.
- Added winget packaging: `packaging/launcher/BraveDebloat.cs` is a small launcher that runs `Invoke-BraveDebloat.ps1` from its own folder with the given arguments (winget only accepts `.exe` portable commands), `scripts/Build-Launcher.ps1` compiles it with the C# compiler from .NET Framework, and `scripts/New-PackageManifests.ps1` writes `osfv.BraveDebloater` manifests (schema 1.10.0) plus the Scoop manifest from a release's `SHA256SUMS.txt`.
- Releases now also publish `BraveDebloater-vX.Y.Z-windows.zip` (the tagged tree flattened with `BraveDebloat.exe`), list both zips in `SHA256SUMS.txt`, include the one-line install command in the notes, store winget and Scoop manifests in a `package-manifests` workflow artifact, and open the winget-pkgs pull request when a `WINGET_TOKEN` secret is configured. CI builds and smoke tests the launcher on Windows.
- `-IncludeFeature`, `-ExcludeFeature`, and `-OnlyFeature` split comma-separated values, so `-ExcludeFeature News,LeoAI` works through `powershell -File`, scheduled tasks, and the launcher, where the list arrives as one string.

## 0.4.0 - 2026-09-11

- Added DNS control: `-DnsOverHttps Off|Automatic|Secure` sets Brave's `DnsOverHttpsMode`, `-DnsOverHttpsTemplates` sets one or more `https://` resolver templates (required for `Secure`), and `-DnsOverHttps Unmanaged` removes both policies so Brave settings control DNS again. Modes without templates also remove a leftover custom resolver. Previews show the current mode; backups and restores cover the string values; `.reg`, JSON, and plist exports include them.
- Fixed profile `Preferences` backups from different apply runs overwriting each other. Each backup now keeps its copies in `backups/profile-files/<backup-name>/`, so restoring an older backup brings back that run's original file. Existing backups keep working.
- Fixed restores of Linux JSON and macOS policy values turning an integer policy that was `0` or `1` (for example `NetworkPredictionOptions = 0`) into a boolean Brave rejects. Restores now write values back with their recorded type, and macOS reads use `defaults read-type` so booleans stay booleans.
- Fixed `.reg` exports escaping a backslash in string values as four backslashes instead of two.
- Fixed `Move-Item`/`Copy-Item` destination handling for profile and policy paths that contain `[` or `]`; file writes now use literal .NET file APIs on every PowerShell version.
- Restore now rejects a backup whose `policyKind` does not match its recorded path (for example a registry key path with a JSON-file kind, or a JSON-file kind pointing at the macOS managed plist), rejects unknown kinds, and stops early without root when restoring the Linux default policy file. File kinds only accept their own platform's default path or the `-PolicyPath` passed to the restore.
- Registry policy removal during apply and restore no longer hides failures; access errors now stop the run instead of reporting "Removed".
- Managed JSON policy values are now snapshotted and reported with their real kind (`String` for strings) instead of always `DWord`.
- `-ExportPolicyPath` combined with `-Apply` no longer demands elevation or fails for Android/iOS; `-Apply` is ignored with a warning because exports never touch the policy target.
- `-PruneBackupsOlderThanDays` and `-KeepLatestBackups` also remove the profile `Preferences` copies stored in the pruned backup's own `profile-files/<backup-name>/` folder, and previews list them. Copies elsewhere, including those from backups made before 0.4.0, are left alone.
- Dry-run and `-WhatIf` lines now show the current state of each policy when the target is readable (`Currently not set.`, `Currently 0.`, or `Already set, no change.`), and the summary counts values that are already set.
- Previews print a hint when selected features also have profile preference patches but `-IncludeProfilePreferences` was not used, and note when Brave is running so an apply run would skip profile cleanup.
- `-PolicyPath` for Linux and macOS machine-wide targets is recorded as a full path, so restores match a relative `-PolicyPath` typed from another working directory.
- Added `-Version` to print the tool version, the recorded Brave policy template version, and the PowerShell version for bug reports.
- `scripts/Test-LatestPolicyTemplates.ps1` now accepts a newer `latest` Brave template with a warning instead of failing CI on every Brave release (pass `-RequireVersionMatch` for release checks), and validates every manifest value against the ADMX definition: `0`/`1` only for boolean policies, listed values for enum policies, and the `minValue`/`maxValue` range for integer policies.
- `scripts/Test-PolicyManifest.ps1` parses every `.ps1` file under `src/`, `scripts/`, and `tests/` for syntax errors, not only the entrypoint.
- `-Doctor -PolicyPath` on Linux reports the selected file once instead of also scanning the default path.
- Recorded Brave policy template `153.1.97.22`. No policy was added, removed, or retyped.
- Added `.github/workflows/release.yml`: pushing a `vX.Y.Z` tag reruns the checks on Windows, Ubuntu, macOS, and Windows PowerShell 5.1 against the tagged commit, then verifies the tag against `$ToolVersion` and `CHANGELOG.md`, and publishes the release archive, `SHA256SUMS.txt`, and notes automatically.

## 0.3.0 - 2026-09-03

- Stop applying Brave's obsolete `PrivacySandboxPromptEnabled` policy, and remove leftover copies of that name plus `PromotionalTabsEnabled` and `IPFSEnabled` from the selected policy target on apply so `brave://policy` no longer flags them.
- Dry-run and `-WhatIf` still preview selected policy writes when an existing Linux policy JSON file is unreadable or malformed; leftover obsolete cleanup is skipped with a warning. `-Apply` still stops before writing a backup if that file cannot be read.
- Fixed profile `Preferences`, backup, and policy JSON being read as ANSI on Windows PowerShell 5.1, which mangled non-ASCII text such as profile names on write. All JSON is now read as UTF-8 and written without a byte order mark.
- Fixed the Brave process check missing the macOS `Brave Browser` process name, which allowed profile preference cleanup while Brave was open.
- Restores that include profile `Preferences` files now stop before writing anything if Brave is running, and Windows registry or macOS backups refuse to apply on another platform.
- Previews, `-List`, and `-ExportPolicyPath` no longer require an elevated session for `-Scope LocalMachine`, `-UserSid`, or the Linux default policy path. Dry-runs print a note when `-Apply` will need elevation, and the Linux default path now fails early with a clear root message.
- `-ExportPolicyPath` writes a `.reg` file for Windows registry targets instead of an Apple plist.
- `-Platform Windows` on another OS no longer fails when `LOCALAPPDATA` is unset, `-PolicyPath` warns when the selected target ignores it, and empty managed policy files are treated as having no policies.
- Closing summaries now show how many policy values were planned or applied.
- Skip unreadable or invalid profile `Preferences` files with a warning instead of failing the whole profile preference cleanup run.
- Added `-Doctor` for a read-only Brave policy, feature, backup, profile, and safety diagnostic report.
- Added Greptile review configuration for safety-focused pull request feedback.
- Added `-OnlyFeature` for running exactly selected feature cleanups without starting from a preset.

## 0.2.0 - 2026-05-04

- Added friendly `Standard`, `High`, and `Extreme` presets while keeping the original preset names as aliases.
- Added `-Customize`, `-IncludeFeature`, `-ExcludeFeature`, and `-ListFeatures` for feature-level cleanup choices.
- Filter profile preference cleanup by selected features when custom choices are used.

## 0.1.1 - 2026-05-03

- Made `-List` a read-only listing path, including optional profile preference patch listing.
- Added safer `-WhatIf` handling, restore backup validation, collision-resistant backup names, and atomic JSON file writes.
- Added behavior checks and Windows PowerShell 5.1 CI coverage.

## 0.1.0

- Initial safety-first Brave debloater.
- Added Core, Privacy, Aggressive, and optional Shield baseline policy sets.
- Added dry-run default, backup creation, restore flow, profile preference cleanup, and manifest checks.
