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

## Status (2026-09-14)

Live since 2026-09-14 20:20Z on all six nodes (hl-0125). The layer had
been Synced/Healthy since 2026-04-30 and had never shipped a line: the
sidecar was removed on 2026-05-23 after a crashloop, and nothing that
remained had ever run. Re-adding it found six defects, each fixed in its
own commit after a one-node trial pod on worker3:

1. `vector validate` rejected the config: the `prometheus_exporter` sink
   was fed the Log components ("Data type mismatch"). Self-metrics now
   come from an `internal_metrics` source (`df11ad3`).
2. `ciliumnetworkpolicy.yaml` admitted only `host`; five of six sidecars
   reach Loki as `remote-node` (`df11ad3`).
3. The disk buffer was 268435456 bytes, 32 short of Vector's minimum;
   the sink refused to build (exit 78). `vector validate` does not build
   buffers, so it had passed. Now 512 MiB (`5796f42`).
4. The remap did `. = parsed` on a record the exporter wraps as
   `{"flow": {...}, "node_name": ..., "time": ...}`, so every line was
   `verdict=UNKNOWN`, `source_namespace=external`; it now unwraps
   `.flow` (`b85d247`).
5. The `node` label was the literal string `${NODE_NAME}`; it now comes
   from the wrapper's `node_name` (cluster prefix stripped) or the
   NODE_NAME env via `get_env_var` (`b85d247`).
6. `loki.monitoring.svc.cluster.local` does not resolve from the
   cilium-agent pod: host network, `dnsPolicy: ClusterFirst`, i.e. the
   node's resolver. The sink pushes to the Service's ClusterIP, which
   `observability/loki` pins (`b85d247`); see caveat 8.

On the producer side (`infrastructure/cilium/values.yaml`, `83d97dc`)
the export is now declared — it had run since bootstrap on ConfigMap
keys neither repo carried — with an `allowList` that keeps
DROPPED/ERROR/AUDIT verdicts, every L7 record and any flow with
`reserved:world` on either side, and `hubble.redact` (hl-0315,
`b73c2e4`/`b682d06`) that strips every HTTP header except Accept,
Content-Type, Content-Length, User-Agent and X-Request-Id, plus URL
query strings and basic-auth user info. Measured after the roll:
~170 lines/s cluster-wide (worker2 70/s, cp1 0.1/s).

**Incident, same day:** the trial pod at 19:50–20:02Z shipped the then
unfiltered, unredacted export from worker3 — 806 lines in Loki carry
Authorization/Cookie/Set-Cookie values for woodpecker, forgejo,
nextcloud, jellyfin, immich and librechat sessions. hl-0315 tracks the
Loki delete request and rotation. Do not run this pipeline against live
flows with `hubble.redact` off.

The sidecar image is `timberio/vector:0.58.0-distroless-libc` pinned by
digest in cilium values; Renovate does not track that string (hl-0253),
bump it by hand. A Docker Hub pull takes ~5 min per node here (30 s
Spegel NodePort timeout, then a slow fetch); a roll with
`maxUnavailable: 2` therefore takes ~10 min.

## What ships

| Source | Loki labels | Notes |
|---|---|---|
| `/var/run/cilium/hubble/events.log` (cilium-agent's hubble static export) | `job=hubble`, `verdict`, `source_namespace`, `node` | Cardinality-bounded to ~600 streams (5 verdicts × ~20 namespaces × 6 nodes); `destination_namespace` and `traffic_direction` stay as queryable JSON fields |

Endpoint: `http://10.98.57.58:3100` — the `loki` Service's pinned
ClusterIP (caveat 8). No tenant header — Loki is `auth_enabled: false` (single-tenant
homelab; NetworkPolicy gates).

Field selection upstream is governed by
[`infrastructure/cilium/values.yaml`](../../infrastructure/cilium/values.yaml)'s
`hubble.export.static.fieldMask` — `time`, `verdict`,
`drop_reason_desc`, `traffic_direction`, `is_reply`, `Type`,
`event_type`, `IP`, `l4`, `l7`, `source`, `destination`, `node_name`
(proto field names) — and its `allowList`, which decides which
records are written at all. Operator extends fieldMask + Vector
remap when a forensic question needs a field.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Resource list. The sidecar container itself is declared in [`infrastructure/cilium/values.yaml`](../../infrastructure/cilium/values.yaml) `extraContainers`. |
| `configmap.yaml` | Vector pipeline config (`vector.yaml` data key). Lives in `kube-system` so the sidecar can mount it; OWNED by this layer. |
| `ciliumnetworkpolicy.yaml` | Loki ingress allow for `fromEntities: [host, remote-node]` — needed because vanilla NetworkPolicy can't select host-network pods. |
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

4. **Vector uses a disk-backed buffer (512 MiB; Vector's minimum is
   256 MiB + 32 bytes) on a hostPath volume at
   `/var/lib/vector/hubble-flow-exporter` per node.**
   `when_full: block` back-pressures the source (Cilium's
   static-export file) on prolonged Loki outages; the file
   itself buffers another ~50 MiB before rotation drops
   events. Total durable-on-disk window: ~512 MiB (Vector) +
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

8. **Loki is addressed by ClusterIP, pinned in
   [`observability/loki/kustomization.yaml`](../loki/kustomization.yaml).**
   A host-network pod with `dnsPolicy: ClusterFirst` uses the node's
   resolver (the router), which has no `cluster.local`; switching the
   cilium DaemonSet to `ClusterFirstWithHostNet` would make the CNI
   agent depend on kube-dns, which depends on the CNI. If Loki's Service
   is ever recreated, the patch keeps the address — unless the service
   CIDR changes, in which case both the patch and `configmap.yaml`
   move together.

9. **Never trial this pipeline on live flows with `hubble.redact` off.**
   HTTP L7 records carry request and response headers; on 2026-09-14
   a trial run shipped 12 minutes of them unredacted (see Status).
   Redaction is a cilium value, so it is on wherever the export is;
   a trial pod that reads the same file inherits it — but only once
   the values that enable it have rolled.

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
