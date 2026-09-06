# bootstrap

Public, secretless stage-zero remote access bootstrap scripts served by a
Cloudflare Worker at `bootstrap.yaronhersh.xyz`.

## One-line commands

Fedora:

```bash
curl -fsSL https://bootstrap.yaronhersh.xyz/fedora | bash
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

## Verify the checksum

Exact-version routes are immutable. Compare the served checksum with the release manifest:

```bash
curl -fsSL "https://bootstrap.yaronhersh.xyz/fedora/v1.0.0.sha256"
curl -fsSL "https://bootstrap.yaronhersh.xyz/fedora/v1.0.0" | shasum -a 256
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
