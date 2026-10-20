#!/bin/bash
# ============================================================
# setup-full.sh
# SSP Ambient-Mesh Testbed — Bare-Metal (kubeadm) Full Setup
# ============================================================
# Orchestrates the complete bring-up sequence for a 3-node
# bare-metal cluster (1 controller + 2 workers):
#
#   0. Prerequisite checks
#   1. [MANUAL] kubeadm cluster init + worker join
#   2. Cilium 1.20 + Istio 1.31 ambient install
#   3. Node labeling (ssp-role)
#   4. KEDA install
#   5. DSB SocialNetwork helm chart (local or upstream)
#   6. NATS JetStream DaemonSet
#   7. Rust Ingestion Proxy DaemonSet
#   8. Workers + KEDA ScaledObjects + virtual Endpoints
#   9. Probe pods (manifests.yaml)
#  10. Gate checks
#
# BEFORE RUNNING:
#   1. Bootstrap the cluster manually (see infra/kubeadm-config.yaml)
#   2. Set the environment variables below:
#
#   export REGISTRY=YOUR_DOCKERHUB_USER        # e.g. myuser (Docker Hub)
#   export UNDER_TEST_NODE=<k8s node name>     # Worker-1 (ssp-role=under-test)
#   export LOADGEN_NODE=<k8s node name>        # Worker-2 (ssp-role=loadgen)
#   bash infra/setup-full.sh
#
# Flags:
#   SKIP_CILIUM_INSTALL=1   skip step 2 (if already installed)
#   SKIP_DSB=1              skip step 5 (if DSB already deployed)
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

info "=== Step 0: Prerequisite checks ==="
for bin in kubectl helm istioctl docker; do
  command -v "$bin" &>/dev/null || error "'$bin' not found in PATH. Install it first."
  info "  OK $bin"
done
[[ -z "${REGISTRY:-}" ]] && error "REGISTRY env var not set. E.g.: export REGISTRY=myuser"
info "  Registry: ${REGISTRY}"

# ── Step 1: Cluster init is MANUAL for bare-metal ────────────────────────
info "=== Step 1: kubeadm cluster bootstrap ==="
info "  This step is MANUAL. The cluster must already exist."
info "  See infra/kubeadm-config.yaml for bootstrap instructions."
info "  Verifying cluster connectivity..."
kubectl cluster-info || error "Cannot reach cluster. Check kubeconfig / run kubeadm init first."

# ── Step 2: Cilium + Istio ambient ───────────────────────────────────────
if [[ "${SKIP_CILIUM_INSTALL:-0}" != "1" ]]; then
  info "=== Step 2: Installing Cilium 1.20 + Istio 1.31 ambient ==="
  bash "${SCRIPT_DIR}/install-cilium-ambient.sh"
else
  info "=== Step 2: SKIPPED (SKIP_CILIUM_INSTALL=1) ==="
fi

# ── Step 3: Label nodes ───────────────────────────────────────────────────
info "=== Step 3: Labeling nodes ==="
if [[ -z "${UNDER_TEST_NODE:-}" ]] || [[ -z "${LOADGEN_NODE:-}" ]]; then
  warn "UNDER_TEST_NODE / LOADGEN_NODE not set. Current nodes:"
  kubectl get nodes -o wide
  read -rp "Enter UNDER_TEST_NODE name (worker-1, under-test): " UNDER_TEST_NODE
  read -rp "Enter LOADGEN_NODE name (worker-2, loadgen):        " LOADGEN_NODE
fi
kubectl label node "${UNDER_TEST_NODE}" ssp-role=under-test --overwrite
kubectl label node "${LOADGEN_NODE}"    ssp-role=loadgen    --overwrite
kubectl get nodes --show-labels | grep -E 'ssp-role|NAME'

