# Research Plan v2 — Proxy-Saturation-Driven EDT Pacing for Ambient-Mesh Fairness

Grounded in: the ICCD paper as TRUTH (`GROUND_TRUTH.md`), and the literature review
(`lit-review/`). Target: A*-grade (NSDI/OSDI/ATC primary; IMC fallback for measurement-heavy
framing). **NO synthetic svc-a/svc-b / http-echo experiment at all** (user decision
2026-09-18) — everything is demonstrated on the DSB microservice benchmark directly. The
"noise source" co-located on the victim's ztunnel is either a DSB-internal aggressor
(headline, purest all-DSB story) or a generic load pod used only to shape burst/churn noise;
all *measured* results are DSB victim latency. NB "interception" needs no code — ambient
ztunnel intercepts pod traffic transparently.

Decisions taken (defaults, user was away for final confirm — revisit if desired):
- Mitigation scope: **full closed-loop pacer + all baselines** (Cilium BWM, admission/drop,
  VPA). Required for the novelty defense (see lit-review 01).
- **Phase-0 feasibility gate first** (cheap) to retire the Cilium-BWM/EDT integration risk.

---

## 1. Thesis
In Istio Ambient Mesh the shared per-node ztunnel is an uninstrumented compute-contention
point whose CPU saturation — not node CPU, bandwidth, or app code — drives victim
tail-latency amplification that compounds across multi-hop microservice calls. This
saturation is observable in the kernel/cgroup + Tokio runtime and can be controlled
proactively by drop-free EDT pacing of the aggressor in the Cilium eBPF dataplane,
restoring victim tails while preserving fair goodput — including under burst/churn where
reactive autoscaling and static bandwidth limits cannot.

## 2. Positioning & novelty (from lit-review 01 — this is the defensible framing)
NOT novel alone: EDT pacing in Cilium (Bandwidth Manager already does it, statically);
saturation/latency overload control (Breakwater OSDI'20, Aequitas SIGCOMM'22, DAGOR);
CPU-interference co-location control (C-Koordinator, at scheduler layer).
**Novel = the closed loop + signal-to-actuator mapping:** shared ambient-mesh proxy
**(ztunnel primary; waypoint as generalization)** CPU saturation as a first-class
congestion signal, fed back to dynamically modulate per-source EDT departure timestamps in
the Cilium eBPF/TC dataplane, for noisy-neighbor isolation. Framing the signal as
"shared-mesh-proxy saturation" (not "ztunnel CPU") is deliberate: it makes the mechanism
proxy-agnostic, so the waypoint arm (§Phase 5) turns a "why only ztunnel?" objection into a
generality result. Distinctions to state explicitly:
- **pace, not drop** (vs Breakwater/DAGOR admission+drop)
- **signal = proxy compute saturation, not per-RPC latency; enforcement = host-local EDT,
  not fabric WFQ** (vs Aequitas)
- **dynamic closed-loop, not static per-pod bandwidth** (vs Cilium Bandwidth Manager)
- **actuate in the network dataplane, not the CPU scheduler** (vs C-Koordinator)
Secondary contribution: first characterization of DeathStarBench under Istio **Ambient**
(no prior published work found — verify vs latest proceedings before claiming "first").

### 2a. Why ztunnel is primary, waypoint is the generalization (state this in the paper)
Ambient has two proxies with different resource semantics:
- **ztunnel** — per-node DaemonSet, **L4** (mTLS/HBONE/L4-authz/telemetry), Rust/Tokio,
  **shared by ALL pods on the node, always in the path, not isolatable per-tenant.**
- **waypoint** — per-namespace/SA **Deployment**, **L7** (HTTP routing/retry/L7-authz),
  Envoy, **only present if L7 features are opted into**, and **independently scalable (HPA)**.
Rationale for centering ztunnel: (1) it is the genuinely *shared, non-isolatable* resource —
a waypoint tenant can "scale out" of contention, ztunnel tenants cannot, which is precisely
why a pacing (not scaling) mitigation is needed; (2) ztunnel is *always* in the path;
(3) the ICCD ground-truth paper scoped to ztunnel (L4 only). BUT because our signal is
"shared-proxy CPU saturation" (proxy-agnostic), Phase 5 adds a **waypoint (Envoy/L7)
saturation arm** to show the same signal→EDT loop generalizes L4→L7 — converting the
obvious reviewer objection into a strength.

## 3. Research questions
- RQ1 (Characterize). Does DSB-on-Ambient reproduce non-plateauing, multi-hop-compounded
  tail amplification, and is it attributable to ztunnel CPU saturation (not node/NIC/app)?
