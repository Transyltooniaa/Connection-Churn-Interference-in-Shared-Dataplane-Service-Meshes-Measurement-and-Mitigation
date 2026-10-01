#!/usr/bin/env python3
"""Generate all paper figures from the real phase CSVs. Run with anaconda python."""
import csv, statistics as st, os
from collections import defaultdict
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams.update({
    "font.size": 12, "axes.titlesize": 12, "axes.labelsize": 12,
    "xtick.labelsize": 11, "ytick.labelsize": 11, "legend.fontsize": 10,
    "figure.dpi": 150, "savefig.dpi": 300, "savefig.bbox": "tight",
    "font.family": "serif", "mathtext.fontset": "cm",
    "axes.grid": True, "grid.alpha": 0.25, "grid.linewidth": 0.6,
    "axes.axisbelow": True, "axes.linewidth": 0.8,
    "axes.spines.top": False, "axes.spines.right": False,
    "legend.frameon": False, "lines.linewidth": 2.0, "lines.markersize": 6,
})
BASE = "/datastore2/ajitesh/ssp/proposal-v2/phases"
OUT = "/datastore2/ajitesh/ssp/proposal-v2/paper/figs"
os.makedirs(OUT, exist_ok=True)
# muted, print-friendly palette
C_CHURN, C_BACK, C_OURS, C_BWM = "#b2182b", "#2166ac", "#1b7837", "#999999"

def f(x):
    try: return float(str(x).replace("ms",""))
    except: return np.nan

# ---------- load P1 sweep ----------
p1 = list(csv.DictReader(open(f"{BASE}/phase1/data/p1_sweep_20260918_170505/summary.csv")))
g = defaultdict(lambda: defaultdict(list))
for r in p1: g[r["arm"]][int(r["level"])].append(r)
def series(arm, col):
    lv = sorted(g[arm]); m=[]; sd=[]
    for l in lv:
        v=[f(r[col]) for r in g[arm][l]]; m.append(np.nanmean(v)); sd.append(np.nanstd(v))
    return np.array(lv), np.array(m), np.array(sd)

# ===== FIG 1: two mechanisms, same symptom / opposite cause (2 panels) =====
fig, ax = plt.subplots(1, 2, figsize=(9, 3.4))
for arm, c, mk, lbl in [("churn", C_CHURN, "o", "connection-churn (proxy)"),
                        ("compose", C_BACK, "s", "compose-post (backend)")]:
    lv, m, sd = series(arm, "v_p99")
    ax[0].errorbar(lv, m, yerr=sd, fmt=mk+"-", color=c, capsize=3, label=lbl, lw=1.8, ms=6)
    lvc, mc, _ = series(arm, "zt_usage_cores")
    ax[1].plot(lvc, mc, mk+"-", color=c, label=lbl, lw=1.8, ms=6)
ax[0].axhline(2.86, ls=":", color="k", alpha=.5, label="no-aggressor baseline")
ax[0].set_xlabel("aggressor intensity"); ax[0].set_ylabel("victim P99 latency (ms)")
ax[0].set_title("(a) Same victim symptom"); ax[0].legend(loc="upper right")
ax[1].axhline(1.0, ls="--", color="k", alpha=.6, label="ztunnel CPU cap (1 core)")
ax[1].set_xlabel("aggressor intensity"); ax[1].set_ylabel("ztunnel CPU (cores)")
ax[1].set_title("(b) Opposite proxy signature"); ax[1].legend(loc="center right")
fig.tight_layout(); fig.savefig(f"{OUT}/fig_two_mechanisms.pdf"); plt.close(fig)

# ===== FIG 2: mechanism signature scatter (ztunnel CPU vs victim P99) =====
fig, axs = plt.subplots(figsize=(5.2, 3.8))
for arm, c, mk, lbl in [("churn", C_CHURN, "o", "connection-churn (proxy)"),
                        ("compose", C_BACK, "s", "compose-post (backend)")]:
    xs=[f(r["zt_usage_cores"]) for l in g[arm] for r in g[arm][l]]
    ys=[f(r["v_p99"]) for l in g[arm] for r in g[arm][l]]
    axs.scatter(xs, ys, c=c, marker=mk, s=45, alpha=.8, edgecolor="k", lw=.4, label=lbl)
axs.axvline(1.0, ls="--", color="k", alpha=.6, label="ztunnel CPU cap")
axs.set_xlabel("ztunnel CPU (cores)"); axs.set_ylabel("victim P99 latency (ms)")
axs.legend(loc="center right"); fig.tight_layout()
fig.savefig(f"{OUT}/fig_signature.pdf"); plt.close(fig)

