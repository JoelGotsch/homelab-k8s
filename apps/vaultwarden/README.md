# apps/vaultwarden

Operator's daily-driver password manager + family-shared
vault. Per [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
D1 (Cloudflare Tunnel for E2EE-encrypted services) +
[audit follow-up](../../../homelab-docs/99-journal/2026-05-01-architecture-audit-alternatives.md)
§Vaultwarden ("1.33.0+ pin; admin panel behind OIDC; CF
Tunnel + WAF in front").

Single-replica Vaultwarden + SQLite on Longhorn (personal-
vault scale doesn't justify CNPG; resilience via Longhorn
snapshot + Restic tier-3). Migration target from NAS-Docker
Vaultwarden per
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
| `values.yaml` | Single-replica + SQLite on Longhorn-replica3; ADMIN_TOKEN as Argon2 hash from ESO; OIDC ships disabled (operator flips post-Authentik client provisioning); WebSocket on; closed registration; logging JSON; readonly rootfs. |
| `externalsecret.yaml` | 3 ExternalSecrets: admin (Argon2-hashed token), oidc (Authentik client), smtp (operator-fillable). |
| `httproute.yaml` | Cilium HTTPRoute for `vaultwarden.lab.<HOMELAB-DOMAIN>`; Tailscale-only at first commit. |
| `networkpolicy.yaml` | Vanilla NP: ingress from Cilium Gateway + Prometheus; egress kube-DNS + Authentik. CCNP: SMTP egress (FQDN-aware; ships placeholder). |
| `servicemonitor.yaml` | Prometheus scrape on `/metrics`. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/vaultwarden/admin` | `admin_token_argon2` | Argon2 hash of operator-chosen admin password. **NOT plaintext.** Generated locally per the snippet below. Plaintext lives in operator's memory + Vaultwarden vault. |
| `kv/data/vaultwarden/oidc` | `client_id`, `client_secret`, `issuer` | Provisioned via `provision-authentik-oidc-client.sh` post-Authentik-bring-up. |
| `kv/data/vaultwarden/smtp` | `host`, `username`, `password` | Operator-typed SMTP relay creds (only required if email invites are wanted). Ships empty — Vaultwarden refuses to send when fields are empty. |

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

# 3. SMTP — only if family invites need email. Operator-typed:
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

7. **SQLite on Longhorn, not CNPG.** Personal-vault scale
   (~hundreds of items) doesn't justify CNPG complexity.
   Recovery via Longhorn snapshot + Restic tier-3.
   Switch to Postgres (Vaultwarden supports it via
   `DATABASE_URL`) if the database grows past ~50MB or
   query latency surfaces.

8. **WebSocket port 3012 in NetworkPolicy** for backwards
   compat with older Bitwarden clients. Vaultwarden 1.30+
   serves websocket on the main port; the 3012 ingress rule
   can be removed once all operator/family clients are
   updated.

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
