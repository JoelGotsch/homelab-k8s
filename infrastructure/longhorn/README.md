# infrastructure/longhorn

In-cluster block storage per
[ADR 0016](../../../homelab-docs/02-decisions/0016-longhorn-for-cluster-storage.md).

## Layout

- `kustomization.yaml` — inflates upstream `longhorn` Helm chart.
- `values.yaml` — Helm values: `defaultReplicaCount: 2`,
  three storage classes (replica-1/2/3), backup target →
  MinIO-on-NAS `longhorn-backups` bucket.
- `storageclasses.yaml` — `longhorn-replica1`,
  `longhorn-replica2` (default), `longhorn-replica3` (ADR 0016 D2);
  the Retain variants `longhorn-replica2-retain` and
  `longhorn-replica3-retain` (ADR 0036 D1); and
  `longhorn-replica1-best-effort-retain` — one replica kept on the
  consumer's node, Retain — for Immich's hot data (ADR 0030 D2).
- `externalsecret.yaml` — projects
  `kv/longhorn/s3-creds` (MinIO svc-account scoped to
  `longhorn-backups`) into the `longhorn-minio-credentials`
  Secret with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
  `AWS_ENDPOINTS` keys consumed by Longhorn.
- `recurring-jobs.yaml` — class-aligned snapshot + backup
  RecurringJob CRs (see below).

## `defaultSettings` apply live — no longhorn-manager restart

Measured 2026-09-12 while setting `nodeDrainPolicy`. The chart renders
`defaultSettings` into the `longhorn-default-setting` ConfigMap, and
`longhorn-kubernetes-configmap-controller` **watches that ConfigMap** and calls
`applyCustomizedDefaultSettingsToDefinitions`, so a live `Setting` CR is rewritten
within about a minute of the Argo sync. Do not restart the DaemonSet to "make a
setting take" — one was restarted needlessly that day on the assumption it was
required.

Read the *Setting*, never the ConfigMap, when checking what is in force — and the
proof of which ConfigMap produced it is on the Setting itself:

```sh
kubectl -n longhorn-system get settings.longhorn.io node-drain-policy \
  -o jsonpath='{.value}{"\n"}{.metadata.annotations}{"\n"}'
#   allow-if-replica-is-stopped
#   {"longhorn.io/configmap-resource-version":"197393992"}   ← == the ConfigMap's rv
```

Two consequences. A hand-edited Setting is reverted to the ConfigMap's value
(`shouldApplyCustomizedSettingValue` writes whenever `setting.Value != value`), so
changes belong in `values.yaml`. And a transient
`Failed to syncing ConfigMap … the object has been modified; please apply your
changes to the latest version` warning in the manager log is the controller losing
an optimistic-concurrency race and retrying — benign, not a failed apply.

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

Cadence + retention per
[backup-and-dr.md §"Retention schedules"](../../../homelab-docs/01-architecture/backup-and-dr.md);
`recurring-jobs.yaml` is the source of truth and carries the
reasoning next to each job. Each PVC opts into a group via the
label `recurring-job-group.longhorn.io/<group>: enabled`. A volume
with no recurring-job label at all joins `default`.

| Group | Job | Cron (UTC) | Retain | Who |
|---|---|---|---|---|
| `default` | `snapshot-default` | `35 * * * *` | 6 | catch-all: small unique state without a class group |
| `secret-personal` | `snapshot-secret-personal` | `25 * * * *` | 20 | unique `secret`/`personal` data, e.g. OpenBao raft snapshots, Grist |
| `internal` | `snapshot-internal` | `35 */4 * * *` | 42 | Forgejo git data, ntfy |
| `internal-media` | `snapshot-internal-media` | `35 2 * * *` | 7 | Jellyfin config, nextcloud-hot |
| `backup` | `backup-daily` | `35 3 * * *` | 14 | opt-in NAS-MinIO backup, list in `scripts/label-backup-volumes.sh` |
| `no-snapshot` | `snapshot-delete-no-snapshot` | `35 4 * * *` | 0 | **no snapshots**: CNPG Postgres, telemetry, caches, scratch |
| all but `no-snapshot` | `filesystem-trim-weekly` | `35 5 * * 0` | – | weekly trim |
| `no-snapshot` | `filesystem-trim-no-snapshot` | `35 5 * * 6` | – | weekly trim, frees deleted snapshots' blocks too |

### Opting a volume out of snapshots

For a **new** PVC, the label is the whole change:

```yaml
metadata:
  labels:
    recurring-job-group.longhorn.io/no-snapshot: "enabled"
```

A CNPG `Cluster` puts it under `spec.inheritedMetadata.labels`.
The Kyverno `longhorn-volume-label-propagation` policy copies it
onto the Longhorn Volume when the volume is created, and a volume
that carries any recurring-job label never joins `default`.

For an **existing** volume, or a PVC whose manifest cannot carry
the label (a StatefulSet's `volumeClaimTemplates` are immutable),
also run:

```sh
scripts/sync-longhorn-no-snapshot.sh              # dry-run: what would change
scripts/sync-longhorn-no-snapshot.sh --apply      # converge
```

Kyverno and `sync-longhorn-recurring-job-labels.sh` only add
labels, so the old snapshot group would otherwise stay on the
Volume and keep snapshotting. The script removes it from PVC and
Volume, sets `spec.unmapMarkSnapChainRemoved: enabled` (trim then
frees the blocks the filesystem released *inside* the snapshot
behind the volume head, which a plain delete cannot reach — it does
not remove that snapshot, which has nowhere to coalesce while the
volume is live, so one stays per volume, marked removed), and holds
the declared list of PVCs that are labelled from the script
rather than a manifest. The existing snapshots go at the next
04:35 UTC run of `snapshot-delete-no-snapshot`, their blocks at
the next Saturday trim. A volume in `backup` cannot opt out:
`backup-daily` needs its last backup's snapshot. A snapshot taken by
hand on a `no-snapshot` volume does not survive the next delete run
or trim — take a CNPG or Longhorn backup before risky work instead.

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
