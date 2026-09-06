setup_file() {
  PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export PROJECT_ROOT
  export PATH="$(dirname "${BATS_TEST_FILENAME}")/helpers/bin:${PATH}"
}

setup_fake_fedora() {
  BATS_MOCK_STATE_DIR=$(mktemp -d)
  export BATS_MOCK_STATE_DIR

  FAKE_ETC=$(mktemp -d)
  export FAKE_ETC
  printf 'ID=fedora\nVERSION_ID=42\n' >"${FAKE_ETC}/os-release"
  printf '0123456789abcdef0123456789abcdef\n' >"${FAKE_ETC}/machine-id"

  export BOOTSTRAP_OS_RELEASE="${FAKE_ETC}/os-release"
  export BOOTSTRAP_MACHINE_ID="${FAKE_ETC}/machine-id"
  export BOOTSTRAP_TAILSCALE_REPO="${FAKE_ETC}/tailscale.repo"

  export TAILSCALE_BACKEND_STATE=NeedsLogin
  export TAILSCALE_RUN_SSH=false
  export TAILSCALE_HOSTNAME=fedora-testhost
  export MOCK_HOSTNAME=fedora-testhost
}

teardown() {
  rm -rf "${BATS_MOCK_STATE_DIR:-}" "${FAKE_ETC:-}"
}

run_bootstrap() {
  run bash "${PROJECT_ROOT}/scripts/fedora.sh"
}

@test "fresh Fedora installation succeeds" {
  setup_fake_fedora
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"Remote access ready"* ]]
  [[ "$output" == *"100.64.0.1"* ]]
  [ -f "${BATS_MOCK_STATE_DIR}/tailscale-repo" ]
  [ -f "${BATS_MOCK_STATE_DIR}/tailscale-installed" ]
}

@test "existing Tailscale repository and package are reused" {
  setup_fake_fedora
  cat >"${BOOTSTRAP_TAILSCALE_REPO}" <<'EOF'
[tailscale-stable]
name=Tailscale stable
baseurl=https://pkgs.tailscale.com/stable/fedora/$basearch
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://pkgs.tailscale.com/stable/fedora/repo.gpg
enabled=1
EOF
  touch "${BATS_MOCK_STATE_DIR}/tailscale-installed"
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"already configured"* ]]
  [[ "$output" == *"already installed"* ]]
}

@test "already-connected node uses tailscale set" {
  setup_fake_fedora
  export TAILSCALE_BACKEND_STATE=Running
  export TAILSCALE_RUN_SSH=true
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"already connected"* ]]
}

@test "generic hostname is replaced with machine-id suffix" {
  setup_fake_fedora
  export MOCK_HOSTNAME=localhost
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"fedora-01234567"* ]]
}

@test "meaningful hostname is preserved" {
  setup_fake_fedora
  export MOCK_HOSTNAME=proart-vm
  export TAILSCALE_HOSTNAME=proart-vm
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"Host: proart-vm"* ]]
}

@test "BOOTSTRAP_HOSTNAME override is honored" {
  setup_fake_fedora
  export BOOTSTRAP_HOSTNAME=custom-host
  export TAILSCALE_HOSTNAME=custom-host
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"Host: custom-host"* ]]
}

@test "unsupported operating system fails before mutation" {
  setup_fake_fedora
  printf 'ID=ubuntu\n' >"${BOOTSTRAP_OS_RELEASE}"
  run_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported operating system"* ]]
  [ ! -f "${BATS_MOCK_STATE_DIR}/tailscale-repo" ]
}

@test "running as root is rejected" {
  setup_fake_fedora
  run env BOOTSTRAP_TEST_EUID=0 bash "${PROJECT_ROOT}/scripts/fedora.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Do not run this script as root"* ]]
}

@test "verification failure does not remove installation" {
  setup_fake_fedora
  run env TAILSCALE_NO_IP=1 bash "${PROJECT_ROOT}/scripts/fedora.sh"
  [ "$status" -ne 0 ]
  [ -f "${BATS_MOCK_STATE_DIR}/tailscale-installed" ]
}

@test "two consecutive successful runs stay idempotent" {
  setup_fake_fedora
  run_bootstrap
  [ "$status" -eq 0 ]
  export TAILSCALE_BACKEND_STATE=Running
  export TAILSCALE_RUN_SSH=true
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"already connected"* ]]
  [[ "$output" == *"already active"* ]]
}

@test "failure prints stage and rerun command without secrets" {
  setup_fake_fedora
  run env PATH="/usr/bin:/bin" bash "${PROJECT_ROOT}/scripts/fedora.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bootstrap failed at stage"* ]]
  [[ "$output" == *"curl -fsSL https://bootstrap.yaronhersh.xyz/fedora | bash"* ]]
}

@test "truncated script executes nothing" {
  setup_fake_fedora
  local truncated_script
  truncated_script=$(mktemp)
  sed '$d' "${PROJECT_ROOT}/scripts/fedora.sh" >"${truncated_script}"
  run bash "${truncated_script}"
  [ "$status" -eq 0 ]
  [ ! -f "${BATS_MOCK_STATE_DIR}/tailscale-repo" ]
  [ ! -f "${BATS_MOCK_STATE_DIR}/tailscale-installed" ]
  rm -f "${truncated_script}"
}

@test "invalid existing Tailscale repository is replaced" {
  setup_fake_fedora
  printf 'invalid repo content\n' >"${BOOTSTRAP_TAILSCALE_REPO}"
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed validation; replacing"* ]]
  [ -f "${BATS_MOCK_STATE_DIR}/tailscale-repo" ]
}
