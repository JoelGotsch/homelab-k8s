# bootstrap/argocd

Argo CD self-management layer. Per
[ADR 0027](../../../homelab-docs/02-decisions/0027-argocd-self-managing.md)
(supersedes ADR 0004's "Argo CD does not manage itself" framing).

## What this is

A Kustomize layer that pulls upstream Argo CD's `install.yaml`
at a pinned version and applies operator-customised patches.
It's reconciled by Argo CD itself via the `argocd-self`
Application at [`../argocd-self.yaml`](../argocd-self.yaml),
which is included in the root kustomization.

Once the root-app syncs (post-bootstrap), Argo CD takes
ownership of its own deployment. From that point:

- **Routine upgrades** → bump `<ARGOCD_VERSION>` in
  `kustomization.yaml`, commit, Argo reconciles, rolls itself.
- **Recovery** → re-run the bootstrap Ansible playbook (kustomize
  apply of `homelab-infra/argocd/install/`); root-app syncs; this
  Application reconciles Argo to the desired version. No separate
  recovery runbook.
- **Configuration changes** → edit patches here, commit, Argo
  applies via ServerSideApply.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Pulls upstream Argo CD `install.yaml` at `<ARGOCD_VERSION>` + applies patches. |
| `patches/argocd-cmd-params.yaml` | CLI flags (reconcile interval, log format JSON for Loki). |
| `patches/argocd-cm.yaml` | Main config (`url`, resource exclusions). |
| `patches/server-resources.yaml` | argocd-server resource limits. |
| `patches/repo-server-resources.yaml` | argocd-repo-server resource limits. |
| `patches/application-controller-resources.yaml` | argocd-application-controller resource limits. |
| `patches/oidc-config.yaml` | Authentik OIDC config — un-commented in `kustomization.yaml` patches[] when Authentik is up. |

## Operator first-commit fills

Search for `<` placeholders and replace before applying:

| Placeholder | Where | Source |
|---|---|---|
| `<ARGOCD_VERSION>` | `kustomization.yaml` | Same as `argocd_version` in `homelab-infra/ansible/inventory/group_vars/all.yml`. **MUST match the bootstrap-time version** at first commit (otherwise the self-managing sync would immediately diverge from what Ansible installed). |
| `<HOMELAB_INTERNAL_DOMAIN>` | `patches/argocd-cm.yaml` | Operator's domain (e.g. `home.example.com`). |
| `<HOMELAB_INTERNAL_DOMAIN>` | `patches/oidc-config.yaml` | Same. |
| `<AUTHENTIK_CLIENT_ID_ARGOCD>` | `patches/oidc-config.yaml` | Created in Authentik at OIDC client setup time. |
| `<HOMELAB_K8S_REPO_URL>` | `../argocd-self.yaml` | Forgejo URL of this repo. |
| `<HOMELAB_K8S_REPO_REVISION>` | `../argocd-self.yaml` | Branch / tag (e.g. `main`). |

## Bootstrap → self-management handoff

The bootstrap-time install lives at
`homelab-infra/argocd/install/` (Jinja-rendered kustomize
applied by Ansible). After bootstrap:

1. Ansible applies the bootstrap kustomize → Argo CD pods come up.
2. Ansible applies the root-app → Argo starts reconciling
   `homelab-k8s/bootstrap/`.
3. The root-app sync includes this `argocd-self` Application →
   Argo applies the kustomize from this directory via SSA.
4. Argo CD now owns itself.

The two kustomize layers (homelab-infra side + this side) are
intentionally close-to-identical at first commit — same upstream
base, same patches. Drift between them is detectable; the
`scripts/check-values-drift.sh` pattern in `homelab-infra/`
extends to cover argocd as a follow-up.

## Caveats

1. **`<ARGOCD_VERSION>` placeholder must match bootstrap version
   at first commit.** A mismatch causes the first self-managing
   sync to immediately upgrade (or downgrade) Argo from what
   Ansible just installed. Operator-fillable; check at commit time.
2. **Patches here mirror `homelab-infra/argocd/install/patches/`
   at first commit.** Drift between the two is fine post-bootstrap
   (this side becomes source of truth) but at first install they
   should match. Drift-check follow-up tracked in TODO.
3. **OIDC patch deferred-with-comment** — Authentik client is
   created post-Authentik-bring-up. Until then, Argo CD admin
   password is the only login path (ESO-projected from OpenBao
   `kv/argocd/admin-password`).
4. **Sync wave -100** on the `argocd-self` Application — Argo
   updates itself before reconciling everything else. If a
   bad Argo upgrade ever lands, Argo may not be healthy enough
   to roll back automatically; manual `kubectl apply` of the
   prior bootstrap kustomize is the recovery path (per ADR 0027).
5. **`prune: false`** on `argocd-self` — removing this layer's
   resources would delete Argo CD itself. selfHeal corrects drift
   without destroying the deployment. Pruning is opt-in via
   manual sync if needed.
6. **ServerSideApply is required.** Inherited from the root-app's
   global `ServerSideApply=true` syncOption; also set on this
   Application explicitly. Removing either would break field
   ownership between Ansible's bootstrap apply and Argo's
   reconciliation.

## OpenBao paths to seed

| Path | Keys | Consumer |
|---|---|---|
| `kv/argocd/admin-password` | `password` | `externalsecret.yaml` (admin login until OIDC) |
| `kv/argocd/oidc` | `client_id`, `client_secret` | `externalsecret.yaml` → `oidc.authentik` Secret |
| `kv/argocd/forgejo-repo-cred` | `username`, `token` | `externalsecret-repo-forgejo.yaml` → Argo repo credential for in-cluster Forgejo (ADR 0037) |

Seed snippet for the repo credential (generates the `svc-argocd`
PAT inside the forgejo pod and pipes it into OpenBao without it
ever landing on a terminal; `bao login` first):

```sh
kubectl exec -n forgejo deploy/forgejo -c forgejo -- \
    forgejo admin user generate-access-token -u svc-argocd \
    -t argocd-repo-read --scopes read:repository --raw | tail -1 | \
  kubectl exec -i -n openbao openbao-0 -- \
    sh -c 'read T; bao kv put kv/argocd/forgejo-repo-cred username=svc-argocd token="$T"'
```

The `svc-argocd` bot must exist and be a read-only collaborator on
`forgejo-admin/homelab-k8s` (created 2026-07-11; recreate at cold
start via `forgejo admin user create` + the collaborators API).

## Related

- [ADR 0037](../../../homelab-docs/02-decisions/0037-argocd-pulls-from-forgejo.md)
  — Argo pulls from in-cluster Forgejo; GitHub mirror is the
  cold-start + break-glass source.
- [ADR 0027](../../../homelab-docs/02-decisions/0027-argocd-self-managing.md)
  — the self-managing pattern + supersedence of ADR 0004 D4.
- [ADR 0004](../../../homelab-docs/02-decisions/0004-argocd-for-gitops.md)
  — the original GitOps-via-Argo decision; D4 ("Argo CD does
  not manage itself") superseded by ADR 0027.
- [`homelab-infra/argocd/install/`](../../../homelab-infra/argocd/install/)
  — bootstrap-time kustomize; runs once; this layer takes over.
- [`homelab-infra/ansible/playbooks/09b-argocd-bootstrap.yml`](../../../homelab-infra/ansible/playbooks/09b-argocd-bootstrap.yml)
  — bootstrap orchestration.
- [99-journal/2026-04-30-argocd-self-managing.md](../../../homelab-docs/99-journal/2026-04-30-argocd-self-managing.md)
  — implementation journal.
