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

## Phase 2 (2026-07-19): what resolves from here vs. what stays rendered

Migrated onto replacements (`.j2` siblings deleted):
- all 14 HTTPRoutes (phase 1)
- `bootstrap/applicationsets/*` + `bootstrap/argocd-self.yaml` (repoURLs, via
  `forgejo_fqdn`), `bootstrap/argocd/{externalsecret-repo-forgejo, patches/argocd-cm}`
- `infrastructure/ingress/gateway.yaml` (wildcard listeners + wildcard cert)
- `infrastructure/ingress/loadbalancer-ippool.yaml` (its `.j2` had no live
  variables at all)

**Intentionally still ansible-rendered** — the `.j2` boundary, with reasons:
- **Helm `values.yaml.j2` (9 files):** kustomize replacements cannot reach
  inside a `helmCharts.valuesFile`; patching the post-render resources
  field-by-field would recreate the wrong-chart-key trap.
- **Free-text blobs:** `renovate.json5.j2`, app configmaps (ntfy, pr-agent,
  cloudflare-tunnel, llm-gateway policies), `bootstrap/argocd/patches/
  oidc-config.yaml.j2` (issuer URL lives INSIDE the `oidc.config` string),
  authentik `_blueprint` generator — replacements cannot substitute inside
  strings.
- **Index-brittle rule arrays:** netpol `.j2`s (woodpecker/langfuse/crowdsec/
  immich) and `backup-cronjobs/prometheusrule.yaml.j2` — their FQDNs sit at
  `spec.<rules>.N.M...` paths whose indices shift on every rule edit (netpol
  rules were inserted twice in the week this was decided); a replacement that
  silently retargets the wrong rule is worse than a render step.

Derived keys (`forgejo_fqdn`) exist because replacements substitute whole
delimiter-tokens and cannot compose `forgejo.` + `fqdn_suffix` inside a URL
token. `scripts/check-site-config.sh` (pre-commit) makes derivation drift
impossible and verifies every placeholder-bearing file pulls this component.
