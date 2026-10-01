# Lit Review 2 — Technical feasibility (verdict: NO HARD SHOWSTOPPER)

## 1. Cilium Bandwidth Manager / EDT — YES, mechanism is exactly what we assume
- Cilium BWM already does eBPF **EDT egress pacing**: reads `kubernetes.io/egress-bandwidth`
  per-pod annotation → BPF stamps departure time → **FQ qdisc on the physical device** enforces.
- A custom TC eBPF program CAN set `skb->tstamp` and have FQ honor it — first-class kernel
  mechanism: helper **`bpf_skb_set_tstamp()`** (`BPF_SKB_TSTAMP_DELIVERY_MONO`), shipped
  **Linux 5.18**. FQ uses it as time_to_send; FQ `horizon` caps how far you can delay
  (paced-not-dropped has a ceiling before FQ drops). EDT model: Van Jacobson / Dumazet,
  kernel ≥4.20 (tc-fq man page, LWN 766564).
- ★ **Integration risk (medium):** Cilium BWM attaches ITS OWN BPF prog to the same TC
  egress hook + owns FQ. Our program must **extend Cilium's datapath**, not attach a naive
  parallel program that clobbers the timestamp. Prototype this early.

## 2. Istio Ambient on Cilium — YES, officially documented, with named caveats
Istio ambient platform-prereqs page covers Cilium. Required/known:
- `cni.exclusive=false` (else Cilium deletes istio-cni config).
- **BPF masquerade breaks ambient health checks** (link-local IPs) → use **iptables masq**.
- default-DENY NetworkPolicy blocks kubelet probes → allow `169.254.7.127/32` via
  CiliumClusterwideNetworkPolicy.
- Extra config if Cilium replaces kube-proxy.
- No showstopper, but these live in the SAME eBPF/tc territory as our work → Phase-0 gate.

## 3. ztunnel internals — Tokio async, NOT a classic fixed worker queue
- ztunnel = Rust + Tokio, **dual runtime**: 1-thread admin runtime + **multi-thread worker
  runtime, default 2 threads, configurable**. Traffic = async tasks on work-stealing runtime,
  NOT thread-per-conn, NOT an inspectable bounded queue. → The ICCD paper's "fixed worker
  thread pool / worker queue" framing is only loosely accurate; REFRAME for our paper.
- **Observe saturation via:** (best) Tokio runtime metrics ztunnel already exports
  (`tokio_num_workers`, `tokio_worker_park_count`); cgroup v2 **`cpu.stat`**
  (`usage_usec`, `nr_throttled`, `throttled_usec`); `/proc/<pid>/schedstat`; sched
  tracepoints. → Drive controller off **cgroup cpu.stat throttling + Tokio park metrics**,
  not an imagined queue depth. With only ~2 worker threads, CPU saturation is real & observable.

## 4. Kernel requirement — 6.1 (AL2023/EKS) is SUFFICIENT; 6.8 NOT required
- EDT+FQ: Linux ≥4.20. `bpf_skb_set_tstamp`: ≥5.18 (the one hard floor). BBR-for-pods: ≥5.18.
  sched tracepoints/kprobes/bpftrace: 4.x. → **6.1 clears everything.** The ICCD README's
  "kernel ≥6.8 required" claim appears UNSUPPORTED.

## Showstoppers / risk summary
- No hard showstopper.
- Integration (medium): coexist with / extend Cilium BWM BPF + FQ ownership.
- Ambient-on-Cilium (medium): BPF-masq + NetworkPolicy caveats.
- Conceptual (low): ztunnel has no inspectable fixed queue → use cgroup cpu.stat + Tokio metrics.
- Unverified sources: Brakmo LPC-2018 PDF, Cilium's own Istio doc page (404) — mechanism
  independently confirmed via LWN + tc-fq(8).
