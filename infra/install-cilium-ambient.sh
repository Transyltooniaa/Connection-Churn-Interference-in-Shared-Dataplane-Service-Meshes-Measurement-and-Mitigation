#!/bin/bash
# Phase-0: install Cilium 1.20 (replacing VPC CNI) + Istio 1.31 ambient on the ssp-p0 cluster.
# Idempotent-ish; run after `eksctl create cluster -f cluster-p0.yaml` completes.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH

echo "== [1] neutralize aws-node (VPC CNI) so Cilium owns networking =="
kubectl -n kube-system patch daemonset aws-node --type='strategic' \
  -p='{"spec":{"template":{"spec":{"nodeSelector":{"io.cilium/aws-node-enabled":"true"}}}}}' 2>&1 || true

echo "== [2] install Cilium 1.20.2 (ENI mode; keep kube-proxy; ambient-safe settings) =="
# ambient requires bpf.masquerade OFF; keep kube-proxy (kubeProxyReplacement=false).
helm install cilium oci://quay.io/cilium/charts/cilium --version 1.20.2 \
  --namespace kube-system \
  --set eni.enabled=true \
  --set ipam.mode=eni \
  --set routingMode=native \
  --set egressMasqueradeInterfaces=eth0 \
  --set bpf.masquerade=false \
  --set kubeProxyReplacement=false \
  --set cni.exclusive=false \
  --set bandwidthManager.enabled=true \
  --set bandwidthManager.bbr=true \
  2>&1 | tail -20

echo "== [3] wait for Cilium + node readiness =="
kubectl -n kube-system rollout status ds/cilium --timeout=300s 2>&1 | tail -3
kubectl get nodes -o wide 2>&1

echo "== [4] Cilium status (bandwidth manager / EDT / BBR) =="
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
kubectl -n kube-system exec "$CILIUM_POD" -- cilium status 2>&1 | grep -iE 'bandwidth|masquer|kubeproxy|routing' || true

echo "== [5] install Istio 1.31 ambient =="
# istioctl must be 1.31 (current /usr/local/bin/istioctl may be 1.23 — check & upgrade if so)
istioctl version --remote=false 2>&1 | head -1
istioctl install --set profile=ambient --skip-confirmation 2>&1 | tail -15

echo "== [6] ambient-on-Cilium NetworkPolicy allow for kubelet health probes =="
cat <<'EOF' | kubectl apply -f - 2>&1
apiVersion: "cilium.io/v2"
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: allow-istio-health-probe
spec:
  endpointSelector: {}
  ingress:
    - fromCIDR:
        - 169.254.7.127/32
EOF

echo "== [7] verify ztunnel DS =="
kubectl -n istio-system get ds ztunnel -o wide 2>&1
kubectl -n istio-system get pods -o wide 2>&1
echo "== done =="
