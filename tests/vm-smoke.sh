#!/usr/bin/env bash
set -euo pipefail

IMAGE="24.04"
VM_NAME="labstrap-smoke-$(date +%s)"
CPUS="2"
MEMORY="4G"
DISK="80G"
KEEP_VM="0"
WITH_HARDEN="0"

usage() {
  cat <<USAGE
Usage: tests/vm-smoke.sh [options]

Creates a fresh Multipass VM, mounts this repo, and runs a smoke test:
  install.sh -> labstrap init -> allow-key -> extras all -> status

Options:
  --name <vm_name>        VM name (default: auto-generated)
  --image <image>         Multipass image (default: 24.04)
  --cpus <n>              CPU count (default: 2)
  --memory <size>         Memory size (default: 4G)
  --disk <size>           Disk size (default: 80G)
  --with-harden           Also run 'sudo labstrap harden' (requires Tailscale auth flow)
  --keep                  Do not delete VM after test
  -h, --help              Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      VM_NAME="${2:?missing value for --name}"
      shift 2
      ;;
    --image)
      IMAGE="${2:?missing value for --image}"
      shift 2
      ;;
    --cpus)
      CPUS="${2:?missing value for --cpus}"
      shift 2
      ;;
    --memory)
      MEMORY="${2:?missing value for --memory}"
      shift 2
      ;;
    --disk)
      DISK="${2:?missing value for --disk}"
      shift 2
      ;;
    --keep)
      KEEP_VM="1"
      shift
      ;;
    --with-harden)
      WITH_HARDEN="1"
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd multipass

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup() {
  if [[ "$KEEP_VM" == "1" ]]; then
    echo "Keeping VM: $VM_NAME"
    return
  fi

  echo "Cleaning up VM: $VM_NAME"
  multipass delete "$VM_NAME" >/dev/null 2>&1 || true
  multipass purge >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "Launching VM '$VM_NAME' (image=$IMAGE cpus=$CPUS memory=$MEMORY disk=$DISK)"
multipass launch "$IMAGE" --name "$VM_NAME" --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK"

echo "Mounting repository into VM"
multipass mount "$REPO_ROOT" "$VM_NAME:/workspace/labstrap"

vm_exec() {
  local cmd="$1"
  multipass exec "$VM_NAME" -- bash -lc "$cmd"
}

echo "Running smoke test inside VM"
vm_exec "set -euo pipefail; \
  cd /workspace/labstrap; \
  sudo ./install.sh; \
  ssh-keygen -t ed25519 -N '' -f /tmp/labstrap_test_key >/dev/null; \
  sudo labstrap init; \
  sudo labstrap allow-key /tmp/labstrap_test_key.pub; \
  sudo labstrap extras all; \
  sudo labstrap status"

if [[ "$WITH_HARDEN" == "1" ]]; then
  echo "Running harden phase (requires Tailscale auth flow)"
  vm_exec "set -euo pipefail; cd /workspace/labstrap; sudo labstrap harden"
else
  echo "Skipping harden phase by default (Tailscale first-run auth is manual)."
fi

echo "Validating structured logs in VM"
vm_exec "set -euo pipefail; \
  LOG=\$(sudo ls -1t /var/log/labstrap/*.jsonl 2>/dev/null | head -n1 || true); \
  if [[ -z \"\$LOG\" ]]; then LOG=\$(ls -1t /tmp/labstrap/*.jsonl 2>/dev/null | head -n1 || true); fi; \
  [[ -n \"\$LOG\" ]] || { echo 'No structured log file found' >&2; exit 1; }; \
  export LOG; \
  echo \"Latest structured log: \$LOG\"; \
  python3 - <<'PY'
import json
import os
log_path = os.environ.get('LOG')
if not log_path:
    raise SystemExit('LOG environment variable is missing')
required = {'timestamp', 'level', 'event', 'message'}
count = 0
with open(log_path, 'r', encoding='utf-8') as fp:
    for line in fp:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        missing = required - set(event.keys())
        if missing:
            raise SystemExit(f\"Missing keys {sorted(missing)} in event: {event}\")
        count += 1
if count == 0:
    raise SystemExit('Structured log file is empty')
print(f'Structured log validation passed ({count} events)')
PY"

echo "Smoke test completed successfully for VM: $VM_NAME"
