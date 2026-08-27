# platform/authentik

Self-hosted Identity Provider (IdP) — the OAuth2/OpenID Connect
endpoint that internal services (Forgejo, Woodpecker, Grafana,
Vaultwarden, Langfuse, ...) authenticate against. Per
[identity.md](../../../homelab-docs/01-architecture/identity.md)
("internal services sit behind Authentik, which enforces
WebAuthn as the primary factor") + [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
D3 (Tailscale-only ingress for internal services).

Single-replica server + worker; external CNPG Postgres for
all persistent state (cache, task queue, channel layer, and
relational data — Authentik 2026.x removed Redis entirely,
replacing it with `django_postgres_cache` /
`django_channels_postgres` / `django_dramatiq_postgres`).
Cilium HTTPRoute on `auth.lab.<HOMELAB-DOMAIN>` reachable
only via Tailscale.

The companion [`templates/`](templates/) directory holds the
reusable per-app OIDC-client pattern — every consuming app
copies + adapts that template into its own manifests.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `authentik` ns; PSA baseline. Server and worker still declare restricted-style uid-1000 pod/container contexts, asserted by `scripts/check-authentik-security-context.sh`. |
| `kustomization.yaml` | Authentik helm chart `2026.2.0`; resource list below. |
| `values.yaml` | Server + worker, external CNPG (Postgres-backed cache + queue — no Redis), JSON logs, telemetry/error-reporting disabled, readonly rootfs, dropped caps. |
| `cnpg-cluster.yaml` | 2-instance CNPG `authentik-pg` on `longhorn-replica3`; barman → MinIO; **90d retention** (longer than other apps — operator-identity data warrants longer recovery window). |
| `externalsecret.yaml` | 4 ExternalSecrets: secret-key, postgres, bootstrap (admin), cnpg-s3. |
| `httproute.yaml` | Cilium HTTPRoute for `auth.lab.<HOMELAB-DOMAIN>`; Tailscale-only. |
| `networkpolicy.yaml` | Server ingress: Cilium Gateway + Prometheus + every OIDC consumer ns (forgejo, woodpecker, vaultwarden, monitoring, langfuse, llm-gateway, nextcloud, jellyfin, argocd). Egress: kube-DNS + CNPG + OpenBao (no Redis — removed in 2026.x). Worker: same egress + outbound to OIDC consumers for token push. |
| `servicemonitor.yaml` | Prometheus scrape on `:9300`. |
| `templates/` | Reusable OIDC-client pattern for consuming apps. Copy + adapt per app. Pre-existing; kept under this layer because Authentik owns the pattern. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/authentik/secret-key` | `value` | Random ≥50 bytes base64 — Django SECRET_KEY for session/CSRF signing. Rotation forces all sessions to re-authenticate. |
| `kv/data/authentik/postgres` | `password` | CNPG-issued; operator copies from the auto-created `authentik-pg-app` Secret. |
| `kv/data/authentik/admin` | `bootstrap_password`, `bootstrap_token`, `bootstrap_email` | Bootstrap admin credentials. Used by `/if/flow/initial-setup/` on first boot to create the `akadmin` superuser. After that flow, these are no longer used by Authentik (they're only re-applied on a re-bootstrap). |
| `kv/shared/smtp` | `host`, `port`, `username`, `from`, `password` | Central homelab outbound SMTP (Proton submission) — shared by every mail-sending app. Seed with `homelab-infra/scripts/seed-smtp.sh`. Projected here as `AUTHENTIK_EMAIL__*` env via the `authentik-smtp` ExternalSecret. |
| `kv/data/cnpg/authentik/s3-creds` | `access_key_id`, `secret_access_key` | MinIO svc-account scoped to `homelab-backups-cluster/cnpg/authentik/`. Standard CNPG-app pattern. |
| `kv/data/<app>/oidc` | `client_id`, `client_secret` | One path per blueprint under `blueprints/`. AUTO-seeded by `homelab-infra/scripts/seed-openbao-paths.sh`. Authentik provider is created by the declarative blueprint reading these via `!Env`; the consumer-side ExternalSecret in the app's ns reads the same path. Currently: `grafana/oidc`. |

**First-install seed:**

```sh
# Django SECRET_KEY — random, base64.
homelab-infra/scripts/seed-random-secret.sh \
    --format base64 --size 50 \
    kv/authentik/secret-key value

# CNPG-issued postgres password — operator copies from CNPG.
bao kv put kv/authentik/postgres \
    password="$(kubectl -n authentik get secret authentik-pg-app \
        -o jsonpath='{.data.password}' | base64 -d)"

# Bootstrap admin — operator-fillable email, random password
# + token. --print so operator can capture both during first-
# install (need to type the password into the /if/flow/
# initial-setup/ form).
bao kv put kv/authentik/admin \
    bootstrap_email="<AUTHENTIK_ADMIN_EMAIL>"
homelab-infra/scripts/seed-random-secret.sh \
    --print --format base64 --size 32 \
    kv/authentik/admin bootstrap_password
homelab-infra/scripts/seed-random-secret.sh \
    --print --format hex --size 32 \
    kv/authentik/admin bootstrap_token

# CNPG s3-creds — provisioned + seeded after MinIO Healthy.
homelab-infra/scripts/provision-minio-svcacct.sh \
    --alias minio \
    --kv-path kv/cnpg/authentik/s3-creds \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/authentik/*" \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/authentik" \
    --label authentik-cnpg
```

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync `infrastructure/cnpg/` | CNPG operator up. |
| Argo sync `infrastructure/cert-manager/` | TLS certs available. |
| Argo sync `infrastructure/minio-on-nas/` | `homelab-backups-cluster` bucket pre-created. |
| Argo sync `platform/openbao/` | OpenBao + ESO ready; operator runs the seed snippet above. |
| Argo sync this layer | CNPG `authentik-pg` Cluster up (90s); server + worker Deployments Ready; HTTPRoute reconciled. |
| Operator: `/if/flow/initial-setup/` | First-admin flow completes; `akadmin` user created with `bootstrap_password`. |
| Operator: enrol Nitrokey as WebAuthn credential | Per [`identity.md` §Authentik](../../../homelab-docs/01-architecture/identity.md). |
| Operator: create OIDC clients per consuming app | Forgejo + Woodpecker + Grafana + Vaultwarden + ... — each per the pattern in [`templates/oidc-client.template.yaml`](templates/oidc-client.template.yaml). |

## Post-bring-up activation (one-time)

After Argo's first sync brings the layer up:

### 1. Initial-setup flow

```sh
# Capture the bootstrap password (printed at seed time but
# also retrievable):
bao kv get -field=bootstrap_password kv/authentik/admin
```

Browse to `https://auth.lab.<HOMELAB-DOMAIN>/if/flow/initial-setup/`,
log in as `akadmin` with that password. Authentik prompts to
set a new password for the `akadmin` user — operator types a
new one (separate from the bootstrap value). The bootstrap
creds in OpenBao stay populated for re-bootstrap recovery
scenarios but aren't otherwise used.

### 2. Enrol Nitrokey as WebAuthn credential

User Settings → Configure Authenticator → WebAuthn → Register.
Touch Nitrokey when prompted. Per
[identity.md](../../../homelab-docs/01-architecture/identity.md)
§"Authentik enforces WebAuthn as the primary factor."

Add the second Nitrokey as a backup credential. Verify both
work by signing out + logging back in with each.

### 3. Configure WebAuthn-required policy

Authentik admin UI → Flows & Stages → default-authentication-flow
→ add a Stage Binding for the Authenticator Validation Stage
restricting to WebAuthn. Operator follows
[Authentik docs §Configure WebAuthn as primary](https://goauthentik.io/docs/flow/examples/flows#two-factor-authentication).

### 4. Create OIDC clients per consuming app

For each app that's expected to authenticate via Authentik
(Forgejo, Woodpecker, Grafana, Vaultwarden, Langfuse, ...),
follow the per-app pattern documented in
[`templates/oidc-client.template.yaml`](templates/oidc-client.template.yaml).

The pattern is repetitive (same shape per app) — see
[`templates/README.md`](templates/README.md) for the
4-step recipe.

## Caveats

1. **Single-replica Authentik server + worker.** No HA at
   the app layer; pod eviction = brief login interruption.
   Resilience via CNPG + Longhorn snapshot + Restic tier-3.
   Operator-identity data is the most consequential to
   recover — 90d barman retention (vs the 30d default for
   other CNPG-using services) reflects that.

2. **No Redis — Postgres-backed cache/queue.** Authentik
   2026.x replaced Redis with `django_postgres_cache` +
   `django_channels_postgres` + `django_dramatiq_postgres`.
   The chart has no Redis subchart and no `redis:` values
   key; the previously configured `redis:` + `authentik.redis`
   blocks were dead config silently dropped at render. Loss
   of Postgres = full service outage (cache, queue, AND
   relational data are all on the same CNPG cluster). CNPG
   HA (2 instances) + 90d barman retention is the resilience
   story.

3. **Bootstrap creds stay in OpenBao after first-admin
   flow.** They're inert (Authentik no longer reads them
   except on first-install), but the operator can use them
   to re-bootstrap if the `akadmin` user gets deleted/
   corrupted. Rotate via re-seed if the threat model
   demands.

4. **NetworkPolicy enumerates every OIDC consumer ns
   explicitly.** Adding a new internal service that needs
   OIDC requires updating `networkpolicy.yaml`'s
   `matchExpressions.values` list (server ingress + worker
   egress). Forgetting this = "OIDC discovery succeeds (DNS
   only) but token exchange fails" — confusing failure mode.

5. **Templates layer is operator-discipline, not enforced.**
   `platform/authentik/templates/` defines the per-app OIDC
   client shape, but no admission policy enforces that
   consuming apps follow it. Kyverno rule "any
   ExternalSecret pointing at `kv/prod/authentik/clients/*`
   must use the standard ConfigMap shape" is a future
   tightening if drift becomes a real problem.

6. **Telemetry + error reporting disabled.** Operator opts
   out of upstream Authentik telemetry (per principle #2 +
   ADR 0028 D7's pattern of disabling vendor telemetry).

7. **No SMTP wired at first install.** Self-service password
   reset / email notifications require operator to populate
   `authentik.email.*` in values.yaml + an SMTP creds Secret.
   For a single-operator homelab this is unused — operator
   resets via `/if/admin/` direct DB-touch if needed.

8. **OIDC issuer URL bakes `<HOMELAB-DOMAIN>`.** If the
   domain changes, every consuming app's OIDC client config
   needs the new issuer URL — re-discovery + re-config in
   the app's helm values + a new OIDC client in Authentik.
   Domain change is a
   [`pki/root-ca-rotation.md`](../../../homelab-docs/03-runbooks/pki/root-ca-rotation.md)
   -shaped event.

## Related

- [identity.md](../../../homelab-docs/01-architecture/identity.md)
  — Authentik as the operator-identity gate.
- [ADR 0024 D3](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  — Tailscale-only for internal services (Authentik first).
- [`templates/`](templates/) — reusable OIDC client pattern
  for consuming apps.
- [`platform/forgejo/`](../forgejo/),
  [`platform/woodpecker/`](../woodpecker/) — first OIDC
  consumers (other apps follow the same pattern).
- [04-guides/known-caveats.md §Authentik](../../../homelab-docs/04-guides/known-caveats.md)
  — accumulated index.
