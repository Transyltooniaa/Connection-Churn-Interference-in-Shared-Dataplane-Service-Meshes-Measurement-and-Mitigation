# Verified Version Matrix (2026-09-18, official sources)

## CRITICAL: pin k8s 1.33 (NOT 1.31). Istio 1.31 (NOT 1.23). Cilium 1.20.

## FINAL RECOMMENDED SET
| Component | Version | Why | Citation |
|---|---|---|---|
| EKS Kubernetes | **1.33** | Only candidate in BOTH Istio 1.31 supported range AND Cilium 1.20 tested range; EKS extended support → Jul 29 2027 | eks kubernetes-versions; istio supported-releases |
| Istio (ambient) | **1.31** | Current stable; ambient GA since 1.24; supports k8s 1.32–1.36 | istio supported-releases; announcing-1.24 |
| Cilium | **1.20.2** | Current stable; guarantees k8s 1.33; Bandwidth Mgr = EDT+FQ, enables BBR | cilium releases; requirements; bandwidth-manager |
| AL2023 kernel | **6.12 kernel AMI** (6.1 also OK) | meets EDT≥4.20, bpf_skb_set_tstamp≥5.18, sched tracepoints | eks/al2023; al2023 relnotes |

## EOL / incompatibility flags (why NOT the old pins)
- **k8s 1.31 = BAD choice:** outside Istio 1.31 supported range (only "tested, not
  supported"); NOT supported by Cilium 1.20 (needs ≥1.33); EKS extended support expires
  **Nov 26 2026** (~2 months → mid-experiment risk). Picking it forces downgrading Istio
  AND Cilium to older/partly-EOL lines.
- **Istio 1.23.0 (the ICCD paper's version) = EOL since Apr 16 2025.** Do not use.
- Both 1.31 & 1.33 are in EKS **extended support** (extra per-cluster-hour cost); 1.33 = longest runway.

## Istio ambient-on-Cilium required settings (verified, Cilium 1.20 + Istio 1.31)
- `cni.exclusive=false` (else Cilium deletes Istio CNI config).
- **`bpf.masquerade=true` NOT supported with ambient** — breaks ambient pod health checks.
  Leave BPF masquerade OFF (use kube-proxy or iptables masq path).
- If full kube-proxy replacement (`kubeProxyReplacement=true`): set
  `socketLB.hostNamespaceOnly=true`. Lower-disruption path = keep kube-proxy.
- default-deny NetworkPolicy → allow link-local probe src **169.254.7.127/32** via
  CiliumClusterwideNetworkPolicy.
- Ambient mTLS tunnels over port 15008 → Cilium sees only L4 there; don't double up L7.

## ★ ONE THING TO VERIFY EMPIRICALLY (Phase 0 gate)
Cilium **BBR-for-Pods needs eBPF host-routing** (normally paired with `bpf.masquerade`),
but **ambient forbids `bpf.masquerade=true`**. → Test the **BBR + ambient +
cni.exclusive=false** combination on a canary node before locking the design. Our core EDT
pacing (skb->tstamp + FQ) does NOT require BBR, so if BBR+ambient conflicts we can still
pace via plain EDT — but confirm in Phase 0.

## To confirm on the node (not in docs)
- Exact AL2023 kernel patch string → `uname -r` on the chosen AMI (6.1/6.12/6.18 lines
  documented; exact patch not in release notes).
