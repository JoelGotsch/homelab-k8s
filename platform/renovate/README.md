# platform/renovate

Self-hosted Renovate runner. Scans every repo under the
`homelab` organization weekly, opens dependency-update PRs
against each, and emits a per-repo Dependency Dashboard issue.

Per [ADR 0023](../../../homelab-docs/02-decisions/0023-forgejo-and-woodpecker-ci.md)
(Forgejo as source of truth) +
[update-policy.md](../../../homelab-docs/01-architecture/update-policy.md)
("Renovate is the dependency-update bot").

**Renovate runs against Forgejo only — never against GitHub.**
The unidirectional Forgejo → GitHub mirror is a recovery path,
not a Renovate target. Pre-Forgejo (during cluster bring-up),
no Renovate runs anywhere; manual bumps fill the gap.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `renovate` ns; PSA restricted. |
| `serviceaccount.yaml` | Dedicated SA; `automountServiceAccountToken: false`. No cluster RBAC needed. |
| `configmap.yaml` | Renovate global config (`config.js`): `platform: gitea`, endpoint, autodiscover filter, JSON logging. |
| `externalsecret.yaml` | OpenBao `kv/platform/renovate/forgejo-token` → `RENOVATE_TOKEN`. |
| `cronjob.yaml` | Weekly Saturday 05:00 UTC scan. **`spec.suspend: true` until operator activates.** |
| `networkpolicy.yaml` | Vanilla: kube-DNS + Forgejo. CCNP: FQDN-aware allow for known upstream registries. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field | Source |
|---|---|---|
| `kv/platform/renovate/forgejo-token` | `token` | Forgejo PAT for the `renovate-bot` user. Generated in Forgejo's web UI: Settings → Applications → Generate New Token. Required scopes: `read:repository`, `write:repository`, `write:issue`. Token is account-wide per Forgejo (see Caveat 1). |

## Post-Forgejo activation (one-time)

Activated 2026-07-16. At activation time `forgejo-admin` was a
plain Forgejo **user** namespace (no Organization existed), so
access was granted per-repo (step 2). Since the 2026-07-30
user→org migration all repos live in the `homelab` organization
and the bot's access comes from the org `bots-write` team
(`migrate-repos-to-forgejo-org.sh` ensures it); step 2 is only
historical context.

### 1. Bot account + PAT + OpenBao seed (scripted)

```sh
FORGEJO_URL=https://forgejo.lab.vyramo.com \
FORGEJO_TOKEN="$(bao kv get -field=admin_pat kv/forgejo/admin)" \
homelab-infra/scripts/provision-forgejo-bot-pat.sh \
    --bot-username renovate-bot \
    --bot-email renovate-bot@invalid.local \
    --kv-path kv/platform/renovate/forgejo-token \
    --token-name renovate-runner-cluster \
    --scopes "read:repository,write:repository,write:issue"
```

The script creates the user, issues the PAT, and seeds OpenBao
(no `--org-name` — see above).

**Manual fallback** (if the script can't reach Forgejo, e.g.,
during a partial outage):

- Web UI → Site Administration → User Accounts → Create User
  (`renovate-bot`, a placeholder email, random password)
- Login as `renovate-bot` → User Settings → Applications →
  Generate New Token (scopes: read:repository, write:repository,
  write:issue)
- `bao kv put kv/platform/renovate/forgejo-token token=<paste>`
- Then still run step 2 below (or its manual fallback) — a PAT
  alone doesn't grant repo access without a collaborator/org
  membership grant.

### 2. Repo access (scripted)

```sh
FORGEJO_URL=https://forgejo.lab.vyramo.com \
FORGEJO_TOKEN="$(bao kv get -field=admin_pat kv/forgejo/admin)" \
homelab-infra/scripts/grant-forgejo-bot-repo-access.sh \
    --bot-username renovate-bot \
    --owner homelab \
    --permission write
```

Enumerates every repo under the given owner namespace live
via the API (not a static list — new repos are picked up
automatically on re-run) and grants `renovate-bot` write
collaborator access. Idempotent; safe to re-run after adding
new repos.

**Manual fallback**: per repo, Settings → Collaborators → Add
Collaborator → `renovate-bot`, permission `write`.

### 3. Flip suspend

Edit `cronjob.yaml`:

```yaml
spec:
  suspend: false   # was: true
```

Commit + push to homelab-k8s; Argo reconciles.

