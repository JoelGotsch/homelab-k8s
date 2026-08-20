# components/site-config

The **single source of truth** for cluster/app site values that Argo/kustomize
consume — domain, subdomain, ingress/NAS IPs, github user. Set them **once** in
`site-config.env`; every manifest *references* them (never hardcodes), so
changing a value here changes it everywhere on the next render.

This is the k8s half of the site config; the pre-cluster/hardware half lives in
`homelab-infra/ansible/inventory/group_vars/all/main.yml`, and the human schema
(required vs optional) is `homelab/examples/site-config.yaml`.

**Corrected 2026-08-19.** This used to say Ansible reads `domain` /
`internal_subdomain` from *this* file cross-repo, "so the domain is declared
exactly once". It does not. `group_vars/all/main.yml` carries its own
`homelab_domain` and `homelab_internal_subdomain`, plus `cluster_ingress_ip`,
`forgejo_ssh_ingress_ip`, `registry_direct_ip` and `operator_github_user` — the
same values, typed twice. Ansible cannot read a kustomize component, so that
overlap is unavoidable and is the ONE duplication ADR 0045 D2 permits.

It is therefore linted rather than wished away:
`homelab-infra/scripts/check-site-config-cross-surface.sh` fails when the two
surfaces disagree. Believing the old sentence is what makes the drift dangerous
— you would change one surface and expect the other to follow.

## How it works

`kustomization.yaml` is a kustomize **Component** that turns `site-config.env`
into a `site-config` ConfigMap, marked `config.kubernetes.io/local-config: "true"`
so it's used for substitution at build time but **not deployed**. Consumers
include the component and add `replacements:` that pull `ConfigMap/site-config`
values into their manifest fields.

