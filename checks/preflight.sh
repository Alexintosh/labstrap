#!/usr/bin/env bash
set -euo pipefail

PHASE="${1:-all}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="${LABSTRAP_CONFIG:-$ROOT_DIR/defaults/config.yml}"
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
  json="{\"timestamp\":\"$ts\",\"level\":\"$(json_escape "$level")\",\"event\":\"$(json_escape "$event")\",\"phase\":\"$(json_escape "$PHASE")\",\"message\":\"$(json_escape "$message")\""

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

fail() {
  log_event "ERROR" "preflight.check_failed" "$1"
  exit 1
}

pass() {
  log_event "INFO" "preflight.check_passed" "$1"
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "Missing required file: $path"
}

get_config_user() {
  local value
  value="$(awk '/^user:[[:space:]]*/ {print $2; exit}' "$CONFIG_PATH")"

  if [[ -z "$value" || "$value" == "auto" ]]; then
    detect_target_user
    return
  fi

  printf '%s\n' "$value"
}

detect_target_user() {
  local candidate

  if [[ -n "${LABSTRAP_USER:-}" && "${LABSTRAP_USER:-}" != "root" ]]; then
    printf '%s\n' "$LABSTRAP_USER"
    return
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
    return
  fi

  candidate="$(logname 2>/dev/null || true)"
  if [[ -n "$candidate" && "$candidate" != "root" ]]; then
    printf '%s\n' "$candidate"
    return
  fi

  candidate="$(awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "nobody" {print $1; exit}' /etc/passwd)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi

  return 1
}

check_os() {
  [[ -f /etc/os-release ]] || fail "Cannot detect OS (missing /etc/os-release)."
  # shellcheck disable=SC1091
  source /etc/os-release

  local id_like="${ID_LIKE:-}"
  local id="${ID:-}"

  if [[ "$id" == "ubuntu" || "$id_like" == *"ubuntu"* ]]; then
    pass "Ubuntu-based OS detected (${PRETTY_NAME:-$id})."
    return
  fi

  fail "Unsupported OS (${PRETTY_NAME:-$id}). Ubuntu-based distributions only."
}

check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    fail "Run with sudo/root privileges."
  fi
  pass "Running with root privileges."
}

check_network() {
  if getent hosts archive.ubuntu.com >/dev/null 2>&1 || ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
    pass "Network connectivity looks available."
    return
  fi
  fail "No network connectivity detected."
}

check_writable() {
  local tmp_file="/tmp/labstrap-preflight-$$"
  if ! touch "$tmp_file"; then
    fail "Cannot write to /tmp."
  fi
  rm -f "$tmp_file"

  local etc_file="/etc/.labstrap-preflight-$$"
  if ! touch "$etc_file"; then
    fail "Cannot write to /etc."
  fi
  rm -f "$etc_file"

  pass "Disk is writable for required paths."
}

check_user_compatibility() {
  local user_name="$1"

  if id "$user_name" >/dev/null 2>&1; then
    local uid
    local home_dir
    uid="$(id -u "$user_name")"
    home_dir="$(getent passwd "$user_name" | cut -d: -f6)"

    [[ "$uid" -ge 1000 ]] || fail "User '$user_name' exists but is a system account (uid=$uid)."
    [[ -n "$home_dir" && -d "$home_dir" ]] || fail "User '$user_name' exists but has no valid home directory."

    pass "User '$user_name' already exists and is compatible."
    return
  fi

  if [[ "$PHASE" == "init" ]]; then
    pass "User '$user_name' does not exist yet (expected for init)."
  else
    fail "User '$user_name' does not exist. Run 'labstrap init' first."
  fi
}

main() {
  log_event "INFO" "preflight.start" "Preflight checks started"

  require_file "$CONFIG_PATH"
  local user_name
  user_name="$(get_config_user || true)"
  [[ -n "$user_name" ]] || fail "Unable to resolve target user. Set LABSTRAP_USER or configure 'user:' in $CONFIG_PATH."

  check_os
  check_root
  check_network
  check_writable
  check_user_compatibility "$user_name"

  log_event "INFO" "preflight.success" "All preflight checks passed"
}

main "$@"
