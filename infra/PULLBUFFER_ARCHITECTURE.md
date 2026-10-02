# Pull-Based Asymmetric Buffer — Architecture & Deployment Guide

> **Replaces**: `p3_controller.sh` (reactive connection-rate throttle)  
> **Design**: Node-Local Pull-Based Asymmetric Buffer with Multi-Tenant Broker Isolation and Queue-Metric Driven Autoscaling

---

## Overview

The mitigation no longer throttles the aggressor's connection rate reactively.
Instead, every under-test Kubernetes node runs three DaemonSet components that
form a stateless absorption buffer between ztunnel and the application workers:

```
[external client]
      │  HBONE/mTLS (port 15008)
      ▼
[ztunnel DaemonSet]          ← AuthorizationPolicy enforced at L4 (unchanged)
      │  plaintext TCP  127.0.0.1:10001 / 10002 / …
      ▼
[Rust Ingestion Proxy]       ← DaemonSet: non-blocking loopback listener → NATS publish
      │  NATS JetStream publish  127.0.0.1:4222
      ▼
[NATS JetStream DaemonSet]   ← isolated per-service streams; DiscardNew backpressure
      │  long-poll Fetch(1) via Queue Group
      ▼
[Worker Pod replicas]        ← KEDA scales 0→N from queue lag; pull 1 msg at a time
```

---

## Files Added / Changed

| File | Type | Description |
|---|---|---|
| `nats-jetstream-daemonset.yaml` | **New** | NATS 2.10 JetStream DaemonSet; 512Mi RAM limit; per-node domain |
| `ingestion-proxy-daemonset.yaml` | **New** | Rust proxy DaemonSet; hostNetwork; per-service loopback listeners |
| `worker-keda-manifests.yaml` | **New** | Worker Deployments + KEDA ScaledObjects + virtual Endpoints + AuthPol |
| `ingestion-proxy/` | **New** | Rust source (`src/main.rs`), `Cargo.toml`, `Dockerfile` |
| `manifests.yaml` | Updated | Header updated; `churngen_ctl` reference removed |
| `p3_closedloop.sh` | Updated | Phase 3 now measures NATS queue lag instead of invoking controller |
| `p4_diff.sh` | Updated | `ours` arm renamed to `pullbuffer`; controller invocation removed |

**Unchanged**: all Phase-0/1/2 scripts, `install-cilium-ambient.sh`, `cluster-p0.yaml`,  
`dsb-values.yaml`, `stat_rigor*.sh`, `p1_*.sh`, `p2_*.sh`, `p3_principle.sh`, `ebpf/`.

---

## Deployment Order

### Prerequisites
- EKS cluster from `cluster-p0.yaml` running
- Cilium 1.20 + Istio 1.31 ambient installed (`install-cilium-ambient.sh`)
- DSB SocialNetwork helm chart deployed into `dsb` namespace
- Node labels: `ssp-role=under-test` and `ssp-role=loadgen`
- KEDA installed: `helm install keda kedacore/keda -n keda --create-namespace`

### Step 1 — Build and push the Rust proxy image

```bash
cd infra/ingestion-proxy
docker build -t <your-registry>/ingestion-proxy:latest .
docker push <your-registry>/ingestion-proxy:latest
# Update image: field in ingestion-proxy-daemonset.yaml
```

### Step 2 — Deploy NATS JetStream broker

```bash
kubectl apply -f infra/nats-jetstream-daemonset.yaml
kubectl -n nats-system rollout status ds/nats-jetstream --timeout=120s
# Verify broker is up:
kubectl -n nats-system get pods -o wide
# Check JetStream health:
kubectl -n nats-system exec ds/nats-jetstream -- wget -qO- http://127.0.0.1:8222/healthz
```

### Step 3 — Deploy Rust ingestion proxy

```bash
kubectl apply -f infra/ingestion-proxy-daemonset.yaml
kubectl -n ingestion-proxy rollout status ds/ingestion-proxy --timeout=120s
```

### Step 4 — Deploy workers, KEDA ScaledObjects, and virtual Endpoints

