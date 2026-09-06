# Task: add the macOS stage-zero bootstrap (`/macos`)

Public repo `yhersh/bootstrap`, branch `feat/macos-bootstrap`, base `origin/main`.
Read `docs/design.md`, then `scripts/fedora.sh` and `scripts/windows.ps1` as they
are on main: they passed an independent security review and a fix round. The
macOS script must meet the SAME bar and reuse the same patterns exactly:
argument-sentinel entrypoint (`__bootstrap_entry__ "$@" bootstrap-entry-v1` as the
final line, nothing executes above it), `set -euo pipefail`, no secrets, no
dotfiles access, idempotent, fail closed, `curl --proto '=https' --tlsv1.2`,
`$LASTEXITCODE`-style checks (bash: check every command), hostname override via
`BOOTSTRAP_HOSTNAME`, rerun command printed on failure. Delete this TASK.md before
opening the PR. This repo is public.

## Goal

`curl -fsSL https://bootstrap.yaronhersh.xyz/macos | bash` on a fresh Mac
(Apple Silicon and Intel, current macOS + previous two) results in the machine
being reachable over **Tailscale SSH** and nothing more. Same contract as Fedora.

## Design decisions (follow these)

1. **Tailscale SSH server needs the open-source `tailscaled`**, which on macOS
   comes from Homebrew (`brew install tailscale`, formula, NOT the cask/App Store
   GUI — those cannot serve Tailscale SSH). Do NOT enable macOS Remote Login
   (`systemsetup -setremotelogin on`): that would expose sshd on every
   interface, which the review rejected for Windows. Tailnet-only by design.
2. **Prerequisites the script must handle, in order, each idempotent:**
   - refuse to run as root; require an admin user with `sudo` (prompt is fine).
   - Xcode Command Line Tools: if `xcode-select -p` fails, run
     `xcode-select --install`, print exactly what to do (approve the GUI dialog),
     and exit non-zero with the rerun command. Do not try to script the GUI.
   - Homebrew: if `brew` is absent, install it with the official installer
     **pinned to a commit** of Homebrew/install, downloaded to a private temp file
     over TLS 1.2+, sha256-verified against a constant in the script, then run
     with `NONINTERACTIVE=1`. Pick the current install.sh commit and compute its
     sha256 as part of this task; record both in the script header. Add
     `/opt/homebrew/bin` or `/usr/local/bin` to PATH for the rest of the run.
   - `brew install tailscale` (formula). Verify `tailscale --version` and that
     the binary is Homebrew's.
   - daemon: `sudo brew services start tailscale` (idempotent: start only if not
     running). Wait for the socket. Verify `tailscale status --json` responds.
   - `sudo tailscale up --ssh --hostname=<name>`; print the auth URL clearly and
     wait for BackendState=Running (bounded wait, then instructions + rerun).
     If already Running and RunSSH is set, say so and skip.
   - verify like fedora.sh: `tailscale status --json` for Running + IPs, and
     `tailscale debug prefs` for `RunSSH=true`; fail closed.
3. **Hostname**: default to the Mac's `scutil --get LocalHostName` lowercased and
   validated; `BOOTSTRAP_HOSTNAME` overrides; same validation function shape as
   fedora.sh.
4. **Privacy/logging**: print hostname + Tailscale IP only; no serial numbers,
   no machine UUID.
5. Everything the script fetches must be listed in the README's inventory table
   with how it is verified (Homebrew installer: pinned commit + sha256; brew
   formula: Homebrew bottle signatures/checksums; Tailscale: from the formula).

## Worker / repo wiring

- `src/worker.ts`: add `/macos` (and `/macos/v1`, `/macos/v1.0.0`, the `.sha256`
  route if fedora has one) exactly like `/fedora`; update `/` usage text and
  `/healthz`; `releases/manifest.json` gets `scripts.macos` with the real sha256
  (the existing vitest hash guard must pass).
- `wrangler.jsonc`: no change needed unless the Text rule must include a new
  extension.
- README: a macOS section mirroring Fedora (command, what it does, what it
  never does, CLT/Homebrew notes, verification).

## Tests

- `test/macos.bats` with shims like `test/helpers/bin/*` for `xcode-select`,
  `brew`, `sudo`, `tailscale`, `scutil`, `curl` (the Homebrew installer download
  must be mocked; never hit the network in tests). Cover: fresh install path,
  CLT-missing stop, brew-present skip, already-connected skip, RunSSH false ->
  fail, hostname override + invalid hostname, truncation byte-prefix test (copy
  the fedora one), installer sha256 mismatch -> abort before running it.
- `shellcheck scripts/macos.sh` clean. `npm test` green (vitest for the new
  routes, HEAD/GET parity, byte-identical body).

## Workflow

Small commits. Delete `TASK.md`. Push, open a PR against main with
`gh pr create` (title `feat: macOS stage-zero bootstrap served at /macos`) with a
"what it fetches and how it is verified" table and what you ran. Do NOT merge,
do NOT deploy. End with exactly `TASK DONE: <pr-url>` or `TASK BLOCKED: <reason>`.
