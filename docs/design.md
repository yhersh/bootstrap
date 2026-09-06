# Secretless Fedora Remote-Access Bootstrap Design

Status: Approved

## Purpose

Provide a canonical one-command bootstrap for a fresh Fedora machine:

```bash
curl -fsSL https://bootstrap.yaronhersh.xyz/fedora | bash
```

The command installs Tailscale, enables Tailscale SSH, guides browser-based
authorization, verifies remote access, and stops. It contains no embedded
credentials and does not access the private dotfiles repository.

## Goals

- Support every currently supported Fedora release.
- Establish authenticated Tailscale SSH from one public command.
- Use `bootstrap.yaronhersh.xyz` as the stable distribution endpoint.
- Keep the bootstrap source public, auditable, versioned, and testable.
- Serve scripts without depending on GitHub availability at request time.
- Make repeated execution safe and avoid unnecessary changes.
- Leave private workstation provisioning to a separate remote-access stage.

## Non-goals

- Supporting Debian, Ubuntu, Arch, macOS, or Windows in version 1.
- Installing OpenSSH or importing GitHub public keys.
- Embedding Tailscale auth keys, GitHub tokens, SSH keys, or other secrets.
- Authenticating GitHub or cloning the private dotfiles repository.
- Installing the complete workstation profile.
- Dynamically generating scripts based on request metadata.
- Collecting custom analytics or storing client IP addresses.

## Architecture

Create a public repository named `yhersh/bootstrap`. It is the source of truth
for the Fedora bootstrap script, Cloudflare Worker, tests, and releases.

Suggested layout:

```text
yhersh/bootstrap/
├── scripts/
│   └── fedora.sh
├── src/
│   └── worker.ts
├── test/
│   ├── fedora.bats
│   └── worker.test.ts
├── releases/
│   └── manifest.json
├── package.json
├── wrangler.jsonc
├── README.md
└── LICENSE                  # MIT
```

Use the MIT license so the public bootstrap can be inspected, copied, and
adapted without ambiguity.

Wrangler bundles the exact Fedora script bytes into the Worker during deploy.
The Worker never fetches GitHub, Tailscale, R2, KV, or another origin while
serving a request. GitHub outages therefore do not affect an already-deployed
bootstrap release.

The Worker uses a custom domain:

```text
bootstrap.yaronhersh.xyz
```

The domain is a distribution front door. The public GitHub repository remains
the review and release authority.

## HTTP interface

| Route | Behavior | Cache policy |
|---|---|---|
| `/` | Human-readable usage, current version, and source links | Five minutes |
| `/fedora` | Current stable Fedora script | Five minutes |
| `/fedora/v1` | Current stable version within major version 1 | Five minutes |
| `/fedora/v1.0.0` | Immutable exact Fedora script | One year, immutable |
| `/fedora/v1.0.0.sha256` | SHA-256 for the exact script | One year, immutable |
| `/health` | Release and Worker build metadata | No cache |

Only `GET` and `HEAD` are accepted. Other methods return `405 Method Not
Allowed` with an `Allow: GET, HEAD` header. Unknown paths return `404` without
redirecting to executable content.

Script responses include:

```text
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Content-Security-Policy: default-src 'none'
X-Bootstrap-Version: 1.0.0
```

Exact-version responses include:

```text
Cache-Control: public, max-age=31536000, immutable
```

Moving aliases use:

```text
Cache-Control: public, max-age=300
```

## Fedora bootstrap flow

The script runs as the normal Fedora user and invokes `sudo` only for operations
that require root privileges.

### 1. Preflight

- Enable strict Bash error handling.
- Confirm `/etc/os-release` identifies Fedora.
- Confirm `dnf`, `systemctl`, `curl`, and `sudo` are available.
- Confirm the session can reach HTTPS endpoints.
- Acquire sudo authorization before making changes.
- Reject execution as root to avoid creating root-owned user state.

The script does not pin a Fedora release number. It supports releases that are
currently supported by Fedora and use the expected `dnf` and systemd interfaces.

### 2. Install Tailscale

- Configure Tailscale's official stable Fedora RPM repository.
- Install the `tailscale` package with `dnf`.
- Enable and start `tailscaled`.
- Reuse an existing official repository and installation when present.

The script configures the official RPM repository directly instead of executing
a nested remote installer script.

### 3. Select the Tailscale hostname

- Honor `BOOTSTRAP_HOSTNAME` when supplied.
- Otherwise preserve a meaningful existing hostname.
- Treat generic values such as `localhost`, `localhost-live`, and their DHCP
  suffixes as unsuitable.
- For a generic hostname, use `fedora-<first-eight-machine-id-characters>`.
- Set only Tailscale's advertised hostname; do not change Fedora's system
  hostname.

Example override:

```bash
BOOTSTRAP_HOSTNAME=proart-vm \
  bash -c "$(curl -fsSL https://bootstrap.yaronhersh.xyz/fedora)"
```

### 4. Authenticate and enable SSH

For a disconnected node, run:

```bash
sudo tailscale up --ssh --hostname="$BOOTSTRAP_HOSTNAME"
```

Tailscale prints its browser authorization URL. The script waits for the user to
approve the node. No reusable auth key is accepted or generated by the default
flow.

