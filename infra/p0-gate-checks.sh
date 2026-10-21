#!/bin/bash
# Phase-0 GATE checks — SSP Ambient-Mesh Testbed (bare-metal kubeadm)
# Run after install-cilium-ambient.sh completes.
# Writes findings to phases/phase0/data relative to the repo root.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH

# Resolve repo root from script location (works regardless of where you call from).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT="${REPO_ROOT}/phases/phase0/data"
mkdir -p "${OUT}"
log(){ echo -e "\n== $* =="; }

log "CHECK a: ambient-on-Cilium up + kernel version"
kubectl get nodes -o wide 2>&1 | tee "${OUT}/nodes.txt"
kubectl get nodes -o custom-columns='NODE:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion,OS:.status.nodeInfo.osImage,RUNTIME:.status.nodeInfo.containerRuntimeVersion' 2>&1 \
  | tee "${OUT}/kernel.txt"
kubectl -n istio-system get ds ztunnel 2>&1 | tee "${OUT}/ztunnel_ds.txt"
kubectl -n kube-system get ds cilium 2>&1 | tee "${OUT}/cilium_ds.txt"

log "CHECK b: ztunnel cgroup cpu.stat + Tokio metrics readable"
ZT=$(kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')
echo "ztunnel pod: ${ZT}" | tee "${OUT}/signal_readability.txt"
kubectl -n istio-system exec "${ZT}" -- sh -c \
  'cat /sys/fs/cgroup/cpu.stat 2>/dev/null || cat /sys/fs/cgroup/cpu/cpu.stat 2>/dev/null' \
  2>&1 | tee -a "${OUT}/signal_readability.txt"
kubectl -n istio-system exec "${ZT}" -- sh -c \
  'curl -s localhost:15020/metrics 2>/dev/null | grep -i tokio | head' \
  2>&1 | tee -a "${OUT}/signal_readability.txt" \
  || echo "(tokio metric path TBD)" | tee -a "${OUT}/signal_readability.txt"

log "CHECK c: Cilium bandwidth manager / EDT / BBR status"
CIL=$(kubectl -n kube-system get pod -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec "${CIL}" -- cilium status 2>&1 \
  | grep -iE 'bandwidth|bbr|masquer|routing|kubeproxy|Tunnel' \
  | tee "${OUT}/cilium_bwm.txt"
# Confirm FQ qdisc present on node's device (via cilium pod which runs in host netns)
kubectl -n kube-system exec "${CIL}" -- sh -c \
  'tc qdisc show 2>/dev/null | grep -i fq | head' \
  2>&1 | tee -a "${OUT}/cilium_bwm.txt" || true

log "Gate raw capture complete -> ${OUT}"
