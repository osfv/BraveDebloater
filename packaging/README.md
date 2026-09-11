# Packaging

Everything here is generated from, or points at, the GitHub release assets. The release workflow
(`.github/workflows/release.yml`) publishes three assets per `vX.Y.Z` tag:

| Asset | Contents | Used by |
| --- | --- | --- |
| `BraveDebloater-vX.Y.Z.zip` | `git archive` of the tagged tree under a `BraveDebloater-vX.Y.Z/` folder | manual download, `install.ps1`, Scoop |
| `BraveDebloater-vX.Y.Z-windows.zip` | the same tree flattened to the zip root plus `BraveDebloat.exe` | winget |
| `SHA256SUMS.txt` | `sha256  filename` lines for both zips | every installer above |

## install.ps1 (one line)

`install.ps1` at the repository root downloads the release zip and `SHA256SUMS.txt`, verifies the hash,
extracts into a folder you control, keeps `backups/` across upgrades, and prints the preview command. It
runs on Windows PowerShell 5.1 and PowerShell 7. It never touches Brave.

```powershell
irm https://raw.githubusercontent.com/osfv/BraveDebloater/main/install.ps1 | iex
```

## launcher/BraveDebloat.cs

winget's community repository only accepts `.exe` files as portable commands, so the Windows zip ships a
small launcher compiled from `launcher/BraveDebloat.cs`. It starts `pwsh.exe` (or `powershell.exe` when
PowerShell 7 is not installed) with `-NoProfile -ExecutionPolicy Bypass -File Invoke-BraveDebloat.ps1`
from its own folder, forwards the arguments, and returns the script's exit code. Started from Explorer, it
waits for Enter before closing. The launcher writes nothing itself; the dry-run default and `-Apply` rule
of the script still apply.

`scripts/Build-Launcher.ps1 -Version X.Y.Z` compiles it with the C# compiler that ships in .NET
Framework, so no SDK download is needed on Windows. Pass `-CompilerPath` to use Mono's `mcs` elsewhere.
Keep the source C# 5 compatible for that compiler.

## winget

`scripts/New-PackageManifests.ps1 -Version X.Y.Z` reads the release `SHA256SUMS.txt` and writes
`winget/manifests/o/osfv/BraveDebloater/X.Y.Z/osfv.BraveDebloater.*.yaml` (schema 1.10.0, portable zip,
`ArchiveBinariesDependOnPath: true` so the whole extracted folder lands on `PATH`). The release workflow
writes the same files into its `package-manifests` artifact.

Submitting to [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs):

- First version: `wingetcreate submit --prtitle "New package: osfv.BraveDebloater version X.Y.Z" <manifest folder>`
  from a Windows machine, or open the pull request by hand. New packages wait for moderator review.
- Later versions: add a `WINGET_TOKEN` repository secret (GitHub personal access token, `public_repo`
  scope, on an account that has forked winget-pkgs). The release workflow's `winget` job then runs
  `wingetcreate submit` automatically. Without the secret the job prints the manual command.

After acceptance: `winget install osfv.BraveDebloater`, then `BraveDebloat` from any shell.

Backups default to `backups/` next to the script, which for winget is inside its package folder
(`%LOCALAPPDATA%\Microsoft\WinGet\Packages\osfv.BraveDebloater_...`). winget owns that folder: upgrades
uninstall the previous version first and `winget uninstall --purge` deletes everything in it, and nothing
in this repository relocates or verifies those files (the Scoop manifest persists `backups/`, winget has
no equivalent). Keep restore points out of the package folder when installing through winget:

```powershell
BraveDebloat -Preset Extreme -BackupDirectory "$env:LOCALAPPDATA\BraveDebloater\backups" -Apply
BraveDebloat -ListBackups -BackupDirectory "$env:LOCALAPPDATA\BraveDebloater\backups"
```

## Scoop

`scoop/bravedebloater.json` installs the source zip and shims `Invoke-BraveDebloat.ps1` as
`bravedebloat`. `persist: backups` keeps backups across upgrades. Scoop needs no approval:

```powershell
scoop install https://raw.githubusercontent.com/osfv/BraveDebloater/main/packaging/scoop/bravedebloater.json
```

`New-PackageManifests.ps1` rewrites this file for each release; commit the result after the release is
published so the raw URL above serves the current version. `checkver` and `autoupdate` also let a Scoop
bucket track new releases on its own.
