# infrastructure/cnpg

CloudNativePG operator. Per
[ADR 0011](../../../homelab-docs/02-decisions/0011-distributed-offline-recovery.md)
(implicit — CNPG over Bitnami pg-ha) and
[backup-and-dr.md §Postgres databases (CNPG)](../../../homelab-docs/01-architecture/backup-and-dr.md).

## Layout

- `kustomization.yaml` — pins the cloudnative-pg Helm chart;
  installs operator + CRDs.
- `values.yaml` — operator config: PodMonitor on, inherited
  Argo annotations + app.kubernetes.io labels onto generated
  resources, conservative resource limits.
- `namespace.yaml` — `cnpg-system` namespace with restricted
  PSA.

## Consumer pattern

Each app that needs Postgres creates a `cnpg-cluster.yaml`
under its own kustomize layer (e.g.
[apps/llm-gateway/cnpg-cluster.yaml](../../apps/llm-gateway/cnpg-cluster.yaml))
and a sibling `cnpg-s3-externalsecret.yaml` that pulls MinIO
backup creds from OpenBao.

Skeleton:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: <app>
  namespace: <app>
spec:
  instances: 2
  storage:
    size: <size>
    storageClass: longhorn-replica3   # CNPG primaries per ADR 0016
  monitoring:
    enablePodMonitor: true
  bootstrap:
    initdb:
      database: <db>
      owner: <owner>
  backup:
    barmanObjectStore:
      destinationPath: s3://homelab-backups-cluster/cnpg/<app>
      endpointURL: http://minio.minio-on-nas.svc.cluster.local:9000
      s3Credentials:
        accessKeyId:    { name: <app>-cnpg-s3, key: ACCESS_KEY_ID }
        secretAccessKey: { name: <app>-cnpg-s3, key: SECRET_ACCESS_KEY }
      wal:  { compression: bzip2 }
      data: { compression: bzip2 }
    retentionPolicy: "90d"
```

Storage-class choice per ADR 0016: CNPG primaries opt into
`longhorn-replica3` because the data is the authoritative
copy at any given moment, and CNPG's own `instances: 2` only
covers DB-level redundancy, not disk-level.

## Backup pipeline

Per
[backup-and-dr.md §Postgres databases (CNPG)](../../../homelab-docs/01-architecture/backup-and-dr.md):

1. Continuous WAL archive → MinIO-on-NAS (per-cluster bucket
   path).
2. Daily base backup → same MinIO bucket. 90 d local retention.
3. MinIO bucket → tier-2 (friend's NAS) + tier-3 (Hetzner)
   via the shared Restic CronJob (configured under
   infrastructure once MinIO + the CronJob land).

**Sequencing caveat**: WAL archiving needs MinIO-on-NAS up
first. Pre-MinIO, comment the `backup:` block out of the
Cluster CRD; the cluster comes up without backups (acceptable
for `internal`-class data during bootstrap; `secret` /
`personal`-class data MUST have backups configured before
any write — gate the app's first sync on this).

## Open follow-ups

- ✅ `homelab-k8s/infrastructure/minio-on-nas/` —
  [scaffolded](../minio-on-nas/) 2026-04-29; standalone MinIO
  on the NAS `cluster-backups` share, canonical buckets
  (`homelab-backups-cluster`, `longhorn-backups`,
  `loki-chunks`) pre-created. Per-app S3 service-account
  credentials are operator-bootstrapped via `mc admin user
  svcacct add` (pattern in
  [minio-on-nas/README.md §Per-app credentials](../minio-on-nas/README.md)).
- ✅ Restic CronJob for the MinIO → tier-3 hop —
  [scaffolded](../backup-cronjobs/) 2026-04-29 as
  `restic-minio-to-hetzner`. Tier-2 sibling
  (`restic-minio-to-friends-nas`) blocks on friend's-NAS
  hardware ship; pattern documented in
  [backup-cronjobs/README §Tier-2 sibling](../backup-cronjobs/README.md).
- Per-app `cnpg-cluster.yaml` for Vaultwarden, Nextcloud,
  Langfuse — added when those apps' kustomize layers are
  scaffolded. Currently only `apps/llm-gateway/` exists.
