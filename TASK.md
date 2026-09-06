# Task: security fix round 1

Public repo `yhersh/bootstrap`, branch `fix/security-review-round-1`, base `origin/main`.
Read `SECURITY-REVIEW.md` (an independent assessment of main). Fix the items
below; leave the review file and this brief OUT of the final PR (delete both
before opening it). Never introduce a secret; this repo is public.

## Fix (required)

- **H1** `scripts/windows.ps1`: never leave sshd reachable off-tailnet. Before
  starting sshd: remove/disable the default "OpenSSH SSH Server (sshd)" any-address
  inbound rule, and create ONE inbound TCP/22 allow rule scoped to the Tailscale
  address range `100.64.0.0/10` (RemoteAddress) — also restrict to the Tailscale
  interface alias if present. Order: install → configure → firewall → start service.
  Verify the effective rule set and fail loudly if any TCP/22 allow rule is broader.
- **M1** `scripts/windows.ps1`: Tailscale SSH is not supported on Windows. Drop
  `--ssh`; run `tailscale up` (print auth URL), then rely on OpenSSH over the
  tailnet. Check `$LASTEXITCODE` after every native command; final verification:
  tailscale backend state Running, sshd Running, exactly the scoped firewall rule.
  Set `$PSNativeCommandUseErrorActionPreference = $true` where available.
- **M5** `scripts/windows.ps1`: the "Jump" mapping `9NBLGGH4Z1SP` is ShareX. Find
  the correct Jump Desktop Connect winget/msstore id; verify it via the winget-pkgs
  manifests on GitHub. If it cannot be verified, REMOVE Jump from `-With` and say so
  in the PR — do not guess. Assert package ids and display names in tests.
- **M2** `scripts/fedora.sh`: guard against partial download: define everything,
  then a single final `main "$@"` at the very end; nothing executes above it.
  Add a bats test that truncates the script before the last line and asserts
  nothing ran.
- **M8** `wrangler.jsonc` / `src/worker.ts`: the Text rule matches `**/*.json`, so
  `releases/manifest.json` is served as a string. Remove `.json` from the Text
  rule (import the manifest as JSON) or parse the text explicitly; add a vitest
  that `/releases/manifest.json` returns an object with `scripts.fedora.sha256`.
- **M9** `.github/workflows/ci.yml`: pin `actions/*` to full commit SHAs (with a
  version comment), add top-level `permissions: contents: read`, and
  `persist-credentials: false` on checkout.
- **M11** `.gitignore`: add `.env*`, `*.pem`, `*.key`, `id_ed25519*`, `id_rsa*`,
  `credentials.json`, `coverage/`, `.dev.vars*` (keep `.dev.vars` ignored).
- **M3** `scripts/fedora.sh`: download the tailscale.repo into a private temp
  file, assert it contains `gpgcheck=1` and `repo_gpgcheck=1` and the expected
  `pkgs.tailscale.com` baseurl before installing it atomically (0644, root);
  validate an existing repo file the same way instead of trusting its existence.
  Use `curl --proto '=https' --tlsv1.2`.
- **M4** `scripts/windows.ps1`: resolve pwsh/powershell for DefaultShell from
  fixed system paths (`$env:ProgramFiles\PowerShell\7\pwsh.exe`,
  `$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`), not PATH.
- **L2** `scripts/fedora.sh`: make the documented hostname override actually
  reach the script (document `BOOTSTRAP_HOSTNAME=x bash -c "$(curl ...)"` or read
  it from the env of the executing shell); validate hostname format.
- **L1** `scripts/fedora.sh`: SSH verification must parse `tailscale status --json`
  (`.Self` / prefs) structurally; fail closed, never substring-match "ssh".
- **L4** `scripts/run-windows-tests.mjs`: when pwsh is missing, exit non-zero in
  CI (`CI=true`) and 0 with a clear SKIP locally.

## Skip (document in PR body, do not implement)
H2 (independent trust anchor: design trade-off), M6/M7/M10 (follow-ups).

## Workflow
`npm install`, `npm test`, `shellcheck scripts/fedora.sh` green. Small commits.
Delete `TASK.md` and `SECURITY-REVIEW.md`, push, open a PR against main
(`gh pr create`, title `fix: security review round 1 — Windows SSH scope, partial-download guard, manifest, CI pins`)
with a findings→fix table and what you verified. Do NOT merge. End with exactly
`TASK DONE: <pr-url>` or `TASK BLOCKED: <reason>`.
