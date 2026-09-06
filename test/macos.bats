setup_file() {
  PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export PROJECT_ROOT
}

setup_fake_macos() {
  BATS_MOCK_STATE_DIR=$(mktemp -d)
  export BATS_MOCK_STATE_DIR

  FAKE_BREW_PREFIX=$(mktemp -d)
  export FAKE_BREW_PREFIX
  export BOOTSTRAP_TEST_HOME="${PROJECT_ROOT}"
  export BOOTSTRAP_BREW_PREFIX="${FAKE_BREW_PREFIX}"
  export BOOTSTRAP_ALLOW_NON_DARWIN=1
  export BOOTSTRAP_DEVELOPER_DIR="${BATS_MOCK_STATE_DIR}/clt"
  mkdir -p "${BOOTSTRAP_DEVELOPER_DIR}"

  export TAILSCALE_BACKEND_STATE=NeedsLogin
  export TAILSCALE_RUN_SSH=false
  export TAILSCALE_HOSTNAME=macbook-pro
  export MOCK_LOCAL_HOSTNAME=macbook-pro
  export BATS_MOCK_BIN_DIR="${PROJECT_ROOT}/test/helpers/macos-bin"
  export BATS_MOCK_TAILSCALE_SOURCE="${PROJECT_ROOT}/test/helpers/bin/tailscale"
  export BOOTSTRAP_TEST_FIXTURES_DIR="${PROJECT_ROOT}/test/fixtures"
}

install_mock_brew() {
  mkdir -p "${FAKE_BREW_PREFIX}/bin"
  cp "${PROJECT_ROOT}/test/helpers/macos-bin/brew" "${FAKE_BREW_PREFIX}/bin/brew"
  chmod +x "${FAKE_BREW_PREFIX}/bin/brew"
}

teardown() {
  rm -rf "${BATS_MOCK_STATE_DIR:-}" "${FAKE_BREW_PREFIX:-}"
}

# Same as run_bootstrap but WITHOUT the fake brew prefix on PATH: models a
# non-login shell where brew exists on disk but is not on PATH.
run_bootstrap_no_brew_path() {
  BOOTSTRAP_TEST_HOME="${PROJECT_ROOT}" \
    PATH="${PROJECT_ROOT}/test/helpers/bin:/usr/bin:/bin" \
    run bash "${PROJECT_ROOT}/scripts/macos.sh"
}

run_bootstrap() {
  run env BOOTSTRAP_TEST_HOME="${PROJECT_ROOT}" \
    PATH="${FAKE_BREW_PREFIX}/bin:${PROJECT_ROOT}/test/helpers/bin:/usr/bin:/bin" \
    bash "${PROJECT_ROOT}/scripts/macos.sh"
}

@test "fresh macOS installation succeeds" {
  setup_fake_macos
  install_mock_brew
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"Remote access ready"* ]]
  [[ "$output" == *"100.64.0.1"* ]]
  [ -f "${BATS_MOCK_STATE_DIR}/tailscale-installed" ]
}

@test "missing Xcode Command Line Tools stops before mutation" {
  setup_fake_macos
  export BOOTSTRAP_DEVELOPER_DIR=""
  export BOOTSTRAP_XCODE_SELECT_MISSING=1
  run_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"Xcode Command Line Tools are required"* ]]
  [ ! -f "${BATS_MOCK_STATE_DIR}/tailscale-installed" ]
}

@test "existing Homebrew installation is reused" {
  setup_fake_macos
  install_mock_brew
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"Homebrew already installed"* ]]
}

@test "brew present at prefix but not on PATH is reused, installer not run" {
  setup_fake_macos
  install_mock_brew
  run_bootstrap_no_brew_path
  [ "$status" -eq 0 ]
  [[ "$output" == *"Homebrew already installed at"* ]]
  [[ "$output" != *"Installing Homebrew..."* ]]
}

@test "Tailscale login URL is printed before tailscale up returns" {
  setup_fake_macos
  install_mock_brew
  export TAILSCALE_UP_DELAY=2
  run_bootstrap
  [ "$status" -eq 0 ]
  local url_at success_at
  url_at=$(printf '%s\n' "$output" | grep -n 'To authenticate, visit:' | head -n1 | cut -d: -f1)
  success_at=$(printf '%s\n' "$output" | grep -n '^Success\.' | head -n1 | cut -d: -f1)
  [ -n "$url_at" ] && [ -n "$success_at" ] && [ "$url_at" -lt "$success_at" ]
  [[ "$output" == *"https://login.tailscale.com/a/mock"* ]]
}

@test "Homebrew is installed when missing" {
  setup_fake_macos
  export BOOTSTRAP_HOMEBREW_INSTALLER_CMD="${PROJECT_ROOT}/test/helpers/stub-homebrew-install.sh"
  run_bootstrap
  [ "$status" -eq 0 ]
  [ -f "${BATS_MOCK_STATE_DIR}/homebrew-installer-downloaded" ]
  [ -f "${BATS_MOCK_STATE_DIR}/homebrew-installed" ]
}

@test "already-connected node with SSH enabled skips authentication" {
  setup_fake_macos
  install_mock_brew
  export TAILSCALE_BACKEND_STATE=Running
  export TAILSCALE_RUN_SSH=true
  export TAILSCALE_HOSTNAME=macbook-pro
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"already connected with SSH enabled"* ]]
}

@test "connected node with SSH enabled updates mismatched hostname" {
  setup_fake_macos
  install_mock_brew
  export TAILSCALE_BACKEND_STATE=Running
  export TAILSCALE_RUN_SSH=true
  export TAILSCALE_HOSTNAME=old-host
  export BOOTSTRAP_HOSTNAME=new-host
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"updating hostname to new-host"* ]]
  [[ "$output" == *"Host: new-host"* ]]
}

