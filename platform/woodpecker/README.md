# platform/woodpecker

Woodpecker CI — phase-1 CI engine per
[ADR 0023](../../../homelab-docs/02-decisions/0023-forgejo-and-woodpecker-ci.md)
D2. Forgejo Actions is the deferred phase-2 second engine
(per ADR 0023 D3); not scaffolded today.

Server + agent run in the `woodpecker` namespace. Step Pods
spawn in the `ci-woodpecker` namespace, isolated by:
- Separate ServiceAccount (`ci-woodpecker-runner`) with NO
  kube-API permissions.
- Restrictive NetworkPolicy: default-deny ingress; egress
  to kube-DNS + Forgejo + curated CCNP toFQDNs (registries).
- ResourceQuota + LimitRange capping CPU/memory/pod-count
  per namespace.
- Pod-per-step lifecycle: each pipeline step gets a fresh
  Pod, torn down at step end.

Per ADR 0023 D5 + D6 + D8 + D9.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `woodpecker` (control plane) + `ci-woodpecker` (step Pods); both PSA restricted. |
| `kustomization.yaml` | Helm chart 3.4.0; resources below. |
| `values.yaml` | Server + agent config. SQLite DB on Longhorn; Forgejo OAuth integration; Kubernetes backend (step Pods spawn in `ci-woodpecker`). |
| `rbac.yaml` | Cross-ns Role + RoleBinding so the agent's SA can manage step Pods in `ci-woodpecker`. Step-Pod SA has no kube-API access. |
| `quota.yaml` | ResourceQuota + LimitRange on `ci-woodpecker` (per ADR 0023 D5). |
| `externalsecret.yaml` | `kv/woodpecker/agent-secret` (server↔agent shared) + `kv/woodpecker/oauth` (Forgejo OAuth client). |
| `httproute.yaml` | Cilium HTTPRoute for `woodpecker.lab.<HOMELAB-DOMAIN>`; Tailscale-only. |
| `networkpolicy.yaml` | Server, agent, and ci-woodpecker default-deny + curated egress (FQDN-aware CCNP for upstream registries). |
| `servicemonitor.yaml` | Prometheus scrape of server `/metrics`. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/woodpecker/agent-secret` | `token` | Random — both server and agent read this; agent presents it on connection. Rotate via re-seed + helm rollout. |
| `kv/data/woodpecker/oauth` | `client_id`, `client_secret` | From Forgejo — operator creates the OAuth2 application in Forgejo (Settings → Applications → OAuth2 Applications → Create), then copies values. |

**First-install seed:**

```sh
# Agent shared secret — random.
homelab-infra/scripts/seed-random-secret.sh \
    kv/woodpecker/agent-secret token

# OAuth client — provisioned via API helper (creates the
# Forgejo OAuth2 app + seeds OpenBao in one shot). Operator
# must have $FORGEJO_TOKEN set (admin PAT from Forgejo's
# Settings → Applications → Tokens after first login).
FORGEJO_URL=https://forgejo.lab.<HOMELAB-DOMAIN> \
FORGEJO_TOKEN="$(bao kv get -field=admin_pat kv/forgejo/admin)" \
homelab-infra/scripts/provision-forgejo-oauth-app.sh \
    --app-name Woodpecker \
    --redirect-uri \
      "https://woodpecker.lab.<HOMELAB-DOMAIN>/authorize" \
    --kv-path kv/woodpecker/oauth

# Manual fallback (Settings → Applications → OAuth2 →
# Create new):
# bao kv put kv/woodpecker/oauth \
#     client_id="<paste-from-forgejo>" \
#     client_secret="<paste-from-forgejo>"
```

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync `platform/forgejo/` | Forgejo up; operator creates OAuth2 app. |
| Operator seeds `kv/woodpecker/{agent-secret,oauth}` | ESO can populate Secrets. |
| Argo sync this layer | Server + agent Deployments Ready; HTTPRoute reconciled; first pipeline can run on next webhook. |
| Operator pushes a `.woodpecker.yml` to a Forgejo repo + a commit | First pipeline triggers via webhook → agent spawns step Pods in `ci-woodpecker`. |

## Post-bring-up activation (one-time)

### 1. Create the Forgejo OAuth2 application

In Forgejo: Settings → Applications → OAuth2 Applications →
Create new OAuth2 application:

- **Application Name**: `Woodpecker`
- **Redirect URI**: `https://woodpecker.lab.<HOMELAB-DOMAIN>/authorize`
- **Confidential Client**: yes

