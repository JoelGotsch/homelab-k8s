# platform/renovate

Self-hosted Renovate runner. Scans every repo in the Forgejo
`<FORGEJO_ORG>` org weekly, opens dependency-update PRs against
each, and emits a per-repo Dependency Dashboard issue.

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

The layer ships dormant — Argo applies the manifests but the
CronJob's `spec.suspend: true` keeps it idle. After Forgejo +
Woodpecker are Healthy at cold-start Step 13:

### 1. Create the bot account in Forgejo

Web UI → Site Administration → User Accounts → Create User
Account:

- **Username**: `renovate-bot`
- **Email**: `<RENOVATE_BOT_EMAIL>` (matches `gitAuthor` in
  `configmap.yaml`)
- **Password**: from `openssl rand -hex 32`; not stored
  anywhere — the bot authenticates via PAT.
- **Active**: yes; **Admin**: no.

### 2. Add the bot to the org

Site Administration → Organizations → `<FORGEJO_ORG>` → Teams
→ Add member → `renovate-bot`. Team permission: **Read**
(autodiscover only needs read; per-repo PR creation works via
the bot's PAT, not via team write).

For repos where Renovate must open PRs, add `renovate-bot` as
a repo collaborator with **Write** permission. Alternative:
make the team **Write** if every repo in the org should be
PR-able.

### 3. Generate the PAT

As `renovate-bot` (login → User Settings → Applications →
Generate New Token):

- **Token name**: `renovate-runner-cluster`
- **Selected scopes**: `read:repository`, `write:repository`,
  `write:issue`.

### 4. Seed OpenBao

```sh
bao kv put kv/platform/renovate/forgejo-token token=<paste-PAT>
```

### 5. Flip suspend

Edit `cronjob.yaml`:

```yaml
spec:
  suspend: false   # was: true
```

Commit + push to homelab-k8s; Argo reconciles.

### 6. Trigger an on-demand run (verify)

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
| Operator runs Steps 1-5 above | CronJob un-suspended; ESO populates the Secret on next reconcile. |
| Saturday 05:00 UTC, then weekly | First scheduled scan. PRs land against repos with `renovate.json5`. |

## Caveats

1. **Forgejo PATs are account-wide** as of 2026 (no per-org
   or per-repo PAT scoping like GitHub fine-grained tokens).
   The dedicated `renovate-bot` account bounds blast radius
   — a compromised PAT yields what `renovate-bot` itself can
   touch (read on the org; write where added as collaborator).

2. **No "GitHub App"-style installation** in Forgejo. The bot
   is a regular user; org admin adds it as a member. New
   repos in the org inherit team permissions but new repos
   *outside* the org need the operator to add `renovate-bot`
   as a collaborator manually.

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
   row covers detection.

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
