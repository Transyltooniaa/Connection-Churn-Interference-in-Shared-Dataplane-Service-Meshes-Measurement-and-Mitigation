#!/bin/bash
# Phase-3 closed-loop demo timeline (single run; repeat for CI later):
#  t0-20s : baseline (no aggressor)
#  t20-50s: aggressor FULL blast, controller OFF (unmitigated) -> victim tail blows up
#  t50-90s: controller ON (reactive pacing) -> victim recovers while aggressor still served
# Captures victim P99 each ~10s phase + ztunnel busy + aggressor achieved.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
OUT=/datastore2/ajitesh/ssp/proposal-v2/phases/phase3/data/closedloop_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
FE=nginx-thrift.dsb.svc.cluster.local:8080
ECHO=agg-echo.dsb.svc.cluster.local:8080
UT=ip-192-168-11-9.us-east-2.compute.internal
ZTIP=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$UT -o jsonpath='{.items[0].status.podIP}')
cleanup(){ kubectl -n dsb exec churn -- pkill -9 churngen_ctl 2>/dev/null||true; kubectl -n dsb exec churn -- pkill -9 churngen 2>/dev/null||true; pkill -f p3_controller 2>/dev/null||true; }
trap cleanup EXIT INT TERM
CSV="$OUT/timeline.csv"; echo "phase,v_p50,v_p99,zt_busy_rate,agg_rate_cap" > "$CSV"
busyrate(){ a=$(kubectl -n loadgen exec loadgen -- curl -s --max-time 2 http://$ZTIP:15020/metrics 2>/dev/null|awk '/tokio_worker_total_busy_duration_seconds_total/{s+=$2}END{print s}'); sleep 4; b=$(kubectl -n loadgen exec loadgen -- curl -s --max-time 2 http://$ZTIP:15020/metrics 2>/dev/null|awk '/tokio_worker_total_busy_duration_seconds_total/{s+=$2}END{print s}'); python3 -c "print(round(($b-$a)/4,3))"; }
vic(){ kubectl -n loadgen exec loadgen -- bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; /usr/local/bin/wrk2 -t2 -c20 -d10s -L -R100 -s ./read-home-timeline.lua http://$FE 2>&1" | awk '/50.000%/{p50=$2}/99.000%/{print p50, $2}'; }
row(){ read p50 p99 <<< "$(vic)"; br=$(busyrate); cap=$(kubectl -n dsb exec churn -- cat /tmp/rate 2>/dev/null||echo NA); echo "$1,$p50,$p99,$br,$cap" >> "$CSV"; echo "  [$1] P50=$p50 P99=$p99 ztBusyRate=$br aggCap=$cap"; }

kubectl -n dsb exec churn -- bash -c 'echo 0 > /tmp/rate'
echo "=== PHASE 1: baseline (no aggressor) ==="
row baseline

echo "=== PHASE 2: aggressor full blast, controller OFF (unmitigated) ==="
kubectl -n dsb exec churn -- timeout 140 /tmp/churngen_ctl $ECHO 800 140 /tmp/rate >/tmp/agg_cl.log 2>&1 &
sleep 6
row unmitigated
row unmitigated2

echo "=== PHASE 3: controller ON (reactive pacing, anti-flap dwell) ==="
SETPOINT=700 HI=1.5 LO=1.0 DWELL=40 RECOVER_N=6 DUR=70 bash /datastore2/ajitesh/ssp/proposal-v2/infra/p3_controller.sh >/tmp/ctl.log 2>&1 &
sleep 14   # let controller detect + clamp + settle into steady pacing before measuring
row mitigated
row mitigated2
cleanup
echo "=== DONE -> $CSV ==="; column -t -s, "$CSV"
echo "--- controller log ---"; tail -8 /tmp/ctl.log