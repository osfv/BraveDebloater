# Debloatable Source Validation

BraveDebloater only adds policy names that can be checked against Brave's own policy sources.

## Source Files

Official sources used for this pass:

- Brave Help Center, Group Policy, updated February 12, 2026: https://support.brave.app/hc/en-us/articles/360039248271-Group-Policy
- Latest Brave policy templates zip: https://brave-browser-downloads.s3.brave.com/latest/policy_templates.zip

Downloaded template evidence:

- Template version: `153.1.96.44`
- Archive timestamp: September 3, 2026
- Checked files: `VERSION` and `windows/admx/brave.admx`

Targeted Reddit, Brave Community, and GitHub searches did not produce a newer or more authoritative debloatable-policy source than Brave's Help Center and template zip.

## What Changed

The manifest version in `config/policies.json` changed from `151.1.94.91` to `153.1.96.44`.

These official-template policies were added because they match BraveDebloater's scope:

- `EmailAliasesEnabled = 0`

The manifest's `deprecatedPolicies` list records names that must stay out of active presets. The current template still lists `PrivacySandboxPromptEnabled`, `PromotionalTabsEnabled`, and `IPFSEnabled`, but places them under the `DeprecatedPolicies` category. They stay out of the active manifest; `PromotionsEnabled = 0` is retained as the supported policy for promotional content. Apply and dry-run remove leftover copies of those names from the selected Brave policy target so older installs do not keep showing them as obsolete in `brave://policy`.

These official-template policies were checked and left out:

- `TorDisabled`: disables a privacy feature instead of removing bloat.
- `DefaultBraveRemember1PStorageSetting`: changes storage behavior instead of removing an extra surface.
- `BraveShieldsDisabledForUrls` and `BraveShieldsEnabledForUrls`: Shield URL lists stay blocked by the safety rules.

## Platform Notes

`Windows`, `macOS`, and `Linux` are validated from the official Brave ADMX template. Brave documents desktop support for Chromium policies plus Brave-specific policies, and documents native policy storage for macOS and Linux.

`Android` is marked `mdm-no-template`. Brave documents Android as MDM-controlled and says it does not currently provide MDM templates for Android.

`iOS` is limited to the Brave-documented mobile policy list:

- `BravePlaylistEnabled`
- `BraveVPNDisabled`
- `BraveNewsDisabled`
- `BraveTalkDisabled`
- `BraveRewardsDisabled`
- `BraveAIChatEnabled`

iOS/iPadOS export validation now reads that allow-list from the manifest instead of a hardcoded list.

## New Check

`scripts/Test-LatestPolicyTemplates.ps1` validates a downloaded official template zip.

It checks that:

- the manifest version matches the zip `VERSION`;
- every manifest policy exists in `windows/admx/brave.admx` and is not under `DeprecatedPolicies`;
- every `deprecatedPolicies` name is absent from the ADMX template, or still present only under `DeprecatedPolicies` / `deprecated="true"`;
- every iOS allow-listed policy is defined in the manifest.

`scripts/Test-Behavior.ps1` also validates target-user registry safety. It checks that `-UserSid` builds only the exact Brave policy path under `HKEY_USERS`, rejects path-like SID input and non-Windows or machine-scope combinations, requires elevation for apply target construction, and requires the same explicit SID to preview a restore.

On Windows, preview another loaded user's policy target before applying it from an elevated session:

```powershell
.\Invoke-BraveDebloat.ps1 -Platform Windows -UserSid S-1-5-21-1000-2000-3000-1001 -Preset Extreme
.\Invoke-BraveDebloat.ps1 -Platform Windows -UserSid S-1-5-21-1000-2000-3000-1001 -Preset Extreme -Apply
```

The target is exactly `HKEY_USERS\<SID>\Software\Policies\BraveSoftware\Brave`. The user hive must already be loaded, and restore requires the same explicit `-UserSid`; `-PolicyPath` cannot authorize an `HKEY_USERS` restore. If profile preference cleanup is requested too, pass that user's `-ProfileRoot` explicitly.

## Validation Commands

Download the current Brave template zip:

```powershell
curl -L -o /tmp/brave-policy-templates.zip https://brave-browser-downloads.s3.brave.com/latest/policy_templates.zip
```

Run the source-backed template check:

```powershell
pwsh -NoProfile -File ./scripts/Test-LatestPolicyTemplates.ps1 -TemplateZipPath /tmp/brave-policy-templates.zip
```

Run the local checks:

```powershell
pwsh -NoProfile -File ./scripts/Test-PolicyManifest.ps1
pwsh -NoProfile -File ./scripts/Test-Behavior.ps1
```

The template validator uses a local zip file on purpose. CI can download the current zip before running it, but normal offline checks do not need network access.