```bash
kubectl apply -f infra/worker-keda-manifests.yaml
# Verify KEDA ScaledObjects are active:
kubectl -n dsb get scaledobjects
# Workers should be at 0 replicas with empty queue:
kubectl -n dsb get deploy worker-alpha worker-beta
```

### Step 5 — Apply existing probe pods

```bash
kubectl apply -f infra/manifests.yaml
```

### Step 6 — Verify end-to-end traffic path

```bash
# Confirm NATS streams exist (created by ingestion proxy on startup):
UT_IP=$(kubectl get node -l ssp-role=under-test \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -s "http://${UT_IP}:8222/jsz?streams=true" | python3 -m json.tool | grep '"name"'
# Expected output: "LOCAL-ALPHA", "LOCAL-BETA"
```

---

## Configuring Services

Edit the `SERVICES` key in the `ingestion-proxy-config` ConfigMap
(`ingestion-proxy-daemonset.yaml`) to match the services co-located on the
under-test node. Format: `name:port` pairs, comma-separated.

```yaml
SERVICES: "alpha:10001,beta:10002,gamma:10003"
```

Each name creates:
- A NATS JetStream stream: `LOCAL-<NAME>` on subject `local.tasks.<name>`
- A TCP loopback listener on `127.0.0.1:<port>`

A corresponding KEDA ScaledObject and Worker Deployment must be added to
`worker-keda-manifests.yaml` for each service.

---

## Tuning Reference

| Parameter | Location | Default | Effect |
|---|---|---|---|
| `STREAM_MAX_BYTES` | ConfigMap | 128 MiB | Per-stream memory wall; DiscardNew activates at this |
| `BACKLOG_LIMIT` | ConfigMap | 10 000 msgs | MaxMsgs per stream |
| `lagThreshold` | ScaledObject | 50 msgs/pod | KEDA target lag per replica |
| `activationLagThreshold` | ScaledObject | 1 msg | Min lag before any scaling |
| `stabilizationWindowSeconds` (down) | ScaledObject | 300 s | Scale-to-zero hysteresis |
| `terminationGracePeriodSeconds` | Worker Deployment | 60 s | Time to finish current message on SIGTERM |
| `NATS_FETCH_WAIT_SECONDS` | Worker env | 20 s | Long-poll idle window (prevents empty-queue thrashing) |
| NATS `max_memory_store` | nats.conf ConfigMap | 256 MiB | Total JetStream memory per node |
| NATS CPU/RAM limits | DaemonSet resources | 500m / 512Mi | Broker cgroup cage |

---

## Experiment Scripts

### Phase-3 closed-loop (`p3_closedloop.sh`)

```bash
bash infra/p3_closedloop.sh
```

Timeline:
- **Phase 1** (baseline): no aggressor; records victim P50/P99 + ztunnel busy rate.
- **Phase 2** (unmitigated): aggressor at full blast; pull-buffer mitigation infrastructure
  is running but churngen sends unrestricted connections to demonstrate interference.
- **Phase 3** (mitigated): same aggressor traffic; KEDA auto-scales worker pods from queue
  lag; ztunnel busy rate expected to drop as connections are absorbed instantly by the proxy.

CSV columns: `phase, v_p50, v_p99, zt_busy_rate, nats_lag_alpha, nats_lag_beta`

### Phase-4 differentiation (`p4_diff.sh`)

```bash
bash infra/p4_diff.sh none
bash infra/p4_diff.sh bwm_1M
bash infra/p4_diff.sh bwm_256k
bash infra/p4_diff.sh pullbuffer   # was: 'ours' (reactive controller)
```

CSV columns: `arm, trial, v_p99, agg_conn_rate, zt_busy_rate, nats_lag_alpha`

---

## Multi-Tenant Isolation Guarantees

| Property | Mechanism |
|---|---|
| Per-service memory wall | `stream.MaxBytes` in NATS; `DiscardNew` drops excess |
| No cross-service memory bleed | Each stream has a separate `max_bytes` allocation |
| Broker CPU/RAM cap | Kubernetes resource `limits` + cgroup enforcement |
| Worker isolation | Separate Deployment + KEDA ScaledObject per service |
| No double-processing | `RetentionPolicy: WorkQueue` — message deleted after ACK |
| Scale-to-zero | KEDA 300 s stabilisation window; 0 idle compute cost |
