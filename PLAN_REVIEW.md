# Plan Review — gaps found (2026-09-18), to resolve before spinning cluster

## A. Hardware — VERIFIED (AWS live checks)
- EKS us-east-2 supports k8s **1.31–1.36** (1.29 gone; don't pin it).
- **c6i.2xlarge, c6i.xlarge, c6i.large, m6i.2xlarge** all offered in all 3 AZs (us-east-2a/b/c). ✅
- AL2023 EKS AMIs current (v20260917) for 1.31 (1.31.14) and 1.33 (1.33.13), containerd 2.x. ✅
- **Kernel version NOT exposed in AMI metadata** — needs live confirm (was 6.1.182 on 2026-09-15;
  AL2023 now has a 6.12 stream that may be default). Pending version-research agent. ⏳

## B. Internal inconsistency (MUST FIX)
- Plan §7 line pins **"Istio 1.23 ambient"** but ambient went **GA in 1.24**, and 1.23 is
  likely EOL. Self-contradictory. Fix Istio version after version-agent confirms.

## C. Undefined experimental variables (needed before Phase 1 can run)
1. **Aggressor definition on DSB** — USER DECISION (2026-09-18): NO separate synthetic
   http-server/intercept experiment. Everything shown on DSB only. The synthetic Exp1/2/3 is
   dropped as a phase (ICCD covered it as motivation). Note: "intercept" needs no code —
   ambient ztunnel intercepts pod traffic transparently. Remaining choice = what creates the
   noise co-located on the victim's ztunnel: (a) **DSB-internal aggressor** (hammer a DSB
   endpoint / 2nd heavy DSB tenant) — purest "all DSB" story, RECOMMENDED headline; (b) a
   generic load pod purely as a noise source (what ICCD Exp6 did) — useful for controllable
   burst/churn shapes. All *measured* results are DSB victim latency either way. Lean: (a)
   headline + (b) as the controllable-noise knob for burst/churn.
2. **Success criterion / SLO** — "restore victim tail" needs a target, e.g. "victim P99
   within X% of no-noise baseline" and "aggressor goodput ≥ Y% of fair share". Without it
   Phase 3/4 have no pass/fail.
3. **"Fair share" definition** — of what, among whom? (equal per-service? SLO-weighted?).
   The control law depends on it. Define concretely.
4. **Goodput + proportional-fairness metrics** — define exactly (achieved/target RPS;
   Jain's fairness index across services?).

## D. Missing infrastructure (add to plan)
5. **Observability stack** — per-hop latency attribution (the multi-hop compounding claim)
   needs distributed tracing (Jaeger); signal capture needs Prometheus + the eBPF/bpftrace
   harness. DSB ships Jaeger but it's flagged broken on `:latest` (lit-review 03). Must pin +
   fix. Not currently in the plan.
6. **DSB sizing** — SocialNetwork ~28 svc + Mongo/Redis/memcached/Jaeger on ONE m6i.2xlarge
   (8vCPU/32GB) data node may be tight. Validate headroom in Phase 0; may need bigger data
   node or split DBs.

## E. A*-grade nice-to-haves
7. **Artifact Evaluation** — design repro kit for AE from day 1 (top venues expect it).
8. **Inter-arm statistical significance** — not just CIs; e.g. Mann-Whitney U on P99
   distributions between arms in Phase 4.
9. **Sensitivity to co-location degree** — 1 aggressor vs N; how many victims per node.

## F. Open framing items (already in plan §11)
- Mitigation scope (default full+all baselines), Phase-0-first (default yes).
- Target venue (NSDI/OSDI/ATC vs IMC).
- No-mesh control (lean: optional appendix).
- Manual proceedings sweep to lock novelty "first" claim.

## Resolution status
- A/B: pending version agent (then fix §7 + pin the matrix).
- C1–C4, D5–D6: propose defaults, confirm with user, then bake into plan.
- E7–E9: fold into plan as explicit sub-items.
