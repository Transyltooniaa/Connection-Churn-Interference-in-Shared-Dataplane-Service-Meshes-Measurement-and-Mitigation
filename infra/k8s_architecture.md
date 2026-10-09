# Kubernetes Architecture — SSP Ambient Mesh Testbed
## Connection-Churn Interference Measurement & Mitigation

> **Stack**: EKS 1.33 · Cilium 1.20 (CNI) · Istio 1.31 Ambient (ztunnel) · KEDA · NATS JetStream · Rust Ingestion Proxy

---

## 1. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  AWS EKS Cluster  (us-east-2)  — 2× c6i.2xlarge nodes                     │
│                                                                             │
│  ┌─────────────────────────────┐   ┌──────────────────────────────────────┐│
│  │  Node: ssp-role=under-test  │   │  Node: ssp-role=loadgen              ││
│  │                             │   │                                      ││
│  │ ┌─────────────────────────┐ │   │  ┌──────────────────────────────┐   ││
│  │ │  ztunnel (DaemonSet)    │ │   │  │  loadgen pod (non-mesh ns)   │   ││
│  │ │  HBONE/mTLS :15008      │ │   │  │  wrk2 + aiohttp              │   ││
│  │ │  AuthorizationPolicy L4 │ │   │  └──────────────────────────────┘   ││
│  │ └────────────┬────────────┘ │   │                                      ││
│  │              │ plaintext    │   └──────────────────────────────────────┘│
│  │              │ 127.0.0.1   │                                             │
│  │ ┌────────────▼────────────┐ │                                             │
│  │ │  Rust Ingestion Proxy   │ │                                             │
│  │ │  (DaemonSet hostNetwork)│ │                                             │
│  │ │  :10001 :10002 …        │ │                                             │
│  │ └────────────┬────────────┘ │                                             │
│  │              │ NATS publish │                                             │
│  │              │ 127.0.0.1   │                                             │
│  │ ┌────────────▼────────────┐ │                                             │
│  │ │  NATS JetStream         │ │                                             │
│  │ │  (DaemonSet hostNetwork)│ │                                             │
│  │ │  :4222 client :8222 mon │ │                                             │
│  │ │  Streams: LOCAL-ALPHA   │ │                                             │
│  │ │           LOCAL-BETA    │ │                                             │
│  │ └────────────┬────────────┘ │                                             │
│  │              │ long-poll    │                                             │
│  │              │ Fetch(1)     │                                             │
│  │ ┌────────────▼────────────┐ │                                             │
│  │ │  Worker Pods            │ │                                             │
│  │ │  worker-alpha (0→20)    │ │                                             │
│  │ │  worker-beta  (0→20)    │ │                                             │
│  │ │  KEDA drives scale      │ │                                             │
│  │ └─────────────────────────┘ │                                             │
│  │                             │                                             │
│  │ ┌──────────┐ ┌────────────┐ │                                             │
│  │ │ nodeprobe│ │bpfbuilder  │ │                                             │
│  │ │ /proc    │ │ eBPF loader│ │                                             │
│  │ └──────────┘ └────────────┘ │                                             │
│  └─────────────────────────────┘                                             │
│                                                                             │
│  Control Plane: KEDA (keda ns) · CoreDNS · Cilium CNI                      │
│  Mesh Control: istiod (istio-system) · ztunnel DaemonSet                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Security Design — ztunnel + AuthorizationPolicy

The security boundary is enforced at the **Istio ambient ztunnel** (L4 proxy), **not** inside the application pods. No sidecar is injected.

### 2.1 Trust Model

```
[external client] ──HBONE/mTLS──► [ztunnel] ──L4 AuthzPolicy──► [ingestion proxy]
                                                                    │
                                                        SPIFFE SVID: cluster.local/
                                                        ns/ingestion-proxy/sa/ingestion-proxy
```