### 4. Trigger an on-demand run (verify)

```sh
kubectl -n renovate create job --from=cronjob/renovate \
  renovate-manual-$(date +%s)
kubectl -n renovate logs -l app.kubernetes.io/name=renovate \
  --tail=200 --follow
```

Successful run signature: `INFO Repository finished` per repo,
no `ERROR` lines, Dependency Dashboard issue created or
updated in each scanned repo.

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync `platform/forgejo/` | Forgejo Service + Deployment Healthy. |
| Argo sync `platform/renovate/` | This layer — namespace, ConfigMap, ESO, CronJob (suspended). |
| Operator runs Steps 1-3 above | CronJob un-suspended; ESO populates the Secret on next reconcile. |
| Saturday 05:00 UTC, then weekly | First scheduled scan. PRs land against repos with `renovate.json5`. |

## Caveats

1. **Forgejo PATs are account-wide** as of 2026 (no per-org
   or per-repo PAT scoping like GitHub fine-grained tokens).
   The dedicated `renovate-bot` account bounds blast radius
   — a compromised PAT yields what `renovate-bot` itself can
   touch (repos it's been added to as a collaborator only).

2. **Access comes from the `homelab` org's `bots-write` team**
   (includes_all_repositories — new org repos are covered
   automatically) since the 2026-07-30 user→org migration. No
   "GitHub App"-style installation model exists in Forgejo
   either way; the bot is a regular user. Pre-migration it was
   a per-repo collaborator via
   `grant-forgejo-bot-repo-access.sh` — that script remains
   useful for one-off grants outside the org, but isn't
   triggered automatically on repo creation. If the operator
   later creates a real Forgejo Organization, this step could
   move to org-team membership instead (`provision-forgejo-bot-pat.sh`
   already supports `--org-name`/`--org-team`).

3. **`platform: gitea` may lag Forgejo API divergence.**
   Forgejo's API was Gitea-compatible at fork (Feb 2024) and
   has slowly diverged. Renovate's Gitea platform driver
   tracks the Gitea API; if Forgejo introduces a breaking
   change, Renovate may temporarily fail until upstream
   patches. Pin the `renovate/renovate` image; bump
   deliberately when readme + release notes confirm Forgejo
   compat.

4. **Dependency Dashboards are per-repo**, not consolidated.
   Each repo emits its own Dashboard issue; cross-repo view
   is via Forgejo's issue search (filter by author =
   `renovate-bot`).

5. **CCNP egress allowlist is curated, not exhaustive.**
   `networkpolicy.yaml` enumerates the registry FQDNs known
   to surface in homelab manifests today. A new manifest
   referencing an unlisted registry → Renovate logs
   "connection refused" → operator extends the `toFQDNs`
   list.

6. **Pre-Forgejo: no Renovate.** During cluster bring-up
   (homelab-infra Ansible + early homelab-k8s Argo), there
   is no Renovate running — operator is hands-on and bumps
   pinned versions manually. CVE landings during this window
   require manual operator attention; the
   [external-dependencies.md security-feed monitoring](../../../homelab-docs/01-architecture/external-dependencies.md)
   row covers detection. (Historical note: this window ran
   far longer than intended in practice — Forgejo went
   healthy 2026-05-02 but activation didn't happen until
   2026-07-16, ten weeks later, during which Forgejo itself
   drifted to an EOL version undetected. See the journal
   entry for that date.)

7. **Argo and `spec.suspend`.** Once the operator flips
   `suspend: false` in the local checkout and pushes,
   subsequent Argo syncs will keep `suspend: false` —
   Argo reconciles the file as written. To re-suspend,
   edit `cronjob.yaml` and push.

## Related

- [ADR 0023](../../../homelab-docs/02-decisions/0023-forgejo-and-woodpecker-ci.md)
  — Forgejo as forge.
- [update-policy.md](../../../homelab-docs/01-architecture/update-policy.md)
  — Renovate as the policy-matrix bot.
- [`homelab-infra/renovate-presets/default.json5`](../../../homelab-infra/renovate-presets/default.json5)
  — central preset every per-repo `renovate.json5` extends.
- [`platform/forgejo/`](../forgejo/) — the runtime target.
- [`04-guides/known-caveats.md`](../../../homelab-docs/04-guides/known-caveats.md)
  §Renovate self-hosted — accumulated index.
