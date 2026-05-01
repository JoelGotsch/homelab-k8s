# observability/otel-collector

OpenTelemetry Collector — DaemonSet (agent) + Deployment
(gateway) pair per ADR 0021 D3. Receives OTLP from cluster
workloads + forwards to Tempo (today) + Langfuse (deferred,
commented-with-TODO until that layer lands).

## Architecture

```
   workload pods                  workload pods
        │                              │
        ▼ OTLP (4317/4318)             ▼ OTLP
   otel-agent                     otel-agent
   (DaemonSet, node N)            (DaemonSet, node M)
        │                              │
        └────────┬─────────────────────┘
                 │ OTLP (4317)
                 ▼
   otel-gateway (Deployment, 2 replicas)
                 │
                 ├── OTLP gRPC → Tempo
                 └── (future) OTLP HTTP → Langfuse
```

## Why two tiers (per ADR 0021 D3)

- **Agent (DaemonSet)** — local-node receiver. Lower-latency
  for workloads + smaller per-node memory footprint than
  pushing every span to the central gateway. Batches + rolls
  up before forwarding.
- **Gateway (Deployment, 2 replicas)** — central
  fan-out point. Where the export decisions live (Tempo +
  later Langfuse). HA via 2 replicas; agents fail-soft to
  whichever replica is available via cluster-DNS.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Two helm releases from `opentelemetry-collector` chart 0.108.0 with different release names + value files. |
| `values-gateway.yaml` | `mode: deployment`, 2 replicas; OTLP receivers; export pipeline → Tempo (Langfuse exporter commented-with-TODO). |
| `values-agent.yaml` | `mode: daemonset`; OTLP receivers; export → gateway via cluster DNS. |
| `networkpolicy.yaml` | Per-tier NetPols: gateway ingress from agents + Prometheus, egress to Tempo + DNS; agent ingress from any-namespace workloads + Prometheus, egress to gateway + DNS. |
| `servicemonitor.yaml` | Per-tier metrics scrape on `:8888`. |

## How workloads emit traces

Workloads target `opentelemetry-collector-agent.monitoring.svc.
cluster.local:4317` (gRPC) or `:4318` (HTTP). The agent
forwards to the gateway, which fans out to Tempo + (future)
Langfuse.

For Pydantic-AI agents, LiteLLM, and other Python services,
set `OTEL_EXPORTER_OTLP_ENDPOINT=http://opentelemetry-collector-
agent.monitoring.svc.cluster.local:4318` in the workload's
ConfigMap or Deployment env. For Go services (cert-manager,
Argo CD), the same envvar applies (the OTel SDK reads it).

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync `observability/tempo/` | Tempo's OTLP receiver listens on 4317/4318. |
| Argo sync this layer | Two helm releases come up: gateway (2 replicas) + agent (DaemonSet on every node). NetPols + ServiceMonitors land. |
| First workload emits OTLP | Spans flow agent → gateway → Tempo; visible in Grafana → Explore → Tempo data source. |

No workloads emit OTLP at first install — Pydantic-AI / LiteLLM
/ etc. need explicit OTLP env config in their values, which is
operator-extensible per-app as instrumentation is added.

## Caveats

1. **No exporters to Langfuse yet** — commented-with-TODO in
   `values-gateway.yaml` `exporters:`. Un-comments when the
   `langfuse` layer lands; needs `LANGFUSE_AUTH_HEADER` ESO
   env injection.
2. **OTel chart version drift risk** — chart 0.108.0 + image
   0.111.0 are pinned independently. Renovate must update both
   in lockstep; chart values schemas can change between minor
   versions.
3. **Agent NetPol allows OTLP from any namespace.** Operator-
   side narrowing (specific namespaceSelector) is the upgrade
   path if a workload-set scope materialises. Today, OTLP push
   from anywhere in the cluster is permitted.
4. **No Jaeger / Zipkin compat** — OTLP only. If a workload
   ships only Jaeger or Zipkin, add a receiver to
   `values-agent.yaml` `receivers:` block + a port mapping
   in `ports:`.
5. **`memory_limiter` percentage-based** — drops data under
   memory pressure rather than crash-looping. Tune at first
   install if normal load is consistently >80% memory.
6. **Two ServiceMonitors but one chart** — chart's bundled
   ServiceMonitor config is disabled (single-bundle assumption
   doesn't fit our two-release shape); we ship our own per-
   tier in `servicemonitor.yaml`.

## Related

- [ADR 0021 D3](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — OTel Collector + Tempo + Langfuse architecture.
- [`observability/tempo/`](../tempo/) — primary OTLP sink.
- Future: `observability/langfuse/` — second OTLP sink for
  LLM-specific tracing + experiment / eval / prompt-versioning.
- [99-journal/2026-05-01-tempo-otel-collector.md](../../../homelab-docs/99-journal/2026-05-01-tempo-otel-collector.md)
  — implementation journal.
