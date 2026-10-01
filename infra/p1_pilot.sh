#!/bin/bash
# Phase-1 PILOT: baseline + one aggressor level, to confirm the interference effect appears
# and ztunnel saturates cleanly before committing to the full N>=5 sweep.
# Victim = home-timeline @ fixed rate. Aggressor = DSB compose-post at high rate (all-DSB story).
# Captures victim latency + ztunnel Tokio/CPU + node CPU simultaneously.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
OUT=/datastore2/ajitesh/ssp/proposal-v2/phases/phase1/data/pilot_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
FE=nginx-thrift.dsb.svc.cluster.local:8080
ZTIP=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=ip-192-168-11-9.us-east-2.compute.internal -o jsonpath='{.items[0].status.podIP}')
UT=ip-192-168-11-9.us-east-2.compute.internal
echo "OUT=$OUT  ztunnel(under-test)=$ZTIP"

# sample ztunnel Tokio metrics + node CPU, backgrounded, every 2s
sample() { # $1=tag
  local tag=$1 f="$OUT/signals_$tag.csv"
  echo "t,tokio_busy0,tokio_busy1,park0,park1,queue_depth,node_cpu_milli" > "$f"
  for i in $(seq 1 90); do
    local m=$(kubectl -n loadgen exec loadgen -- curl -s --max-time 3 "http://$ZTIP:15020/metrics" 2>/dev/null)
    local b0=$(echo "$m" | awk -F' ' '/tokio_worker_total_busy_duration_seconds_total.*worker="0"/{print $2}')
    local b1=$(echo "$m" | awk -F' ' '/tokio_worker_total_busy_duration_seconds_total.*worker="1"/{print $2}')
    local p0=$(echo "$m" | awk -F' ' '/tokio_worker_park_count.*worker="0"/{print $2}')
    local p1=$(echo "$m" | awk -F' ' '/tokio_worker_park_count.*worker="1"/{print $2}')
    local qd=$(echo "$m" | awk -F' ' '/tokio_global_queue_depth/{print $2}')
    local nc=$(kubectl top node "$UT" --no-headers 2>/dev/null | awk '{print $2}')
    echo "$i,$b0,$b1,$p0,$p1,$qd,$nc" >> "$f"
    sleep 2
  done
}

run_victim() { # $1=tag $2=duration
  kubectl -n loadgen exec loadgen -- bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; \
    /usr/local/bin/wrk2 -t2 -c20 -d$2 -L -R100 -s ./read-home-timeline.lua http://$FE 2>&1" > "$OUT/victim_$1.txt" 2>&1
}
run_aggressor() { # $1=rate $2=duration  (compose-post = write fan-out, heavy)
  kubectl -n loadgen exec loadgen -- bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; \
    /usr/local/bin/wrk2 -t4 -c50 -d$2 -R$1 -s ./compose-post.lua http://$FE 2>&1" > "$OUT/aggressor_$1.txt" 2>&1
}

echo "=== [1] BASELINE: victim home-timeline @100rps, 60s, no aggressor ==="
sample baseline & SP=$!
run_victim baseline 60s
kill $SP 2>/dev/null; wait $SP 2>/dev/null

echo "=== [2] INTERFERENCE: victim @100rps + aggressor compose-post @1500rps, 90s ==="
sample interference & SP=$!
run_aggressor 1500 90s & AP=$!
sleep 5
run_victim interference 60s
wait $AP 2>/dev/null
kill $SP 2>/dev/null; wait $SP 2>/dev/null

echo "=== PILOT DONE -> $OUT ==="
echo "--- victim baseline percentiles ---"; grep -E "50.000%|90.000%|99.000%|99.900%|Non-2xx|Requests/sec" "$OUT/victim_baseline.txt" | head
echo "--- victim interference percentiles ---"; grep -E "50.000%|90.000%|99.000%|99.900%|Non-2xx|Requests/sec" "$OUT/victim_interference.txt" | head
echo "--- ztunnel busy delta (baseline vs interference) ---"
echo "baseline tail:"; tail -2 "$OUT/signals_baseline.csv"
echo "interference tail:"; tail -2 "$OUT/signals_interference.csv"
