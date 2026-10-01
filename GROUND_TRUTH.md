# Prior-work reference — the (UNPUBLISHED) ICCD-style paper

Source: `SSP_Service_Mesh_Project_Shashank_Ajitesh.pdf` ("Performance Evaluation of Istio
Ambient Mesh in Kubernetes", Ajitesh Kumar Singh & Shashank Tippanavar, IIIT Bangalore).

**Status (user, 2026-09-18): this paper is NOT peer-reviewed / not published.** The results
are trusted as *internal prior work and motivation*, but they CANNOT be cited as established
fact in the new paper. Consequence for the plan:
- We do NOT re-run the *synthetic* svc-a/svc-b Exp 1/2/3 (that ground is covered enough for
  motivation).
- We DO re-demonstrate the interference **ourselves, from scratch, on a standard microservice
  benchmark**, as the new paper's first primary result ("show congestion first", Phase 1) —
  before proposing any mitigation. The numbers below are the *expected shape* to reproduce,
  not citable facts.

## Testbed used in the paper (their environment)
- GCP, Kubernetes v1.29.15, Ubuntu 22.04.5, kernel 6.8.0 (GCP), containerd 2.2.2
- CNI: **Flannel (VXLAN overlay)**. Service mesh: **Istio Ambient**.
- Nodes: control plane 4 vCPU/16GB; 2× worker 2 vCPU/8GB.
- Load: wrk2 + Fortio, open-loop; DSB driven by wrk2 open-loop Poisson.

## Key established results (ground truth)
1. **Mesh tax:** Istio Ambient adds **8–22%** tail-latency overhead under normal load
   (P50 ~8–10%, P99 ~12–15%, P99.99 ~15–22%), consistent across read/write endpoints.
   Throughput dropped ~9800→~5400 RPS (45%) with mesh on; avg latency 10.8→18.9 ms.
2. **Synthetic noisy neighbor (svc-a victim @500 QPS, svc-b swept 500–4000):**
   victim P99 amplifies to **~2.4× around 2000 QPS then PLATEAUS** (ztunnel saturation);
   P90/P50 stay flat → tail-only. Beyond saturation, svc-b efficiency collapses (~47% at
   4000 QPS) which partially relieves the victim. (Table V: victim P99 170→246→381→331 ms
   at svc-b 0/1000/2000/4000.)
3. **DSB Social Network (12+ services, multi-hop):** noisy neighbor effect is
   **non-linear and does NOT plateau** — multi-hop requests accumulate ztunnel queue delay
   at every hop. **home-timeline P99 = 5.67× ambient baseline at 700 RPS noise** (vs mesh
   tax 14.6%). Table VI medians: compose-post 894→3560ms (3.98×), home-timeline 755→4280ms
   (5.67×), user-timeline 638→1270ms (1.99×). P50 stays flat throughout.
4. **Victim ordering A>B>C:** amplification depends on how many endpoints/fan-outs route
   through the co-located victim service (social-graph > user > media). Negative control:
   user-timeline in Case A (doesn't traverse social-graph) stays <2.1×.
5. **Interference SHAPE matters (Case A, compose-post):** at equal ~300–400 RPS mean,
   **burst (1500 RPS/200ms on, 800ms off) ≈1.8× worse P99.99 than sustained; churn
   (200 RPS + 75 new TLS conn/s) causes similar damage at low RPS.** →
   **ztunnel CPU-time, not request count, drives tail amplification.**
6. **Root cause:** ztunnel worker-queue buildup; ztunnel CPU hits **636 millicores
   (63.6% of one vCPU)** at peak — much higher than app CPU. Not app/network/kernel.

## What this means for the proposal
- The MOTIVATION is already proven (their data). New paper does not need to re-establish
  "interference exists." It needs: (a) reproduce/confirm the DSB amplification on our
  testbed as the setting, (b) build a mitigation, (c) show it works — especially on the
  burst/churn cases and the multi-hop non-plateau that autoscaling can't handle.
- The paper's OWN conclusion — "ztunnel CPU usage can act as an early warning for
  tail-latency issues" and "CPU-time not RPS drives the tail" — is the empirical support
  for a CPU/saturation-driven pacing signal. (Nuance: aggregate cgroup CPU vs per-worker
  occupancy still to be validated, but the paper leans CPU-time.)

## Deltas from paper testbed we will make (and must justify)
- Cloud: GCP→AWS EKS (managed control plane, reproducible). CNI: Flannel→**Cilium**
  (needed for EDT/FQ mitigation + Bandwidth-Manager comparison). These are deliberate and
  documented; baseline+treatment run on the SAME stack so the mitigation delta is clean.
