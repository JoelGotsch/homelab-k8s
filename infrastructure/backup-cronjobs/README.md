# infrastructure/backup-cronjobs

Scheduled jobs that replicate MinIO bucket contents to
off-cluster storage with client-side encryption.

Per
[backup-and-dr.md §Cluster Longhorn volumes (PVCs)](../../../homelab-docs/01-architecture/backup-and-dr.md)
and
[backup-and-dr.md §Postgres databases (CNPG)](../../../homelab-docs/01-architecture/backup-and-dr.md)
+ [ADR 0006](../../../homelab-docs/02-decisions/0006-hybrid-backup-topology.md).

## Pipelines

| CronJob | Source | Target tier | Encryption | Schedule | Status |
|---|---|---|---|---|---|
| `restic-minio-to-hetzner` | MinIO buckets `homelab-backups-cluster` + `longhorn-backups` | tier-3 — Hetzner Storage Box | Restic client-side (operator's password) | 02:00 UTC daily | scaffolded 2026-04-29 |
| `restic-minio-to-friends-nas` | _same_ | tier-2 — friend's NAS | _same_ | _TBD_ | **not scaffolded** — depends on friend's-NAS hardware ship; sibling CronJob with the same shape pointing at a different Restic repo |

`loki-chunks` is intentionally *not* mirrored — Loki retention
is configured in its own values; loss of historical Loki data
is acceptable per [ADR 0021](../../../homelab-docs/02-decisions/0021-observability-stack.md).

## Why a per-target CronJob, not one job with two repos

Restic snapshots are tied to repository state. Writing the
same `restic backup` invocation to two repos sequentially
couples their failure modes — a SFTP hiccup at Hetzner stalls
or aborts the whole job, and the friend's-NAS replica falls
behind the same window. Independent CronJobs cap the blast
radius of any single target's outage.

The mirror step (`mc mirror` MinIO → staging PVC) is
duplicated per CronJob. Each CronJob has its own staging PVC.
At the cost of redundant cluster I/O, fault isolation between
backup destinations.

## Restic mirror+backup design

Each pod runs:

1. **Init container** (`minio/mc`): `mc mirror --remove --overwrite`
   from the in-cluster MinIO endpoint to a Longhorn-replica1
   PVC. Incremental — only new/changed/deleted bucket objects
   are touched. Persistent PVC = `mc mirror` finds prior state
   to compare against, avoiding full re-copy each run.
2. **Main container** (`restic/restic`): `restic backup`
   the staging tree to the SFTP backend, tagged
   `tier-3 + automated`. Then `restic forget --prune` per
   retention policy.

Sizing the staging PVC: 50Gi starter. Operator resizes (online
via Longhorn) as cluster backup volume grows. Alert if
`mc mirror` cannot complete within `activeDeadlineSeconds`
(currently 6h).

### Why `mc mirror` not `restic backup` of an S3 mount

Restic doesn't natively back up S3 sources — its backend mode
is "where the repo lives," not "what to back up." Options
considered:

- **`s3fs` / `goofys` FUSE mount** of MinIO bucket, point
  Restic at the mount path. Adds a FUSE dependency + a
  network round-trip per file Restic stats; brittle under
  partial NFS-mount failures.
- **`rclone` instead of Restic**. rclone has built-in
  encryption + direct bucket-to-SFTP. Rejected:
  [backup-and-dr.md](../../../homelab-docs/01-architecture/backup-and-dr.md)
  pins Restic specifically — its content-addressable dedup
  is load-bearing for tier-3 storage cost
  ([Hetzner Storage Box pricing tier matters at the
  10TB+ scale](../../../homelab-docs/01-architecture/backup-and-dr.md)).
- **MinIO's own bucket replication.** Server-side encryption
  only (no client-side at the cluster boundary). Doesn't
  meet the "operator-controlled encryption keys" requirement
  per [ADR 0006](../../../homelab-docs/02-decisions/0006-hybrid-backup-topology.md).

## Retention policy

Tier-3 retains 365d + monthly-forever for `personal+` per
[backup-and-dr.md](../../../homelab-docs/01-architecture/backup-and-dr.md).
Restic `forget --prune` translation:

```
--keep-daily 30      # last 30 days
--keep-weekly 12     # 12 weeks of weeklies
--keep-monthly 120   # 10 years of monthlies (de-facto "forever")
--keep-yearly 10     # 10 years of yearlies
--keep-tag preserve  # snapshots tagged 'preserve' never get pruned
```

Manual `preserve`-tagging covers anything we want pinned past
10 years. Workflow: `restic tag --add preserve <snapshot-id>`.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Plain kustomize (no Helm chart). |
| `namespace.yaml` | `backup-cronjobs` namespace, restricted PSA. |
| `pvc.yaml` | Staging PVC (50Gi starter, longhorn-replica1, online-resizable). |
| `externalsecret.yaml` | Restic password + Hetzner SB SSH creds + MinIO read-only S3 creds, all from OpenBao. |
| `cronjob.yaml` | Daily 02:00 UTC. Init container mirrors MinIO; main container runs Restic backup + forget --prune. |
| `networkpolicy.yaml` | Default-deny + egress to MinIO (in-cluster) + WAN ports 22/23 (Hetzner SFTP) + kube-DNS. |

## Bring-up

This layer's bring-up is wired into
[cold-start.md](../../../homelab-docs/04-guides/cold-start.md)
— specifically Step 13c (OpenBao seeding) covers the
secrets prerequisites; the layer applies via Argo CD as part
of the Step 13 wave.

| Bring-up step | What lands |
|---|---|
| [Step 9 — Cluster bring-up](../../../homelab-docs/04-guides/cold-start.md) | NFS CSI, Longhorn, ESO, OpenBao, Argo CD ready |
| [infrastructure/minio-on-nas/](../minio-on-nas/) sync wave | MinIO Healthy; the source buckets exist |
| [Step 13c — Seed ExternalSecret OpenBao paths](../../../homelab-docs/04-guides/cold-start.md) | `prod/restic/cluster-tier-3/password`, `prod/backup/hetzner-storage-box`, `prod/backup/minio-reader/s3-creds` populated |
| Argo sync | This layer reconciles; first scheduled run is at 02:00 UTC after sync completes |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).
ExternalSecrets in `externalsecret.yaml` project these into
the namespace; without them, the CronJob's pods stay
`CreateContainerConfigError`.

