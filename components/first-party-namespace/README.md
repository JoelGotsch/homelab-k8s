# components/first-party-namespace

Shared kustomize Component that seeds the ADR 0036 D2 baseline
into every first-party namespace: LimitRange defaults, a
per-namespace ResourceQuota, a default-deny K8s NetworkPolicy,
and a commented CNP egress scaffold.

Referenced by [ADR 0036 — Cluster resource
governance](../../../homelab-docs/02-decisions/0036-cluster-resource-governance.md).

## Usage

From an app's `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: my-app

resources:
  - namespace.yaml
  - deployment.yaml
  - ciliumnetworkpolicy.yaml   # app-specific CNP; see below

components:
  - ../../components/first-party-namespace
```

The component is **namespace-agnostic**. The app's own
`namespace.yaml` remains authoritative for the namespace name
AND for the required labels:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
  labels:
    homelab.internal/first-party: "true"
    homelab.internal/data-class: internal   # or public/personal/secret
    pod-security.kubernetes.io/enforce: restricted
```

The two `homelab.internal/*` labels drive the Kyverno
ClusterPolicies' `match.any.resources.namespaceSelector`
(ADR 0036 D4). Without them, the policies do not apply and
the workload runs *unchecked* — not more-strict.

## What each file emits

| File | Kind | Purpose |
|---|---|---|
| `kustomization.yaml` | `Component` | Aggregates the resources below. |
| `limitrange.yaml` | `LimitRange` | Container-level default `{cpu: 500m, memory: 512Mi}` / defaultRequest `{cpu: 50m, memory: 128Mi}`; PVC `min: 100Mi`. Capacity ceilings live in per-StorageClass `ResourceQuota` fields so NAS claims are not constrained by Longhorn limits. |
| `resourcequota.yaml` | `ResourceQuota` | Per-namespace ceilings (`requests.memory: 16Gi`, `count/persistentvolumeclaims: 20`, `count/services.loadbalancers: 0`, etc.). |
| `networkpolicy-default-deny.yaml` | `NetworkPolicy` | Vanilla K8s `podSelector: {}` deny-all; defence-in-depth alongside Cilium. |
| `ciliumnetworkpolicy-egress-scaffold.yaml` | (comments only) | Template CNP with kube-DNS + kube-apiserver (443 AND 6443) + FQDN allowlist. App copies + edits + registers. |

## Fields the app is expected to override

The component ships *defaults*. Apps that legitimately need
more headroom override in their own overlay.

| Field | Override how | When |
|---|---|---|
| `LimitRange.spec.limits[type=Container].default.{cpu,memory}` | Strategic-merge patch in the app kustomization. | App has a genuine per-container ceiling (JVM, ClickHouse, ML inference). |
| `ResourceQuota.spec.hard.requests.memory` (and siblings) | Same. | App has a well-understood aggregate above the default. |
| `ResourceQuota.spec.hard.count/persistentvolumeclaims` | Same. | App creates >20 PVCs by design (Woodpecker CI historically hit this — see ADR 0023 D5 lineage). |
| `ciliumnetworkpolicy-egress-scaffold.yaml` | The scaffold is commented; app copies it into `apps/<name>/ciliumnetworkpolicy.yaml` and fills in labels + FQDNs. | Always — the scaffold is a template, not a policy. |

**Do not** override by editing this component — the
component is shared. All overrides live in the calling app's
overlay.

## Requesting a bypass

Some workloads legitimately need to escape a Kyverno
enforcement (e.g., a legacy Helm chart whose image tag is
mutable-by-design; a CronJob whose peak memory legitimately
exceeds the default LimitRange). The bypass annotation
convention is (ADR 0036 D3):

```yaml
metadata:
  annotations:
    bypass.homelab.internal/<policy-name>: "reason: <text>; ticket: <link>; expires: <YYYY-MM-DD>"
```

- `<policy-name>` matches the Kyverno ClusterPolicy name
  (e.g., `homelab-container-resources-required`,
  `homelab-image-digest-required`).
- Kyverno's `preconditions` on each policy check for the
  matching annotation and skip enforcement when present.
- `expires:` is not enforced by Kyverno; the audit ClusterPolicy
  `homelab-bypass-audit` flags annotations whose `expires:`
  is in the past for operator review.
- A bypass without an `expires:` value SHOULD be paired with
  either an ADR amendment (durable) or an ADR-listed known
  caveat (durable-but-tolerated).

For PVCs on the `-retain` storage classes, the reason lives
in its own annotation family (retain is opt-in, not a
bypass):

```yaml
metadata:
  annotations:
    retention.homelab.internal/reason: "CNPG primary data; deleted PVC must not tombstone volume"
```

Enforced by `homelab-retain-requires-reason` (ADR 0036 D1
+ D3).

## Related documents

- [ADR 0036 — Cluster resource governance](../../../homelab-docs/02-decisions/0036-cluster-resource-governance.md)
- [ADR 0016 — Longhorn](../../../homelab-docs/02-decisions/0016-longhorn-for-cluster-storage.md)
- [ADR 0019 — Forgejo Packages + Kyverno signing gate](../../../homelab-docs/02-decisions/0019-forgejo-packages-as-artifact-registry.md)
- [ADR 0023 D5 — CI-namespace quota pattern](../../../homelab-docs/02-decisions/0023-forgejo-and-woodpecker-ci.md)
- [ADR 0003 — Data classification](../../../homelab-docs/02-decisions/0003-data-classification.md)
- [`infrastructure/kyverno/`](../../infrastructure/kyverno/) — ClusterPolicies that enforce the same shape at admission time
- [`infrastructure/longhorn/storageclasses.yaml`](../../infrastructure/longhorn/storageclasses.yaml) — Delete-default + `-retain` opt-in classes (ADR 0036 D1)
