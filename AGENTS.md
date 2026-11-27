# AGENTS.md

BraveDebloater is a PowerShell 5.1-compatible Brave Browser policy tool.

PowerShell is the cross-platform runtime. Keep platform-specific writes native:

- Windows: Brave registry policy keys.
- macOS: `defaults` or managed plist policy payloads.
- Linux: managed JSON policy files. `/etc/brave/policies/managed` is the only location: machine-wide, mandatory, root to write. Call it `LocalMachine`, never `CurrentUser`.
- Android/iOS: export MDM payloads only; do not add local device writes.

## Code Discovery

Use codebase-memory-mcp before text search for code structure:

1. `search_graph`
2. `trace_path`
3. `get_code_snippet`
4. `query_graph`
5. `search_code`

Use `rg` for docs, configs, literal strings, and when the graph is not enough.

## Safety Rules

Do not add policies that disable Brave updates, disable Brave Shields, add Shield allowlists, weaken Safe Browsing, or remove extensions.

Keep dry-run as the default. `-Apply` must be required before writes.

Keep backup and restore validation strict. Restores must stay limited to Brave policy targets and selected Brave profile `Preferences` files.

Profile preference cleanup must not run while Brave is open.

## Implementation Notes

Keep `Invoke-BraveDebloat.ps1` as the thin entrypoint. Put shared behavior in `src/*.ps1`.

Use existing helpers before adding new ones.

Keep user-facing messages short, concrete, and action-oriented. Say what happened, whether anything changed, and what to do next.

A profile preference patch must name a preference the current Brave release registers. Check `brave/brave-core` first: Brave deletes preferences it has migrated away from on launch.

Under `sudo` on Linux, `HOME` is root's. Resolve profile folders through `Get-DefaultProfileRoot`, which uses the home of the `SUDO_UID` account. Call system tools by absolute path there.

When adding or changing policies, update:

- `config/policies.json`
- `docs/debloatable-validation.md`
- `scripts/Test-PolicyManifest.ps1` or `scripts/Test-LatestPolicyTemplates.ps1` if validation rules change

## Checks

Run the local checks before handing off:

```powershell
pwsh -NoProfile -File scripts/Test-PolicyManifest.ps1
pwsh -NoProfile -File scripts/Test-Behavior.ps1
```

CI (`.github/workflows/ci.yml`) also runs Pester 5.7.1 (`Invoke-Pester -Path ./tests -CI`), PSScriptAnalyzer 1.24.0 at `-Severity Error` on the entrypoint, `install.ps1`, `scripts`, and `src`, and the two scripts above again in Windows PowerShell 5.1 (`powershell -NoProfile -File ...`).

When a Brave policy template zip is available, also run:

```powershell
pwsh -NoProfile -File scripts/Test-LatestPolicyTemplates.ps1 -TemplateZipPath /tmp/brave-policy-templates.zip
```

## Website

The landing page lives in `site/` (Vite, React, Tailwind v4, Motion). `.github/workflows/pages.yml` builds it on pull requests and publishes it from `main` to GitHub Pages at <https://bravedebloater.tersa.tech> (`site/public/CNAME`). `/site export-ignore` keeps it out of release archives.

- It reads features, presets, and the blocklist from `config/policies.json`, so manifest changes show up on the page without edits.
- Media in `site/public/media/` comes from `assets/`: frames and a cut of the Linux recording.
- The refusal tester (`site/src/lib/safety.ts`) mirrors `Assert-PolicySafety`. With `pwsh` installed, `npm test` fails when its messages drift from `src/Manifest.ps1`; CI always runs that comparison.
- Keep the copy free of em dashes, adverbs, and passive voice. Use real output and real counts only.

```powershell
cd site
npm ci
npm run dev      # local preview
npm run build    # typecheck, then build to site/dist
npm test         # compares generated commands and refusal messages with the real script (needs pwsh)
```
