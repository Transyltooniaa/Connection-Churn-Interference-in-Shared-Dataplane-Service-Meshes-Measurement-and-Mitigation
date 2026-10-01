# Lit Review 1 — Novelty stress-test (verdict: PARTIALLY DEFENSIBLE, reframe needed)

Method caveat: Google/Scholar/ACM DL/DuckDuckGo were blocked (403/CAPTCHA). Findings
rest on arXiv API, Breakwater OSDI'20 PDF, Cilium docs, Carousel page, SIGCOMM'22 program.
A manual sweep of 2023–2026 NSDI/SoCC/SIGCOMM proceedings still recommended before finalizing.

## Closest prior work
1. **Breakwater** (OSDI'20) — signal: server queueing delay; mech: credit-based admission +
   AQM drop; layer: RPC lib (kernel-bypass). Diff: drop not pace; RPC stack not CNI.
2. **Aequitas** (SIGCOMM'22, Google) — signal: per-RPC latency SLO violation; mech:
   admission + WFQ class downgrade; layer: host net + switch WFQ. Diff: latency not proxy
   CPU; WFQ/admission not EDT; DC fabric not co-located pods.
3. **DAGOR** (SoCC'18, WeChat) — signal: server queuing time + priority; mech: priority
   load-shedding (drop); layer: service framework. Diff: drop not pace; no CPU/EDT/CNI.
4. **Carousel** (SIGCOMM'17, Google) — time-based packet release (timing wheel); the
   ANCESTOR of Linux/eBPF EDT pacing. Diff: it's the *primitive* we reuse; no controller,
   no mesh awareness → proves "EDT pacing" itself is NOT novel.
5. **Cilium Bandwidth Manager** (product) — ★CLOSEST MECHANISM MATCH★: already does
   eBPF-EDT egress pacing in the Cilium TC dataplane, but driven by STATIC per-pod
   bandwidth annotations, no dynamic/CPU signal, no co-location protection.
6. **C-Koordinator** (arXiv 2025) — signal: CPI-based CPU-interference prediction; mech:
   scheduler/resource mgmt (NOT network pacing). Conceptually adjacent signal.
7. **Meshlib** (2026) — in-process L7 policy over Cilium eBPF; about policy placement.
8. **RL service-mesh SLO control** (arXiv:2210.04002) — RL controller on Istio; generic
   actuators, not eBPF-EDT.

## Verdict: PARTIALLY DEFENSIBLE
The claim decomposes into 3 pieces, EACH with prior art:
- "EDT pacing in Cilium" → already in Bandwidth Manager (so "first EDT in Cilium" is FALSE).
- "saturation/latency-driven mesh overload control" → Breakwater/Aequitas/DAGOR.
- "CPU-contention signal for co-location protection" → C-Koordinator (at scheduler layer).
NO prior work does the specific COMBINATION: closed loop from **shared mesh-proxy CPU
saturation** → **dynamic modulation of eBPF-EDT pacing rates in the CNI dataplane** for
**noisy-neighbor isolation in ambient mesh**. Not "already done", but current wording
overclaims and WILL be attacked.

## Defensible reframing (use this)
"First closed-loop controller that treats CPU/saturation of the shared ambient-mesh proxy
(ztunnel) as a first-class congestion signal and feeds it back to dynamically modulate
per-source EDT departure timestamps in the Cilium eBPF/TC dataplane — repurposing an
actuator previously driven only by static bandwidth annotations — to isolate co-located
latency-sensitive services." Contrast: pace-not-drop (vs Breakwater/DAGOR); signal is
proxy compute saturation not per-RPC latency and enforcement is host-local EDT not fabric
WFQ (vs Aequitas); dynamic closed-loop not static per-pod limit (vs Cilium BWM); actuate
in network dataplane not CPU scheduler (vs C-Koordinator).

## MUST-HAVE baselines for review (reviewers will demand)
- vs **Cilium Bandwidth Manager** (static bandwidth pacing) — head to head.
- vs a **Breakwater/Aequitas-style** admission/drop overload controller.
- vs reactive **VPA/HPA autoscaling**.
