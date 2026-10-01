# SETUP / RECOVERY RUNBOOK — SSP Ambient-Mesh Proposal

How to recreate the cluster from scratch (or resume the paused one) and replicate/fix any
result. Written 2026-09-18 after the full 6-phase study. Read this first if "something feels
wrong" or you're returning after a break.

--------------------------------------------------------------------------------
## 0. TL;DR — three situations

| Situation | Action |
|---|---|
| **Cluster still exists, nodes scaled to 0** (current state) | `eksctl scale nodegroup --cluster ssp-p0 --region us-east-2 --name ng-p0 --nodes 2` → wait ~3min → workloads (Cilium/Istio/DSB) auto-reschedule. Then §4 re-derive dynamic values. |
| **Cluster deleted / recreating fresh** | Run §1 → §2 → §3 → §4 in order (~40min). |
| **Just want the data/results, no cluster** | Everything is in `phases/phase{0..6}/RESULTS.md` + `data/`. No cluster needed. |

Environment gotcha (ALWAYS): base PATH is broken on this box. Prefix every shell:
`export PATH=/usr/bin:/bin:/usr/local/bin:$PATH`
matplotlib/scipy only in `/home/ubuntu/anaconda3/bin/python`. AWS: acct 355905009903, region
us-east-2. CLIs (kubectl/eksctl/istioctl 1.31/helm) in /usr/local/bin.

--------------------------------------------------------------------------------
## 1. VERIFIED VERSION STACK (do not deviate without re-checking compat)
(full rationale: `lit-review/04_version_matrix.md`)
- EKS Kubernetes **1.33** (only ver inside Istio-1.31 AND Cilium-1.20 support)
- AL2023 nodes, kernel **6.12** (auto on 1.33 AMIs; clears EDT/bpf_skb_set_tstamp/tracepoints)
- Istio **1.31** ambient (ambient GA since 1.24; do NOT use 1.23 = EOL)
- Cilium **1.20.2**, **OVERLAY/VXLAN** mode (ENI mode FAILED — node role lacks ec2 ENI IAM)
- Nodes: **c6i.2xlarge** (non-burstable — t3 credits ruin tail reproducibility)
- Fortio/wrk2: giltene wrk2 built in-pod (NOTE: lacks `-D exp`; use `-R` only, still open-loop)