Forgejo prints `client_id` + `client_secret`. Seed both into
OpenBao via the snippet above.

### 2. First login

Visit `https://woodpecker.lab.<HOMELAB-DOMAIN>/`, click "Login
with Forgejo." Operator's Forgejo account becomes the admin
(matches `WOODPECKER_ADMIN` in values.yaml).

### 3. Activate a repo

In Woodpecker UI: Repos → Activate. Select the Forgejo repos
to enable CI on. Activation registers a webhook in Forgejo;
push events trigger pipelines.

### 4. First pipeline

Add a `.woodpecker.yml` (or `.woodpecker/*.yml`) to the repo's
root. Push. The agent spawns step Pods in `ci-woodpecker` per
the pipeline spec.

Example minimal pipeline:

```yaml
when:
  - event: push

steps:
  - name: hello
    image: alpine:3.20
    commands:
      - echo "hello from ci-woodpecker"
```

## Caveats

1. **SQLite DB on Longhorn** — Woodpecker's job state DB is
   not CNPG-backed; it's per-pod SQLite on a Longhorn PVC.
   Resilience via Longhorn snapshot + Restic tier-3.
   Pipeline-execution state is recoverable but not
   high-frequency-backed up; a few hours of pipeline history
   loss is acceptable on a worst-case restore. If churn
   grows, switch to CNPG via `WOODPECKER_DATABASE_DRIVER=postgres`.

2. **Single agent replica + 4 concurrent workflows.** At
   homelab scale this caps total parallel step Pods at ~8
   (pipelines × steps-in-flight). Increase
   `WOODPECKER_MAX_WORKFLOWS` or scale agent replicas if
   queue depth becomes painful.

3. **Step Pods can talk to upstream registries via the CCNP
   toFQDNs allowlist** — not unrestricted internet egress.
   New pipeline → unlisted registry → "connection refused"
   → operator extends `networkpolicy.yaml` `toFQDNs` list.
   Same pattern as `platform/renovate/`.

4. **No Forgejo Actions runner** (D3 deferred). Woodpecker
   is the only CI engine in phase 1. When Forgejo Actions
   lands as phase 2, the runner manifests live in a separate
   layer `platform/forgejo-actions/`; both run alongside.

5. **OAuth-app config ties Woodpecker to Forgejo's URL.**
   If Forgejo's hostname changes (operator-fillable
   `<HOMELAB-DOMAIN>` change), the OAuth2 app's Redirect URI
   in Forgejo must update too — otherwise the login callback
   404s. Re-seed `kv/woodpecker/oauth` if Forgejo issues
   new credentials.

6. **Step Pod images pulled per-step.** No image-pull cache
   is shared across step Pods today; each step's image pulls
   from upstream. Spegel (DaemonSet) caches by digest at
   the node level, so repeated pulls of the same image hit
   the cache. New images on a fresh node = full pull.

7. **Step Pods inherit the `ci-woodpecker` ResourceQuota.**
   A pipeline declaring step `resources: requests: cpu: 4`
   when only 2 vCPU remains in the namespace quota will
   fail to schedule. Operator tunes quota.yaml as the
   pipeline mix grows.

8. **No SBOM/cosign signing built in.** ADR 0023 D9 calls
   for cosign signing + SBOM generation in CI; that's
   pipeline-side discipline (each per-app `.woodpecker.yml`
   includes the steps), not server config. Skeleton
   pipeline templates land alongside the first first-party
   app pipeline (out of scope for this layer).

## Related

- [ADR 0023](../../../homelab-docs/02-decisions/0023-forgejo-and-woodpecker-ci.md)
  — CI engine decisions (D2, D5, D6, D8, D9).
- [ADR 0019](../../../homelab-docs/02-decisions/0019-forgejo-packages-as-artifact-registry.md)
  — registry that Woodpecker pushes to.
- [`platform/forgejo/`](../forgejo/) — the OAuth provider +
  webhook source.
- [`platform/renovate/`](../renovate/) — separate dependency-
  update bot; can run on Woodpecker as a phase-2 alternative
  to the CronJob.
- [04-guides/known-caveats.md §Woodpecker](../../../homelab-docs/04-guides/known-caveats.md)
  — accumulated index.
