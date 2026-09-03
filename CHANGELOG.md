# Changelog

## Unreleased

- Stop applying Brave's obsolete `PrivacySandboxPromptEnabled` policy, and remove leftover copies of that name plus `PromotionalTabsEnabled` and `IPFSEnabled` from the selected policy target on apply so `brave://policy` no longer flags them.
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
