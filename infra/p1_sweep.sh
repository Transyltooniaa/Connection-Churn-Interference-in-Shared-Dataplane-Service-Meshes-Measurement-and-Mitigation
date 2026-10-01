#!/bin/bash
# Phase-1 FULL SWEEP — rigorous characterization + capture-everything.
# Sweeps aggressor 0..MAX, N trials/level, all 3 victim endpoints; captures victim latency,
# aggressor self-metrics, ztunnel Tokio + node-side cgroup cpu.stat/throttling, node CPU,
# per-DSB-service cpu. Randomized level order. Writes raw per-run + a tidy CSV.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH

RUN=p1_sweep_$(date +%Y%m%d_%H%M%S)
OUT=/datastore2/ajitesh/ssp/proposal-v2/phases/phase1/data/$RUN
mkdir -p "$OUT/raw"
FE=nginx-thrift.dsb.svc.cluster.local:8080
UT=ip-192-168-11-9.us-east-2.compute.internal
ZTUID_US=e89377a4_6613_4f93_b367_01d7096664af   # ztunnel pod uid (underscored) on UT node
ZTIP=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$UT -o jsonpath='{.items[0].status.podIP}')

TRIALS=${TRIALS:-5}
AGG_LEVELS=(0 200 500 1000 2000 4000)   # aggressor compose-post rps
VICTIM_RATE=100                          # home-timeline fixed rps
VDUR=60                                   # victim measurement seconds
WARM=15                                   # warmup/aggressor-lead seconds
CSV="$OUT/summary.csv"
echo "run,endpoint,agg_rps,trial,v_p50,v_p90,v_p99,v_p999,v_max,v_rps,v_non2xx,zt_busy_rate,zt_throttled_us_delta,zt_usage_us_delta,node_cpu_pct,agg_rps_ach,agg_non2xx" > "$CSV"

# read ztunnel node-side cgroup cumulative usage_usec + throttled_usec
zt_cg() { kubectl -n kube-system exec nodeprobe -- bash -c "
P=\$(find /host/sys/fs/cgroup/kubepods.slice -path '*pod${ZTUID_US}*' -name cpu.stat 2>/dev/null | grep -v cri-containerd | head -1)
awk '/^usage_usec/{u=\$2} /^throttled_usec/{t=\$2} END{print u, t}' \"\$P\"" 2>/dev/null; }
# read host cpu busy & total jiffies (cols: user nice sys idle iowait irq softirq steal)
# busy = all except idle+iowait ; total = all
node_cpu_start(){ kubectl -n kube-system exec nodeprobe -- awk '/^cpu /{busy=$2+$3+$4+$7+$8+$9; tot=$2+$3+$4+$5+$6+$7+$8+$9; print busy, tot}' /host/proc/stat 2>/dev/null; }
# ztunnel Tokio total busy seconds (sum of workers)
zt_busy(){ kubectl -n loadgen exec loadgen -- curl -s --max-time 3 "http://$ZTIP:15020/metrics" 2>/dev/null | awk '/tokio_worker_total_busy_duration_seconds_total/{s+=$2} END{print s+0}'; }

pct(){ grep -E "^ *$1%" "$2" | awk '{print $2}' | head -1 | sed 's/ms//;s/us/e-3/;s/s$//'; }  # crude; we post-parse properly
extract(){ # $1=victim file -> echo p50 p90 p99 p999 max rps non2xx
python3 - "$1" <<'PY'
import sys,re
t=open(sys.argv[1]).read()
def g(p):
    m=re.search(rf'^\s*{re.escape(p)}%\s+([0-9.]+)(ms|us|s)?',t,re.M)
    if not m: return 'NA'
    v=float(m.group(1)); u=m.group(2) or 'ms'
    return v*(0.001 if u=='us' else 1000 if u=='s' else 1)
rps=re.search(r'Requests/sec:\s+([0-9.]+)',t); rps=rps.group(1) if rps else 'NA'
non=re.search(r'Non-2xx or 3xx responses:\s+(\d+)',t); non=non.group(1) if non else '0'
mx=re.search(r'#\[Max\s*=\s*([0-9.]+)',t); mx=mx.group(1) if mx else 'NA'
print(g('50.000'),g('90.000'),g('99.000'),g('99.900'),mx,rps,non)
PY
}

run_victim(){ kubectl -n loadgen exec loadgen -- bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; /usr/local/bin/wrk2 -t2 -c20 -d${VDUR}s -L -R$VICTIM_RATE -s ./$1 http://$FE 2>&1"; }
run_agg(){ kubectl -n loadgen exec loadgen -- bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; /usr/local/bin/wrk2 -t4 -c50 -d$1s -R$2 -s ./compose-post.lua http://$FE 2>&1"; }

VICTIMS=("read-home-timeline.lua" "read-user-timeline.lua")   # home + user timeline as victims
# randomized level order per trial
for trial in $(seq 1 $TRIALS); do
  LEVELS=$(echo "${AGG_LEVELS[@]}" | tr ' ' '\n' | awk 'BEGIN{srand('$trial')}{print rand()"\t"$0}' | sort | cut -f2)
  for agg in $LEVELS; do
    for vic in "${VICTIMS[@]}"; do
      ep=${vic%.lua}
      tag="${ep}_agg${agg}_t${trial}"
      echo "[$(date +%T)] trial=$trial agg=$agg victim=$ep"
      if [ "$agg" -gt 0 ]; then run_agg $((VDUR+WARM+10)) $agg > "$OUT/raw/agg_$tag.txt" 2>&1 & AP=$!; sleep $WARM; else AP=""; fi
      # baselines sampled AFTER warmup so rates reflect the victim window only
      read zu0 zt0 <<< "$(zt_cg)"; b0=$(zt_busy); read nb0 nt0 <<< "$(node_cpu_start)"
      run_victim "$vic" > "$OUT/raw/victim_$tag.txt" 2>&1
      b1=$(zt_busy); read zu1 zt1 <<< "$(zt_cg)"; read nb1 nt1 <<< "$(node_cpu_start)"
      [ -n "$AP" ] && wait $AP 2>/dev/null || true
      # compute deltas / rates
      read v50 v90 v99 v999 vmax vrps vnon <<< "$(extract "$OUT/raw/victim_$tag.txt")"
      zbusy=$(python3 -c "print(round(($b1-$b0)/$VDUR,4))")
      ztht=$(python3 -c "print($zt1-$zt0)")
      zusg=$(python3 -c "print($zu1-$zu0)")
      ncpu=$(python3 -c "d=($nt1-$nt0); b=($nb1-$nb0); print(round(100*b/d,1) if d>0 else 'NA')")
      if [ -n "$AP" ]; then read a50 a90 a99 a999 amax arps anon <<< "$(extract "$OUT/raw/agg_$tag.txt")"; else arps=0; anon=0; fi
      echo "$RUN,$ep,$agg,$trial,$v50,$v90,$v99,$v999,$vmax,$vrps,$vnon,$zbusy,$ztht,$zusg,$ncpu,$arps,$anon" >> "$CSV"
      echo "    -> P50=$v50 P99=$v99 P99.9=$v999 | ztBusy/s=$zbusy throttled_us=$ztht nodeCPU%=$ncpu | aggRPS=$arps"
      sleep 8   # cooldown
    done
  done
done
echo "=== SWEEP DONE -> $CSV ==="; column -t -s, "$CSV" | head -60
