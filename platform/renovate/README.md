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
| `namespace.yaml` | `renovate` ns; PSA restricted; `homelab.lab/inject-ca=true` so trust-manager drops the `homelab-root-ca` ConfigMap here. |
| `serviceaccount.yaml` | Dedicated SA; `automountServiceAccountToken: false`. No cluster RBAC needed. |
| `configmap.yaml` | Renovate global config (`config.js`): `platform: forgejo`, endpoint, autodiscover filter, `minimumReleaseAgeBehaviour: timestamp-optional` (Caveat 9), `hostRules`: `allowInternal` grants for the two cluster-VIP hosts plus a `hostType: docker` credential for both names of the Forgejo Packages registry — `registry.homelab.internal` (in-cluster `registry-direct`) and `forgejo.lab.vyramo.com` (gateway path, what app Dockerfiles pin). Rendered from the `.j2` sibling by `00-render-static.yml`. |
| `externalsecret.yaml` | OpenBao `kv/platform/renovate/forgejo-token` → `RENOVATE_TOKEN`. |
| `externalsecret-github-token.yaml` | OpenBao `kv/renovate/github` → `GITHUB_COM_TOKEN` (github-releases / github-tags datasources, release notes). Operator-minted; the env ref is `optional` so an unseeded path only darkens the GitHub deps, not the run. |
| `registry-pull-secret.yaml` | OpenBao `kv/argocd/registry-pull` (the `read:package` bot Argo's repo-server already uses) → `HOMELAB_REGISTRY_USERNAME/PASSWORD` → `config.js` `hostRules`. |
| `cronjob.yaml` | Weekly Saturday 05:00 Europe/Berlin (`spec.timeZone`) scan, inside the preset's `before 08:00 on saturday` window. Runs `renovate/renovate:44.82.0@sha256:965b516a…` (Caveat 3). Mounts the `homelab-root-ca` bundle for `NODE_EXTRA_CA_CERTS`. |
| `networkpolicy.yaml` | Vanilla: kube-DNS + Forgejo. CCNP: FQDN-aware allow for known upstream registries (incl. `api.opentofu.org` / `registry.opentofu.org` for the OpenTofu-initialised lock file in homelab-infra). |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field | Source |
|---|---|---|
| `kv/platform/renovate/forgejo-token` | `token` | Forgejo PAT for the `renovate-bot` user. Generated in Forgejo's web UI: Settings → Applications → Generate New Token. Required scopes: `read:repository`, `write:repository`, `write:issue`, `read:user`, `read:organization`. **`read:user` is not optional** — Renovate calls `GET /api/v1/user` on platform init and aborts if it 403s; see Caveat 8. Token is account-wide per Forgejo (see Caveat 1). |
| `kv/renovate/github` | `token` | github.com personal access token, **read-only, public repositories only** (fine-grained PAT, no repository access needed — the "Public repositories" scope is enough; classic PATs need no scopes at all). Operator-minted at github.com → Settings → Developer settings; no script in this estate can create it. Exposed as `GITHUB_COM_TOKEN` so the `github-releases` / `github-tags` datasources and changelog fetches are authenticated: unauthenticated `api.github.com` is capped at 60 requests/hour, which is why `talos_version` / `argocd_version` in `homelab-infra` never received a PR. Seed: put it in `homelab-infra/ansible/vars/secrets.sops.yaml` as `homelab_secrets.renovate_github_token` (Nitrokey workstation), then run `homelab-infra/scripts/seed-openbao-paths.sh` — its SOPS phase runs `scripts/verify/github-public-read-pat.sh` (accepted at api.github.com, 5,000/h, no OAuth scopes) and writes only on acceptance; the value never enters argv. Then `kubectl -n renovate annotate externalsecret renovate-github-token force-sync=$(date +%s) --overwrite`. |
| `kv/argocd/registry-pull` | `username` `token` | **Not seeded here** — already minted for Argo's repo-server (`bootstrap/argocd/`, `provision-forgejo-bot-pat.sh --bot-username argocd-chart-pull --scopes read:package`). This layer is a second consumer: `registry-pull-secret.yaml` projects it so `config.js` can authenticate the `docker` datasource to `registry.homelab.internal`, which refuses anonymous reads. |

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
    --token-name renovate-runner-cluster
```

**Do not pass `--scopes` here.** The script's built-in default is
`read:user,read:organization,write:repository,write:issue` and it is
authoritative — it carries the fix for the 2026-07-29 re-provisioning
where a PAT without `read:user` made Renovate 403 at boot. This README
used to override it with a list that omitted `read:user`, which
re-introduced that exact failure on 2026-08-22 (Caveat 8). An override
here can only drift from the script; the scope list in the seed table
above is for the manual web-UI path.

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
| Operator seeds `kv/renovate/github` | GitHub-hosted datasources light up on the next run; until then those deps are skipped, everything else proceeds. |
| Saturday 05:00 Europe/Berlin, then weekly | First scheduled scan. PRs land against repos with `renovate.json5`. |

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

3. **The runner is pinned `tag@digest` and does not bump itself.**
   `cronjob.yaml` runs `renovate/renovate:44.82.0@sha256:965b516a…`
   (the multi-arch index digest) since the 2026-09-11 cutover. Earlier
   that day the same line was pinned to `38.142.7@sha256:8327ee17…`,
   ending the floating `:38` tag that Kyverno's
   audit-third-party-image-digest had flagged on every run. Renovate's
   `kubernetes` manager has no default file pattern and none is
   configured for this repo — the extraction stats list
   `helm-values`, `kustomize`, `woodpecker`, `regex` — so the bot
   never sees this image line. Bump deliberately: take the new
   tag's `docker-content-digest` from registry-1.docker.io (equals
   Docker Hub's tag-level `digest`, not the per-arch one), change
   tag and digest together, and for a major run a dry-run pod first
   (bare Pod, `restartPolicy: Never`, `RENOVATE_DRY_RUN=full`,
   `RENOVATE_REPOSITORIES=…`, a scratch ConfigMap for `config.js`;
   that is how 44 was rehearsed on 2026-09-11 against four repos).
   `platform: forgejo` is used since that cutover — the `gitea`
   driver still accepts Forgejo but warns "please use 'forgejo'
   platform instead" and its readme announces removal; Forgejo's
   API divergence from Gitea is therefore upstream's problem in the
   `forgejo` module, not ours to track. Follow-up owed in
   `homelab-infra/renovate-presets/default.json5`: its two
   `customManagers` still say `fileMatch`, which 44 auto-migrates to
   `managerFilePatterns` (`lib/config/migrations/custom/
   file-match-migration.ts`, wraps each pattern as `/…/`). Rename
   them now that nothing runs 38 any more — 38 would have rejected
   `managerFilePatterns` as unknown, which is why the rename could
   not precede the image.

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

8. **A missing token scope surfaces as `FATAL: Authentication
   failure`, not as a scope error.** Renovate calls `GET
   /api/v1/user` during platform init; Forgejo answers a token
   lacking `read:user` with 403 and the body `token does not have
   at least one of required scope(s): [read:user]`, which Renovate
   logs at info level only as "Error authenticating with Gitea.
   Check your token". The token is valid — rotating it changes
   nothing unless the scope list changes too. Broke the
   2026-08-22 run this way; the scope list in "OpenBao paths to
   seed" above had never included `read:user`, so every token this
   README ever produced was missing it — while
   `provision-forgejo-bot-pat.sh`'s own default has had `read:user`
   since 2026-07-29, when this same 403 was found and fixed there. The
   README's `--scopes` override silently un-did that fix; it has been
   removed rather than corrected. It only started mattering again when
   the then-floating `renovate/renovate:38` tag rolled forward — the
   CronJob pins `tag@digest` since 2026-09-11 (Caveat 3), so a runner
   change is now an operator commit, not a Saturday surprise.
   Read the body, not the FATAL line:

   ```sh
   kubectl -n renovate logs <pod> | grep -A2 'required scope'
   ```

9. **A 7-day soak needs a release timestamp, and most registries do
   not give one.** Since Renovate 42, `minimumReleaseAge` (the
   preset's global `7 days`) defaults to
   `minimumReleaseAgeBehaviour: timestamp-required`: a candidate
   version with no `releaseTimestamp` is parked under "Pending Status
   Checks" and never opens. The `docker` datasource only carries
   timestamps for Docker Hub (`tag_last_pushed`); ghcr.io, quay.io,
   registry.k8s.io, code.forgejo.org and `registry.homelab.internal`
   images have none. The 2026-09-11 dry-run rehearsal of 44.82.0 with
   the default parked exactly those updates while 38 (which treated a
   missing timestamp as "old enough") listed them; `config.js` sets
   `timestamp-optional` to keep the 38 semantics. Hub images still
   soak — `alpine/helm 3.22.0` sat in "Pending Status Checks" under
   both versions for that reason — but only while Hub's tag listing
   fits in ten pages: for `library/python` and `woodpeckerci/*` the
   Hub API answered page 11 with 403, Renovate fell back to the
   plain registry tag list ("Docker: error fetching data from
   DockerHub"), and those releases have no timestamp either. So the
   soak is best-effort for images and reliable for helm indexes,
   Galaxy, PyPI, github-releases and the Terraform/OpenTofu
   registries. If an image update you expect is missing from a
   dashboard, check this before the network policy.

10. **`internalHostAccess` will flip to `block`.** New in 44: every
    request to a private address logs "HTTP request to an internal
    host, which `internalHostAccess=block` would refuse" (our Forgejo
    endpoint and `registry.homelab.internal` are cluster VIPs), and
    upstream says the default becomes `block` in a future major with
    the `allow` escape hatch removed after that. `config.js` carries
    `allowInternal: true` hostRules for both hosts, which is the
    documented grant: the warning is gone under today's `warn` and
    the run completes under `block` (both rehearsed 2026-09-11). A
    new internal host Renovate must reach needs its own grant, or
    the next major refuses it outright.

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
