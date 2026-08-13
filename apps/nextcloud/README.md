# apps/nextcloud

Family-shared file sync + calendar + contacts. Synology
Drive replacement (per ADR 0025 D4) + Radicale replacement.
Per [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
D5 (Tailscale-only — non-E2EE files / calendar / contacts
don't qualify for Cloudflare TLS termination per D4).

Single-replica Nextcloud + external CNPG Postgres + bundled
Redis + hot/cold storage split per
[ADR 0030 §D2](../../../homelab-docs/02-decisions/0030-csi-rclone-and-storage-split.md):
hot bucket (config / custom_apps / themes / tmp) on Longhorn,
cold buckets (user files + Group Folders) on csi-rclone-NFS-
crypt across three shares — `personal-files`,
`family-shared`, `internal-archive` — each with its own key
per ADR 0025 D8. Cilium HTTPRoute on
`nextcloud.lab.<HOMELAB-DOMAIN>` reachable only via Tailscale.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `nextcloud` ns; PSA restricted. |
| `kustomization.yaml` | nextcloud/nextcloud helm 5.5.0; resource list below. |
| `values.yaml` | Single-replica + external CNPG + bundled Redis. **Four PVCs** mounted per ADR 0030 §D2: `nextcloud-hot` (Longhorn) at `/var/www/html` for config/custom_apps/themes/tmp; `nextcloud-personal-files` (csi-rclone) at `/var/www/html/data` for user homes; `nextcloud-family-shared` (csi-rclone) at `/mnt/family-shared`; `nextcloud-internal-archive` (csi-rclone) at `/mnt/internal-archive`. OIDC env wired (operator activates via occ post-Authentik). |
| `cnpg-cluster.yaml` | 2-instance CNPG `nextcloud-pg` on `longhorn-replica3`; barman → MinIO; 90d retention. |
| `pvc.yaml` | Four PVCs per ADR 0030 §D2: `nextcloud-hot` (50Gi Longhorn-replica2 RWX, LUKS-at-rest via ADR 0017) + three csi-rclone PVCs (`nextcloud-personal-files` 1Ti, `nextcloud-family-shared` 500Gi, `nextcloud-internal-archive` 1Ti) against per-share `nas-crypt-*` StorageClasses. |
| `externalsecret.yaml` | 4 ESOs: admin, postgres, oidc, cnpg-s3. |
| `httproute.yaml` | Cilium HTTPRoute on `nextcloud.lab.<HOMELAB-DOMAIN>`. |
| `networkpolicy.yaml` | Vanilla NP: Cilium Gateway + Prometheus + CNPG + Redis + Authentik. **No CCNP NAS egress** — csi-rclone is the only NAS-talking layer per ADR 0030. |
| `servicemonitor.yaml` | Prometheus scrape on `/metrics`. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/nextcloud/admin` | `username`, `password` | Operator-typed admin user; password generated random. Operator captures the password for first login (set `--print` on the seed helper). |
| `kv/data/nextcloud/oidc` | `client_id`, `client_secret`, `issuer` | Provisioned via `provision-authentik-oidc-client.sh`. Ships dormant; `user_oidc` Nextcloud app activated post-bring-up via `occ`. |

The Postgres credential is NOT seeded into OpenBao. CNPG creates the
`nextcloud-pg-app` Secret directly in the namespace (with `host`/`username`/
`password`/`dbname` keys, rotated on password changes), and the chart's
`externalDatabase.existingSecret` consumes it as-is. Mirroring CNPG-issued
creds through OpenBao is the anti-pattern previously fixed for forgejo and
removed here on 2026-06-02.
| `kv/data/cnpg/nextcloud/s3-creds` | `access_key_id`, `secret_access_key` | MinIO svc-account (CNPG WAL+base). Standard CNPG-app pattern. |

**First-install seed:**

```sh
# Admin user — generate + seed + print password for first login.
bao kv put kv/nextcloud/admin username="ncadmin"
homelab-infra/scripts/seed-random-secret.sh \
    --print --format base64 --size 32 \
    kv/nextcloud/admin password

# (No CNPG-postgres seed: the chart reads nextcloud-pg-app directly.)

# Authentik OIDC client — provisioned via API helper.
AUTHENTIK_URL=https://auth.lab.<HOMELAB-DOMAIN> \
AUTHENTIK_TOKEN="$(bao kv get -field=api_token kv/authentik/admin)" \
homelab-infra/scripts/provision-authentik-oidc-client.sh \
    --app-name nextcloud \
    --redirect-uri \
      "https://nextcloud.lab.<HOMELAB-DOMAIN>/apps/user_oidc/code" \
    --kv-path kv/nextcloud/oidc

# CNPG s3-creds — provisioned + seeded after MinIO Healthy.
homelab-infra/scripts/provision-minio-svcacct.sh \
    --alias minio \
    --kv-path kv/cnpg/nextcloud/s3-creds \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/nextcloud/*" \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/nextcloud" \
    --label nextcloud-cnpg
```

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Operator runs the rclone-crypt key bootstrap ceremony three times (one per share) per [`03-runbooks/nas/rclone-crypt-key-bootstrap.md`](../../../homelab-docs/03-runbooks/nas/rclone-crypt-key-bootstrap.md). | OpenBao paths `kv/prod/nas-encryption/{personal-files,family-shared,internal-archive}/rclone_config` populated; offline-recovery archive updated; three NAS ciphertext shares pre-created. |
| Argo sync `infrastructure/cnpg/` + `cert-manager/` + `minio-on-nas/` + `platform/openbao/` + `infrastructure/csi-rclone/` (with the three `nas-crypt-*` StorageClasses registered) | Prereqs Healthy. |
| Operator runs the seed snippet above. | ESO populates Secrets. |
| Argo sync this layer | CNPG `nextcloud-pg` up; four PVCs bind (`nextcloud-hot` on Longhorn + three csi-rclone PVCs); Nextcloud Deployment Ready; HTTPRoute reconciled. |
| First-time admin login at `https://nextcloud.lab.<HOMELAB-DOMAIN>` | Operator dismisses default-app-enable wizard; sets locale + timezone. |
| (post-Authentik) operator runs `occ app:install user_oidc + occ user_oidc:provider` | OIDC login flow active for family members. |
| Operator installs Group Folders app + creates `family-shared` and `internal-archive` group folders pointing at `/mnt/family-shared` and `/mnt/internal-archive` respectively. | Family + archive group folders accessible to assigned users; data goes to the right encrypted backend per ACL. |

## Post-bring-up activation (one-time)

### 1. user_oidc app activation

After Authentik OIDC client provisioned + `kv/nextcloud/oidc`
populated:

```sh
kubectl -n nextcloud exec -it deploy/nextcloud -- \
    sudo -u www-data php occ app:install user_oidc

kubectl -n nextcloud exec -it deploy/nextcloud -- \
    sudo -u www-data php occ user_oidc:provider authentik \
    --clientid="$OIDC_CLIENT_ID" \
    --clientsecret="$OIDC_CLIENT_SECRET" \
    --discoveryuri="$OIDC_ISSUER.well-known/openid-configuration" \
    --scope="openid email profile"
```

The env vars are projected by the chart's `extraEnv` block;
they're available inside the pod.

### 2. Family-onboarding

Per `nextcloud/family-onboarding.md` (TBD). Each family
member gets:
- Authentik account (operator creates in Authentik admin UI)
- Nextcloud user auto-provisioned on first OIDC login
- Group membership (operator assigns)
- Default share ACLs

### 3. Calendar / contacts migration from Radicale

Per [`migration/nas.md`](../../../homelab-docs/03-runbooks/migration/nas.md)
+ [`nextcloud/migrate-from-baikal.md`](../../../homelab-docs/03-runbooks/nextcloud/migrate-from-baikal.md)
(TBD). Export Radicale's .ics + .vcf files; import via
Nextcloud Calendar/Contacts upload.

### 4. Files migration from Synology Drive

Per [`migration/nas.md`](../../../homelab-docs/03-runbooks/migration/nas.md)
+ [`nextcloud/migrate-from-synology-drive.md`](../../../homelab-docs/03-runbooks/nextcloud/migrate-from-synology-drive.md)
(TBD). Operator copies files from Synology Drive's
operator-volume into the Nextcloud user's NFS-backed data
dir, then runs `occ files:scan` to register them.

## Caveats

1. **Tailscale-only ingress.** Per ADR 0024 D5 — Nextcloud
   files/calendar/contacts are not E2EE so don't qualify
   for Cloudflare TLS termination. Family members reach via
   Tailscale (operator's tailnet ACL gates access). Phase-2
   reconsider only if Nextcloud E2EE app investigation
   surfaces a viable encrypted-at-rest story (per TODO.md
   "Investigate Nextcloud E2EE").

2. **Cold-bucket data on NAS via csi-rclone-NFS-crypt.**
   User files (home trees + group folders) live on three
   per-share encrypted volumes per ADR 0030 §D2; NAS sees
   only ciphertext. Recovery via NAS Synology snapshot-
   replication + Restic tier-2/3 per ADR 0006. NOT
   cluster-Longhorn-backed — file data doesn't fit the
   Longhorn capacity profile. CNPG metadata + Redis cache +
   chart's hot bucket (config / custom_apps / themes / tmp)
   are Longhorn-resilient with LUKS-at-rest via ADR 0017.

3. **`readOnlyRootFilesystem: false`** — Nextcloud-fpm-alpine
   writes to `/var` at runtime (PHP session, cache, opcache).
   Default chart values mount data dirs separately but cache
   stays on rootfs. Switching to true requires redirecting
   PHP cache via `php_value` to a separate emptyDir; chart
   knob TBD.

4. **OIDC ships dormant.** `user_oidc` Nextcloud app is
   NOT installed by chart. Operator runs `occ app:install
   user_oidc` post-bring-up + the `occ user_oidc:provider`
   command above. Family rollout depends on this.

5. **Single replica.** Nextcloud's HA story (Galera +
   shared cache) is operationally heavy; for homelab scale
   the single-replica + Longhorn snapshot + Restic tier-3
   approach is sufficient. Pod eviction = ~30s of
   sync-client-side retries; no permanent data loss.

6. **First-install admin password retrievable from OpenBao.**
   `bao kv get -field=password kv/nextcloud/admin`. Operator
   logs in once + immediately sets up MFA (via Nextcloud
   admin's TOTP), then either rotates the password OR stops
   using it once OIDC is wired (admin via OIDC + Authentik
   WebAuthn instead).

7. **Cron sidecar runs background jobs every 5min.** File
   scans for changes, federated calendar sync, preview
   generation. Default behaviour; tunable via `cronjob.cmd`.

## Related

- [ADR 0024 D5](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  — Tailscale-only Nextcloud.
- [ADR 0025 D4](../../../homelab-docs/02-decisions/0025-nas-as-encrypted-bulk-substrate.md)
  — Synology Drive replacement.
- [`platform/authentik/templates/`](../../platform/authentik/templates/)
  — per-app OIDC client pattern.
- [03-runbooks/nextcloud/](../../../homelab-docs/03-runbooks/nextcloud/)
  — per-app runbooks (initial-setup, family-onboarding,
  migrate-from-synology-drive, migrate-from-baikal).
- [03-runbooks/migration/nas.md](../../../homelab-docs/03-runbooks/migration/nas.md)
  — pre-cluster NAS extraction.
