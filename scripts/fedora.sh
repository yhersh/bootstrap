#!/usr/bin/env bash
# Secretless Fedora remote-access bootstrap — stage zero.
# Canonical invocation:
#   curl -fsSL https://bootstrap.yaronhersh.xyz/fedora | bash
#
# Optional hostname override:
#   BOOTSTRAP_HOSTNAME=my-host bash -c "$(curl -fsSL https://bootstrap.yaronhersh.xyz/fedora)"

set -euo pipefail
set -E

readonly RERUN_COMMAND='curl -fsSL https://bootstrap.yaronhersh.xyz/fedora | bash'
readonly TAILSCALE_REPO_URL='https://pkgs.tailscale.com/stable/fedora/tailscale.repo'

STAGE="preflight"
TMPDIR_BOOTSTRAP=""

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
  current=$(hostname -s 2>/dev/null || hostname)

  if ! is_generic_hostname "${current}"; then
    validate_hostname "${current}"
    echo "${current}"
    return
  fi

  local machine_id_file="${BOOTSTRAP_MACHINE_ID:-/etc/machine-id}"
  local machine_id=""
  if [[ -f "${machine_id_file}" ]]; then
    machine_id=$(tr -d '[:space:]' <"${machine_id_file}")
  fi

  if [[ -z "${machine_id}" ]]; then
    machine_id="00000000"
  fi

  echo "fedora-${machine_id:0:8}"
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

validate_tailscale_repo_file() {
  local file=$1

  [[ -f "${file}" ]] || return 1
  python3 - "${file}" <<'PY'
import re
import sys
from urllib.parse import urlparse

path = sys.argv[1]
try:
    content = open(path, encoding="utf-8").read()
except OSError:
    sys.exit(1)

sections = {}
current = None
for raw_line in content.splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or line.startswith(";"):
        continue
    section_match = re.fullmatch(r"\[([^\]]+)\]", line)
    if section_match:
        current = section_match.group(1)
        sections[current] = {}
        continue
    if current is None or "=" not in line:
        sys.exit(1)
    key, value = line.split("=", 1)
    sections[current][key.strip()] = value.strip()

if set(sections.keys()) != {"tailscale-stable"}:
    sys.exit(1)

section = sections["tailscale-stable"]
required = {
    "gpgcheck": "1",
    "repo_gpgcheck": "1",
    "enabled": "1",
}
for key, expected in required.items():
    if section.get(key) != expected:
        sys.exit(1)

for url_key in ("baseurl", "gpgkey"):
    url = section.get(url_key, "")
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.netloc != "pkgs.tailscale.com":
        sys.exit(1)

if "pkgs.tailscale.com" not in section.get("baseurl", ""):
    sys.exit(1)
PY
}

install_tailscale_repo() {
  local repo_file=$1
  local tmp_repo="${TMPDIR_BOOTSTRAP}/tailscale.repo"

  curl --proto '=https' --tlsv1.2 -fsSL -o "${tmp_repo}" "${TAILSCALE_REPO_URL}"

  if ! validate_tailscale_repo_file "${tmp_repo}"; then
    echo "Downloaded Tailscale repository file failed validation." >&2
    exit 1
  fi

  sudo install -m 0644 -o root -g root "${tmp_repo}" "${repo_file}"
}

stage_preflight() {
  STAGE="preflight"

  if [[ "${BOOTSTRAP_TEST_EUID:-${EUID}}" -eq 0 ]]; then
    echo "Do not run this script as root. Run as a normal user with sudo access." >&2
    return 1
  fi

  local os_release="${BOOTSTRAP_OS_RELEASE:-/etc/os-release}"
  if [[ ! -f "${os_release}" ]]; then
    echo "Unsupported operating system: missing ${os_release}" >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  source "${os_release}"
  if [[ "${ID:-}" != "fedora" ]]; then
    echo "Unsupported operating system: ${ID:-unknown}. This script supports Fedora only." >&2
    exit 1
  fi

  require_cmd dnf
  require_cmd systemctl
  require_cmd curl
  require_cmd sudo
  require_cmd python3

  if ! curl --proto '=https' --tlsv1.2 -fsSL --max-time 15 https://pkgs.tailscale.com/ >/dev/null; then
    echo "Cannot reach Tailscale package repository over HTTPS." >&2
    exit 1
  fi

  if ! sudo -v; then
    echo "sudo authorization required." >&2
    exit 1
  fi

  TMPDIR_BOOTSTRAP=$(mktemp -d)
  chmod 700 "${TMPDIR_BOOTSTRAP}"
}

stage_repository() {
  STAGE="repository"

  local repo_file="${BOOTSTRAP_TAILSCALE_REPO:-/etc/yum.repos.d/tailscale.repo}"
  if [[ -f "${repo_file}" ]] && validate_tailscale_repo_file "${repo_file}"; then
    echo "Tailscale repository already configured."
    return
  fi

  if [[ -f "${repo_file}" ]]; then
    echo "Existing Tailscale repository file failed validation; replacing..."
  else
    echo "Configuring Tailscale official Fedora repository..."
  fi

  install_tailscale_repo "${repo_file}"
}

stage_install() {
  STAGE="install"

  if rpm -q tailscale >/dev/null 2>&1; then
    echo "Tailscale package already installed."
    return
  fi

  echo "Installing Tailscale..."
  sudo dnf install -y tailscale
}

stage_service() {
  STAGE="service"

  if ! systemctl is-enabled --quiet tailscaled 2>/dev/null; then
    sudo systemctl enable tailscaled
  fi

  if ! systemctl is-active --quiet tailscaled; then
    echo "Starting tailscaled..."
    sudo systemctl start tailscaled
  else
    echo "tailscaled is already active."
  fi
}

stage_authenticate() {
  STAGE="authenticate"

  local hostname
  hostname=$(resolve_bootstrap_hostname)

  local backend_state=""
  backend_state=$(tailscale_backend_state || true)

  if [[ "${backend_state}" == "Running" ]]; then
    echo "Tailscale already connected; enabling SSH without reauthentication..."
    sudo tailscale set --ssh=true --hostname="${hostname}"
  else
    echo "Starting Tailscale authentication (browser approval required)..."
    echo "Hostname: ${hostname}"
    sudo tailscale up --ssh --hostname="${hostname}"
  fi
}

stage_verify() {
  STAGE="verify"

  if ! systemctl is-active --quiet tailscaled; then
    echo "Verification failed: tailscaled is not active." >&2
    exit 1
  fi

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
  stage_repository
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
