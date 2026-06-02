# infrastructure/csi-rclone

Cluster-wide encryption layer for `personal+`-classified data
on the NAS. Per
[ADR 0030](../../../homelab-docs/02-decisions/0030-csi-rclone-and-storage-split.md)
(refines [ADR 0025 D3](../../../homelab-docs/02-decisions/0025-nas-as-encrypted-bulk-substrate.md)).

`veloxpack/csi-driver-rclone` runs a privileged DaemonSet in
this namespace; rclone is embedded as a Go library so there's
no external binary to manage. Each `personal+` share gets its
own StorageClass `nas-crypt-<share>` whose config (NFS host +
share path + obscured crypt password/salt) lives in OpenBao
and is projected via ExternalSecret into a Secret the
StorageClass references via
`csi.storage.k8s.io/node-publish-secret-name`. Consumer apps
(Immich, future Nextcloud Files, Paperless, etc.) claim a PVC
against the relevant StorageClass and stay PSA-`restricted` —
they never see `/dev/fuse`, never run privileged.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `csi-rclone` ns; PSA **privileged** (driver needs `/dev/fuse` + mount propagation). |
| `kustomization.yaml` | Helm chart `oci://ghcr.io/veloxpack/charts/csi-driver-rclone` v0.4.11; resource list below. |
| `values.yaml` | Node DaemonSet + Controller + driver-level rclone defaults (`--vfs-cache-mode=full --vfs-cache-max-size=5G --vfs-cache-max-age=1h`); ServiceMonitor enabled. |
| `storageclasses.yaml` | Per-share `nas-crypt-*` StorageClasses. Today: `nas-crypt-personal-photos` (Immich), `nas-crypt-personal-files` + `nas-crypt-family-shared` + `nas-crypt-internal-archive` (Nextcloud), `nas-crypt-forgejo-lfs` + `nas-crypt-registry-blobs` (Forgejo), `nas-crypt-personal-documents` (Paperless). Add new SCs as new encrypted consumer apps land. |
| `externalsecret.yaml` | One ExternalSecret per StorageClass (7 today), each pulling the share's rclone INI from `kv/prod/nas-encryption/<share>/rclone_config`. Per-share keys per ADR 0025 D8 — compromise of one share doesn't expose another. |
| `networkpolicy.yaml` | Ingress: Prometheus scrape only. Egress: kube-DNS + `<NAS_IP>:2049/111` (NFS). |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/prod/nas-encryption/personal-photos` | `rclone_config` | Immich originals. Generated during the operator-side ceremony per [`03-runbooks/nas/rclone-crypt-key-bootstrap.md`](../../../homelab-docs/03-runbooks/nas/rclone-crypt-key-bootstrap.md). Single string holding the full rclone INI for the chained `crypt:` over `nfs:` remote (NAS IP, ciphertext share path, obscured password + salt). |
| `kv/data/prod/nas-encryption/personal-files` | `rclone_config` | Nextcloud's primary data dir (operator + family user-home tree). Same generation procedure as personal-photos. |
| `kv/data/prod/nas-encryption/family-shared` | `rclone_config` | Nextcloud Group Folder for family-shared content. |
| `kv/data/prod/nas-encryption/internal-archive` | `rclone_config` | Nextcloud Group Folder for archived internal documents. |
| `kv/data/prod/nas-encryption/forgejo-lfs` | `rclone_config` | Forgejo Git LFS objects per ADR 0023 D12. |
| `kv/data/prod/nas-encryption/registry-blobs` | `rclone_config` | Forgejo Packages (artifact registry) blob storage per ADR 0019 D7. |
| `kv/data/prod/nas-encryption/personal-documents` | `rclone_config` | Paperless-ngx source documents (scanned receipts, statements, IDs). |

Field is the **assembled** rclone INI, not the raw password.
Storing it pre-assembled keeps secrets out of templates and
matches the offline-recovery archive shape — the operator
backs up only the OpenBao snapshot, not a separate "what does
the config look like" sidecar doc. The crypt password +
salt themselves additionally land in the offline-recovery
archive per ADR 0025 D8 so a full-cluster-loss scenario can
reconstruct without OpenBao.

**Operator-side ceremony** (one-time, per share):
[`03-runbooks/nas/rclone-crypt-key-bootstrap.md`](../../../homelab-docs/03-runbooks/nas/rclone-crypt-key-bootstrap.md).
High-level: generate password + salt, run
`rclone obscure`, build the INI, seed OpenBao, update the
offline-recovery archive (Nitrokey-gated). Pre-create the
ciphertext NFS share on the NAS.

## Bring-up wiring

| Step | Owner | What lands |
|---|---|---|
| 1. Generate per-share rclone-crypt key + assembled INI | Operator (one-time, per share) | `kv/prod/nas-encryption/<share>/rclone_config` populated; offline-recovery archive updated; NAS ciphertext share pre-created. |
| 2. Argo sync `infrastructure/external-secrets/` + `platform/openbao/` | Argo | ESO can pull the Secret. |
| 3. Argo sync this layer | Argo | Driver DaemonSet up on every node; ExternalSecret reconciles to Secret in this ns; StorageClass `nas-crypt-<share>` registered. |
| 4. Argo sync the consumer app (e.g., `apps/immich/`) | Argo | Consumer claims PVC against `nas-crypt-<share>`; CSI provisions a volume; volume mounts in consumer pod with plaintext view. |
| 5. End-to-end check | Operator | Write a test file in the consumer pod → verify it appears as ciphertext on the NAS share via SSH-to-NAS + `ls`. Read it back via the consumer pod → verify plaintext round-trip. |

## Onboarding a new encrypted share

Each new `personal+` (or `internal`-encrypted) consumer app
that needs cluster-side-encrypted bulk storage requires four
mechanical additions, all in lockstep. Pattern established
with `nas-crypt-personal-photos` (Immich); follow the same
shape for every subsequent share.

| Step | Where | What |
|---|---|---|
| 1. Per-share rclone-crypt key generation | Operator (one-time) | Run [`03-runbooks/nas/rclone-crypt-key-bootstrap.md`](../../../homelab-docs/03-runbooks/nas/rclone-crypt-key-bootstrap.md) for the new share name. The runbook generates the crypt password + salt, assembles the rclone INI, seeds `kv/prod/nas-encryption/<share>/rclone_config`, and adds the password+salt to the offline-recovery archive (per [ADR 0025 D8](../../../homelab-docs/02-decisions/0025-nas-as-encrypted-bulk-substrate.md)). |
| 2. NAS ciphertext share pre-create | Operator (one-time) | DSM Control Panel → Shared Folder → create `<share>-cipher` with k8s-nfs RW + NFS-export to cluster nodes per [`nas/initial-setup.md` §"Step 3 — Create shares"](../../../homelab-docs/03-runbooks/nas/initial-setup.md). Do **not** enable DSM-side encryption — the encryption layer is cluster-side rclone-crypt per ADR 0025 D6. |
| 3. ExternalSecret + StorageClass | This layer | Add an `ExternalSecret` row to `externalsecret.yaml` pulling `kv/prod/nas-encryption/<share>/rclone_config` into Secret `nas-crypt-<share>-config`; add a matching `StorageClass nas-crypt-<share>` to `storageclasses.yaml` referencing the secret via `csi.storage.k8s.io/node-publish-secret-name`. |
| 4. cold-start.md row | docs | Append a row to [`cold-start.md` Step 13c](../../../homelab-docs/04-guides/cold-start.md) under `infrastructure/csi-rclone/` so the operator-action gate (Step 1 above) is sequenced before this layer's first sync. |

Plus the consumer app's own kustomize layer claims a PVC
against `nas-crypt-<share>` — that's app-side, not this layer.

**Sequencing**: steps 1+2 are operator-actions; they must
land **before** Argo syncs this layer, otherwise the
ExternalSecret stays in `SecretSyncedError` and the
StorageClass is registered but unusable.

**Compromise blast radius**: per ADR 0025 D8, each share has
its own crypt key. Compromise of one key exposes only its
share; the others stay opaque. Rotation per
[`03-runbooks/nas/encryption-key-rotation.md`](../../../homelab-docs/03-runbooks/nas/encryption-key-rotation.md).

## Caveats

1. **Veloxpack is pre-1.0**, ~318 stars, primarily one
   maintainer. Per ADR 0030 §D5 the maturity hedge is:
   pin image digest, mirror to Forgejo Packages once ADR 0019
   is serving, FUSE-sidecar fallback documented in
   [`known-caveats.md`](../../../homelab-docs/04-guides/known-caveats.md).
   Operator monitors upstream releases via Renovate.

2. **Privileged namespace.** The driver's Node DaemonSet runs
   privileged with `/dev/fuse` + mount propagation
   `Bidirectional`. Bounded to this namespace; consumer apps
   stay PSA `restricted`. Falco rules in
   [`observability/falco-stack/rules-configmap.yaml`](../../observability/falco-stack/rules-configmap.yaml)
   carry a scoped exception (`user_privileged_containers` +
   `user_sensitive_mount_containers` extension entries for
   the veloxpack csi-driver-rclone image) so csi-rclone's
   privileged ops don't trigger general "privileged
   container" alerts. Defense-in-depth: a homelab-custom rule
   in the same overlay fires if `/dev/fuse` is opened from
   any namespace other than `csi-rclone`.

3. **One key per share.** Per ADR 0025 D8, each NAS share has
   its own rclone-crypt key. Compromise of one key exposes
   only that share. Adding a new `personal+` consumer →
   generate a new key + StorageClass, not reuse an existing
   one.

4. **Initial ML index pass on Immich** (and any future
   consumer doing a full-library re-scan) burns through the
   entire library decrypted once. Bounded one-shot cost; not
   a steady-state concern. Flagged in
   [`migrate-from-photoprism.md`](../../../homelab-docs/03-runbooks/immich/migrate-from-photoprism.md).

5. **Hot/cold split is a per-app responsibility.** This layer
   provides the encrypted cold-bucket surface. Each consumer
   declares two PVCs (one Longhorn-backed for the hot bucket,
   one `nas-crypt-*`-backed for the cold bucket) per
   ADR 0030 §D2. The split is not enforced by this layer;
   an app that puts thumbnails on `nas-crypt-*` will work but
   take the read-amplification hit.

6. **`nfs-csi` cleanup landed alongside this ADR.** The
   `nfs-personal-files`, `nfs-family-shared`,
   `nfs-internal-archive` SCs that previously sat in
   `infrastructure/nfs-csi/storageclasses.yaml` were forward-
   declarations from when ADR 0025 D3's per-app FUSE-sidecar
   pattern was the assumed shape. They never had a consumer;
   ADR 0030 redirects every `personal+` consumer here instead.
   Removed in the same commit that added this layer.
   `infrastructure/nfs-csi/` now serves only plaintext-at-NAS
   shares (`internal-media`, `public-*`, `cluster-backups`,
   `time-machine-mba`).

7. **Transport is SMB, not NFS** — ADR 0030 §D5 mentioned
   "csi-driver-rclone PR #17 added crypt: over nfs: stacking";
   PR #17 added *stacking* support, but neither the embedded
   rclone library nor upstream rclone has an `nfs:` backend
   (NFS is kernel-mode). Empirically validated 2026-06-01:
   `type = nfs` in the rclone INI fails NodePublishVolume with
   `didn't find backend called "nfs"`. The 7 `kv/prod/nas-encryption/<share>`
   paths use **`type = smb`** transport with the
   `ansible-automation` DSM service account; per-share crypt
   keys layer on top unchanged. See
   [2026-06-02 journal](../../../homelab-docs/99-journal/2026-06-02-nas-encryption-ceremony.md).