| Layer | Mechanism | What it enforces |
|-------|-----------|-----------------|
| **Transport** | HBONE (HTTP/2 CONNECT) over mTLS | All inter-node traffic is mutually-authenticated, encrypted |
| **Identity** | SPIFFE X.509 SVIDs issued by istiod | Every workload has a cryptographic identity — no IP-based auth |
| **L4 Access Control** | `AuthorizationPolicy` (ztunnel-enforced) | Only the ingestion proxy SA may receive inbound TCP for svc-alpha/beta |
| **Namespace isolation** | `istio.io/dataplane-mode: none` on `nats-system` + `ingestion-proxy` | Broker and proxy are **excluded** from the mesh — they only handle post-decrypt plaintext |
| **Broker auth** | NATS username/password (Kubernetes Secret) | Prevents unauthorized NATS publish from other pods |
| **Pod security** | `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: ALL` caps | Hardened containers even without a sidecar |

### 2.2 AuthorizationPolicy Flow

```
AuthorizationPolicy: allow-ingestion-proxy-alpha (namespace: dsb)
  selector: app=svc-alpha
  action: ALLOW
  from:
    principals: [cluster.local/ns/ingestion-proxy/sa/ingestion-proxy]

AuthorizationPolicy: allow-ingestion-proxy-beta (namespace: dsb)
  selector: app=svc-beta
  action: ALLOW
  from:
    principals: [cluster.local/ns/ingestion-proxy/sa/ingestion-proxy]
```

All traffic **not** matching these policies is **implicitly denied** by ztunnel once ambient mode is active.

---

## 3. Component Inventory

| Component | Kind | Namespace | Scheduling | Purpose |
|-----------|------|-----------|------------|---------|
| `ztunnel` | DaemonSet | `istio-system` | All nodes | HBONE/mTLS termination, L4 AuthzPolicy enforcement |
| `nats-jetstream` | DaemonSet | `nats-system` | `ssp-role=under-test` | Node-local message broker, JetStream streams |
| `ingestion-proxy` | DaemonSet | `ingestion-proxy` | `ssp-role=under-test` | Multi-ingress TCP→NATS bridge (Rust, hostNetwork) |
| `worker-alpha` | Deployment | `dsb` | `ssp-role=under-test` | Pull consumer for LOCAL-ALPHA stream |
| `worker-beta` | Deployment | `dsb` | `ssp-role=under-test` | Pull consumer for LOCAL-BETA stream |
| `keda-alpha` | ScaledObject | `dsb` | n/a | KEDA autoscaler for worker-alpha (lag-based) |
| `keda-beta` | ScaledObject | `dsb` | n/a | KEDA autoscaler for worker-beta (lag-based) |
| `agg-echo` | Deployment | `dsb` | `ssp-role=under-test` | Aggressor echo target (disjoint from victim) |
| `churn` | Pod | `dsb` | `ssp-role=under-test` | churngen aggressor source |
| `loadgen` | Pod | `loadgen` | `ssp-role=loadgen` | wrk2 victim traffic generator (non-mesh) |
| `nodeprobe` | Pod | `kube-system` | `ssp-role=under-test` | /proc + cgroup reader (node metrics) |
| `bpfbuilder` | Pod | `kube-system` | `ssp-role=under-test` | eBPF TC SYN-limiter builder |
| KEDA | Helm Release | `keda` | Control plane | Event-driven autoscaling operator |
| istiod | Deployment | `istio-system` | Control plane | Ambient mesh control plane + SVID issuance |
| Cilium | DaemonSet | `kube-system` | All nodes | CNI, eBPF dataplane, BBR bandwidth manager |

---

## 4. Namespace Layout

```
kube-system          — Cilium CNI, CoreDNS, nodeprobe, bpfbuilder
istio-system         — istiod, ztunnel DaemonSet
nats-system          — NATS JetStream DaemonSet  [istio.io/dataplane-mode: none]
ingestion-proxy      — Rust ingestion proxy DS   [istio.io/dataplane-mode: none]
dsb                  — App workloads (DSB SocialNetwork), workers, KEDA ScaledObjects
loadgen              — Load generator pod (non-ambient, external client perspective)
keda                 — KEDA operator
```

> **Critical**: `nats-system` and `ingestion-proxy` namespaces carry `istio.io/dataplane-mode: none` — they are intentionally **excluded** from the ambient mesh. These components handle already-decrypted plaintext on loopback; adding ztunnel would double-proxy them.

---

## 5. Step-by-Step Setup Commands

### Prerequisites
- AWS CLI configured, `eksctl` ≥ 0.180, `kubectl`, `helm` ≥ 3.14, `istioctl` 1.31

