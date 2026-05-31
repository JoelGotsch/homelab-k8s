# infrastructure/clickhouse-operator

Altinity ClickHouse Operator — declarative ClickHouse cluster
management via the `ClickHouseInstallation` (chi) CR. Per
[ADR 0028](../../../homelab-docs/02-decisions/0028-langfuse-deployment-shape.md).

Same operator-pattern as CNPG (operator at infrastructure
layer, per-app `ClickHouseInstallation` CR in the consumer
layer). Today the only consumer is `observability/langfuse/`
for its analytics database.

## Why Altinity over the official ClickHouse Operator

The official ClickHouse Kubernetes Operator (released by
ClickHouse Inc. on **2026-01-29** under Apache 2.0) is at
**v1alpha1** as of this commit. Altinity has been GA + 8
years production-deployed; Altinity reports "tens of
thousands of ClickHouse servers worldwide."

For a homelab single-instance ClickHouse backing Langfuse:
- Altinity's stable API matters more than the official's
  upstream blessing
- v1alpha1 CRD field-renames between releases would surface
  as Argo `OutOfSync` warnings on every operator bump
- None of the official's distinctive features (multi-shard
  rolling upgrades, ClickHouse Cloud production patterns)
  are load-bearing here

ADR 0028 names the reconsider-trigger: *"if the official
operator reaches v1 (GA), AND adds features Altinity
doesn't, AND those features become load-bearing for
Langfuse, migrate."*

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Altinity helm chart 0.26.3 (Renovate-pinned). |
| `namespace.yaml` | `clickhouse-operator` ns; PSA baseline. |
| `values.yaml` | Operator + metrics-exporter sidecar; RBAC scope: `namespace_clusterwide` (watches CHIs in any namespace). |
| `networkpolicy.yaml` | Ingress: Prometheus self-metrics. Egress: kube-DNS, kube-API (watch CHIs), ClickHouse pods in any namespace. |

## What this provides

- **CRDs**: `ClickHouseInstallation` (chi),
  `ClickHouseInstallationTemplate` (chit),
  `ClickHouseOperatorConfiguration`, `ClickHouseKeeperInstallation`
- **Cluster-wide watch**: any namespace can declare a chi
  and the operator reconciles it.
- **Standard CRD lifecycle**: helm chart manages CRDs +
  operator + metrics-exporter; per-app config lives in the
  consumer's chi spec.

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync this layer | Altinity operator + CRDs ready cluster-wide. |
| Argo sync `observability/langfuse/` | Langfuse's `ClickHouseInstallation` CR is created; operator provisions a single-replica ClickHouse pod + Service. |

## Caveats

1. **CRD lifecycle is helm-managed.** Operator upgrades that
   change CRD schema flow through helm. Renovate must update
   chart + image in lockstep.
2. **Cluster-wide RBAC.** The operator can manage CHIs in
   any namespace. Necessary for the per-app pattern; risk
   accepted (same trust shape as CNPG).
3. **Metrics-exporter is a sidecar in the operator pod**,
   not a separate Deployment. Its scrape port (9999) is
   distinct from the operator's own (8888).
4. **No operator-managed Keeper for our use case** — the
   single-replica Langfuse ClickHouse doesn't need
   ClickHouse Keeper (only multi-shard / replicated tables
   require it). The chart-default skips Keeper unless we
   declare a `ClickHouseKeeperInstallation` CR.
5. **`WATCH_NAMESPACES` MUST be explicit on this operator
   version (0.26.3).** The docs claim "empty = all
   namespaces"; empirically (verified 2026-05-31), an empty
   `WATCH_NAMESPACES` defaults to the operator's own
   namespace and CHIs in other namespaces are silently
   ignored. `values.yaml` sets the env explicitly via
   `operator.env`. **Any future app that ships a
   `ClickHouseInstallation` must add its namespace to this
   comma-separated list.** Symptom if forgotten: CHI
   created, finalizer never added, status empty, operator
   log shows zero mentions of the CHI name. Pinned by the
   journal entry at
   [99-journal/2026-05-31-langfuse-and-vaultwarden-bringup-saga.md](../../../homelab-docs/99-journal/2026-05-31-langfuse-and-vaultwarden-bringup-saga.md).
6. **Annotation-only changes don't trigger user-credential
   refresh.** When `kv/<app>/clickhouse` is re-seeded, ESO
   updates the K8s Secret but the CH pod still holds the
   *old* value in its `secretKeyRef` env var. The fix flow:
   re-seed → ESO sync → patch the CHI spec (not just an
   annotation — needs `metadata.generation` to bump, e.g.
   `kubectl patch chi <name> --type=merge -p
   '{"spec":{"stop":"no"}}'`) → **delete the CH pod**
   so it re-reads the env. Operator alone does not restart
   the pod on user-credential changes.

## Related

- [ADR 0028](../../../homelab-docs/02-decisions/0028-langfuse-deployment-shape.md)
  — Langfuse deployment shape; Altinity ClickHouse over
  official operator + OTel-as-instrumentation-contract.
- [ADR 0021 D3](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — Tempo + Langfuse split (LLM-specific tracing scope).
- [`observability/langfuse/`](../../observability/langfuse/)
  — the consumer; declares the `ClickHouseInstallation` CR.
- [Altinity ClickHouse Operator on GitHub](https://github.com/Altinity/clickhouse-operator)
- [Altinity Operator documentation](https://docs.altinity.com/altinitykubernetesoperator/)
