#!/usr/bin/env bash
# Secretless macOS remote-access bootstrap — stage zero.
# Canonical invocation:
#   curl -fsSL https://bootstrap.yaronhersh.xyz/macos | bash
#
# Optional hostname override:
#   BOOTSTRAP_HOSTNAME=my-host bash -c "$(curl -fsSL https://bootstrap.yaronhersh.xyz/macos)"
#
# Pinned Homebrew installer (https://github.com/Homebrew/install):
#   commit: 7a133dcc74051ee4efc79467ed215dfedf45aea2
#   sha256: 12479a24be3f5307eecac7cde670fad7118640f031229e964f544b1367b52a41

set -euo pipefail
set -E

readonly RERUN_COMMAND='curl -fsSL https://bootstrap.yaronhersh.xyz/macos | bash'
readonly HOMEBREW_INSTALL_COMMIT='7a133dcc74051ee4efc79467ed215dfedf45aea2'
readonly HOMEBREW_INSTALL_SHA256='12479a24be3f5307eecac7cde670fad7118640f031229e964f544b1367b52a41'
readonly HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/${HOMEBREW_INSTALL_COMMIT}/install.sh"
readonly TAILSCALE_AUTH_WAIT_SECONDS="${BOOTSTRAP_TAILSCALE_AUTH_WAIT_SECONDS:-300}"

STAGE="preflight"
TMPDIR_BOOTSTRAP=""
BREW_PREFIX=""

cleanup() {
  if [[ -n "${TMPDIR_BOOTSTRAP}" && -d "${TMPDIR_BOOTSTRAP}" ]]; then
    rm -rf "${TMPDIR_BOOTSTRAP}"
  fi
}

on_error() {
  local exit_code=$?
  echo "Bootstrap failed at stage: ${STAGE} (exit ${exit_code})" >&2
  echo "Rerun: ${RERUN_COMMAND}" >&2
  exit "${exit_code}"
}

trap cleanup EXIT
trap on_error ERR

# Absorb truncated downloads that end mid-token on the final invocation line.
__bootstrap_entry() { return 0; }

require_cmd() {
  local cmd=$1
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    return 1
  fi
}