| Path | Keys | Source |
|---|---|---|
| `kv/prod/restic/cluster-tier-3/password` | `value` | `openssl rand -base64 32`. **Persist to offline-recovery archive** per [ADR 0011](../../../homelab-docs/02-decisions/0011-distributed-offline-recovery.md) — loss = no decrypt of any tier-3 snapshot. |
| `kv/prod/backup/hetzner-storage-box` | `host`, `user`, `port`, `ssh_key`, `ssh_known_host` *(optional)* | from Hetzner Robot account; SSH key is operator-generated ed25519 keypair, public half added to Storage Box console. **Reused** by openbao raft-snapshot-cronjob. The `ssh_known_host` field is the post-TOFU pinned host-key — see "Host-key pinning" below. |
| `kv/prod/backup/minio-reader/s3-creds` | `access_key_id`, `secret_access_key` | provisioned post-MinIO-Healthy via `mc admin user svcacct add` with **read-only** policy on `homelab-backups-cluster` + `longhorn-backups` buckets. |

**First-install seed (after MinIO + OpenBao are Healthy):**

```sh
# Restic repo password — generate + seed + print so operator
# can persist to offline-recovery archive (loss = no decrypt
# of any tier-3 snapshot per ADR 0011).
homelab-infra/scripts/seed-random-secret.sh \
    --print --format base64 --size 32 \
    kv/prod/restic/cluster-tier-3/password value
# Operator manually persists the printed value to the archive
# per offline-recovery/rotation.md, then clears scrollback.

# Hetzner SB SSH key — operator-generated keypair (host-side
# correlation matters; not pure randomness). Keep manual:
ssh-keygen -t ed25519 -f /tmp/hetzner-sb -N ''
# Add /tmp/hetzner-sb.pub to Hetzner Robot → Storage Box → SSH Keys
bao kv put kv/prod/backup/hetzner-storage-box \
  host="u123456.your-storagebox.de" \
  user="u123456" \
  port="23" \
  ssh_key="$(cat /tmp/hetzner-sb)"
shred -u /tmp/hetzner-sb /tmp/hetzner-sb.pub

# MinIO read-only svc account — provisioned + seeded:
homelab-infra/scripts/provision-minio-svcacct.sh \
    --alias minio \
    --kv-path kv/prod/backup/minio-reader/s3-creds \
    --policy-actions "s3:GetObject,s3:ListBucket" \
    --resource-prefix arn:aws:s3:::homelab-backups-cluster \
    --resource-prefix arn:aws:s3:::homelab-backups-cluster/* \
    --resource-prefix arn:aws:s3:::longhorn-backups \
    --resource-prefix arn:aws:s3:::longhorn-backups/* \
    --label backup-minio-reader
```

