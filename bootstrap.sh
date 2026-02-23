#!/usr/bin/env bash
set -euo pipefail

LABSTRAP_REPO_URL="${LABSTRAP_REPO_URL:-https://github.com/Alexintosh/labstrap.git}"
LABSTRAP_REF="${LABSTRAP_REF:-main}"
LABSTRAP_ARCHIVE_URL="${LABSTRAP_ARCHIVE_URL:-}"
LABSTRAP_BOOTSTRAP_DIR="${LABSTRAP_BOOTSTRAP_DIR:-}"

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
  json="{\"timestamp\":\"$ts\",\"level\":\"$(json_escape "$level")\",\"event\":\"$(json_escape "$event")\",\"command\":\"bootstrap.sh\",\"message\":\"$(json_escape "$message")\""
  while [[ "$#" -ge 2 ]]; do
    local key="$1"
    local value="$2"
    shift 2
    json="$json,\"$(json_escape "$key")\":\"$(json_escape "$value")\""
  done
  json="$json}"
  printf '%s\n' "$json"
}

if [[ "$EUID" -ne 0 ]]; then
  log_event "ERROR" "bootstrap.not_root" "bootstrap.sh must run as root"
  echo "ERROR: bootstrap.sh must run as root. Example: curl ... | sudo bash" >&2
  exit 1
fi

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    log_event "ERROR" "bootstrap.missing_tool" "Missing required tool" "tool" "$1"
    echo "ERROR: Missing required tool: $1" >&2
    exit 1
  }
}

use_download_tool() {
  if command -v curl >/dev/null 2>&1; then
    echo "curl"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    echo "wget"
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log_event "INFO" "bootstrap.install_deps" "Installing curl dependency"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl
    echo "curl"
    return
  fi

  log_event "ERROR" "bootstrap.no_downloader" "Neither curl nor wget is available"
  echo "ERROR: Need curl or wget installed." >&2
  exit 1
}

build_archive_url() {
  local repo_url="$1"
  local ref="$2"

  if [[ -n "$LABSTRAP_ARCHIVE_URL" ]]; then
    printf '%s' "$LABSTRAP_ARCHIVE_URL"
    return
  fi

  if [[ "$repo_url" =~ ^https://github.com/([^/]+)/([^/.]+)(\.git)?$ ]]; then
    printf 'https://codeload.github.com/%s/%s/tar.gz/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$ref"
    return
  fi

  log_event "ERROR" "bootstrap.archive_url_unresolved" "Unable to infer archive URL from repo" "repo" "$repo_url"
  echo "ERROR: Unable to infer archive URL from LABSTRAP_REPO_URL. Set LABSTRAP_ARCHIVE_URL explicitly." >&2
  exit 1
}

prepare_workspace() {
  if [[ -n "$LABSTRAP_BOOTSTRAP_DIR" ]]; then
    mkdir -p "$LABSTRAP_BOOTSTRAP_DIR"
    printf '%s' "$LABSTRAP_BOOTSTRAP_DIR"
    return
  fi
  mktemp -d /tmp/labstrap-bootstrap.XXXXXX
}

main() {
  local downloader
  local archive_url
  local work_dir
  local archive_file
  local extract_dir
  local source_dir

  log_event "INFO" "bootstrap.start" "Starting bootstrap" "repo" "$LABSTRAP_REPO_URL" "ref" "$LABSTRAP_REF"

  require_tool tar
  downloader="$(use_download_tool)"
  archive_url="$(build_archive_url "$LABSTRAP_REPO_URL" "$LABSTRAP_REF")"
  work_dir="$(prepare_workspace)"

  if [[ -z "$LABSTRAP_BOOTSTRAP_DIR" ]]; then
    trap 'rm -rf "$work_dir"' EXIT
  fi

  archive_file="$work_dir/labstrap.tar.gz"
  extract_dir="$work_dir/src"
  mkdir -p "$extract_dir"

  log_event "INFO" "bootstrap.download" "Downloading labstrap archive" "url" "$archive_url"
  if [[ "$downloader" == "curl" ]]; then
    curl -fsSL "$archive_url" -o "$archive_file"
  else
    wget -q "$archive_url" -O "$archive_file"
  fi

  log_event "INFO" "bootstrap.extract" "Extracting labstrap archive" "archive" "$archive_file"
  tar -xzf "$archive_file" -C "$extract_dir"

  source_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$source_dir" ]] || {
    log_event "ERROR" "bootstrap.extract_failed" "Failed to locate extracted source directory"
    echo "ERROR: Failed to locate extracted source directory." >&2
    exit 1
  }

  [[ -f "$source_dir/install.sh" ]] || {
    log_event "ERROR" "bootstrap.missing_install" "install.sh missing in extracted source" "source_dir" "$source_dir"
    echo "ERROR: install.sh not found in extracted source." >&2
    exit 1
  }

  chmod +x "$source_dir/install.sh"
  log_event "INFO" "bootstrap.install" "Running install.sh" "source_dir" "$source_dir"
  "$source_dir/install.sh"
  log_event "INFO" "bootstrap.success" "Bootstrap completed"
}

main "$@"
