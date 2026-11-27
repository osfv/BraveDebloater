# Install

Back to the [README](../README.md).

One line in PowerShell (Windows PowerShell 5.1 or PowerShell 7 on Windows, macOS, or Linux):

```powershell
irm https://raw.githubusercontent.com/osfv/BraveDebloater/main/install.ps1 | iex
```

It downloads the latest release zip and `SHA256SUMS.txt`, refuses to continue if the hash does not match, extracts to `%LOCALAPPDATA%\Programs\BraveDebloater` on Windows, or to `$XDG_DATA_HOME/BraveDebloater` on macOS and Linux (`~/.local/share/BraveDebloater` when that variable is not set), and prints the folder it used with the preview command. Running it again upgrades in place and keeps `backups/`. It does not touch Brave. To pick a version or folder:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/osfv/BraveDebloater/main/install.ps1))) -Version 0.9.4 -Destination C:\Tools\BraveDebloater
```

Scoop users can install straight from this repository, with a `bravedebloat` shim and `backups/` persisted across upgrades:

```powershell
scoop install https://raw.githubusercontent.com/osfv/BraveDebloater/main/packaging/scoop/bravedebloater.json
```

winget: releases from 0.5.0 ship `BraveDebloater-vX.Y.Z-windows.zip` with a `BraveDebloat.exe` launcher so the package can be listed in [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) as `osfv.BraveDebloater`. Once that listing is accepted, `winget install osfv.BraveDebloater` puts `BraveDebloat` on your `PATH`; it runs `Invoke-BraveDebloat.ps1` with the same arguments (`BraveDebloat -Preset Extreme`). Because winget owns its package folder and upgrades reinstall it, pass `-BackupDirectory` pointing outside that folder (for example `"$env:LOCALAPPDATA\BraveDebloater\backups"`) so restore points survive. See [packaging/README.md](../packaging/README.md).

Manual install: download `BraveDebloater-vX.Y.Z.zip` from the Releases page, then extract it to a folder you control, such as `Downloads\BraveDebloater`. To verify the archive first, download `SHA256SUMS.txt` from the same release and compare it with:

```powershell
Get-FileHash .\BraveDebloater-vX.Y.Z.zip -Algorithm SHA256
```

Releases from 0.9.0 carry a signed build provenance (`BraveDebloater-vX.Y.Z.sigstore.json`). With the [GitHub CLI](https://cli.github.com), confirm that this repository's release workflow built the archive from the `vX.Y.Z` tag:

```powershell
gh attestation verify .\BraveDebloater-vX.Y.Z.zip --repo osfv/BraveDebloater --source-ref refs/tags/vX.Y.Z --signer-workflow osfv/BraveDebloater/.github/workflows/release.yml
```

Open PowerShell in the extracted folder and run the default dry-run:

```powershell
.\Invoke-BraveDebloat.ps1
```

Review the output before applying changes. If Windows PowerShell blocks local scripts (`Restricted` execution policy), allow them for your user once with `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`; the installer prints this hint when it applies.

Next: [preview, apply, and undo](../README.md#quick-start), or read the [usage guide](usage.md).