@test "second run does not restart tailscaled service" {
  setup_fake_macos
  install_mock_brew
  run_bootstrap
  [ "$status" -eq 0 ]
  [ "$(tr -d '[:space:]' <"${BATS_MOCK_STATE_DIR}/brew-services-start-count")" -eq 1 ]
  export TAILSCALE_BACKEND_STATE=Running
  export TAILSCALE_RUN_SSH=true
  run_bootstrap
  [ "$status" -eq 0 ]
  [ "$(tr -d '[:space:]' <"${BATS_MOCK_STATE_DIR}/brew-services-start-count")" -eq 1 ]
  [[ "$output" == *"already running via Homebrew services"* ]]
}

@test "connected node with RunSSH disabled fails verification" {
  setup_fake_macos
  install_mock_brew
  export TAILSCALE_BACKEND_STATE=Running
  export TAILSCALE_RUN_SSH=false
  export TAILSCALE_LEAVE_RUN_SSH=false
  run_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tailscale SSH is not enabled"* ]]
}

@test "BOOTSTRAP_HOSTNAME override is honored" {
  setup_fake_macos
  install_mock_brew
  export BOOTSTRAP_HOSTNAME=custom-host
  export TAILSCALE_HOSTNAME=custom-host
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"Host: custom-host"* ]]
}

@test "invalid BOOTSTRAP_HOSTNAME is rejected" {
  setup_fake_macos
  install_mock_brew
  export BOOTSTRAP_HOSTNAME='bad hostname'
  run_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid BOOTSTRAP_HOSTNAME"* ]]
}

@test "generic hostname gets a hashed (non-reversible) platform suffix" {
  setup_fake_macos
  install_mock_brew
  export MOCK_LOCAL_HOSTNAME=localhost
  export TAILSCALE_HOSTNAME=mac-eabf6fd8
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"mac-eabf6fd8"* ]]
  [[ "$output" != *"abcdef12"* ]]
}

@test "installer sha256 mismatch aborts before running installer" {
  setup_fake_macos
  export MOCK_HOMEBREW_INSTALLER_SHA256_MISMATCH=1
  run_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"Homebrew installer checksum mismatch"* ]]
  [ ! -f "${BATS_MOCK_STATE_DIR}/homebrew-installed" ]
}

@test "running as root is rejected" {
  setup_fake_macos
  run env BOOTSTRAP_TEST_HOME="${PROJECT_ROOT}" BOOTSTRAP_TEST_EUID=0 \
    PATH="${FAKE_BREW_PREFIX}/bin:${PROJECT_ROOT}/test/helpers/bin:/usr/bin:/bin" \
    bash "${PROJECT_ROOT}/scripts/macos.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Do not run this script as root"* ]]
}

@test "test overrides are ignored when invoked via bash -c" {
  setup_fake_macos
  install_mock_brew
  run env PATH="${FAKE_BREW_PREFIX}/bin:${PROJECT_ROOT}/test/helpers/bin:/usr/bin:/bin" \
    bash -c "BOOTSTRAP_TEST_HOME='${PROJECT_ROOT}' BOOTSTRAP_TEST_EUID=0 BOOTSTRAP_ALLOW_NON_DARWIN=1 bash -c \"\$(cat '${PROJECT_ROOT}/scripts/macos.sh')\""
  [[ "$output" != *"Do not run this script as root"* ]]
}

@test "failure prints stage and rerun command without secrets" {
  setup_fake_macos
  run env PATH="/usr/bin:/bin" bash "${PROJECT_ROOT}/scripts/macos.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bootstrap failed at stage"* ]]
  [[ "$output" == *"curl -fsSL https://bootstrap.yaronhersh.xyz/macos | bash"* ]]
}

@test "truncated script executes nothing" {
  setup_fake_macos
  local truncated_script
  truncated_script=$(mktemp)
  sed '$d' "${PROJECT_ROOT}/scripts/macos.sh" >"${truncated_script}"
  run bash "${truncated_script}"
  [ "$status" -eq 0 ]
  [ ! -f "${BATS_MOCK_STATE_DIR}/tailscale-installed" ]
  rm -f "${truncated_script}"
}

@test "no byte prefix within final 160 bytes executes stages" {
  setup_fake_macos
  install_mock_brew
  python3 - "${PROJECT_ROOT}/scripts/macos.sh" "${BATS_MOCK_STATE_DIR}" <<'PY'
import os
import pathlib
import subprocess
import sys

source = pathlib.Path(sys.argv[1])
state_dir = pathlib.Path(sys.argv[2])
data = source.read_bytes()
size = len(data)
start = max(0, size - 160)
invoke_line = b'__bootstrap_entry__ "$@" bootstrap-entry-v1'
invoke_start = data.rfind(invoke_line)
if invoke_start == -1:
    raise SystemExit('invoke line not found')
invoke_end = invoke_start + len(invoke_line)
env = os.environ.copy()
stage_markers = (
    "Installing Tailscale via Homebrew",
    "Remote access ready",
)

for end in range(start, size):
    if end >= invoke_end:
        continue
    truncated = data[:end]
    result = subprocess.run(
        ["bash"],
        input=truncated,
        capture_output=True,
        env=env,
    )
    (state_dir / "tailscale-installed").unlink(missing_ok=True)
    output = result.stdout.decode() + result.stderr.decode()
    if (state_dir / "tailscale-installed").exists():
        raise SystemExit(f"stages executed for truncation ending at byte {end}")
    for marker in stage_markers:
        if marker in output:
            raise SystemExit(f"stage marker '{marker}' seen at byte {end}")
PY
}
