#!/usr/bin/env bash
# Stop Kubernetes services on both worker VMs and the laptop's WSL.
# Usage: bash infra/cluster-down.sh [--shutdown-wsl] [--local-only]
set -uo pipefail

CTRL_IP="${CTRL_IP:-100.96.31.124}"
WORKER1_IP="${WORKER1_IP:-100.114.48.94}"
WORKER2_IP="${WORKER2_IP:-100.117.8.27}"
WORKER1_SSH="${WORKER1_SSH:-iiitb@${WORKER1_IP}}"
WORKER2_SSH="${WORKER2_SSH:-iiitb@${WORKER2_IP}}"
SHUTDOWN_WSL=0
LOCAL_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --shutdown-wsl) SHUTDOWN_WSL=1 ;;
    --local-only) LOCAL_ONLY=1 ;;
    -h|--help)
      echo "Usage: bash infra/cluster-down.sh [--shutdown-wsl] [--local-only]"
      echo "By default, stops kubelet and containerd on both workers and locally."
      echo "--shutdown-wsl also asks Windows to run 'wsl.exe --shutdown'."
      echo "--local-only skips remote worker service stops."
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "WARNING: This stops Kubernetes/containerd services and interrupts running pods/workloads."
if [[ ! -t 0 ]]; then
  echo "Refusing to stop services non-interactively. Run this from an interactive terminal." >&2
  exit 2
fi
read -r -p "Continue? Type YES to stop the cluster: " answer
[[ "$answer" == "YES" ]] || { echo "Cancelled."; exit 0; }

stop_worker() {
  local label="$1" target="$2"
  echo
  echo "==> Stopping services on ${label} (${target})"
  # -t allows sudo to prompt on the worker. If unreachable, continue and report it.
  if ! ssh -t -o ConnectTimeout=8 "$target" \
    "sudo systemctl stop kubelet; sudo systemctl stop containerd"; then
    echo "WARNING: Could not stop services on ${label}. Check that VM/SSH is reachable." >&2
    return 1
  fi
  return 0
}

errors=0
if [[ "$LOCAL_ONLY" -eq 0 ]]; then
  stop_worker "iiitb" "$WORKER1_SSH" || errors=1
  stop_worker "iiitb-worker2" "$WORKER2_SSH" || errors=1
fi

echo
echo "==> Stopping local Kubernetes services in WSL"
sudo systemctl stop kubelet || errors=1
sudo systemctl stop containerd || errors=1

echo
echo "Local Kubernetes services stopped."
if [[ "$errors" -ne 0 ]]; then
  echo "WARNING: One or more services could not be stopped cleanly; check the warnings above." >&2
fi

if [[ "$SHUTDOWN_WSL" -eq 1 ]]; then
  if ! command -v powershell.exe >/dev/null 2>&1; then
    echo "Cannot find powershell.exe from WSL. Open Windows PowerShell and run: wsl --shutdown" >&2
    exit 1
  fi
  echo "Requesting Windows to shut down WSL..."
  powershell.exe -NoProfile -Command "wsl.exe --shutdown"
else
  echo "To stop the WSL virtual machine completely, run this in Windows PowerShell:"
  echo "  wsl --shutdown"
fi
exit "$errors"
