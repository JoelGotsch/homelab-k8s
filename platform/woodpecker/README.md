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
| `kustomization.yaml` | Helm chart 3.6.5; resources below. |
| `values.yaml` | Server + agent config. SQLite DB on Longhorn; Forgejo OAuth integration; Kubernetes backend (step Pods spawn in `ci-woodpecker`). |
| `rbac.yaml` | Cross-ns Role + RoleBinding so the agent's SA can manage step Pods in `ci-woodpecker`. Step-Pod SA has no kube-API access. |
| `quota.yaml` | ResourceQuota + LimitRange on `ci-woodpecker` (per ADR 0023 D5). |
| `externalsecret.yaml` | `kv/woodpecker/oauth` (Forgejo OAuth client) + `kv/woodpecker/agent-token` (per-agent registration token, seeded post-bring-up via the Woodpecker UI). |
| `httproute.yaml` | Cilium HTTPRoute for `woodpecker.lab.<HOMELAB-DOMAIN>`; Tailscale-only. |
| `networkpolicy.yaml` | Server, agent, and ci-woodpecker default-deny + curated egress (FQDN-aware CCNP for upstream registries). |
| `servicemonitor.yaml` | Prometheus scrape of server `/metrics`. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/woodpecker/oauth` | `client_id`, `client_secret` | From Forgejo — operator creates the OAuth2 application in Forgejo (Settings → Applications → OAuth2 Applications → Create), then copies values. |
| `kv/data/woodpecker/agent-secret` | `token` | Server-side shared "system" agent secret (`WOODPECKER_AGENT_SECRET`). Random, script-seeded: `seed-random-secret.sh kv/woodpecker/agent-secret token`. Pinned 2026-08-16 so the chart stops minting a new one per render (`server.createAgentSecret: false`). Only gates system-token registration of new agents; rotation = re-seed `--force`, refresh the ExternalSecret, delete the server pod (OnDelete) in a no-CI window. |
| `kv/data/woodpecker/agent-token` | `token` | Per-agent token — operator-filled after the server is up: Woodpecker UI → Settings → Agents → agent detail → token (ADR 0046 manual mint; rotated end-to-end 2026-07-29). Projected as `WOODPECKER_AGENT_TOKEN` + `WOODPECKER_AGENT_SECRET` on the agent. |

**First-install seed:**

```sh
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
| Operator seeds `kv/woodpecker/oauth` | ESO can populate the OAuth Secret. |
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
   ADR 0036 requires the small build-history volume to use a
   Retain-policy class. Source still selects `longhorn-replica2`
   until the attended KST-03 claim migration; the retention
   contract records this as a known mismatch. Tier-1 Longhorn
   snapshots exist, but no independent tier-3 membership is
   currently declared. If churn grows, switch to CNPG via
   `WOODPECKER_DATABASE_DRIVER=postgres`.

   The separate agent `agent-config` claim contains only reconstructable
   configuration. Its live StatefulSet template predates the explicit storage
   contract and omits the immutable `storageClassName` field. Source therefore
   keeps the pinned chart's `agent.persistence.storageClass` explicitly empty,
   which renders the key absent and lets the claim resolve to the sole cluster
   default, `longhorn-replica2` (`Delete`). The retention gates hard-bind this
   as the only implicit-default exception and reject a second/moved omission,
   a different/default-missing StorageClass, a present-but-empty rendered key,
   or source/`.j2` drift. KST-03 owns an attended recreation of only the
   StatefulSet controller under an explicit template. Preserve and reuse the
   existing `agent-config-*` PVC; after verifying that PVC remains on
   `longhorn-replica2` and the agent is healthy, retire the exception and
   restore the explicit chart value atomically. Do not delete/recreate the PVC
   or make that immutable controller change unattended.

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
