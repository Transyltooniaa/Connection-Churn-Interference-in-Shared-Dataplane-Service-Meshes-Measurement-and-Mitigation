#!/bin/bash
# Phase-2 signal selection (clean single-clock design).
# One loop per arm: each step (i) grabs all candidate signals, (ii) runs a short victim probe,
# recording signal+victim on the SAME row/clock. Aggressor turns ON partway so we see the
# transition. Rates computed as deltas between consecutive rows.
# Arms: churn (proxy mechanism) and compose (backend mechanism).
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
RUN=p2_signals_$(date +%Y%m%d_%H%M%S)
OUT=/datastore2/ajitesh/ssp/proposal-v2/phases/phase2/data/$RUN; mkdir -p "$OUT"
FE=nginx-thrift.dsb.svc.cluster.local:8080
ECHO=agg-echo.dsb.svc.cluster.local:8080
UT=ip-192-168-11-9.us-east-2.compute.internal
ZTUID_US=e89377a4_6613_4f93_b367_01d7096664af
ZTIP=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$UT -o jsonpath='{.items[0].status.podIP}')
STEPS=${STEPS:-40}; ON=${ON:-12}   # aggressor turns on at step ON

zt_snapshot(){ kubectl -n loadgen exec loadgen -- curl -s --max-time 2 "http://$ZTIP:15020/metrics" 2>/dev/null | awk '
/^istio_tcp_connections_opened_total/{o+=$2} /^istio_tcp_connections_closed_total/{c+=$2}
/^tokio_worker_total_busy_duration_seconds_total/{b+=$2} /^tokio_worker_park_count_total/{p+=$2}
/^tokio_global_queue_depth/{q=$2} /^tokio_num_alive_tasks/{a=$2}
END{printf "%d %d %.4f %d %d %d\n", o,c,b,p,q,a}'; }
zt_cg(){ kubectl -n kube-system exec nodeprobe -- bash -c '
  ZP=$(find /host/sys/fs/cgroup/kubepods.slice -path "*pod'"$ZTUID_US"'*" -name cpu.stat 2>/dev/null|grep -v cri-containerd|head -1)
  echo $(awk "/^usage_usec/{print \$2}" "$ZP") $(awk "/^nr_throttled/{print \$2}" "$ZP")' 2>/dev/null; }
victim_p99(){ kubectl -n loadgen exec loadgen -- bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; /usr/local/bin/wrk2 -t2 -c20 -d5s -L -R100 -s ./read-home-timeline.lua http://$FE 2>&1" | awk '/99.000%/{print $2}' | head -1; }

run_arm(){ local arm=$1 csv="$OUT/ts_$1.csv"
  echo "step,agg_on,opened,closed,busy,park,qdepth,alive,zt_usage_us,zt_nr_throttled,victim_p99" > "$csv"
  local AP=""
  # aggressor duration = exactly the remaining steps * ~7s, bounded
  local AGGDUR=$(( (STEPS-ON+2)*7 )); [ $AGGDUR -gt 250 ] && AGGDUR=250
  for s in $(seq 1 $STEPS); do
    if [ "$s" -eq "$ON" ]; then
      if [ "$arm" = churn ]; then kubectl -n dsb exec churn -- timeout $AGGDUR /tmp/churngen $ECHO 800 $AGGDUR >/dev/null 2>&1 & AP=$!
      else kubectl -n loadgen exec loadgen -- timeout $AGGDUR bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; /usr/local/bin/wrk2 -t4 -c50 -d${AGGDUR}s -R2000 -s ./compose-post.lua http://$FE" >/dev/null 2>&1 & AP=$!
      fi
    fi
    on=0; [ "$s" -ge "$ON" ] && on=1
    read o c b p q a <<< "$(zt_snapshot)"; read zu znt <<< "$(zt_cg)"; v=$(victim_p99)
    echo "$s,$on,$o,$c,$b,$p,$q,$a,$zu,$znt,${v:-NA}" >> "$csv"
    echo "  [$arm s$s on=$on] opened=$o busy=$b park=$p qd=$q usg=$zu thr=$znt P99=${v:-NA}"
  done
  # HARD cleanup: kill pod-side aggressor processes by name (not just the exec client)
  kubectl -n dsb exec churn -- pkill -9 churngen 2>/dev/null || true
  kubectl -n loadgen exec loadgen -- pkill -9 wrk2 2>/dev/null || true
  [ -n "$AP" ] && { kill $AP 2>/dev/null; wait $AP 2>/dev/null; } || true
  sleep 10   # let ztunnel drain before next arm
}
cleanup(){ kubectl -n dsb exec churn -- pkill -9 churngen 2>/dev/null || true; kubectl -n loadgen exec loadgen -- pkill -9 wrk2 2>/dev/null || true; }
trap cleanup EXIT INT TERM

run_arm churn
sleep 15
run_arm compose
cleanup
echo "=== DONE -> $OUT ==="