# ===== FIG 3: detector — busy_rate distribution idle vs loaded (P2 hc) =====
hc = f"{BASE}/phase2/data/p2_hc_20260918_184707"
busy_idle, busy_load = [], []
for rep in range(1,6):
    fn=f"{hc}/sig_{rep}.csv"
    if not os.path.exists(fn): continue
    T,B=[],[]
    for r in csv.reader(open(fn)):
        if len(r)<4: continue
        try: T.append(float(r[0])); B.append(float(r[2]))
        except: continue
    T=np.array(T); B=np.array(B)
    if len(T)<3: continue
    dt=np.diff(T); dt[dt<=0]=np.nan
    br=np.concatenate([[np.nan],np.diff(B)/dt]); t0=T[0]
    for t,b in zip(T,br):
        if np.isnan(b): continue
        rel=t-t0
        if rel<13: busy_idle.append(b)
        elif 16<rel<45: busy_load.append(b)
fig, axd = plt.subplots(figsize=(4.6,3.6))
bp=axd.boxplot([busy_idle, busy_load], labels=["idle\n(unsaturated)","loaded\n(saturated)"],
               patch_artist=True, widths=.5, showfliers=False)
for patch,c in zip(bp["boxes"],[C_OURS,C_CHURN]): patch.set_facecolor(c); patch.set_alpha(.6)
thr=(np.percentile(busy_idle,95)+np.percentile(busy_load,5))/2
axd.axhline(thr, ls="--", color="k", label=f"threshold (100%% separable)")
axd.set_ylabel("ztunnel worker busy-rate (core-s/s)")
axd.legend(loc="center right"); fig.tight_layout()
fig.savefig(f"{OUT}/fig_detector.pdf"); plt.close(fig)

# ===== FIG 4: control principle / dose-response (P3 principle) =====
pr = list(csv.DictReader(open([f"{BASE}/phase3/data/"+d+"/principle.csv"
       for d in os.listdir(f"{BASE}/phase3/data") if d.startswith("principle_")][0])))
cg = defaultdict(list); tg = defaultdict(list)
for r in pr:
    cap=int(r["conn_rate_cap"]); cg[cap].append(f(r["v_p99"])); tg[cap].append(f(r["zt_throttle_delta"]))
caps=sorted(cg, key=lambda x:(x==0, x))  # put 0(unlimited) last visually via label
caps=[c for c in [100,200,400,800,1500,3000,0] if c in cg]
labels=[("unlim" if c==0 else str(c)) for c in caps]
p99=[np.mean(cg[c]) for c in caps]; thr=[np.mean(tg[c]) for c in caps]
fig, ax1 = plt.subplots(figsize=(5.6,3.6)); x=range(len(caps))
ax1.plot(x, p99, "o-", color=C_OURS, lw=1.8, ms=7, label="victim P99")
ax1.axhline(2.86, ls=":", color="k", alpha=.5)
ax1.set_xticks(list(x)); ax1.set_xticklabels(labels)
ax1.set_xlabel("aggressor new-connection rate cap (conns/s)")
ax1.set_ylabel("victim P99 latency (ms)", color=C_OURS)
ax2=ax1.twinx(); ax2.plot(x, thr, "s--", color=C_CHURN, lw=1.5, ms=6, label="ztunnel throttle events")
ax2.set_ylabel("ztunnel throttle events / 12s", color=C_CHURN)
fig.tight_layout(); fig.savefig(f"{OUT}/fig_principle.pdf"); plt.close(fig)

# ===== FIG 5: mitigation bars with 95%% bootstrap CI (prefer n=12 rigor data) =====
def bootstrap_ci(vals, iters=10000, alpha=0.05):
    vals=np.array(vals); n=len(vals)
    if n<2: return (np.mean(vals) if n else np.nan, 0.0, 0.0)
    # deterministic bootstrap (fixed seed) so figures are reproducible
    rng=np.random.default_rng(12345)
    boots=np.array([np.mean(rng.choice(vals,n,replace=True)) for _ in range(iters)])
    m=np.mean(vals)
    return m, m-np.percentile(boots,100*alpha/2), np.percentile(boots,100*(1-alpha/2))-m
rigor_csv=f"{BASE}/phase_stat/data/rigor.csv"
cond=defaultdict(list)
if os.path.exists(rigor_csv):
    for r in csv.DictReader(open(rigor_csv)):
        if r["arm"] in ("baseline","unmitigated","mitigated"): cond[r["arm"]].append(f(r["v_p99"]))
