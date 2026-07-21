# platform/openbao

OpenBao — secret-management substrate for the cluster. The
authoritative store for everything classified `secret` per
[ADR 0003](../../../homelab-docs/02-decisions/0003-data-classification.md).
Per [ADR 0018](../../../homelab-docs/02-decisions/0018-openbao-deployment-shape.md):
in-cluster 3-replica Raft, manual Shamir 2-of-3 unseal,
cert-manager TLS, daily Raft snapshot to Hetzner Storage
Box.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Pins the `openbao` Helm chart; assembles the resources below. |
| `values.yaml` | HA Raft mode, 3 replicas, TLS, audit log, listener config. |
| `httproute.yaml` | Internal HTTPRoute (Tailscale-only — operator reaches the UI / API via tailnet). |
| `snapshot-serviceaccount.yaml`, `snapshot-auth.sh` | Dedicated, no-automount workload identity. Each Job exchanges a 15-minute, `audience=openbao` projected JWT for a fixed-TTL batch token carrying only the `snapshot` policy. |
| `snapshot-token-rollback-bridge.yaml` | Temporary, unused rollback bridge retaining the already-issued static token while rollout evidence accrues. Remove only after the one-off, natural hourly/daily, remote-checksum, and restore gates pass; never issue a replacement. |
| `raft-snapshot-cronjob.yaml`, `snapshot-upload.sh` | Daily 03:05 UTC snapshot, SHA-256 verification, atomic SCP publish, and remote checksum comparison on Hetzner Storage Box port 23. Snapshot and upload run in separate containers; only the verified snapshot and checksum cross their shared fsGroup at mode `0640`, while the uploader cannot read the OpenBao JWT/token or init-only scratch. |
| `raft-snapshot-hourly.yaml` | Hourly snapshot to a local Longhorn PVC (`openbao-raft-snapshots`, 10Gi, replica2), 168 retain (= 7d), with an owner-only (`0600`) checksum sidecar per file. |
| `snapshot-networkpolicy.yaml`, `snapshot-prometheusrule.yaml` | No-ingress and exact egress policy plus failed/stale snapshot alerts. The daily policy sends only kube-dns TCP/UDP 53 through Cilium's L7 DNS proxy so its Storage Box `toFQDNs` rule can learn the resolved IP; hourly has no FQDN rule and remains L3/L4-only. Jobs and redacted termination evidence are retained for 24 hours. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).
The daily CronJob projects the Storage Box credential into the
openbao namespace; without it only the off-site tier stays in
`CreateContainerConfigError`. Snapshot authentication itself
does not use an ExternalSecret. The separate rollback bridge keeps the old
ExternalSecret temporarily, but neither snapshot workload references its Secret.

**Caveat — chicken-and-egg.** OpenBao is the OpenBao backend
itself. The first-install seeds below are only writable AFTER
OpenBao is up and the operator has performed the manual
`bao operator init` + Shamir unseal ceremony per
[cluster/argocd-bootstrap.md](../../../homelab-docs/03-runbooks/cluster/argocd-bootstrap.md)
Step 4. The CronJob waits unhealthy until the seeds land —
that's expected on day one.

| Path | Keys | Source |
|---|---|---|
| `kv/prod/backup/hetzner-storage-box` | `ssh_key` | from Hetzner Robot account. Host, account name, and port are non-secret routing configuration pinned in the workload and checked against its Cilium policy and public host keys. Port 23 is required for the documented remote `sha256sum`. The public host keys are versioned in `snapshot-uploader-config.yaml` and kept byte-identical to [infrastructure/backup-cronjobs/](../../infrastructure/backup-cronjobs/). |

**Snapshot authentication is day-two configuration, not a KV seed.** Run
`homelab-infra/scripts/configure-openbao-snapshot-auth.sh --apply` after OpenBao's
Kubernetes auth method exists. That convergent script owns the exact one-path/read-only
policy and the exact ServiceAccount/namespace/audience-bound role. The old static
snapshot-token rollback bridge must be revoked and its KV entry removed only after a one-off
Job, one natural hourly schedule, one natural daily upload, and a restore rehearsal
all pass. Never issue a replacement long-lived token.

