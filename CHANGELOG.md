# Changelog

## Unreleased

- Rewriting a profile `Preferences` file or a Linux policy file on Linux and macOS now keeps the file's owner and permissions (PowerShell 7.3 or newer). Previously the replaced file got the default permissions, so a `0600` `Preferences` file became world-readable (`0644`), and a file rewritten with `sudo` ended up owned by root.

- On Linux, `/etc/brave/policies/managed/BraveDebloater.json` and the `brave/policies/managed` folders are now made readable for every user after an apply or undo run. With a restrictive root umask (`027` or `077`) Brave could not read the new file, so the applied policies silently had no effect. A `-PolicyPath` file keeps the permissions it has.

- A string policy value that differs only in case, for example `DnsOverHttpsMode` = `OFF`, is no longer reported as "Already set" in previews, reports, and `-Doctor`. Brave reads these values case-sensitively.

- `-ReportPath` on a Linux desktop now opens reports whose path contains spaces. The path was split into several arguments for `xdg-open`.

- The Linux default profile folder for `-IncludeProfilePreferences` and `-Doctor` follows `XDG_CONFIG_HOME` when it is set to an absolute path, as Brave does.

- A `-NoBackup` preview report no longer says `Backup: Written on -Apply` or promises an undo command; it now says that the matching `-Apply` run writes no backup.

- The "Could not read existing policies" warning no longer ends with a doubled period.

- `scripts/Update-PolicyTemplateVersion.ps1` no longer rewrites the "What Changed" sentence in `docs/debloatable-validation.md`. On the version-only `156.1.100.5` update it changed "from `155.1.99.2` to `156.1.99.33`" into "to `156.1.100.5`", which credited the Autofill deprecations to the wrong template. It now updates only the template evidence: the version and the `VERSION` entry date from the zip.

- The weekly policy template check no longer fails when the repository does not let GitHub Actions open pull requests. It still pushes `automation/policy-templates`, then opens or updates one issue with the comparison and a link to open the pull request. Later runs close that issue once a pull request from the branch is open or `main` records the latest templates. The check always compares and rewrites `main`, also when started by hand from another branch. Every run now shows the comparison and the manifest validation output on its run page. The October 12 and 19 runs failed at that step, so the `156.1.100.5` update found on October 19 never reached a pull request.

## 0.9.1 - 2026-10-24

- After an `-Apply` run that writes a policy or a profile `Preferences` file, BraveDebloater asks you to star it on GitHub, in the console and in the `-ReportPath` HTML report. Dry runs, `-WhatIf`, undo runs, and apply runs where every write was skipped don't ask.

## 0.9.0 - 2026-10-23

- `-Doctor` reports DNS-over-HTTPS state from the selected target: `DNS over HTTPS: <mode> (<resolver>)`, or `not managed` when `DnsOverHttpsMode` and `DnsOverHttpsTemplates` are absent.
- Releases now include `BraveDebloater-vX.Y.Z.sigstore.json`, a signed SLSA build provenance for both archives. The README's manual install section shows the `gh attestation verify` command that ties an archive to its tag and the release workflow.
- Added OpenSSF Scorecard, CodeQL scanning of the GitHub Actions workflows, and weekly Dependabot updates for pinned actions. The weekly policy template workflow now grants write access only to the job that opens its pull request.
- `SECURITY.md` names the private reporting channels: GitHub private vulnerability reporting or email.

## 0.8.0 - 2026-10-12