- RQ2 (Signal). Which ztunnel-observable signal best predicts victim tail at ≤100 ms lead:
  cgroup cpu.stat throttling, Tokio park/busy metrics, run-queue delay, or conn/flow count?
- RQ3 (Mechanism). Does proxy-saturation-driven EDT pacing of the aggressor restore victim
  P99/P99.9 while keeping aggressor goodput proportional-fair and drop-free?
- RQ4 (Differentiation). Does it beat Cilium Bandwidth Manager (static), an admission/drop
  overload controller (Breakwater/Aequitas-style), and VPA/HPA — most under burst/churn?
- RQ5 (Cost). Per-packet TC overhead <1 µs; true no-op below threshold; controller CPU
  negligible; graceful degradation on controller failure; control-loop stability (no oscillation).
- RQ6 (Generality). Does the same proxy-saturation→EDT loop mitigate interference driven by
  **waypoint (Envoy/L7)** CPU saturation, not just ztunnel (L4)? → shows proxy-agnosticism.

## 4. System design (per lit-review 02)
- **Actuator:** extend Cilium's Bandwidth-Manager eBPF datapath (do NOT attach a naive
  parallel TC prog — both own the egress hook + FQ). Program stamps `skb->tstamp`
  (`bpf_skb_set_tstamp`, mono delivery) per source-service; FQ enforces; respect FQ horizon.
- **Signal source:** userspace Go DaemonSet polls ztunnel **cgroup v2 `cpu.stat`
  (usage_usec, nr_throttled, throttled_usec) + Tokio runtime metrics** at 100 ms → BPF map.
  (NOT an "imagined worker queue" — reframed per feasibility review.)
- **Control law:** below LOW threshold → tstamp=0 (passthrough, zero overhead). Above HIGH →
  per-service pacing rate ∝ fair share, hysteresis band to prevent oscillation.
- **Identity:** pod-IP→service via K8s watch → BPF map. Reuse Cilium identity where possible.
- **Waypoint signal note:** waypoint is Envoy (not Tokio) → its saturation signal is Envoy
  worker/cgroup CPU + Envoy admin stats, not Tokio metrics. Same cgroup cpu.stat approach applies.

## 4a. Definitions (pin these before Phase 1 — needed for pass/fail)
- **SLO / success criterion:** victim P99 restored to within **X%** of the no-noise ambient
  baseline (X to set from Phase-1 data; provisional 20%). Report P99 AND P99.9.
- **Fair share:** target = equal share of ztunnel capacity per *meshed source service* by
  default; weighted variant (SLO-class weights) as a sensitivity arm. Aggressor goodput
  target ≥ its fair share.
- **Goodput:** achieved/target RPS with only non-error (2xx / valid) responses counted.
- **Fairness metric:** Jain's fairness index across co-tenant services' achieved-vs-fair-share.
- **Observability stack (required):** Prometheus (metrics) + distributed tracing (Jaeger,
  PINNED digest — DSB's `:latest` is broken) for per-hop latency attribution (multi-hop
  compounding claim) + bpftrace/eBPF harness for sched/cgroup signals. Provision from Phase 1.

## 5. Experimental phases (each = a paper figure/table)

### Phase 0 — Feasibility gate (cheap, ~$1–2, DO FIRST)  ★ retires biggest risk
Small cluster (verified versions §7). Prove GO/NO-GO on:
(a) Istio 1.31 Ambient runs on Cilium 1.20 CNI (`cni.exclusive=false`, bpf.masquerade OFF,
    NetworkPolicy allow 169.254.7.127/32); confirm `uname -r` kernel on the AMI.
(b) a custom/extended eBPF prog sets `skb->tstamp` and FQ honors the delay alongside Cilium
    BWM (microbench: inject known delay → measure applied, no drops).
(c) ztunnel cgroup `cpu.stat` + Tokio runtime metrics readable at 100 ms.
(d) **BBR-for-Pods + ambient** coexistence (BBR wants eBPF host-routing ↔ ambient forbids
    bpf.masquerade) — if conflict, note it; core EDT pacing does NOT need BBR.
(e) DSB SocialNetwork fits the node sizing (deploy once, check headroom).
If (b) is hard, fall back to a standalone-Cilium mechanism testbed with the confound documented.

