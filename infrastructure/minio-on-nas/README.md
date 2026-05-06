# infrastructure/minio-on-nas

MinIO standalone instance backed by the Synology NAS
`cluster-backups` share. Acts as the S3-compatible substrate
for in-cluster backup pipelines.

Per
[backup-and-dr.md §Cluster Longhorn volumes (PVCs)](../../../homelab-docs/01-architecture/backup-and-dr.md)
and
[backup-and-dr.md §Postgres databases (CNPG)](../../../homelab-docs/01-architecture/backup-and-dr.md).

## Why in-cluster MinIO over NAS-side MinIO

Decided 2026-04-29. Two paths existed:

- **(a) MinIO running in cluster, PV backed by NFS share on
  NAS** — *chosen*. Lives inside the GitOps boundary, gets
  Argo-managed updates, ESO-managed credentials, Cilium
  NetworkPolicy enforcement. Pays write amplification over
  NFS but that amplification is on a path that's already
  bandwidth-bound by the 1 GbE NAS link in the current
  hardware (10 GbE upgrade per ADR 0020 reduces but does not
  eliminate).
- **(b) MinIO running on the NAS itself via Synology Container
  Manager** — *rejected*. Outside GitOps, manual updates,
  no NetworkPolicy, credentials live in DSM rather than
  OpenBao. Closer to bare metal but the operability tax is
  paid every operation.

(a) is consistent with ADR 0025's NAS-as-encrypted-bulk-substrate
philosophy: the NAS is a dumb byte sink; intelligence lives in
the cluster.

## Why standalone-mode

Distributed MinIO over a single NFS share is a known
anti-pattern: no parallelism benefit (one underlying disk
group), write amplification + lock contention. Multi-instance
MinIO is appropriate when each instance has its own local
disks. This deployment has one NAS share; one MinIO replica
suffices. Redundancy:

- **At NAS layer:** Synology RAID (per
  [hardware.md §nas](../../../homelab-docs/01-architecture/hardware.md)).
- **Off-cluster:** Restic CronJob replicates to friend's NAS
  (tier-2) + Hetzner Storage Box (tier-3) per
  [backup-and-dr.md](../../../homelab-docs/01-architecture/backup-and-dr.md).

MinIO itself is the **staging area**, not the source-of-truth.
The source is whatever wrote the backup (Longhorn snapshot,
CNPG WAL+base). Loss of the MinIO bucket means rebuilding
from those primaries; loss of the primaries plus MinIO means
restoring from tier-2/3.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Pins MinIO Helm chart (5.4.0). |
| `namespace.yaml` | `minio` namespace, restricted PSA. |
| `values.yaml` | Standalone mode, existing PVC, existing root secret, canonical buckets, no console exposure. |
| `pv.yaml` | Static PV bound to `/volume1/cluster-backups/minio` on the NAS via NFS CSI; PVC `minio-data` claims it. |
| `externalsecret.yaml` | Root credentials from OpenBao at `kv/data/minio-on-nas/root-creds`. |
| `networkpolicy.yaml` | Default-deny + allow from CNPG / Longhorn / Loki / Restic CronJob namespaces; egress to NAS NFS only. |

## Bootstrap

This layer's bring-up is wired into the homelab cold-start
sequence — **not a free-standing checklist**. Operators
following [cold-start.md](../../../homelab-docs/04-guides/cold-start.md)
will hit each prereq and seed step at the right moment:

| Bring-up step | What lands |
|---|---|
| [Step 8 — NAS bring-up](../../../homelab-docs/04-guides/cold-start.md) | `cluster-backups` share + `cluster-backups/minio/` subdir created (per [nas/initial-setup.md §Step 3](../../../homelab-docs/03-runbooks/nas/initial-setup.md)) |
| [Step 9 — Cluster bring-up](../../../homelab-docs/04-guides/cold-start.md) | NFS CSI, ExternalSecrets operator, OpenBao up + unsealed, ClusterSecretStore `openbao` reconciled, Argo CD bootstrapped |
| [Step 13a — Pre-rollout: render + check placeholders](../../../homelab-docs/04-guides/cold-start.md) | `<NAS-IP>` in `pv.yaml` + `networkpolicy.yaml` filled (`scripts/check-placeholders.sh` gates) |
| [Step 13c — Pre-rollout: seed ExternalSecret OpenBao paths](../../../homelab-docs/04-guides/cold-start.md) | `kv/minio-on-nas/root-creds` populated; per-app S3 service-accounts (`kv/cnpg/<app>/s3-creds`) provisioned post-MinIO-Healthy via `mc admin user svcacct add` (snippet inline in cold-start §13c) |

Argo CD then reconciles this layer; MinIO comes up Healthy.

**Verify (after Argo sync):**

```sh
kubectl -n minio get pods,pvc,secret
# Expect: 1 minio pod Running, minio-data PVC Bound,
# minio-root Secret present.

kubectl -n minio logs -l app=minio | tail -20
# Expect: 'API: http://...:9000', no errors mounting NFS.

# Bucket presence (port-forward console + login as root, or use mc):
kubectl -n minio port-forward svc/minio 9001:9001
# Browse https://localhost:9001 → expect 3 buckets:
# homelab-backups-cluster, longhorn-backups, loki-chunks.
```

