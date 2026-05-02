# observability/hubble-flow-exporter

Hubble network flows → Loki, via a Vector **sidecar** in the
`cilium-agent` DaemonSet. Per
[ADR 0021 D5](../../../homelab-docs/02-decisions/0021-observability-stack.md)
("Hubble flows are the primary exfiltration signal").

Decisions captured in
[99-journal/2026-04-30-hubble-flow-shipping.md](../../../homelab-docs/99-journal/2026-04-30-hubble-flow-shipping.md).

## Why a sidecar (not a Deployment-talks-to-relay)

| Property | Sidecar in cilium-agent | Deployment + hubble-relay |
|---|---|---|
| Per-node lifecycle alignment | yes — dies with cilium-agent on its node | no — independent lifecycle, can be alive while producer restarts |
| `hubble-relay` as SPOF for security signal | no — reads cilium-agent's local static-export file | yes — relay outage = exfiltration-signal blackout |
| Topology | per-node producer → per-node consumer (straight path) | per-node producer → relay aggregate → exporter re-fan to Loki |
| Failure-mode legibility | "node-3's flows missing → check node-3" | layer triage required |

## What ships

| Source | Loki labels | Notes |
|---|---|---|
| `/var/run/cilium/hubble/events.log` (cilium-agent's hubble static export) | `job=hubble`, `verdict`, `source_namespace`, `node` | Cardinality-bounded to ~600 streams (5 verdicts × ~20 namespaces × 6 nodes); `destination_namespace` and `traffic_direction` stay as queryable JSON fields |

Endpoint: `http://loki.monitoring.svc.cluster.local:3100`. No
tenant header — Loki is `auth_enabled: false` (single-tenant
homelab; NetworkPolicy gates).

Field selection upstream is governed by
[`infrastructure/cilium/values.yaml`](../../infrastructure/cilium/values.yaml)'s
`hubble.export.static.fieldMask` — currently `time`, `source`,
`destination`, `verdict`, `drop_reason_desc`,
`traffic_direction`, `l4`, `l7`. Operator extends fieldMask
+ Vector remap when a forensic question needs a field.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Resource list. The sidecar container itself is declared in [`infrastructure/cilium/values.yaml`](../../infrastructure/cilium/values.yaml) `extraContainers`. |
| `configmap.yaml` | Vector pipeline config (`vector.yaml` data key). Lives in `kube-system` so the sidecar can mount it; OWNED by this layer. |
| `ciliumnetworkpolicy.yaml` | Loki ingress allow for `fromEntities: [host]` — needed because vanilla NetworkPolicy can't select host-network pods. |
| `podmonitor.yaml` | Prometheus scrape of the sidecar's `:9598` self-metrics via the named `hubble-export` container port. |
| `prometheusrule.yaml` | Buffer-fullness + event-drop + source-stall alerts. Closes the audit follow-up "no actionable threshold alert on Vector pipeline lag." |

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync `infrastructure/cilium/` | cilium-agent DaemonSet now includes the sidecar container (Vector reading the local static-export file). |
| Argo sync `observability/loki/` | Loki Service + NetworkPolicy + chunks bucket. |
| Argo sync this layer | ConfigMap (sidecar starts shipping after next cilium-agent rotation), CCNP (Loki accepts host-identity ingress on 3100), PodMonitor (Prometheus scrapes Vector metrics). |
| Argo sync `observability/kube-prometheus-stack/` (Loki data source enabled) | Operator queries `{job="hubble"}` in Grafana → Explore. |

Order matters at first install: the sidecar will retry-loop
its loki sink until the Loki Service exists; the CCNP must
land before Loki ingress works. All three components are in
the same observability sync wave (5) → no inter-wave
coordination needed.

## Caveats

1. **Sidecar runs as root** within the cilium-agent pod. The
   cilium-agent writes `events.log` with mode `0600`; reading
   it from a non-root sidecar would require either a Cilium
   chart knob to relax the file mode or a shared `fsGroup`,
   neither of which is cleanly exposed at the chart level.
   All capabilities dropped, `readOnlyRootFilesystem: true`,
   `allowPrivilegeEscalation: false`. The pod is already
   privileged for legitimate CNI reasons; the sidecar's blast
   radius is bounded by what `cilium-agent` itself can do.

2. **Sidecar restarts independently of cilium-agent on
   ConfigMap update.** Kustomize's ConfigMap suffixing is OFF
   in this layer (no `configMapGenerator` — direct
   `configmap.yaml` resource), so Vector picks up new config
   only on container restart. To roll a config change:
   `kubectl rollout restart daemonset/cilium -n kube-system`.
   Coupling this to the agent's lifecycle is intentional —
   we want the sidecar's life to track its host pod's life.

3. **Cardinality budget: ~600 active Loki streams.** Labels
   are `job` (1) × `verdict` (~5) × `source_namespace`
   (~20) × `node` (~6). `destination_namespace`,
   `traffic_direction`, source/dest pod, L4/L7 details are
   JSON fields, not labels — query via LogQL JSON parser.
   If `source_namespace` cardinality grows past ~50, drop it
   from labels too; Loki streams scale with the *product* of
   label cardinalities.

4. **Vector uses a disk-backed buffer (256 MiB) on a hostPath
   volume at `/var/lib/vector/hubble-flow-exporter` per node.**
   `when_full: block` back-pressures the source (Cilium's
   static-export file) on prolonged Loki outages; the file
   itself buffers another ~50 MiB before rotation drops
   events. Total durable-on-disk window: ~256 MiB (Vector) +
   ~50 MiB (Cilium rotation) before any drops happen.
   Hostpath survives sidecar restarts and pod rescheduling
   on the same node.

5. **Static export file rotation.** Cilium's `hubble.export`
   chart options bound the file (`fileMaxSizeMb`,
   `fileMaxBackups`, `fileCompress`). Vector's file source
   discovers `events.log.*` rotated files — they get tailed
   to completion. A burst that fills + rotates faster than
   Vector can drain still drops events on the rotated-out
   tail; bound is set conservatively (10 MiB × 5 backups =
   50 MiB before drops at sustained burst).

6. **CCNP-only ingress for host-identity traffic.** Loki's
   vanilla NetworkPolicy at
   [`loki/networkpolicy.yaml`](../loki/networkpolicy.yaml)
   handles pod-to-pod traffic from Alloy / Falcosidekick /
   Grafana / Prometheus; this layer's CCNP adds the
   host-identity rule for cilium-agent's hostNetwork
   sidecar. Both policies compose with OR — order doesn't
   matter, neither is canonical for "all Loki ingress."

7. **PodMonitor selects on `k8s-app: cilium`** — the chart
   default label on cilium-agent pods. If the chart relabels
   in a future bump, the PodMonitor stops matching and
   sidecar metrics go dark. The sidecar's *flow shipping*
   continues; only the metrics pipeline breaks. ServiceMonitor
   coverage of cilium-agent itself (already in cilium values)
   exposes a `cilium_hubble_flows_*` counter that's an
   independent canary.

## Related

- [ADR 0021 D5](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — Hubble Loki exporter as primary exfiltration signal.
- [99-journal/2026-04-30-hubble-flow-shipping.md](../../../homelab-docs/99-journal/2026-04-30-hubble-flow-shipping.md)
  — sidecar-vs-deployment decision + caveats.
- [`infrastructure/cilium/values.yaml`](../../infrastructure/cilium/values.yaml)
  — sidecar container declaration (`extraContainers` block).
- [`observability/loki/`](../loki/) — the destination.
- [05-security/threat-model/scenarios/secret-exfiltration.md](../../../homelab-docs/05-security/threat-model/scenarios/secret-exfiltration.md)
  — the scenario this signal carries.
