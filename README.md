# homelab-k8s

The GitOps truth. Everything Argo CD reconciles: cluster
infrastructure, platform services, observability, and app
deployment manifests. The app-of-apps root lives in
`bootstrap/`.

## Layout

```
bootstrap/
  kustomization.yaml                root kustomization
  bootstrap-namespaces.yaml         pre-created namespaces with PSA labels
  applicationsets/
    infrastructure.yaml             ApplicationSet — git directories generator
    platform.yaml                   over each subdir; one Argo Application
    observability.yaml              per dir.
    apps.yaml

infrastructure/                     sync wave -10
  cilium/                           CNI + Hubble + Gateway API
  cert-manager/                     issues internal TLS leafs from OpenBao PKI
  external-secrets/                 OpenBao kv/* → Kubernetes Secrets
  ingress/                          GatewayClass + Gateway + wildcard cert
  longhorn/                         block storage (replica2 default)
  nfs-csi/                          NAS shares (per-share StorageClass)
  kyverno/                          admission policies (cosign + digest pin)
  trust-manager/                    distributes Root CA to namespaces

platform/                           sync wave 0
  openbao/                          OpenBao day-2 + Raft snapshot CronJob
  authentik/                        OIDC provider (skeleton)
  forgejo/                          forge (skeleton)
  woodpecker/                       CI engine (skeleton)

observability/                      sync wave 5
  prometheus/, alertmanager/, grafana/, loki/, tempo/,
  falco/, crowdsec/, trivy-operator/                 (skeletons)

apps/                               sync wave 10
  vaultwarden/, nextcloud/, jellyfin/, llm-gateway/,
  knowledge-graph/, personal-agent/, signal-bridge/,
  whatsapp-bridge/, paperless/, immich/, frigate/,
  windmill/, website/                                (skeletons)

sets/                               kustomize overlay layer
  base/, prod/                                       (empty — single-env homelab)
```

## Bootstrap → ongoing handoff

Some components (Cilium, OpenBao) are **first installed by**
the bootstrap Ansible playbook in
`homelab-infra/ansible/playbooks/09b-argocd-bootstrap.yml`,
then **owned by** Argo CD via the manifests here. The values
files in this repo MUST match the bootstrap-time values in
`homelab-infra/ansible/files/<chart>-{values,overrides}.yaml`,
or be drifted from them deliberately for bootstrap-only
reasons.

After Argo takes over, all changes to those components flow
through this repo via PR.

## Operator first-commit fills

Search for `<` placeholders and replace before applying:

| Placeholder | Where | Source |
|---|---|---|
| `<REPO-URL>` | `bootstrap/applicationsets/*.yaml` | This repo's git URL (Forgejo or GitHub mirror) |
| `<CLUSTER-VIP>` | `infrastructure/cilium/values.yaml` | Cluster API VIP — fills post-cluster |
| `<HOMELAB-DOMAIN>` | `infrastructure/ingress/gateway.yaml`, `platform/openbao/httproute.yaml`, etc. | Operator's domain |
| `<NAS-IP>` | `infrastructure/nfs-csi/storageclasses.yaml` | NAS IP on `storage` VLAN |
| Root CA cert | `infrastructure/trust-manager/bundles.yaml` | OpenBao PKI root — `vault read -field=certificate pki/cert/ca` per ADR 0034 D2 (the `pki/ca-ceremony.md` path is DEFERRED per ADR 0034 D6) |
| OpenBao bootstrap CA | `infrastructure/cert-manager/openbao-pki-secret.yaml`, `infrastructure/external-secrets/clustersecretstore.yaml`, `infrastructure/trust-manager/bundles.yaml` | `homelab-infra/scripts/generate-openbao-bootstrap-tls.sh` output |

These are NOT templated via Jinja (no Argo-side templating
playbook yet); operator hand-fills at first commit. If
placeholder count grows, a `00-render-static.yml`-style
pattern similar to homelab-infra is the natural extension.

## Sync waves

| Wave | Layer | Notes |
|---|---|---|
| -10 | `infrastructure/*` | Comes up first; foundational |
| 0 | `platform/*` | Authentik / Forgejo / OpenBao day-2 |
| 5 | `observability/*` | After platform; parallel-able with apps |
| 10 | `apps/*` | After everything else |

Per-component overrides go via `argocd.argoproj.io/sync-wave`
annotations on individual manifests when finer ordering needed.

## What's NOT here

- **Per-app deep manifests** — operator's per-app
  initial-setup runbooks (under `homelab-docs/03-runbooks/`)
  populate each `apps/<name>/` subdir over time.
- **Argo CD bootstrap-time install** — `homelab-infra/argocd/install/`
  kustomize, applied once by the Ansible playbook. Per
  [ADR 0027](../homelab-docs/02-decisions/0027-argocd-self-managing.md)
  (supersedes ADR 0004 D4): post-bootstrap, Argo manages itself
  via the `argocd-self` Application at
  [`bootstrap/argocd-self.yaml`](bootstrap/argocd-self.yaml),
  which targets [`bootstrap/argocd/`](bootstrap/argocd/) and
  applies upstream Argo CD manifests via Server-Side Apply.
  Routine upgrades are GitOps PRs (bump the version pin in
  `bootstrap/argocd/kustomization.yaml`); recovery is "re-run
  bootstrap" — the same procedure as fresh install.
