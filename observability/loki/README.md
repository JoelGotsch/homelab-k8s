# observability/loki

Loki — log aggregation per
[ADR 0021 D6 + D8](../../../homelab-docs/02-decisions/0021-observability-stack.md).

Monolithic deployment (single binary, single replica) — homelab
log volume doesn't justify simple-scalable / distributed
topologies. Chunks land in MinIO at the `loki-chunks` bucket
(pre-created by [infrastructure/minio-on-nas/](../../infrastructure/minio-on-nas/)).

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Pins grafana/loki chart 6.16.0. |
| `values.yaml` | SingleBinary mode, S3 backend → MinIO `loki-chunks`, 90d default retention, auth disabled (single-tenant cluster). Read/write/backend pods + caches + gateway disabled (saves replica count). |
| `externalsecret.yaml` | MinIO S3 svc-account creds from `kv/loki/s3-creds`. |
| `networkpolicy.yaml` | Ingress from Alloy + Falcosidekick + Grafana + Prometheus; egress to MinIO + kube-DNS. |
| `servicemonitor.yaml` | Self-metrics scrape via kube-prometheus-stack. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).
**Sequencing**: requires MinIO Healthy first (svc-account
provisioned via `mc admin user svcacct add`).

| Path | Keys | Source |
|---|---|---|
| `kv/loki/s3-creds` | `access_key_id`, `secret_access_key` | provisioned post-MinIO-Healthy via `mc admin user svcacct add` with read+write policy on `arn:aws:s3:::loki-chunks/*` |

**First-install seed (after MinIO + this layer's Argo sync):**

```sh
# Inside an mc-configured shell with MinIO root creds:
mc admin user svcacct add minio root \
  --policy <(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:*"],
    "Resource": [
      "arn:aws:s3:::loki-chunks",
      "arn:aws:s3:::loki-chunks/*"
    ]
  }]
}
EOF
)
# Capture printed access_key + secret_key:
bao kv put kv/loki/s3-creds \
  access_key_id="<access_key>" \
  secret_access_key="<secret_key>"

# Force-refresh ESO; restart Loki pod:
kubectl -n monitoring annotate externalsecret loki-s3-creds \
  force-sync=$(date +%s) --overwrite
kubectl -n monitoring rollout restart statefulset loki
```

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| [Step 9 — Cluster bring-up](../../../homelab-docs/04-guides/cold-start.md) | Cilium + Longhorn + ESO + Argo CD ready |
| Argo sync `infrastructure/minio-on-nas/` | MinIO + `loki-chunks` bucket ready |
| Operator runs MinIO svc-account bootstrap (above) | `kv/loki/s3-creds` populated |
| Argo sync this layer | Loki StatefulSet up; ESO projects creds; first chunks land in MinIO |
| Argo sync `observability/alloy/` | log streams start flowing |
| Argo sync `observability/kube-prometheus-stack/` (with Loki data source enabled) | Grafana queries Loki |
| Argo sync `observability/falco-stack/` (with Loki output enabled in values.yaml) | Falco events also retrospect-able |

## Caveats

1. **SingleBinary mode caps throughput.** For homelab volume
   (~1 GB/day estimated peak) it's fine; cluster nodes
   ingesting > ~10 MB/s of logs would push toward
   simple-scalable. Operator monitors via Loki's own
   `loki_distributor_lines_received_total` metric.

2. **`auth_enabled: false`** — single-tenant cluster, no
   X-Scope-OrgID needed. NetworkPolicy gates all ingress
   to known pods. Standard pattern for a single-tenant
   homelab Loki.

3. **`s3ForcePathStyle: true` + `insecure: true`** — required
   for MinIO (path-style URL form) + cluster-internal HTTP
   (no TLS termination on the MinIO endpoint at
   `minio.minio.svc.cluster.local:9000`). The bytes-in-flight
   stay within Cilium-mesh.

4. **90d default retention with 1y overrides for security-
   forensic streams** — Falco events (`{job="falcosidekick"}`),
   Hubble flows (`{job="hubble"}`), and audit-log units
   (`{unit=~".*audit.*"}`) extended to 1y per ADR 0021 D8.
   Operator adds further per-stream overrides in
   `values.yaml`'s `retention_stream` block as new
   security-forensic sources land (e.g., a future
   OpenBao-audit stream).

5. **Compactor retention deletes are async.** Setting
   `retention_period: 90d` doesn't immediately delete
   90+d-old chunks; the compactor sweeps periodically.
   Disk-usage on MinIO will lag the configured retention
   by ~1 retention cycle (default 10m). Acceptable.

6. **Loki PVC stores the WAL + index cache, not chunks.**
   20Gi is enough for the WAL window + recent index. If
   the StatefulSet pod restarts before WAL drains to S3,
   the PVC's WAL replays at startup. No chunk data loss.

7. **No HA at first install.** Single replica; pod
   eviction = log-shipping interruption (Alloy buffers
   client-side per its config). Multi-replica needs
   `replication_factor: 3` + simple-scalable mode +
   memberlist clustering — meaningful refactor at
   scale-trigger.

8. **Metrics cardinality for Loki itself** — the chart's
   default labels include `pod`, `instance`, `container`.
   At cluster scale the chunk-store metrics can blow up;
   watch `loki_chunk_store_index_entries_per_chunk` +
   `loki_chunks_created_total` cardinality at first week.

## Related

- [ADR 0021 D6 + D8](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — log aggregation choice + storage tiering.
- [observability/alloy/](../alloy/) — companion DaemonSet
  that ships node + pod logs to Loki.
- [observability/kube-prometheus-stack/](../kube-prometheus-stack/)
  — Grafana queries this Loki via the data source
  configured there.
- [observability/falco-stack/](../falco-stack/)
  — Falcosidekick has a Loki output (commented-out at
  scaffold; enabled by this layer's existence).
- [infrastructure/minio-on-nas/](../../infrastructure/minio-on-nas/)
  — chunk-storage backend; pre-created the `loki-chunks`
  bucket.