- `BraveDebloat.exe` now resolves relative paths against the folder you run it from. Previously it ran the script inside its own folder, so `BraveDebloat -ExportPolicyPath .\brave.reg` (or a relative `-PolicyPath`, `-ProfileRoot`, `-BackupDirectory`, or `-UndoFromBackup`) used the launcher's folder, which for winget is a package folder that upgrades replace.
- `-Doctor` on macOS now checks obsolete and explicitly blocked policy names, including `IPFSEnabled` and `BraveShieldsDisabledForUrls`. It identifies read failures as an incomplete safety check and explains the scan's limits even when it finds a protected policy. Open `brave://policy` for names outside that scan, including pattern-only safety matches.
- `-Customize` now stops with a clear message when no answer can be read (redirected or closed input, for example in a scheduled task or CI), instead of failing with "You cannot call a method on a null-valued expression."
- `install.ps1` resolves `~` and filesystem PowerShell drive paths in `-Destination`, `-ArchivePath`, and `-ChecksumPath`. Previously `-Destination ~/Tools/BraveDebloater` installed into a folder literally named `~` under the current folder. Non-filesystem providers such as `Env:` and `Variable:` now produce an error instead of a disk path.
- Launcher smoke tests use unique filenames so they cannot overwrite a local `BraveDebloat.exe` build or delete an unrelated `relative-export.json`. They also check relative export, apply, backup, and restore paths.
- `-ReportPath <file.html>` saves a self-contained HTML report of a dry run or `-Apply` run: each policy's current and new value, run details, and the exact undo command with a Copy button. Skipped profile cleanup (Brave running, no profile files, or an invalid `Preferences` file) is listed in the report, and prior profile values that are JSON `null` or objects are shown as JSON.
- A weekly workflow compares Brave's latest policy templates with `config/policy-template-snapshot.json` and opens a pull request listing new, removed, and deprecated policies.
- Updated the manifest and policy snapshot to Brave template `156.1.99.33`. `AutofillSettings` replaces the deprecated address/card Autofill switches, with structured JSON/plist support and a JSON string in the Windows registry. Apply backs up and removes the old values; undo still restores them.
- `-DnsOverHttpsTemplates https://a,https://b` through `powershell -File` or `BraveDebloat.exe` now sets two resolvers. Previously the comma-joined text was written as one invalid template. A comma before `https://` that comes after a query string is ambiguous, so it is now rejected with a hint to use spaces or `%2C`.
- The undo command printed through `BraveDebloat.exe` no longer ends a quoted path with a backslash (for example `-ProfileRoot "...\User Data\"`), which escaped the closing quote and broke the pasted command.
- `install.ps1` installs into a folder that only holds a `backups/` folder instead of refusing it as not empty. A `Backups/` folder counts as that folder only on case-insensitive filesystems (Windows, default macOS); on case-sensitive filesystems it is treated as existing content.
- Fixed profile `Preferences` backups failing under Windows PowerShell 5.1 when the backup folder and profile path were long (for example a WinGet install under `%LOCALAPPDATA%`). Backup copies are now named after their path under the profile root.
- Fixed the installer's "next steps" `Set-Location` hint so it can be pasted into PowerShell when the install folder contains an apostrophe or brackets.
- Fixed `scripts/Build-Launcher.ps1` failing under Windows PowerShell 5.1 when `-OutputPath` is an absolute path.
- Fixed `scripts/Test-Launcher.ps1` stopping under Windows PowerShell 5.1 on the launcher's expected error output. CI now builds the launcher to an absolute path and tests it under Windows PowerShell 5.1 too.

## 0.7.0 - 2026-10-03

- Apply now stops before any write when a current policy value (for example the string `"true"` for a boolean policy, `null`, or an array in Linux JSON) could not be restored from the backup it would create. Previously the value was overwritten and the printed undo command was rejected.
- Profile preference cleanup skips a setting with a warning when a parent value on its path is `null`, a scalar, or an array, instead of crashing.
- Profile `Preferences` writes now honor `-Confirm` and `-WhatIf`.
- Fixed two profile folders whose names normalize to the same backup file name (for example `Profile 1` and `Profile_1`) overwriting each other's `Preferences` backup in one run.
- Fixed `-PolicyPath` allowing restores outside the Brave registry policy keys when it matched a backup's path.
- Preserve deeply nested unrelated Linux policy JSON during apply and undo. Refuse JSON writes that exceed serialization depth instead of silently truncating data, including profile Preferences and backups.
- `-List` now includes policy totals and DNS policies to remove if present.
- Added the Linux preview, apply, and undo video to the README.

## 0.6.0 - 2026-09-24

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
