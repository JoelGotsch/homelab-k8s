# infrastructure/cnpg-barman-plugin

The [Barman Cloud CNPG-I plugin](https://cloudnative-pg.io/plugin-barman-cloud/):
the backup and WAL-archiving path for every CloudNativePG database in
this cluster, replacing the in-core `spec.backup.barmanObjectStore`
support that CloudNativePG removes in **1.31.0**.

Migration procedure (phases, per-cluster gates, rollback):
[barman-plugin-migration.md](../../../homelab-docs/03-runbooks/cnpg/barman-plugin-migration.md).

## Layout

- `kustomization.yaml` — pins the `plugin-barman-cloud` Helm chart
  (chart `0.7.1` → plugin `v0.14.0`), same chart repo as the operator.
- `values.yaml` — explicit `resources` (mandatory: no LimitRange in
  `cnpg-system` + Kyverno `homelab-disallow-unlimited-containers`).

The namespace itself is owned by [../cnpg](../cnpg) — this layer only
adds workloads to it, at the same sync wave (-10), so the plugin is
available before any app-layer `Cluster` reconciles.

## What it installs

| Object | Name | Note |
|---|---|---|
| CRD | `objectstores.barmancloud.cnpg.io` | the per-cluster backup target |
| Deployment | `barman-cloud-plugin-barman-cloud` | gRPC plugin the operator calls |
| Service | `barman-cloud:9090` | carries the `cnpg.io/plugin*` discovery annotations |
| ConfigMap | `plugin-barman-cloud-config` | `SIDECAR_IMAGE` for the injected sidecar |
| Issuer + 2 Certificates | `selfsigned-issuer`, `barman-cloud-{client,server}` | cert-manager, namespace-local |
| RBAC | SA + Cluster/Role bindings | plugin reads Backups, patches Clusters |

## Consumer pattern

An app that needs a backup lane declares an `ObjectStore` in its own
namespace and references it from its `Cluster`. Credentials are the
same ESO-projected `<app>-cnpg-s3` Secret used before the migration —
no new OpenBao paths, which is why this layer has no
"OpenBao paths to seed" section.

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: <app>-backups
  namespace: <app>
spec:
  retentionPolicy: 30d          # moved here from Cluster.spec.backup
  configuration:
    destinationPath: s3://homelab-backups-cluster/cnpg/<app>
    endpointURL: http://minio.minio-on-nas.svc.cluster.local:9000
    s3Credentials:
      accessKeyId:
        name: <app>-cnpg-s3
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: <app>-cnpg-s3
        key: SECRET_ACCESS_KEY
    wal:
      compression: bzip2
    data:
      compression: bzip2
  instanceSidecarConfiguration:
    resources:                  # never omit — see values.yaml
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        memory: 1Gi
---
# in the Cluster:
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: <app>-backups
---
# in the ScheduledBackup:
spec:
  method: plugin
  target: prefer-standby        # was inherited from spec.backup.target
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

`serverName` stays unset: the plugin derives it from the Cluster name,
which is what the existing S3 prefixes already use — that is what makes
the migration continuous rather than a fresh backup chain.

## Caveats

- **The switch is atomic per cluster.** The Cluster CRD refuses
  `plugins[].isWALArchiver: true` while `spec.backup.barmanObjectStore`
  is still present, so removing the old block and adding the plugin
  must land in one commit. There is no dual-write window.
- **`kubectl get backup` is ambiguous here** — `longhorn.io` shadows
  `postgresql.cnpg.io`. Use `kubectl get backups.postgresql.cnpg.io`;
  the short form silently reports Longhorn's (empty) list, and
  `kubectl explain backups.spec` documents the wrong schema.
- **Backup metrics change name** with the migration:
  `cnpg_collector_last_*_backup_timestamp` →
  `barman_cloud_cloudnative_pg_io_last_*_backup_timestamp`. Both are
  scraped through the instance endpoint on :9187 (see
  [../cnpg/podmonitor-instances.yaml](../cnpg/podmonitor-instances.yaml)
  and the 9187 entry in the Prometheus egress allowlist).
