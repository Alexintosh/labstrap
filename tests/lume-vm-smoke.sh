#!/usr/bin/env bash
set -euo pipefail

VM_NAME="labstrap-lume-smoke-$(date +%s)"
IPSW_VALUE="latest"
UNATTENDED_PRESET=""
KEEP_VM="0"
INSTALL_LUME="1"
RUN_SECONDS="45"

usage() {
  cat <<USAGE
Usage: tests/lume-vm-smoke.sh [options]

Creates and runs a macOS VM with Lume using the documented flow:
  1) Install Lume (optional)
  2) lume create <name> --os macos --ipsw <value>
  3) lume run <name> --no-display
  4) verify VM appears as running
  5) stop and optionally delete VM

Options:
  --name <vm_name>           VM name (default: auto-generated)
  --ipsw <value>             IPSW value/path (default: latest)
  --unattended <preset>      Setup Assistant preset (e.g., tahoe, sequoia)
  --run-seconds <n>          Seconds to keep VM running before verification (default: 45)
  --skip-install             Do not install Lume if missing
  --keep                     Keep VM after test (skip delete)
  -h, --help                 Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      VM_NAME="${2:?missing value for --name}"
      shift 2
      ;;
    --ipsw)
      IPSW_VALUE="${2:?missing value for --ipsw}"
      shift 2
      ;;
    --unattended)
      UNATTENDED_PRESET="${2:?missing value for --unattended}"
      shift 2
      ;;
    --run-seconds)
      RUN_SECONDS="${2:?missing value for --run-seconds}"
      shift 2
      ;;
    --skip-install)
      INSTALL_LUME="0"
      shift
      ;;
    --keep)
      KEEP_VM="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This test requires macOS (Darwin host)." >&2
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This test requires Apple Silicon (arm64)." >&2
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

if ! command -v lume >/dev/null 2>&1; then
  if [[ "$INSTALL_LUME" != "1" ]]; then
    echo "Lume is not installed and --skip-install was set." >&2
    exit 1
  fi

  echo "Installing Lume CLI"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/trycua/cua/main/libs/lume/scripts/install.sh)"
fi

require_cmd lume
require_cmd python3

cleanup() {
  echo "Stopping VM if running: $VM_NAME"
  lume stop "$VM_NAME" >/dev/null 2>&1 || true

  if [[ "$KEEP_VM" == "1" ]]; then
    echo "Keeping VM: $VM_NAME"
    return
  fi

  echo "Deleting VM: $VM_NAME"
  lume delete "$VM_NAME" --force >/dev/null 2>&1 || lume delete "$VM_NAME" >/dev/null 2>&1 || true
}

trap cleanup EXIT

create_args=("$VM_NAME" "--os" "macos" "--ipsw" "$IPSW_VALUE")
if [[ -n "$UNATTENDED_PRESET" ]]; then
  create_args+=("--unattended" "$UNATTENDED_PRESET" "--no-display")
fi

echo "Creating VM: $VM_NAME"
lume create "${create_args[@]}"

echo "Starting VM headless"
lume run "$VM_NAME" --no-display >/tmp/lume-run-"$VM_NAME".log 2>&1 &
LUME_RUN_PID=$!

echo "Waiting ${RUN_SECONDS}s for VM boot"
sleep "$RUN_SECONDS"

echo "Checking VM status via 'lume ls -f json'"
VM_NAME="$VM_NAME" python3 - <<'PY'
import json
import os
import subprocess
import sys

vm_name = os.environ["VM_NAME"]
proc = subprocess.run(["lume", "ls", "-f", "json"], check=True, capture_output=True, text=True)
try:
    payload = json.loads(proc.stdout)
except json.JSONDecodeError as exc:
    raise SystemExit(f"Failed to parse lume ls output as JSON: {exc}\nOutput: {proc.stdout}")

entries = payload if isinstance(payload, list) else payload.get("vms", [])
vm = None
for item in entries:
    if item.get("name") == vm_name:
        vm = item
        break

if not vm:
    raise SystemExit(f"VM '{vm_name}' not found in lume ls output")

status = (vm.get("status") or "").lower()
if status not in {"running", "started"}:
    raise SystemExit(f"VM '{vm_name}' is not running (status={vm.get('status')})")

print(f"VM '{vm_name}' is running (status={vm.get('status')})")
PY

echo "Stopping VM"
lume stop "$VM_NAME"

if kill -0 "$LUME_RUN_PID" >/dev/null 2>&1; then
  wait "$LUME_RUN_PID" || true
fi

echo "Lume VM smoke test completed successfully for: $VM_NAME"
