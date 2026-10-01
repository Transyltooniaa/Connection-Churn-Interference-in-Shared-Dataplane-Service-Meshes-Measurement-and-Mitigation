# Literature Review — Executive Summary (2026-09-18)

Three parallel research passes. Full detail in 01_novelty / 02_feasibility /
03_benchmark_methodology. Web search engines were blocked this session (Scholar/ACM/DDG
403/429); findings rest on arXiv, primary PDFs, official docs, GitHub. A manual sweep of
2023–2026 NSDI/SoCC/SIGCOMM proceedings is still recommended before finalizing claims.

## Three headline verdicts

### 1. Novelty: PARTIALLY DEFENSIBLE — must reframe
- "EDT pacing in Cilium" is NOT novel — **Cilium Bandwidth Manager already does it** (static
  per-pod bandwidth annotations). Saturation-driven overload control also exists
  (Breakwater OSDI'20, Aequitas SIGCOMM'22, DAGOR SoCC'18 — all drop/admission/WFQ).
  CPU-interference-for-co-location exists at the scheduler layer (C-Koordinator 2025).
- The **combination is novel**: closed loop from *shared mesh-proxy (ztunnel) CPU
  saturation* → *dynamic modulation of eBPF-EDT pacing rates in the CNI dataplane* → for
  *noisy-neighbor isolation in ambient mesh*. No prior work ties proxy-CPU to a
  network-pacing actuator.
- **Reframed claim** (defensible): "first closed-loop controller treating shared
  ambient-mesh proxy CPU saturation as a congestion signal that dynamically modulates
  per-source EDT departure times in the Cilium eBPF dataplane — pace-not-drop, host-local,
  no app/sidecar change." MUST include head-to-head baselines: Cilium BWM (static),
  Breakwater/Aequitas-style admission/drop, VPA/HPA.

### 2. Feasibility: NO HARD SHOWSTOPPER
- Custom TC eBPF setting `skb->tstamp` + FQ enforcement is a first-class kernel mechanism
  (`bpf_skb_set_tstamp`, Linux ≥5.18). **Kernel 6.1 (AL2023/EKS) suffices — 6.8 NOT needed.**
- Istio Ambient on Cilium is officially supported, with caveats to handle in a Phase-0 gate:
  `cni.exclusive=false`, use iptables masq (BPF masq breaks ambient health checks),
  NetworkPolicy `169.254.7.127/32` allow.
- Integration risk (medium): our BPF must **extend Cilium's Bandwidth-Manager datapath**,
  not attach a naive parallel program (both own the TC egress hook + FQ). Prototype early.
- ztunnel is **Tokio async (~2 worker threads), not a fixed inspectable queue** → drive the
  controller off **cgroup v2 `cpu.stat` (throttling) + Tokio park metrics**, and REFRAME the
  paper's "worker queue" language.

### 3. Benchmark + methodology: DSB SocialNetwork primary
- **DeathStarBench SocialNetwork** = most reviewer-accepted, real multi-hop fan-out, ships
  Helm + wrk2 (open-loop, HDR). HotelReservation (Go/gRPC) as a 2nd point to show
  language-independence. Optional: Online Boutique (Istio-blessed gRPC) or muBench
  (controlled fan-out/depth sweeps for the mechanism section). Avoid Sock Shop (archived).
- Methodology reviewers expect: open-loop load, sweep % of saturation, ≥5–10 trials +95%CI,
  discarded warmup, deliberate co-location + CPU pinning, and CRITICALLY **isolate the
  node-saturation confound** (report utilization alongside latency; antagonist on separate
  cores so node has headroom but shared proxy is the bottleneck).
- DSB Helm charts are dated — budget time to patch (Consul shutdown, command paths, pin
  `:latest`→digests, wrk2 `-R` divisible by threads). No published DSB-on-Ambient paper found.

## Net effect on the plan
- Motivation is already proven by the ICCD paper (ground truth) → new work = MITIGATION.
- Single Cilium+ambient cluster, kernel 6.1 OK, non-burstable nodes.
- The paper's spine: (i) confirm DSB amplification on our stack, (ii) build the closed-loop
  proxy-CPU→EDT pacer extending Cilium BWM, (iii) beat BWM/admission-drop/VPA baselines,
  especially on burst/churn + multi-hop non-plateau.
