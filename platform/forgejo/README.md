# platform/forgejo

Self-hosted forge — source of truth for all homelab repos.
Per [ADR 0023](../../../homelab-docs/02-decisions/0023-forgejo-and-woodpecker-ci.md)
(forge + CI engine) + [ADR 0019](../../../homelab-docs/02-decisions/0019-forgejo-packages-as-artifact-registry.md)
(Forgejo Packages as artifact registry) +
[ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
(Tailscale-only ingress, no Cloudflare for source-of-truth).

Single-replica Forgejo on Longhorn for app + git data; external
CNPG Postgres for relational metadata; csi-rclone-NFS-crypt for
LFS + Packages bulk storage per
[ADR 0030 §D1](../../../homelab-docs/02-decisions/0030-csi-rclone-and-storage-split.md)
(refining ADR 0025 D7) — `internal` data with cluster-overlay
encryption, per-share keys per ADR 0025 D8. Authentik OIDC for
login; Cilium HTTPRoute on `forgejo.lab.<HOMELAB-DOMAIN>`
reachable only via Tailscale.

GitHub stays as a unidirectional read-only mirror (per ADR 0023
D14 — sync direction Forgejo → GitHub for public + internal repos).

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `forgejo` ns; PSA restricted. |
| `kustomization.yaml` | Forgejo helm chart 10.0.0 (OCI); resource list below. |
| `values.yaml` | Single-replica; external CNPG; chart's persistence on Longhorn for app data; csi-rclone PVCs for LFS + Packages mounted via `additionalVolumes` + `additionalVolumeMounts` at `/data/lfs` + `/data/packages`. OIDC; readonly rootfs. |
| `cnpg-cluster.yaml` | 2-instance CNPG cluster `forgejo-pg` on `longhorn-replica3`; barman backup → MinIO; same shape as Langfuse / Crowdsec. |
| `pvc.yaml` | Two dynamic PVCs per ADR 0030 §D2: `forgejo-lfs` (200Gi `nas-crypt-forgejo-lfs` SC) + `forgejo-packages` (200Gi `nas-crypt-registry-blobs` SC). Both RWX; per-share keys; encryption-at-rest on NAS via the chained `crypt:` over `nfs:` remote. |
| `externalsecret.yaml` | 5 ExternalSecrets: admin, security-keys (4 fields), postgres-creds, oidc, cnpg-s3. |
| `httproute.yaml` | Cilium HTTPRoute for `forgejo.lab.<HOMELAB-DOMAIN>`; Tailscale-reachable; cert via cluster Gateway TLS block. |
| `networkpolicy.yaml` | Ingress: Cilium Gateway + Prometheus + Woodpecker server/agent + ci-woodpecker runner pods + Renovate. Egress: kube-DNS + CNPG + OpenBao + Authentik. **No CCNP NAS egress** — csi-rclone is the only NAS-talking layer per ADR 0030. |
| `servicemonitor.yaml` | Prometheus scrape on `/metrics`. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/forgejo/admin` | `password`, `email` | Random password (operator uses to log in once + create OIDC, then switches to OIDC-only). Email = operator's contact address — projected into the `forgejo-admin` Secret via ESO template, then env-substituted into the chart's admin-create command at init-container start. Keeps operator PII out of git-committed values.yaml. |
| `kv/data/forgejo/security-keys` | `secret_key`, `internal_token`, `jwt_secret`, `lfs_jwt_secret` | All random. Loss = forced re-login + LFS re-upload. |
| `kv/data/forgejo/postgres` | `password` | CNPG-issued; operator copies from the auto-created `forgejo-pg-app` Secret. |
| `kv/data/forgejo/oidc` | `client_id`, `client_secret` | From Authentik — operator creates the `forgejo` OIDC client in Authentik admin UI, then copies values. |
| `kv/data/cnpg/forgejo/s3-creds` | `access_key_id`, `secret_access_key` | MinIO svc-account scoped to `homelab-backups-cluster/cnpg/forgejo/`. Standard CNPG-app pattern. |

**First-install seed:**

```sh
# Admin password — generate + seed + print so operator can log
# in once after first sync.
homelab-infra/scripts/seed-random-secret.sh \
    --print --format base64 --size 32 \
    kv/forgejo/admin password

# Admin email — operator's contact address. Patched onto the
# existing kv/forgejo/admin entry; do NOT use `bao kv put` (it
# would clobber the random password). Use `bao kv patch` so
# both fields coexist.
read -rs -p "Operator email: " OPERATOR_EMAIL && echo
bao kv patch kv/forgejo/admin email="$OPERATOR_EMAIL"
unset OPERATOR_EMAIL

# Security keys — all 4 random.
for f in secret_key internal_token jwt_secret lfs_jwt_secret; do
  homelab-infra/scripts/seed-random-secret.sh \
      kv/forgejo/security-keys "$f"
done

# CNPG-issued postgres password — operator copies from CNPG's
# auto-issued Secret after the cluster comes up.
bao kv put kv/forgejo/postgres \
    password="$(kubectl -n forgejo get secret forgejo-pg-app \
        -o jsonpath='{.data.password}' | base64 -d)"

# Authentik OIDC — provisioned via API helper (creates the
# OAuth2 provider + application in Authentik + seeds OpenBao
# in one shot). Operator must have $AUTHENTIK_TOKEN set
# (admin API token from User Settings → Tokens after first
# login).
AUTHENTIK_URL=https://auth.lab.<HOMELAB-DOMAIN> \
AUTHENTIK_TOKEN="$(bao kv get -field=api_token kv/authentik/admin)" \
homelab-infra/scripts/provision-authentik-oidc-client.sh \
    --app-name forgejo \
    --redirect-uri \
      "https://forgejo.lab.<HOMELAB-DOMAIN>/user/oauth2/authentik/callback" \
    --kv-path kv/forgejo/oidc

# Manual fallback (if the script doesn't fit, e.g., custom
# scope mappings):
# bao kv put kv/forgejo/oidc \
#     client_id="<paste-from-authentik>" \
#     client_secret="<paste-from-authentik>"

# CNPG s3-creds — provisioned + seeded after MinIO Healthy.
homelab-infra/scripts/provision-minio-svcacct.sh \
    --alias minio \
    --kv-path kv/cnpg/forgejo/s3-creds \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/forgejo/*" \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/forgejo" \
    --label forgejo-cnpg
```

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Operator runs the rclone-crypt key bootstrap ceremony twice (once per share) per [`03-runbooks/nas/rclone-crypt-key-bootstrap.md`](../../../homelab-docs/03-runbooks/nas/rclone-crypt-key-bootstrap.md). | OpenBao paths `kv/prod/nas-encryption/{forgejo-lfs,registry-blobs}/rclone_config` populated; offline-recovery archive entries added per ADR 0025 D8; two NAS ciphertext shares pre-created. |
| Argo sync `infrastructure/cnpg/` | CNPG operator up. |
| Argo sync `infrastructure/cert-manager/` | TLS certs available. |
| Argo sync `platform/authentik/` | IdP up; operator creates the `forgejo` OIDC client. |
| Argo sync `platform/openbao/` | OpenBao + ESO ready; operator runs the seed snippet above. |
| Argo sync `infrastructure/minio-on-nas/` | `homelab-backups-cluster` bucket pre-created for CNPG barman. |
| Argo sync `infrastructure/csi-rclone/` (with `nas-crypt-forgejo-lfs` + `nas-crypt-registry-blobs` SCs registered) | csi-rclone driver up; per-share ExternalSecrets reconcile to Secrets in csi-rclone ns. |
| Argo sync this layer | CNPG `forgejo-pg` Cluster up; csi-rclone PVCs bind (`forgejo-lfs`, `forgejo-packages`); Forgejo Deployment Ready; HTTPRoute reconciled; first admin login works. |
| Operator post-bring-up: `forgejo admin auth add-oauth` | OIDC enabled in Forgejo; subsequent logins via Authentik. |
| Argo sync `platform/woodpecker/` | Woodpecker server registers Forgejo OAuth client. |

## Post-bring-up activation (one-time)

After Argo's first sync brings the layer up:

### 1. First-login admin password

```sh
bao kv get -field=password kv/forgejo/admin
```

Browse to `https://forgejo.lab.<HOMELAB-DOMAIN>/`, log in as
`forgejo-admin` with that password.

### 2. Create the Authentik OIDC client

In Authentik admin UI: Applications → Providers → Create →
OAuth2/OpenID Provider. Then Applications → Create with the
provider attached. Copy `client_id` + `client_secret` into
OpenBao via the seed snippet above.

### 3. Add the OAuth source in Forgejo

```sh
kubectl -n forgejo exec deploy/forgejo -- forgejo admin auth add-oauth \
    --name authentik \
    --provider openidConnect \
    --key "$(bao kv get -field=client_id kv/forgejo/oidc)" \
    --secret "$(bao kv get -field=client_secret kv/forgejo/oidc)" \
    --auto-discover-url https://auth.<HOMELAB-DOMAIN>/application/o/forgejo/.well-known/openid-configuration \
    --skip-local-2fa false
```

### 4. Create the homelab org

```sh
kubectl -n forgejo exec deploy/forgejo -- forgejo admin user \
    create --admin --email "<FORGEJO_ADMIN_EMAIL>" \
    --username "<operator-username>" \
    --random-password
# (operator captures the printed random password; rotates to
# their Vaultwarden master after first OIDC login).

# Create the homelab org via the Forgejo UI:
# https://forgejo.lab.<HOMELAB-DOMAIN>/org/create
# Name: homelab (matches <FORGEJO_ORG> in Renovate config).
```

### 5. Migrate repos from GitHub-private mirror

Per [`forgejo/github-personal-to-org-migration.md`](../../../homelab-docs/03-runbooks/forgejo/github-personal-to-org-migration.md)
(TBD; runbook stub on TODO list).

### 6. Wire push-mirror back to GitHub

Per [`forgejo/github-mirror-setup.md`](../../../homelab-docs/03-runbooks/forgejo/github-mirror-setup.md)
(TBD). Direction: Forgejo → GitHub, unidirectional. Public +
internal repos only per ADR 0023 D14 + ADR 0003.

## First-party image pulls

Forgejo Packages doubles as the homelab's private OCI image
registry (`registry.homelab.internal` via the
`platform/forgejo/httproute-registry.yaml` Gateway alias of
`forgejo.lab.<HOMELAB-DOMAIN>`). Packages are intentionally
**private** — neither package nor repo visibility is flipped
to public; consumer pods authenticate every pull.

### Bot account — `ci-packages` (dual-use)

A single Forgejo bot, `ci-packages`, services both pipelines:

| Side | Operation | Auth |
|---|---|---|
| Woodpecker CI | `docker push` to `registry.homelab.internal/<name>:<tag>` | Basic auth, PAT from OpenBao |
| Cluster pods | kubelet pull (image-pull cred) | Basic auth, same PAT, projected via ESO dockerconfigjson |

**Why one bot, not two:** at homelab scale a separate
pull-only bot (`ci-packages-pull` with `read:package` only)
buys minimal real-world isolation — only one push pipeline
exists and any incident-response flow rotates the shared
PAT anyway. The refactor trigger is "the first additional
pull consumer whose trust profile genuinely differs from
the Woodpecker pusher" — then split into
`ci-packages-push` (write scope, single namespace) and
`ci-packages-pull` (read scope, many namespaces) under
distinct OpenBao paths.

### OpenBao path

```
kv/data/shared/forgejo-packages/ci
  username = ci-packages
  token    = <Forgejo PAT, scopes: read:package + write:package>
```

Seeded once per `homelab-infra/scripts/provision-forgejo-bot-pat.sh`.
Rotation = re-run the script (PATCH bot password → POST token
endpoint → re-seed the kv path; ESO refresh + kubelet cred
re-read happen automatically within the ES `refreshInterval`).

### Secret name convention

Every consuming namespace renders a Secret named
**`registry-homelab-internal-pull`** (type
`kubernetes.io/dockerconfigjson`) via an ExternalSecret that
templates `.dockerconfigjson` from the bot's `username` +
`token`. The Secret is attached to the namespace's `default`
ServiceAccount, so every pod that uses the default SA
inherits the pull cred — no per-Deployment edits needed.

Files per namespace (two-file pattern):

```
registry-pull-secret.yaml   ExternalSecret → dockerconfigjson Secret
sa-default.yaml             ServiceAccount/default with imagePullSecrets
```

The ExternalSecret uses ESO v2 templating
(`template.engineVersion: v2`, `template.type:
kubernetes.io/dockerconfigjson`) with
`{{ printf "%s:%s" .username .password | b64enc }}` for the
`auth` field; rendered Secret value never traverses the
operator's shell.

### Adding a new namespace to the pull-enabled list

1. Copy `apps/approval-channel/registry-pull-secret.yaml`
   and `apps/approval-channel/sa-default.yaml` into the new
   namespace's directory. Edit the `metadata.namespace` field
   in both files (the ES `targetSecret` name + the SA name
   stay `default`).
2. Add both filenames to the namespace's `kustomization.yaml`
   under `resources:`.
3. Argo syncs → ESO materializes the Secret → kubelet picks
   it up on next pull attempt.

**Mixed-image safety:** kubelet scopes dockerconfigjson lookups
by registry host, so adding the pull cred to a namespace that
also pulls third-party images (e.g., llm-gateway pulls
`mcr.microsoft.com/presidio-*` for the Presidio sidecars) is
safe — the third-party pulls remain anonymous.

**Mixed-trust SAs:** if a namespace has workloads with
divergent trust requirements (e.g., one Deployment that
must NOT have access to the registry credential), create
dedicated ServiceAccounts and attach `imagePullSecrets` per
workload instead of on `default`. None of the current four
pull-enabled namespaces (`llm-gateway`, `approval-channel`,
`ntfy-e2ee-relay`, `pr-agent`) have that constraint.

### Adjacent — Kyverno digest-pinning

The `require-first-party-image-digest` ClusterPolicy in
`infrastructure/kyverno/clusterpolicies.yaml` requires
`registry.homelab.internal/*` and `forgejo.lab/*` images to
be referenced by `@sha256:...` digest. It is currently
`validationFailureAction: Audit` (per the bring-up note in
that file). When flipped back to `Enforce` per ADR 0019 D3,
all four consumer Deployments above need to switch from
`:<tag>` to `@sha256:<digest>` image refs — tracked
separately in TODO.md.

## Caveats

1. **Single-replica Forgejo.** No HA at the app layer; pod
   eviction = brief git-push interruption. Resilience comes
   from CNPG Postgres + Longhorn snapshot + Restic tier-3
   per ADR 0006 + ADR 0023 D11. Per-pod restart on Talos
   node maintenance is the longest-running drop window.

2. **CNPG bootstrap-then-handoff timing.** CNPG `forgejo-pg`
   Cluster takes 30-90s to become Ready; Forgejo's pod will
   crashloop on `connection refused` until Postgres is up.
   Helm chart's startup probe accommodates; first sync may
   take a few minutes to settle.

3. **NFS PV recovery requires offline mount.** If the NAS is
   the only copy of LFS/Packages and the share is corrupted,
   recovery is via Restic tier-3 restore of the NAS share's
   snapshots, NOT via Longhorn. Backup-and-DR cadence per
   ADR 0006 covers this.

4. **`readOnlyRootFilesystem: true`** — Forgejo writes only
   to `/data` (Longhorn PVC), `/data/lfs` (NFS), `/data/packages`
   (NFS), and `/tmp` (emptyDir, mounted by chart). Verified
   per the helm chart's `extraVolumeMounts` setup.

5. **Forgejo Actions deferred** to phase 2 per ADR 0023 D3.
   Woodpecker is the phase-1 CI engine. When Forgejo Actions
   lands, runner manifests go in `homelab-k8s/platform/forgejo-actions/`
   (separate layer; doesn't replace Woodpecker, runs alongside).

6. **No Cloudflare Tunnel.** Source-of-truth stays
   Tailscale-only per ADR 0024 D4. The GitHub mirror is the
   "public-readable" surface for OSS visibility.

7. **GitHub mirror direction is unidirectional Forgejo → GitHub.**
   Bidirectional sync gets complex with PRs, branches, and
   issue tracking; it's intentionally not supported. If a
   commit lands directly on GitHub during a Forgejo outage,
   reconciliation is operator-manual (cherry-pick into Forgejo
   after recovery).

8. **PAT scoping is account-wide.** Forgejo PATs (as of 2026)
   don't have GitHub-style fine-grained per-repo / per-org
   scopes. Bots get dedicated accounts (e.g., `renovate-bot`,
   `woodpecker-bot`) to bound blast radius — see Renovate
   layer's caveat 1.

9. **Renovate compatibility.** Renovate's `platform: gitea`
   driver tracks the Gitea API; Forgejo has slowly diverged
   since the Feb 2024 fork. Pin the `renovate/renovate` image
   and bump deliberately; cross-check Forgejo release notes
   for API changes.

## Related

- [ADR 0023](../../../homelab-docs/02-decisions/0023-forgejo-and-woodpecker-ci.md)
  — forge + CI decisions.
- [ADR 0019](../../../homelab-docs/02-decisions/0019-forgejo-packages-as-artifact-registry.md)
  — Packages as artifact registry.
- [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  — Tailscale-only ingress; no Cloudflare for source-of-truth.
- [`platform/woodpecker/`](../woodpecker/) — CI engine that
  consumes Forgejo's OAuth + webhooks.
- [`platform/renovate/`](../renovate/) — dependency-update bot
  consuming Forgejo's API.
- [`platform/authentik/`](../authentik/) — IdP for OIDC login.
- [04-guides/known-caveats.md §Forgejo](../../../homelab-docs/04-guides/known-caveats.md)
  — accumulated index.
- [03-runbooks/forgejo/](../../../homelab-docs/03-runbooks/forgejo/) —
  GitHub-mirror setup + rotation + migration runbooks.
