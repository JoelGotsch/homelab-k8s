# observability/tempo

Distributed tracing per ADR 0021 D3. OTLP receiver + S3-backed
block storage on MinIO `tempo-blocks` + Grafana data source for
exemplar-linked tracing from Prometheus alerts to spans to Loki
log lines.

## Architecture

```
            Workloads (Pydantic-AI agents, LiteLLM,
            cert-manager, Argo CD, etc.) emit OTLP
                           │
                           ▼
            otel-collector-agent (DaemonSet)
                           │
                           ▼
            otel-collector-gateway (Deployment)
                           │
                           ▼
            Tempo monolithic (this layer)
                           │
                           ▼
            MinIO `tempo-blocks` bucket
                           ▲
                           │ (queries)
            Grafana data source
```

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | grafana/tempo chart 1.10.1 (Renovate-pinned). |
| `values.yaml` | Monolithic mode; auth disabled (single-tenant); OTLP gRPC + HTTP receivers; S3 backend pointing at MinIO `tempo-blocks` (creds from ESO-managed Secret). |
| `externalsecret.yaml` | tempo/s3-creds from OpenBao. |
| `networkpolicy.yaml` | Ingress: OTel Collector gateway (4317/4318), Grafana + Prometheus (3200). Egress: kube-DNS + MinIO. |
| `servicemonitor.yaml` | Self-metrics scrape on `http-metrics`. |

## OpenBao paths to seed

| Path | Field | Notes |
|---|---|---|
| `kv/data/tempo/s3-creds` | `access_key_id`, `secret_access_key` | MinIO svc-account scoped to `tempo-blocks`. Standard CNPG-app pattern (operator runs `mc admin user svcacct add` after MinIO Healthy; cold-start.md Step 13c). |

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync `infrastructure/minio-on-nas/` | `tempo-blocks` bucket pre-created. |
| Operator seeds `kv/tempo/s3-creds` | ESO can populate. |
| Argo sync this layer | Tempo monolithic up; PVC mounted; OTLP receivers listen on 4317/4318. |
| Argo sync `observability/otel-collector/` | Gateway forwards OTLP to Tempo; first traces flow when workloads emit. |
| Argo sync `observability/kube-prometheus-stack/` (with Tempo data source uncommented) | Operator queries `service.name="..."` traces via Grafana → Explore → Tempo. |

## Caveats

1. **Monolithic mode caps throughput** at chart-default
   ingest. At homelab scale (~100s of spans/sec) this is
   fine. Scale-trigger to `distributed` deploymentMode if
   ingest visibly stalls; same shape as Loki D1's pivot path.
2. **`multitenancy_enabled: false`** — single-tenant cluster
   per ADR 0021. NetworkPolicy gates ingress (OTel Collector
   gateway, Grafana, Prometheus); auth at app layer is
   redundant.
3. **14d local hot retention** per ADR 0021 D8
   (`block_retention: 336h`). MinIO-side warm tier (30d) is
   operator-managed via MinIO lifecycle rules at first
   install — not configured here.
4. **Single replica** — Tempo monolithic doesn't HA; pod
   eviction = brief query interruption (writes from OTel
   Collector retry on 5xx). HA needs `distributed` mode +
   memberlist.
5. **No Jaeger / Zipkin compat receivers** — OTLP only.
   Workloads must emit OTLP (most Pydantic-AI / LiteLLM /
   cert-manager bridges support OTLP natively).
6. **Search retention is unlimited** (`max_duration: 0s`).
   Tune if query volume becomes expensive.

## Related

- [ADR 0021 D3](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — distributed tracing decision; Tempo + Langfuse split.
- [ADR 0021 D8](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — Tempo retention table.
- [`observability/otel-collector/`](../otel-collector/) — the
  OTLP receiver/forwarder that ships traces to Tempo.
- [`observability/loki/`](../loki/) — companion log store;
  shared exemplar-linking via Grafana.
- [`infrastructure/minio-on-nas/`](../../infrastructure/minio-on-nas/)
  — `tempo-blocks` bucket source.
- [99-journal/2026-05-01-tempo-otel-collector.md](../../../homelab-docs/99-journal/2026-05-01-tempo-otel-collector.md)
  — implementation journal.
