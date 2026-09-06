setup_file() {
  PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export PROJECT_ROOT
}

setup_fake_macos() {
  BATS_MOCK_STATE_DIR=$(mktemp -d)
  export BATS_MOCK_STATE_DIR

  FAKE_BREW_PREFIX=$(mktemp -d)
  export FAKE_BREW_PREFIX
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

run_bootstrap() {
  run env PATH="${FAKE_BREW_PREFIX}/bin:${PROJECT_ROOT}/test/helpers/bin:/usr/bin:/bin" \
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
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"already connected with SSH enabled"* ]]
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
  run env BOOTSTRAP_TEST_EUID=0 PATH="${FAKE_BREW_PREFIX}/bin:${PROJECT_ROOT}/test/helpers/bin:/usr/bin:/bin" \
    bash "${PROJECT_ROOT}/scripts/macos.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Do not run this script as root"* ]]
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
