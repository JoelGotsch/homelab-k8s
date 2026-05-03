# infrastructure/longhorn

In-cluster block storage per
[ADR 0016](../../../homelab-docs/02-decisions/0016-longhorn-for-cluster-storage.md).

## Layout

- `kustomization.yaml` — inflates upstream `longhorn` Helm chart.
- `values.yaml` — Helm values: `defaultReplicaCount: 2`,
  three storage classes (replica-1/2/3), backup target →
  MinIO-on-NAS `longhorn-backups` bucket.
- `storageclasses.yaml` — `longhorn-replica1`,
  `longhorn-replica2` (default), `longhorn-replica3`. Per
  ADR 0016 D2.
- `externalsecret.yaml` — projects
  `kv/longhorn/s3-creds` (MinIO svc-account scoped to
  `longhorn-backups`) into the `longhorn-minio-credentials`
  Secret with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
  `AWS_ENDPOINTS` keys consumed by Longhorn.
- `recurring-jobs.yaml` — class-aligned snapshot + backup
  RecurringJob CRs (see below).

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Keys | Source |
|---|---|---|
| `kv/longhorn/s3-creds` | `access_key_id`, `secret_access_key` | provisioned post-MinIO-Healthy via `mc admin user svcacct add` per [minio-on-nas/README §Per-app credentials](../minio-on-nas/README.md). Scope to bucket `longhorn-backups` only. |

**First-install seed (paste before Step 13c-driven Argo
sync):**

```sh
homelab-infra/scripts/provision-minio-svcacct.sh \
    --alias minio \
    --kv-path kv/longhorn/s3-creds \
    --resource-prefix \
        "arn:aws:s3:::longhorn-backups/*" \
    --resource-prefix \
        "arn:aws:s3:::longhorn-backups" \
    --label longhorn
```

## RecurringJob class alignment

Cadence + retention table per
[backup-and-dr.md §"Retention schedules"](../../../homelab-docs/01-architecture/backup-and-dr.md).
Each PVC opts into a class group via the label
`recurring-job-group.longhorn.io/<group>: enabled`. Volumes
without an explicit group join `default` (the catch-all
hourly cadence — see below for trade-off).

| Group | Cron | Retain | Effective window | Class |
|---|---|---|---|---|
| `default` | `0 * * * *` | 168 | 7 days hourly | catch-all (matches secret/personal) |
| `secret-personal` | `0 * * * *` | 168 | 7 days hourly | Vaultwarden, OpenBao, Authentik (post-app-PVC retrofit) |
| `internal` | `0 */4 * * *` | 42 | 7 days @ 4-hourly | Forgejo, CrowdSec, llm-gateway |
| `internal-media` | `0 2 * * *` | 7 | 7 days daily | Jellyfin (multi-TB media) |
| `default` (`task: backup`) | `0 3 * * *` | 90 | 90-day backups in NAS-MinIO | all volumes |

**Per-app PVC labelling is a follow-up** — TODO sub-item under
the backup gap-check parent. Today most stateful PVCs lack
the `recurring-job-group.longhorn.io/<group>: enabled` label
and therefore land in `default` (hourly snapshots). That's
safe-by-default but over-snapshots Jellyfin's media volumes.
Class assignment lands as the consumer apps are revised.

## Backup pipeline

Per ADR 0016 D4 + ADR 0006:

```
Longhorn volume ──snapshot──▶ local snapshot (Longhorn-native)
                              │
                              └──daily backup──▶ MinIO-on-NAS
                                                  `longhorn-backups`
                                                  │
                                  ┌───────────────┘
                                  ▼
                       Restic CronJob (infrastructure/backup-cronjobs/)
                                  │
                       ┌──────────┴──────────┐
                       ▼                     ▼
                Friend's NAS           Hetzner Storage Box
                (tier-2; 90d)          (tier-3; 365d + monthly)
```

Volume-level Longhorn backup catches the "entire PVC needs to
come back" case; CNPG `barmanObjectStore` (per-app) catches
the "one DB row got corrupted" case via WAL replay. The two
mechanisms are complementary per ADR 0016 D4.
