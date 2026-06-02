# apps/paperless

Document archive — scanned receipts, statements, IDs,
medical paperwork. Per `personal-documents` share in
[storage.md](../../../homelab-docs/01-architecture/storage.md)
+ [ADR 0025 D4](../../../homelab-docs/02-decisions/0025-nas-as-encrypted-bulk-substrate.md)
(cluster app for `personal+` data) +
[ADR 0030 §D2](../../../homelab-docs/02-decisions/0030-csi-rclone-and-storage-split.md)
(hot/cold split with csi-rclone for the cold bucket).

Single-replica Paperless-ngx + bundled Redis + external CNPG
Postgres + four PVCs split across hot (Longhorn) and cold
(csi-rclone). Cilium HTTPRoute on
`paperless.lab.<HOMELAB-DOMAIN>` is **Tailscale-only at all
times** — `personal` data classification per ADR 0024 D5;
no Cloudflare TLS termination, no public sharing surface.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `paperless` ns; PSA restricted. |
| `kustomization.yaml` | Helm chart `oci://ghcr.io/gabe565/charts/paperless-ngx` v0.24.1; resource list below. |
| `values.yaml` | Single Deployment; bundled Redis on; bundled Postgres + MariaDB off (CNPG instead). **Four PVCs** mounted per ADR 0030 §D2: `paperless-data` (Longhorn) at `/usr/src/paperless/data`; `paperless-media` (csi-rclone) at `/usr/src/paperless/media`; `paperless-consume` (Longhorn) at `/usr/src/paperless/consume`; `paperless-export` (Longhorn) at `/usr/src/paperless/export`. OCR languages eng+deu. Tika+Gotenberg disabled at first install. |
| `cnpg-cluster.yaml` | 2-instance CNPG `paperless-pg` on `longhorn-replica3`; barman → MinIO; 90d retention. Stock cnpg-postgresql image (no extensions needed). |
| `pvc.yaml` | Four PVCs: `paperless-data` (10Gi Longhorn-replica2 RWO), `paperless-media` (500Gi `nas-crypt-personal-documents` RWX), `paperless-consume` (10Gi Longhorn-replica2 RWO), `paperless-export` (100Gi Longhorn-replica2 RWO). |
| `externalsecret.yaml` | 3 ESOs: admin, oidc, cnpg-s3. DB creds are CNPG-managed in-namespace. |
| `httproute.yaml` | Cilium HTTPRoute on `paperless.lab.<HOMELAB-DOMAIN>`; Tailscale-only. |
| `networkpolicy.yaml` | Vanilla NP: same-ns broad allow + Cilium Gateway ingress + Prometheus scrape. CCNP: kube-DNS + MinIO (CNPG WAL) + GitHub (first-run NLTK / spacy / tessdata downloads). **No NAS direct egress** — csi-rclone handles it. |
| `servicemonitor.yaml` | Prometheus scrape on `/metrics` (django-prometheus middleware). |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/paperless/admin` | `username`, `password`, `email` | Operator-typed admin user; password generated random + `--print` for first login. Operator rotates to OIDC-only post-Authentik. |
| `kv/data/paperless/oidc` | `client_id`, `client_secret`, `issuer` | Provisioned via `provision-authentik-oidc-client.sh`. Ships dormant; operator activates via admin UI Settings → SocialAccountSettings post-Authentik client provisioning. |
| `kv/data/paperless/cnpg-s3` | `access_key_id`, `secret_access_key` | MinIO svc-account scoped to `homelab-backups-cluster/cnpg/paperless/`. Standard CNPG-app pattern. |
| `kv/data/paperless/redis` | `password` | Bitnami redis subchart AUTH password. The paperless-ngx chart unconditionally injects an `A_REDIS_PASSWORD` env from Secret `paperless-redis` key `redis-password` whenever `redis.enabled: true` — with no gate on `auth.enabled` (chart bug). Materialized via `existingSecret` pattern; seed before first Argo sync of this layer. |

DB user/password: not in OpenBao. CNPG creates the
`paperless-pg-app` Secret in-namespace at cluster bootstrap
and values.yaml's env wires it directly.

**First-install seed:**

```sh
# Admin user — generate + seed + print password for first login.
bao kv put kv/paperless/admin \
    username="paperless-admin" \
    email="<OPERATOR_EMAIL>"
homelab-infra/scripts/seed-random-secret.sh \
    --print --format base64 --size 32 \
    kv/paperless/admin password

# Authentik OIDC client.
AUTHENTIK_URL=https://auth.lab.<HOMELAB-DOMAIN> \
AUTHENTIK_TOKEN="$(bao kv get -field=api_token kv/authentik/admin)" \
homelab-infra/scripts/provision-authentik-oidc-client.sh \
    --app-name paperless \
    --redirect-uri \
      "https://paperless.lab.<HOMELAB-DOMAIN>/accounts/oidc/authentik/login/callback/" \
    --kv-path kv/paperless/oidc