is_generic_hostname() {
  local name=$1
  case "${name}" in
    localhost | localhost-live | localhost.localdomain | localhost-live.localdomain)
      return 0
      ;;
    localhost.* | localhost-live.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_hostname() {
  local name=$1
  if [[ ! "${name}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo "Invalid BOOTSTRAP_HOSTNAME: ${name}" >&2
    exit 1
  fi
}

resolve_bootstrap_hostname() {
  if [[ -n "${BOOTSTRAP_HOSTNAME:-}" ]]; then
    validate_hostname "${BOOTSTRAP_HOSTNAME}"
    echo "${BOOTSTRAP_HOSTNAME}"
    return
  fi

  local current
  current=$(scutil --get LocalHostName 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)

  if [[ -n "${current}" ]] && ! is_generic_hostname "${current}"; then
    validate_hostname "${current}"
    echo "${current}"
    return
  fi

  local platform_uuid=""
  platform_uuid=$(
    ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
      awk -F'"' '/IOPlatformUUID/ {print $4; exit}' |
      tr '[:upper:]' '[:lower:]' |
      tr -d '-' || true
  )

  if [[ -z "${platform_uuid}" ]]; then
    platform_uuid="00000000"
  fi

  echo "mac-${platform_uuid:0:8}"
}

parse_tailscale_status_json() {
  local field=$1
  local status_json=$2
  python3 - "$field" "$status_json" <<'PY'
import json
import sys

field = sys.argv[1]
try:
    data = json.loads(sys.argv[2])
except json.JSONDecodeError:
    sys.exit(1)

if field == "backend_state":
    print(data.get("BackendState", ""))
elif field == "hostname":
    self_info = data.get("Self") or {}
    print(self_info.get("HostName", ""))
else:
    sys.exit(1)
PY
}

parse_tailscale_prefs_json() {
  local field=$1
  local prefs_json=$2
  python3 - "$field" "$prefs_json" <<'PY'
import json
import sys

field = sys.argv[1]
try:
    data = json.loads(sys.argv[2])
except json.JSONDecodeError:
    sys.exit(1)

if field == "run_ssh":
    print("true" if data.get("RunSSH") else "false")
else:
    sys.exit(1)
PY
}

tailscale_backend_state() {
  local status_json
  status_json=$(tailscale status --json 2>/dev/null) || return 1
  parse_tailscale_status_json backend_state "${status_json}"
}

tailscale_hostname() {
  local status_json
  status_json=$(tailscale status --json 2>/dev/null) || return 1
  parse_tailscale_status_json hostname "${status_json}"
}

tailscale_ssh_enabled() {
  local prefs_json run_ssh
  prefs_json=$(tailscale debug prefs 2>/dev/null) || return 1
  run_ssh=$(parse_tailscale_prefs_json run_ssh "${prefs_json}") || return 1
  [[ "${run_ssh}" == "true" ]]
}

detect_brew_prefix() {
  if [[ -n "${BOOTSTRAP_BREW_PREFIX:-}" ]]; then
    echo "${BOOTSTRAP_BREW_PREFIX}"
    return
  fi

  if command -v brew >/dev/null 2>&1; then
    brew --prefix
    return
  fi

  if [[ "$(uname -m)" == "arm64" ]]; then
    echo /opt/homebrew
  else
    echo /usr/local
  fi
}

ensure_brew_path() {
  BREW_PREFIX=$(detect_brew_prefix)
  export PATH="${BREW_PREFIX}/bin:${PATH}"
}

sha256_file() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
    return
  fi
  echo "Missing required command: shasum or sha256sum" >&2
  return 1
}

is_homebrew_tailscale() {
  local tailscale_path brew_prefix
  tailscale_path=$(command -v tailscale 2>/dev/null || true)
  brew_prefix=$(brew --prefix 2>/dev/null || true)
  if [[ -z "${tailscale_path}" || -z "${brew_prefix}" ]]; then
    return 1
  fi
  [[ "${tailscale_path}" == "${brew_prefix}/bin/tailscale" ]]
}

wait_for_tailscale_status() {
  local attempts=30
  local delay=1
  local attempt=0

  while [[ "${attempt}" -lt "${attempts}" ]]; do
    if tailscale status --json >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep "${delay}"
  done

  echo "tailscaled is not responding to tailscale status." >&2
  return 1
}

wait_for_tailscale_running() {
  local deadline=$((SECONDS + TAILSCALE_AUTH_WAIT_SECONDS))
  local backend_state=""

  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    backend_state=$(tailscale_backend_state || true)
    if [[ "${backend_state}" == "Running" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "Tailscale authentication timed out after ${TAILSCALE_AUTH_WAIT_SECONDS}s." >&2
  echo "Approve the node in your browser, then rerun:" >&2
  echo "  ${RERUN_COMMAND}" >&2
  return 1
}

install_homebrew() {
  local installer="${TMPDIR_BOOTSTRAP}/homebrew-install.sh"
  local actual_hash=""

  curl --proto '=https' --tlsv1.2 -fsSL -o "${installer}" "${HOMEBREW_INSTALL_URL}"

  actual_hash=$(sha256_file "${installer}")
  if [[ "${actual_hash}" != "${HOMEBREW_INSTALL_SHA256}" ]]; then
    echo "Homebrew installer checksum mismatch." >&2
    exit 1
  fi

  if [[ -n "${BOOTSTRAP_HOMEBREW_INSTALLER_CMD:-}" ]]; then
    # shellcheck disable=SC2086
    ${BOOTSTRAP_HOMEBREW_INSTALLER_CMD} "${installer}"
  else
    NONINTERACTIVE=1 bash "${installer}"
  fi
}

stage_preflight() {
  STAGE="preflight"

  if [[ "${BOOTSTRAP_TEST_EUID:-${EUID}}" -eq 0 ]]; then
    echo "Do not run this script as root. Run as a normal user with sudo access." >&2
    return 1
  fi

  if [[ "$(uname -s)" != "Darwin" && -z "${BOOTSTRAP_ALLOW_NON_DARWIN:-}" ]]; then
    echo "Unsupported operating system: this script supports macOS only." >&2
    exit 1
  fi

  require_cmd curl
  require_cmd sudo
  require_cmd python3
  require_cmd scutil

  if ! sudo -v; then
    echo "sudo authorization required." >&2
    exit 1
  fi

  TMPDIR_BOOTSTRAP=$(mktemp -d)
  chmod 700 "${TMPDIR_BOOTSTRAP}"
}

stage_xcode() {
  STAGE="xcode"

  local developer_dir="${BOOTSTRAP_DEVELOPER_DIR:-}"
  if [[ -n "${developer_dir}" ]]; then
    if [[ ! -d "${developer_dir}" ]]; then
      echo "Xcode Command Line Tools are not installed." >&2
      exit 1
    fi
    return
  fi

  if xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools already installed."
    return
  fi

  xcode-select --install || true
  cat <<'EOF'

Xcode Command Line Tools are required but not installed.
A software update dialog should appear. Click Install, wait for it to finish,
then rerun this bootstrap command.
EOF
  exit 1
}

stage_homebrew() {
  STAGE="homebrew"

  if command -v brew >/dev/null 2>&1; then
    echo "Homebrew already installed."
    ensure_brew_path
    return
  fi

  echo "Installing Homebrew..."
  install_homebrew
  ensure_brew_path

  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew installation did not provide the brew command." >&2
    exit 1
  fi
}

stage_install() {
  STAGE="install"

  ensure_brew_path

  if brew list --formula tailscale >/dev/null 2>&1; then
    echo "Tailscale formula already installed."
  else
    echo "Installing Tailscale via Homebrew..."
    brew install tailscale
  fi

  if ! tailscale --version >/dev/null 2>&1; then
    echo "Tailscale binary is not executable after installation." >&2
    exit 1
  fi

  if ! is_homebrew_tailscale; then
    echo "Tailscale binary is not from the Homebrew formula." >&2
    exit 1
  fi
}

stage_service() {
  STAGE="service"

  ensure_brew_path

  if brew services list 2>/dev/null | grep -Eq 'tailscale[[:space:]]+started'; then
    echo "tailscaled is already running via Homebrew services."
  else
    echo "Starting tailscaled via Homebrew services..."
    sudo brew services start tailscale
  fi

  wait_for_tailscale_status
}

stage_authenticate() {
  STAGE="authenticate"

  local hostname backend_state
  hostname=$(resolve_bootstrap_hostname)
  backend_state=$(tailscale_backend_state || true)

  if [[ "${backend_state}" == "Running" ]] && tailscale_ssh_enabled; then
    echo "Tailscale already connected with SSH enabled; skipping authentication."
    return
  fi

  if [[ "${backend_state}" == "Running" ]]; then
    echo "Tailscale already connected; enabling SSH without reauthentication..."
    sudo tailscale set --ssh=true --hostname="${hostname}"
    return
  fi

  echo "Starting Tailscale authentication (browser approval required)..."
  echo "Hostname: ${hostname}"
  sudo tailscale up --ssh --hostname="${hostname}"
  wait_for_tailscale_running
}

stage_verify() {
  STAGE="verify"

  local backend_state=""
  backend_state=$(tailscale_backend_state || true)
  if [[ "${backend_state}" != "Running" ]]; then
    echo "Verification failed: Tailscale is not connected." >&2
    exit 1
  fi

  if ! tailscale_ssh_enabled; then
    echo "Verification failed: Tailscale SSH is not enabled." >&2
    exit 1
  fi

  local ts_ip=""
  ts_ip=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  if [[ -z "${ts_ip}" ]]; then
    echo "Verification failed: no Tailscale IPv4 address assigned." >&2
    exit 1
  fi

  local hostname=""
  hostname=$(tailscale_hostname || true)
  if [[ -z "${hostname}" ]]; then
    hostname=$(resolve_bootstrap_hostname)
  fi

  cat <<EOF

Remote access ready
Host: ${hostname}
Tailscale IP: ${ts_ip}
Next: tell the operator "done"
EOF
}

main() {
  stage_preflight
  stage_xcode
  stage_homebrew
  stage_install
  stage_service
  stage_authenticate
  stage_verify
}

__bootstrap_entrypoint__() { main "$@"; }
__bootstrap_entry__() {
  [[ "${!#}" == "bootstrap-entry-v1" ]] || return 0
  set -- "${@:1:$#-1}"
  __bootstrap_entrypoint__ "$@"
}
__bootstrap_entry__ "$@" bootstrap-entry-v1
