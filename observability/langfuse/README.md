# observability/langfuse

LLM-specific tracing + experiment + evaluation +
prompt-versioning per ADR 0021 D3. Per
[ADR 0028](../../../homelab-docs/02-decisions/0028-langfuse-deployment-shape.md):
ClickHouse hosted via Altinity operator; instrumentation
contract is OpenTelemetry SDK (not the Langfuse-specific SDK)
to keep workloads backend-agnostic.

## Architecture

```
   Pydantic-AI agent       LiteLLM gateway       Mac Studio vLLM
        │                        │                       │
        ▼ OTLP                   ▼                       ▼
   otel-agent (DaemonSet, per-node)
        │
        ▼ OTLP
   otel-collector-gateway
        │
        ├──► Tempo (generic tracing; observability/tempo/)
        └──► Langfuse /api/public/otel
                │
                ▼
   ┌────────────┴────────────────────────┐
   │   langfuse-web + langfuse-worker     │
   └─────┬──────────────┬──────────────┬──┘
         ▼              ▼              ▼
    ClickHouse      Postgres       MinIO
    (Altinity)     (CNPG)        langfuse-blobs
    OLAP traces    app data      blob payloads
                                  (LLM I/O text,
                                   attachments)
                  + Redis (chart-managed; queue + cache)
```

## Why this shape (per ADR 0028)

| Decision | Picked | Why |
|---|---|---|
| Backend choice | **Langfuse** (not Phoenix) | ADR 0021 D3 reconsider-trigger conditions partially met (ClickHouse complexity, Phoenix feature parity) but operator preferred Langfuse's broader ecosystem momentum. Reconsider-trigger refined in ADR 0028. |
| ClickHouse host | **Altinity operator** | GA + 8 years production-deployed; stable CRD API. Official ClickHouse operator (Jan 2026) is v1alpha1 — too young for our GitOps shape. |
| Postgres | **CNPG** (codebase-wide pattern) | Same as crowdsec-lapi, llm-gateway, paperless, etc. WAL+base backup to MinIO; restic-tier-3 mirrors. |
| Redis | **Chart-managed** | Small, ephemeral (queue + cache); no durability concern; not load-bearing. |
| Blob storage | **MinIO `langfuse-blobs` bucket** | Same NFS-on-NAS substrate as the other observability buckets per ADR 0025. Bucket pre-created by `infrastructure/minio-on-nas/`. |
| Instrumentation contract | **OpenTelemetry SDK** (not Langfuse SDK) | Workloads stay backend-agnostic. If Langfuse breaks or feature-drifts, switching to Phoenix is a Collector-exporter change, not a workload-code change. |

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | langfuse-k8s helm chart 1.6.0 (Renovate-pinned). |
| `namespace.yaml` | `langfuse` ns; PSA baseline. |
| `values.yaml` | Helm values: external ClickHouse (Altinity-managed), external Postgres (CNPG-managed), chart-managed Redis, MinIO blob storage. Telemetry to Langfuse Inc. disabled per principle #2. |
| `clickhouseinstallation.yaml` | Altinity `ClickHouseInstallation` CR: single-replica + single-shard; 50 GB longhorn-replica2; user password from ESO Secret. |
| `cnpg-cluster.yaml` | CNPG `Cluster` CR: 2 instances longhorn-replica3; 30d WAL retention to MinIO; same pattern as crowdsec-lapi. |
| `externalsecret.yaml` | Three ESO ExternalSecrets: ClickHouse creds, Langfuse app secrets (NEXTAUTH_SECRET / SALT / ENCRYPTION_KEY / S3 creds), CNPG MinIO backup creds. |
| `networkpolicy.yaml` | Two NetPols: app (web + worker) ingress allow-list + egress to dependencies; ClickHouse ingress allow-list. |
| `servicemonitor.yaml` | Per-component metrics scrape (web `/api/public/metrics`, worker `/metrics`). |

## OpenBao paths to seed