# Capture the under-test node internal IP (used for NATS health checks + KEDA)
UT_NODE_IP=$(kubectl get node "${UNDER_TEST_NODE}" \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
info "Under-test node IP: ${UT_NODE_IP}"

# ── Step 4: KEDA ─────────────────────────────────────────────────────────
info "=== Step 4: Installing KEDA ==="
helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update kedacore
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace \
  --version 2.15.0 --wait --timeout 5m
kubectl -n keda get pods

# ── Step 5: DSB SocialNetwork ─────────────────────────────────────────────
if [[ "${SKIP_DSB:-0}" != "1" ]]; then
  info "=== Step 5: Deploying DSB SocialNetwork ==="
  kubectl create namespace dsb --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace dsb istio.io/dataplane-mode=ambient --overwrite

  # Check for a local helm chart first (DeathStarBench submodule).
  DSB_LOCAL_CHART="${SCRIPT_DIR}/../DeathStarBench/socialNetwork/helm-chart/socialnetwork"
  if [[ -d "${DSB_LOCAL_CHART}" ]]; then
    info "  Using local DSB chart: ${DSB_LOCAL_CHART}"
    helm upgrade --install social-network "${DSB_LOCAL_CHART}" \
      --namespace dsb -f "${SCRIPT_DIR}/dsb-values.yaml" \
      --wait --timeout 15m
  else
    info "  Local chart not found; using upstream DSB helm repo"
    helm repo add dsb https://raw.githubusercontent.com/delimitrou/DeathStarBench/master/helm-chart/socialnetwork 2>/dev/null || true
    helm repo update dsb
    helm upgrade --install social-network dsb/socialnetwork \
      --namespace dsb -f "${SCRIPT_DIR}/dsb-values.yaml" \
      --wait --timeout 15m
  fi

  # Pin ALL DSB deployments to the under-test node (co-location = shared ztunnel).
  info "  Pinning all DSB pods to under-test node: ${UNDER_TEST_NODE}"
  for d in $(kubectl -n dsb get deploy -o jsonpath='{.items[*].metadata.name}'); do
    kubectl -n dsb patch deploy "$d" --type merge \
      -p '{"spec":{"template":{"spec":{"nodeSelector":{"ssp-role":"under-test"}}}}}' \
      2>/dev/null || true
  done

  # CAP ztunnel CPU to 1 core (confound control per study design).
  kubectl -n istio-system patch ds ztunnel --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"200m","memory":"512Mi"},"limits":{"cpu":"1000m","memory":"1Gi"}}}]'

  kubectl -n dsb get pods
else
  info "=== Step 5: SKIPPED (SKIP_DSB=1) ==="
fi

# ── Step 6: NATS JetStream DaemonSet ──────────────────────────────────────
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

# ── Step 7: Build + Deploy Rust Ingestion Proxy ────────────────────────────
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

# ── Step 8: Workers + KEDA ScaledObjects + virtual Endpoints ──────────────
info "=== Step 8: Deploying Workers + KEDA ScaledObjects ==="
WORKER_MANIFEST=$(mktemp /tmp/worker-XXXXXX.yaml)
# Patch NATS monitoring endpoint with actual under-test node IP.
sed "s|100.117.8.27|${UT_NODE_IP}|g" \
  "${SCRIPT_DIR}/worker-keda-manifests.yaml" > "${WORKER_MANIFEST}"
kubectl apply -f "${WORKER_MANIFEST}"
rm -f "${WORKER_MANIFEST}"
kubectl -n dsb get scaledobjects
kubectl -n dsb get deploy worker-alpha worker-beta

# ── Step 9: Probe pods ─────────────────────────────────────────────────────
info "=== Step 9: Deploying probe pods ==="
kubectl apply -f "${SCRIPT_DIR}/manifests.yaml"
kubectl -n dsb get pods
kubectl -n loadgen get pods

# ── Step 10: Gate checks ───────────────────────────────────────────────────
info "=== Step 10: Running gate checks ==="
bash "${SCRIPT_DIR}/p0-gate-checks.sh"

info ""
info "===================================================="
info "  Cluster fully provisioned!"
info "  Under-test node (WORKER1): ${UNDER_TEST_NODE}  IP: ${UT_NODE_IP}"
info "  Loadgen node    (WORKER2): ${LOADGEN_NODE}"
info "  Run experiments:"
info "    bash infra/p3_closedloop.sh"
info "    bash infra/p4_diff.sh pullbuffer"
info "===================================================="
