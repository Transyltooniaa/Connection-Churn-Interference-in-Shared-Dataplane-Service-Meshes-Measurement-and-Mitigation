#!/bin/bash
# Phase-2 hardening: HIGH-CADENCE signal + victim trace to measure lead-time properly.
# Runs a continuous ~200ms-cadence sampler of ztunnel signals AND a continuous victim
# latency stream (wrk2 reports per-1s), aligned on wall clock. Aggressor (churn) toggles
# mid-trace. Repeats REPS times for CI. No inline victim-probe blocking (that caused the
# coarse 7s cadence before).
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
RUN=p2_hc_$(date +%Y%m%d_%H%M%S)
OUT=/datastore2/ajitesh/ssp/proposal-v2/phases/phase2/data/$RUN; mkdir -p "$OUT"
FE=nginx-thrift.dsb.svc.cluster.local:8080
ECHO=agg-echo.dsb.svc.cluster.local:8080
UT=ip-192-168-11-9.us-east-2.compute.internal
ZTIP=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$UT -o jsonpath='{.items[0].status.podIP}')
REPS=${REPS:-5}
cleanup(){ kubectl -n dsb exec churn -- pkill -9 churngen 2>/dev/null || true; kubectl -n loadgen exec loadgen -- pkill -9 wrk2 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# High-cadence signal sampler: runs INSIDE loadgen pod (one curl loop, ~200ms), writes locally.
# We scrape metrics fast and emit epoch_ms + throttle/busy/opened/alive each tick.
signal_stream(){ # $1 outfile $2 seconds
  kubectl -n loadgen exec loadgen -- bash -c '
  end=$(( $(date +%s) + '"$2"' ))
  while [ $(date +%s) -lt $end ]; do
    t=$(date +%s.%N)
    m=$(curl -s --max-time 1 http://'"$ZTIP"':15020/metrics 2>/dev/null)
    o=$(echo "$m"|awk "/^istio_tcp_connections_opened_total/{s+=\$2}END{print s+0}")
    b=$(echo "$m"|awk "/^tokio_worker_total_busy_duration_seconds_total/{s+=\$2}END{print s+0}")
    a=$(echo "$m"|awk "/^tokio_num_alive_tasks/{print \$2}")
    echo "$t,$o,$b,$a"
    sleep 0.2
  done' > "$1" 2>/dev/null
}
# Victim latency stream: wrk2 prints per-second latency to a log we timestamp-parse.
# Simpler robust approach: run back-to-back 2s victim probes tagged with epoch.
victim_stream(){ # $1 outfile $2 seconds
  kubectl -n loadgen exec loadgen -- bash -c '
  cd /dsb/wrk2scripts/social-network; export max_user_index=962
  end=$(( $(date +%s) + '"$2"' ))
  while [ $(date +%s) -lt $end ]; do
    t=$(date +%s.%N)
    p=$(/usr/local/bin/wrk2 -t2 -c20 -d2s -L -R100 -s ./read-home-timeline.lua http://'"$FE"' 2>&1 | awk "/99.000%/{print \$2}" | head -1)
    echo "$t,$p"
  done' > "$1" 2>/dev/null
}

for rep in $(seq 1 $REPS); do
  echo "=== rep $rep: 15s idle, churn ON 15-45s, 45-55s idle ==="
  DUR=55
  signal_stream "$OUT/sig_$rep.csv" $DUR & SS=$!
  victim_stream "$OUT/vic_$rep.csv" $DUR & VS=$!
  sleep 15
  kubectl -n dsb exec churn -- timeout 30 /tmp/churngen $ECHO 800 30 >/dev/null 2>&1 || true
  wait $SS 2>/dev/null; wait $VS 2>/dev/null
  cleanup; sleep 8
done
echo "=== DONE -> $OUT ==="; wc -l "$OUT"/sig_*.csv "$OUT"/vic_*.csv 2>/dev/null | tail -3