#!/usr/bin/env bash
# Secretless Fedora remote-access bootstrap — stage zero.
# Canonical invocation:
#   curl -fsSL https://bootstrap.yaronhersh.xyz/fedora | bash

set -euo pipefail
set -E

readonly RERUN_COMMAND='curl -fsSL https://bootstrap.yaronhersh.xyz/fedora | bash'

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

resolve_bootstrap_hostname() {
  if [[ -n "${BOOTSTRAP_HOSTNAME:-}" ]]; then
    echo "${BOOTSTRAP_HOSTNAME}"
    return
  fi

  local current
  current=$(hostname -s 2>/dev/null || hostname)

  if ! is_generic_hostname "${current}"; then
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

  if ! curl -fsSL --max-time 15 https://pkgs.tailscale.com/ >/dev/null; then
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
  if [[ -f "${repo_file}" ]]; then
    echo "Tailscale repository already configured."
    return
  fi

  echo "Configuring Tailscale official Fedora repository..."
  sudo curl -fsSL -o "${repo_file}" \
    https://pkgs.tailscale.com/stable/fedora/tailscale.repo
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
  if tailscale status --json >/dev/null 2>&1; then
    backend_state=$(tailscale status --json 2>/dev/null | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
  fi

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
  backend_state=$(tailscale status --json 2>/dev/null | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
  if [[ "${backend_state}" != "Running" ]]; then
    echo "Verification failed: Tailscale is not connected." >&2
    exit 1
  fi

  if ! tailscale debug prefs 2>/dev/null | grep -q 'RunSSH": true'; then
    if ! tailscale status 2>/dev/null | grep -qi 'ssh'; then
      echo "Verification failed: Tailscale SSH is not enabled." >&2
      exit 1
    fi
  fi

  local ts_ip=""
  ts_ip=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  if [[ -z "${ts_ip}" ]]; then
    echo "Verification failed: no Tailscale IPv4 address assigned." >&2
    exit 1
  fi

  local hostname
  hostname=$(tailscale status --json 2>/dev/null | sed -n 's/.*"HostName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
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

stage_preflight
stage_repository
stage_install
stage_service
stage_authenticate
stage_verify
