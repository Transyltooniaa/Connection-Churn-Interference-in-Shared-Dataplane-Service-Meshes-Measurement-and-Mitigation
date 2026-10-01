# Data-capture & statistical-rigor standard (MANDATORY for every result phase)

User directives (2026-09-18):
1. **Log everything, keep everything.** Capture CPU stats + ALL microservice stats + extras
   even if not used in the paper — so we can always come back and add them later. Nothing is
   thrown away; raw data is retained per RUN_ID and never overwritten.
2. **Results must be STRONG.** Prove reproducibility with statistical rigour: std, variance,
   CV, confidence intervals — not point estimates. A number without a spread is not a result.

---

## A. Capture-everything manifest (every run writes ALL of these into phaseN/data/<RUN_ID>/)

### Latency / load (per endpoint, per arm, per trial)
- Full HDR histogram (not just percentiles) — enables recomputing any percentile later.
- P50/P90/P99/P99.9/P99.99, mean, max, achieved vs target RPS, error counts by code.
- Raw wrk2/Fortio JSON + the exact command line + seed/rate/threads/duration.

### Proxy (ztunnel AND waypoint when present)
- cgroup v2: `cpu.stat` (usage_usec, user_usec, system_usec, nr_periods, nr_throttled,
  throttled_usec), `memory.current`, `memory.stat`, `io.stat`, `pids.current`.
- Tokio runtime metrics (ztunnel) / Envoy admin stats (waypoint): workers, park count,
  busy ratio, queue/backlog, active conns, task counts.
- ztunnel/waypoint version + image digest.

### EVERY microservice (not just victim) — the "extras" the user wants
- Per-pod CPU (millicores), memory, restarts, throttling, QoS class, node placement.
- Per-service request rate, latency, error rate (Prometheus).
- DB/cache stats: Mongo/Redis/memcached ops, hit/miss, connections, evictions.
- Distributed traces (Jaeger) — per-hop spans for fan-out attribution.
- Queue depths / conntrack counts where available.

### Node / system (every node, sampled ≥ every 5–10s, timestamped)
- Node CPU% (per-core), mem, NIC RX/TX Gbps + pps, retransmits, softirq, run-queue len,
  load avg, context switches. Idle/control node captured too (proves locality).

### Provenance (once per run)
- All versions (k8s, Istio, Cilium, kernel `uname -r`, AMI id, containerd, wrk2, controller).
- Full as-applied manifests, Helm values, Cilium config, ztunnel/waypoint CPU limits.
- Cluster topology, node instance types/AZs, image digests, git SHA of our code.
- Timestamps for every phase/step; RUN_ID; random seeds.

Storage: `phases/phaseN/data/<RUN_ID>/{latency,proxy,services,node,traces,provenance}/`.
Raw kept forever; a `manifest.json` lists what was captured. Compress but never delete.

## B. Statistical-rigor protocol (the bar for "strong results")

- **Replication:** ≥5 independent trials per cell (target 10 for headline numbers), on FRESH
  deploys where feasible; **randomize load-level / arm order** across trials (break
  time/thermal/ordering confounds).
- **Report for every metric:** mean, **std, variance, CV%**, median, IQR, and **95% CI**
  (bootstrap for percentiles — percentile CIs are NOT normal). Never a bare point estimate.
- **Reproducibility evidence:** show run-to-run CV%; low CV = reproducible, high CV is itself
  a finding (e.g. peak-contention variance, as ICCD saw). Report n explicitly everywhere.
- **Inter-arm comparison (P4 etc.):** non-parametric **Mann–Whitney U** on P99 distributions
  (latency isn't normal); report effect size + p-value; correct for multiple comparisons
  (Holm/Bonferroni) across endpoints×modes.
- **Correlation/lead-time (P2):** Spearman (not Pearson) + cross-correlation lag with CI.
- **Outliers/warmup:** define + discard warmup window explicitly; document any exclusion rule
  (e.g. node>~70% points) — never silently drop.
- **Plots:** show the spread (CI bands / box / violin / CCDF), not just a mean line.

## C. How this shows up per phase
Every RESULTS.md must include an explicit **"Statistical rigor"** subsection: n, trial order,
mean±std (CV%), 95% CI, and the significance test used. Every run must produce the full §A
capture even if the RESULTS.md only discusses a subset — the rest is banked for later.
