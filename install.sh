#!/usr/bin/env bash
set -euo pipefail

LABSTRAP_LOG_DIR="${LABSTRAP_LOG_DIR:-/var/log/labstrap}"
LABSTRAP_LOG_FILE="${LABSTRAP_LOG_FILE:-}"

json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

log_event() {
  local level="$1"
  local event="$2"
  local message="$3"
  shift 3 || true

  local ts
  local json
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  json="{\"timestamp\":\"$ts\",\"level\":\"$(json_escape "$level")\",\"event\":\"$(json_escape "$event")\",\"command\":\"install.sh\",\"message\":\"$(json_escape "$message")\""
  while [[ "$#" -ge 2 ]]; do
    local key="$1"
    local value="$2"
    shift 2
    json="$json,\"$(json_escape "$key")\":\"$(json_escape "$value")\""
  done
  json="$json}"

  printf '%s\n' "$json"
  if [[ -n "$LABSTRAP_LOG_FILE" ]]; then
    printf '%s\n' "$json" >> "$LABSTRAP_LOG_FILE" || true
  fi
}

if [[ "$EUID" -ne 0 ]]; then
  log_event "ERROR" "install.not_root" "install.sh must be run as root"
  echo "ERROR: install.sh must be run with sudo/root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="/opt/labstrap"
BIN_LINK="/usr/local/bin/labstrap"

if [[ -z "$LABSTRAP_LOG_FILE" ]]; then
  if ! mkdir -p "$LABSTRAP_LOG_DIR" >/dev/null 2>&1; then
    LABSTRAP_LOG_DIR="/tmp/labstrap"
    mkdir -p "$LABSTRAP_LOG_DIR"
  fi
  LABSTRAP_LOG_FILE="$LABSTRAP_LOG_DIR/$(date -u +"%Y%m%dT%H%M%SZ")-install-$$.jsonl"
fi
: > "$LABSTRAP_LOG_FILE"
export LABSTRAP_LOG_FILE
log_event "INFO" "install.start" "Install started" "log_file" "$LABSTRAP_LOG_FILE"

echo "== Installing dependencies =="
log_event "INFO" "install.dependencies" "Installing apt dependencies"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ansible \
  curl \
  git \
  python3 \
  python3-apt \
  rsync

echo "== Installing labstrap files =="
log_event "INFO" "install.filesync" "Syncing project files" "source" "$SCRIPT_DIR" "target" "$INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT"
rsync -a --delete \
  --exclude '.git' \
  --exclude '.DS_Store' \
  "$SCRIPT_DIR/" "$INSTALL_ROOT/"

chmod +x "$INSTALL_ROOT/labstrap"
chmod +x "$INSTALL_ROOT/checks/preflight.sh"
chmod +x "$INSTALL_ROOT/install.sh"

log_event "INFO" "install.symlink" "Updating labstrap symlink" "link" "$BIN_LINK" "target" "$INSTALL_ROOT/labstrap"
ln -sfn "$INSTALL_ROOT/labstrap" "$BIN_LINK"

echo "== Installation complete =="
echo "Binary: $BIN_LINK"
echo "Project root: $INSTALL_ROOT"
log_event "INFO" "install.success" "Install completed" "binary" "$BIN_LINK" "project_root" "$INSTALL_ROOT"
