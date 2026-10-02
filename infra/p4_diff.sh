#!/bin/bash
# Phase-4 differentiation: mitigate the CHURN attack with different mechanisms, compare
# victim recovery + aggressor goodput. Arms:
#   none        : aggressor full churn, no mitigation (control)
#   bwm_1M      : Cilium Bandwidth Manager egress cap 1Mbit (byte-pacing)
#   bwm_256k    : Cilium BWM egress cap 256kbit (very aggressive byte cap)
#   pullbuffer  : our pull-based buffer design (NATS JetStream + Rust ingestion proxy + KEDA)
#                 Replaces the former "ours" arm (reactive connection-rate pacer @ 700/s).
# NOTE: BWM cap is changed by recreating churn pod w/ annotation (done by caller per arm).
# This script runs ONE arm given $ARM.
# For the pullbuffer arm the NATS DaemonSet + ingestion proxy + KEDA must already be deployed.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
ARM=${1:-none}
OUT=/datastore2/ajitesh/ssp/proposal-v2/phases/phase4/data; mkdir -p "$OUT"
FE=nginx-thrift.dsb.svc.cluster.local:8080; ECHO=agg-echo.dsb.svc.cluster.local:8080
UT=ip-192-168-11-9.us-east-2.compute.internal
ZTIP=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$UT -o jsonpath='{.items[0].status.podIP}')
NATS_MON="http://$(kubectl get node $UT -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):8222"
CSV="$OUT/diff.csv"; [ -f "$CSV" ] || echo "arm,trial,v_p99,agg_conn_rate,zt_busy_rate,nats_lag_alpha" > "$CSV"
cleanup(){
  kubectl -n dsb exec churn -- pkill -9 churngen 2>/dev/null||true
  # churngen_ctl and p3_controller.sh no longer used
}
trap cleanup EXIT INT TERM
vic(){ kubectl -n loadgen exec loadgen -- bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; /usr/local/bin/wrk2 -t2 -c20 -d10s -L -R100 -s ./read-home-timeline.lua http://$FE 2>&1" | awk '/99.000%/{print $2}'|head -1; }
busyrate(){ a=$(kubectl -n loadgen exec loadgen -- curl -s --max-time 2 http://$ZTIP:15020/metrics 2>/dev/null|awk '/tokio_worker_total_busy_duration_seconds_total/{s+=$2}END{print s}'); sleep 4; b=$(kubectl -n loadgen exec loadgen -- curl -s --max-time 2 http://$ZTIP:15020/metrics 2>/dev/null|awk '/tokio_worker_total_busy_duration_seconds_total/{s+=$2}END{print s}'); python3 -c "print(round(($b-$a)/4,3))"; }
nats_lag_alpha(){
  kubectl -n loadgen exec loadgen -- curl -s --max-time 2 \
    "${NATS_MON}/jsz?streams=true&consumers=true" 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in (d.get('account_details') or [{}])[0].get('stream_detail') or []:
    if s.get('name') == 'LOCAL-ALPHA':
        print(sum(c.get('num_pending',0) for c in s.get('consumer_detail') or []))
        sys.exit(0)
print(0)
" 2>/dev/null || echo 0
}

for tr in 1 2 3; do
  if [ "$ARM" = pullbuffer ]; then
    # Pull-buffer arm: NATS JetStream DaemonSet + Rust ingestion proxy + KEDA are
    # already running on the node as infrastructure-level DaemonSets.
    # churngen sends connections at full blast; the ingestion proxy absorbs them
    # into the NATS queue (bounded by DiscardNew policy); KEDA scales worker pods.
    # No controller process is started — mitigation is entirely passive/infra-level.
    kubectl -n dsb exec churn -- timeout 60 /tmp/churngen $ECHO 800 60 >/tmp/agg4.log 2>&1 &
    sleep 16   # allow KEDA to detect lag, scale workers, and reach steady state
  else
    # bwm arms & none: plain full-blast churngen (BWM cap already set via pod annotation)
    kubectl -n dsb exec churn -- timeout 45 /tmp/churngen $ECHO 800 45 >/tmp/agg4.log 2>&1 &
    sleep 8
  fi
  p99=$(vic); br=$(busyrate)
  lag_a=$(nats_lag_alpha)
  ach=$(kubectl -n dsb exec churn -- cat /tmp/agg4.log 2>/dev/null | grep -oE 'rate=[0-9]+' | cut -d= -f2)
  echo "$ARM,$tr,$p99,${ach:-NA},$br,$lag_a" >> "$CSV"
  echo "  [$ARM tr$tr] victim P99=$p99 | aggConnRate=${ach:-running} | ztBusy=$br | natsLagAlpha=$lag_a"
  cleanup; sleep 10
done
echo "=== arm $ARM done ==="