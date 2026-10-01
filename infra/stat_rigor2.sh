#!/bin/bash
# High-n statistical run v2: robust. Each arm's N trials grouped; a verified-clean GATE
# before every measurement (poll until ztunnel busy-rate < 0.2 = drained); controller killed
# by exact PID. baseline / unmitigated / mitigated. (BWM arm handled by stat_bwm.sh.)
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
OUT=/datastore2/ajitesh/ssp/proposal-v2/phases/phase_stat/data; mkdir -p "$OUT"
FE=nginx-thrift.dsb.svc.cluster.local:8080; ECHO=agg-echo.dsb.svc.cluster.local:8080
UT=$(kubectl get node -l ssp-role=under-test -o jsonpath='{.items[0].metadata.name}')
ZTIP=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$UT -o jsonpath='{.items[0].status.podIP}')
N=${N:-12}
CSV="$OUT/rigor.csv"; echo "arm,trial,v_p50,v_p99,v_p999" > "$CSV"

kill_load(){ kubectl -n dsb exec churn -- pkill -9 churngen 2>/dev/null||true; kubectl -n dsb exec churn -- pkill -9 churngen_ctl 2>/dev/null||true; }
trap kill_load EXIT INT TERM
busyrate(){ a=$(kubectl -n loadgen exec loadgen -- curl -s --max-time 2 http://$ZTIP:15020/metrics 2>/dev/null|awk '/tokio_worker_total_busy_duration_seconds_total/{s+=$2}END{print s}'); sleep 3; b=$(kubectl -n loadgen exec loadgen -- curl -s --max-time 2 http://$ZTIP:15020/metrics 2>/dev/null|awk '/tokio_worker_total_busy_duration_seconds_total/{s+=$2}END{print s}'); awk "BEGIN{print ($b-$a)/3}"; }
# GATE: wait until proxy is drained (busy-rate<0.2) before trusting a baseline/measurement
gate(){ for i in $(seq 1 15); do br=$(busyrate); if awk "BEGIN{exit !($br<0.2)}"; then return 0; fi; sleep 3; done; }
vic(){ kubectl -n loadgen exec loadgen -- bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; /usr/local/bin/wrk2 -t2 -c20 -d10s -L -R100 -s ./read-home-timeline.lua http://$FE 2>&1" | awk '/50.000%/{p50=$2}/99.000%/{p99=$2}/99.900%/{print p50,p99,$2}'; }
emit(){ read a b c <<< "$(vic)"; echo "$1,$2,${a:-NA},${b:-NA},${c:-NA}" >> "$CSV"; echo "  [$1 t$2] P50=$a P99=$b P99.9=$c"; }

echo "=== BASELINE x$N (gate before each) ==="
for tr in $(seq 1 $N); do gate; emit baseline $tr; done

echo "=== UNMITIGATED x$N ==="
for tr in $(seq 1 $N); do
  gate
  kubectl -n dsb exec churn -- timeout 30 /tmp/churngen $ECHO 800 30 >/dev/null 2>&1 & AP=$!
  sleep 7; emit unmitigated $tr
  kill_load; wait $AP 2>/dev/null||true; sleep 5
done

echo "=== MITIGATED x$N (controller by exact PID) ==="
for tr in $(seq 1 $N); do
  gate
  kubectl -n dsb exec churn -- bash -c 'echo 0 > /tmp/rate'
  kubectl -n dsb exec churn -- timeout 45 /tmp/churngen_ctl $ECHO 800 45 /tmp/rate >/dev/null 2>&1 & AP=$!
  SETPOINT=700 HI=1.5 LO=1.0 DWELL=40 RECOVER_N=6 DUR=45 bash /datastore2/ajitesh/ssp/proposal-v2/infra/p3_controller.sh >/dev/null 2>&1 & CP=$!
  sleep 15; emit mitigated $tr
  kill -9 $CP 2>/dev/null||true; kill_load; wait $AP 2>/dev/null||true; sleep 6
done
echo "=== DONE -> $CSV ==="; wc -l "$CSV"