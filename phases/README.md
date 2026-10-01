# Phase execution + results-checkpoint protocol

**Rule (user, 2026-09-18):** after each phase that PRODUCES RESULTS, we deep-dive the
numbers to find interesting findings and store them in that phase's `RESULTS.md`. Phases
that only GATE / build (no analyzable numbers of their own) get a short `STATUS.md` instead —
no forced analysis. We do a results deep-dive ONLY when the phase has numbers to produce.

**Two standing requirements for ALL phases → see `DATA_AND_STATS_STANDARD.md`:**
- **Capture everything, keep everything** (CPU + all microservice stats + node + traces +
  provenance) even if unused in the paper — bankable for later. Raw kept forever per RUN_ID.
- **Statistical rigor** — ≥5 trials, randomized order, report mean/std/variance/CV%/95% CI,
  Mann–Whitney between arms. No bare point estimates; prove reproducibility.

## Workflow per phase
1. Run the phase experiments (per RESEARCH_PLAN.md), ≥5 trials, randomized order.
2. Capture the FULL data manifest (DATA_AND_STATS_STANDARD §A) + provenance into
   `phases/phaseN/data/<RUN_ID>/` — the complete set, not just what the RESULTS.md discusses.
3. If result-producing → write `phases/phaseN/RESULTS.md` (template below, incl. mandatory
   Statistical-rigor subsection). Then PAUSE for user review before proceeding.
4. If gate/build only → write `phases/phaseN/STATUS.md`: GO/NO-GO + what was built. Proceed.

## Phase classification
| Phase | Type | Produces analyzable numbers? | Checkpoint artifact |
|---|---|---|---|
| P0 Feasibility gate | GATE | No (pass/fail + microbench sanity) | STATUS.md (GO/NO-GO) |
| P1 Establish congestion on DSB | **RESULTS** | **Yes** — victim P50/P99/P99.9 vs noise, ztunnel CPU, per-hop | **RESULTS.md → review** |
| P2 Signal selection | **RESULTS** | **Yes** — signal↔tail correlation + lead-time ranking | **RESULTS.md → review** |
| P3 Mechanism (pacer closes loop) | **RESULTS** | **Yes** — victim tail restored, goodput, stability | **RESULTS.md → review** |
| P4 Differentiation (vs baselines) | **RESULTS** | **Yes** — arm×mode P99/goodput + significance | **RESULTS.md → review** |
| P5 Generalization (waypoint, Hotel) | **RESULTS** | **Yes** — does effect+fix generalize | **RESULTS.md → review** |
| P6 Overhead & sensitivity | **RESULTS** | **Yes** — per-pkt latency, threshold sweep, degrade | **RESULTS.md → review** |

Only P0 is a pure gate (STATUS.md, no deep-dive). P1–P6 each end in a RESULTS.md +
review pause. Build/prototype work inside P3 is not separately checkpointed — its numbers
are the P3 results.

## RESULTS.md template (each result phase)
```
# Phase N Results — <title>   (RUN_ID, date)
## Headline numbers        <key table/plot, WITH mean±std/CI — no bare points>
## Statistical rigor       <n, trial order, mean/std/variance/CV%, 95% CI (bootstrap for
                            percentiles), significance test (Mann–Whitney) + effect size>
## Interesting / surprising <what stands out, expected vs actual>
## Mechanism check         <does the causal story hold? confounds clean?>
## Extras banked           <what else we captured (CPU, other svc, traces...) for later use>
## Caveats                 <saturation flags, high-CV cells, what's not covered>
## Decision                <proceed? adjust next phase? new question raised?>
## Data                    <paths to raw + processed under phaseN/data/<RUN_ID>/>
```
