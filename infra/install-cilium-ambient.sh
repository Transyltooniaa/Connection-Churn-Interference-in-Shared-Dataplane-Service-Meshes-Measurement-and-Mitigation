#!/bin/bash
# ============================================================
# install-cilium-ambient.sh
# SSP Ambient-Mesh Testbed — Bare-Metal (kubeadm)
# ============================================================
# Installs Cilium 1.20 (VXLAN overlay) + Istio 1.31 ambient on a
# kubeadm cluster. Run AFTER:
#   sudo kubeadm init --config infra/kubeadm-config.yaml
#   (and workers joined via kubeadm join)
#
# BEFORE RUNNING:
#   - kubectl must be configured (kubeconfig pointing at your cluster)
#   - helm >= 3.14 and istioctl 1.31 must be in PATH
#
# Usage:
#   bash infra/install-cilium-ambient.sh
# ============================================================
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH

# -- [1] Install Cilium 1.20.2 - VXLAN overlay -----------------------------------------
# bpf.masquerade MUST be OFF for Istio ambient (ztunnel uses HBONE, not MASQ).
# kubeProxyReplacement=false: keep kube-proxy (lower-disruption path for ambient).
# cni.exclusive=false: allows coexistence with any stub CNI left by kubeadm.
# bandwidthManager + BBR: required for the EDT/BBR confound-control measurement.
echo "== [1] Installing Cilium 1.20.2 (VXLAN overlay, ambient-safe) =="
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update cilium
helm upgrade --install cilium cilium/cilium --version 1.20.2 \
  --namespace kube-system \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set bpf.masquerade=false \
  --set kubeProxyReplacement=false \
  --set cni.exclusive=false \
  --set bandwidthManager.enabled=true \
  --set bandwidthManager.bbr=true \
  2>&1 | tail -20

# -- [2] Wait for Cilium DaemonSet + node readiness -----------------------------------
echo "== [2] Waiting for Cilium DaemonSet rollout =="
kubectl -n kube-system rollout status ds/cilium --timeout=300s 2>&1 | tail -5
echo "Nodes:"
kubectl get nodes -o wide 2>&1

# -- [3] Verify Cilium status ---------------------------------------------------------
echo "== [3] Cilium status (bandwidth manager / routing / masquerade) =="
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
kubectl -n kube-system exec "${CILIUM_POD}" -- cilium status 2>&1 \
  | grep -iE 'BandwidthManager|Tunnel|Masquerade|KubeProxy|Routing' || true
# Expected:
#   BandwidthManager: EDT with BPF [BBR]
#   Tunnel: vxlan

# -- [4] Install Istio 1.31 ambient ---------------------------------------------------
# istioctl MUST be version 1.31. Verify first:
echo "== [4] Checking istioctl version =="
istioctl version --remote=false 2>&1 | head -1
# If the above shows a version OTHER than 1.31.x, download it:
#   curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.31.0 sh -
#   export PATH=$PWD/istio-1.31.0/bin:$PATH

echo "== [4] Installing Istio 1.31 ambient profile =="
istioctl install --set profile=ambient --skip-confirmation 2>&1 | tail -20

# -- [5] Verify ztunnel DaemonSet -----------------------------------------------------
echo "== [5] Verifying ztunnel DaemonSet =="
kubectl -n istio-system get ds ztunnel -o wide 2>&1
kubectl -n istio-system get pods -o wide 2>&1
echo "== done =="