8. **Consumer pods MUST set `securityContext.fsGroup`.** The
   veloxpack driver only auto-enables `-o allow_other` when
   the CSI request includes `volume_mount_group`, which kubelet
   populates *only* from the pod's `fsGroup` (the SC parameter
   `allow_other: "true"` alone is NOT honored — verified via
   `pkg/rclone/nodeserver.go`). Without `fsGroup` on the
   consumer pod, the mount lands `user_id=0,group_id=0`
   without `allow_other`, and any non-root container hits
   `Permission denied` on `ls /mnt/...`. Convention:
   - **Immich / Paperless / Forgejo** → `fsGroup: 1000`
   - **Nextcloud** → `fsGroup: 33` (www-data)
   - **Jellyfin** (plaintext NAS, not crypt) → also `fsGroup: 1000` for the consume mount
   These can land at chart-`pod.securityContext.fsGroup` for
   bjw-s-schema charts, or top-level `podSecurityContext.fsGroup`
   for other chart schemas — values-key audit per consumer.

## Related

- [ADR 0030](../../../homelab-docs/02-decisions/0030-csi-rclone-and-storage-split.md)
  — the decision this layer implements.
- [ADR 0025](../../../homelab-docs/02-decisions/0025-nas-as-encrypted-bulk-substrate.md)
  — D3 refined; D8 (offline-recovery key) still applies.
- [ADR 0017](../../../homelab-docs/02-decisions/0017-cluster-node-disk-encryption.md)
  — closes the threat-model loop for hot-bucket data on
  Longhorn.
- [`storage.md`](../../../homelab-docs/01-architecture/storage.md)
  — share inventory + Tier-A/B/C access matrix.
- [`apps/immich/`](../../apps/immich/) — first consumer.
- [`infrastructure/nfs-csi/`](../nfs-csi/) — sibling layer
  for `internal-media` / `public-*` plaintext shares (e.g.,
  Jellyfin) that don't need the encryption hop.
- Upstream:
  [veloxpack/csi-driver-rclone](https://github.com/veloxpack/csi-driver-rclone),
  [PR #17 nested remotes](https://github.com/veloxpack/csi-driver-rclone/pull/17),
  [veloxpack docs](https://www.veloxpack.io/docs/csi-driver-rclone/).
