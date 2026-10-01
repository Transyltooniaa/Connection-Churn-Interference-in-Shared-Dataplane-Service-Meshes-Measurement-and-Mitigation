# Paper — build instructions

Upload this whole `paper/` folder to Overleaf (or build locally). Self-contained.

## Files
- `paper.tex`   — the paper (standard `article` class; no exotic packages → builds anywhere).
- `figs/*.pdf`  — all figures (vector PDF), generated from the real experiment CSVs.
- `make_figs.py`— regenerates every figure from `../phases/phase*/data/*.csv`.
                  Run with: `/home/ubuntu/anaconda3/bin/python make_figs.py` (needs matplotlib+numpy+scipy).

## Build
```
pdflatex paper.tex   # run twice for cross-references (Table/Figure numbers)
pdflatex paper.tex
```
On Overleaf: just upload the folder and hit Recompile (menu → pdfLaTeX).

## Figure ↔ result map
| Figure | Result | Source data |
|---|---|---|
| fig_two_mechanisms | two aggressors, same symptom / opposite proxy signature | phase1 p1_sweep_20260918_170505 |
| fig_signature | proxy-CPU vs victim P99 scatter (regime separation) | phase1 same |
| fig_detector | busy-rate idle-vs-loaded box (100%-separable) | phase2 p2_hc_20260918_184707 |
| fig_principle | conn-rate cap dose-response (knee) | phase3 principle_* |
| fig_mitigation | closed-loop 13× recovery bars | phase3 repeats_* |
| fig_differentiation | vs Cilium BWM bars | phase4 diff.csv |
| fig_sensitivity | setpoint robustness curve | phase6 setpoint_sweep.csv |

## Submitting to an ACM venue (optional)
Replace the top preamble block (through `\date{}`) with:
```
\documentclass[sigconf,nonacm]{acmart}
\usepackage{graphicx,booktabs,xcolor,amsmath}
\settopmatter{printacmref=false}\pagestyle{plain}
\title{Who Melted My Proxy? ...}
\author{Ajitesh Kumar Singh}\affiliation{\institution{IIIT Bangalore}\country{}}
\author{Shashank Tippanavar}\affiliation{\institution{IIIT Bangalore}\country{}}
```
and replace the `\twocolumn[{ \maketitle \begin{center}...abstract...\end{center} }]`
block with a normal `\begin{abstract}...\end{abstract}` + `\maketitle`.

## Reviewer critique — what's addressed vs. open (2026-09-19)
A top-venue self-review raised 6 issues. Status:
- [WRITING-FIXED] #3 controller-not-in-datapath: paper now explicitly separates the two
  enforcement backends (connection-admission = closed-loop numbers; eBPF = 9ns microbench),
  §setup-ebpf + §mitigation + §diff cost paragraph. No result is over-claimed as end-to-end eBPF.
- [WRITING-FIXED] #5 adversarial robustness: new §"Threat Model and Robustness" — evasion by
  staying-under-threshold (self-limiting: the knee IS where harm begins) + spreading across IPs
  (honest limitation; detection is source-agnostic, fair actuation is future work).
- [WRITING-FIXED] #6 baselines beyond BWM: Related Work now explains how Breakwater/DAGOR adapt
  to this setting (proxy-resident per-connection fair-share) and names it as the top baseline to add.
- [WRITING-PARTIAL] #4 multi-tenant: framed honestly in §threat + §disc as the primary open
  problem; detection generalizes, actuation (fair-share across sources) is future work.
- [NEEDS CLUSTER] #1 statistical power: extend n=3/5 → n≥10 + bootstrap CIs. ~$ + a few hrs.
- [NEEDS CLUSTER] #2 generality: L7 waypoint arm (needs HTTP/gRPC victim, see phase5 notes) +
  a 2nd workload (Hotel needs chart-bug fix) + optionally Cilium service-mesh mode.
See ../SETUP_RECOVERY.md to bring the cluster back for the two empirical items.

## Other pre-submission TODO
- Add proper \bibliography (Breakwater OSDI'20, DAGOR SoCC'18, Aequitas SIGCOMM'22,
  Carousel SIGCOMM'17, Cilium docs, DeathStarBench ASPLOS'19) — Related Work is prose now.
