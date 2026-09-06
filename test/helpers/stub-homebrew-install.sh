#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${BATS_MOCK_STATE_DIR:-/tmp/bootstrap-bats-state}"
mkdir -p "${STATE_DIR}"

prefix="${BOOTSTRAP_BREW_PREFIX:-/opt/homebrew}"
helper_dir="${BATS_MOCK_BIN_DIR:-$(cd "$(dirname "$0")" && pwd)}"
mkdir -p "${prefix}/bin"
cp "${helper_dir}/brew" "${prefix}/bin/brew"
chmod +x "${prefix}/bin/brew"
touch "${STATE_DIR}/homebrew-installed"
