# observability/falco-stack

Falco DaemonSet + Falcosidekick fanout — runtime HIDS per
[ADR 0021 D4 + D7](../../../homelab-docs/02-decisions/0021-observability-stack.md).

**Status: suspended.** `kustomization.yaml` comments out the Helm chart and all
Falco-dependent resources because no tested Falco driver currently loads on the
running Talos kernel. Argo therefore applies only the shared `monitoring`
namespace from this layer; no Falco/Falcosidekick pod or notification route is
active from these manifests.

If the documented wake-up criteria are satisfied, the dormant `values.yaml`
currently describes this fan-out:

```
Falco ──> Falcosidekick ──┬──> Alertmanager ──> formatter ──> ntfy (primary)
                          ├──> Loki (retrospection)
                          └──> ntfy-e2ee-relay ──> ntfy (temporary; unreadable wire format)
```

Critical events entering Alertmanager would also inherit its separately
baselined temporary operational Signal fan-out.

## Temporary custom-relay containment

The dormant `falcosidekick.config.webhook.address` route to `ntfy-e2ee-relay`
has a custom encrypted payload which cannot be read by the current mobile
client. Suspension means it is not live, but it is still unsafe resume
configuration and cannot count as working alert coverage. P0-07 labels and
exact-baselines it so activation or another relay dependency is review-visible.

Do not remove it based on configuration inspection alone. First inject a
synthetic Falco event through Falcosidekick -> Alertmanager -> alert-formatter
-> ntfy and confirm a readable recipient receipt. Do not send raw Falco JSON
straight to alert-formatter; that service expects Alertmanager webhook shape.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Suspends the chart/resources and records exact driver wake-up criteria; the commented candidate pin is 8.0.5. |
| `namespace.yaml` | `monitoring` namespace; PSA `privileged` (Falco DaemonSet needs to read `/proc` + load eBPF). |
| `values.yaml` | Dormant resume values: interim `driver: ebpf`, tolerations, rule files, Alertmanager/Loki outputs, and the temporary custom-relay webhook. |
| `networkpolicy.yaml` | Dormant until resume: Falco/Falcosidekick ingress and egress policy. |
| `servicemonitor.yaml` | Self-metrics scrape for both Falco + Falcosidekick. |
| `rules-configmap.yaml` | Operator's local rule overlay (mounted at `/etc/falco/rules.d`). Today carries: csi-rclone driver allowlist (`user_privileged_containers` + `user_sensitive_mount_containers` extension entries for `ghcr.io/veloxpack/csi-driver-rclone`) + a homelab rule "Unexpected /dev/fuse access outside csi-rclone" defense-in-depth signal. Conventions documented inline. |

## Bring-up

This layer is part of the broader observability layer rollout
per [ADR 0021](../../../homelab-docs/02-decisions/0021-observability-stack.md).
Sequencing:

| Bring-up step | What lands |
|---|---|
| [Step 9 — Cluster bring-up](../../../homelab-docs/04-guides/cold-start.md) | Cilium + OpenBao + Argo CD ready |
| Current Argo sync | Shared `monitoring` namespace only; Falco chart and dependent resources remain commented out. |
| Resume after a wake-up criterion | Prove one Falco pod loads first, then enable Falcosidekick/Loki/Alertmanager resources in lockstep. |
| Notification gate during resume | Inject a synthetic Falco event through Alertmanager + formatter + ntfy and confirm readable receipt; do not activate the custom relay. |
| **(later) deception layer per [ADR 0010](../../../homelab-docs/02-decisions/0010-deception-controls.md)** | populate `rules-configmap.yaml` with deception rules (honeycred reads, etc.) |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

**At first install: none.** The layer is suspended and creates no Falco
workload. Its dormant output configuration declares no credential.

Current Loki, Alertmanager, and custom-relay outputs are cluster-internal and
declare no Falcosidekick credential here.

## Operator inputs

- Confirm `monitoring` namespace doesn't already exist
  with conflicting PSA labels (kube-prometheus-stack also
  creates this ns; whichever Argo Application syncs first
  wins on labels). If conflict surfaces post-deploy, the
  newer manifest wins via Argo's last-applied tracking.
- Review Falco's upstream rule list at chart-bump time —
  Renovate opens a PR per chart bump; operator confirms
  no breaking rule changes per
  [update-policy.md](../../../homelab-docs/01-architecture/update-policy.md).

## Caveats

1. **CO-RE eBPF requires kernel 5.8+.** Talos current ships
   6.x — fully supported. If operator ever runs Falco on a
   non-Talos node (rare; mac-studio doesn't get Falco), CO-RE
   compatibility needs verification.
2. **Detection-only.** Per [ADR 0021 D4](../../../homelab-docs/02-decisions/0021-observability-stack.md):
   Falco doesn't kill processes or block syscalls. Response
   path is external (revert + rotate + redeploy via the
   incident-response runbooks). Acknowledged trade-off: in-
   kernel enforcement was rejected because false-positive
   blast radius in a homelab is operator-disruptive.
3. **Privileged DaemonSet.** Falco runs privileged for syscall
   capture. The privilege is read-only on syscalls (Falco
   doesn't write back). Documented as accepted in
   [ADR 0021 D4](../../../homelab-docs/02-decisions/0021-observability-stack.md).
4. **Rule-tuning is ongoing.** Out-of-the-box rules will
   produce false positives in the homelab's specific
   workload mix. Per
   [03-runbooks/observability/rule-tuning.md](../../../homelab-docs/03-runbooks/observability/rule-tuning.md):
   quarterly review of false positives + rule overlay
   updates in `rules-configmap.yaml`.
5. **If resumed unchanged, the custom-relay webhook would send all events at or
   above `notice`.** Its recipient-incompatible format means it is temporary
   drift, not verified delivery. The parallel Alertmanager setting is the
   candidate supported path but still requires a synthetic receipt test.
6. **`monitoring` namespace co-locates Falco (privileged)
   with Prometheus (restricted).** PSA at the namespace
   level is `privileged` (the floor); each pod's
   `securityContext` enforces the actual posture. Standard
   pattern; documented inline in `namespace.yaml`.
7. **On resume, Signal fan-out would be inherited from Alertmanager, not a
   Falcosidekick approval route.** Critical Falco events would dual-send under
   the current P0-07 Alertmanager baseline. That operational path remains
   distinct from a future approval item/state flow.
8. **k8s audit-log integration depends on Talos config.**
   Per ADR 0021 D4 the K8s audit-log plugin is enabled in
   `values.yaml` — but Talos must route the audit log to
   the path Falco's plugin watches. Talos-side routing
   lives in the talos-bootstrap playbook (operator
   confirms the audit-log path matches at first install).

## Related

- [ADR 0021](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — observability stack design (Falco choice + outputs +
  routing).
- [ADR 0010](../../../homelab-docs/02-decisions/0010-deception-controls.md)
  — deception layer; operator extends `rules-configmap.yaml`
  when honeycred files land.
- [03-runbooks/observability/rule-tuning.md](../../../homelab-docs/03-runbooks/observability/rule-tuning.md)
  — quarterly false-positive review + suppression patterns.
- [`scripts/temporary-notification-route-baseline.yaml`](../../scripts/temporary-notification-route-baseline.yaml)
  — exact custom-relay and operational-Signal containment inventory.
- [apps/ntfy-e2ee-relay/](../../apps/ntfy-e2ee-relay/) —
  the webhook target for this layer's Falcosidekick output.
- [apps/ntfy/](../../apps/ntfy/) — the primary delivery endpoint through the
  Alertmanager formatter path.