**One mechanism for both raw manifests AND Helm output** — `replacements:` run on
the final resource tree, so they fix a field whether it came from a raw YAML or a
rendered Helm chart. (The rare exception: a value a Helm chart needs at *template*
time, e.g. a conditional — set that in the chart's `helmCharts[].valuesInline`.)

## Usage

In an app's `kustomization.yaml`:

```yaml
components:
  - ../../components/site-config      # brings ConfigMap/site-config into scope
replacements:
  - source: { kind: ConfigMap, name: site-config, fieldPath: data.fqdn_suffix }
    targets:
      - select: { kind: HTTPRoute, name: myapp }
        fieldPaths: [spec.hostnames.0]
        options: { delimiter: '.', index: 1 }   # myapp.PLACEHOLDER -> myapp.<fqdn_suffix>
```

A worked, render-tested example is in `../site-config-example/` (a constructed
hostname + a full-value NAS-IP field). Render it: `kubectl kustomize
components/site-config-example`.

### The hostname trick
A hostname like `myapp.lab.vyramo.com` is built from `myapp.PLACEHOLDER` by a
replacement with `delimiter: '.'`, `index: 1` — kustomize splits on `.`, swaps the
last segment for `fqdn_suffix` (`lab.vyramo.com`), and rejoins. No domain literal
in the manifest.

### Full-value fields
Straight replacement (no delimiter): the NAS IP, `k8sServiceHost`, LB VIPs, etc.

## Debugging provenance (the point)
To find where `myapp.lab.vyramo.com` comes from: it's not a literal — the manifest
has `myapp.PLACEHOLDER`, and the `replacements:` block names
`ConfigMap/site-config.data.fqdn_suffix`, defined in `site-config.env`. **One hop
to the source**, not "which `.j2` in the other repo rendered this."

## Why the env lives in this dir (not the repo root)
Kustomize forbids a kustomization from reading files above its own root, and a
Component is rooted at its own dir — so `site-config.env` must live here, beside
the Component that reads it. This is the well-known single path; don't relax
`--load-restrictor` to move it (that would let any kustomization read any file).

## Migration status
This is the pattern + a proven example. Converting the ~40 hardcoded manifests to
reference site-config is the deliberate reusability pass tracked in
`homelab/reusability-architecture.md` (Workstream B) — do it per-app, verifying
each render against live, behind the CI equality gate.

## What resolves from here vs. what stays rendered

Migrated onto replacements (`.j2` siblings deleted):
- all 14 HTTPRoutes (phase 1)
- `bootstrap/applicationsets/*` + `bootstrap/argocd-self.yaml` (repoURLs, via
  `forgejo_fqdn`), `bootstrap/argocd/{externalsecret-repo-forgejo, patches/argocd-cm}`
- `infrastructure/ingress/gateway.yaml` (wildcard listeners + wildcard cert)
- `infrastructure/ingress/loadbalancer-ippool.yaml` (its `.j2` had no live
  variables at all)
- **2026-08-20, ADR 0045 C2** — `platform/pr-agent/configmap.yaml`
  (`GITEA__URL`), `platform/woodpecker/networkpolicy.yaml` (the Forgejo
  `matchName`), `infrastructure/backup-cronjobs/prometheusrule.yaml` (five
  `runbook_url` owners), and the first three Helm `values.yaml`:
  `platform/authentik` (`AUTHENTIK_HOST`), `platform/woodpecker`
  (`WOODPECKER_HOST` + `WOODPECKER_FORGEJO_URL`), `observability/langfuse`
  (`NEXTAUTH_URL`). Four more `.j2` were deleted outright because their only
  Jinja was inside a comment (`observability/{crowdsec,langfuse}/networkpolicy`,
  `observability/{kube-prometheus-stack,langfuse}/externalsecret`), and
  `renovate.json5.j2` because it templated nothing at all.
- **2026-08-20, ADR 0045 C2 (second pass)** —
  `infrastructure/kyverno/policies/verify-first-party-image-signature.yaml`
  (the two apex-Forgejo `imageReferences` globs, each selected by its own
  value) and `bootstrap/argocd/patches/oidc-config.yaml` (the OIDC issuer,
  staged commented-out alongside the patch it targets). The kyverno one also
  needed the policy's `description` annotation reworded, because that
  annotation named the host in prose and is itself rendered output.

### Two objections that were withdrawn, and why

Both were written on 2026-07-19 and are no longer true:

- *"kustomize replacements cannot reach inside a `helmCharts.valuesFile`"* —
  correct, and irrelevant. They do not have to: replacements run on the final
  resource tree, so the placeholder survives Helm inflation and is fixed in the
  RENDERED object (`spec.template.spec.containers.[name=…].env.[name=…].value`).
  ADR 0052's A3 spike settled this as D3a. Three values files moved this way
  with byte-identical renders.
- *"index-brittle rule arrays"* — the fix is not a render step, it is to stop
  using indices. Select the element by its own value or name:
  `spec.egress.*.toFQDNs.[matchName=FORGEJO_FQDN].matchName`,
  `spec.groups.[name=…].rules.[alert=…].annotations.runbook_url`,
  `…imageReferences.[=FORGEJO_FQDN/homelab/*]`. A value selector that stops
  matching is a hard `kustomize build` error ("unable to find field … in
  replacement target"), not a silent no-op. Never use `*` over the list that
  holds the placeholder — see lessons.md.

### Still rendered, with the specific reason

The remaining reason is always the same one: **the value sits inside a
free-text string**, and a replacement substitutes a whole field or a
delimiter-token, never a substring of a blob.

| File | Where the value sits, and what was measured |
|---|---|
| `infrastructure/cloudflare-tunnel/configmap.yaml.j2` | three public hostnames inside the `data.config\.yaml` blob. **Not expressible at all**, not merely fragile: on `delimiter: '.'` the domain occupies TWO tokens (`vyramo` at indices 10/18/26/35, `com` after each), and a replacement rewrites one token — `vaultwarden.` + `vyramo.com` + `.com`. On `':'` each token is ` vaultwarden.vyramo.com\n    service`, i.e. the value plus the next line |
| `platform/renovate/configmap.yaml.j2` | `endpoint:` inside the `data.config\.js` JavaScript blob. A `delimiter: '/', index: 13` replacement **does** render correctly today (verified). It was still refused: the blob is 72 `/`-tokens of which the first 13 are comment prose, so ONE added `//` comment line above the endpoint shifts it. Verified by doing exactly that — `kustomize build` exits 0, prints no warning, overwrites the new comment with the FQDN, and ships `endpoint: 'https://FORGEJO_FQDN/api/v1'` to a weekly CronJob. `'`-splitting isolates the whole URL at index 3 but counts apostrophes in prose the same way |
| `observability/kube-prometheus-stack/values.yaml.j2` | five URLs inside the **chart-generated** `grafana.ini` blob. `delimiter: '/'` isolates the three Authentik URLs cleanly (indices 2, 8, 14) but never `domain`/`root_url` (tokens 32/34 carry the following INI section), so the fragile route covers 3 of 5. And the indices move on a chart bump, which is not hypothetical: the blob's own `[unified_storage] index_path = /var/lib/grafana-search/bleve` is a recently-added chart default sitting after them |
| `platform/forgejo/values.yaml.j2` | `DOMAIN`/`ROOT_URL`/`SSH_DOMAIN` inside the chart-generated `server` field of the `forgejo-inline-config` Secret, plus the OIDC `autoDiscoverUrl` inside the chart's `configure_gitea.sh` init-script blob. Only `ROOT_URL`'s host is a clean token (`'/'` index 3); `DOMAIN` and `SSH_DOMAIN` split as `forgejo.lab.vyramo.com\nENABLE_PPROF` — value plus next key. Helm sorts the section alphabetically, so one added `server` key with a `/` in its value shifts index 3 |
| `platform/authentik/blueprints/_blueprint.yaml.j2` | a generator over `homelab-infra/ansible/inventory/oidc-apps.yml`, not a projection — documented ADR 0045 exception |
| `scripts/fixtures/retention-unparseable-default-storageclass.yaml.j2` | a deliberately unparseable test fixture on a non-Argo path — documented ADR 0045 exception |
| `apps/*` (8 files) | superseded central copies. Every one reconciles from its OWN repo at `k8s/` per `bootstrap/applicationsets/apps.yaml`; nothing renders these. They go with the guarded `apps/*` cleanup and **cannot be deleted ahead of it**: deleting a `.j2` removes the sibling exemption in `check-no-bare-domain.sh`, and five of the eight rendered siblings still carry a value-position domain literal (nextcloud 3, vaultwarden 2, immich-public-proxy / ntfy / paperless-values 1 each). That script's own comment says the same — do the directory cleanup first, or re-add them to `KNOWN_VIOLATIONS` for the interval |

The four blob rows share one property worth stating plainly: a replacement can
substitute a whole field or a whole delimiter-token, never a substring. Where
the only reachable token is at a **hand-counted index**, converting is worse
than leaving the literal — the literal is wrong loudly at another site, and the
index is wrong silently at this one.

Note that "still rendered" overstates it: `00-render-static.yml` has hard-failed
on its own drift guard since 2026-07-17, so none of these can actually be
re-rendered today.

Derived keys (`forgejo_fqdn`) exist because replacements substitute whole
delimiter-tokens and cannot compose `forgejo.` + `fqdn_suffix` inside a URL
token. `scripts/check-site-config.sh` (pre-commit) makes derivation drift
impossible and verifies every placeholder-bearing file pulls this component.
