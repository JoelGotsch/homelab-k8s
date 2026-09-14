# Kyverno policy test suites

Offline proofs for the CEL policies in `../cel/`, run by
`scripts/check-kyverno-policy-tests.sh` (pre-commit hook `check-kyverno-policy-tests`)
with the Kyverno CLI pinned in `cli-pin.env` to the engine the cluster runs.

| Suite       | Policies                                                        | Fixtures |
|-------------|-----------------------------------------------------------------|----------|
| `validate/` | the ten Audit validators + `enforce-digest-pinning-allowlist`   | `resources.yaml` (Pods, controllers, PVCs, Secrets, CNPs/CCNPs, Namespaces), `clusterresources.yaml` (Namespaces, LimitRange/ResourceQuota/NetworkPolicy the `require-*` lookups list), `crds/` (Cilium), `values.yaml` (namespace labels) |
| `mutate/`   | ndots, openbao PVC retention, longhorn label propagation        | `resources.yaml` triggers, `patched.yaml` expected outputs (captured from real server dry-runs of the ClusterPolicy versions on 2026-09-14), `clusterresources.yaml` (PV/PVC the longhorn lookup reads), `crds/` (longhorn Volume) |
| `generate/` | the three `homelab-generate-default-*` policies                 | `resources.yaml` trigger Namespace, `generated-*.yaml` expected downstreams (the live `vikunja` objects' spec, renamed) |

Every fixture is a sanitised copy of a real live object (names, images, resources,
probes, labels kept; Secret `data` replaced by placeholders, status/managedFields
dropped). Add a fixture whenever a policy gains a branch.

## Conventions the CLI imposes (v1.19.1)

- A result row needs `isValidatingPolicy` / `isMutatingPolicy` /
  `isGeneratingPolicy` / `isImageValidatingPolicy: true`, or the CLI looks the
  policy up as a `ClusterPolicy` and reports `Not found`.
- A resource name may appear in `resources:` OR `clusterResources:`, never both —
  the CLI panics (`namespaces "x" already exists`) rather than erroring.
- CRDs under `clusterResources` must be `.yaml`/`.yml` files listed in
  `spec.crds`; JSON is rejected.
- `namespaceObject` / `namespaceSelector` are fed from `values.yaml`
  (`namespaceSelector[].labels`), not from Namespace resources.
- Generating policies emit NO row for a trigger they do not match, so an
  exclusion cannot be asserted as `skip`. Exclusions are checked with
  `kyverno apply <policy> --resource resources.yaml -o <dir>` — only the matched
  triggers produce a file.
- Old-kind (`ClusterPolicy`) policies using `context.apiCall` cannot be evaluated
  offline (`kyverno apply` errors on the call), so old-vs-new parity for the three
  `require-*` policies and `disallow-inline-secrets` is a cluster proof only (the
  PolicyReport fail-set comparison in the 2026-09-14 journal), not a suite here.

## What a green run does not prove

That the policy evaluates on the cluster (2026-08-02: a policy compiled, reported
Ready and enforced nothing). The cluster proof is the PolicyReport fail set plus
`kyverno_policy_results_total{policy_name=...}` per `../README.md`.
