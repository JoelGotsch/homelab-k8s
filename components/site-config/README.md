# components/site-config

The **single source of truth** for cluster/app site values that Argo/kustomize
consume — domain, subdomain, ingress/NAS IPs, github user. Set them **once** in
`site-config.env`; every manifest *references* them (never hardcodes), so
changing a value here changes it everywhere on the next render.

This is the k8s half of the site config; the pre-cluster/hardware half lives in
`homelab-infra/.../main.yml`, and the human schema (required vs optional) is
`homelab/examples/site-config.yaml`. Ansible reads `domain`/`internal_subdomain`
from *this* file cross-repo, so the domain is declared exactly once.

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
