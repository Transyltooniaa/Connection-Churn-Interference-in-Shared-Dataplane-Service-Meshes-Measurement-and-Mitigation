#!/bin/bash
# Phase-3 CLOSED-LOOP controller: reactive, threshold + hysteresis, ~fast loop.
# Reads ztunnel saturation signal (busy-rate over short window ~ CPU near cap) and sets the
# aggressor's connection-rate cap: saturated -> clamp to SETPOINT; recovered -> release.
# Writes /tmp/rate in the churn pod (churngen_ctl reads it live).
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
UT=$(kubectl get node -l ssp-role=under-test -o jsonpath='{.items[0].metadata.name}')
ZTIP=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$UT -o jsonpath='{.items[0].status.podIP}')
SETPOINT=${SETPOINT:-700}   # conns/s cap when saturated (below the ~800-1500 knee)
HI=${HI:-1.5}               # busy-rate/s high threshold (ztunnel saturating, ~cap)
LO=${LO:-1.0}               # low threshold (recovered) -> hysteresis band
DUR=${DUR:-120}
LOG=${LOG:-/tmp/ctl.log}
busy(){ kubectl -n loadgen exec loadgen -- curl -s --max-time 2 "http://$ZTIP:15020/metrics" 2>/dev/null | awk '/tokio_worker_total_busy_duration_seconds_total/{s+=$2}END{print s+0}'; }
setrate(){ kubectl -n dsb exec churn -- bash -c "echo $1 > /tmp/rate"; }

# Anti-flap: once paced, hold >= DWELL seconds AND require RECOVER_N consecutive low samples
# before releasing. Prevents the pace/release oscillation (paced state un-saturates ztunnel,
# which would otherwise immediately trigger release -> re-saturate).
DWELL=${DWELL:-15}; RECOVER_N=${RECOVER_N:-4}
echo "controller: SETPOINT=$SETPOINT HI=$HI LO=$LO DWELL=$DWELL RECOVER_N=$RECOVER_N" | tee "$LOG"
state="open"; setrate 0; paced_at=0; lowcount=0
end=$(( $(date +%s) + DUR ))
prev=$(busy); pt=$(date +%s.%N)
while [ $(date +%s) -lt $end ]; do
  sleep 1
  cur=$(busy); ct=$(date +%s.%N)
  rate=$(python3 -c "dt=$ct-$pt; print(round(($cur-$prev)/dt,3) if dt>0 else 0)")
  prev=$cur; pt=$ct
  if [ "$state" = open ]; then
    if python3 -c "exit(0 if $rate>=$HI else 1)"; then state="paced"; setrate $SETPOINT; paced_at=$(date +%s); lowcount=0; act="SATURATED->pace@$SETPOINT"; else act="ok"; fi
  else
    # in paced state: only consider releasing after DWELL, and after RECOVER_N sustained-low samples
    if python3 -c "exit(0 if $rate<$LO else 1)"; then lowcount=$((lowcount+1)); else lowcount=0; fi
    held=$(( $(date +%s) - paced_at ))
    if [ $held -ge $DWELL ] && [ $lowcount -ge $RECOVER_N ]; then state="open"; setrate 0; act="recovered(held=${held}s)->release"; else act="holding@$SETPOINT (held=${held}s low=$lowcount)"; fi
  fi
  echo "$(date +%T) busy_rate=$rate state=$state $act" | tee -a "$LOG"
done
setrate 0
echo "controller done" | tee -a "$LOG"