# CNPG s3-creds.
homelab-infra/scripts/provision-minio-svcacct.sh \
    --alias minio \
    --kv-path kv/paperless/cnpg-s3 \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/paperless/*" \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/paperless" \
    --label paperless-cnpg

# Redis AUTH password — random 32-char.
homelab-infra/scripts/seed-random-secret.sh \
    --format base64 --size 32 \
    kv/paperless/redis password
```

## Bring-up wiring

| Step | Owner | What lands |
|---|---|---|
| 1. Operator runs the rclone-crypt key bootstrap ceremony for `personal-documents` per [`03-runbooks/nas/rclone-crypt-key-bootstrap.md`](../../../homelab-docs/03-runbooks/nas/rclone-crypt-key-bootstrap.md). | OpenBao path `kv/prod/nas-encryption/personal-documents/rclone_config` populated; offline-recovery archive entry added per ADR 0025 D8; NAS ciphertext share `personal-documents-cipher` pre-created. |
| 2. Argo sync `infrastructure/cnpg/` + `cert-manager/` + `minio-on-nas/` + `platform/openbao/` + `external-secrets/` + `infrastructure/csi-rclone/` (with the `nas-crypt-personal-documents` SC registered). | Prereqs Healthy. |
| 3. Operator runs the seed snippet above. | ESO populates Secrets. |
| 4. Argo sync this layer. | CNPG `paperless-pg` reconciles; four PVCs bind; Paperless Deployment Ready (first-run downloads NLTK + spacy + tessdata, ~5 min); HTTPRoute reconciled. |
| 5. First-time admin login at `https://paperless.lab.<HOMELAB-DOMAIN>`. | Operator dismisses initial wizard; sets locale + default tags + ML settings. |
| 6. (post-Authentik) operator wires OIDC via admin UI → Settings → SocialAccountSettings, pasting values from the OIDC Secret env vars. | OIDC login flow active for operator + any family members granted document access. |

## Caveats

1. **Tailscale-only at all times** — per ADR 0024 D5, no
   public hostname. Operator + selected family members reach
   Paperless via Tailscale. The data classification
   (`personal`) makes Cloudflare TLS termination unacceptable;
   Paperless's content is too sensitive for the
   `internal-media`-class CF-Tunnel exception either.

2. **Thumbnails on csi-rclone (accepted small cost).**
   Paperless writes thumbnails under `media/thumbnails/`
   with no env var to redirect them to a separate path; the
   whole `media/` tree lives on csi-rclone-encrypted NAS.
   The 8-10x rclone-mount read-amp pattern Immich's research
   surfaced applies here in a milder form (Paperless paginates
   document grids; doesn't infinite-scroll like a photo
   timeline). Accepted at this scale; revisit if the operator's
   archive grows past ~50k documents.

3. **Polling consumer (60s)** instead of inotify. inotify
   over FUSE-mounted csi-rclone is unreliable; polling is
   the safe default. Operator drops files via Nextcloud
   sync to a path inside the consume mount, or via the
   web UI upload button. Polling cost is bounded
   (one stat per consume-dir scan).

4. **First-run downloads** ~3GB total (NLTK data, spacy
   models, tessdata for eng+deu). `Caveats #3` of the CCNP
   egress allows GitHub + GitHub-objects only; if the
   operator extends OCR languages beyond eng+deu, additional
   tessdata pulls may need a NetworkPolicy update.

5. **Tika + Gotenberg disabled by default.** The chart can
   integrate sibling Tika + Gotenberg deployments for
   converting Office documents (`.docx`, `.xlsx`, etc.) to
   PDF before OCR. The operator's expected workload is
   primarily PDF + image scans; enabling these adds two
   more pods + complexity. Re-enable via
   `PAPERLESS_TIKA_ENABLED=true` + `PAPERLESS_TIKA_ENDPOINT`
   + `PAPERLESS_TIKA_GOTENBERG_ENDPOINT` env vars + sibling
   Deployments when an Office-doc workflow surfaces.

6. **Single replica.** Paperless's HA story is operationally
   heavy (shared media volume + Postgres + Redis + worker
   coordination). Single-replica + Longhorn snapshot + Restic
   tier-3 covers the homelab use case.

7. **First-install admin password retrievable from OpenBao.**
   `bao kv get -field=password kv/paperless/admin`. Operator
   logs in once + immediately rotates to OIDC-only post-
   Authentik. The bootstrapped admin account stays as a
   non-OIDC fallback for OIDC-broken scenarios (similar to
   Nextcloud's pattern).

## Related

- [ADR 0024 D5](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  — Tailscale-only ingress (no Cloudflare TLS termination
  for `personal` data).
- [ADR 0025 D4](../../../homelab-docs/02-decisions/0025-nas-as-encrypted-bulk-substrate.md)
  — cluster app for `personal-documents`; NAS sees ciphertext.
- [ADR 0030](../../../homelab-docs/02-decisions/0030-csi-rclone-and-storage-split.md)
  — csi-rclone hot/cold split; `nas-crypt-personal-documents`
  StorageClass.
- [ADR 0017](../../../homelab-docs/02-decisions/0017-cluster-node-disk-encryption.md)
  — closes the threat-model loop for hot-bucket data on
  Longhorn.
- [`infrastructure/csi-rclone/`](../../infrastructure/csi-rclone/)
  — driver + StorageClass `nas-crypt-personal-documents`.
- [`storage.md`](../../../homelab-docs/01-architecture/storage.md)
  — `personal-documents` share, Tier-A/B/C access matrix.
- [`platform/authentik/templates/`](../../platform/authentik/templates/)
  — OIDC client pattern.
- [`apps/immich/`](../immich/) + [`apps/nextcloud/`](../nextcloud/)
  — sibling apps with the same hot/cold-split pattern.
- [`03-runbooks/nas/rclone-crypt-key-bootstrap.md`](../../../homelab-docs/03-runbooks/nas/rclone-crypt-key-bootstrap.md)
  — operator ceremony for the encryption key.
- Upstream: [paperless-ngx docs](https://docs.paperless-ngx.com/),
  [gabe565/charts/paperless-ngx](https://github.com/gabe565/charts/tree/main/charts/paperless-ngx).
