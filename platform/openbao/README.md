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
| `raft-snapshot-cronjob.yaml` | Daily 03:00 UTC snapshot via `bao operator raft snapshot save`, scp'd to Hetzner Storage Box per ADR 0018 D5. |
| `raft-snapshot-hourly.yaml` | Hourly snapshot to a local Longhorn PVC (`openbao-raft-snapshots`, 10Gi, replica2), 168 retain (= 7d). Per ADR 0018 D5 + backup-and-dr.md §"OpenBao". The PVC opts into Longhorn's `secret-personal` recurring-job group so the volume itself is also Longhorn-snapshotted hourly — file-level (this CronJob) + block-level (Longhorn) at the same cadence. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).
ExternalSecrets in `raft-snapshot-cronjob.yaml` project these
into the openbao namespace; without them the snapshot CronJob
stays in `CreateContainerConfigError`.

**Caveat — chicken-and-egg.** OpenBao is the OpenBao backend
itself. The first-install seeds below are only writable AFTER
OpenBao is up and the operator has performed the manual
`bao operator init` + Shamir unseal ceremony per
[cluster/argocd-bootstrap.md](../../../homelab-docs/03-runbooks/cluster/argocd-bootstrap.md)
Step 4. The CronJob waits unhealthy until the seeds land —
that's expected on day one.

| Path | Keys | Source |
|---|---|---|
| `kv/prod/openbao/snapshot-token` | `token` | `bao token create -policy=snapshot -ttl=8760h -orphan` (after applying the `snapshot` policy below). Yearly rotation. |
| `kv/prod/backup/hetzner-storage-box` | `host`, `user`, `port`, `ssh_key`, `ssh_known_host` *(optional)* | from Hetzner Robot account; SSH key is operator-generated ed25519 keypair, public half added to Storage Box console. **Reused** by [infrastructure/backup-cronjobs/](../../infrastructure/backup-cronjobs/). The `ssh_known_host` field is the post-TOFU pinned host-key — capture procedure in [backup-cronjobs/README §Host-key pinning](../../infrastructure/backup-cronjobs/README.md). |

**First-install seed (after OpenBao initialized + unsealed):**

```sh
# 1. Apply the snapshot-only policy:
cat > /tmp/snapshot.hcl <<'EOF'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF
bao policy write snapshot /tmp/snapshot.hcl
shred -u /tmp/snapshot.hcl

# 2. Issue a long-lived orphan token bound to the snapshot policy:
SNAPSHOT_TOKEN=$(bao token create \
  -policy=snapshot -ttl=8760h -orphan \
  -format=json | jq -r .auth.client_token)

bao kv put kv/prod/openbao/snapshot-token value="$SNAPSHOT_TOKEN"
unset SNAPSHOT_TOKEN

# 3. Hetzner SB SSH key (one-time; reused by backup-cronjobs).
# Skip if already populated by the backup-cronjobs bring-up.
ssh-keygen -t ed25519 -f /tmp/hetzner-sb -N ''
# Add /tmp/hetzner-sb.pub to Hetzner Robot → Storage Box → SSH Keys.
bao kv put kv/prod/backup/hetzner-storage-box \
  host="u123456.your-storagebox.de" \
  user="u123456" \
  port="23" \
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

Tier-2 (friend's NAS) intentionally does **not** receive
OpenBao snapshots — the seal already makes them opaque-and-
encrypted, so tier-2's dedup buys nothing. Direct `scp` to
Hetzner SB only.

The Restic CronJob in [infrastructure/backup-cronjobs/](../../infrastructure/backup-cronjobs/)
also writes to Hetzner SB but at a different path
(`/cluster-backups-tier-3/`); OpenBao snapshots live at
`/openbao-snapshots/`. No collision.

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