| Path | Field | Notes |
|---|---|---|
| `kv/data/langfuse/clickhouse` | `password` | Operator generates random 32-char password at first install (`openssl rand -base64 32`). |
| `kv/data/langfuse/clickhouse` | `password_sha256_hex` | SHA-256 hex of the password (`echo -n <password> \| sha256sum`). The Altinity operator consumes this for ClickHouse user-config. |
| `kv/data/langfuse/postgres` | `password` | CNPG-issued; copy from the `langfuse-pg-app` Secret CNPG creates at cluster bootstrap. |
| `kv/data/langfuse/app` | `nextauth_secret` | 32+ random bytes (`openssl rand -base64 32`). |
| `kv/data/langfuse/app` | `salt` | Same. |
| `kv/data/langfuse/app` | `encryption_key` | 64-char hex (`openssl rand -hex 32`). |
| `kv/data/langfuse/app` | `telemetry_enabled` | Literal string `"false"`. |
| `kv/data/langfuse/s3` | `access_key_id`, `secret_access_key` | MinIO svc-account scoped to `langfuse-blobs` bucket. |
| `kv/data/cnpg/langfuse/s3-creds` | `access_key_id`, `secret_access_key` | MinIO svc-account scoped to `homelab-backups-cluster/cnpg/langfuse/`. Standard CNPG-app pattern. |

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync `infrastructure/cnpg/` | CNPG operator up. |
| Argo sync `infrastructure/clickhouse-operator/` | Altinity operator up + CRDs. |
| Argo sync `infrastructure/minio-on-nas/` (with `langfuse-blobs` bucket) | Bucket pre-created. |
| Operator seeds OpenBao paths above | ESO can populate Secrets. |
| Argo sync this layer | CNPG `langfuse-pg` cluster + Altinity `langfuse` chi + Langfuse helm release. ClickHouse + Postgres ready in 1–3 minutes; Langfuse migrations run on web pod startup. |
| Argo sync `observability/otel-collector/` (Langfuse exporter un-commented) | Gateway forwards OTLP to Langfuse `/api/public/otel`. |
| First workload emits OTLP | Spans appear in Langfuse Trace view. |

## Caveats

1. **Langfuse v3 → v4 migration** — chart 1.6.0 ships
   Langfuse v3 by default. v4 (the OTel-native SDK
   release) requires explicit chart values; check chart
   release notes at upgrade time.
2. **ClickHouse `password_sha256_hex` must match `password`**
   — operator-fillable; document the openssl recipe in cold-
   start.md to avoid mismatch.
3. **Single-replica ClickHouse** — pod eviction = brief
   trace-write interruption; Langfuse worker buffers via
   Redis. Scale-trigger to multi-replica if storage >100 GB
   OR query latency becomes user-visible.
4. **Telemetry disabled** — operator opts out of Langfuse
   Inc. anonymous telemetry per principle #2. Set in helm
   values + ESO-projected env (`TELEMETRY_ENABLED=false`).
5. **ClickHouse `readOnlyRootFilesystem: false`** — the
   ClickHouse server image writes config + temporary files
   to rootfs at startup. Volume mounts cover persistent
   state. The volume claim templates handle data-volume +
   log-volume separately.
6. **Cilium Gateway HTTPRoute deferred** — operator wires
   `langfuse.<HOMELAB_INTERNAL_DOMAIN>` per ADR 0024
   (Tailscale-only access). Until then, port-forward to the
   `langfuse-web` Service for UI access.
7. **Authentik OIDC integration deferred** — Langfuse helm
   values' `auth.oidc.*` block is not configured. Lands when
   Authentik is up + the `langfuse` OIDC client is created.
   Until then, default email/password auth (admin user
   created via `langfuse user create` at first install).

## Related

- [ADR 0021 D3](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — LLM-specific tracing + experiment + eval scope.
- [ADR 0028](../../../homelab-docs/02-decisions/0028-langfuse-deployment-shape.md)
  — Langfuse deployment shape: Altinity over official
  operator + OTel-as-instrumentation-contract.
- [`infrastructure/clickhouse-operator/`](../../infrastructure/clickhouse-operator/)
  — Altinity operator that reconciles `clickhouseinstallation.yaml`.
- [`observability/otel-collector/`](../otel-collector/)
  — gateway pushes OTLP traces here.
- [`observability/tempo/`](../tempo/) — sister tracing
  backend; same OTel Collector fans out to both.
- [99-journal/2026-05-01-langfuse-shape.md](../../../homelab-docs/99-journal/2026-05-01-langfuse-shape.md)
  — implementation journal.