**Remaining first-install seed (after OpenBao initialized + unsealed):**

```sh
# Hetzner SB SSH key (one-time; reused by backup-cronjobs).
# Skip if already populated by the backup-cronjobs bring-up.
ssh-keygen -t ed25519 -f /tmp/hetzner-sb -N ''
# Add /tmp/hetzner-sb.pub to Hetzner Robot → Storage Box → SSH Keys.
# Patch only this key: `kv put` would erase the host/user/known-host fields
# consumed by the independent backup-cronjobs lane.
bao kv patch -mount=kv prod/backup/hetzner-storage-box \
  ssh_key="$(cat /tmp/hetzner-sb)"
shred -u /tmp/hetzner-sb /tmp/hetzner-sb.pub
```

## Raft snapshot retention

Two-tier shape per ADR 0018 D5 + backup-and-dr.md §"OpenBao":

- **Tier-1 (hourly, local)** — `raft-snapshot-hourly.yaml`
  saves to PVC `openbao-raft-snapshots`, retains 168 (= 7d).
  Recovery floor for cluster-internal incidents (accidental
  delete, transient corruption); no network round-trip.
- **Tier-3 (daily, remote)** — `raft-snapshot-cronjob.yaml`
  scps a fresh snapshot to Hetzner Storage Box. Recovery floor
  for cluster-loss / DR scenarios.

`snapshot-auth.sh` keeps its token, partial output, and all scratch owner-only under
`umask 077`. After local SHA-256 verification, the daily init container publishes
only the final snapshot and sidecar as `0640`; producer UID 100 and uploader UID
1000 share group/fsGroup 1000. The hourly single-container path explicitly keeps
its final files at `0600`.

Tier-2 (friend's NAS) intentionally does **not** receive
OpenBao snapshots — the seal already makes them opaque-and-
encrypted, so tier-2's dedup buys nothing. Direct `scp` to
Hetzner SB only.

The Restic CronJob in [infrastructure/backup-cronjobs/](../../infrastructure/backup-cronjobs/)
also writes to Hetzner SB but at a different path
(`/cluster-backups-tier-3/`); OpenBao snapshots live at
`/openbao-snapshots/`. No collision.

The daily Cilium policy allows all DNS *questions* only to the cluster's trusted
`kube-dns` endpoints so Cilium's DNS proxy can observe replies and populate the
`toFQDNs` identity for `u609156.your-storagebox.de`. This does not grant general
external egress: the separate destination rule still permits only that exact FQDN
on TCP/23. Do not add the L7 DNS rule to the hourly policy, which has no FQDN-based
destination to populate.

Quarterly restore drill per
[`openbao/restore-drill.md`](../../../homelab-docs/03-runbooks/openbao/restore-drill.md)
(part of the [quarterly-checklist](../../../homelab-docs/05-security/audit/quarterly-checklist.md)).

## Operator inputs

- `<HOMELAB-DOMAIN>` in `httproute.yaml` (caught by
  [`scripts/check-placeholders.sh`](../../scripts/check-placeholders.sh)).
- Initial unseal ceremony per
  [`cluster/argocd-bootstrap.md`](../../../homelab-docs/03-runbooks/cluster/argocd-bootstrap.md)
  Step 4 — Shamir keyshares distributed per
  [ADR 0018](../../../homelab-docs/02-decisions/0018-openbao-deployment-shape.md)
  (laptop / paper-in-safe / offline-recovery archive).

## Related

- [ADR 0018](../../../homelab-docs/02-decisions/0018-openbao-deployment-shape.md) —
  deployment shape decision.
- [cluster/argocd-bootstrap.md §Step 4](../../../homelab-docs/03-runbooks/cluster/argocd-bootstrap.md) —
  init + unseal procedure.
- [infrastructure/backup-cronjobs/](../../infrastructure/backup-cronjobs/) —
  shares the Hetzner SB SSH cred.
- [infrastructure/external-secrets/](../../infrastructure/external-secrets/) —
  the `openbao` ClusterSecretStore that all ESOs in this repo
  reference.
