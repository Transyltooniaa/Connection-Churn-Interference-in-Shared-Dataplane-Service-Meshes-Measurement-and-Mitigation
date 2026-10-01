#!/bin/bash
# Phase-3 control-principle spike: does CAPPING the aggressor's new-connection rate restore
# the victim? Sweep conn-rate cap; measure victim P99 + ztunnel throttle/CPU + aggressor achieved.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
OUT=/datastore2/ajitesh/ssp/proposal-v2/phases/phase3/data/principle_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
FE=nginx-thrift.dsb.svc.cluster.local:8080
ECHO=agg-echo.dsb.svc.cluster.local:8080
UT=ip-192-168-11-9.us-east-2.compute.internal
ZTUID_US=e89377a4_6613_4f93_b367_01d7096664af
ZTIP=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$UT -o jsonpath='{.items[0].status.podIP}')
cleanup(){ kubectl -n dsb exec churn -- pkill -9 churngen2 2>/dev/null||true; kubectl -n dsb exec churn -- pkill -9 churngen 2>/dev/null||true; }
trap cleanup EXIT INT TERM
CSV="$OUT/principle.csv"; echo "conn_rate_cap,trial,v_p99,v_p50,zt_throttle_delta,zt_cpu_cores,agg_achieved" > "$CSV"

zt_cg(){ kubectl -n kube-system exec nodeprobe -- bash -c '
  ZP=$(find /host/sys/fs/cgroup/kubepods.slice -path "*pod'"$ZTUID_US"'*" -name cpu.stat 2>/dev/null|grep -v cri-containerd|head -1)
  echo $(awk "/^usage_usec/{print \$2}" "$ZP") $(awk "/^nr_throttled/{print \$2}" "$ZP")' 2>/dev/null; }
vic(){ kubectl -n loadgen exec loadgen -- bash -c "cd /dsb/wrk2scripts/social-network; export max_user_index=962; /usr/local/bin/wrk2 -t2 -c20 -d12s -L -R100 -s ./read-home-timeline.lua http://$FE 2>&1" | awk '/50.000%/{p50=$2} /99.000%/{p99=$2} END{print p50, p99}'; }

# caps: 0=unlimited(baseline saturation), then increasingly tight rate limits
for cap in 0 3000 1500 800 400 200 100; do
  for tr in 1 2; do
    # start rate-capped churn (conc 800, 30s, cap conns/s)
    kubectl -n dsb exec churn -- timeout 30 /tmp/churngen2 $ECHO 800 30 $cap >/tmp/cg_$cap.log 2>&1 & AP=$!
    sleep 6
    read zu0 zt0 <<< "$(zt_cg)"
    read p50 p99 <<< "$(vic)"
    read zu1 zt1 <<< "$(zt_cg)"
    wait $AP 2>/dev/null || true
    ach=$(kubectl -n dsb exec churn -- cat /tmp/cg_$cap.log 2>/dev/null | grep -oE 'rate=[0-9]+' | cut -d= -f2)
    cpu=$(python3 -c "print(round(($zu1-$zu0)/1e6/12,3))")
    thr=$((zt1-zt0))
    echo "$cap,$tr,$p99,$p50,$thr,$cpu,${ach:-NA}" >> "$CSV"
    echo "  cap=${cap} tr$tr -> victim P99=$p99 P50=$p50 | ztThrottle+$thr ztCPU=${cpu}c | aggAchieved=$ach"
    sleep 6
  done
done
echo "=== DONE -> $CSV ==="; column -t -s, "$CSV"