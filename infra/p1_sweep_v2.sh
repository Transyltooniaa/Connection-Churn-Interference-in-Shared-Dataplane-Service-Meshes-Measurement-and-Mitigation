#!/bin/bash
# Phase-1 FULL SWEEP v2 — clean churn-based design + capture-everything + N>=5 + CI.
# Two aggressor arms:
#   churn   = connection churn to disjoint agg-echo (isolates PROXY saturation)  [PRIMARY]
#   compose = DSB compose-post (realistic mixed: proxy + shared app-backend)     [REALISTIC]
# Victim = home-timeline @100rps (+ user-timeline). Sweeps aggressor intensity, randomized order.
# Captures: victim latency (HDR), ztunnel Tokio busy, node-side ztunnel cgroup usage+throttle,
#           node CPU%, aggressor achieved. Writes raw per-run + tidy summary.csv.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH

RUN=p1_sweep_$(date +%Y%m%d_%H%M%S)
OUT=/datastore2/ajitesh/ssp/proposal-v2/phases/phase1/data/$RUN
mkdir -p "$OUT/raw"
FE=nginx-thrift.dsb.svc.cluster.local:8080
ECHO=agg-echo.dsb.svc.cluster.local:8080
UT=ip-192-168-11-9.us-east-2.compute.internal
ZTUID_US=e89377a4_6613_4f93_b367_01d7096664af
ZTIP=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$UT -o jsonpath='{.items[0].status.podIP}')

TRIALS=${TRIALS:-5}
CHURN_LEVELS=(0 250 500 1000 2000)   # churngen concurrency (→ conns/s)
COMPOSE_LEVELS=(0 500 1000 2000)     # compose-post rps
VRATE=100; VDUR=60; WARM=12
CSV="$OUT/summary.csv"
echo "run,arm,victim,level,trial,v_p50,v_p90,v_p99,v_p999,v_max,v_rps,v_non2xx,zt_busy_per_s,zt_usage_cores,zt_throttled_delta,node_cpu_pct,agg_achieved" > "$CSV"