### Phase 1 — Establish the congestion, from scratch (RQ1)  ★ SELF-CONTAINED PRIMARY RESULT
NOTE: the ICCD paper is UNPUBLISHED → we do NOT cite its numbers as fact. Phase 1 must
**demonstrate the interference ourselves** as the paper's first result. This "show
congestion first" is a prerequisite to earning the right to propose a mitigation.
Deploy DSB SocialNetwork on EKS + Cilium + Ambient (patched Helm, pinned images). Drive
compose-post/home-timeline/user-timeline open-loop (wrk2). Inject co-located aggressor;
sweep noise. Establish:
1. **The effect:** victim tail (P99/P99.9) amplifies with aggressor load while P50 stays
   flat; multi-hop compounding (non-plateau vs the single-hop synthetic case).
2. **The cause is proxy congestion, not node/NIC/app:** report ztunnel cgroup cpu.stat
   (throttling) + Tokio busy/park metrics rising in lockstep with the tail; **isolate the
   node-saturation confound** (oversize node + capped ztunnel CPU + aggressor on separate
   cores; report node CPU%/NIC Gbps at every point; flag node>~70%). Independent negative
   controls: stress node CPU / NIC / app-CPU separately → do NOT reproduce the flat-P50/
   rising-tail signature that proxy saturation does.
N≥5 trials + 95% CI. Deliverable: the motivating figure(s) — this is our evidence the
phenomenon is real, mechanistic, and proxy-driven, standing on its own without ICCD.

