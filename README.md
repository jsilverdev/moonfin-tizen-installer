# Moonfin Tizen Installer

[Español](README.es.md)

Safe cross-platform installer and updater for **Moonfin** on Samsung Tizen TVs. It uses the signed [Apps2Samsung](https://github.com/Apps2Samsung/Apps2Samsung) catalog, preserves the signing certificate between updates, and verifies the installed application afterwards.

- Windows: `install.ps1`
- Linux: `install.sh`
- Supported Moonfin variants: `Regular` and `Oblong` for Samsung TVs from 2017 onward

The installer never removes an existing application automatically.

## Requirements

- Samsung TV and computer on the same local network.
- Developer Mode enabled on the TV.
- TV `Host PC IP` set to the computer's LAN address.
- Samsung account for the first signing-certificate creation.
- Windows: PowerShell 7 on x64 or ARM64.
- Linux: Bash 4+, Python 3, `curl`, `tar`, `sha256sum`, `awk`, and `find` on x64 or ARM64.

## Usage

Windows:

```powershell
.\install.ps1 -TvIp 192.168.1.11 -Launch
```

Linux:

```bash
chmod +x ./install.sh
./install.sh --tv-ip 192.168.1.11 --launch
```

Useful options:

| Purpose | Windows | Linux |
|---|---|---|
| Select Oblong | `-Variant Oblong` | `--variant Oblong` |
| Validate without installing | `-ValidateOnly` | `--validate-only` |
| Reinstall the same version | `-Force` | `--force` |
| Print the Samsung login URL | `-NoBrowser` | `--no-browser` |
| Allow an intentional downgrade | `-AllowDowngrade` | `--allow-downgrade` |
| Set retry count | `-NetworkRetries 5` | `--network-retries 5` |
| Set the local LAN address | `-LocalIp 192.168.1.100` | `--local-ip 192.168.1.100` |
| Use an existing CLI | `-CliPath <path>` | `--cli-path <path>` |

## Updates and certificates

Run the same command again to update Moonfin. Versions are compared using SemVer, downgrades are blocked by default, remembered variants are preserved, and Apps2Samsung alternative application IDs are recognized.

Keep the `.state` directory. It contains the signing certificate required to update the installed copy without deleting its local data. If the original certificate is missing, expired, or incompatible, the installer stops with guidance instead of uninstalling Moonfin. `.state` and `.tools` must never be committed or shared.

Network operations retry three times by default. If GitHub is temporarily unavailable, an already downloaded Apps2Samsung CLI can be reused.

## Continuous integration

GitHub Actions validates PowerShell and Bash on Windows and Ubuntu. A live contract test also verifies the current Apps2Samsung release, SHA-256 digest, Moonfin catalog, and certificate JSON schema on pushes to `main`, manual runs, and a weekly schedule.
