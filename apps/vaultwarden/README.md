# apps/vaultwarden

> **SUPERSEDED — do not deploy from this directory.** `vaultwarden` reconciles
> from its own repository at `vaultwarden/k8s/` (ADR 0001 app-repo model); no Argo
> Application has sourced this path since the 2026-07-20 split. It is kept
> because ten immutable journal entries and several runbooks link into it.
>
> Specifically dangerous as of 2026-08-15: the `cnpg-cluster.yaml` here still
> describes `spec.backup.barmanObjectStore`, which CloudNativePG **removes in
> 1.31.0**. The live `vaultwarden-pg` moved to the Barman Cloud plugin
> ([ADR 0050](../../../homelab-docs/02-decisions/0050-cnpg-barman-cloud-plugin.md));
> applying this copy on a 1.31+ operator would be rejected, and on 1.30 it
> would silently move the cluster back onto a removed API. Read
> `vaultwarden/k8s/` instead.

Operator's daily-driver password manager + family-shared
vault. Per [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
D1 (Cloudflare Tunnel for E2EE-encrypted services) +
[audit follow-up](../../../homelab-docs/99-journal/2026-05-01-architecture-audit-alternatives.md)
§Vaultwarden ("1.33.0+ pin; admin panel behind OIDC; CF
Tunnel + WAF in front").

Single-replica Vaultwarden + external CNPG Postgres
(operator's call 2026-05-02; switched from SQLite for
backup-consistency uniformity — Longhorn-snapshot of running
SQLite can capture mid-transaction state, while CNPG's
WAL-shipping captures every committed transaction. Same
restore-drill semantics as every other CNPG-using app).
Attachments + sends still on a small Longhorn-replica3 PVC.
Migration target from NAS-Docker Vaultwarden per
[`migration/nas.md`](../../../homelab-docs/03-runbooks/migration/nas.md).

**Phase 1** (today): Tailscale-only HTTPRoute on
`vaultwarden.lab.<HOMELAB-DOMAIN>` for operator + family
testing.
**Phase 2** (when `infrastructure/cloudflare-tunnel/`
lands): public-facing on `vaultwarden.<HOMELAB-DOMAIN>`
via Cloudflare Tunnel + WAF.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `vaultwarden` ns; PSA restricted. |
| `kustomization.yaml` | guerzon/vaultwarden helm chart 0.32.0; resource list below. |
| `values.yaml` | Single-replica + external CNPG Postgres + Longhorn-replica3 PVC for attachments; ADMIN_TOKEN as Argon2 hash from ESO; OIDC ships disabled; closed registration; logging JSON. |
| `cnpg-cluster.yaml` | 2-instance CNPG `vaultwarden-pg` on `longhorn-replica3`; barman → MinIO; **90d retention** (operator daily-driver credentials warrant longer recovery window). |
| `externalsecret.yaml` | 4 ExternalSecrets: admin (Argon2 token), oidc (dormant), smtp (operator-fillable), cnpg-s3 (barman backup). DATABASE_URL projected directly from CNPG's auto-created `vaultwarden-pg-app` Secret — no separate `vaultwarden-postgres-creds` ESO. |
| `httproute.yaml` | Cilium HTTPRoute for `vaultwarden.lab.<HOMELAB-DOMAIN>`; Tailscale-only at first commit. |
| `networkpolicy.yaml` | Vanilla NP: ingress Cilium Gateway + Prometheus; egress kube-DNS + CNPG + Authentik. CCNP: SMTP egress (FQDN-aware; placeholder). |
| `servicemonitor.yaml` | Prometheus scrape on `/metrics`. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/vaultwarden/admin` | `admin_token_argon2` | Argon2 hash of operator-chosen admin password. **NOT plaintext.** Generated locally per the snippet below. Plaintext lives in operator's memory + Vaultwarden vault. |
| `kv/data/vaultwarden/oidc` | `client_id`, `client_secret`, `issuer` | Provisioned via `provision-authentik-oidc-client.sh` post-Authentik-bring-up. |
| `kv/data/vaultwarden/smtp` | `host`, `username`, `password` | Operator-typed SMTP relay creds (only required if email invites are wanted). Ships empty — Vaultwarden refuses to send when fields are empty. |
| `kv/data/cnpg/vaultwarden/s3-creds` | `access_key_id`, `secret_access_key` | MinIO svc-account scoped to `homelab-backups-cluster/cnpg/vaultwarden/`. Standard CNPG-app pattern. |

(The Postgres password itself is **not** stored in OpenBao —
CNPG auto-creates `vaultwarden-pg-app` Secret with the full
DATABASE_URL; values.yaml's `extraEnv` references it directly.
This avoids duplicating the credential between two secret
stores + makes CNPG's password-rotation transparent to
Vaultwarden.)

**First-install seed:**

```sh
# 1. ADMIN_TOKEN — Argon2 hash. Generate locally; the
# plaintext stays in operator's memory + their Vaultwarden
# vault entry. Vaultwarden 1.32+ requires the hash form.
PLAINTEXT="$(openssl rand -base64 48)"
HASH="$(echo -n "$PLAINTEXT" | argon2 \
    "$(openssl rand -hex 32)" -id -t 3 -m 16 -p 4 -e)"
echo "PLAINTEXT (memorize / paste into Vaultwarden vault):"
echo "  $PLAINTEXT"
bao kv put kv/vaultwarden/admin admin_token_argon2="$HASH"
unset PLAINTEXT HASH

# 2. OIDC client — provisioned via API helper post-Authentik:
AUTHENTIK_URL=https://auth.lab.<HOMELAB-DOMAIN> \
AUTHENTIK_TOKEN="$(bao kv get -field=api_token kv/authentik/admin)" \
homelab-infra/scripts/provision-authentik-oidc-client.sh \
    --app-name vaultwarden \
    --redirect-uri \
      "https://vaultwarden.lab.<HOMELAB-DOMAIN>/identity/connect/oidc-signin" \
    --scopes "openid email profile" \
    --kv-path kv/vaultwarden/oidc

# (Postgres password not in OpenBao — Vaultwarden reads
# DATABASE_URL directly from CNPG's auto-created
# `vaultwarden-pg-app` Secret. See note above the seed table.)

# 3. CNPG s3-creds — provisioned + seeded after MinIO Healthy.
homelab-infra/scripts/provision-minio-svcacct.sh \
    --alias minio \
    --kv-path kv/cnpg/vaultwarden/s3-creds \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/vaultwarden/*" \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/vaultwarden" \
    --label vaultwarden-cnpg

# 4. SMTP — only if family invites need email. Operator-typed:
# bao kv put kv/vaultwarden/smtp \
#     host="smtp.<provider>" \
#     username="<smtp-user>" \
#     password="<smtp-pass>"
```

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync `infrastructure/cert-manager/` | TLS certs available. |
| Argo sync `platform/openbao/` | OpenBao + ESO ready. |
| Operator runs the seed snippet above | ESO can populate Secrets. |
| Argo sync this layer | Vaultwarden Deployment Ready; HTTPRoute reconciled; admin panel reachable via Tailscale at `https://vaultwarden.lab.<HOMELAB-DOMAIN>/admin`. |
| Argo sync `platform/authentik/` + operator runs `provision-authentik-oidc-client.sh` | OIDC client provisioned; operator flips `sso.enabled: true` in values.yaml + commits + pushes. |
| **(later)** Argo sync `infrastructure/cloudflare-tunnel/` | Public ingress on `vaultwarden.<HOMELAB-DOMAIN>` enabled. |

## Migration from NAS-Docker Vaultwarden

Per [`migration/nas.md`](../../../homelab-docs/03-runbooks/migration/nas.md)
+ `vaultwarden/migrate-from-nas-docker.md` (TBD). High-level:

1. Cluster Vaultwarden up + admin login working.
2. Run quarterly restore drill (per
   [`vaultwarden/restore-drill.md`](../../../homelab-docs/03-runbooks/vaultwarden/restore-drill.md))
   on the cluster instance — gates family rollout per ADR 0024.
3. Operator exports JSON from NAS-Docker Vaultwarden (admin
   panel → Organizations → Export).
4. Import into cluster Vaultwarden.
5. Re-point operator's clients (browsers, F-Droid, Mac) to
   the new URL; verify daily-driver vault access for 14 days.
6. After 14 days zero issues: stop NAS-Docker Vaultwarden;
   30 days later remove the container + volume.

## Caveats

1. **1.33.0+ pin discipline** per the audit. Vaultwarden's
   2025 CVE pattern (4 CVEs in 6 months including
   CVE-2025-24364 admin-panel RCE fixed in 1.33.0) makes the
   image-tag freshness load-bearing. Renovate auto-PRs the
   chart bumps; operator merges within 7 days of release per
   [update-policy.md](../../../homelab-docs/01-architecture/update-policy.md).
   Quarterly checklist also re-checks the running version
   against upstream.

2. **ADMIN_TOKEN is Argon2-hashed at rest.** Plaintext lives
   only in operator's memory + their Vaultwarden vault entry.
   Loss = re-generate; existing data unaffected.

3. **Admin panel is gated by both ADMIN_TOKEN AND Authentik
   OIDC** post-bring-up (defense-in-depth). The `/admin`
   path requires the token in the URL fragment; OIDC layer
   gates the URL itself.

4. **OIDC ships disabled.** Vaultwarden's SSO env vars are
   ESO-projected from `vaultwarden-oidc` Secret which is
   empty until operator runs `provision-authentik-oidc-client.sh`.
   Operator flips `sso.enabled: true` post-population —
   commits + pushes — Argo reconciles. Until then, native
   email/password auth is the only path.

5. **Cloudflare Tunnel deferred.** ADR 0024 D1 specifies CF
   Tunnel as the public path. Until `infrastructure/cloudflare-tunnel/`
   lands, Vaultwarden is Tailscale-only — fine for
   operator-only testing; family rollout waits for CF Tunnel.

6. **SMTP ships disabled.** Email invites for family-sharing
   require operator-populated `vaultwarden-smtp` Secret +
   the placeholder FQDN in `networkpolicy.yaml`'s CCNP
   replaced with the actual SMTP relay. Vaultwarden refuses
   to send when fields are empty (safe default).

7. **External CNPG Postgres** (operator's call 2026-05-02;
   not SQLite). Backup uniformity with the rest of the
   cluster: continuous WAL shipping → MinIO → Restic
   tier-2/3; same restore-drill semantics as every other
   CNPG-using app. Trade-off: 2 extra CNPG instances + a
   barmanObjectStore for personal-vault data; accepted as
   the price of consistent backup posture.

## Related

- [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  — Cloudflare Tunnel + Authentik OIDC for Vaultwarden.
- [04-guides/known-caveats.md §Vaultwarden](../../../homelab-docs/04-guides/known-caveats.md)
  — accumulated caveats incl. CVE-pin discipline.
- [`platform/authentik/templates/`](../../platform/authentik/templates/)
  — per-app OIDC client pattern.
- [03-runbooks/vaultwarden/](../../../homelab-docs/03-runbooks/vaultwarden/)
  — restore drill, family-account onboarding, master-password
  rotation, NAS-Docker migration.
- [03-runbooks/migration/nas.md](../../../homelab-docs/03-runbooks/migration/nas.md)
  — pre-cluster NAS extraction + per-Docker disposition.