### Phase 2 — Signal selection (RQ2)
At each noise step, simultaneously capture cgroup cpu.stat, Tokio park/busy, run-queue delay
(sched tracepoints), conn/flow count, victim P99. Rank by Spearman correlation +
cross-correlation lead-time vs victim P99; require readable/stable at 100 ms; test under
burst. Output: chosen control signal (resolves the paper's CPU-vs-queue framing).

### Phase 3 — Mechanism (RQ3)
Build controller + eBPF pacer (§4). Close the loop on DSB: victim P99/P99.9 restored,
aggressor paced not dropped, no errors, goodput proportional-fair. Test loop stability.

### Phase 4 — Differentiation (RQ4)  ★ the "why us" section
Arms: none / ours / Cilium Bandwidth Manager / admission-drop / VPA. Modes: sustained-ramp,
**burst** (1500 RPS 200ms on/800ms off), **churn** (200 RPS + 75 new TLS conn/s). Show ours
wins most under burst/churn (autoscaler lag; BWM blind to CPU; drop hurts goodput).

### Phase 5 — Generalization (RQ6)
(a) **Waypoint (L7/Envoy) arm** — deploy a waypoint for the victim namespace, saturate
*waypoint* CPU, show (i) it also causes interference and (ii) the same proxy-saturation→EDT
loop mitigates it. Demonstrates the signal/mechanism is proxy-agnostic (L4→L7), answering
"why only ztunnel?". (b) HotelReservation (Go/gRPC) as a second workload → effect +
mitigation aren't language/RPC-specific. Optional: victim-placement (A>B>C) mitigation.

### Phase 6 — Overhead & sensitivity (RQ5)
Per-packet TC latency, controller CPU, no-op proof, LOW/HIGH threshold sweep, fairness-weight
correctness, controller-kill graceful degradation, oscillation/stability.

## 6. Methodology (fixed for all phases; lit-review 03)
Open-loop load (wrk2 `-R`, `-R` divisible by threads); HDR histograms; sweep 30/50/70/90% of
measured saturation; ≥5–10 trials on fresh deploys; median + 95% bootstrap CI; discarded
warmup + ≥60–120 s steady state; deliberate co-location + CPU pinning; load-gen OFF the SUT
node; HPA disabled/documented, replicas fixed, DBs/caches pinned, image digests pinned;
report node CPU%/NIC Gbps alongside latency (confound control); flag/exclude node>~70% points.
Inter-arm comparisons: report **statistical significance** (Mann–Whitney U on P99
distributions), not just CIs. Build the repro kit for **Artifact Evaluation** from day 1
(pinned versions/images, one-command deploy, seeds, raw+processed data retained).

## 7. Hardware & versions (VERIFIED 2026-09-18; single Cilium+ambient cluster, non-burstable)
Version matrix (details + citations in lit-review/04_version_matrix.md):
| Component | Version | Note |
|---|---|---|
| EKS Kubernetes | **1.33** | only version in BOTH Istio-1.31 & Cilium-1.20 support; EKS ext-support→Jul2027 |
| Istio (ambient) | **1.31** | ambient GA since 1.24; supports k8s 1.32–1.36. (**NOT 1.23 — EOL Apr'25**) |
| Cilium | **1.20.2** | current stable; supports k8s 1.33; BandwidthMgr = EDT+FQ | 
| AL2023 kernel | **6.12 AMI** (6.1 OK) | meets EDT≥4.20, bpf_skb_set_tstamp≥5.18, sched tracepoints |

- ⚠️ **Do NOT use k8s 1.31** (outside Istio 1.31 support; not in Cilium 1.20; EKS ext-support
  ends ~Nov 2026 — mid-experiment risk). Both 1.31/1.33 are EKS *extended support* (extra $/hr).
- Ambient-on-Cilium required settings: `cni.exclusive=false`; **`bpf.masquerade=true` NOT
  supported w/ ambient**; if kubeProxyReplacement→`socketLB.hostNamespaceOnly=true`;
  NetworkPolicy allow `169.254.7.127/32`.
- ★ Phase-0 must empirically verify **BBR-for-Pods + ambient** (BBR wants eBPF host-routing
  which pairs with bpf.masquerade, but ambient forbids that). Core EDT pacing does NOT need
  BBR — fall back to plain EDT if they conflict.
- Non-burstable **c6i/m6i** only (t3 burst credits ruin tail reproducibility).
- Topology: Node U (victim + aggressor + shared ztunnel, ztunnel `limits.cpu`≈1–2 cores) ·
  Node L (wrk2 load-gen, off-SUT) · Node D (DSB Mongo/Redis/memcached/Jaeger, Phase 1+).
- Sizing: c6i.2xlarge (8 vCPU) compute nodes; m6i.2xlarge (32 GB) DSB data node (validate
  headroom for ~28 svc + DBs + Jaeger in Phase 0; may need bigger/split).
- HW availability CONFIRMED: c6i.2xlarge/xlarge/large + m6i.2xlarge in all 3 us-east-2 AZs.
- Cost: ~$0.66–1.10/hr active + EKS extended-support premium; scale nodes→0 when idle; delete between gaps.

## 8. Baselines (mandatory, lit-review 01)
none · **Cilium Bandwidth Manager** (static byte-rate EDT) · **admission/drop** (Breakwater/
Aequitas-style) · **VPA/HPA** (reactive). Optional: raise ztunnel CPU limit (capacity-planning arm).

## 9. Threats → defenses
T1 node-saturation confound → oversize node + cap ztunnel + separate cores + report util.
T2 signal circularity → Phase 2 empirical selection.
T3 coordinated omission → open-loop, HDR.
T4 variance → ≥5–10 trials, CI, randomized order.
T5 ztunnel "queue" mis-framing → drive off cgroup cpu.stat + Tokio metrics; state async model.
T6 resolution → 100 ms sampling, not 15 s kubectl top.
T7 EDT not enforced / BWM conflict → Phase-0 microbench; extend BWM datapath.
T8 external validity → DSB + HotelReservation (+ placements/waypoint).
T9 reproducibility → pinned AMI/images/versions, patched-DSB fork documented.
T10 novelty overclaim → reframed claim §2 + head-to-head baselines §8.
T11 **ICCD paper is UNPUBLISHED (not peer-reviewed)** → we cannot cite it as established
    fact. It is trusted internal prior work / motivation only. Therefore the paper must
    **demonstrate the congestion (interference) itself, from scratch, as OUR OWN primary
    result** (Phase 1) before any mitigation — not lean on ICCD numbers. Phase 1 is promoted
    from "confirm ICCD" to "establish the phenomenon" (self-contained, N≥5+CI, confound-controlled).

## 10. Milestones
M0 Phase-0 gate (GO/NO-GO) ........ wk 1
M1 DSB characterization ........... wk 2–3
M2 signal chosen .................. wk 4
M3 pacer closes loop .............. wk 5–7
M4 differentiation (burst/churn) .. wk 8–9
M5 generalization (Hotel) ......... wk 10
M6 overhead + write-up ............ wk 11–14

## 11. Open items to confirm with user
- Mitigation scope (defaulted to full + all baselines) and Phase-0-gate-first (defaulted yes).
- Target venue (drives measurement-vs-systems emphasis): NSDI/OSDI/ATC vs IMC.
- Whether to include the no-mesh "mesh tax" control (leaning: optional appendix; paper is
  about fairness under ambient, and the ICCD paper already quantified mesh tax).
- Manual proceedings sweep (NSDI/SoCC/SIGCOMM 2023–26) to lock the novelty claim.