---

### Step 0 — Create the EKS Cluster

```bash
# From the repo root
eksctl create cluster -f infra/cluster-p0.yaml
# Takes ~15 min. Verify nodes (they'll be NotReady until Cilium installs):
kubectl get nodes
```

---

### Step 1 — Install Cilium + Istio Ambient

```bash
bash infra/install-cilium-ambient.sh
# This script:
#  [1] Neutralises aws-node (VPC CNI) — Cilium takes over networking
#  [2] Installs Cilium 1.20.2 (ENI mode, BBR, no bpf.masquerade)
#  [3] Waits for Cilium DaemonSet rollout
#  [4] Installs Istio 1.31 ambient profile (istiod + ztunnel DaemonSet)
#  [5] Applies CiliumClusterwideNetworkPolicy for kubelet health probes

# Verify ztunnel is running on all nodes:
kubectl -n istio-system get ds ztunnel -o wide
kubectl -n istio-system get pods -l app=ztunnel -o wide
```

---

### Step 2 — Label Nodes

```bash
# Identify the two worker nodes:
kubectl get nodes -o wide

# Label the "under-test" node (victim services + aggressor share this node):
kubectl label node <UNDER_TEST_NODE_NAME> ssp-role=under-test

# Label the load-generator node:
kubectl label node <LOADGEN_NODE_NAME> ssp-role=loadgen
```

---

### Step 3 — Install KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --version 2.15.0 \
  --wait

# Verify KEDA operator is running:
kubectl -n keda get pods
```

---

### Step 4 — Deploy DSB SocialNetwork (DeathStarBench)

```bash
helm repo add dsb https://raw.githubusercontent.com/delimitrou/DeathStarBench/master/helm-chart/socialnetwork
helm repo update

# Enable ambient mesh on the dsb namespace BEFORE deploying:
kubectl create namespace dsb
kubectl label namespace dsb istio.io/dataplane-mode=ambient

helm install social-network dsb/socialnetwork \
  --namespace dsb \
  -f infra/dsb-values.yaml \
  --wait --timeout 10m

# Verify pods:
kubectl -n dsb get pods
```

---

### Step 5 — Deploy NATS JetStream DaemonSet

```bash
kubectl apply -f infra/nats-jetstream-daemonset.yaml

# Wait for rollout on the under-test node:
kubectl -n nats-system rollout status ds/nats-jetstream --timeout=120s

