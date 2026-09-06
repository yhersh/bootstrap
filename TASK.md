# Task: build the bootstrap Worker (v1 + Windows)

You are working in a git worktree of the public repo `yhersh/bootstrap`, branch
`feat/bootstrap-worker`, base `origin/main`. Read `docs/design.md` first: it is
the approved design and you implement it as written, with ONE scope addition
(Windows, below). Secrets must never appear in this repo, in tests, or in
output: it is public.

## Deliverables

1. `scripts/fedora.sh` — exactly per the spec: install Tailscale from the
   official repo, enable Tailscale SSH (`tailscale up --ssh`), guide browser
   auth, verify, idempotent, `set -euo pipefail`, no secrets, no dotfiles
   access. Support every currently supported Fedora release.
2. `scripts/windows.ps1` — the Windows sibling (scope addition, keep it the
   same shape and rules):
   - install Tailscale (winget `Tailscale.Tailscale`), run `tailscale up --ssh`
     and print the auth URL
   - enable OpenSSH Server (`Add-WindowsCapability OpenSSH.Server~~~~0.0.1.0`,
     service automatic + started, firewall rule), and make PowerShell the
     default SSH shell (HKLM:\SOFTWARE\OpenSSH DefaultShell)
   - ensure Python 3 is present (winget `Python.Python.3.12`) — the fleet
     agent needs it
   - optional flag `-With Jump,Sunshine`: winget-install Jump Desktop Connect
     and Sunshine (LizardByte). Default is neither. Verify the winget ids
     exist via `winget search` at runtime and print what you would do under
     `-WhatIf`.
   - idempotent, `$ErrorActionPreference = 'Stop'`, requires elevation and
     says so if not elevated, never embeds credentials.
   - invocation to document: `irm https://bootstrap.yaronhersh.xyz/windows | iex`
     (and how to pass `-With` when piped: download to a file, then run).
3. `src/worker.ts` — Cloudflare Worker serving `/fedora` → fedora.sh and
   `/windows` → windows.ps1 with the headers the spec lists
   (`text/plain; charset=utf-8`, `Cache-Control`, `X-Content-Type-Options`,
   `X-Bootstrap-Version`), plus `/` (usage text) and `/healthz`. Scripts are
   bundled at build time (import as text) — no GitHub fetch at request time
   (spec: no runtime dependency on GitHub). `/releases/manifest.json` served
   from `releases/manifest.json`.
4. `wrangler.jsonc` — name `bootstrap`, route `bootstrap.yaronhersh.xyz/*`
   (zone `yaronhersh.xyz`), `compatibility_date` current, observability on.
   DO NOT run `wrangler deploy` or create DNS/routes: the operator deploys.
   `wrangler dev` / `npm test` are fine.
5. Tests: `test/fedora.bats` (bats, shellcheck), `test/windows.Tests.ps1`
   (Pester if `pwsh` is available; otherwise a `pwsh -NoProfile -Command
   "Invoke-ScriptAnalyzer"`-style lint is acceptable, but say so in the PR),
   `test/worker.test.ts` (vitest + `@cloudflare/vitest-pool-workers`): routes,
   headers, 404 on unknown path, byte-identical body to the script file.
   `shellcheck scripts/fedora.sh` clean.
6. `releases/manifest.json`, `package.json` (scripts: `test`, `lint`, `dev`,
   `deploy`), `README.md` (both commands, what runs, what it never does, how
   to verify the checksum), `.github/workflows/ci.yml` running lint + tests
   on PR.

## Workflow

- Commit in small steps on this branch. When done and green locally, push and
  open a PR against `main` with `gh pr create` (title
  `feat: bootstrap worker serving /fedora and /windows`). Describe what you
  verified and how. Do NOT merge; the supervisor merges.
- If something in the spec is impossible or wrong, do the rest and state it
  plainly in the PR body. Do not silently narrow scope.
- End by printing exactly: `TASK DONE: <pr-url>` (or `TASK BLOCKED: <reason>`).
