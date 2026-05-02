# apps/immich

Self-hosted photo library. Replaces NAS-Docker PhotoPrism (and
DSM Synology Photos) per
[ADR 0025 D4](../../../homelab-docs/02-decisions/0025-nas-as-encrypted-bulk-substrate.md).
Migration runbook:
[`immich/migrate-from-photoprism.md`](../../../homelab-docs/03-runbooks/immich/migrate-from-photoprism.md).
Day-to-day usage:
[`photo-management-with-immich.md`](../../../homelab-docs/04-guides/photo-management-with-immich.md).

Three workload pods (server, microservices, machine-learning) +
chart-bundled Redis + an external CNPG Postgres cluster with
the **vectorchord** extension for CLIP smart-search and
ArcFace face embeddings. Library backend is the NAS
`personal-photos` share via NFS-CSI (RWX), with the
rclone-crypt overlay per
[ADR 0025 D3](../../../homelab-docs/02-decisions/0025-nas-as-encrypted-bulk-substrate.md)
sitting between the pod's view (plaintext) and the NAS-stored
ciphertext. Cilium HTTPRoute on `immich.lab.<HOMELAB-DOMAIN>` is
**Tailscale-only at all times**; public album sharing happens
via the separate
[`apps/immich-public-proxy/`](../immich-public-proxy/) layer
behind Cloudflare Tunnel per
[ADR 0024 D1](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md).

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `immich` ns; PSA restricted. |
| `kustomization.yaml` | Helm chart `oci://ghcr.io/immich-app/immich-charts/immich` v0.11.1; resource list below. |
| `values.yaml` | server + microservices + machine-learning enabled; bundled Redis on, bundled Postgres off; library PVC `immich-library` mounted at `/usr/src/app/upload`; OAuth (Authentik OIDC) wired via `OAUTH_*` extraEnv; non-root + dropped caps. |
| `cnpg-cluster.yaml` | 2-instance CNPG cluster `immich-pg` using the cnpg-pgvector-vectorchord image (vectorchord + pgvector + pgvecto.rs); 20Gi Longhorn-replica3; barman → MinIO; `vchord.so` preloaded; `vector` + `vchord` extensions installed at bootstrap. |
| `nfs-pv.yaml` | Static PV+PVC `immich-library` (4Ti soft cap, RWX) backed by NAS share `<NAS_PERSONAL_PHOTOS>`. **Mounts the ciphertext share — see "Bring-up wiring" below for the rclone-crypt overlay activation.** |
| `externalsecret.yaml` | OIDC client + CNPG-WAL S3 creds (DB credentials are CNPG-managed in-namespace, not in OpenBao). |
| `httproute.yaml` | Cilium HTTPRoute on `immich.lab.<HOMELAB-DOMAIN>`; Tailscale-only at all times. |
| `networkpolicy.yaml` | Vanilla NP: same-ns broad allow + Cilium Gateway ingress on server, Prometheus scrape, immich-public-proxy ingress on server. CCNP: NFS to `<NAS_IP>` + MinIO (CNPG WAL) + GeoNames + GitHub releases (Immich's reverse-geocoding download). |
| `servicemonitor.yaml` | Prometheus scrape on `/api/server/metrics`. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/immich/oidc` | `client_id`, `client_secret`, `issuer` | Provisioned via `provision-authentik-oidc-client.sh`. Operator + family login flow uses Authentik OIDC; native Immich users are kept off (`OAUTH_AUTO_REGISTER=true` provisions Immich users on first OIDC login). |
| `kv/data/immich/cnpg-s3` | `access_key_id`, `secret_access_key` | MinIO bucket `homelab-backups-cluster` for CNPG WAL archival; sibling to `nextcloud-cnpg-s3`. Provisioned via the same MinIO console flow. |

DB user/password: not in OpenBao. CNPG creates the
`immich-pg-app` Secret in-namespace at cluster bootstrap and
values.yaml's env wires it directly. Operator never touches it.

**First-install seed:**

```sh
# Authentik OIDC client.
AUTHENTIK_URL=https://auth.lab.<HOMELAB-DOMAIN> \
AUTHENTIK_TOKEN="$(bao kv get -field=api_token kv/authentik/admin)" \
homelab-infra/scripts/provision-authentik-oidc-client.sh \
    --app-name immich \
    --redirect-uri \
      "https://immich.lab.<HOMELAB-DOMAIN>/auth/login" \
    --kv-path kv/immich/oidc

# MinIO bucket creds for CNPG WAL.
mc admin user add minio immich-cnpg \
    "$(openssl rand -base64 32)"
mc admin policy attach minio readwrite --user immich-cnpg
bao kv put kv/immich/cnpg-s3 \
    access_key_id=immich-cnpg \
    secret_access_key="<from-mc-output>"
```

## Bring-up wiring

| Step | What lands |
|---|---|
| Argo sync `infrastructure/cert-manager/` + `platform/openbao/` + `platform/external-secrets/` + `platform/cnpg/` + `infrastructure/minio-on-nas/` | Prereqs Healthy. |
| Operator pre-stages NAS share `<NAS_PERSONAL_PHOTOS>` (ciphertext rclone-crypt config) per `nas/initial-setup.md`; rclone-crypt key seeded at `kv/prod/nas-encryption/personal-photos`. | NFS PV can bind. |
| **Operator wires the rclone-crypt overlay** (TBD — see "Known scaffolding gap" below). | Server + microservices + ML pods see plaintext at `/usr/src/app/upload`. |
| Argo sync this layer | CNPG cluster reconciles; `immich-pg-app` Secret materialises; ExternalSecrets pull OIDC + S3 creds; library PVC binds; server / microservices / ML Deployments Ready; HTTPRoute reconciled. |
| Operator visits `https://immich.lab.<HOMELAB-DOMAIN>` | Sign-up flow creates the operator's admin user (the first registered user is admin in Immich). Subsequent users provision via OIDC. |
| Operator runs the migration runbook | PhotoPrism originals + albums move into the library; tag tree built from the original folder hierarchy. |

## Known scaffolding gap — rclone-crypt overlay

This layer is the **first** consumer of the
[ADR 0025 D3](../../../homelab-docs/02-decisions/0025-nas-as-encrypted-bulk-substrate.md)
encrypted-bulk pattern (`personal+` data on NAS encrypted
client-side, decrypted only in cluster pods). The pattern is
specified in the ADR but has no reference implementation in the
codebase as of this scaffold's first commit.

What's missing:

- A sidecar / init-container running `rclone mount` against the
  ciphertext NFS PV with the `crypt:` remote configured from
  the OpenBao-projected key, exposing the plaintext mount to the
  app containers via a shared `emptyDir` (or via a propagated
  `mountPropagation: Bidirectional` once the FUSE-in-Pod
  permissions are sorted).
- Or, alternatively, a CSI plugin that does the same
  decryption transparently.
- A livenessProbe touching the decrypted mount to detect
  overlay hangs (called out in ADR 0025 D3).

Until that's wired, **do not Argo-sync this layer against
production data** — the pods will see ciphertext, fail to read
EXIF, and (worse) write plaintext over the encrypted blobs in a
way that needs a full restore to recover from. A test sync against
a throwaway share is fine for validating the rest of the
plumbing (Postgres bootstrap, OIDC, Helm release).

This gap is tracked in `homelab-docs/TODO.md` under "Wire ADR
0025 D3 rclone-crypt overlay; Immich is the first consumer."

## Caveats

1. **DB image is non-CNPG-native.** The
   `cnpg-pgvector-vectorchord` image is a community build. It
   does NOT receive automatic CNPG security backports — operator
   tracks vectorchord upstream releases manually via Renovate
   (chart pin) and the `imageName` field. Sibling apps using
   stock CNPG images (Nextcloud, Authentik, Forgejo) are
   unaffected.

2. **Postgres major upgrades are operator-driven.** Vectorchord
   only validates a narrow Postgres-version window per release;
   a Postgres major bump may require the vectorchord image to
   catch up first. Consult upstream Immich release notes before
   bumping the chart `image.tag` past v1.135.

3. **Immich admin UI is Tailscale-only at all times** — there
   is no public hostname for `immich.<HOMELAB-DOMAIN>` and no
   plan to add one. Public album sharing goes through
   `apps/immich-public-proxy/` which exposes only `/share/*`
   read-only routes via Cloudflare Tunnel, per ADR 0024 D1.

4. **First sign-up = admin.** Immich's bootstrap is
   browser-driven: the first registered user becomes admin.
   Operator must visit `immich.lab.<HOMELAB-DOMAIN>` BEFORE
   any family member's OIDC login, otherwise a family member
   could land as admin.

5. **`OAUTH_AUTO_REGISTER=true`** — anyone who can authenticate
   to Authentik can land in Immich as a non-admin user. This is
   intentional for family-onboarding (no manual Immich-side
   user creation), and acceptable because Authentik is itself
   Tailscale-only per ADR 0024 D3, so the attacker would need a
   tailnet device + Authentik creds + a homelab-app group in
   Authentik. Tighten by adding an `OAUTH_AUTO_REGISTER=false`
   override + manual admin-side user provisioning if the family
   surface gets uncomfortable.

6. **Storage growth.** Photos library + thumbnails +
   transcoded videos + Postgres WAL accumulate fast. The 4Ti PV
   capacity is a soft cap (NFS doesn't enforce it cluster-side);
   the underlying NAS volume is the actual constraint. Operator
   monitors via Prometheus (Immich's `/api/server/metrics`
   exposes asset counts and library size).

7. **No GPU.** ML jobs (CLIP + ArcFace) run on CPU. First-pass
   indexing of a 100k-photo library takes ~24-48h at the
   resource limits configured here. Subsequent indexing is
   incremental and lightweight. If the operator adds a GPU
   later, raise the ML pod's `resources` and add a
   `nodeSelector` for the GPU node.

8. **Locked Folder is UI-only.** Per ADR 0003, the rclone-crypt
   overlay encrypts everything in the library at NAS rest;
   Locked Folder adds a UI-level visibility gate but no
   additional encryption layer. See guide §"Locked Folder for
   sensitive content" for the framing.

## Migration from PhotoPrism

Per
[`immich/migrate-from-photoprism.md`](../../../homelab-docs/03-runbooks/immich/migrate-from-photoprism.md).
High-level:

1. Cluster Immich up + admin signed up + OIDC verified.
2. PhotoPrism kept running on the NAS during migration.
3. `immich-go upload from-folder --folder-as-tags=PATH` ports
   originals + builds tag tree from folder hierarchy.
4. `ppim-migrator` carries over PhotoPrism albums + favorites
   + RAW stacks via the dual-API match.
5. Auto-archive workflow album set up for unsorted
   buckets (WhatsApp, screenshots, friends' content).
6. After 30 days of stable operation, decommission PhotoPrism.

## Related

- [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  D1 — Tailscale Phase 1 + CF Tunnel via immich-public-proxy
  for public sharing.
- [ADR 0025](../../../homelab-docs/02-decisions/0025-nas-as-encrypted-bulk-substrate.md)
  D3+D4 — rclone-crypt overlay; Immich replaces Synology Photos.
- [`storage.md`](../../../homelab-docs/01-architecture/storage.md) —
  `personal-photos` share, Tier-A/B/C access matrix.
- [`platform/authentik/templates/`](../../platform/authentik/templates/)
  — OIDC client pattern.
- [`infrastructure/cnpg/`](../../infrastructure/cnpg/) —
  CNPG operator base.
- [`apps/nextcloud/`](../nextcloud/) — sibling app with the
  same CNPG + ExternalSecret + NFS-PV pattern.
- [03-runbooks/immich/](../../../homelab-docs/03-runbooks/immich/)
  — migration runbook.
- [04-guides/photo-management-with-immich.md](../../../homelab-docs/04-guides/photo-management-with-immich.md)
  — day-to-day usage.