# Verify NATS is healthy:
UT_NODE=$(kubectl get node -l ssp-role=under-test \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -s "http://${UT_NODE}:8222/healthz"
# Expected: {"status":"ok","jetstream":{"config":{"domain":"node-local",...}}}
```

---

### Step 6 — Build and Push the Rust Ingestion Proxy

```bash
cd infra/ingestion-proxy

# Build the Docker image (requires Docker + Rust toolchain or just Docker for multi-stage build):
docker build -t <YOUR_REGISTRY>/ingestion-proxy:latest .
docker push <YOUR_REGISTRY>/ingestion-proxy:latest

# Update the image field in the daemonset manifest:
sed -i "s|image: ingestion-proxy:latest|image: <YOUR_REGISTRY>/ingestion-proxy:latest|" \
  ../ingestion-proxy-daemonset.yaml

cd ../..
```

---

### Step 7 — Deploy Rust Ingestion Proxy DaemonSet

```bash
kubectl apply -f infra/ingestion-proxy-daemonset.yaml

# Wait for rollout:
kubectl -n ingestion-proxy rollout status ds/ingestion-proxy --timeout=120s

# Verify streams were created by the proxy on startup:
curl -s "http://${UT_NODE}:8222/jsz?streams=true" | python3 -m json.tool | grep '"name"'
# Expected: "LOCAL-ALPHA", "LOCAL-BETA"
```

---

### Step 8 — Deploy Workers + KEDA ScaledObjects + Virtual Endpoints

```bash
# Patch the NATS monitoring endpoint IP in the ScaledObjects:
sed -i "s|192.168.11.9|${UT_NODE}|g" infra/worker-keda-manifests.yaml

kubectl apply -f infra/worker-keda-manifests.yaml

# Verify KEDA ScaledObjects are Active:
kubectl -n dsb get scaledobjects
# READY=True, ACTIVE=False (queue empty → 0 replicas)

# Workers should be at 0:
kubectl -n dsb get deploy worker-alpha worker-beta
```

---

### Step 9 — Deploy Probe + Aggressor Pods

```bash
kubectl apply -f infra/manifests.yaml

# Wait for all pods:
kubectl -n dsb get pods
kubectl -n loadgen get pods
kubectl -n kube-system get pods -l app=nodeprobe
kubectl -n kube-system get pods -l app=bpfbuilder
```

---

### Step 10 — Verify Gate Checks

```bash
bash infra/p0-gate-checks.sh
# Checks: Cilium ready, ztunnel ready, DSB pods ready, NATS healthy,
#         proxy streams exist, KEDA ScaledObjects active.
```

---

## 6. Full Traffic-Path Walkthrough

```
1. loadgen (non-mesh, ssp-role=loadgen node)
      │  HTTP/1.1 to ClusterIP:8080
      ▼
2. ztunnel on loadgen node
      │  wraps in HBONE tunnel: HTTP/2 CONNECT + mTLS (x509 SVID)
      ▼
3. ztunnel on under-test node  ← AuthorizationPolicy enforced HERE
      │  validates peer SVID; checks AuthzPolicy for svc-alpha
      │  only allows: ns/ingestion-proxy/sa/ingestion-proxy
      │  decrypts to plaintext TCP
      ▼
4. Rust Ingestion Proxy (127.0.0.1:10001)  [hostNetwork DaemonSet]
      │  non-blocking accept → reads ≤1MiB payload
      │  publishes to NATS subject: local.tasks.alpha
      │  connection closed immediately after publish
      ▼
5. NATS JetStream (127.0.0.1:4222)  [hostNetwork DaemonSet]
      │  WorkQueue retention: exactly-once delivery
      │  DiscardNew when stream.MaxBytes (128MiB) exceeded
      │  KEDA scrapes :8222/jsz for consumer lag
      ▼
6. worker-alpha Pod  (long-poll Fetch(1), NATS queue group)
      │  pulls 1 message, processes, sends ACK
      │  NATS deletes message on ACK (WorkQueue semantics)
      ▼
   KEDA ScaledObject: targetPods = ceil(queue_lag / 50)
   Scale-up:  up to 4 pods/15s (burst)
   Scale-down: 1 pod/60s, 300s stabilization window
```

---

## 7. KEDA Scaling Formula

```
targetReplicas = ceil(consumerLag / lagThreshold)

Where:
  consumerLag   = NATS JetStream pending messages for consumer group
  lagThreshold  = 50 messages per pod (configurable in ScaledObject)

Activation: only triggers when lag ≥ 1 (activationLagThreshold)
Scale-down: waits 300s of empty queue before going to 0 (hysteresis)
```

---

## 8. Tuning Reference

| Parameter | Location | Default | Effect |
|-----------|----------|---------|--------|
| `STREAM_MAX_BYTES` | `ingestion-proxy-config` ConfigMap | 128 MiB | Per-stream memory wall; `DiscardNew` activates at this |
| `BACKLOG_LIMIT` | `ingestion-proxy-config` ConfigMap | 10 000 msgs | `MaxMsgs` per stream |
| `lagThreshold` | ScaledObject | 50 msgs/pod | KEDA target lag per replica |
| `activationLagThreshold` | ScaledObject | 1 msg | Min lag before any scaling |
| `stabilizationWindowSeconds` (down) | ScaledObject | 300 s | Scale-to-zero hysteresis |
| `terminationGracePeriodSeconds` | Worker Deployment | 60 s | Time to finish current message on SIGTERM |
| `NATS_FETCH_WAIT_SECONDS` | Worker env | 20 s | Long-poll idle window (prevents empty-queue thrashing) |
| `max_memory_store` | `nats-node-config` ConfigMap | 256 MiB | Total JetStream memory per node instance |
| NATS CPU/RAM limits | `nats-jetstream` DaemonSet | 500m / 512Mi | Broker cgroup cage |
| Proxy CPU/RAM limits | `ingestion-proxy` DaemonSet | 500m / 256Mi | Proxy cgroup cage |

---

## 9. Multi-Tenant Isolation Guarantees

| Property | Mechanism |
|----------|-----------|
| Per-service memory wall | `stream.MaxBytes` in NATS; `DiscardNew` drops excess after cap |
| No cross-service memory bleed | Each stream has a **separate** `max_bytes` allocation |
| Broker CPU/RAM cap | K8s resource `limits` + cgroup enforcement on NATS pod |
| Worker isolation | Separate Deployment + KEDA ScaledObject per service |
| No double-processing | `RetentionPolicy: WorkQueue` — message deleted after ACK |
| Scale-to-zero | KEDA 300 s stabilisation window; 0 idle compute cost |
| L4 identity enforcement | ztunnel `AuthorizationPolicy` bound to SPIFFE principal (not IP) |
| Broker access control | NATS password auth (Kubernetes Secret, not ConfigMap) |

---

## 10. Adding a New Service

To add a third service (e.g., `gamma` on port 10003):

**1. Update ConfigMap in `ingestion-proxy-daemonset.yaml`:**
```yaml
SERVICES: "alpha:10001,beta:10002,gamma:10003"
```

**2. Add port entry in the DaemonSet:**
```yaml
- name: svc-gamma
  containerPort: 10003
  hostPort: 10003
  protocol: TCP
```

**3. Add to `worker-keda-manifests.yaml`:**
- Copy the `worker-alpha` Deployment block → rename to `worker-gamma`
- Change `NATS_SUBJECT` to `local.tasks.gamma`, `NATS_QUEUE_GROUP` to `workers-gamma`
- Copy `keda-alpha` ScaledObject → rename to `keda-gamma`
- Change `streamName` to `LOCAL-GAMMA`, `consumerName` to `workers-gamma`
- Add `svc-gamma` Service + Endpoints pointing to `127.0.0.1:10003`
- Add `AuthorizationPolicy` for `app: svc-gamma`

**4. Redeploy:**
```bash
kubectl apply -f infra/ingestion-proxy-daemonset.yaml
kubectl apply -f infra/worker-keda-manifests.yaml
kubectl -n ingestion-proxy rollout restart ds/ingestion-proxy
```

---

## 11. Observability Commands

```bash
# ── NATS queue lag (live) ──────────────────────────────────────────────────
UT_NODE=$(kubectl get node -l ssp-role=under-test \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -s "http://${UT_NODE}:8222/jsz?streams=true&consumers=true" | \
  python3 -m json.tool

# ── KEDA ScaledObject status ───────────────────────────────────────────────
kubectl -n dsb get scaledobjects -o wide
kubectl -n dsb describe scaledobject keda-alpha

# ── Worker replica count ───────────────────────────────────────────────────
kubectl -n dsb get deploy worker-alpha worker-beta

# ── ztunnel connection stats ───────────────────────────────────────────────
kubectl -n istio-system exec ds/ztunnel -- \
  curl -s http://localhost:15000/stats | grep -E 'cx_|connection'

# ── Ingestion proxy logs ───────────────────────────────────────────────────
kubectl -n ingestion-proxy logs ds/ingestion-proxy -f

# ── Node CPU/cgroup (via nodeprobe) ───────────────────────────────────────
kubectl -n kube-system exec nodeprobe -- \
  cat /host/sys/fs/cgroup/system.slice/ztunnel.service/cpu.stat

# ── Cilium bandwidth manager ───────────────────────────────────────────────
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec ${CILIUM_POD} -- cilium status | grep -i bandwidth
```

---

## 12. Experiment Phase Cheat Sheet

| Phase | Script | What it measures |
|-------|--------|-----------------|
| Gate checks | `p0-gate-checks.sh` | Cluster baseline health |
| P1 baseline sweep | `p1_sweep_v2.sh` | Victim latency vs connection rate (no aggressor) |
| P2 high-cadence | `p2_highcadence.sh` | Interference signal characterization |
| P3 closed-loop | `p3_closedloop.sh` | Pull-buffer mitigation (NATS lag as control signal) |
| P4 differentiation | `p4_diff.sh` | `none` vs `bwm_1M` vs `bwm_256k` vs `pullbuffer` |
| Stat rigor | `stat_rigor2.sh` | Bootstrap CIs, Mann-Whitney U, effect sizes |