For an already-connected node, run the equivalent of:

```bash
sudo tailscale set --ssh=true --hostname="$BOOTSTRAP_HOSTNAME"
```

This avoids forcing reauthentication.

### 5. Verify

Require all of the following before reporting success:

- `tailscaled` is active.
- Tailscale reports the node as connected.
- Tailscale SSH is enabled.
- The node has a Tailscale IPv4 address.

Print a concise completion card:

```text
Remote access ready
Host: proart-vm
Tailscale IP: 100.x.x.x
Next: tell the operator "done"
```

The script stops after remote access is ready. A remote operator can then perform
GitHub authentication, transfer an audited repository bundle, or run the
private workstation bootstrap.

## Idempotence and failure handling

Every operation belongs to a named stage:

```text
preflight
repository
install
service
authenticate
verify
```

An error trap prints the failed stage, exit code, and exact rerun command. It
must not print environment variables, Tailscale node keys, or credentials.

Behavior on failure:

- Unsupported operating systems fail before mutation.
- Existing packages and repository files are reused.
- Existing active services are not restarted unnecessarily.
- Interrupted browser authorization leaves the installed daemon intact.
- Rerunning resumes at authentication or verification.
- Verification failure does not uninstall a working Tailscale installation.
- Temporary files use a private `mktemp` directory and are removed on exit.
- The script performs no speculative rollback that could break existing access.

## Security model

The repository, Worker bundle, and served script contain no:

- Tailscale auth keys or node keys;
- GitHub tokens;
- SSH private keys;
- 1Password credentials;
- Cloudflare credentials; or
- private dotfiles content.

Authentication occurs through Tailscale's browser approval. Deployment
credentials remain in the operator's authenticated local Wrangler profile and
are never committed or returned by the Worker.

The Worker adds no cookies, custom analytics, request-body logging, or client-IP
storage. Normal Cloudflare platform logs remain subject to the account's
standard configuration.

A compromised Cloudflare account could replace the served script. Mitigations:

- enforce account MFA;
- keep the Worker intentionally small;
- deploy only from reviewed commits;
- require an explicit local `wrangler deploy`;
- publish immutable version routes;
- publish checksums in both the Worker and GitHub release; and
- document a versioned raw GitHub fallback.

The checksum endpoint detects transfer or caching errors and allows comparison
with GitHub. It does not independently protect against a compromised Worker when
both script and checksum are served by that Worker.

## Release and deployment process

1. Update `scripts/fedora.sh` and the release manifest.
2. Run ShellCheck, Bats, Worker tests, and secret scanning.
3. Build the Worker and confirm the bundled script matches the committed bytes.
4. Deploy to a Wrangler preview URL.
5. Run the bootstrap twice in a disposable Fedora VM.
6. Confirm the second run performs no unnecessary package or authentication
   changes.
7. Tag the public repository release and publish the script plus checksum.
8. Explicitly deploy the reviewed commit to production with Wrangler.
9. Verify `/health`, the exact-version route, checksum, and moving aliases.
10. Update `/fedora` and `/fedora/v1` only after exact-version verification.

Initial deployment is manual through the authenticated Wrangler CLI. CI-based
deployment is out of scope for version 1, avoiding a Cloudflare deployment token
in the public repository's CI settings.

## Testing strategy

### Fedora script

Use ShellCheck and Bats with command shims for `dnf`, `sudo`, `systemctl`, and
`tailscale`.

Cover:

- fresh Fedora installation;
- existing Tailscale package and repository;
- already-connected node;
- generic and meaningful hostnames;
- `BOOTSTRAP_HOSTNAME` override;
- interrupted browser authorization;
- unsupported operating system;
- missing dependency or sudo access;
- service startup failure;
- verification failure; and
- two consecutive successful runs.

### Worker

Use Vitest with the Workers test environment.

Cover:

- every documented route;
- `HEAD` returns the same status, metadata headers, and `Content-Length` as
  `GET`, with an empty body;
- `404` and `405` behavior;
- `Allow` header;
- security and version headers;
- immutable and moving cache policies;
- alias-to-version mapping;
- exact script byte equality; and
- checksum correctness.

### Security and release checks

- Scan commits for tokens, private keys, and high-entropy credentials.
- Compare the bundled script SHA-256 with the release manifest.
- Verify no Worker code performs runtime network fetches.
- Run an end-to-end smoke test in a disposable Fedora VM before production.

## Acceptance criteria

- A fresh supported Fedora machine reaches authenticated Tailscale SSH using the
  canonical one-line command.
- No reusable credential is embedded in or required by the public script.
- The same command is safe to execute again.
- The Worker serves the script without a runtime origin dependency.
- Exact-version routes are immutable and have published checksums.
- The Worker adds no custom tracking or credential logging.
- Tests cover fresh, repeated, interrupted, and failure paths.
- The private dotfiles repository is not contacted during stage-zero bootstrap.

## Future extensions

Future designs may add Debian/Ubuntu, Arch, and macOS scripts under separate
versioned routes. A Worker dispatcher or staged release mechanism should be
added only when multiple platforms create a concrete need; version 1 remains a
small Fedora-only distribution service.