Repaving / re-running this layer after the initial bring-up
follows the same dependency table — the cold-start steps are
re-runnable individually per
[cold-start.md §Re-running parts of the bring-up](../../../homelab-docs/04-guides/cold-start.md).

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).
ExternalSecret in `externalsecret.yaml` projects this into
the namespace; without it, MinIO does not start.

| Path | Keys | Source |
|---|---|---|
| `kv/minio-on-nas/root-creds` | `rootUser`, `rootPassword` | operator-generated, persisted; rotation = re-write + restart MinIO |

**First-install seed:**

```sh
ROOT_USER="minio-root-$(openssl rand -hex 4)"
ROOT_PASSWORD="$(openssl rand -base64 32)"
bao kv put kv/minio-on-nas/root-creds \
  rootUser="$ROOT_USER" \
  rootPassword="$ROOT_PASSWORD"
```

Per-app S3 service-account credentials live separately, each
owned by the consumer app's README. Their bootstrap depends
on MinIO being up — pattern is in §Per-app credentials below.

Currently provisioned per-app paths (extend as new
S3-consuming layers land):

- `kv/cnpg/<app>/s3-creds` — per-app CNPG WAL+base
  destination (one entry per app with a Postgres cluster).
- `kv/backup/minio-reader/s3-creds` — read-only svc-account
  for the Restic cronjob (per
  [infrastructure/backup-cronjobs/README](../backup-cronjobs/README.md)).
- `kv/loki/s3-creds` — Loki chunk storage scoped to the
  `loki-chunks` bucket (per
  [observability/loki/README](../../observability/loki/README.md)).

## Per-app credentials

The chart pre-creates buckets but does not provision per-app
service-account credentials (deliberately — `users:` in the
chart is too coarse for our policy needs). Operator creates
each per-app key with `mc admin user svcacct add` scoped to
the relevant bucket, then writes the access key + secret to
OpenBao.

Pattern (one-time per app):

```sh
# Inside an mc-configured shell with root creds.
mc admin user svcacct add minio root \
  --policy <(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:*"],
    "Resource": [
      "arn:aws:s3:::homelab-backups-cluster/cnpg/<app>/*",
      "arn:aws:s3:::homelab-backups-cluster/cnpg/<app>"
    ]
  }]
}
EOF
)
# Capture the printed access_key + secret_key, write to OpenBao:
bao kv put kv/cnpg/<app>/s3-creds \
  access_key_id="<access_key>" \
  secret_access_key="<secret_key>"
```

The app's own
`apps/<app>/cnpg-s3-externalsecret.yaml` then projects that
into the app namespace as a Secret consumed by the CNPG
Cluster CRD's `barmanObjectStore.s3Credentials` (see
[apps/llm-gateway/cnpg-s3-externalsecret.yaml](../../apps/llm-gateway/cnpg-s3-externalsecret.yaml)
for the canonical example).

When the per-app cluster count gets meaningful (>5), this
pattern becomes a candidate for automation — a
`scripts/bootstrap-app-bucket.sh` or a small operator that
watches Cluster CRD creation and provisions the matching
service-account. Out of scope for first install.

## Lifecycle policies

**Not configured here.** Bucket-side lifecycle (90-day expire,
versioning, etc.) lives in the consumer's own backup config:

- CNPG: `barmanObjectStore.retentionPolicy` per Cluster CRD.
- Longhorn: backup retention per RecurringJob.
- Loki: `compactor.retention_period` in Loki values.

Centralizing lifecycle here would couple consumer policy to
infra; keeping it consumer-side matches the principle that
each app owns its data lifecycle.

## Backup of MinIO itself

**Not configured.** MinIO is the staging area, not the source.
Its data is the *replicated* form of consumer backups; the
authoritative copies live in the consumer's own primary
storage (Longhorn volumes, CNPG WAL stream, etc.). Backing up
MinIO would be circular. Loss-of-MinIO recovery is "wait for
the next backup cycle from each consumer" + "Restic CronJob
re-pulls from tier-2/3 if needed for in-flight recovery."

The chart's metadata (bucket policies, access keys) is
re-bootstrappable from the kustomize manifests + ESO; nothing
to back up at the infra layer.

## Known caveats

- **NFS lock semantics over MinIO's metadata writes.** MinIO's
  internal `xl.meta` files are tiny per-object metadata
  blobs. NFSv4.1 handles them adequately at single-replica
  scale. Distributed mode would not.
- **Network is the bottleneck**, not CPU. CRS312 10 GbE
  upgrade per [ADR 0020](../../../homelab-docs/02-decisions/0020-switch-upgrade-to-10g-mikrotik.md)
  + 10Gtek X520-DA2 SFP+ NIC (per ADR 0020 D4 amendment) will
  materially help; pre-upgrade the path is 1 GbE.
- **No HA.** Single replica, single PV. A NAS reboot or NFS
  blip stalls all in-cluster backup writes for the duration.
  Acceptable: backups are not on the critical path; consumers
  retry. If sustained NAS unavailability becomes a pattern,
  the answer is fixing NAS reliability, not adding MinIO
  replicas.
- **Standalone-mode MinIO has different config surface vs
  distributed.** When chart updates ship distributed-only
  features (e.g. site replication), the values won't apply
  cleanly. Renovate-PR review at chart-bump time should sanity-
  check.