--------------------------------------------------------------------------------
## 2. RECREATE CLUSTER (fresh)
```bash
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
cd /datastore2/ajitesh/ssp/proposal-v2/infra
eksctl create cluster -f cluster-p0.yaml        # ~15-20min; 2x c6i.2xlarge, k8s 1.33
```
Then install Cilium(overlay) + Istio ambient. `install-cilium-ambient.sh` was written for ENI
mode which FAILS — use the OVERLAY commands below instead (these are what actually worked):
```bash
# neutralize VPC CNI so Cilium owns networking
kubectl -n kube-system patch daemonset aws-node --type=strategic \
  -p='{"spec":{"template":{"spec":{"nodeSelector":{"io.cilium/aws-node-enabled":"true"}}}}}'
# Cilium 1.20.2 OVERLAY (bpf.masquerade OFF for ambient; keep kube-proxy)
helm install cilium oci://quay.io/cilium/charts/cilium --version 1.20.2 -n kube-system \
  --set routingMode=tunnel --set tunnelProtocol=vxlan \
  --set bpf.masquerade=false --set kubeProxyReplacement=false --set cni.exclusive=false \
  --set bandwidthManager.enabled=true --set bandwidthManager.bbr=true
kubectl -n kube-system rollout status ds/cilium --timeout=300s
# Istio 1.31 ambient
istioctl install --set profile=ambient --skip-confirmation
```
GOTCHA: if `helm install cilium` says "cannot re-use name" or a `cilium-secrets` ns is stuck
Terminating (from a prior failed install) → `helm uninstall cilium -n kube-system`; if the ns
hangs, clear its finalizer:
```bash
kubectl get ns cilium-secrets -o json | python3 -c "import sys,json;d=json.load(sys.stdin);d['spec']['finalizers']=[];print(json.dumps(d))" \
 | kubectl replace --raw /api/v1/namespaces/cilium-secrets/finalize -f -
```
Do NOT apply the Istio health-probe CiliumClusterwideNetworkPolicy with `endpointSelector: {}`
— it flips the whole cluster to default-deny-ingress and blocks everything. Only needed if you
run a default-deny policy (we don't).

Verify gate (Phase 0):
```bash
kubectl get nodes -o custom-columns='N:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion'
CIL=$(kubectl -n kube-system get pod -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec $CIL -- cilium status | grep -iE 'BandwidthManager|Routing'
# expect: "BandwidthManager: EDT with BPF [BBR]" and "Tunnel [vxlan]"
```

--------------------------------------------------------------------------------
## 3. DEPLOY WORKLOADS (DSB SocialNetwork + loadgen + aggressors)
```bash
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
# label the two nodes
NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
kubectl label node ${NODES[0]} ssp-role=under-test --overwrite
kubectl label node ${NODES[1]} ssp-role=loadgen --overwrite
# DSB SocialNetwork (ambient ns), pinned images
kubectl create namespace dsb; kubectl label ns dsb istio.io/dataplane-mode=ambient --overwrite
SN=/datastore2/ajitesh/ssp/proposal-v2/DeathStarBench/socialNetwork/helm-chart/socialnetwork
helm install dsb "$SN" -n dsb -f /datastore2/ajitesh/ssp/proposal-v2/infra/dsb-values.yaml
# pin ALL dsb deploys to under-test node (co-location = shared ztunnel)
for d in $(kubectl -n dsb get deploy -o jsonpath='{.items[*].metadata.name}'); do
  kubectl -n dsb patch deploy "$d" --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"ssp-role":"under-test"}}}}}'; done
# CAP ztunnel CPU to 1 core (confound control: proxy saturates while node has headroom)
kubectl -n istio-system patch ds ztunnel --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"200m","memory":"512Mi"},"limits":{"cpu":"1000m","memory":"1Gi"}}}]'
# disjoint aggressor target (shares ONLY ztunnel with victim)
kubectl -n dsb create deployment agg-echo --image=hashicorp/http-echo:1.0 -- -text=agg -listen=:5678 || true
# (see infra for the full agg-echo Deployment+Service YAML if needed)
```
Load the social graph (once) + build tooling — see §3b.

### 3b. loadgen + churn pods (the drivers)
Recreate the debian pods and rebuild wrk2 + churngen binaries (they're NOT baked into images):
- loadgen pod: ns `loadgen`, node `ssp-role=loadgen`. Install: git build-essential libssl-dev
  zlib1g-dev python3 python3-pip; `git clone https://github.com/giltene/wrk2 /opt/wrk2 && make
  && cp /opt/wrk2/wrk /usr/local/bin/wrk2`; `pip3 install --break-system-packages aiohttp`.
  Copy DSB scripts+dataset in; PATCH lua to RELATIVE paths (see GOTCHA #1).
- churn pod: ns `dsb`, node `ssp-role=under-test`, install golang-go. The churngen sources
  (churn.go / churn_ctl.go) are embedded in infra/p3_*.sh and p4_diff.sh — copy from there and
  `go build`. churn_ctl reads a live rate cap from /tmp/rate (the controller writes it).
- Load social graph: from loadgen, `python3 init_social_graph.py --graph socfb-Reed98 --ip
  nginx-thrift.dsb.svc.cluster.local --port 8080` (needs dataset at datasets/social-graph/).

--------------------------------------------------------------------------------
## 4. ★ RE-DERIVE DYNAMIC VALUES (scripts HARDCODE these — they CHANGE on every recreate!)
The Phase-2/3/4 scripts hardcode the ztunnel pod UID and the churn veth. After ANY recreate
or pod restart, re-derive and update the scripts, or results will be wrong/empty:
```bash
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
UT=$(kubectl get node -l ssp-role=under-test -o jsonpath='{.items[0].metadata.name}')
# ztunnel pod UID on under-test node (scripts use ZTUID_US = UID with _ instead of -)
kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$UT -o jsonpath='{.items[0].metadata.uid}'
# ztunnel pod IP (metrics scrape :15020)
kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$UT -o jsonpath='{.items[0].status.podIP}'
# churn pod host veth (aggressor) — needed only for eBPF/tc attach experiments
PEER=$(kubectl -n dsb exec churn -- cat /sys/class/net/eth0/iflink)
kubectl -n kube-system exec bpfbuilder -- bash -c "ip -o link | awk -F': ' '\$1==$PEER{print \$2}' | cut -d@ -f1"
```
Then sed-replace `ZTUID_US=...`, `ZTIP=...`, veth name in the relevant infra/*.sh before running.
The nodeprobe (kube-system/nodeprobe) reads host /proc + cgroup because metrics-server/kubectl
top is BROKEN on Cilium overlay (see GOTCHA #2). Recreate it if missing (spec in git history /
p1 work: privileged, hostPID, mounts /proc + /sys/fs/cgroup).

--------------------------------------------------------------------------------
## 5. REPLICATE A SPECIFIC RESULT
Each phase's script + expected numbers (baseline victim P99 ≈ 2.8ms throughout):
- **P1 characterization** (`infra/p1_sweep_v2.sh`): churn arm → victim P99 ~50ms (17× amp),
  ztunnel saturates (throttle, ~1.13c), node ~30%. compose arm → cliff at 2000rps.
- **P2 signal** (`infra/p2_highcadence.sh`, 5 reps): signals are near-perfect DETECTORS
  (throttle/busy 100% idle-vs-loaded), NOT proportional predictors (within-regime r≈0), no lead.
- **P3 mitigation** (`infra/p3_closedloop.sh` + `p3_controller.sh`): unmitigated ~46ms →
  mitigated ~3.6ms (13× recovery). Controller = threshold on ztunnel busy-rate + DWELL/hysteresis.
- **P3 principle** (`infra/p3_principle.sh`): conn-rate cap ≤800/s un-saturates ztunnel, victim recovers.
- **P4 differentiation** (`infra/p4_diff.sh`): Cilium BWM@1M ~56ms (no help), BWM@256k ~29ms
  (barely), OURS ~3.5ms. Toggle BWM via churn pod annotation `kubernetes.io/egress-bandwidth`
  (recreate pod to change).
- **P6 overhead** (bpftool prog run bench = 9ns; no-op idle = baseline; setpoint sweep robust).
Always: run each cell N≥5 for CI (some phases were spikes at n=1-3 — see each RESULTS.md caveats).

--------------------------------------------------------------------------------
## 6. KNOWN GOTCHAS (the traps we hit — check these FIRST if something's wrong)
1. **wrk2 lua scripts hardcode `http://localhost:8080`** → wrk2 mis-formats requests → ALL
   non-2xx. FIX: `sed -i 's|http://localhost:8080||' *.lua` (use RELATIVE paths).
2. **metrics-server / `kubectl top` BROKEN on Cilium overlay** ("Address is not allowed" — it
   rejects overlay pod IPs). Use the `nodeprobe` pod reading /host/proc/stat + cgroup cpu.stat
   directly. Don't rely on `kubectl top`.
3. **churngen RUNAWAY**: a detached churngen kept hammering ztunnel after its launcher died,
   silently contaminating baselines (P99 stuck ~50ms with "nothing running"). ALWAYS after a
   run: `kubectl -n dsb exec churn -- pgrep -c churngen; ...churngen_ctl`. If a pod is wedged,
   `kubectl -n dsb delete pod churn --force` and rebuild. churngen now has a hard timeout; keep it.
4. **Contaminated baseline check**: victim P99 should be ~2.8ms with no aggressor. If it's tens
   of ms "at idle", something is still loading ztunnel (see #3) — hunt it before trusting data.
5. **eBPF actuator vs Cilium**: Cilium owns the veth via a **tcx** hook (`cil_from_container`)
   that runs BEFORE classic `tc` filters, so a classic-tc attach sees 0 packets. The compiled
   synlimit.bpf.o is the artifact; real in-dataplane attach needs tcx-ordering (cilium/ebpf Go
   loader or newer bpftool). Phase-3/4 closed-loop used connection-layer enforcement (PoC path).
   bpfbuilder pod (kube-system, privileged, clang/bpftool) is where we compiled/loaded it.
6. **ztunnel/waypoint are distroless** (no cat/sh/curl) → read cgroup from the node (nodeprobe),
   scrape metrics from another pod (loadgen curl → ztunnel :15020).
7. **Pod recreate changes veth ifindex + pod UID** → re-derive (§4) before eBPF/cgroup scripts.
8. **Long polls hit the 10-min shell cap** → run long experiments in background (`&`) and poll.

--------------------------------------------------------------------------------
## 7. COST CONTROL
- Running (2 nodes): ~$0.66/hr. Nodes scaled to 0: ~$0.10/hr (control plane, current state).
- Scale to 0 when idle: `eksctl scale nodegroup --cluster ssp-p0 --region us-east-2 --name ng-p0 --nodes 0`
- Full teardown ($0): `eksctl delete cluster --name ssp-p0 --region us-east-2`
  (if delete hangs on VPC/subnets: a leftover VPC endpoint or SG blocks it — delete those
  manually then re-run; we hit this once with the old ssp-baseline cluster.)

--------------------------------------------------------------------------------
## 8. FILE MAP
- `RESEARCH_PLAN.md` — full plan/phases/thesis. `GROUND_TRUTH.md` — ICCD paper facts (unpublished).
- `lit-review/` — novelty(01), feasibility(02), benchmark(03), version-matrix(04), summary(00).
- `phases/phase{0..6}/{BRIEF,RESULTS,STATUS}.md` + `data/<RUN_ID>/` — per-phase results + raw.
- `phases/README.md` — checkpoint protocol. `phases/DATA_AND_STATS_STANDARD.md` — capture/stats rules.
- `infra/*.sh` — all experiment harnesses (churngen sources embedded in p3_*/p4_*). `cluster-p0.yaml`,
  `dsb-values.yaml` — provisioning inputs.
- `infra/manifests.yaml` — ★ all reusable pod specs (agg-echo, churn, loadgen, nodeprobe,
  bpfbuilder) in one `kubectl apply`. `infra/ebpf/synlimit.bpf.c` + `BUILD.md` — the eBPF
  SYN-limiter source + build/bench notes (RESCUED from the ephemeral bpfbuilder pod).
- Memory: `~/.claude/projects/-home-ubuntu/memory/ssp-eks-baseline.md` — running state across sessions.
