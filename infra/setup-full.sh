#!/bin/bash
# ============================================================
# Full Cluster Setup — SSP Ambient Mesh Testbed
# ============================================================
# Orchestrates the complete bring-up sequence:
#   0. Prerequisite checks
#   1. EKS cluster creation  (cluster-p0.yaml)
#   2. Cilium 1.20 + Istio 1.31 ambient install
#   3. Node labeling
#   4. KEDA install
#   5. DSB SocialNetwork helm chart
#   6. NATS JetStream DaemonSet
#   7. Rust Ingestion Proxy DaemonSet
#   8. Workers + KEDA ScaledObjects + virtual Endpoints
#   9. Probe pods (manifests.yaml)
#  10. Gate checks
#
# Usage:
#   export REGISTRY=<your-docker-registry>
#   export UNDER_TEST_NODE=<k8s node name>
#   export LOADGEN_NODE=<k8s node name>
#   bash infra/setup-full.sh
#
# Set SKIP_CLUSTER_CREATE=1 to skip eksctl if cluster already exists.
# Set SKIP_CILIUM_INSTALL=1 to skip install-cilium-ambient.sh.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

info "=== Step 0: Prerequisite checks ==="
for bin in eksctl kubectl helm istioctl docker; do
  command -v "$bin" &>/dev/null || error "'$bin' not found in PATH. Install it first."
  info "  OK $bin"
done
[[ -z "${REGISTRY:-}" ]] && error "REGISTRY env var not set. Export it before running."
info "  Registry: ${REGISTRY}"

if [[ "${SKIP_CLUSTER_CREATE:-0}" != "1" ]]; then
  info "=== Step 1: Creating EKS cluster (ssp-p0) ==="
  eksctl create cluster -f "${SCRIPT_DIR}/cluster-p0.yaml" 2>&1 | tee "${SCRIPT_DIR}/create-p0.log"
  aws eks update-kubeconfig --region us-east-2 --name ssp-p0
else
  info "=== Step 1: SKIPPED (SKIP_CLUSTER_CREATE=1) ==="
fi

kubectl cluster-info || error "Cannot reach cluster. Check kubeconfig."

if [[ "${SKIP_CILIUM_INSTALL:-0}" != "1" ]]; then
  info "=== Step 2: Installing Cilium 1.20 + Istio 1.31 ambient ==="
  bash "${SCRIPT_DIR}/install-cilium-ambient.sh"
else
  info "=== Step 2: SKIPPED (SKIP_CILIUM_INSTALL=1) ==="
fi

info "=== Step 3: Labeling nodes ==="
if [[ -z "${UNDER_TEST_NODE:-}" ]] || [[ -z "${LOADGEN_NODE:-}" ]]; then
  warn "UNDER_TEST_NODE / LOADGEN_NODE not set. Current nodes:"
  kubectl get nodes -o wide
  read -rp "Enter UNDER_TEST_NODE name: " UNDER_TEST_NODE
  read -rp "Enter LOADGEN_NODE name: "    LOADGEN_NODE
fi
kubectl label node "${UNDER_TEST_NODE}" ssp-role=under-test --overwrite
kubectl label node "${LOADGEN_NODE}"    ssp-role=loadgen    --overwrite
kubectl get nodes --show-labels | grep -E 'ssp-role|NAME'

UT_NODE_IP=$(kubectl get node "${UNDER_TEST_NODE}" \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
info "Under-test node IP: ${UT_NODE_IP}"

info "=== Step 4: Installing KEDA ==="
helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update kedacore
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace \
  --version 2.15.0 --wait --timeout 5m
kubectl -n keda get pods

info "=== Step 5: Deploying DSB SocialNetwork ==="
kubectl create namespace dsb --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace dsb istio.io/dataplane-mode=ambient --overwrite
helm repo add dsb https://raw.githubusercontent.com/delimitrou/DeathStarBench/master/helm-chart/socialnetwork 2>/dev/null || true
helm repo update dsb
helm upgrade --install social-network dsb/socialnetwork \
  --namespace dsb -f "${SCRIPT_DIR}/dsb-values.yaml" \
  --wait --timeout 15m
kubectl -n dsb get pods

info "=== Step 6: Deploying NATS JetStream DaemonSet ==="
kubectl apply -f "${SCRIPT_DIR}/nats-jetstream-daemonset.yaml"
kubectl -n nats-system rollout status ds/nats-jetstream --timeout=120s
for i in $(seq 1 12); do
  STATUS=$(curl -sf "http://${UT_NODE_IP}:8222/healthz" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
  [[ "$STATUS" == "ok" ]] && { info "NATS healthy"; break; }
  warn "Waiting for NATS... (${i}/12)"; sleep 5
done
[[ "${STATUS:-}" != "ok" ]] && error "NATS did not become healthy in 60s"

info "=== Step 7: Building + Deploying Rust Ingestion Proxy ==="
(
  cd "${SCRIPT_DIR}/ingestion-proxy"
  docker build -t "${REGISTRY}/ingestion-proxy:latest" .
  docker push "${REGISTRY}/ingestion-proxy:latest"
)
PROXY_MANIFEST=$(mktemp /tmp/proxy-XXXXXX.yaml)
sed "s|image: ingestion-proxy:latest|image: ${REGISTRY}/ingestion-proxy:latest|g" \
  "${SCRIPT_DIR}/ingestion-proxy-daemonset.yaml" > "${PROXY_MANIFEST}"
kubectl apply -f "${PROXY_MANIFEST}"
rm -f "${PROXY_MANIFEST}"
kubectl -n ingestion-proxy rollout status ds/ingestion-proxy --timeout=120s
info "Verifying JetStream streams created by proxy..."
sleep 10
curl -s "http://${UT_NODE_IP}:8222/jsz?streams=true" | python3 -m json.tool | grep '"name"' || true

info "=== Step 8: Deploying Workers + KEDA ScaledObjects ==="
WORKER_MANIFEST=$(mktemp /tmp/worker-XXXXXX.yaml)
sed "s|192.168.11.9|${UT_NODE_IP}|g" \
  "${SCRIPT_DIR}/worker-keda-manifests.yaml" > "${WORKER_MANIFEST}"
kubectl apply -f "${WORKER_MANIFEST}"
rm -f "${WORKER_MANIFEST}"
kubectl -n dsb get scaledobjects
kubectl -n dsb get deploy worker-alpha worker-beta

info "=== Step 9: Deploying probe pods ==="
kubectl apply -f "${SCRIPT_DIR}/manifests.yaml"
kubectl -n dsb get pods
kubectl -n loadgen get pods

info "=== Step 10: Running gate checks ==="
bash "${SCRIPT_DIR}/p0-gate-checks.sh"

info ""
info "===================================================="
info "  Cluster fully provisioned!"
info "  Under-test node IP: ${UT_NODE_IP}"
info "  Run experiments:"
info "    bash infra/p3_closedloop.sh"
info "    bash infra/p4_diff.sh pullbuffer"
info "===================================================="