Manual fallback for the MinIO svcacct (e.g., if `--policy-actions`
doesn't fit):

```sh
mc alias set minio http://minio.minio.svc.cluster.local:9000 \
  "$ROOT_USER" "$ROOT_PASSWORD"
mc admin user svcacct add minio root \
  --policy <(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::homelab-backups-cluster",
      "arn:aws:s3:::homelab-backups-cluster/*",
      "arn:aws:s3:::longhorn-backups",
      "arn:aws:s3:::longhorn-backups/*"
    ]
  }]
}
EOF
)
bao kv put kv/prod/backup/minio-reader/s3-creds \
  access_key_id="<access_key>" \
  secret_access_key="<secret_key>"
```

## Verify

After Argo sync + first scheduled run completes:

```sh
# CronJob ran at least once:
kubectl -n backup-cronjobs get jobs -l app.kubernetes.io/name=restic-tier-3
# Most recent should be Complete; last few minutes ago.

# Check the pod log of the last run:
kubectl -n backup-cronjobs logs job/<latest-job-name> -c mirror-minio
# Expect: '=== mirror src/<bucket> → /staging/<bucket> ==='
#         '=== mirror complete: NNg staged ==='
kubectl -n backup-cronjobs logs job/<latest-job-name> -c restic
# Expect: 'snapshots' line with the new snapshot ID.

# Snapshot list from a manual restic invocation:
kubectl -n backup-cronjobs run -it --rm restic-shell \
  --image=restic/restic:0.17.3 --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000}},"containers":[{"name":"restic-shell","image":"restic/restic:0.17.3","stdin":true,"tty":true,"envFrom":[{"secretRef":{"name":"hetzner-sb-creds"}}]}]}' \
  -- /bin/sh
# (then export RESTIC_REPOSITORY + RESTIC_PASSWORD and run restic snapshots)
```

## Restore drill

The first restore drill is mandatory before declaring tier-3
operational, per
[backup-restore-test.md](../../../homelab-docs/03-runbooks/backup-restore-test.md)
and
[backup-and-dr.md §Drills](../../../homelab-docs/01-architecture/backup-and-dr.md).
Workflow:

1. Pick a small recent snapshot (e.g., a CNPG WAL segment).
2. `restic restore <snapshot-id> --target /tmp/restore`.
3. Verify content — for CNPG, this is a `barman-cloud-restore`
   target.
4. Run `restic check --read-data-subset=10%` to validate
   integrity of a sample of the chunks (full check is slow on
   large repos; subset is enough for confidence).

Cadence: per
[quarterly-checklist.md](../../../homelab-docs/05-security/audit/quarterly-checklist.md)
backup-restore rotation.

## Host-key pinning

The cronjob's `~/.ssh/known_hosts` is generated per run.
Two modes (auto-selected):

- **Pinned** (preferred): operator captures the Hetzner SB
  host fingerprint at first manual SSH and writes it to
  OpenBao. Cronjob uses it.
- **TOFU** (default at first install): cronjob runs
  `ssh-keyscan` each invocation. Accepts whatever the
  host presents — vulnerable to MITM at first run.

### Capture + pin procedure (one-time)

```sh
# 1. From a Tier A host, SSH to the Storage Box once to
#    populate operator's local known_hosts:
ssh -p 23 u123456@u123456.your-storagebox.de
# Accept the host key prompt; ssh adds the line to
# ~/.ssh/known_hosts.

# 2. Capture the line:
KNOWN_HOST=$(ssh-keygen -F "[u123456.your-storagebox.de]:23" -f ~/.ssh/known_hosts | grep -v '^#' | head -1)
echo "$KNOWN_HOST"
# Expect: `[u123456.your-storagebox.de]:23 ssh-ed25519 AAAA...`

# 3. Sanity-check: should be ssh-ed25519 (Hetzner's default
#    host key type as of mid-2025; if rsa, that's fine too).

# 4. Write to OpenBao:
bao kv patch kv/prod/backup/hetzner-storage-box \
  ssh_known_host="$KNOWN_HOST"

# 5. Force-refresh ESO so the cronjob picks up the new field:
kubectl -n backup-cronjobs annotate externalsecret \
  hetzner-sb-creds force-sync=$(date +%s) --overwrite
kubectl -n openbao annotate externalsecret \
  hetzner-sb-creds force-sync=$(date +%s) --overwrite

unset KNOWN_HOST
```

### Verifying the pin works

Trigger an off-schedule cronjob run + watch logs:

```sh
# Manually create a Job from the CronJob template (so we
# don't wait for 02:00 UTC):
kubectl -n backup-cronjobs create job --from=cronjob/restic-minio-to-hetzner \
  test-pin-$(date +%s)

# Tail logs of the resulting pod:
kubectl -n backup-cronjobs logs -f job/test-pin-<...> -c restic
# Expect: no `ssh-keyscan` invocation; ssh connects directly.
# Restic backup + forget proceed normally.
```

If the pin is wrong (capture typo, key rotated upstream),
SSH fails with "Host key verification failed." Recovery:
re-capture the current key + re-write to OpenBao.

### When to re-capture

- Hetzner rotates the SB host key (rare; communicated via
  Hetzner status page).
- Operator migrates to a different SB.
- Operator suspects the captured value is wrong (MITM at
  capture time, ssh-keyscan output rather than real
  fingerprint, etc.).

Annual quarterly-checklist line item: confirm the pinned
value still matches what `ssh-keyscan` returns. If
divergence: investigate (legitimate rotation vs MITM).

## Known caveats

- **Host-key trust path:** the cronjob picks between two
  modes based on whether `SSH_KNOWN_HOST` is set:
  - **Pinned** (post-TOFU, preferred): if
    `kv/prod/backup/hetzner-storage-box` has the
    `ssh_known_host` field set, the cronjob writes that
    line directly to `~/.ssh/known_hosts` and SSH refuses
    to connect to a host with a different key.
  - **TOFU** (first-install fallback): if unset, the
    cronjob `ssh-keyscan`s and accepts whatever the host
    presents.

  See "Host-key pinning" below for the operator capture
  procedure. **Pinning is the recommended posture** —
  TOFU is only for the bring-up window.
- **Restic password loss = total tier-3 data loss.** Repo
  cannot be recreated without it. Archive copy in
  offline-recovery is mandatory; OpenBao copy alone is not
  enough (chicken-and-egg on cluster recovery — OpenBao
  itself restores from tier-3 in the disaster path).
- **`mc mirror --remove` syncs deletions from MinIO to
  staging PVC.** A bucket-side mass-delete (whether
  intentional or attacker-driven) propagates to staging on
  the next mirror run. Restic snapshots don't auto-delete —
  prior snapshots remain valid until `forget --prune` runs
  past their retention. Recovery from a malicious
  bucket-wipe: restore from a Restic snapshot taken before
  the wipe.
- **PVC sizing surfaces only via timeout, not via PVC fill
  alert.** If staging fills up, `mc mirror` errors out and
  the job fails — the alert path is "job failure" not
  "PVC near full." Worth a future PrometheusRule on
  `kubelet_volume_stats_used_bytes` for this PVC.
- **Read-only filesystem + Restic cache.** Restic uses
  `~/.cache/restic`. The pod sets `HOME=/tmp` and mounts a
  Memory-backed emptyDir at `/tmp` (256Mi). For very large
  repos the cache may exceed this; symptom is performance
  degradation. Operator increases `tmp` sizeLimit if needed.
- **Single-CronJob ergonomics; no per-bucket isolation.** A
  malformed object in `longhorn-backups` could fail the
  whole job and stall `homelab-backups-cluster` backup. If
  this becomes a real failure mode, split into two
  CronJobs (one per source bucket), accepting the extra
  cluster I/O.
- **`failedJobsHistoryLimit: 5` retains the last 5 failed
  Job records.** Operator should review (`kubectl -n
  backup-cronjobs get jobs --sort-by=.status.startTime |
  tail -10`) at least quarterly; a steady failure rate
  indicates a deeper issue (network egress, Hetzner SB
  reachability, expired SSH key).

## Tier-2 sibling (when friend's NAS arrives)

When the friend's-NAS hardware ship is complete and the
WireGuard tunnel + restic-server are up per
[friends-nas-setup.md](../../../homelab-docs/03-runbooks/friends-nas-setup.md),
add a sibling `cronjob-friends-nas.yaml` with:

- Different namespace? — no, same; same secret store, same
  staging PVC pattern (separate PVC instance).
- Different `RESTIC_REPOSITORY` — `rest:https://...` for the
  rest-server backend instead of SFTP.
- Different OpenBao path — `kv/prod/restic/cluster-tier-2/password`.
- Different schedule — stagger from tier-3 (e.g., 04:00 UTC
  to follow tier-3's typical completion) to avoid contending
  for staging cluster I/O.

The mirror step (`mc mirror`) is the same; consider extracting
to a shared script or accepting duplication for now.
