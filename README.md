# bootstrap

Public, secretless stage-zero remote access bootstrap scripts served by a
Cloudflare Worker at `bootstrap.yaronhersh.xyz`.

## One-line commands

Fedora:

```bash
curl -fsSL https://bootstrap.yaronhersh.xyz/fedora | bash
```

macOS:

```bash
curl -fsSL https://bootstrap.yaronhersh.xyz/macos | bash
```

Windows (Administrator PowerShell):

```powershell
irm https://bootstrap.yaronhersh.xyz/windows | iex
```

Optional Windows components (Sunshine) require saving
the script first when piping:

```powershell
irm https://bootstrap.yaronhersh.xyz/windows -OutFile bootstrap-windows.ps1
.\bootstrap-windows.ps1 -With Sunshine
```

## What runs

### Fedora (`scripts/fedora.sh`)

- Verifies the host is Fedora with `dnf`, `systemctl`, `curl`, and `sudo`
- Adds Tailscale's official Fedora repository and installs `tailscale`
- Enables and starts `tailscaled`
- Runs `tailscale up --ssh` (or `tailscale set --ssh=true` when already connected)
- Verifies Tailscale connectivity, SSH, and an assigned Tailscale IPv4 address

Optional hostname override:

```bash
BOOTSTRAP_HOSTNAME=my-host bash -c "$(curl -fsSL https://bootstrap.yaronhersh.xyz/fedora)"
```

### macOS (`scripts/macos.sh`)

- Refuses to run as root; requires an admin user with `sudo`
- Ensures Xcode Command Line Tools are installed (prompts via `xcode-select --install` when missing)
- Installs Homebrew from a pinned `Homebrew/install` commit with SHA-256 verification when `brew` is absent
- Installs the Homebrew `tailscale` formula (not the GUI cask) and starts `tailscaled` via `brew services`
- Runs `tailscale up --ssh` (or `tailscale set --ssh=true` when already connected)
- Verifies Tailscale connectivity, SSH, and an assigned Tailscale IPv4 address

Optional hostname override:

```bash
BOOTSTRAP_HOSTNAME=my-host bash -c "$(curl -fsSL https://bootstrap.yaronhersh.xyz/macos)"
```

Notes:

- Tailscale SSH on macOS requires the open-source `tailscaled` from Homebrew; the App Store or cask GUI clients cannot serve Tailscale SSH.
- The script does not enable macOS Remote Login (`sshd` on all interfaces); access stays tailnet-only.
- If Xcode Command Line Tools are missing, approve the GUI installer dialog and rerun the bootstrap command.

### Windows (`scripts/windows.ps1`)

- Installs Tailscale via winget (`Tailscale.Tailscale`) and runs `tailscale up`
- Installs OpenSSH Server, restricts SSH firewall access to the Tailscale CIDR, starts `sshd`, and sets PowerShell as the default SSH shell
- Ensures Python 3.12 is present via winget (`Python.Python.3.12`)
- Optionally installs Sunshine with `-With Sunshine`

## What it never does

- Embed Tailscale auth keys, GitHub tokens, SSH private keys, or other secrets
- Access or clone a private dotfiles repository
- Install a full workstation profile
- Fetch scripts from GitHub at request time (the Worker bundles committed bytes at build time)

## What the scripts fetch and how it is verified

| Asset | Source | Verification |
|---|---|---|
| Fedora Tailscale repo file | `pkgs.tailscale.com` over HTTPS TLS 1.2+ | Repo file structure and `https://pkgs.tailscale.com` URLs validated before install |
| Fedora `tailscale` RPM | Tailscale Fedora repository via `dnf` | RPM GPG checks from the official repo configuration |
| macOS Homebrew installer | Pinned `Homebrew/install` commit (`7a133dcc74051ee4efc79467ed215dfedf45aea2`) over HTTPS TLS 1.2+ | SHA-256 of the downloaded `install.sh` must match the constant in `scripts/macos.sh` before execution |
| macOS `tailscale` formula | Homebrew bottle via `brew install` | Homebrew formula checksums and bottle signatures |
| Windows Tailscale | `winget` package index | Winget package identity `Tailscale.Tailscale` |
| Windows OpenSSH / Python / optional Sunshine | `winget` package index | Winget package IDs pinned in the script |

Tailscale packages on Fedora and macOS ultimately come from Tailscale's official distribution channels (RPM repo and Homebrew formula, respectively).

## Verify the checksum

Exact-version routes are immutable. Compare the served checksum with the release manifest:

```bash
curl -fsSL "https://bootstrap.yaronhersh.xyz/fedora/v1.0.0.sha256"
curl -fsSL "https://bootstrap.yaronhersh.xyz/fedora/v1.0.0" | shasum -a 256

curl -fsSL "https://bootstrap.yaronhersh.xyz/macos/v1.0.0.sha256"
curl -fsSL "https://bootstrap.yaronhersh.xyz/macos/v1.0.0" | shasum -a 256
```

The manifest at `/releases/manifest.json` publishes the same SHA-256 values.

## Development

```bash
npm install
npm test
npm run dev
```

Deploy manually with `npm run deploy` after review. CI does not deploy.

## License

MIT — see [LICENSE](LICENSE).
