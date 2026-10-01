#!/bin/bash
# High-n statistical run: baseline / unmitigated / mitigated / BWM arms, N>=10 each,
# randomized order, for bootstrap CIs. Writes one tidy CSV.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
OUT=/datastore2/ajitesh/ssp/proposal-v2/phases/phase_stat/data; mkdir -p "$OUT"
FE=nginx-thrift.dsb.svc.cluster.local:8080; ECHO=agg-echo.dsb.svc.cluster.local:8080
# derive under-test node dynamically (node names change on every cluster recreate)
UT=$(kubectl get node -l ssp-role=under-test -o jsonpath='{.items[0].metadata.name}')
ZTIP=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$UT -o jsonpath='{.items[0].status.podIP}')
N=${N:-12}
CSV="$OUT/rigor.csv"; echo "arm,trial,v_p50,v_p99,v_p999" > "$CSV"
cleanup(){ kubectl -n dsb exec churn -- pkill -9 churngen_ctl 2>/dev/null||true; kubectl -n dsb exec churn -- pkill -9 churngen 2>/dev/null||true; for p in $(pgrep -f p3_controller.sh 2>/dev/null); do kill -9 $p 2>/dev/null; done; }
trap cleanup EXIT INT TERM

vic(){ kubectl -n loadgen exec loadgen -- bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; /usr/local/bin/wrk2 -t2 -c20 -d10s -L -R100 -s ./read-home-timeline.lua http://$FE 2>&1" | awk '/50.000%/{p50=$2}/99.000%/{p99=$2}/99.900%/{print p50,p99,$2}'; }
emit(){ read a b c <<< "$(vic)"; echo "$1,$2,${a:-NA},${b:-NA},${c:-NA}" >> "$CSV"; echo "  [$1 t$2] P50=$a P99=$b P99.9=$c"; }

# Build a randomized schedule of N trials x 4 arms
ARMS=(baseline unmitigated mitigated bwm)
for tr in $(seq 1 $N); do
  # randomize arm order within each trial block (awk rand seeded by trial)
  order=$(printf '%s\n' "${ARMS[@]}" | awk -v s=$tr 'BEGIN{srand(s*7+1)}{print rand()"\t"$0}'|sort|cut -f2)
  for arm in $order; do
    case $arm in
      baseline)
        emit baseline $tr ;;
      unmitigated)
        kubectl -n dsb exec churn -- timeout 30 /tmp/churngen $ECHO 800 30 >/dev/null 2>&1 & AP=$!
        sleep 7; emit unmitigated $tr; wait $AP 2>/dev/null||true; cleanup; sleep 6 ;;
      mitigated)
        kubectl -n dsb exec churn -- bash -c 'echo 0 > /tmp/rate'
        kubectl -n dsb exec churn -- timeout 45 /tmp/churngen_ctl $ECHO 800 45 /tmp/rate >/dev/null 2>&1 &
        SETPOINT=700 HI=1.5 LO=1.0 DWELL=40 RECOVER_N=6 DUR=45 bash /datastore2/ajitesh/ssp/proposal-v2/infra/p3_controller.sh >/dev/null 2>&1 &
        sleep 14; emit mitigated $tr; cleanup; sleep 8 ;;
      bwm)
        # BWM handled separately (needs pod annotation); skip here, done in bwm block below
        : ;;
    esac
  done
done
echo "=== DONE (baseline/unmitigated/mitigated) -> $CSV ==="
wc -l "$CSV"