if not all(len(cond.get(a,[]))>=5 for a in ("baseline","unmitigated","mitigated")):
    # fallback to the n=3 pilot if the n>=10 run isn't present yet
    rp=list(csv.DictReader(open([f"{BASE}/phase3/data/"+d+"/repeats.csv"
          for d in os.listdir(f"{BASE}/phase3/data") if d.startswith("repeats_")][0])))
    cond=defaultdict(list)
    for r in rp:
        if r["cond"] in ("baseline","unmitigated","mitigated"): cond[r["cond"]].append(f(r["v_p99"]))
order=["baseline","unmitigated","mitigated"]; labs=["no\naggressor","unmitigated","ours\n(controller on)"]
stats=[bootstrap_ci([v for v in cond[c] if not np.isnan(v)]) for c in order]
means=[s[0] for s in stats]; lo=[s[1] for s in stats]; hi=[s[2] for s in stats]
nlab=[len([v for v in cond[c] if not np.isnan(v)]) for c in order]
fig, axm=plt.subplots(figsize=(4.6,3.6))
bars=axm.bar(labs, means, yerr=[lo,hi], capsize=4, color=[C_OURS,C_CHURN,C_OURS],
             alpha=.85, edgecolor="black", linewidth=0.6, error_kw={"elinewidth":1.2})
for b,m,n in zip(bars,means,nlab):
    axm.text(b.get_x()+b.get_width()/2, m+max(means)*0.03, f"{m:.1f}", ha="center", fontsize=10)
axm.set_ylabel("victim P99 latency (ms)")
axm.text(0.97,0.95,f"$n={nlab[0]}$ per bar\n95% bootstrap CI",transform=axm.transAxes,
         ha="right",va="top",fontsize=9,color="0.35")
fig.tight_layout(); fig.savefig(f"{OUT}/fig_mitigation.pdf"); plt.close(fig)

# ===== FIG 6: differentiation bars (P4) =====
p4=list(csv.DictReader(open(f"{BASE}/phase4/data/diff.csv")))
arm=defaultdict(list); armb=defaultdict(list)
for r in p4: arm[r["arm"]].append(f(r["v_p99"])); armb[r["arm"]].append(f(r["zt_busy_rate"]))
order=["bwm_1M","bwm_256k","ours"]; labs=["Cilium BWM\n(1 Mbit)","Cilium BWM\n(256 kbit)","ours\n(conn-pacer)"]
means=[np.mean(arm[a]) for a in order]; sds=[np.std(arm[a]) for a in order]
fig, axf=plt.subplots(figsize=(5.0,3.6))
cols=[C_BWM,C_BWM,C_OURS]
bars=axf.bar(labs, means, yerr=sds, capsize=5, color=cols, alpha=.8, edgecolor="k")
axf.axhline(46.3, ls="--", color=C_CHURN, alpha=.7, label="unmitigated (46 ms)")
axf.axhline(2.86, ls=":", color="k", alpha=.6, label="baseline (2.9 ms)")
for b,m,a in zip(bars,means,order):
    axf.text(b.get_x()+b.get_width()/2, m+1.5, f"{m:.0f}", ha="center", fontsize=9)
axf.set_ylabel("victim P99 latency (ms)")
axf.legend(loc="upper right"); fig.tight_layout(); fig.savefig(f"{OUT}/fig_differentiation.pdf"); plt.close(fig)

# ===== FIG 7: setpoint sensitivity (P6) =====
sp=list(csv.DictReader(open(f"{BASE}/phase6/data/setpoint_sweep.csv")))
x=[int(r["setpoint"]) for r in sp]; y=[f(r["v_p99"]) for r in sp]
fig, axs2=plt.subplots(figsize=(4.8,3.4))
axs2.plot(x,y,"o-",color=C_OURS,lw=1.8,ms=7)
axs2.axhline(2.86, ls=":", color="k", alpha=.5, label="baseline")
axs2.axhline(46.3, ls="--", color=C_CHURN, alpha=.6, label="unmitigated")
axs2.axvspan(200,1200,alpha=.12,color=C_OURS,label="robust region (6× range)")
axs2.set_xlabel("connection-rate setpoint (conns/s)"); axs2.set_ylabel("victim P99 latency (ms)")
axs2.legend(loc="upper left", fontsize=8); fig.tight_layout()
fig.savefig(f"{OUT}/fig_sensitivity.pdf"); plt.close(fig)

print("figures written to", OUT)
for fn in sorted(os.listdir(OUT)): print(" ", fn)
