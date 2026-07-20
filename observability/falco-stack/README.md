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
```

If ntfy publish fails, the formatter provides the conditional one-way Signal
fallback; Falcosidekick has no direct Signal or custom-relay output.

## Custom relay retired from resume configuration

The incompatible `ntfy-e2ee-relay` webhook was removed. When this suspended
layer resumes, inject a synthetic Falco event through Falcosidekick ->
Alertmanager -> alert-formatter -> ntfy and confirm readable receipt. Do not
send raw Falco JSON straight to alert-formatter; it expects Alertmanager shape.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Suspends the chart/resources and records exact driver wake-up criteria; the commented candidate pin is 8.0.5. |
| `namespace.yaml` | `monitoring` namespace; PSA `privileged` (Falco DaemonSet needs to read `/proc` + load eBPF). |
| `values.yaml` | Dormant resume values: interim `driver: ebpf`, tolerations, rule files, and Alertmanager/Loki outputs. |
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
| Notification gate during resume | Inject a synthetic Falco event through Alertmanager + formatter + ntfy and confirm readable receipt. |
| **(later) deception layer per [ADR 0010](../../../homelab-docs/02-decisions/0010-deception-controls.md)** | populate `rules-configmap.yaml` with deception rules (honeycred reads, etc.) |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

**At first install: none.** The layer is suspended and creates no Falco
workload. Its dormant output configuration declares no credential.

Current Loki and Alertmanager outputs are cluster-internal and
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
5. **Resume still requires a synthetic receipt.** Configuration inspection
   proves shape, not mobile delivery through Falcosidekick and Alertmanager.
6. **`monitoring` namespace co-locates Falco (privileged)
   with Prometheus (restricted).** PSA at the namespace
   level is `privileged` (the floor); each pod's
   `securityContext` enforces the actual posture. Standard
   pattern; documented inline in `namespace.yaml`.
7. **On resume, Signal is conditional fallback only.** Critical Falco events
   still target ntfy; an ntfy publish failure may produce the one-way typed
   fallback, which remains distinct from approval state.
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
  — route-regression inventory; Alertmanager/custom-relay expected sets are empty.
- [apps/ntfy/](../../apps/ntfy/) — the primary delivery endpoint through the
  Alertmanager formatter path.
