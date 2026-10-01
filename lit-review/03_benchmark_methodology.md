# Lit Review 3 — Benchmark choice + methodology (verdict: DSB SocialNetwork primary)

Source caveat: Google Scholar (403) / Semantic Scholar (429) blocked → citation counts approx.

## Benchmark landscape
| Benchmark | #svc | Comm | K8s/Helm | Loadgen | Maturity | Ambient fit |
|---|---|---|---|---|---|---|
| **DeathStarBench** SocialNet~28 / Media / Hotel~19 | Thrift+gRPC+HTTP | Yes | **wrk2 built-in** | de-facto std, ~1400+ cites | Strong |
| Online Boutique (hipster) 11 | internal gRPC | Yes, Istio manifests shipped | Locust | ~21k stars, active | Good, easy |
| Train-Ticket 41 | REST | Yes | — | SE std, ~400+ | Heavy, resource-hungry |
| Sock Shop | REST | Yes | — | **ARCHIVED Dec 2023 — avoid** | — |
| TeaStore 5 | REST, client-LB | Yes | JMeter | ~250+ | atypical LB for mesh |
| muBench (synthetic) | HTTP+gRPC | Yes | custom | TPDS'23 | great for controlled sweeps, not "real" |
| Alibaba traces | dataset only, not runnable | — | — | SoCC'21 | realism justification only |

## Recommendation
**Primary: DeathStarBench — SocialNetwork headline**, HotelReservation as 2nd data point
(Go/gRPC contrast to SN's C++/Thrift → shows effect isn't language/RPC-specific).
Most reviewer-accepted; genuine multi-hop fan-out (composePost touches user, text,
url-shorten, media, post-storage, write-home-timeline + caches/DBs); ships Helm + wrk2.
**Optional secondary:** Online Boutique (clean Istio-blessed gRPC cross-check) OR muBench
(controlled fan-out/depth/CPU sweeps for the MECHANISM section). Avoid Sock Shop.

## Methodology checklist (reviewer expectations)
Load gen:
- **Open-loop / constant-throughput** to avoid coordinated omission. wrk2 (in DSB) or Fortio
  fixed-QPS; HDR histograms (wrk2 native). Avoid Locust/JMeter for tail numbers.
- Sweep load as fraction of measured saturation (30/50/70/90% of max sustainable QPS), not one point.
Metrics/stats:
- Report full p50/p90/p99/p99.9(/p99.99); publish HDR histogram or CCDF, not one number.
- **≥5–10 independent trials** on fresh deployments; median + 95% CI or IQR; state trial count+duration.
- Explicit warmup window discarded (JIT/cache/pool/autoscaler settle); steady-state ≥60–120s/trial.
Interference setup (core):
- Deliberate co-location: nodeSelector/affinity + CPU pinning (static CPU mgr, cpuset) so
  victim + shared ztunnel + antagonist land on same node. Show topology.
- **Isolate node-saturation confound (critical):** (a) A/B no-mesh vs ambient/ztunnel; (b) hold
  node CPU/mem constant, vary only which component is shared; (c) attribute cycles to ztunnel via
  cgroup accounting; (d) antagonist on separate core set so raw CPU headroom exists but shared
  proxy is bottleneck. **Report resource utilization alongside latency.**
- Load generator OFF the SUT node, dedicated machine/NIC; verify client isn't bottleneck.
- Disable HPA (or document), fix replicas, pin DBs/caches, pin image versions.

## Known DSB-on-K8s/Ambient gotchas (from live issue tracker)
- HotelReservation: RunContainerError (#361), stale Consul IPs / no graceful shutdown (#367),
  deploy failures (#358/#356). Media socket-reconnect under wrk (#369).
- Jaeger tracing broken after Helm (#366/#351), `jaegertracing/all-in-one:latest` incompat.
- wrk2 `-R` must be divisible by thread count (#360/#347) else wrong throughput.
- Ambient transparent → **no app change**, but Thrift/gRPC get L7 only WITH a waypoint;
  decide per-experiment: ztunnel-only (L4) vs ztunnel+waypoint (L7) interference.
- Pin `:latest` images to digests; budget time to patch/modernize Helm charts (document fork).
- **No published paper found running DSB on Istio AMBIENT specifically** → part of the novelty,
  but verify against latest proceedings before claiming "first."