- **Bootstrap-time Helm releases** of Cilium + OpenBao —
  initial install is via
  `homelab-infra/ansible/playbooks/09b-argocd-bootstrap.yml`;
  Argo takes over via the manifests here.
- **Vector + Harbor + oauth2-proxy** dirs — removed; Vector
  superseded by Alloy (ADR 0021), Harbor superseded by Forgejo
  Packages (ADR 0019), oauth2-proxy unneeded since Authentik
  exposes OIDC directly.

## Development setup

Local sanity checks run via `pre-commit`:

```sh
pip install pre-commit  # one-time
pre-commit install      # one-time per checkout
# Now every `git commit` runs the configured hooks.

# Run on demand against the whole repo:
pre-commit run --all-files
```

Hooks are in [.pre-commit-config.yaml](.pre-commit-config.yaml);
each is a repo-local script under [scripts/](scripts/):

| Script | What it checks | Mode |
|---|---|---|
| `check-bare-tokens.sh` | bare ALL_CAPS placeholder tokens at value-bearing keys (`cidr:`, `server:`, `endpoint:`, etc.) — must be `<UPPER_SNAKE>` form so `check-placeholders.sh` catches them | pre-commit |
| `check-eso-readme.sh` | every kustomize layer with an ExternalSecret has the `## OpenBao paths to seed` section in its README | pre-commit |
| `check-placeholders.sh` | unfilled `<PLACEHOLDER>` tokens — **deploy-time** (cold-start.md Step 13a), not commit-time. Run manually before `kubectl apply -k` / Argo apply. | manual |
| `check-helm-values-keys.sh` | every key path in a layer's `values.yaml` exists in the chart's published `helm show values` tree — catches the wrong-chart-key class that bit 4 apps in the 2026-05-29→31 bring-up ([journal](../homelab-docs/99-journal/2026-05-31-langfuse-and-vaultwarden-bringup-saga.md)). v1 is manual-run because charts with undocumented back-compat shims produce false positives; a per-layer `.helmcheckignore` baseline-file refinement is queued in TODO. | manual |

Per the operator's "script everything scriptable now" policy:
new schema-pairing or cross-doc completeness checks land here
as scripts, not as deferred journal items.

## Argo CD Server-Side Apply — constraints worth knowing

Argo CD applies manifests with **Server-Side Apply** (SSA), not the
client-side `kubectl apply` (CSA) you might use locally. There are two
SSA constraints that are easy to forget and have already cost
debugging time this codebase:

1. **No duplicate env keys in a container.** SSA's
   structured-merge-diff rejects two `env:` entries with the same
   `name` in the same container with `ComparisonError`. `kubectl apply`
   (CSA) tolerates duplicates and last-wins, which is sometimes used in
   ad-hoc overrides — that approach is NOT portable to Argo. If you need
   to override a chart-rendered env var, use the chart's documented knob
   (`existingSecret`, `additionalEnv`, etc.) **or** a kustomize
   strategic-merge patch with the `name` merge key replacing the entry
   in place — never duplicate-and-rely-on-last-wins.
2. **`additionalEnv` cannot shadow chart-rendered env by re-declaring.**
   Following from (1): if the chart already defines `FOO` and you set
   `additionalEnv: - name: FOO ...`, Argo's SSA refuses the apply. Use
   a different env name, a kustomize strategic-merge patch, or change
   the chart's rendered value via its own values.

If you find yourself wanting to "just add the env again with a different
value," it won't work under Argo — you have to come at it the chart's
own way.

## Related

- [ADR 0004](../homelab-docs/02-decisions/0004-argocd-for-gitops.md)
  — GitOps via Argo CD
- [ADR 0016](../homelab-docs/02-decisions/0016-longhorn-for-cluster-storage.md)
  — Longhorn replica policy
- [ADR 0018](../homelab-docs/02-decisions/0018-openbao-deployment-shape.md)
  — OpenBao Raft + Shamir
- [ADR 0019](../homelab-docs/02-decisions/0019-forgejo-packages-as-artifact-registry.md)
  — image signing + Kyverno admission
- [ADR 0021](../homelab-docs/02-decisions/0021-observability-stack.md)
- [ADR 0023](../homelab-docs/02-decisions/0023-forgejo-and-woodpecker-ci.md)
- [ADR 0025](../homelab-docs/02-decisions/0025-nas-as-encrypted-bulk-substrate.md)
  — NAS-as-encrypted-bulk; rclone-crypt overlays per share
- [03-runbooks/cluster/argocd-bootstrap.md](../homelab-docs/03-runbooks/cluster/argocd-bootstrap.md)
- [04-guides/cold-start.md](../homelab-docs/04-guides/cold-start.md)