zt_busy(){ kubectl -n loadgen exec loadgen -- curl -s --max-time 3 "http://$ZTIP:15020/metrics" 2>/dev/null | awk '/tokio_worker_total_busy_duration_seconds_total/{s+=$2} END{print s+0}'; }
# node-side sampler: prints "nb nt zu znt" (node busy jiffies, node total, ztunnel usage_usec, ztunnel nr_throttled)
nodesamp(){ kubectl -n kube-system exec nodeprobe -- bash -c '
read _ u n s i w q sq st _ < <(grep "^cpu " /host/proc/stat)
ZP=$(find /host/sys/fs/cgroup/kubepods.slice -path "*pod'"$ZTUID_US"'*" -name cpu.stat 2>/dev/null|grep -v cri-containerd|head -1)
zu=$(awk "/^usage_usec/{print \$2}" "$ZP"); znt=$(awk "/^nr_throttled/{print \$2}" "$ZP")
echo $((u+n+s+q+sq+st)) $((u+n+s+i+w+q+sq+st)) $zu $znt' 2>/dev/null; }

extract(){ python3 - "$1" <<'PY'
import sys,re
t=open(sys.argv[1]).read()
def g(p):
    m=re.search(rf'^\s*{re.escape(p)}%\s+([0-9.]+)(ms|us|s)?',t,re.M)
    if not m: return 'NA'
    v=float(m.group(1)); u=m.group(2) or 'ms'
    return round(v*(0.001 if u=='us' else 1000 if u=='s' else 1),3)
rps=re.search(r'Requests/sec:\s+([0-9.]+)',t)
non=re.search(r'Non-2xx or 3xx responses:\s+(\d+)',t)
mx=re.search(r'#\[Max\s*=\s*([0-9.]+)',t)
print(g('50.000'),g('90.000'),g('99.000'),g('99.900'),(mx.group(1) if mx else 'NA'),(rps.group(1) if rps else 'NA'),(non.group(1) if non else '0'))
PY
}

run_victim(){ kubectl -n loadgen exec loadgen -- bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; /usr/local/bin/wrk2 -t2 -c20 -d${VDUR}s -L -R$VRATE -s ./$1 http://$FE 2>&1"; }
start_churn(){ kubectl -n dsb exec churn -- /tmp/churngen $ECHO $1 $((VDUR+WARM+8)) >/tmp/cg_$1.log 2>&1 & echo $!; }
start_compose(){ kubectl -n loadgen exec loadgen -- bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; /usr/local/bin/wrk2 -t4 -c50 -d$((VDUR+WARM+8))s -R$1 -s ./compose-post.lua http://$FE" >/tmp/comp_$1.log 2>&1 & echo $!; }

do_cell(){ # $1=arm $2=victim.lua $3=level $4=trial
  local arm=$1 vic=$2 lvl=$3 tr=$4 ep=${2%.lua} tag="${1}_${2%.lua}_L${3}_t${4}"
  local AP=""
  if [ "$lvl" -gt 0 ]; then
    if [ "$arm" = churn ]; then AP=$(start_churn $lvl); else AP=$(start_compose $lvl); fi
    sleep $WARM
  fi
  read nb0 nt0 zu0 znt0 <<< "$(nodesamp)"; b0=$(zt_busy)
  run_victim "$vic" > "$OUT/raw/victim_$tag.txt" 2>&1
  b1=$(zt_busy); read nb1 nt1 zu1 znt1 <<< "$(nodesamp)"
  [ -n "$AP" ] && wait $AP 2>/dev/null || true
  read v50 v90 v99 v999 vmax vrps vnon <<< "$(extract "$OUT/raw/victim_$tag.txt")"
  local zbusy=$(python3 -c "print(round(($b1-$b0)/$VDUR,4))")
  local zusg=$(python3 -c "print(round(($zu1-$zu0)/1e6/$VDUR,3))")
  local zthr=$(python3 -c "print($znt1-$znt0)")
  local ncpu=$(python3 -c "d=$nt1-$nt0; b=$nb1-$nb0; print(round(100*b/d,1) if d>0 else 'NA')")
  local ach=0
  if [ "$lvl" -gt 0 ]; then
    if [ "$arm" = churn ]; then ach=$(grep -oE 'rate=[0-9]+' /tmp/cg_$lvl.log 2>/dev/null | head -1 | cut -d= -f2);
    else ach=$(kubectl -n loadgen exec loadgen -- sh -c "true"; grep -oE 'Requests/sec:[ ]+[0-9.]+' /tmp/comp_$lvl.log 2>/dev/null|awk '{print $2}'); fi
  fi
  echo "$RUN,$arm,$ep,$lvl,$tr,$v50,$v90,$v99,$v999,$vmax,$vrps,$vnon,$zbusy,$zusg,$zthr,$ncpu,${ach:-NA}" >> "$CSV"
  echo "  [$arm $ep L$lvl t$tr] P50=$v50 P99=$v99 P99.9=$v999 | ztCPU=$zusg cores thr+$zthr | node=${ncpu}% | ach=$ach"
  sleep 8
}

echo "=== PHASE-1 SWEEP v2  RUN=$RUN  TRIALS=$TRIALS ==="
for tr in $(seq 1 $TRIALS); do
  # PRIMARY arm: churn, victim home-timeline; randomized level order
  for lvl in $(printf '%s\n' "${CHURN_LEVELS[@]}" | awk -v s=$tr 'BEGIN{srand(s)}{print rand()"\t"$0}'|sort|cut -f2); do
    do_cell churn read-home-timeline.lua $lvl $tr
  done
done
# REALISTIC arm (fewer trials to bound time): compose-post, home-timeline
for tr in $(seq 1 3); do
  for lvl in $(printf '%s\n' "${COMPOSE_LEVELS[@]}" | awk -v s=$tr 'BEGIN{srand(s+9)}{print rand()"\t"$0}'|sort|cut -f2); do
    do_cell compose read-home-timeline.lua $lvl $tr
  done
done
echo "=== DONE -> $CSV ==="
column -t -s, "$CSV"